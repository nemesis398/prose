package prose_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import prose "../src"

// A sample marks every run it expects to be markup: « » where LanguageTool
// may still report on it, ‹ › where its reports are suppressed. The marks are
// taken out before masking. The near misses at the end are what the
// reference leaves alone, each for a reason in its patterns.
@(private = "file")
KIND_SAMPLES := [][2]string {
	{"frontmatter", "‹---\ntitle: x\n---\n›Prose under the\nfront matter."},
	{"fence", "Prose before.\n‹```sh\necho hi\n```›\nProse after."},
	{"fence, tilde and indented", "Prose before.\n‹  ~~~\ncode\n   ~~~ tail›\nProse after."},
	{"comment", "Prose ‹<!-- a\nnote -->› prose.\nMore prose."},
	{"htmlblock", "Prose.\n«<style>\n.a { b: 1px; }\n</style>»\nProse."},
	{"htmlblock, any case", "Prose.\n«<SCRIPT type=x>\nlet a = 1;\n</script>»\nProse."},
	{"math", "Prose.\n‹$$\nx^2\n$$›\nProse."},
	{"codespan", "Run ‹`make test`› now.\nNext line."},
	{"codespan over one line break", "Run ‹`make\ntest`› now.\nNext line."},
	{"wikilink", "See ‹[[Note|alias]]› here.\nNext line."},
	{"wikilink embed", "See ‹![[pic.png|300]]› here.\nNext line."},
	{"link", "A «[»link«](https://x.org/a \"T\")» here.\nNext line."},
	{"image link", "An «![»image«](pic.png)» here.\nNext line."},
	{"angle url", "See ‹<https://example.org/a>› now.\nNext line."},
	{"bare url", "Read ‹https://example.org/a_(b)›.\nNext line."},
	{"html", "Text ‹<span class=\"x\">›word‹</span>› text.\nNext line."},
	{"html over lines", "Text ‹<div\n  style=\"a\">› text.\nNext line."},
	{"table pipes and rule", "«|» a «|» b «|»\n«|---|---|»\n«|» c «|» d «|»"},
	{"hrule", "Prose.\n«***»\nProse."},
	{"headmark", "«## »Heading\nProse."},
	{"quotemark", "Prose.\n«> »Quoted text."},
	{"listmark", "Prose.\n«- »item\n«2. »second\n«- [x] »done"},
	{"footnote", "Text«[^1]» here.\n«[^1]:» The note."},
	{"tag", "Tagged ‹#project/alpha› and ‹#todo›.\nNext line."},
	{"emph", "Some «**»bold«**», «_»it«_» and «~~»gone«~~».\nNext line."},
	{"strayticks", "A stray «` tick here»\nNext line."},
	{"no fence at four spaces", "Prose.\n    ‹``›«`»\n    code\n    ‹``›«`»\nProse."},
	{"no code span over two line breaks", "Run «`make»\n\ntest«` now.»"},
	{"no htmlblock without a word boundary", "Prose.\n‹<styles>›\nx\n‹</styles>›"},
	{"no tag without a letter or after a word", "A #1 and a# tag.\nNext line."},
	{"no heading at seven hashes", "Seven ####### hashes.\n####### no heading"},
}

@(private = "file")
Mark :: enum u8 {
	Prose,
	Markup,
	Suppressed,
}

// unmark takes the marks out of `marked` and returns the runes and the mark
// of each. Both slices are the caller's.
@(private = "file")
unmark :: proc(marked: string) -> (src: []rune, want: []Mark) {
	out := make([dynamic]rune)
	marks := make([dynamic]Mark)
	mark := Mark.Prose
	for r in marked {
		switch r {
		case '«':
			mark = .Markup
		case '‹':
			mark = .Suppressed
		case '»', '›':
			mark = .Prose
		case:
			append(&out, r)
			append(&marks, mark)
		}
	}
	return out[:], marks[:]
}

@(test)
mask_each_kind_marks_the_construct_and_nothing_else :: proc(t: ^testing.T) {
	for sample in KIND_SAMPLES {
		name, marked := sample[0], sample[1]
		src, want := unmark(marked)
		defer delete(src)
		defer delete(want)
		m := prose.mask_markdown(src)
		defer prose.masked_destroy(&m)
		if !testing.expectf(t, len(m.is_markup) == len(src) && len(m.suppress) == len(src), "%s: array lengths", name) {
			continue
		}
		for i in 0 ..< len(src) {
			got := Mark.Prose
			if m.suppress[i] {
				got = .Suppressed if m.is_markup[i] else Mark(255)
			} else if m.is_markup[i] {
				got = .Markup
			}
			if got != want[i] {
				testing.expectf(t, false, "%s: rune %d (%q) is %v, want %v", name, i, src[i], got, want[i])
				break
			}
		}
	}
}

