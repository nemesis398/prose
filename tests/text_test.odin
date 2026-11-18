package prose_tests

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import prose "../src"

@(private = "file")
runes :: proc(s: string) -> []rune {
	return utf8.string_to_runes(s)
}

@(test)
to_line_col_counts_code_points :: proc(t: ^testing.T) {
	src := runes("a\nbc\n")
	defer delete(src)
	starts := prose.line_index(src)
	defer delete(starts)
	testing.expect_value(t, len(starts), 3)
	line, col := prose.to_line_col(starts, 3)
	testing.expect_value(t, line, 2)
	testing.expect_value(t, col, 2)
	line, col = prose.to_line_col(starts, 0)
	testing.expect_value(t, line, 1)
	testing.expect_value(t, col, 1)
	// The "\n" itself belongs to the line it ends; the offset after the last
	// "\n" opens an empty last line.
	line, col = prose.to_line_col(starts, 1)
	testing.expect_value(t, line, 1)
	testing.expect_value(t, col, 2)
	line, col = prose.to_line_col(starts, 5)
	testing.expect_value(t, line, 3)
	testing.expect_value(t, col, 1)
}

@(test)
line_index_of_empty_and_unterminated_text :: proc(t: ^testing.T) {
	empty := prose.line_index(nil)
	defer delete(empty)
	testing.expect_value(t, len(empty), 1)
	line, col := prose.to_line_col(empty, 0)
	testing.expect_value(t, line, 1)
	testing.expect_value(t, col, 1)

	// An astral character is one column, not two.
	src := runes("😀x")
	defer delete(src)
	starts := prose.line_index(src)
	defer delete(starts)
	line, col = prose.to_line_col(starts, 1)
	testing.expect_value(t, line, 1)
	testing.expect_value(t, col, 2)
}

@(test)
excerpt_cuts_at_34_code_points_with_ellipsis :: proc(t: ^testing.T) {
	long := strings.repeat("x", 100)
	defer delete(long)
	src := runes(long)
	defer delete(src)
	got := prose.excerpt_at(src, 50)
	defer delete(got)
	// 34 before, the character, 34 after: 69 x, an ellipsis each side.
	xs := strings.repeat("x", 69)
	defer delete(xs)
	want := strings.concatenate({"…", xs, "…"})
	defer delete(want)
	testing.expect_value(t, got, want)
}

@(test)
excerpt_at_the_edges_has_no_ellipsis :: proc(t: ^testing.T) {
	src := runes("  hello world\nnext line\n")
	defer delete(src)
	got := prose.excerpt_at(src, 5)
	defer delete(got)
	testing.expect_value(t, got, "hello world")

	// The second line, from its last character: stops at the line end.
	got2 := prose.excerpt_at(src, 22)
	defer delete(got2)
	testing.expect_value(t, got2, "next line")
}

@(test)
excerpt_never_crosses_a_line_and_handles_empty_input :: proc(t: ^testing.T) {
	src := runes("ab\ncd")
	defer delete(src)
	got := prose.excerpt_at(src, 3, 2)
	defer delete(got)
	testing.expect_value(t, got, "cd")

	got2 := prose.excerpt_at(nil, 0)
	defer delete(got2)
	testing.expect_value(t, got2, "")

	// An offset past the end is clamped, not a crash.
	got3 := prose.excerpt_at(src, 999)
	defer delete(got3)
	testing.expect_value(t, got3, "cd")

	// Python's strip() also removes a no-break space and an ideographic space.
	sp := runes("  hi　")
	defer delete(sp)
	got4 := prose.excerpt_at(sp, 2)
	defer delete(got4)
	testing.expect_value(t, got4, "hi")
}

// A failing allocator is a result, not a crash: the excerpt is "" and nothing
// leaks. `fail_from` is the number of allocations that succeed first.
@(private = "file")
Flaky :: struct {
	inner:     mem.Allocator,
	fail_from: int,
	count:     int,
}

