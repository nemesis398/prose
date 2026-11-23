package prose_tests

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import curl "vendor:curl"
import prose "../src"

// The LanguageTool pass, against the fake server replaying the answers that
// were recorded from the real API. The golden files in tests/golden-lt are
// the reference's output for the same answers.

@(private = "file")
RECORDINGS :: #directory + "lt-recordings"

// The reference's probe, its canonical string and its recording: the
// fake's key derivation, pinned.
@(test)
the_fake_keys_the_probe_like_the_reference :: proc(t: ^testing.T) {
	form, ok := parse_form("text=This+are+a+test.&language=en-US")
	defer form_destroy(&form)
	testing.expect(t, ok)
	canonical, cok := canonical_items(form)
	defer delete(canonical)
	testing.expect(t, cok)
	testing.expect_value(t, canonical, "t:This are a test.")
	key, kok := recording_key(form)
	defer delete(key)
	testing.expect(t, kok)
	testing.expect_value(t, key, "b042188f04f4c99d9ca1a03db109d6b18a97ebcdab95bc68243fb9622adfb8d8")
	path := strings.concatenate({RECORDINGS, "/", key, ".json"})
	defer delete(path)
	testing.expectf(t, os.is_file(path), "no recording %s", path)
}

// A request with `data`, as Python's urlencode and json.dumps sent it:
// text and markup items, with and without interpretAs. The canonical string
// and the key are the reference fake's for the same body.
@(test)
the_fake_keys_a_data_request_like_the_reference :: proc(t: ^testing.T) {
	body := "data=%7B%22annotation%22%3A+%5B%7B%22text%22%3A+%22Ein+%5C%22Test%5C%22.%5Cn%22%7D%2C+%7B%22markup%22%3A+%22%60x%60%22%2C+%22interpretAs%22%3A+%22x%22%7D%2C+%7B%22markup%22%3A+%22%5B%5Ba%5D%5D%22%7D%5D%7D&language=de-DE&level=picky"
	form, ok := parse_form(body)
	defer form_destroy(&form)
	testing.expect(t, ok)
	canonical, _ := canonical_items(form)
	defer delete(canonical)
	testing.expect_value(t, canonical, "t:Ein \"Test\".\n\x01m:`x`\x02x\x01m:[[a]]\x02")
	key, _ := recording_key(form)
	defer delete(key)
	testing.expect_value(t, key, "38cb817c9c4232a75a30eecd7415c10c34ec7b9257d3706cce79af16dde9e166")
}

// Malformed requests get no key: `data` that is not JSON, not an object,
// or whose annotation is not a list of objects.
@(test)
the_fake_refuses_malformed_data :: proc(t: ^testing.T) {
	for body in ([]string{"data=%7B", "data=%5B%5D", "data=%7B%22annotation%22%3A+1%7D", "data=%7B%22annotation%22%3A+%5B1%5D%7D", "data=%7B%22annotation%22%3A+%5B%7B%22markup%22%3A+1%7D%5D%7D"}) {
		form, _ := parse_form(body)
		key, ok := recording_key(form)
		testing.expectf(t, !ok, "%s: got key %s", body, key)
		delete(key)
		form_destroy(&form)
	}
	_, ok := parse_form("text=%FF")
	testing.expect(t, !ok, "a body that is not UTF-8 is malformed")
}

// The form encoding is Python's urlencode, byte for byte.
@(test)
form_encode_matches_python :: proc(t: ^testing.T) {
	fields := [?][2]string{{"a b", "x&y=z+1~_.-ü/€ 😀"}, {"data", "{\"annotation\": [{\"text\": \"Hä?\\n\"}]}"}}
	got := prose.form_encode(fields[:])
	defer delete(got)
	testing.expect_value(t, got, "a+b=x%26y%3Dz%2B1~_.-%C3%BC%2F%E2%82%AC+%F0%9F%98%80&data=%7B%22annotation%22%3A+%5B%7B%22text%22%3A+%22H%C3%A4%3F%5Cn%22%7D%5D%7D")
	none := prose.form_encode({})
	defer delete(none)
	testing.expect_value(t, none, "")
}

// A server that is not there: an error, no status, no body.
@(test)
post_form_to_a_closed_port_fails :: proc(t: ^testing.T) {
	listener, err := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	testing.expect(t, err == nil)
	ep, _ := net.bound_endpoint(listener)
	net.close(listener)
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", ep.port)
	defer delete(url)
	status, body, herr := prose.post_form(url, {{"text", "x"}}, 5)
	defer delete(body)
	defer delete(herr.message)
	testing.expect_value(t, status, 0)
	testing.expect_value(t, body, "")
	testing.expect(t, herr.message != "", "no error for a closed port")
}

