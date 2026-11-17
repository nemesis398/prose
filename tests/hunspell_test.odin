#+build !windows
package prose_tests

import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import prose "../src"

// The local spelling pass, against the stubs in tests/stub, which speak
// hunspell's `-a` pipe protocol. The real hunspell is never run here.

@(private = "file")
STUB :: #directory + "stub/hunspell"

@(private = "file")
LONG :: 20 * time.Second

// hunspell_findings masks and splits `text` and runs the pass with `command`.
// Free the result with `prose.findings_destroy`.
@(private = "file")
hunspell_findings :: proc(
	text, lang, command: string,
	words: prose.Word_Set = nil,
	timeout := LONG,
) -> []prose.Finding {
	src := utf8.string_to_runes(text)
	defer delete(src)
	m := prose.mask_markdown(src)
	defer prose.masked_destroy(&m)
	blocks := prose.language_blocks(&m, lang)
	defer delete(blocks)
	starts := prose.line_index(src)
	defer delete(starts)
	found := prose.run_hunspell_with(command, timeout, src, &m, blocks, starts, words)
	return found[:]
}

@(test)
an_english_block_gets_a_finding_in_the_references_shape :: proc(t: ^testing.T) {
	found := hunspell_findings("The colr is red.\n", "en", STUB)
	defer prose.findings_destroy(found)
	if !testing.expect_value(t, len(found), 1) {
		return
	}
	f := found[0]
	testing.expect_value(t, f.line, 1)
	testing.expect_value(t, f.col, 1)
	testing.expect_value(t, f.severity, prose.Severity.Warning)
	testing.expect_value(t, f.rule, "HUNSPELL")
	testing.expect_value(t, f.message, "Unknown word “colr” (hunspell fallback, LanguageTool was unreachable)")
	testing.expect_value(t, f.excerpt, "")
	testing.expect_value(t, f.suggestion, "")
}

@(test)
german_blocks_are_not_sent :: proc(t: ^testing.T) {
	// Forced German: nothing is English, so nothing is asked.
	forced := hunspell_findings("Das ist der colr und er wird nicht gut.\n", "de", STUB)
	defer prose.findings_destroy(forced)
	testing.expect_value(t, len(forced), 0)

	// Auto: a German paragraph between two English ones, `colr` in each.
	// Only the English ones are reported, on their own lines.
	text := "This is the colr that you will have.\n\nDas ist der colr und er wird nicht gut.\n\nThis is the colr that you will have.\n"
	mixed := hunspell_findings(text, "auto", STUB)
	defer prose.findings_destroy(mixed)
	if !testing.expect_value(t, len(mixed), 2) {
		return
	}
	testing.expect_value(t, mixed[0].line, 1)
	testing.expect_value(t, mixed[1].line, 5)
}

@(test)
a_word_in_the_accepted_words_is_not_reported :: proc(t: ^testing.T) {
	words: prose.Word_Set
	defer prose.word_set_destroy(&words)
	prose.word_set_add(&words, "Colr")
	found := hunspell_findings("The colr is red.\n", "en", STUB, words)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
}

@(test)
a_missing_hunspell_gives_no_findings :: proc(t: ^testing.T) {
	for command in ([]string{"/nonexistent", "/nonexistent/dir/hunspell", ""}) {
		found := hunspell_findings("The colr is red.\n", "en", command)
		defer prose.findings_destroy(found)
		testing.expectf(t, len(found) == 0, "command %q gave %d findings", command, len(found))
	}
}

@(test)
a_word_is_reported_once_per_line :: proc(t: ^testing.T) {
	found := hunspell_findings("colr and colr and colr\ncolr\n\nthe colr\n", "en", STUB)
	defer prose.findings_destroy(found)
	if !testing.expect_value(t, len(found), 3) {
		return
	}
	testing.expect_value(t, found[0].line, 1)
	testing.expect_value(t, found[1].line, 2)
	testing.expect_value(t, found[2].line, 4)
}

@(test)
lines_stay_aligned_after_markup_that_swallows_newlines :: proc(t: ^testing.T) {
	// The fence and the table are markup, newlines included; the finding
	// after them is still reported on its own line of the source.
	text := "Some text here.\n\n```\ncode\nmore code\n```\n\n| a | b |\n|---|---|\n| x | y |\n\nThe colr is red.\n"
	found := hunspell_findings(text, "en", STUB)
	defer prose.findings_destroy(found)
	if !testing.expect_value(t, len(found), 1) {
		return
	}
	testing.expect_value(t, found[0].line, 12)
}

@(test)
text_that_looks_like_a_command_does_not_shift_the_lines :: proc(t: ^testing.T) {
	// hunspell reads a line that starts with `%` or `!` as a command and
	// answers nothing, not even the blank line, unless it is escaped.
	text := "%colr first\n\n!colr second\n\nthe colr third\n"
	found := hunspell_findings(text, "en", STUB)
	defer prose.findings_destroy(found)
	if !testing.expect_value(t, len(found), 3) {
		return
	}
	testing.expect_value(t, found[0].line, 1)
	testing.expect_value(t, found[1].line, 3)
	testing.expect_value(t, found[2].line, 5)
}

