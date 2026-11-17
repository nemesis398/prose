package prose_tests

import "core:crypto/sha2"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

// A fake LanguageTool: plain HTTP on 127.0.0.1, an ephemeral port, one
// thread, answering `POST /v2/check` from the recordings in
// tests/lt-recordings. It is the Odin twin of reference/fake_lt.py, whose
// docstring defines the recording key; `recording_key` computes it the same
// way from the decoded form fields.
//
// Each test starts its own fake with `fake_lt_start` and ends it with
// `fake_lt_stop`, which joins the thread and frees everything. Odin has no
// closures, so the fake is a handle rather than a `stop` procedure.

Fake_Mode :: enum {
	// Answer every request from its recording; 404 without one.
	Replay,
	// Answer every POST with 403.
	Refuse_403,
	// Read every request and never answer; the client has to give up. The
	// connection stays open, unanswered, until the fake stops, and the fake
	// goes on accepting: waiting for the client to close instead would wait
	// for ever when a child process started meanwhile by another test has
	// inherited the client's socket, as it can from a libcurl that does not
	// open its sockets close-on-exec (7.61 does not).
	Hang,
	// Replay, except that the second distinct check request (one with a
	// `data` field) and every retry of it get 500.
	Fail_Second_Chunk,
}

Fake_Lt :: struct {
	dir:       string,
	mode:      Fake_Mode,
	listener:  net.TCP_Socket,
	port:      int,
	worker:    ^thread.Thread,
	stopping:  bool, // atomic
	requests:  int, // atomic: every request read in full
	// The server thread's own: the connections Hang holds open.
	held:      [dynamic]net.TCP_Socket,
	// The server thread's own, for Fail_Second_Chunk.
	data_keys: [dynamic]string,
}

// A request bigger than this is refused. A full chunk is under 1 MiB.
@(private = "file")
MAX_REQUEST_BYTES :: 16 << 20

// fake_lt_start starts a fake that answers from `recordings_dir` (copied)
// in `mode`. It fails the calling test, and returns nil, when it cannot
// listen.
fake_lt_start :: proc(recordings_dir: string, mode: Fake_Mode) -> (fake: ^Fake_Lt, port: int) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if err != nil {
		fmt.eprintfln("fake LanguageTool: cannot listen: %v", err)
		return nil, 0
	}
	ep, eerr := net.bound_endpoint(listener)
	if eerr != nil {
		net.close(listener)
		return nil, 0
	}
	fake = new(Fake_Lt)
	fake.dir = strings.clone(recordings_dir)
	fake.mode = mode
	fake.listener = listener
	fake.port = ep.port
	fake.data_keys = make([dynamic]string)
	fake.held = make([dynamic]net.TCP_Socket)
	fake.worker = thread.create(fake_serve)
	fake.worker.data = fake
	fake.worker.init_context = context
	thread.start(fake.worker)
	return fake, fake.port
}

// fake_lt_stop stops the fake: it wakes the thread out of `accept` with a
// connection of its own, joins it, and frees everything.
fake_lt_stop :: proc(fake: ^Fake_Lt) {
	if fake == nil {
		return
	}
	sync.atomic_store(&fake.stopping, true)
	if wake, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = fake.port}); err == nil {
		net.close(wake)
	}
	thread.join(fake.worker)
	thread.destroy(fake.worker)
	net.close(fake.listener)
	for c in fake.held {
		net.close(c)
	}
	delete(fake.held)
	for k in fake.data_keys {
		delete(k)
	}
	delete(fake.data_keys)
	delete(fake.dir)
	free(fake)
}

// fake_lt_requests is the number of requests the fake has read in full.
fake_lt_requests :: proc(fake: ^Fake_Lt) -> int {
	return sync.atomic_load(&fake.requests)
}

@(private = "file")
fake_serve :: proc(th: ^thread.Thread) {
	fake := (^Fake_Lt)(th.data)
	for {
		client, _, err := net.accept_tcp(fake.listener)
		if sync.atomic_load(&fake.stopping) {
			if err == nil {
				net.close(client)
			}
			return
		}
		if err != nil {
			return
		}
		net.set_option(client, .Receive_Timeout, time.Second)
		if fake_handle(fake, client) {
			append(&fake.held, client)
		} else {
			net.close(client)
		}
	}
}

@(private = "file")
Request :: struct {
	method, path: string,
	body:         string,
}