// Only http and https: a file URL is refused before anything is read.
@(test)
post_form_refuses_other_schemes :: proc(t: ^testing.T) {
	status, body, herr := prose.post_form("file:///etc/hostname", {{"text", "x"}}, 5)
	defer delete(body)
	defer delete(herr.message)
	testing.expect_value(t, status, 0)
	testing.expect(t, herr.message != "", "a file URL was fetched")
}

// The fake answers a key it has no recording for with 404 and the key, and
// any other path with 404, as the reference fake does.
@(test)
the_fake_answers_404_without_a_recording :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", port)
	defer delete(url)
	status, body, herr := prose.post_form(url, {{"text", "Nobody recorded this."}, {"language", "en-US"}}, 5)
	defer delete(body)
	testing.expect_value(t, herr.message, "")
	testing.expect_value(t, status, 404)
	testing.expect(t, strings.has_prefix(body, "no recording for key "), body)

	other := fmt.aprintf("http://127.0.0.1:%d/v2/other", port)
	defer delete(other)
	status2, body2, _ := prose.post_form(other, {{"text", "x"}}, 5)
	defer delete(body2)
	testing.expect_value(t, status2, 404)
	testing.expect_value(t, fake_lt_requests(fake), 2)
}

// An empty form is an empty POST body. Given no body, curl would read the
// body from standard input instead.
@(test)
post_form_sends_an_empty_form_as_an_empty_body :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", port)
	defer delete(url)
	status, body, herr := prose.post_form(url, {}, 3)
	defer delete(body)
	defer delete(herr.message)
	testing.expect_value(t, herr.message, "")
	testing.expect_value(t, status, 404)
	// The key of no fields at all: language "", level "default", "t:".
	testing.expect_value(t, body, "no recording for key f96c9710b7cdf89aa05636d9b1baa5faaf5fc8bc010d40678cef6d57df16056f")
}

@(private = "file")
golden_words :: proc() -> prose.Word_Set {
	// What the reference had when the goldens were made: the built-in words
	// and the shipped dictionary, which holds comments only.
	return prose.load_words_in({}, "", #directory + "../skills/prose")
}

@(private = "file")
server_backend :: proc(port: int) -> prose.Backend {
	return prose.Backend {
		kind  = .Server,
		url   = fmt.aprintf("http://127.0.0.1:%d", port),
		label = "self-hosted",
	}
}

@(private = "file")
read_corpus :: proc(name: string) -> string {
	path := strings.concatenate({#directory, "corpus/", name})
	defer delete(path)
	data, _ := os.read_entire_file(path, context.allocator)
	return string(data)
}

// load_golden reads a golden file's note and findings. The strings belong
// to `value`; free it with `json.destroy_value` and the slice with `delete`.
@(private = "file")
load_golden :: proc(t: ^testing.T, path: string) -> (note: string, want: []prose.Finding, value: json.Value, ok: bool) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, rerr == nil, "read %s: %v", path, rerr) {
		return
	}
	defer delete(data)
	perr: json.Error
	value, perr = json.parse(data, parse_integers = true)
	if !testing.expectf(t, perr == nil, "parse %s: %v", path, perr) {
		json.destroy_value(value)
		return "", nil, nil, false
	}
	files, _ := value.(json.Array)
	doc, _ := files[0].(json.Object)
	note, _ = doc["note"].(json.String)
	list, _ := doc["findings"].(json.Array)
	want = make([]prose.Finding, len(list))
	for item, i in list {
		w, _ := item.(json.Object)
		sev: prose.Severity
		switch w["severity"].(json.String) or_else "" {
		case "error":
			sev = .Error
		case "warning":
			sev = .Warning
		case "note":
			sev = .Note
		case:
			testing.expectf(t, false, "%s: finding %d has an unknown severity", path, i)
		}
		want[i] = prose.Finding {
			line       = int(w["line"].(json.Integer) or_else -1),
			col        = int(w["col"].(json.Integer) or_else -1),
			severity   = sev,
			rule       = w["rule"].(json.String) or_else "\x00",
			message    = w["message"].(json.String) or_else "\x00",
			excerpt    = w["excerpt"].(json.String) or_else "\x00",
			suggestion = w["suggestion"].(json.String) or_else "\x00",
		}
	}
	return note, want, value, true
}

// Every corpus file with a golden-lt file gives the reference's findings
// and note through the fake, and de-note.md with picky its picky file.
// empty.md and only-code.md have no prose after masking, so the port sends
// nothing at all (Review Focus 3): their findings must match and the fake
// must see no request. Their golden note is hand-corrected to the port's,
// which has no LanguageTool part since nothing was sent.
@(test)
languagetool_matches_the_golden_files :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	words := golden_words()
	defer prose.word_set_destroy(&words)

	dir := #directory + "corpus"
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)

	Case :: struct {
		name, golden: string,
		picky:        bool,
	}
	cases := make([dynamic]Case)
	defer delete(cases)
	paths := make([dynamic]string)
	defer {
		for p in paths {
			delete(p)
		}
		delete(paths)
	}
	for e in entries {
		if !strings.has_suffix(e.name, ".md") {
			continue
		}
		golden := strings.concatenate({#directory, "golden-lt/", e.name[:len(e.name) - 3], ".json"})
		append(&paths, golden)
		if os.is_file(golden) {
			append(&cases, Case{e.name, golden, false})
		}
	}
	picky := #directory + "golden-lt/de-note.picky.json"
	append(&cases, Case{"de-note.md", picky, true})
	testing.expectf(t, len(cases) == 10, "%d cases, want 9 golden-lt files and the picky one", len(cases))

	matched := 0
	for c in cases {
		if golden_lt_matches(t, fake, c.name, c.golden, c.picky, backend, words) {
			matched += 1
		}
	}
	testing.expectf(t, matched == len(cases), "%d of %d match their golden-lt file", matched, len(cases))
}

@(private = "file")
golden_lt_matches :: proc(
	t: ^testing.T,
	fake: ^Fake_Lt,
	name, golden: string,
	picky: bool,
	backend: prose.Backend,
	words: prose.Word_Set,
) -> bool {
	note, want, value, ok := load_golden(t, golden)
	defer json.destroy_value(value)
	defer delete(want)
	if !ok {
		return false
	}
	md := read_corpus(name)
	defer delete(md)
	before := fake_lt_requests(fake)
	result, cerr := prose.check_text(md, {lang = "auto", use_lt = true, picky = picky, backend = backend, words = words})
	defer prose.file_result_destroy(&result)
	defer delete(cerr.message)
	if !testing.expectf(t, cerr.message == "", "%s: error %q", name, cerr.message) {
		return false
	}
	if name == "empty.md" || name == "only-code.md" {
		sent := fake_lt_requests(fake) - before
		if !testing.expectf(t, sent == 0, "%s: %d requests for a text with no prose", name, sent) {
			return false
		}
	}
	if !testing.expectf(t, result.note == note, "%s: note %q, golden %q", name, result.note, note) {
		return false
	}
	return expect_findings(t, golden, 0, result.findings, want)
}

// A backend that refuses the probe stops the check, naming the backend, its
// URL and the status; 403 is not retried.
@(test)
a_refusing_backend_stops_the_check :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Refuse_403)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	md := read_corpus("fixture.md")
	defer delete(md)
	result, err := prose.check_text(md, {lang = "auto", use_lt = true, backend = backend})
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	want := fmt.aprintf("self-hosted (%s) answered HTTP 403", backend.url)
	defer delete(want)
	testing.expect_value(t, err.message, want)
	testing.expect_value(t, len(result.findings), 0)
	testing.expect_value(t, result.note, "")
	testing.expect_value(t, fake_lt_requests(fake), 1)
}