@(private = "file")
flaky_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	f := (^Flaky)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		f.count += 1
		if f.count > f.fail_from {
			return nil, .Out_Of_Memory
		}
	}
	return f.inner.procedure(f.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
excerpt_survives_a_failing_allocator :: proc(t: ^testing.T) {
	long := strings.repeat("x", 100)
	defer delete(long)
	src := runes(long)
	defer delete(src)
	// 0: the text itself cannot be allocated. 1: the ellipses cannot be added.
	for fail_from in 0 ..= 1 {
		f := Flaky{inner = context.allocator, fail_from = fail_from}
		got := prose.excerpt_at(src, 50, allocator = mem.Allocator{flaky_proc, &f})
		testing.expectf(t, got == "", "fail_from %d: got %q, want an empty excerpt", fail_from, got)
		delete(got)
	}
	// And with room enough it still works through the same allocator.
	f := Flaky{inner = context.allocator, fail_from = 2}
	got := prose.excerpt_at(src, 50, allocator = mem.Allocator{flaky_proc, &f})
	defer delete(got)
	testing.expect_value(t, len(got), 69 + 6)
}

@(test)
excerpt_counts_code_points_not_bytes :: proc(t: ^testing.T) {
	text := strings.repeat("ä", 40)
	defer delete(text)
	src := runes(text)
	defer delete(src)
	got := prose.excerpt_at(src, 40 - 1)
	defer delete(got)
	// Offset 39 is the last character: 34 before it, none after.
	as := strings.repeat("ä", 35)
	defer delete(as)
	want := strings.concatenate({"…", as})
	defer delete(want)
	testing.expect_value(t, got, want)
}

@(test)
table_rows_numbers_lines_from_one :: proc(t: ^testing.T) {
	src := runes("text\n| a | b |\n|---|---|\nx | y | z\nx | y\n  | lead |\n")
	defer delete(src)
	rows := prose.table_rows(src, nil)
	defer delete(rows)
	testing.expect_value(t, len(rows), 3)
	_, has2 := rows[2]
	_, has3 := rows[3]
	_, has6 := rows[6]
	_, has1 := rows[1]
	_, has4 := rows[4] // two bars, not leading: not a row
	_, has5 := rows[5]
	testing.expect(t, has2 && has3 && has6, "lines 2, 3 and 6 are rows")
	testing.expect(t, !has1 && !has4 && !has5, "lines 1, 4 and 5 are not")

	none := prose.table_rows(nil, nil)
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}

@(test)
utf16_offsets_count_surrogate_pairs :: proc(t: ^testing.T) {
	src := runes("😀a")
	defer delete(src)
	prefix := prose.utf16_prefix(src)
	defer delete(prefix)
	testing.expect_value(t, len(prefix), 3)
	testing.expect_value(t, prefix[0], 0)
	testing.expect_value(t, prefix[1], 2)
	testing.expect_value(t, prefix[2], 3)
	testing.expect_value(t, prose.utf16_to_codepoint(prefix, 2), 1)
	testing.expect_value(t, prose.utf16_to_codepoint(prefix, 0), 0)
	// Inside the pair: the next code point, as bisect_left does.
	testing.expect_value(t, prose.utf16_to_codepoint(prefix, 1), 1)
	// Past the end: capped.
	testing.expect_value(t, prose.utf16_to_codepoint(prefix, 99), 2)
	testing.expect_value(t, prose.utf16_to_codepoint(prefix, -5), 0)

	empty := prose.utf16_prefix(nil)
	defer delete(empty)
	testing.expect_value(t, len(empty), 1)
	testing.expect_value(t, prose.utf16_to_codepoint(empty, 7), 0)
}

@(test)
emoji_clusters_join_families_and_flags :: proc(t: ^testing.T) {
	src := runes("👨‍👩‍👧 x 🇩🇪")
	defer delete(src)
	got := prose.emoji_clusters(src)
	defer prose.emoji_destroy(got)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0].offset, 0)
		testing.expect_value(t, got[0].cluster, "👨‍👩‍👧")
		// Five code points of family, " x " is three more.
		testing.expect_value(t, got[1].offset, 8)
		testing.expect_value(t, got[1].cluster, "🇩🇪")
	}
}

@(test)
emoji_clusters_keep_the_references_quirks :: proc(t: ^testing.T) {
	// (c) and the trade mark are emoji, a variation selector joins, a joiner
	// before a non-emoji is skipped, a trailing joiner stays in the cluster.
	src := runes("a© ™️ ❤️‍🔥 ‍😀 x😀‍ y")
	defer delete(src)
	got := prose.emoji_clusters(src)
	defer prose.emoji_destroy(got)
	testing.expect_value(t, len(got), 5)
	if len(got) == 5 {
		testing.expect_value(t, got[0].offset, 1)
		testing.expect_value(t, got[1].offset, 3)
		testing.expect_value(t, got[1].cluster, "™️")
		testing.expect_value(t, got[2].offset, 6)
		testing.expect_value(t, got[2].cluster, "❤️‍🔥")
		testing.expect_value(t, got[3].offset, 12)
		testing.expect_value(t, got[4].offset, 15)
		testing.expect_value(t, got[4].cluster, "😀‍")
	}
}

