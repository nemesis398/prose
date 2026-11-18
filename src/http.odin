package prose

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import curl "vendor:curl"

// HTTP for the LanguageTool pass: one form POST at a time over libcurl,
// which brings HTTPS with the system's certificates on every platform.
// `vendor:curl` links libcurl the way each platform needs.

// Why a request got no usable HTTP answer: no connection, a timeout, a broken
// reply, an answer too big to take, or a libcurl that cannot do what the
// request needs. An empty `message` means there was an answer, whatever its
// status. A non-empty one is allocated with the allocator given to
// `post_form`; free it with `delete`.
//
// `retryable` says whether asking again could help: a timeout or a lost
// connection, yes; an answer too big, a refused option or a bad URL, no.
// `kind` says where it went wrong.
Http_Error :: struct {
	message:   string,
	kind:      Http_Error_Kind,
	retryable: bool,
}

Http_Error_Kind :: enum {
	// The server could not be reached, or the exchange broke off.
	Unreachable,
	// The server answered, and the answer cannot be taken: it is too big.
	Bad_Answer,
	// The request never left: libcurl is missing a feature or refused an
	// option.
	Local,
}

// What a caller may ask of one request beyond the URL and the form.
//
// - `no_proxy`: libcurl's NOPROXY list, a comma-separated list of hosts that
//   bypass a proxy. "" sets nothing, which leaves it to the `no_proxy`
//   variable.
// - `proxy`: the proxy to use. "" leaves it to the `http_proxy` variables. It
//   exists so that a test can name a proxy without touching the process
//   environment.
Http_Options :: struct {
	no_proxy, proxy: string,
}

// The hosts that never go through a proxy: the machine itself, which is where
// a self-hosted LanguageTool and the test server live.
LOOPBACK_NO_PROXY :: "localhost,127.0.0.1,::1"