// A server that answers 200 and JSON but no matches list, or an empty one
// for the probe sentence, is not checking: the probe fails, so no text is
// reported clean that was never looked at.
@(test)
a_backend_that_does_not_check_fails_the_probe :: proc(t: ^testing.T) {
	for mode in ([]Fake_Mode{.No_Matches, .Empty_Matches}) {
		fake, port := fake_lt_start(RECORDINGS, mode)
		defer fake_lt_stop(t, fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		backend := server_backend(port)
		defer delete(backend.url)
		md := read_corpus("fixture.md")
		defer delete(md)
		result, err := prose.check_text(md, {lang = "auto", use_lt = true, backend = backend})
		defer prose.file_result_destroy(&result)
		defer delete(err.message)
		testing.expectf(t, err.message != "", "%v: the probe passed, note %q", mode, result.note)
		prefix := fmt.aprintf("self-hosted (%s) answered but is not checking: the answer has no matches", backend.url)
		defer delete(prefix)
		testing.expectf(t, strings.has_prefix(err.message, prefix), "%v: error %q", mode, err.message)
		testing.expectf(t, !strings.contains(err.message, "unreachable"), "%v: error %q", mode, err.message)
		testing.expect_value(t, result.note, "")
		testing.expect_value(t, len(result.findings), 0)
		testing.expect_value(t, fake_lt_requests(fake), 1)
	}
}

// A check answer without a matches list, after a good probe, is a failed
// chunk, never a clean one.
@(test)
a_chunk_answer_without_matches_is_a_failed_chunk :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .No_Matches_After_Probe)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	md := read_corpus("fixture.md")
	defer delete(md)
	timing := prose.LT_TIMING
	timing.retry_pause_ms = 10
	result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expect_value(t, err.message, "")
	testing.expectf(t, strings.contains(result.note, " | chunk failed: the answer has no matches list"), "note %q", result.note)
	failed := 0
	for f in result.findings {
		if f.rule == "LT-CHUNK-FAILED" {
			failed += 1
			testing.expect_value(t, f.severity, prose.Severity.Error)
			testing.expectf(t, strings.contains(f.message, "the answer has no matches list"), "%s", f.message)
		}
	}
	testing.expectf(t, failed > 0, "no LT-CHUNK-FAILED finding")
}