// read_request reads one request: the head up to the blank line, then
// `Content-Length` bytes of body. `raw` holds it all; the strings point
// into it. False on a timeout, a closed connection or a malformed head.
@(private = "file")
read_request :: proc(client: net.TCP_Socket, raw: ^[dynamic]byte) -> (req: Request, ok: bool) {
	buf: [64 << 10]byte
	head_end := -1
	for head_end < 0 {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n == 0 {
			return
		}
		append(raw, ..buf[:n])
		head_end = strings.index(string(raw[:]), "\r\n\r\n")
		if head_end < 0 && len(raw) > MAX_REQUEST_BYTES {
			return
		}
	}
	head := string(raw[:head_end])
	lines := head
	request_line, _ := strings.split_lines_iterator(&lines)
	parts := strings.fields(request_line)
	defer delete(parts)
	if len(parts) != 3 {
		return
	}
	length := 0
	for line in strings.split_lines_iterator(&lines) {
		colon := strings.index_byte(line, ':')
		if colon > 0 && strings.equal_fold(strings.trim_space(line[:colon]), "content-length") {
			n, nok := strconv.parse_int(strings.trim_space(line[colon + 1:]), 10)
			if !nok || n < 0 || n > MAX_REQUEST_BYTES {
				return
			}
			length = n
		}
	}
	body_start := head_end + 4
	for len(raw) - body_start < length {
		n, err := net.recv_tcp(client, buf[:])
		if err != nil || n == 0 {
			return
		}
		append(raw, ..buf[:n])
	}
	// The strings point into `raw`; nothing may append to it from here on.
	return Request{method = parts[0], path = parts[1], body = string(raw[body_start:body_start + length])}, true
}

// fake_handle answers one connection. True means keep it open, unanswered,
// until the fake stops.
@(private = "file")
fake_handle :: proc(fake: ^Fake_Lt, client: net.TCP_Socket) -> (hold: bool) {
	raw := make([dynamic]byte)
	defer delete(raw)
	req, ok := read_request(client, &raw)
	if !ok {
		return
	}
	sync.atomic_add(&fake.requests, 1)

	if fake.mode == .Hang {
		return true
	}

	path := req.path
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	if path != "/v2/check" {
		send_response(client, 404, "text/plain", "not found")
		return
	}
	if req.method != "POST" {
		send_response(client, 405, "text/plain", "not found")
		return
	}
	if fake.mode == .Refuse_403 {
		send_response(client, 403, "text/plain", "forbidden")
		return
	}

	form, fok := parse_form(req.body)
	defer form_destroy(&form)
	key, kok := "", false
	if fok {
		key, kok = recording_key(form)
	}
	if !kok {
		send_response(client, 400, "text/plain", "malformed request")
		return
	}
	defer delete(key)

	if fake.mode == .Fail_Second_Chunk && "data" in form {
		known := false
		for k in fake.data_keys {
			known ||= k == key
		}
		if !known {
			append(&fake.data_keys, strings.clone(key))
		}
		if len(fake.data_keys) >= 2 && fake.data_keys[1] == key {
			send_response(client, 500, "text/plain", "simulated failure")
			return
		}
	}

	path_json := strings.concatenate({fake.dir, "/", key, ".json"})
	defer delete(path_json)
	body, rerr := os.read_entire_file(path_json, context.allocator)
	if rerr != nil {
		msg := strings.concatenate({"no recording for key ", key})
		defer delete(msg)
		send_response(client, 404, "text/plain", msg)
		return
	}
	defer delete(body)
	send_response(client, 200, "application/json", string(body))
	return
}

@(private = "file")
send_response :: proc(client: net.TCP_Socket, status: int, ctype, body: string) {
	reason := "OK"
	switch status {
	case 400:
		reason = "Bad Request"
	case 403:
		reason = "Forbidden"
	case 404:
		reason = "Not Found"
	case 405:
		reason = "Method Not Allowed"
	case 500:
		reason = "Internal Server Error"
	}
	head := fmt.aprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		status, reason, ctype, len(body),
	)
	defer delete(head)
	net.send_tcp(client, transmute([]byte)head)
	net.send_tcp(client, transmute([]byte)body)
}

// A decoded form: each field's first value, as the reference fake keeps
// it. Keys and values are allocated; free with `form_destroy`.
Form :: map[string]string

form_destroy :: proc(form: ^Form) {
	for k, v in form {
		delete(k)
		delete(v)
	}
	delete(form^)
}