@(private = "file")
Want_Segment :: struct {
	kind:     prose.Segment_Kind,
	text:     string,
	plain:    string,
	suppress: bool,
}

@(private = "file")
expect_segments :: proc(t: ^testing.T, source: string, want: []Want_Segment, loc := #caller_location) {
	src := utf8.string_to_runes(source)
	defer delete(src)
	m := prose.mask_markdown(src)
	defer prose.masked_destroy(&m)
	if !testing.expectf(t, len(m.segments) == len(want), "%q: %d segments, want %d", source, len(m.segments), len(want), loc = loc) {
		return
	}
	at := 0
	for s, i in m.segments {
		w := want[i]
		text := prose.runes_to_string(src[s.orig_start:s.orig_start + s.orig_len])
		defer delete(text)
		testing.expectf(t, s.orig_start == at, "%q seg %d: starts at %d, want %d", source, i, s.orig_start, at, loc = loc)
		testing.expectf(t, s.kind == w.kind && text == w.text && s.plain_text == w.plain && s.suppress == w.suppress,
			"%q seg %d: got {%v %q %q %v}, want {%v %q %q %v}", source, i,
			s.kind, text, s.plain_text, s.suppress, w.kind, w.text, w.plain, w.suppress, loc = loc)
		at += s.orig_len
	}
	testing.expectf(t, at == len(src), "%q: segments end at %d of %d", source, at, len(src), loc = loc)
}

@(test)
mask_segments_carry_the_interpretation :: proc(t: ^testing.T) {
	expect_segments(t, "See [[Target|alias]] and `code`.", {
		{.Text, "See ", "See ", false},
		{.Markup, "[[Target|alias]]", "Target", true},
		{.Text, " and ", " and ", false},
		{.Markup, "`code`", "code", true},
		{.Text, ".", ".", false},
	})
	// The target wins over the alias; an empty target leaves the alias; with
	// neither, the whole match.
	expect_segments(t, "[[|x]] [[]] ``", {
		{.Markup, "[[|x]]", "x", true},
		{.Text, " ", " ", false},
		{.Markup, "[[]]", "[[]]", true},
		{.Text, " ", " ", false},
		{.Markup, "``", "", true},
	})
	expect_segments(t, "a https://x.org b\n\n```\nc\n```", {
		{.Text, "a ", "a ", false},
		{.Markup, "https://x.org", "X", true},
		{.Text, " b\n\n", " b\n\n", false},
		{.Markup, "```\nc\n```", "\n\n", true},
	})
	// Two adjacent constructs of one kind stay two segments.
	expect_segments(t, "|x||", {
		{.Markup, "|", "\n", false},
		{.Text, "x", "x", false},
		{.Markup, "|", "\n", false},
		{.Markup, "|", "\n", false},
	})
	// An escaped paren does not end a link target, and the title goes too.
	expect_segments(t, `[P](https://x/P_\(f\) "P (f)") is`, {
		{.Markup, "[", "", false},
		{.Text, "P", "P", false},
		{.Markup, `](https://x/P_\(f\) "P (f)")`, "", false},
		{.Text, " is", " is", false},
	})
	// Without a closing paren after it, the target ends at the escaped one:
	// the reference backtracks into the escape.
	expect_segments(t, `[a](b\)c d) e`, {
		{.Markup, "[", "", false},
		{.Text, "a", "a", false},
		{.Markup, `](b\)`, "", false},
		{.Text, "c d) e", "c d) e", false},
	})
	// A rule line from a blank line takes that blank line with it.
	expect_segments(t, "a\n\n---\nb", {
		{.Text, "a\n", "a\n", false},
		{.Markup, "\n---", "\n", false},
		{.Text, "\nb", "\nb", false},
	})
}

@(test)
mask_of_empty_text :: proc(t: ^testing.T) {
	m := prose.mask_markdown(nil)
	defer prose.masked_destroy(&m)
	testing.expect_value(t, len(m.segments), 0)
	testing.expect_value(t, len(m.is_markup), 0)
	anns := prose.annotations_for(&m, 0, 0)
	defer prose.annotations_destroy(anns)
	testing.expect_value(t, len(anns), 0)
	testing.expect_value(t, prose.suppressed(&m, 0, 1), false)
}

