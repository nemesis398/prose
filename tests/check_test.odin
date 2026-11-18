package prose_tests

import "core:testing"
import "core:time"
import "core:unicode/utf8"
import prose "../src"

// The local spelling pass as `check_text` and `run_hunspell_with` run it, on
// every system. On Windows it does nothing: `command_with_input` cannot bound
// a wrapper's own child there, so hunspell is not started at all. Elsewhere
// the stub's one miss is found. tests/hunspell_test.odin covers the pass
// itself, on the systems where it runs.

@(private = "file")
STUB :: #directory + "stub/hunspell"

@(private = "file")
TEXT :: "The colr is red.\n"

@(private = "file")
count_rule :: proc(findings: []prose.Finding, rule: string) -> (n: int) {
	for f in findings {
		if f.rule == rule {
			n += 1
		}
	}
	return
}

@(test)
check_text_runs_hunspell_except_on_windows :: proc(t: ^testing.T) {
	// LanguageTool asked for, and no backend: the local pass stands in.
	r, err := prose.check_text(TEXT, {lang = "en", use_lt = true, hunspell_command = STUB})
	defer prose.file_result_destroy(&r)
	testing.expect_value(t, err.message, "")
	when ODIN_OS == .Windows {
		testing.expect_value(t, count_rule(r.findings, "HUNSPELL"), 0)
	} else {
		testing.expect_value(t, count_rule(r.findings, "HUNSPELL"), 1)
	}
}

@(test)
run_hunspell_does_nothing_on_windows :: proc(t: ^testing.T) {
	src := utf8.string_to_runes(TEXT)
	defer delete(src)
	m := prose.mask_markdown(src)
	defer prose.masked_destroy(&m)
	blocks := prose.language_blocks(&m, "en")
	defer delete(blocks)
	starts := prose.line_index(src)
	defer delete(starts)
	found := prose.run_hunspell_with(STUB, 20 * time.Second, src, &m, blocks, starts, nil)
	defer prose.findings_destroy(found[:])
	when ODIN_OS == .Windows {
		testing.expect_value(t, len(found), 0)
	} else {
		testing.expect_value(t, len(found), 1)
	}
}
