package prose_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import prose "../src"

// Every corpus file, checked with LanguageTool off, gives the reference's
// findings in tests/golden/NAME.json: the same note, and the same findings,
// field by field and in order. The golden `file` is the bare name, which the
// caller sets, so it is not compared here.
@(test)
deterministic_rules_match_the_golden_files :: proc(t: ^testing.T) {
	dir := strings.concatenate({#directory, "corpus"})
	defer delete(dir)
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)

	corpus, matched := 0, 0
	for e in entries {
		if !strings.has_suffix(e.name, ".md") {
			continue
		}
		corpus += 1
		stem := e.name[:len(e.name) - 3]
		if golden_matches(t, dir, e.name, stem) {
			matched += 1
		}
	}
	testing.expect(t, corpus > 0, "no corpus file found")
	testing.expectf(t, matched == corpus, "%d of %d corpus files match their golden file", matched, corpus)
}

@(private = "file")
golden_matches :: proc(t: ^testing.T, dir, name, stem: string) -> bool {
	md_path := strings.concatenate({dir, "/", name})
	defer delete(md_path)
	json_path := strings.concatenate({#directory, "golden/", stem, ".json"})
	defer delete(json_path)
	md, merr := os.read_entire_file(md_path, context.allocator)
	if !testing.expectf(t, merr == nil, "read %s: %v", md_path, merr) {
		return false
	}
	defer delete(md)
	data, jerr := os.read_entire_file(json_path, context.allocator)
	if !testing.expectf(t, jerr == nil, "read %s: %v", json_path, jerr) {
		return false
	}
	defer delete(data)
	value, perr := json.parse(data, parse_integers = true)
	if !testing.expectf(t, perr == nil, "parse %s: %v", json_path, perr) {
		return false
	}
	defer json.destroy_value(value)

	files, _ := value.(json.Array)
	if !testing.expectf(t, len(files) == 1, "%s: %d results, want 1", json_path, len(files)) {
		return false
	}
	doc, _ := files[0].(json.Object)
	note, _ := doc["note"].(json.String)
	list, _ := doc["findings"].(json.Array)
	want := make([]prose.Finding, len(list))
	defer delete(want)
	for item, i in list {
		w, _ := item.(json.Object)
		sev, ok := severity_of(w["severity"].(json.String) or_else "")
		if !testing.expectf(t, ok, "%s: finding %d has an unknown severity", stem, i) {
			return false
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

	result, cerr := prose.check_text(string(md), {lang = "auto"})
	defer prose.file_result_destroy(&result)
	if !testing.expectf(t, cerr.message == "", "%s: error %q", stem, cerr.message) {
		return false
	}
	if !testing.expectf(t, result.note == note, "%s: note %q, reference %q", stem, result.note, note) {
		return false
	}
	return expect_findings(t, stem, 0, result.findings, want)
}

@(private = "file")
severity_of :: proc(name: string) -> (prose.Severity, bool) {
	switch name {
	case "error":
		return .Error, true
	case "warning":
		return .Warning, true
	case "note":
		return .Note, true
	}
	return .Error, false
}