@(test)
annotations_for_drops_interpretation_of_a_cut_span :: proc(t: ^testing.T) {
	src := utf8.string_to_runes("A [[Target|alias]] b.")
	defer delete(src)
	m := prose.mask_markdown(src)
	defer prose.masked_destroy(&m)

	whole := prose.annotations_for(&m, 0, len(src))
	defer prose.annotations_destroy(whole)
	if testing.expect_value(t, len(whole), 3) {
		testing.expect(t, !whole[0].is_markup && whole[0].text == "A ")
		testing.expect(t, whole[1].is_markup && whole[1].markup == "[[Target|alias]]" && whole[1].interpret_as == "Target")
		testing.expect(t, !whole[2].is_markup && whole[2].text == " b.")
	}

	exact := prose.annotations_for(&m, 2, 18)
	defer prose.annotations_destroy(exact)
	if testing.expect_value(t, len(exact), 1) {
		testing.expect_value(t, exact[0].interpret_as, "Target")
	}

	cut := prose.annotations_for(&m, 4, 10)
	defer prose.annotations_destroy(cut)
	if testing.expect_value(t, len(cut), 1) {
		testing.expect_value(t, cut[0].markup, "Target")
		testing.expect_value(t, cut[0].interpret_as, "")
		testing.expect(t, cut[0].is_markup)
	}

	across := prose.annotations_for(&m, 1, 19)
	defer prose.annotations_destroy(across)
	if testing.expect_value(t, len(across), 3) {
		testing.expect_value(t, across[0].text, " ")
		testing.expect_value(t, across[1].interpret_as, "Target")
		testing.expect_value(t, across[2].text, " ")
	}

	none := prose.annotations_for(&m, 5, 5)
	defer prose.annotations_destroy(none)
	testing.expect_value(t, len(none), 0)
}

@(test)
suppressed_looks_at_at_least_one_rune :: proc(t: ^testing.T) {
	src := utf8.string_to_runes("ab `c` d")
	defer delete(src)
	m := prose.mask_markdown(src)
	defer prose.masked_destroy(&m)
	testing.expect(t, !prose.suppressed(&m, 0, 3))
	testing.expect(t, prose.suppressed(&m, 0, 4))
	testing.expect(t, prose.suppressed(&m, 4, 0))
	testing.expect(t, !prose.suppressed(&m, 6, 0))
	testing.expect(t, prose.suppressed(&m, -2, 6))
	testing.expect(t, !prose.suppressed(&m, -2, 3))
	testing.expect(t, !prose.suppressed(&m, 8, 5))
	testing.expect(t, !prose.suppressed(&m, 100, 1))
}