// One emoji, as the reader sees it, is one cluster: a skin-tone modifier
// (U+1F3FB..U+1F3FF) belongs to the emoji before it, a joined sequence with
// toned members is one, and so is a keycap, which is a digit, "#" or "*", an
// optional U+FE0F and U+20E3. The reference does not do this; its findings
// differ only for text with such emoji, which no golden file holds.
@(test)
emoji_clusters_hold_skin_tones_keycaps_and_toned_joins_as_one :: proc(t: ^testing.T) {
	src := runes("a 👍🏽 b")
	defer delete(src)
	got := prose.emoji_clusters(src)
	defer prose.emoji_destroy(got)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {
		testing.expect_value(t, got[0].offset, 2)
		testing.expect_value(t, got[0].cluster, "👍🏽")
	}

	// Keycaps: digit, "#" or "*", U+FE0F, U+20E3; the selector may be absent.
	caps := runes("1\uFE0F\u20E3 #\uFE0F\u20E3 *\uFE0F\u20E3 9\u20E3")
	defer delete(caps)
	keys := prose.emoji_clusters(caps)
	defer prose.emoji_destroy(keys)
	testing.expect_value(t, len(keys), 4)
	if len(keys) == 4 {
		testing.expect_value(t, keys[0].offset, 0)
		testing.expect_value(t, keys[0].cluster, "1\uFE0F\u20E3")
		testing.expect_value(t, keys[1].offset, 4)
		testing.expect_value(t, keys[2].offset, 8)
		testing.expect_value(t, keys[2].cluster, "*\uFE0F\u20E3")
		testing.expect_value(t, keys[3].offset, 12)
		testing.expect_value(t, keys[3].cluster, "9\u20E3")
	}

	// A digit with a variation selector but no keycap mark is no emoji, and
	// neither is a bare digit or the mark alone after text.
	plain := runes("1\uFE0F 12 #1 *")
	defer delete(plain)
	none := prose.emoji_clusters(plain)
	defer prose.emoji_destroy(none)
	testing.expect_value(t, len(none), 0)

	// A woman, a skin tone, a joiner and a laptop: one emoji of four code points.
	tone := runes("👩🏽\u200D💻 x")
	defer delete(tone)
	joined := prose.emoji_clusters(tone)
	defer prose.emoji_destroy(joined)
	testing.expect_value(t, len(joined), 1)
	if len(joined) == 1 {
		testing.expect_value(t, joined[0].offset, 0)
		testing.expect_value(t, joined[0].cluster, "👩🏽\u200D💻")
	}

	// Both members toned: still one.
	pair := runes("🧑🏽\u200D🤝\u200D🧑🏿!")
	defer delete(pair)
	handshake := prose.emoji_clusters(pair)
	defer prose.emoji_destroy(handshake)
	testing.expect_value(t, len(handshake), 1)
	if len(handshake) == 1 {
		testing.expect_value(t, handshake[0].offset, 0)
		testing.expect_value(t, handshake[0].cluster, "🧑🏽\u200D🤝\u200D🧑🏿")
	}

	// Two toned emoji side by side are two; a modifier after a modifier, or
	// after a flag, starts an emoji of its own; one with no base is one.
	side := runes("👍🏽👍🏿")
	defer delete(side)
	two := prose.emoji_clusters(side)
	defer prose.emoji_destroy(two)
	testing.expect_value(t, len(two), 2)
	if len(two) == 2 {
		testing.expect_value(t, two[1].offset, 2)
	}
	stray := runes("👍🏽🏽 a🏽 \U0001F1E9\U0001F1EA🏽")
	defer delete(stray)
	odd := prose.emoji_clusters(stray)
	defer prose.emoji_destroy(odd)
	testing.expect_value(t, len(odd), 5)
}

// A flag is a pair of regional indicators, one emoji, with or without a
// variation selector; a third indicator starts the next.
@(test)
emoji_clusters_hold_a_flag_pair_as_one :: proc(t: ^testing.T) {
	src := runes("\U0001F1E9\U0001F1EA x \U0001F1FA\U0001F1F8\uFE0F \U0001F1EB\U0001F1F7\U0001F1EC\U0001F1E7")
	defer delete(src)
	got := prose.emoji_clusters(src)
	defer prose.emoji_destroy(got)
	testing.expect_value(t, len(got), 4)
	if len(got) == 4 {
		testing.expect_value(t, got[0].offset, 0)
		testing.expect_value(t, got[1].offset, 5)
		testing.expect_value(t, got[1].cluster, "\U0001F1FA\U0001F1F8\uFE0F")
		testing.expect_value(t, got[2].offset, 9)
		testing.expect_value(t, got[2].cluster, "\U0001F1EB\U0001F1F7")
		testing.expect_value(t, got[3].offset, 11)
	}
}