// An integer beyond 64 bits in an answer is not read as some other number: a
// parser wraps 18446744073709551616 to 0, which would put a finding at the
// start of the chunk. The chunk fails instead, and is not retried.
@(test)
an_answer_with_a_number_beyond_64_bits_is_a_failed_chunk :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Wide_Number_After_Probe)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	md := read_corpus("fixture.md")
	defer delete(md)
	timing := prose.LT_TIMING
	timing.retry_pause_ms = 10
	result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expect_value(t, err.message, "")
	testing.expectf(t, strings.contains(result.note, " | chunk failed: the answer holds an integer beyond 64 bits"), "note %q", result.note)
	failed, from_server := 0, 0
	for f in result.findings {
		if f.rule == "LT-CHUNK-FAILED" {
			failed += 1
		}
		if f.rule == "LT:X" {
			from_server += 1
		}
	}
	testing.expectf(t, failed > 0, "no LT-CHUNK-FAILED finding")
	testing.expect_value(t, from_server, 0)
}

// A backend that never answers: the probe gives up after its timeout, is
// retried as the reference retries, and the check stops naming the backend.
@(test)
a_hanging_backend_times_out :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Hang)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	md := read_corpus("fixture.md")
	defer delete(md)
	timing := prose.Lt_Timing {
		request_s      = 2,
		probe_s        = 2,
		retries        = prose.LT_TIMING.retries,
		retry_pause_ms = 10,
	}
	start := time.tick_now()
	result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend}, timing)
	elapsed := time.tick_since(start)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	prefix := fmt.aprintf("self-hosted (%s) is unreachable: ", backend.url)
	defer delete(prefix)
	testing.expectf(t, strings.has_prefix(err.message, prefix), "error %q", err.message)
	testing.expectf(t, strings.contains(err.message, "timed out"), "error %q", err.message)
	testing.expect_value(t, fake_lt_requests(fake), 1 + prose.LT_TIMING.retries)
	testing.expectf(t, elapsed >= 3 * 2 * time.Second, "gave up after %v", elapsed)
	testing.expectf(t, elapsed < 20 * time.Second, "gave up only after %v", elapsed)
}

// The second of long.md's three chunks fails every time: one
// LT-CHUNK-FAILED error names its lines, the note says so, and the findings
// of the first and third chunks are all there.
@(test)
a_failed_chunk_is_an_error_and_the_rest_still_counts :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Fail_Second_Chunk)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	words := golden_words()
	defer prose.word_set_destroy(&words)
	_, want, value, ok := load_golden(t, #directory + "golden-lt/long.json")
	defer json.destroy_value(value)
	defer delete(want)
	if !ok {
		return
	}
	md := read_corpus("long.md")
	defer delete(md)
	timing := prose.LT_TIMING
	timing.retry_pause_ms = 10
	result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend, words = words}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	if !testing.expect_value(t, err.message, "") {
		return
	}
	// The probe, three chunks, and two retries of the second.
	testing.expect_value(t, fake_lt_requests(fake), 6)
	testing.expectf(t, strings.contains(result.note, " | chunk failed: HTTP 500"), "note %q", result.note)

	failed := make([dynamic]prose.Finding)
	defer delete(failed)
	for f in result.findings {
		if f.rule == "LT-CHUNK-FAILED" {
			append(&failed, f)
		}
	}
	if !testing.expect_value(t, len(failed), 1) {
		return
	}
	f := failed[0]
	testing.expect_value(t, f.severity, prose.Severity.Error)
	testing.expect_value(t, f.col, 1)
	testing.expect_value(t, f.excerpt, "")
	testing.expect_value(t, f.suggestion, "re-run, and if it repeats use --no-lt knowingly rather than trusting a partial pass")
	// "Lines A to B were never checked: HTTP 500. This run is incomplete, ..."
	first, last, shaped := failed_lines(f.message)
	if !testing.expectf(t, shaped, "the message is not 'Lines A to B were never checked: ...': %q", f.message) {
		return
	}
	testing.expect_value(t, first, f.line)
	testing.expectf(t, first > 1 && last > first, "lines %d to %d", first, last)
	testing.expect(t, strings.has_suffix(f.message, " were never checked: HTTP 500. This run is incomplete, so a clean result here would be misleading."), f.message)

	// Every golden finding outside the failed lines, and every finding that
	// is not LanguageTool's, is there, in order; no LanguageTool finding sits
	// strictly inside them.
	expected := make([dynamic]prose.Finding)
	defer delete(expected)
	before, after := 0, 0
	for w in want {
		is_lt := strings.has_prefix(w.rule, "LT:")
		if !is_lt || w.line < first || w.line > last {
			append(&expected, w)
			if is_lt && w.line < first {
				before += 1
			}
			if is_lt && w.line > last {
				after += 1
			}
		}
	}
	testing.expectf(t, before > 0 && after > 0, "%d findings before the failed chunk and %d after", before, after)
	i := 0
	for g in result.findings {
		if i < len(expected) && g == expected[i] {
			i += 1
		}
		if strings.has_prefix(g.rule, "LT:") {
			testing.expectf(t, g.line <= first || g.line >= last, "a finding from the failed chunk: %v", g)
		}
	}
	testing.expectf(t, i == len(expected), "only %d of %d expected findings, in order", i, len(expected))
}

