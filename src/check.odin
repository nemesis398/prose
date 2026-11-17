package prose

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// How one text is checked. `lang` is "de" or "en" to force the language of
// every paragraph; anything else, "auto" included, detects it per paragraph.
// `use_lt` adds the LanguageTool pass, `picky` its picky mode. `backend` is
// the LanguageTool to ask, from `choose_backend`, and `words` the accepted
// words, from `load_words`; both belong to the caller, and their zero values
// (no backend, no words) leave the checks as they were.
Check_Options :: struct {
	lang:          string,
	use_lt, picky: bool,
	backend:       Backend,
	words:         Word_Set,
}

// Why a text could not be checked. An empty `message` means it could. A
// non-empty one is allocated with the allocator given to `check_text` and
// freed by the caller with `delete`.
Check_Error :: struct {
	message: string,
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
	src := utf8.string_to_runes(source, allocator)
	defer delete(src, allocator)
	m := mask_markdown(src, allocator)
	defer masked_destroy(&m)
	blocks := language_blocks(&m, opts.lang, allocator)
	defer delete(blocks, allocator)

	findings := check_deterministic(src, &m, blocks, allocator)

	// The seam for the LanguageTool pass (Task 8): it appends its findings to
	// `findings` and sets `pass_note`, which lands after " | " in the note.
	pass_note := ""
	if opts.use_lt {
		findings_destroy(findings[:], allocator)
		return {}, Check_Error{strings.clone("the LanguageTool pass is not built yet", allocator)}
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