@(test)
arrows_are_not_emoji :: proc(t: ^testing.T) {
	src := runes("a → b ← c ↔ d ⇒ e")
	defer delete(src)
	got := prose.emoji_clusters(src)
	defer prose.emoji_destroy(got)
	testing.expect_value(t, len(got), 0)
	testing.expect(t, !prose.is_emoji_rune('→'), "arrow")
	testing.expect(t, !prose.is_emoji_rune('a'), "letter")
	testing.expect(t, prose.is_emoji_rune('😀'), "grinning face")
	testing.expect(t, prose.is_emoji_rune('©'), "copyright")
	testing.expect(t, prose.is_emoji_rune(0x1F000), "range start")
	testing.expect(t, prose.is_emoji_rune(0x1FAFF), "range end")
	testing.expect(t, !prose.is_emoji_rune(0x1FB00), "past the range")
	// A lone regional indicator is one emoji; three make a flag and a stray.
	flags := runes("\U0001F1E9\U0001F1EA\U0001F1E9")
	defer delete(flags)
	c := prose.emoji_clusters(flags)
	defer prose.emoji_destroy(c)
	testing.expect_value(t, len(c), 2)
}

@(test)
write_json_matches_the_reference_for_one_finding :: proc(t: ^testing.T) {
	// The first finding of tests/golden/de-note.json, as the reference printed it.
	results := []prose.File_Result {
		{
			file = "de-note.md",
			note = "language: de",
			findings = {
				{
					line = 6,
					col = 8,
					severity = .Error,
					rule = "DE-UNIT-SPACE",
					message = "German typography puts a space between number and unit: 0 °C.",
					excerpt = "rund 250°C, damit die Brötchen knusprig werd…",
					suggestion = "0 °C",
				},
			},
		},
	}
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	prose.write_json(strings.to_writer(&sb), results)
	want := `[
  {
    "file": "de-note.md",
    "note": "language: de",
    "findings": [
      {
        "line": 6,
        "col": 8,
        "severity": "error",
        "rule": "DE-UNIT-SPACE",
        "message": "German typography puts a space between number and unit: 0 °C.",
        "excerpt": "rund 250°C, damit die Brötchen knusprig werd…",
        "suggestion": "0 °C"
      }
    ]
  }
]
`
	testing.expect_value(t, strings.to_string(sb), want)
}

@(test)
write_json_empty_lists :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	prose.write_json(strings.to_writer(&sb), nil)
	testing.expect_value(t, strings.to_string(sb), "[]\n")

	strings.builder_reset(&sb)
	prose.write_json(strings.to_writer(&sb), []prose.File_Result{{file = "a.md", note = ""}})
	testing.expect_value(
		t,
		strings.to_string(sb),
		"[\n  {\n    \"file\": \"a.md\",\n    \"note\": \"\",\n    \"findings\": []\n  }\n]\n",
	)
}

@(test)
write_json_escapes_as_python_does :: proc(t: ^testing.T) {
	// json.dumps("q\"b\\n\nt\tr\rb\bf\fo\x01x\x1fd\x7fü€😀 ", ensure_ascii=False)
	results := []prose.File_Result {
		{file = "q\"b\\n\nt\tr\rb\bf\fo\x01x\x1fd\x7fü€😀 ", note = "", findings = {}},
	}
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	prose.write_json(strings.to_writer(&sb), results)
	want := "[\n  {\n    \"file\": \"q\\\"b\\\\n\\nt\\tr\\rb\\bf\\fo\\u0001x\\u001fd\x7fü€😀 \",\n    \"note\": \"\",\n    \"findings\": []\n  }\n]\n"
	testing.expect_value(t, strings.to_string(sb), want)
}