// failed_lines reads A and B out of "Lines A to B were never checked: ...".
// False for any other shape, so a reworded message fails the test instead of
// slicing out of range.
@(private = "file")
failed_lines :: proc(message: string) -> (first, last: int, ok: bool) {
	rest := strings.trim_prefix(message, "Lines ")
	if len(rest) == len(message) {
		return
	}
	to := strings.index(rest, " to ")
	if to < 0 {
		return
	}
	first = strconv.parse_int(rest[:to]) or_return
	rest = rest[to + len(" to "):]
	space := strings.index_byte(rest, ' ')
	if space < 0 {
		return
	}
	last = strconv.parse_int(rest[:space]) or_return
	return first, last, true
}

// No backend sends nothing: not the probe, not a chunk.
@(test)
no_backend_sends_nothing :: proc(t: ^testing.T) {
	fake, _ := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	md := read_corpus("fixture.md")
	defer delete(md)
	result, err := prose.check_text(md, {lang = "auto", use_lt = true, hunspell_command = "/nonexistent"})
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	plain, _ := prose.check_text(md, {lang = "auto"})
	defer prose.file_result_destroy(&plain)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, fake_lt_requests(fake), 0)
	testing.expect_value(t, result.note, plain.note)
	expect_findings(t, "no backend", 0, result.findings, plain.findings)
}

// language_runs merges neighbours of one language and covers the source.
@(test)
language_runs_cover_the_source :: proc(t: ^testing.T) {
	blocks := [?]prose.Block{{3, 10, "de"}, {12, 20, "de"}, {22, 30, "en"}, {32, 40, "de"}}
	runs := prose.language_runs(blocks[:], 45)
	defer delete(runs)
	want := [?]prose.Lt_Run{{0, 22, "de"}, {22, 32, "en"}, {32, 45, "de"}}
	testing.expect_value(t, len(runs), len(want))
	for w, i in want {
		if i < len(runs) {
			testing.expect_value(t, runs[i], w)
		}
	}
	none := prose.language_runs({}, 7)
	defer delete(none)
	testing.expect_value(t, len(none), 1)
	testing.expect_value(t, none[0], prose.Lt_Run{0, 7, "en"})
}

// chunk_annotations closes a chunk before the annotation that would take it
// past the limit, and gives an oversized annotation a chunk of its own.
@(test)
chunk_annotations_split_at_the_limit :: proc(t: ^testing.T) {
	anns := [?]prose.Annotation {
		{text = "aaaa"},
		{markup = "ü`b`", is_markup = true},
		{text = "cc"},
		{text = "dddddddddddd"},
		{text = "e"},
	}
	chunks := prose.chunk_annotations(anns[:], 100, 10)
	defer delete(chunks)
	want := [?]prose.Lt_Chunk{{0, 3, 100}, {3, 4, 110}, {4, 5, 122}}
	testing.expect_value(t, len(chunks), len(want))
	for w, i in want {
		if i < len(chunks) {
			testing.expect_value(t, chunks[i], w)
		}
	}
	empty := prose.chunk_annotations({}, 0, 10)
	defer delete(empty)
	testing.expect_value(t, len(empty), 0)
}

// The tier in the probe's note comes from `software.premium`: a self-hosted
// open-source server says false and has free rules only, as does one that
// sets `premiumHint` even when it says premium.
@(test)
the_probe_names_the_tier_from_software_premium :: proc(t: ^testing.T) {
	for mode in ([]Fake_Mode{.Probe_Free, .Probe_Premium_Hint}) {
		fake, port := fake_lt_start(RECORDINGS, mode)
		defer fake_lt_stop(t, fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		backend := server_backend(port)
		defer delete(backend.url)
		result, err := prose.check_text("A short sentence.\n", {lang = "en", use_lt = true, backend = backend})
		defer prose.file_result_destroy(&result)
		defer delete(err.message)
		testing.expect_value(t, err.message, "")
		testing.expect_value(
			t,
			result.note,
			"language: en | self-hosted: ok, 1 match(es) on the probe sentence, LanguageTool 6.5, free rules only",
		)
	}
}

// An answer over the size cap cannot shrink on a second try: one request,
// no retries, and the check stops naming the backend.
@(test)
an_answer_over_the_size_cap_is_not_retried :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Too_Big_Answer)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	backend := server_backend(port)
	defer delete(backend.url)
	md := read_corpus("fixture.md")
	defer delete(md)
	timing := prose.LT_TIMING
	timing.retry_pause_ms = 10
	result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	want := fmt.aprintf("self-hosted (%s) answered but is not checking: the answer is too big", backend.url)
	defer delete(want)
	testing.expect_value(t, err.message, want)
	testing.expect_value(t, fake_lt_requests(fake), 1)
}

