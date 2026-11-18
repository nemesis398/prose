package prose_tests

import "core:os"
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

// The two tests above pass on Windows with or without the guard: an sh stub
// cannot start there, so it gives no findings either way. This one starts a
// `.cmd` stub that writes a marker file when it runs, so a marker proves that
// hunspell was started. It runs on Windows only and could not be run when it
// was written; the cross-compile checks that it builds. It first runs the
// stub on its own and expects the marker, so that it cannot pass merely
// because the stub never starts.
@(test)
windows_never_starts_hunspell :: proc(t: ^testing.T) {
	MARKER :: #directory + "stub/hunspell-marker.started"
	_ = os.remove(MARKER) // a leftover of an earlier run
	defer os.remove(MARKER)
	when ODIN_OS == .Windows {
		CMD :: #directory + "stub/hunspell-marker.cmd"

		// The positive control: run the stub as `command_output` would, and the
		// marker must appear. Without it, a stub that never starts at all (a
		// path or a shell that cannot run it) would pass every check below.
		_, started := prose.command_output({CMD}, 20 * time.Second, false)
		testing.expect(t, started, "the stub did not run")
		testing.expect(t, os.exists(MARKER), "the stub ran but left no marker: the test cannot see a start")
		testing.expect(t, os.remove(MARKER) == nil)

		r, err := prose.check_text(TEXT, {lang = "en", use_lt = true, hunspell_command = CMD})
		defer prose.file_result_destroy(&r)
		testing.expect_value(t, err.message, "")
		testing.expect_value(t, count_rule(r.findings, "HUNSPELL"), 0)

		src := utf8.string_to_runes(TEXT)
		defer delete(src)
		m := prose.mask_markdown(src)
		defer prose.masked_destroy(&m)
		blocks := prose.language_blocks(&m, "en")
		defer delete(blocks)
		starts := prose.line_index(src)
		defer delete(starts)
		found := prose.run_hunspell_with(CMD, 20 * time.Second, src, &m, blocks, starts, nil)
		defer prose.findings_destroy(found[:])
		testing.expect_value(t, len(found), 0)

		testing.expect(t, !os.exists(MARKER), "hunspell was started")
	}
}