@(test)
write_json_several_results_and_findings :: proc(t: ^testing.T) {
	results := []prose.File_Result {
		{file = "a.md", note = "n", findings = {{line = 1, col = 2, severity = .Warning, rule = "R"}, {line = 10, col = 200, severity = .Note, rule = "S"}}},
		{file = "b.md", note = "m"},
	}
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	prose.write_json(strings.to_writer(&sb), results)
	want := `[
  {
    "file": "a.md",
    "note": "n",
    "findings": [
      {
        "line": 1,
        "col": 2,
        "severity": "warning",
        "rule": "R",
        "message": "",
        "excerpt": "",
        "suggestion": ""
      },
      {
        "line": 10,
        "col": 200,
        "severity": "note",
        "rule": "S",
        "message": "",
        "excerpt": "",
        "suggestion": ""
      }
    ]
  },
  {
    "file": "b.md",
    "note": "m",
    "findings": []
  }
]
`
	testing.expect_value(t, strings.to_string(sb), want)
}

// The goldens are what the reference printed, so reading one, parsing it,
// writing it back and getting the same bytes proves the writer.
// corpus_count is the number of documents in tests/corpus. The oracle tests
// check every one of them against its reference file and assert that count,
// so a document that is skipped, or an oracle file that is missing, fails.
corpus_count :: proc(t: ^testing.T) -> int {
	dir := strings.concatenate({#directory, "corpus"})
	defer delete(dir)
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	count := 0
	for e in entries {
		if strings.has_suffix(e.name, ".md") {
			count += 1
		}
	}
	return count
}

@(test)
write_json_round_trips_every_golden_file :: proc(t: ^testing.T) {
	dir := strings.concatenate({#directory, "golden"})
	defer delete(dir)
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	checked := 0
	for e in entries {
		if !strings.has_suffix(e.name, ".json") {
			continue
		}
		path := strings.concatenate({dir, "/", e.name})
		defer delete(path)
		data, rerr := os.read_entire_file(path, context.allocator)
		if !testing.expectf(t, rerr == nil, "read %s: %v", path, rerr) {
			continue
		}
		defer delete(data)

		value, perr := json.parse(data, parse_integers = true)
		if !testing.expectf(t, perr == nil, "parse %s: %v", e.name, perr) {
			continue
		}
		defer json.destroy_value(value)
		results, ok := results_from_json(value)
		defer destroy_results(results)
		if !testing.expectf(t, ok, "%s has an unexpected shape", e.name) {
			continue
		}

		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		prose.write_json(strings.to_writer(&sb), results)
		testing.expectf(t, strings.to_string(sb) == string(data), "%s does not round-trip", e.name)
		checked += 1
	}
	corpus := corpus_count(t)
	testing.expectf(t, corpus >= 10, "only %d corpus files found", corpus)
	testing.expectf(t, checked == corpus, "%d golden files round-tripped, %d corpus files", checked, corpus)
}

@(private = "file")
destroy_results :: proc(results: []prose.File_Result) {
	for r in results {
		delete(r.findings)
	}
	delete(results)
}

// results_from_json builds the results from a parsed golden file. The strings
// point into `value`, which the caller keeps alive; the slices are the
// caller's to free with `destroy_results`.
@(private = "file")
results_from_json :: proc(value: json.Value) -> (results: []prose.File_Result, ok: bool) {
	arr := value.(json.Array) or_return
	out := make([dynamic]prose.File_Result)
	defer if !ok {
		for r in out {
			delete(r.findings)
		}
		delete(out)
	}
	for item in arr {
		obj := item.(json.Object) or_return
		file := obj["file"].(json.String) or_return
		note := obj["note"].(json.String) or_return
		fs := obj["findings"].(json.Array) or_return
		findings := make([dynamic]prose.Finding)
		for fv in fs {
			fo, is_obj := fv.(json.Object)
			if !is_obj {
				delete(findings)
				return nil, false
			}
			line, l_ok := fo["line"].(json.Integer)
			col, c_ok := fo["col"].(json.Integer)
			sev, s_ok := fo["severity"].(json.String)
			rule, r_ok := fo["rule"].(json.String)
			msg, m_ok := fo["message"].(json.String)
			exc, e_ok := fo["excerpt"].(json.String)
			sug, g_ok := fo["suggestion"].(json.String)
			if !(l_ok && c_ok && s_ok && r_ok && m_ok && e_ok && g_ok) {
				delete(findings)
				return nil, false
			}
			severity: prose.Severity
			switch sev {
			case "error":
				severity = .Error
			case "warning":
				severity = .Warning
			case "note":
				severity = .Note
			case:
				delete(findings)
				return nil, false
			}
			append(&findings, prose.Finding{int(line), int(col), severity, rule, msg, exc, sug})
		}
		append(&out, prose.File_Result{file, note, findings[:]})
	}
	return out[:], true
}