// A 429 is retried and the retry is invisible: the same note and findings as
// without it, one request more.
@(test)
a_rate_limited_request_is_retried :: proc(t: ^testing.T) {
	steady, steady_port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, steady)
	limited, limited_port := fake_lt_start(RECORDINGS, .Rate_Limit_First)
	defer fake_lt_stop(t, limited)
	if !testing.expect(t, steady != nil && limited != nil) {
		return
	}
	md := read_corpus("fixture.md")
	defer delete(md)
	words := golden_words()
	defer prose.word_set_destroy(&words)
	timing := prose.LT_TIMING
	timing.retry_pause_ms = 10

	a := server_backend(steady_port)
	defer delete(a.url)
	b := server_backend(limited_port)
	defer delete(b.url)
	want, werr := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = a, words = words}, timing)
	defer prose.file_result_destroy(&want)
	defer delete(werr.message)
	got, gerr := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = b, words = words}, timing)
	defer prose.file_result_destroy(&got)
	defer delete(gerr.message)
	testing.expect_value(t, werr.message, "")
	testing.expect_value(t, gerr.message, "")
	testing.expect_value(t, got.note, want.note)
	expect_findings(t, "after a 429", 0, got.findings, want.findings)
	testing.expect_value(t, fake_lt_requests(limited), fake_lt_requests(steady) + 1)
}