// loopback_no_proxy is the `no_proxy` option of `Http_Options` to use when
// the user did (`user_set`) or did not set `no_proxy` or `NO_PROXY`. A user
// who set it keeps their list, empty included.
loopback_no_proxy :: proc(user_set: bool) -> string {
	return "" if user_set else LOOPBACK_NO_PROXY
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

// CURLOPT_PROTOCOLS, the bit mask that libcurl before 7.85 knows in place
// of CURLOPT_PROTOCOLS_STR. Odin's binding left it out as deprecated; libcurl
// still takes it.
@(private = "file")
CURLOPT_PROTOCOLS :: curl.option(curl.OPTTYPE_LONG + 181)

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
// connecting included, must finish within `timeout_s` seconds. `opts` says
// which hosts bypass a proxy.
//
// Every option is checked: one that libcurl refuses stops the request before
// it is sent, with an error naming the option, because a timeout or a
// protocol limit that silently vanished is worse than no request. The one
// exception is NOPROXY, an optimization: see `setopt_is_fatal`.
//
// On an error `status` is 0 and `body` empty. `body` and `err.message` are
// allocated with `allocator`; the caller frees them with `delete`. The
// fields may hold a key: nothing here prints them.
post_form :: proc(
	url: string,
	fields: [][2]string,
	timeout_s: int,
	opts: Http_Options = {},
	allocator := context.allocator,
) -> (
	status: int,
	body: string,
	err: Http_Error,
) {
	curl_init()
	h := curl.easy_init()
	if h == nil {
		return 0, "", Http_Error{message = strings.clone("curl could not start", allocator), kind = .Local}
	}
	defer curl.easy_cleanup(h)

	// Only http and https. A libcurl older than 7.85 (EL8's 7.61, Ubuntu
	// 22.04's 7.81) refuses PROTOCOLS_STR as an unknown option and would
	// then speak every protocol it has, file: included; it takes the bit
	// mask instead. A libcurl that takes neither is not used at all.
	if curl.easy_setopt(h, .PROTOCOLS_STR, cstring("http,https")) != .E_OK &&
	   curl.easy_setopt(h, CURLOPT_PROTOCOLS, c.long(curl.PROTO_HTTP | curl.PROTO_HTTPS)) != .E_OK {
		return 0, "", Http_Error{message = strings.clone("curl cannot be limited to http and https", allocator), kind = .Local}
	}

	curl_url := strings.clone_to_cstring(url, allocator)
	defer delete(curl_url, allocator)
	payload := form_encode(fields, allocator)
	defer delete(payload, allocator)
	curl_no_proxy := strings.clone_to_cstring(opts.no_proxy, allocator)
	defer delete(curl_no_proxy, allocator)
	curl_proxy := strings.clone_to_cstring(opts.proxy, allocator)
	defer delete(curl_proxy, allocator)

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

	set := Options{}
	option(&set, curl.easy_setopt(h, .URL, curl_url), "URL")
	option(&set, curl.easy_setopt(h, .USERAGENT, cstring(USER_AGENT)), "USERAGENT")
	option(&set, curl.easy_setopt(h, .HTTPHEADER, headers), "HTTPHEADER")
	option(&set, curl.easy_setopt(h, .POSTFIELDSIZE_LARGE, curl.off_t(len(payload))), "POSTFIELDSIZE_LARGE")
	option(&set, curl.easy_setopt(h, .POSTFIELDS, raw_data(payload)), "POSTFIELDS")
	// The size limit lives in the write callback.
	option(&set, curl.easy_setopt(h, .WRITEFUNCTION, curl.write_callback(sink_write)), "WRITEFUNCTION")
	option(&set, curl.easy_setopt(h, .WRITEDATA, &sink), "WRITEDATA")
	option(&set, curl.easy_setopt(h, .ERRORBUFFER, &errbuf[0]), "ERRORBUFFER")
	option(&set, curl.easy_setopt(h, .TIMEOUT, c.long(timeout_s)), "TIMEOUT")
	// No signals: the timeout must not use SIGALRM in a threaded program.
	option(&set, curl.easy_setopt(h, .NOSIGNAL, c.long(1)), "NOSIGNAL")
	if opts.no_proxy != "" {
		option(&set, curl.easy_setopt(h, .NOPROXY, curl_no_proxy), "NOPROXY")
	}
	if opts.proxy != "" {
		option(&set, curl.easy_setopt(h, .PROXY, curl_proxy), "PROXY")
	}
	if set.failed != "" {
		delete(sink.body)
		msg := fmt.aprintf("curl refused its %s option: %s", set.failed, curl.easy_strerror(set.code), allocator = allocator)
		return 0, "", Http_Error{message = msg, kind = .Local}
	}

	code := curl.easy_perform(h)
	if code != .E_OK {
		delete(sink.body)
		detail := string(cstring(&errbuf[0]))
		if sink.too_big {
			return 0, "", Http_Error{message = strings.clone("the answer is too big", allocator), kind = .Bad_Answer}
		}
		if detail == "" {
			detail = string(curl.easy_strerror(code))
		}
		return 0, "", Http_Error{message = strings.clone(detail, allocator), retryable = is_transient(code)}
	}
	response: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &response)
	return int(response), string(sink.body[:]), {}
}

// The first option that libcurl refused, and its answer.
@(private = "file")
Options :: struct {
	failed: string,
	code:   curl.code,
}

@(private = "file")
option :: proc(o: ^Options, code: curl.code, name: string) {
	if o.failed == "" && setopt_is_fatal(name, code) {
		o.failed, o.code = name, code
	}
}

// setopt_is_fatal tells whether libcurl's answer `code` to the option `name`
// stops the request. Any refusal does, except one of NOPROXY, which only
// saves a loopback request a trip through a proxy: a libcurl built without
// proxy support answers CURLE_UNKNOWN_OPTION, and has no proxy to bypass.
setopt_is_fatal :: proc(name: string, code: curl.code) -> bool {
	return code != .E_OK && name != "NOPROXY"
}

// is_transient reports whether a failed transfer may succeed when tried
// again: the network let go, or was slow. A certificate that does not verify,
// a URL that is not one, or an answer that does not fit will not change.
@(private = "file")
is_transient :: proc(code: curl.code) -> bool {
	#partial switch code {
	case .E_COULDNT_RESOLVE_PROXY,
	     .E_COULDNT_RESOLVE_HOST,
	     .E_COULDNT_CONNECT,
	     .E_OPERATION_TIMEDOUT,
	     .E_GOT_NOTHING,
	     .E_SEND_ERROR,
	     .E_RECV_ERROR,
	     .E_PARTIAL_FILE,
	     .E_HTTP2,
	     .E_HTTP2_STREAM,
	     .E_SSL_CONNECT_ERROR:
		return true
	}
	return false
}
