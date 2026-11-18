package prose

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// How one text is checked. `lang` is "de" or "en" to force the language of
// every paragraph; anything else, "auto" included, detects it per paragraph.
// `use_lt` adds the LanguageTool pass, `picky` its picky mode. `backend` is
// the LanguageTool to ask, from `choose_backend`, and `words` the accepted
// words, from `load_words`; both belong to the caller, and their zero values
// (no backend, no words) leave the checks as they were. `hunspell_command`
// is the program for the local spelling pass, which runs with `use_lt` and no
// backend, and never on Windows; "" means `$PROSE_HUNSPELL`, else `hunspell`
// on PATH. It exists so a test can name a stub without touching the process
// environment.
Check_Options :: struct {
	lang:             string,
	use_lt, picky:    bool,
	backend:          Backend,
	words:            Word_Set,
	hunspell_command: string,
}

// Why a text could not be checked. An empty `message` means it could. A
// non-empty one is allocated with the allocator given to `check_text` and
// freed by the caller with `delete`.
Check_Error :: struct {
	message: string,
	// The fault is this machine's libcurl, not the backend; see `Lt_Error`.
	local:   bool,
}

// check_text checks one text, as the reference's `check_text` does: mask it,
// split it into paragraphs with a language each, run the deterministic rules
// and, with `use_lt`, LanguageTool, then sort the findings by line, column
// and rule, keeping the order of the passes among equals.
//
// `result.file` stays empty; the caller names the file. `result.note` is
// "language: de, en" (the languages found, sorted, or "unknown"), followed by
// " | " and the LanguageTool pass's own note when it has one. Everything in
// `result` is allocated with `allocator`; free it with `file_result_destroy`.
// On an error `result` is empty.
check_text :: proc(
	source: string,
	opts: Check_Options,
	allocator := context.allocator,
) -> (
	result: File_Result,
	err: Check_Error,
) {
	return check_text_timed(source, opts, LT_TIMING, allocator)
}

// check_text_timed is `check_text` with the LanguageTool pass's timeouts
// and retries given, so a test can wait 2 s for a server that hangs. With
// `use_lt`, a backend that refuses or does not answer the probe is a
// `Check_Error` holding the pass's `Lt_Error` message; a `.None` backend
// adds nothing.
check_text_timed :: proc(
	source: string,
	opts: Check_Options,
	timing: Lt_Timing,
	allocator := context.allocator,
) -> (
	result: File_Result,
	err: Check_Error,
) {
	src := utf8.string_to_runes(source, allocator)
	defer delete(src, allocator)
	m := mask_markdown(src, allocator)
	defer masked_destroy(&m)
	blocks := language_blocks(&m, opts.lang, allocator)
	defer delete(blocks, allocator)

	findings := check_deterministic(src, &m, blocks, allocator)

	// The LanguageTool pass's note lands after " | " in the note.
	pass_note := ""
	defer delete(pass_note, allocator)
	if opts.use_lt {
		starts := line_index(src, allocator)
		defer delete(starts, allocator)
		lt, note, lt_err := run_languagetool_timed(src, &m, blocks, starts, opts.backend, opts.words, opts.picky, timing, allocator)
		if lt_err.message != "" {
			delete(lt)
			findings_destroy(findings[:], allocator)
			return {}, Check_Error{lt_err.message, lt_err.local}
		}
		append(&findings, ..lt[:])
		delete(lt)
		pass_note = note
		if opts.backend.kind == .None {
			// No LanguageTool to ask: the local English spelling pass stands
			// in, except on Windows, where it does nothing (see
			// `run_hunspell_with`). It leaves the note as it is.
			command := opts.hunspell_command if opts.hunspell_command != "" else hunspell_program()
			local := run_hunspell_with(command, HUNSPELL_TIMEOUT, src, &m, blocks, starts, opts.words, allocator)
			append(&findings, ..local[:])
			delete(local)
		}
	}

	sort_findings(findings[:])
	result.note = language_note(blocks, pass_note, allocator)
	result.findings = findings[:]
	return result, {}
}

// sort_findings orders findings by line, column and rule, as the reference's
// `findings.sort(key=lambda f: (f.line, f.col, f.rule))` does. The sort is
// stable, so findings equal in all three keep the order they were added in.
sort_findings :: proc(findings: []Finding) {
	slice.stable_sort_by(findings, proc(a, b: Finding) -> bool {
		if a.line != b.line {
			return a.line < b.line
		}
		if a.col != b.col {
			return a.col < b.col
		}
		return a.rule < b.rule
	})
}

// language_note builds the reference's note: "language: " and the sorted,
// distinct languages of the blocks joined by ", ", or "unknown" when there
// is none, then " | " and `pass_note` when that is not empty.
@(private = "file")
language_note :: proc(blocks: []Block, pass_note: string, allocator := context.allocator) -> string {
	langs := make([dynamic]string, allocator)
	defer delete(langs)
	for b in blocks {
		if b.lang != "" && !slice.contains(langs[:], b.lang) {
			append(&langs, b.lang)
		}
	}
	slice.sort(langs[:])
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "language: ")
	for l, i in langs {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, l)
	}
	if len(langs) == 0 {
		strings.write_string(&sb, "unknown")
	}
	if pass_note != "" {
		strings.write_string(&sb, " | ")
		strings.write_string(&sb, pass_note)
	}
	return strings.to_string(sb)
}

// findings_destroy frees findings whose strings were all allocated with
// `allocator`, as the checker's passes allocate them, and the slice itself.
findings_destroy :: proc(findings: []Finding, allocator := context.allocator) {
	for f in findings {
		delete(f.rule, allocator)
		delete(f.message, allocator)
		delete(f.excerpt, allocator)
		delete(f.suggestion, allocator)
	}
	delete(findings, allocator)
}

// file_result_destroy frees what `check_text` allocated: the note and the
// findings. `file` is the caller's and is not freed.
file_result_destroy :: proc(r: ^File_Result, allocator := context.allocator) {
	delete(r.note, allocator)
	findings_destroy(r.findings, allocator)
	r^ = {}
}
