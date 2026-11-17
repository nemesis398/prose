package prose

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Pass 2: LanguageTool. A port of the reference's `lt_post`, `probe`,
// `language_runs`, `chunk_annotations` and `run_languagetool`: the masked
// text goes to LanguageTool as annotations, a run of one language at a time
// in chunks of at most MAX_CHUNK code points, and its matches come back as
// findings, filtered as the reference filters them.

// A chunk holds at most this many code points: under the free tier's
// ceiling, safe on either plan.
MAX_CHUNK :: 18000

// How long a request may take, and what happens when one fails. The
// reference waits 30 s for a check and 12 s for the probe, and retries a
// rate limit, a server error or a lost connection twice, pausing 2 s and
// then 4 s (`retry_pause_ms` times the attempt).
Lt_Timing :: struct {
	request_s, probe_s: int,
	retries:            int,
	retry_pause_ms:     int,
}

LT_TIMING :: Lt_Timing {
	request_s      = 30,
	probe_s        = 12,
	retries        = 2,
	retry_pause_ms = 2000,
}

// Why the LanguageTool pass could not run: the backend refused the probe
// or did not answer it. `message` names the backend, its URL and the HTTP
// status or why it was unreachable, as the reference's `probe_failure`
// does, and never the key. Empty means no error; a non-empty one is
// allocated with the allocator given to `run_languagetool` and freed by the
// caller with `delete`.
Lt_Error :: struct {
	message: string,
}

// LanguageTool rules that argue with the house style, or that fire
// constantly on note-shaped markdown. Sent as `disabledRules`.
LT_DISABLED_RULES :: "DASH_RULE,TYPOGRAFISCHE_ANFUEHRUNGSZEICHEN,EN_QUOTES,UPPERCASE_SENTENCE_START,PUNCTUATION_PARAGRAPH_END,WHITESPACE_RULE,COMMA_PARENTHESIS_WHITESPACE,MORFOLOGIK_RULE_EN_US,GERMAN_SPELLER_RULE"

// Spelling rules whose hits go through the accepted words.
LT_SPELLING_RULES := [?]string{"MORFOLOGIK_RULE_EN_US", "MORFOLOGIK_RULE_EN_GB", "GERMAN_SPELLER_RULE", "HUNSPELL_RULE"}

// Premium's adverts for its browser plugin and its login, dropped.
LT_AD_PREFIXES := [?]string{"LT_RECOMMENDATION"}

// Premium's rephrasing rules, which call themselves grammar: demoted to
// warnings, and dropped on table rows, where they would corrupt the table.
LT_SUGGESTION_PREFIXES := [?]string{"QB_NEW_", "AI_"}

// Casing complaints go through the accepted words too.
LT_CASING_CATEGORIES := [?]string{"CASING", "TYPOS"}

@(private = "file")
LT_PROBE_TEXT :: "This are a test."

// run_languagetool runs the LanguageTool pass over the masked text with
// the reference's timeouts. See `run_languagetool_timed`.
run_languagetool :: proc(
	src: []rune,
	m: ^Masked,
	blocks: []Block,
	starts: []int,
	backend: Backend,
	words: Word_Set,
	picky: bool,
	allocator := context.allocator,
) -> (
	findings: [dynamic]Finding,
	note: string,
	err: Lt_Error,
) {
	return run_languagetool_timed(src, m, blocks, starts, backend, words, picky, LT_TIMING, allocator)
}