// The account and the key travel as form fields to the Premium backend, and
// show up in no message and no note, whatever goes wrong.
@(test)
premium_credentials_are_sent_and_never_shown :: proc(t: ^testing.T) {
	USER :: "account-name-7"
	KEY :: "S3CRET-key-8"
	for mode in ([]Fake_Mode{.Replay, .Refuse_403, .No_Matches_After_Probe, .Fail_Second_Chunk}) {
		fake, port := fake_lt_start(RECORDINGS, mode)
		defer fake_lt_stop(t, fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		backend := prose.Backend {
			kind     = .Premium,
			url      = fmt.aprintf("http://127.0.0.1:%d", port),
			username = USER,
			key      = KEY,
			label    = "premium cloud",
		}
		defer delete(backend.url)
		md := read_corpus("fixture.md")
		defer delete(md)
		timing := prose.LT_TIMING
		timing.retry_pause_ms = 10
		result, err := prose.check_text_timed(md, {lang = "auto", use_lt = true, backend = backend}, timing)
		defer prose.file_result_destroy(&result)
		defer delete(err.message)

		sent := fake_lt_requests(fake)
		testing.expectf(t, sent > 0, "%v: no request", mode)
		testing.expectf(t, fake_lt_requests_with_field(fake, "username", USER) == sent, "%v: not every request carries the account", mode)
		testing.expectf(t, fake_lt_requests_with_field(fake, "apiKey", KEY) == sent, "%v: not every request carries the key", mode)

		shown := make([dynamic]string)
		defer delete(shown)
		append(&shown, err.message, result.note)
		for f in result.findings {
			append(&shown, f.message, f.excerpt, f.suggestion, f.rule)
		}
		for text in shown {
			testing.expectf(t, !strings.contains(text, KEY) && !strings.contains(text, "apiKey"), "%v: the key shows in %q", mode, text)
			testing.expectf(t, !strings.contains(text, USER), "%v: the account shows in %q", mode, text)
		}
	}
}

// A timeout that libcurl refuses is an error, not a request without a
// timeout: nothing is sent.
@(test)
post_form_stops_when_libcurl_refuses_an_option :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", port)
	defer delete(url)
	// A negative timeout is out of range for CURLOPT_TIMEOUT.
	status, body, herr := prose.post_form(url, {{"text", "x"}}, -1)
	defer delete(body)
	defer delete(herr.message)
	testing.expect_value(t, status, 0)
	testing.expectf(t, strings.contains(herr.message, "TIMEOUT"), "error %q", herr.message)
	testing.expect_value(t, herr.retryable, false)
	testing.expect_value(t, fake_lt_requests(fake), 0)

	// Through the check, the failure is the machine's, not the server's:
	// it is not retried, and not worded as unreachable.
	backend := server_backend(port)
	defer delete(backend.url)
	timing := prose.Lt_Timing{request_s = 5, probe_s = -1, retries = 2, retry_pause_ms = 10}
	result, err := prose.check_text_timed("A short note.\n", {lang = "en", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expect(t, err.local)
	testing.expectf(t, strings.has_prefix(err.message, "libcurl on this machine refused its TIMEOUT option"), "error %q", err.message)
	testing.expect_value(t, fake_lt_requests(fake), 0)
}

// A transfer cut short after the headers is the network letting go: it is
// retried as often as the timing says, and then the check stops.
@(test)
a_connection_cut_after_the_headers_is_retried :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Cut_After_Headers)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", port)
	defer delete(url)
	status, body, herr := prose.post_form(url, {{"text", "x"}}, 5)
	defer delete(body)
	defer delete(herr.message)
	testing.expect_value(t, status, 0)
	testing.expect(t, herr.message != "")
	testing.expect_value(t, herr.retryable, true)
	testing.expect_value(t, fake_lt_requests(fake), 1)

	backend := server_backend(port)
	defer delete(backend.url)
	timing := prose.Lt_Timing{request_s = 5, probe_s = 5, retries = 2, retry_pause_ms = 10}
	result, err := prose.check_text_timed("A short note.\n", {lang = "en", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expectf(t, strings.contains(err.message, "is unreachable"), "error %q", err.message)
	testing.expect_value(t, fake_lt_requests(fake), 1 + 3)
}

// What a retry cannot cure is not retried: a reply that is no HTTP, a URL
// with a scheme that is not spoken. One request, and the failure is final.
@(test)
an_error_a_retry_cannot_cure_is_not_retried :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Garbage_Reply)
	defer fake_lt_stop(t, fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", port)
	defer delete(url)
	status, body, herr := prose.post_form(url, {{"text", "x"}}, 5)
	delete(body)
	defer delete(herr.message)
	testing.expect_value(t, status, 0)
	testing.expect(t, herr.message != "")
	testing.expect_value(t, herr.retryable, false)

	backend := server_backend(port)
	defer delete(backend.url)
	timing := prose.Lt_Timing{request_s = 5, probe_s = 5, retries = 2, retry_pause_ms = 10}
	result, err := prose.check_text_timed("A short note.\n", {lang = "en", use_lt = true, backend = backend}, timing)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expect(t, err.message != "")
	// One request from post_form, one from the check: neither was repeated.
	testing.expect_value(t, fake_lt_requests(fake), 2)

	// A scheme that is not spoken never leaves the machine and is final.
	status2, body2, herr2 := prose.post_form("ftp://127.0.0.1:1/v2/check", {{"text", "x"}}, 5)
	delete(body2)
	defer delete(herr2.message)
	testing.expect_value(t, status2, 0)
	testing.expect(t, herr2.message != "")
	testing.expect_value(t, herr2.retryable, false)
}

// The path from the process environment to libcurl, end to end: with a proxy
// variable pointing at a dead port, a run against a LanguageTool on loopback
// still reaches it, because `run_env_from_os` hands the loopback list on and
// `lt_post` gives it to libcurl. In process, the environment is the test
// runner's and may not be touched, so this runs the checker with an
// environment of its own. The checker is the one `PROSE_CHECK_BIN` names, where
// the runner has no Odin (the Intel CI job runs a cross-compiled test runner),
// else one this test builds. The premise is checked too: when the user's own
// `NO_PROXY` is set, the bypass yields and the same run dies at the dead proxy.
@(test)
a_run_reaches_loopback_past_a_proxy_variable :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		fake, port := fake_lt_start(RECORDINGS, .Replay)
		defer fake_lt_stop(t, fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		dir, derr := os.make_directory_temp("", "prose-proxy-*", context.allocator)
		if !testing.expect(t, derr == nil) {
			return
		}
		defer {
			_ = os.remove_all(dir)
			delete(dir)
		}
		exe: string
		defer delete(exe)
		if given, ok := os.lookup_env("PROSE_CHECK_BIN", context.allocator); ok && given != "" {
			exe = given
			if !testing.expectf(t, os.exists(exe), "PROSE_CHECK_BIN=%s does not exist", exe) {
				return
			}
		} else {
			delete(given)
			exe, _ = os.join_path({dir, "prose-check"}, context.allocator)
			out_flag := strings.concatenate({"-out:", exe})
			defer delete(out_flag)
			build_state, build_out, build_err, berr := os.process_exec(
				{command = {"odin", "build", #directory + "../src", out_flag, "-o:none"}},
				context.allocator,
			)
			defer delete(build_out)
			defer delete(build_err)
			if !testing.expectf(
				t,
				berr == nil && build_state.exit_code == 0,
				"build failed: %v %s (without Odin, set PROSE_CHECK_BIN to a built prose-check)",
				berr,
				build_err,
			) {
				return
			}
		}

		server := fmt.aprintf("LANGUAGETOOL_SERVER=http://127.0.0.1:%d", port)
		defer delete(server)
		xdg := strings.concatenate({"XDG_CONFIG_HOME=", dir})
		defer delete(xdg)
		file := #directory + "corpus/fixture.md"
		// Port 1 is not listening: a request sent there fails to connect.
		dead := "http_proxy=http://127.0.0.1:1"

		run :: proc(t: ^testing.T, exe, file: string, env: []string) -> (code: int, stderr: string) {
			state, out, err, perr := os.process_exec({command = {exe, file}, env = env}, context.allocator)
			delete(out)
			testing.expectf(t, perr == nil, "run failed: %v", perr)
			return state.exit_code, string(err)
		}

		code, errs := run(t, exe, file, {server, xdg, dead})
		defer delete(errs)
		testing.expectf(t, code == 0 || code == 1, "with the bypass: exit %d, stderr %q", code, errs)
		testing.expect(t, fake_lt_requests(fake) > 0)

		before := fake_lt_requests(fake)
		code2, errs2 := run(t, exe, file, {server, xdg, dead, "NO_PROXY=example.org"})
		defer delete(errs2)
		testing.expectf(t, code2 == 2, "with the user's NO_PROXY: exit %d, stderr %q", code2, errs2)
		testing.expect_value(t, fake_lt_requests(fake), before)
	}
}

// A libcurl built without proxy support refuses CURLOPT_NOPROXY, and has no
// proxy to bypass, so that refusal is not an error. Every other refusal is.
@(test)
a_refused_noproxy_does_not_stop_the_request_but_any_other_option_does :: proc(t: ^testing.T) {
	for code in ([]curl.code{.E_UNKNOWN_OPTION, .E_NOT_BUILT_IN, .E_BAD_FUNCTION_ARGUMENT}) {
		testing.expectf(t, !prose.setopt_is_fatal("NOPROXY", code), "NOPROXY %v stops the request", code)
		for name in ([]string{"TIMEOUT", "URL", "PROXY", "NOSIGNAL", "WRITEFUNCTION"}) {
			testing.expectf(t, prose.setopt_is_fatal(name, code), "%s %v does not stop the request", name, code)
		}
	}
	for name in ([]string{"NOPROXY", "TIMEOUT", "PROXY"}) {
		testing.expectf(t, !prose.setopt_is_fatal(name, .E_OK), "%s ok stops the request", name)
	}
}

// Loopback does not go through a proxy unless the user's no_proxy says so:
// with the bypass the request reaches the server, without it the proxy.
@(test)
loopback_bypasses_a_proxy :: proc(t: ^testing.T) {
	target, target_port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(t, target)
	proxy, proxy_port := fake_lt_start(RECORDINGS, .Refuse_403)
	defer fake_lt_stop(t, proxy)
	if !testing.expect(t, target != nil && proxy != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d/v2/check", target_port)
	defer delete(url)
	proxy_url := fmt.aprintf("http://127.0.0.1:%d", proxy_port)
	defer delete(proxy_url)
	fields := [][2]string{{"text", "This are a test."}, {"language", "en-US"}}

	status, body, herr := prose.post_form(url, fields, 5, {proxy = proxy_url, no_proxy = prose.loopback_no_proxy(false)})
	delete(body)
	delete(herr.message)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, fake_lt_requests(target), 1)
	testing.expect_value(t, fake_lt_requests(proxy), 0)

	// The premise: without the bypass the same request goes to the proxy.
	status, body, herr = prose.post_form(url, fields, 5, {proxy = proxy_url})
	delete(body)
	delete(herr.message)
	testing.expect_value(t, fake_lt_requests(target), 1)
	testing.expect_value(t, fake_lt_requests(proxy), 1)
}

// The user's own no_proxy wins: the bypass list is empty then, so that
// libcurl reads the variable.
@(test)
the_loopback_bypass_yields_to_the_users_no_proxy :: proc(t: ^testing.T) {
	testing.expect_value(t, prose.loopback_no_proxy(true), "")
	got := prose.loopback_no_proxy(false)
	for host in ([]string{"localhost", "127.0.0.1", "::1"}) {
		testing.expectf(t, strings.contains(got, host), "%q lacks %s", got, host)
	}
}

// The fake's accept loop dying of an error nobody asked for is reported at
// stop, and stopping does not hang. Linux only: shutdown on a listening
// socket is what makes accept fail there.
@(test)
the_fake_reports_an_accept_error_and_still_stops :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		fake, _ := fake_lt_start(RECORDINGS, .Replay)
		if !testing.expect(t, fake != nil) {
			return
		}
		testing.expect(t, net.shutdown(fake.listener, .Both) == nil)
		time.sleep(200 * time.Millisecond)
		failure := fake_lt_shutdown(fake)
		defer delete(failure)
		testing.expectf(t, strings.has_prefix(failure, "accept failed"), "failure %q", failure)
	}
}