// The reference's masking of every corpus file, dumped into
// tests/mask/NAME.json (see tests/README.md).
@(test)
mask_matches_the_reference_on_the_corpus :: proc(t: ^testing.T) {
	dir := strings.concatenate({#directory, "corpus"})
	defer delete(dir)
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	checked := 0
	for e in entries {
		if !strings.has_suffix(e.name, ".md") {
			continue
		}
		stem := e.name[:len(e.name) - 3]
		md_path := strings.concatenate({dir, "/", e.name})
		defer delete(md_path)
		json_path := strings.concatenate({#directory, "mask/", stem, ".json"})
		defer delete(json_path)
		md, merr := os.read_entire_file(md_path, context.allocator)
		if !testing.expectf(t, merr == nil, "read %s: %v", md_path, merr) {
			continue
		}
		defer delete(md)
		data, jerr := os.read_entire_file(json_path, context.allocator)
		if !testing.expectf(t, jerr == nil, "read %s: %v", json_path, jerr) {
			continue
		}
		defer delete(data)
		value, perr := json.parse(data, parse_integers = true)
		if !testing.expectf(t, perr == nil, "parse %s: %v", json_path, perr) {
			continue
		}
		defer json.destroy_value(value)

		src := utf8.string_to_runes(string(md))
		defer delete(src)
		m := prose.mask_markdown(src)
		defer prose.masked_destroy(&m)
		if compare_with_reference(t, stem, &m, value) {
			checked += 1
		}
	}
	testing.expectf(t, checked >= 10, "only %d corpus files matched", checked)
}

// compare_with_reference reports the first difference in each part and
// returns whether there was none.
@(private = "file")
compare_with_reference :: proc(t: ^testing.T, name: string, m: ^prose.Masked, value: json.Value) -> bool {
	doc, is_obj := value.(json.Object)
	if !testing.expectf(t, is_obj, "%s: not an object", name) {
		return false
	}
	ok := true
	length := doc["length"].(json.Integer) or_else -1
	if !testing.expectf(t, int(length) == len(m.src), "%s: length %d, reference %d", name, len(m.src), length) {
		return false
	}
	ok &= compare_runs(t, name, "is_markup", m.is_markup, doc["is_markup"])
	ok &= compare_runs(t, name, "suppress", m.suppress, doc["suppress"])

	segs := doc["segments"].(json.Array) or_else nil
	if !testing.expectf(t, len(segs) == len(m.segments), "%s: %d segments, reference %d", name, len(m.segments), len(segs)) {
		ok = false
	}
	for i in 0 ..< min(len(segs), len(m.segments)) {
		w := segs[i].(json.Object) or_else nil
		s := m.segments[i]
		kind := "text" if s.kind == .Text else "markup"
		if kind != (w["kind"].(json.String) or_else "") ||
		   s.orig_start != int(w["orig_start"].(json.Integer) or_else -1) ||
		   s.orig_len != int(w["orig_len"].(json.Integer) or_else -1) ||
		   s.plain_text != (w["plain_text"].(json.String) or_else "\x00") ||
		   s.suppress != (w["suppress"].(json.Boolean) or_else !s.suppress) {
			testing.expectf(t, false, "%s: segment %d is {%s %d %d %q %v}, reference %v", name, i,
				kind, s.orig_start, s.orig_len, s.plain_text, s.suppress, segs[i])
			ok = false
			break
		}
	}

	want := doc["annotations"].(json.Array) or_else nil
	anns := prose.annotations_for(m, 0, len(m.src))
	defer prose.annotations_destroy(anns)
	if !testing.expectf(t, len(want) == len(anns), "%s: %d annotations, reference %d", name, len(anns), len(want)) {
		ok = false
	}
	for i in 0 ..< min(len(want), len(anns)) {
		w := want[i].(json.Object) or_else nil
		a := anns[i]
		_, has_text := w["text"]
		_, has_interp := w["interpretAs"]
		same: bool
		if a.is_markup {
			same = !has_text && a.markup == (w["markup"].(json.String) or_else "\x00") &&
				(a.interpret_as != "") == has_interp &&
				(!has_interp || a.interpret_as == (w["interpretAs"].(json.String) or_else "\x00"))
		} else {
			same = has_text && a.text == (w["text"].(json.String) or_else "\x00") && len(w) == 1
		}
		if !same {
			testing.expectf(t, false, "%s: annotation %d is %v, reference %v", name, i, a, want[i])
			ok = false
			break
		}
	}
	return ok
}

@(private = "file")
compare_runs :: proc(t: ^testing.T, name, field: string, got: []bool, runs: json.Value) -> bool {
	arr, is_arr := runs.(json.Array)
	if !testing.expectf(t, is_arr, "%s: %s is not a list", name, field) {
		return false
	}
	at := 0
	for run in arr {
		pair := run.(json.Array) or_else nil
		if len(pair) != 2 {
			testing.expectf(t, false, "%s: %s has a bad run %v", name, field, run)
			return false
		}
		v := pair[0].(json.Boolean) or_else false
		count := int(pair[1].(json.Integer) or_else 0)
		for k in 0 ..< count {
			if at + k >= len(got) || got[at + k] != v {
				testing.expectf(t, false, "%s: %s[%d] is %v, reference %v", name, field, at + k,
					got[at + k] if at + k < len(got) else !v, v)
				return false
			}
		}
		at += count
	}
	return testing.expectf(t, at == len(got), "%s: %s covers %d of %d", name, field, at, len(got))
}


// Python's `\w` and `\d` differ from core:unicode's letters and digits, and
// the mask's word boundaries follow Python.
@(test)
py_classes_follow_python :: proc(t: ^testing.T) {
	testing.expect(t, prose.is_py_word('_'))
	testing.expect(t, prose.is_py_word('ß'))
	testing.expect(t, prose.is_py_word(0xB2)) // ², a No digit
	testing.expect(t, !prose.is_py_word(0x0345)) // a combining mark core:unicode calls a letter
	testing.expect(t, !prose.is_py_word(0x24B6)) // Ⓐ, likewise
	testing.expect(t, !prose.is_py_word(0x0301))
	testing.expect(t, !prose.is_py_word('-'))
	testing.expect(t, prose.is_py_decimal(0x0663)) // Arabic-Indic three
	testing.expect(t, !prose.is_py_decimal(0xB2))
	testing.expect(t, !prose.is_py_decimal(0x11DE0)) // newer than Python's Unicode 16
	testing.expect(t, prose.is_py_space(0x1C))
	testing.expect(t, !prose.is_py_space(0x200B))
}