// run_languagetool_timed is the LanguageTool pass with the timeouts and
// retries given.
//
// A `.None` backend sends nothing and finds nothing. Neither does a text
// with no prose left after masking (no text annotation with a character
// that is not white space): that sends no probe either, unlike the
// reference. Otherwise the backend is probed first; a refusal or no answer
// is an `Lt_Error`, and nothing stands in for the backend. Then every
// chunk is checked. A chunk that fails is an `LT-CHUNK-FAILED` error
// finding naming the lines it skipped, and the other chunks still count.
//
// `note` is the reference's: the backend's label and the probe's answer,
// then " | chunk failed: WHY" per failed chunk. It is "" when nothing was
// sent. The findings are sorted by line and column. Everything is
// allocated with `allocator`: free the findings with `findings_destroy`
// (on `findings[:]`) and `note` with `delete`. On an error both are empty.
run_languagetool_timed :: proc(
	src: []rune,
	m: ^Masked,
	blocks: []Block,
	starts: []int,
	backend: Backend,
	words: Word_Set,
	picky: bool,
	timing: Lt_Timing,
	allocator := context.allocator,
) -> (
	findings: [dynamic]Finding,
	note: string,
	err: Lt_Error,
) {
	findings = make([dynamic]Finding, allocator)
	if backend.kind == .None || !has_prose(m) {
		return
	}

	ok, detail := probe(backend, timing, allocator)
	defer delete(detail, allocator)
	if !ok {
		return findings, "", Lt_Error{probe_failure(backend, detail, allocator)}
	}
	nb := strings.builder_make(allocator)
	fmt.sbprintf(&nb, "%s: %s", backend.label, detail)

	tables := table_rows(src, m.is_markup, allocator)
	defer delete(tables)
	runs := language_runs(blocks, len(src), allocator)
	defer delete(runs, allocator)

	for run in runs {
		anns := annotations_for(m, run.start, run.end, allocator)
		defer annotations_destroy(anns, allocator)
		chunks := chunk_annotations(anns, run.start, MAX_CHUNK, allocator)
		defer delete(chunks, allocator)
		for ch in chunks {
			check_chunk(&findings, &nb, src, m, starts, tables, backend, words, picky, timing, run.lang, anns[ch.lo:ch.hi], ch.start, allocator)
		}
	}

	slice.stable_sort_by(findings[:], proc(a, b: Finding) -> bool {
		if a.line != b.line {
			return a.line < b.line
		}
		return a.col < b.col
	})
	return findings, strings.to_string(nb), {}
}

// has_prose reports whether any text segment holds a character that is not
// white space, which is whether LanguageTool has anything to read.
@(private = "file")
has_prose :: proc(m: ^Masked) -> bool {
	for s in m.segments {
		if s.kind != .Text {
			continue
		}
		for r in m.src[s.orig_start:s.orig_start + s.orig_len] {
			if !is_py_space(r) {
				return true
			}
		}
	}
	return false
}

// A run of one language: `src[start:end]`, `lang` "de" or "en".
Lt_Run :: struct {
	start, end: int,
	lang:       string,
}

// language_runs merges the blocks into runs of one language that cover the
// whole source, as the reference's `language_runs` does: the first run
// starts at 0, each run ends where the next starts, and the last ends at
// `length`. Without blocks the source is one English run. Sending a mixed
// document under one language would check English as German. The caller
// frees the result with `delete`.
language_runs :: proc(blocks: []Block, length: int, allocator := context.allocator) -> []Lt_Run {
	runs := make([dynamic]Lt_Run, allocator)
	if len(blocks) == 0 {
		append(&runs, Lt_Run{0, length, "en"})
		return runs[:]
	}
	for b in blocks {
		if len(runs) > 0 && runs[len(runs) - 1].lang == b.lang {
			runs[len(runs) - 1].end = b.end
		} else {
			append(&runs, Lt_Run{b.start, b.end, b.lang})
		}
	}
	runs[0].start = 0
	for i in 0 ..< len(runs) - 1 {
		runs[i].end = runs[i + 1].start
	}
	runs[len(runs) - 1].end = length
	for &r in runs {
		if r.lang == "" {
			r.lang = "en"
		}
	}
	return runs[:]
}

// One chunk: the annotations `[lo:hi]` of a run, whose text starts at the
// source offset `start`.
Lt_Chunk :: struct {
	lo, hi, start: int,
}