// parse_form decodes an `application/x-www-form-urlencoded` body as
// Python's `parse_qs(keep_blank_values=True)` does: fields split on `&`, a
// field without `=` has an empty value, `+` is a space, `%XX` a byte. The
// result must be UTF-8.
parse_form :: proc(body: string) -> (form: Form, ok: bool) {
	form = make(Form)
	rest := body
	for field in strings.split_iterator(&rest, "&") {
		if field == "" {
			continue
		}
		eq := strings.index_byte(field, '=')
		name, value := field, ""
		if eq >= 0 {
			name, value = field[:eq], field[eq + 1:]
		}
		k := form_decode(name)
		v := form_decode(value)
		if !utf8.valid_string(k) || !utf8.valid_string(v) || k in form {
			// Not UTF-8 fails the request; a repeated field keeps the first.
			bad := !utf8.valid_string(k) || !utf8.valid_string(v)
			delete(k)
			delete(v)
			if bad {
				form_destroy(&form)
				return nil, false
			}
			continue
		}
		form[k] = v
	}
	return form, true
}

// form_decode turns `+` into a space and `%XX` into its byte; a `%` not
// followed by two hex digits stays as it is, as in Python's `unquote`.
@(private = "file")
form_decode :: proc(s: string) -> string {
	hexval :: proc(c: u8) -> (int, bool) {
		switch c {
		case '0' ..= '9':
			return int(c - '0'), true
		case 'a' ..= 'f':
			return int(c - 'a' + 10), true
		case 'A' ..= 'F':
			return int(c - 'A' + 10), true
		}
		return 0, false
	}
	out := make([dynamic]byte, 0, len(s))
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '+' {
			append(&out, ' ')
			continue
		}
		if c == '%' && i + 2 < len(s) {
			hi, hok := hexval(s[i + 1])
			lo, lok := hexval(s[i + 2])
			if hok && lok {
				append(&out, u8(hi << 4 | lo))
				i += 2
				continue
			}
		}
		append(&out, c)
	}
	return string(out[:])
}

// canonical_items joins the annotation items of a request as
// reference/fake_lt.py's docstring says: "t:" + text, or "m:" + markup +
// "\x02" + interpretAs, joined with "\x01"; from the JSON in `data`, or, without
// it, the one text item of `text`. Allocated; free with `delete`. False when
// `data` is not a JSON object whose `annotation` is a list of objects.
canonical_items :: proc(form: Form) -> (canonical: string, ok: bool) {
	sb := strings.builder_make()
	data, has_data := form["data"]
	if !has_data {
		strings.write_string(&sb, "t:")
		strings.write_string(&sb, form["text"] or_else "")
		return strings.to_string(sb), true
	}
	value, err := json.parse_string(data, .JSON, true)
	defer json.destroy_value(value)
	doc, is_obj := value.(json.Object)
	if err != .None || !is_obj {
		strings.builder_destroy(&sb)
		return "", false
	}
	items: json.Array
	if list, present := doc["annotation"]; present {
		items, ok = list.(json.Array)
		if !ok {
			strings.builder_destroy(&sb)
			return "", false
		}
	}
	for item, i in items {
		obj, iok := item.(json.Object)
		if !iok {
			strings.builder_destroy(&sb)
			return "", false
		}
		if i > 0 {
			strings.write_byte(&sb, 0x01)
		}
		if markup, has_markup := obj["markup"]; has_markup {
			m, mok := markup.(json.String)
			interp, _ := obj["interpretAs"].(json.String)
			if !mok {
				strings.builder_destroy(&sb)
				return "", false
			}
			strings.write_string(&sb, "m:")
			strings.write_string(&sb, m)
			strings.write_byte(&sb, 0x02)
			strings.write_string(&sb, interp)
		} else {
			text, _ := obj["text"].(json.String)
			strings.write_string(&sb, "t:")
			strings.write_string(&sb, text)
		}
	}
	return strings.to_string(sb), true
}

// recording_key is hex(sha256(language + "\x00" + level + "\x00" +
// canonical)), with `level` "default" when the field is absent or empty.
// Allocated; free with `delete`.
recording_key :: proc(form: Form) -> (key: string, ok: bool) {
	canonical := canonical_items(form) or_return
	defer delete(canonical)
	level := form["level"] or_else ""
	if level == "" {
		level = "default"
	}
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)(form["language"] or_else ""))
	sha2.update(&ctx, []byte{0})
	sha2.update(&ctx, transmute([]byte)level)
	sha2.update(&ctx, []byte{0})
	sha2.update(&ctx, transmute([]byte)canonical)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	HEX := "0123456789abcdef"
	out := make([]byte, 2 * len(digest))
	for b, i in digest {
		out[2 * i] = HEX[b >> 4]
		out[2 * i + 1] = HEX[b & 15]
	}
	return string(out), true
}