@(test)
only_alphabetic_words_are_reported :: proc(t: ^testing.T) {
	// `#` lines (no suggestion) count; `zz'a` has an apostrophe and does not.
	found := hunspell_findings("zzab zz'a colr\n", "en", STUB)
	defer prose.findings_destroy(found)
	if !testing.expect_value(t, len(found), 2) {
		return
	}
	testing.expect(t, strings.contains(found[0].message, "“zzab”"))
	testing.expect(t, strings.contains(found[1].message, "“colr”"))
}

@(test)
non_ascii_text_goes_through :: proc(t: ^testing.T) {
	found := hunspell_findings("The café has a colr, naïve as it is.\n", "en", STUB)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 1)
}

@(test)
a_hunspell_that_hangs_is_killed_and_gives_nothing :: proc(t: ^testing.T) {
	start := time.now()
	found := hunspell_findings("The colr is red.\n", "en", #directory + "stub/hunspell-hang", nil, 300 * time.Millisecond)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
	testing.expectf(t, time.since(start) < 10 * time.Second, "took %v", time.since(start))
}

@(test)
a_hunspell_that_dies_at_once_gives_nothing_and_does_not_crash_us :: proc(t: ^testing.T) {
	// 4 MiB of input is far past a pipe buffer, so the writer is still busy
	// when the reader is gone.
	text := strings.repeat("The colr is red and the sky is blue.\n", 110_000)
	defer delete(text)
	found := hunspell_findings(text, "en", #directory + "stub/hunspell-quit")
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
}

// A wrapper that does not `exec` leaves a child that holds the pipes after
// the wrapper is killed. The run is still bounded by the timeout, with input
// far past a pipe buffer so the writer is blocked when the time is up.
@(test)
a_wrapper_whose_child_holds_the_pipes_is_still_bounded :: proc(t: ^testing.T) {
	text := strings.repeat("The colr is red and the sky is blue.\n", 110_000)
	defer delete(text)
	start := time.now()
	found := hunspell_findings(text, "en", #directory + "stub/hunspell-wrapper", nil, 300 * time.Millisecond)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
	testing.expectf(t, time.since(start) < 5 * time.Second, "took %v", time.since(start))
}

// The wrapper exits and its child lives on holding the stdin pipe: the
// checker sees the end and does not wait on the writer for the child.
@(test)
a_wrapper_that_exits_and_leaves_a_child_is_not_waited_for :: proc(t: ^testing.T) {
	text := strings.repeat("The colr is red and the sky is blue.\n", 110_000)
	defer delete(text)
	start := time.now()
	found := hunspell_findings(text, "en", #directory + "stub/hunspell-orphan", nil, 30 * time.Second)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
	testing.expectf(t, time.since(start) < 5 * time.Second, "took %v", time.since(start))
}

@(test)
a_long_text_does_not_deadlock_on_the_pipes :: proc(t: ^testing.T) {
	// Input and output both pass a pipe buffer many times over. Each line is
	// its own paragraph to the stub, which answers one finding per line, so
	// distinct lines give distinct findings.
	lines := 60_000
	text := strings.repeat("word\n", lines)
	defer delete(text)
	found := hunspell_findings(text, "en", #directory + "stub/hunspell-lines")
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), lines)
	if len(found) == lines {
		testing.expect_value(t, found[lines - 1].line, lines)
	}
}

@(test)
lines_without_a_word_and_a_non_zero_exit_are_survived :: proc(t: ^testing.T) {
	found := hunspell_findings("The colr is red.\n", "en", #directory + "stub/hunspell-noise")
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 1)
}

@(test)
an_empty_text_gives_nothing :: proc(t: ^testing.T) {
	found := hunspell_findings("", "en", STUB)
	defer prose.findings_destroy(found)
	testing.expect_value(t, len(found), 0)
}

// The wiring: with no backend and `use_lt`, `check_text` runs the pass.
@(test)
check_text_runs_hunspell_when_no_backend_and_use_lt :: proc(t: ^testing.T) {
	md := "This is the colr that you will have.\n"
	opts := prose.Check_Options{lang = "auto", use_lt = true, hunspell_command = STUB}
	result, err := prose.check_text(md, opts)
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	testing.expect_value(t, err.message, "")
	found := 0
	for f in result.findings {
		if f.rule == "HUNSPELL" {
			found += 1
		}
	}
	testing.expect_value(t, found, 1)
	testing.expect_value(t, result.note, "language: en")

	// Without use_lt the pass is off.
	opts.use_lt = false
	plain, perr := prose.check_text(md, opts)
	defer prose.file_result_destroy(&plain)
	defer delete(perr.message)
	for f in plain.findings {
		testing.expect(t, f.rule != "HUNSPELL")
	}
}

@(test)
check_text_with_a_missing_hunspell_adds_nothing :: proc(t: ^testing.T) {
	md := "This is the colr that you will have.\n"
	result, err := prose.check_text(md, {lang = "auto", use_lt = true, hunspell_command = "/nonexistent"})
	defer prose.file_result_destroy(&result)
	defer delete(err.message)
	plain, _ := prose.check_text(md, {lang = "auto"})
	defer prose.file_result_destroy(&plain)
	testing.expect_value(t, err.message, "")
	testing.expect_value(t, len(result.findings), len(plain.findings))
	testing.expect_value(t, result.note, plain.note)
}