// chunk_annotations splits a run's annotations into chunks, as the
// reference's `chunk_annotations` does: an annotation that would take a
// non-empty chunk past `limit` code points starts the next one, so an
// annotation longer than `limit` gets a chunk of its own. `base` is the
// source offset of the first annotation. The caller frees the result with
// `delete`.
chunk_annotations :: proc(anns: []Annotation, base: int, limit := MAX_CHUNK, allocator := context.allocator) -> []Lt_Chunk {
	out := make([dynamic]Lt_Chunk, allocator)
	lo, size, offset := 0, 0, base
	for a, i in anns {
		n := utf8.rune_count(annotation_piece(a))
		if size + n > limit && i > lo {
			append(&out, Lt_Chunk{lo, i, offset})
			offset += size
			lo, size = i, 0
		}
		size += n
	}
	if lo < len(anns) {
		append(&out, Lt_Chunk{lo, len(anns), offset})
	}
	return out[:]
}

@(private = "file")
annotation_piece :: proc(a: Annotation) -> string {
	return a.markup if a.is_markup else a.text
}

@(private = "file")
lt_code :: proc(lang: string) -> string {
	return "de-DE" if lang == "de" else "en-US"
}

// annotation_json is the reference's
// `json.dumps({"annotation": batch}, ensure_ascii=False)`.
@(private = "file")
annotation_json :: proc(anns: []Annotation, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	w := strings.to_writer(&sb)
	strings.write_string(&sb, `{"annotation": [`)
	for a, i in anns {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		if a.is_markup {
			strings.write_string(&sb, `{"markup": `)
			json_string(w, a.markup)
			if a.interpret_as != "" {
				strings.write_string(&sb, `, "interpretAs": `)
				json_string(w, a.interpret_as)
			}
		} else {
			strings.write_string(&sb, `{"text": `)
			json_string(w, a.text)
		}
		strings.write_byte(&sb, '}')
	}
	strings.write_string(&sb, "]}")
	return strings.to_string(sb)
}

// check_chunk sends one chunk and appends its findings, or the
// LT-CHUNK-FAILED finding and a note when the chunk got no answer.
@(private = "file")
check_chunk :: proc(
	findings: ^[dynamic]Finding,
	note: ^strings.Builder,
	src: []rune,
	m: ^Masked,
	starts: []int,
	tables: map[int]struct{},
	backend: Backend,
	words: Word_Set,
	picky: bool,
	timing: Lt_Timing,
	lang: string,
	batch: []Annotation,
	chunk_start: int,
	allocator := context.allocator,
) {
	chunk_sb := strings.builder_make(allocator)
	defer strings.builder_destroy(&chunk_sb)
	for a in batch {
		strings.write_string(&chunk_sb, annotation_piece(a))
	}
	chunk_runes := utf8.string_to_runes(strings.to_string(chunk_sb), allocator)
	defer delete(chunk_runes, allocator)
	prefix := utf16_prefix(chunk_runes, allocator)
	defer delete(prefix, allocator)

	data := annotation_json(batch, allocator)
	defer delete(data, allocator)
	fields := [?][2]string {
		{"data", data},
		{"language", lt_code(lang)},
		{"disabledRules", LT_DISABLED_RULES},
		{"level", "picky" if picky else "default"},
	}
	res, why := lt_post(backend, fields[:], timing.request_s, timing, allocator)
	defer json.destroy_value(res, allocator)
	defer delete(why, allocator)
	matches, is_list := jv_field(res, "matches").(json.Array)
	if why == "" && !is_list {
		// A missing list is as bad as a wrong one: an answer without matches
		// is not an answer to a check, and would read as a clean chunk.
		why = strings.clone("the answer has no matches list", allocator)
	}
	if why != "" {
		// A dropped chunk means part of the document went unchecked. As a
		// note it would let an incomplete run read as a clean one.
		first, _ := to_line_col(starts, chunk_start)
		last, _ := to_line_col(starts, min(len(src) - 1, chunk_start + len(chunk_runes)))
		fmt.sbprintf(note, " | chunk failed: %s", why)
		append(findings, Finding {
			line     = first,
			col      = 1,
			severity = .Error,
			rule     = strings.clone("LT-CHUNK-FAILED", allocator),
			message  = fmt.aprintf(
				"Lines %d to %d were never checked: %s. This run is incomplete, so a clean result here would be misleading.",
				first, last, cut_runes(why, 80), allocator = allocator,
			),
			excerpt    = strings.clone("", allocator),
			suggestion = strings.clone("re-run, and if it repeats use --no-lt knowingly rather than trusting a partial pass", allocator),
		})
		return
	}

	for item in matches {
		if f, keep := match_finding(item, src, m, starts, tables, words, prefix, chunk_start, allocator); keep {
			append(findings, f)
		}
	}
}

