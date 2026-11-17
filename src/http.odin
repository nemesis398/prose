package prose

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import curl "vendor:curl"

// HTTP for the LanguageTool pass: one form POST at a time over libcurl,
// which brings HTTPS with the system's certificates on every platform.
// `vendor:curl` links libcurl the way each platform needs.

// Why a request got no HTTP answer: no connection, a timeout, a broken
// reply, an answer too big to take. An empty `message` means there was an
// answer, whatever its status. A non-empty one is allocated with the
// allocator given to `post_form`; free it with `delete`.
Http_Error :: struct {
	message: string,
}

// An answer bigger than this is refused. LanguageTool's answer to a full
// chunk is a few hundred kilobytes.
MAX_RESPONSE_BYTES :: 32 << 20

USER_AGENT :: "prose-check"

@(private = "file")
curl_once: sync.Once

// curl_global_init must run once per process before any other libcurl call,
// and tests post from several threads at once, so it goes through a Once.
// It is never undone: the process ends first.
@(private = "file")
curl_init :: proc() {
	sync.once_do(&curl_once, proc() {
		curl.global_init(curl.GLOBAL_ALL)
	})
}

@(private = "file")
Sink :: struct {
	ctx:      runtime.Context,
	body:     [dynamic]byte,
	too_big:  bool,
}

@(private = "file")
sink_write :: proc "c" (buffer: [^]byte, size, nitems: c.size_t, outstream: rawptr) -> c.size_t {
	s := (^Sink)(outstream)
	context = s.ctx
	n := int(size * nitems)
	if len(s.body) + n > MAX_RESPONSE_BYTES {
		s.too_big = true
		return 0 // anything short of n makes curl stop with an error
	}
	if _, err := append(&s.body, ..buffer[:n]); err != nil {
		return 0
	}
	return c.size_t(n)
}

// form_encode encodes `fields` as `application/x-www-form-urlencoded`, the
// way Python's `urllib.parse.urlencode` does: letters, digits and `_.-~`
// stay, a space becomes `+`, every other byte becomes `%XX`.
form_encode :: proc(fields: [][2]string, allocator := context.allocator) -> string {
	HEX := "0123456789ABCDEF"
	sb := strings.builder_make(allocator)
	for f, i in fields {
		if i > 0 {
			strings.write_byte(&sb, '&')
		}
		for part, j in f {
			if j == 1 {
				strings.write_byte(&sb, '=')
			}
			for k in 0 ..< len(part) {
				b := part[k]
				switch b {
				case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '_', '.', '-', '~':
					strings.write_byte(&sb, b)
				case ' ':
					strings.write_byte(&sb, '+')
				case:
					strings.write_byte(&sb, '%')
					strings.write_byte(&sb, HEX[b >> 4])
					strings.write_byte(&sb, HEX[b & 15])
				}
			}
		}
	}
	return strings.to_string(sb)
}

// post_form POSTs `fields`, form-encoded, to `url` and returns the status
// and the body of the answer, whatever the status. Redirects are not
// followed, only http and https are spoken, and the whole exchange,
// connecting included, must finish within `timeout_s` seconds.
//
// On an error `status` is 0 and `body` empty. `body` and `err.message` are
// allocated with `allocator`; the caller frees them with `delete`. The
// fields may hold a key: nothing here prints them.
post_form :: proc(
	url: string,
	fields: [][2]string,
	timeout_s: int,
	allocator := context.allocator,
) -> (
	status: int,
	body: string,
	err: Http_Error,
) {
	curl_init()
	h := curl.easy_init()
	if h == nil {
		return 0, "", Http_Error{strings.clone("curl could not start", allocator)}
	}
	defer curl.easy_cleanup(h)

	curl_url := strings.clone_to_cstring(url, allocator)
	defer delete(curl_url, allocator)
	payload := form_encode(fields, allocator)
	defer delete(payload, allocator)

	headers: ^curl.slist
	headers = curl.slist_append(headers, "Accept: application/json")
	// curl asks a server for "100 Continue" before a big body; LanguageTool
	// never needs the round trip, and the reference never made it.
	headers = curl.slist_append(headers, "Expect:")
	defer curl.slist_free_all(headers)

	sink := Sink {
		ctx  = context,
		body = make([dynamic]byte, allocator),
	}
	errbuf: [curl.ERROR_SIZE]byte

	curl.easy_setopt(h, .URL, curl_url)
	curl.easy_setopt(h, .PROTOCOLS_STR, cstring("http,https"))
	curl.easy_setopt(h, .USERAGENT, cstring(USER_AGENT))
	curl.easy_setopt(h, .HTTPHEADER, headers)
	curl.easy_setopt(h, .POSTFIELDSIZE_LARGE, curl.off_t(len(payload)))
	curl.easy_setopt(h, .POSTFIELDS, raw_data(payload))
	curl.easy_setopt(h, .WRITEFUNCTION, curl.write_callback(sink_write))
	curl.easy_setopt(h, .WRITEDATA, &sink)
	curl.easy_setopt(h, .ERRORBUFFER, &errbuf[0])
	curl.easy_setopt(h, .TIMEOUT, c.long(timeout_s))
	// No signals: the timeout must not use SIGALRM in a threaded program.
	curl.easy_setopt(h, .NOSIGNAL, c.long(1))

	code := curl.easy_perform(h)
	if code != .E_OK {
		delete(sink.body)
		detail := string(cstring(&errbuf[0]))
		if sink.too_big {
			detail = "the answer is too big"
		} else if detail == "" {
			detail = string(curl.easy_strerror(code))
		}
		return 0, "", Http_Error{strings.clone(detail, allocator)}
	}
	response: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &response)
	return int(response), string(sink.body[:]), {}
}