// match_finding turns one LanguageTool match into a finding, or drops it:
// an advert, a match on suppressed text, an accepted word, a suggestion on
// a table row, or a match whose text is nowhere near where it should be.
@(private = "file")
match_finding :: proc(
	item: json.Value,
	src: []rune,
	m: ^Masked,
	starts: []int,
	tables: map[int]struct{},
	words: Word_Set,
	prefix: []int,
	chunk_start: int,
	allocator := context.allocator,
) -> (
	f: Finding,
	keep: bool,
) {
	orig := chunk_start + utf16_to_codepoint(prefix, jv_int(jv_field(item, "offset"), 0))
	length := jv_int(jv_field(item, "length"), 1)
	rule := jv_field(item, "rule")
	rule_id := jv_str(jv_field(rule, "id"), "LT")
	category := jv_str(jv_field(jv_field(rule, "category"), "id"), "")
	issue := jv_str(jv_field(rule, "issueType"), "")
	ctx := jv_field(item, "context")
	ctx_runes := utf8.string_to_runes(jv_str(jv_field(ctx, "text"), ""), allocator)
	defer delete(ctx_runes, allocator)
	ctx_lo := jv_int(jv_field(ctx, "offset"), 0)
	ctx_hi := ctx_lo + jv_int(jv_field(ctx, "length"), 0)
	flagged := ctx_runes[clamp(ctx_lo, 0, len(ctx_runes)):max(clamp(ctx_hi, 0, len(ctx_runes)), clamp(ctx_lo, 0, len(ctx_runes)))]
	is_suggestion := has_any_prefix(rule_id, LT_SUGGESTION_PREFIXES[:])

	if has_any_prefix(rule_id, LT_AD_PREFIXES[:]) {
		return
	}
	if suppressed(m, orig, length) {
		return
	}
	if issue == "misspelling" || issue == "typographical" || slice.contains(LT_SPELLING_RULES[:], rule_id) || slice.contains(LT_CASING_CATEGORIES[:], category) {
		word := strip_word(flagged)
		word_str := utf8.runes_to_string(word, allocator)
		defer delete(word_str, allocator)
		if word_set_has(words, word_str) {
			return
		}
	}
	if is_suggestion {
		if line, _ := to_line_col(starts, orig); line in tables {
			return
		}
	}
	// A cheap check of the offset arithmetic: if the flagged text is not
	// where the offset says, look for it nearby, and drop the match rather
	// than print a confident wrong line.
	if len(flagged) > 0 && !runes_at(src, orig, flagged) {
		near := find_runes(src, flagged, max(0, orig - 200), orig + 200)
		if near < 0 {
			return
		}
		orig = near
	}

	line, col := to_line_col(starts, orig)
	sev := Severity.Warning
	if !is_suggestion && (issue == "grammar" || issue == "misspelling" || issue == "typographical") {
		sev = .Error
	}
	repl := strings.builder_make(allocator)
	if repls, ok := jv_field(item, "replacements").(json.Array); ok {
		for r, i in repls[:min(3, len(repls))] {
			if i > 0 {
				strings.write_string(&repl, ", ")
			}
			strings.write_string(&repl, jv_str(jv_field(r, "value"), ""))
		}
	}
	return Finding {
		line       = line,
		col        = col,
		severity   = sev,
		rule       = strings.concatenate({"LT:", rule_id}, allocator),
		message    = strings.clone(strings.trim_right(jv_str(jv_field(item, "message"), ""), "."), allocator),
		excerpt    = excerpt_at(src, orig, max(length, 1), allocator = allocator),
		suggestion = strings.to_string(repl),
	}, true
}

@(private = "file")
has_any_prefix :: proc(s: string, prefixes: []string) -> bool {
	for p in prefixes {
		if strings.has_prefix(s, p) {
			return true
		}
	}
	return false
}

// strip_word is the reference's
// `flagged.strip().strip(".,;:()[]„“”\"'")`.
@(private = "file")
strip_word :: proc(word: []rune) -> []rune {
	w := word
	for len(w) > 0 && is_py_space(w[0]) {
		w = w[1:]
	}
	for len(w) > 0 && is_py_space(w[len(w) - 1]) {
		w = w[:len(w) - 1]
	}
	is_punct :: proc(r: rune) -> bool {
		switch r {
		case '.', ',', ';', ':', '(', ')', '[', ']', '„', '“', '”', '"', '\'':
			return true
		}
		return false
	}
	for len(w) > 0 && is_punct(w[0]) {
		w = w[1:]
	}
	for len(w) > 0 && is_punct(w[len(w) - 1]) {
		w = w[:len(w) - 1]
	}
	return w
}

// runes_at reports whether `src[at:]` starts with `want`, as the
// reference's `source[at:at + len(want)] == want`.
@(private = "file")
runes_at :: proc(src: []rune, at: int, want: []rune) -> bool {
	if at < 0 || at + len(want) > len(src) {
		return false
	}
	return slice.equal(src[at:at + len(want)], want)
}

// find_runes is Python's `src.find(want, lo, hi)`: the first offset in
// `[lo, hi - len(want)]` where `want` starts, or -1.
@(private = "file")
find_runes :: proc(src: []rune, want: []rune, lo, hi: int) -> int {
	end := min(hi, len(src))
	for i := lo; i + len(want) <= end; i += 1 {
		if slice.equal(src[i:i + len(want)], want) {
			return i
		}
	}
	return -1
}

// cut_runes is `s[:n]` in code points.
@(private = "file")
cut_runes :: proc(s: string, n: int) -> string {
	count := 0
	for _, i in s {
		if count == n {
			return s[:i]
		}
		count += 1
	}
	return s
}

// ---------------------------------------------------------------------------
// Talking to the backend
// ---------------------------------------------------------------------------

// lt_post POSTs `fields` to the backend's /v2/check and parses the answer,
// as the reference's `lt_post` does: with the account and the key added for
// Premium, and a rate limit (429), a server error (500, 502, 503, 504), a
// timeout or a lost connection retried `timing.retries` times, pausing
// longer each time. A retried 429 is invisible; an unretried one would
// silently remove findings.
//
// `why` is "" on success, else what went wrong: `HTTP 403` for a status
// that is not 2xx, the transport's message, or that the answer is not
// JSON. `value` and `why` are allocated with `allocator`; free them with
// `json.destroy_value` and `delete`.
@(private = "file")
lt_post :: proc(
	backend: Backend,
	fields: [][2]string,
	timeout_s: int,
	timing: Lt_Timing,
	allocator := context.allocator,
) -> (
	value: json.Value,
	why: string,
) {
	all := make([dynamic][2]string, allocator)
	defer delete(all)
	append(&all, ..fields)
	if backend.username != "" && backend.key != "" {
		append(&all, [2]string{"username", backend.username}, [2]string{"apiKey", backend.key})
	}
	url := strings.concatenate({strings.trim_right(backend.url, "/"), "/v2/check"}, allocator)
	defer delete(url, allocator)

	for attempt := 0; ; attempt += 1 {
		status, body, err := post_form(url, all[:], timeout_s, allocator)
		defer delete(body, allocator)
		retry := false
		if err.message != "" {
			why = err.message
			retry = true
		} else if status < 200 || status > 299 {
			why = fmt.aprintf("HTTP %d", status, allocator = allocator)
			switch status {
			case 429, 500, 502, 503, 504:
				retry = true
			}
		} else {
			v, perr := json.parse_string(body, .JSON, true, allocator)
			if perr != .None {
				json.destroy_value(v, allocator)
				return nil, strings.clone("the answer is not JSON", allocator)
			}
			if _, is_obj := v.(json.Object); !is_obj {
				json.destroy_value(v, allocator)
				return nil, strings.clone("the answer is not a JSON object", allocator)
			}
			return v, ""
		}
		if !retry || attempt >= timing.retries {
			return nil, why
		}
		delete(why, allocator)
		why = ""
		time.sleep(time.Duration(timing.retry_pause_ms * (attempt + 1)) * time.Millisecond)
	}
}

// probe sends the reference's probe sentence. On success `detail` is the
// reference's "ok, N match(es) on the probe sentence, LanguageTool
// VERSION, TIER", where the tier is "premium rules active" unless the
// answer carries a `premiumHint`: `software.premium` only says what the
// build can do. On failure `detail` says why. Allocated with `allocator`.
// `--selftest` calls it too.
@(private)
probe :: proc(backend: Backend, timing: Lt_Timing, allocator := context.allocator) -> (ok: bool, detail: string) {
	fields := [?][2]string{{"text", LT_PROBE_TEXT}, {"language", "en-US"}}
	res, why := lt_post(backend, fields[:], timing.probe_s, timing, allocator)
	defer json.destroy_value(res, allocator)
	if why != "" {
		return false, why
	}
	list, is_list := jv_field(res, "matches").(json.Array)
	if !is_list {
		return false, strings.clone("the answer has no matches list", allocator)
	}
	n := len(list)
	if n == 0 {
		// LanguageTool always flags the probe sentence, so an empty list means
		// the server is not checking.
		return false, strings.clone("the answer has no matches on the probe sentence, so the server is not checking", allocator)
	}
	software := jv_field(res, "software")
	tier := "free rules only" if jv_truthy(jv_field(software, "premiumHint")) else "premium rules active"
	version := jv_str(jv_field(software, "version"), "?")
	return true, fmt.aprintf("ok, %d match(es) on the probe sentence, LanguageTool %s, %s", n, version, tier, allocator = allocator)
}

// probe_failure is the reference's one line for a backend that did not
// answer the probe: its label, its URL, and the HTTP status or why not.
@(private = "file")
probe_failure :: proc(backend: Backend, detail: string, allocator := context.allocator) -> string {
	fields := strings.fields(detail, allocator)
	defer delete(fields, allocator)
	first := strings.join(fields, " ", allocator)
	defer delete(first, allocator)
	if strings.has_prefix(first, "HTTP ") {
		return fmt.aprintf("%s (%s) answered %s", backend.label, backend.url, first, allocator = allocator)
	}
	return fmt.aprintf("%s (%s) is unreachable: %s", backend.label, backend.url, cut_runes(first, 120), allocator = allocator)
}

// ---------------------------------------------------------------------------
// Reading the answer the way the reference's `dict.get` does
// ---------------------------------------------------------------------------

@(private = "file")
jv_field :: proc(v: json.Value, key: string) -> json.Value {
	if o, ok := v.(json.Object); ok {
		return o[key]
	}
	return nil
}

@(private = "file")
jv_int :: proc(v: json.Value, default: int) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	}
	return default
}

@(private = "file")
jv_str :: proc(v: json.Value, default: string) -> string {
	if s, ok := v.(json.String); ok {
		return s
	}
	return default
}

// jv_truthy is Python's truth value of a JSON value: false for null,
// false, 0, "", [] and {}, and for a missing value.
@(private = "file")
jv_truthy :: proc(v: json.Value) -> bool {
	switch x in v {
	case json.Null:
		return false
	case json.Boolean:
		return x
	case json.Integer:
		return x != 0
	case json.Float:
		return x != 0
	case json.String:
		return x != ""
	case json.Array:
		return len(x) > 0
	case json.Object:
		return len(x) > 0
	}
	return false
}
