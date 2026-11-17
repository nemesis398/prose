package prose_tests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import prose "../src"

@(private = "file")
detect :: proc(s: string) -> string {
	r := utf8.string_to_runes(s)
	defer delete(r)
	return prose.detect_language(r)
}

@(test)
detect_language_picks_the_language_with_more_marker_words :: proc(t: ^testing.T) {
	testing.expect_value(t, detect("Das ist ein Test und er wird nicht gut."), "de")
	testing.expect_value(t, detect("This is the test that you will have."), "en")
	// Case does not matter, and neither does a capital umlaut in a marker.
	testing.expect_value(t, detect("DER HUND UND DIE KATZE"), "de")
	testing.expect_value(t, detect("FÜR ÜBER"), "de")
	testing.expect_value(t, detect("THE AND OF"), "en")
}

@(test)
detect_language_gives_nothing_for_a_tie_or_no_words :: proc(t: ^testing.T) {
	testing.expect_value(t, detect(""), "")
	testing.expect_value(t, detect("   \n\t "), "")
	testing.expect_value(t, detect("12345 !!! ..."), "")
	// "und" is German and "the" English: one each.
	testing.expect_value(t, detect("und the"), "")
	// Words without a marker in either set.
	testing.expect_value(t, detect("Kaffee tomato"), "")
}

@(test)
detect_language_counts_an_umlaut_three_times :: proc(t: ^testing.T) {
	// One English marker against one umlaut (3) and no marker.
	testing.expect_value(t, detect("the ä"), "de")
	// Two English markers do not beat one umlaut.
	testing.expect_value(t, detect("the and ö"), "de")
	// Three markers tie with one umlaut.
	testing.expect_value(t, detect("the and of Ü"), "")
	testing.expect_value(t, detect("the and of that Ü"), "en")
	// The umlaut counts anywhere in the text, also outside a word match,
	// and the sharp s counts as well.
	testing.expect_value(t, detect("the 1ß1"), "de")
	testing.expect_value(t, detect("x Ä Ö"), "de")
	// Python's word pattern includes the apostrophe and À-ÿ.
	testing.expect_value(t, detect("it's the"), "en")
	testing.expect_value(t, detect("ÀÿÞ"), "")
}

@(private = "file")
Block_Want :: struct {
	start, end: int,
	lang:       string,
}

@(private = "file")
blocks_of :: proc(s: string, forced: string) -> (blocks: []prose.Block, src: []rune, m: prose.Masked) {
	src = utf8.string_to_runes(s)
	m = prose.mask_markdown(src)
	blocks = prose.language_blocks(&m, forced)
	return
}

@(private = "file")
expect_blocks :: proc(t: ^testing.T, s: string, forced: string, want: []Block_Want, loc := #caller_location) {
	blocks, src, m := blocks_of(s, forced)
	defer delete(blocks)
	defer delete(src)
	defer prose.masked_destroy(&m)
	if !testing.expectf(t, len(blocks) == len(want), "%q: %d blocks, want %d: %v", s, len(blocks), len(want), blocks, loc = loc) {
		return
	}
	for b, i in blocks {
		testing.expectf(t, b.start == want[i].start && b.end == want[i].end && b.lang == want[i].lang,
			"%q block %d: [%d %d %q], want [%d %d %q]", s, i, b.start, b.end, b.lang, want[i].start, want[i].end, want[i].lang, loc = loc)
	}
}

@(test)
blocks_split_at_blank_lines_and_keep_the_gap_out :: proc(t: ^testing.T) {
	expect_blocks(t, "", "auto", {})
	expect_blocks(t, " \n\n\t", "auto", {})
	expect_blocks(t, "ab\n\ncd", "auto", {{0, 2, "en"}, {4, 6, "en"}})
	// One break, not two: a single newline does not split.
	expect_blocks(t, "ab\ncd", "auto", {{0, 5, "en"}})
	// A separator takes all the white space around its last newline.
	expect_blocks(t, "ab\n \n\n cd", "auto", {{0, 2, "en"}, {6, 9, "en"}})
	// The separator needs a newline at each end; a no-break space is white
	// space to Python's `\s`.
	expect_blocks(t, "ab\n \ncd", "auto", {{0, 2, "en"}, {5, 7, "en"}})
	expect_blocks(t, "ab \n \ncd", "auto", {{0, 3, "en"}, {6, 8, "en"}})
	// White space at the ends belongs to the first and last block.
	expect_blocks(t, "  ab  \n\ncd\n", "auto", {{0, 6, "en"}, {8, 11, "en"}})
	// CR LF is not a break of its own, but the LF still is.
	expect_blocks(t, "ab\r\n\r\ncd", "auto", {{0, 3, "en"}, {6, 8, "en"}})
}

@(test)
blocks_carry_the_previous_language_over_a_short_or_unclear_block :: proc(t: ^testing.T) {
	de := "Das ist ein Test und er wird nicht gut für uns alle."
	en := "This is the test that you will have with them."
	text := strings.concatenate({de, "\n\nKurz.\n\n", en, "\n\nShort.\n\nund the one two three four five six"})
	defer delete(text)
	blocks, src, m := blocks_of(text, "auto")
	defer delete(blocks)
	defer delete(src)
	defer prose.masked_destroy(&m)
	langs := make([dynamic]string)
	defer delete(langs)
	for b in blocks {
		append(&langs, b.lang)
	}
	// de, then short "Kurz." keeps de, en, short keeps en, a tie keeps en.
	testing.expect_value(t, len(langs), 5)
	if len(langs) == 5 {
		testing.expect_value(t, langs[0], "de")
		testing.expect_value(t, langs[1], "de")
		testing.expect_value(t, langs[2], "en")
		testing.expect_value(t, langs[3], "en")
		testing.expect_value(t, langs[4], "en")
	}
}

@(test)
blocks_start_from_the_language_of_the_whole_text :: proc(t: ^testing.T) {
	// The first block is short and unclear, so it takes the language of the
	// whole text, which is German here; with no marker anywhere, English.
	expect_blocks(t, "Hallo.\n\nDas ist ein Test und er wird nicht gut für uns alle.", "auto", {{0, 6, "de"}, {8, 60, "de"}})
	expect_blocks(t, "Hello.\n\nKaffee Tomate Birne Apfel Kiwi Mango Pflaume.", "auto", {{0, 6, "en"}, {8, 53, "en"}})
}

@(test)
blocks_read_masked_text_as_blank :: proc(t: ^testing.T) {
	// The code span is full of English markers; read as blank it counts for
	// nothing, so the paragraph stays German.
	expect_blocks(t, "Das ist ein Test und er wird nicht gut `the and of that this is are was were` für alle.", "auto", {{0, 87, "de"}})
}

@(test)
forced_language_labels_every_block :: proc(t: ^testing.T) {
	text := "Das ist ein Test und er wird nicht gut für uns alle.\n\nThis is the test that you will have with them."
	blocks, src, m := blocks_of(text, "de")
	defer delete(blocks)
	defer delete(src)
	defer prose.masked_destroy(&m)
	testing.expect_value(t, len(blocks), 2)
	for b in blocks {
		testing.expect_value(t, b.lang, "de")
	}
	b2, s2, m2 := blocks_of(text, "en")
	defer delete(b2)
	defer delete(s2)
	defer prose.masked_destroy(&m2)
	for b in b2 {
		testing.expect_value(t, b.lang, "en")
	}
}

// The reference's blocks for every corpus file, dumped into
// tests/mask/NAME.blocks.json (see tests/README.md).
@(test)
blocks_match_the_reference_on_the_corpus :: proc(t: ^testing.T) {
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
		json_path := strings.concatenate({#directory, "mask/", stem, ".blocks.json"})
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
		blocks := prose.language_blocks(&m, "auto")
		defer delete(blocks)

		doc, _ := value.(json.Object)
		want, _ := doc["blocks"].(json.Array)
		if !testing.expectf(t, len(want) == len(blocks), "%s: %d blocks, reference %d", stem, len(blocks), len(want)) {
			continue
		}
		same := true
		for b, i in blocks {
			w, _ := want[i].(json.Object)
			ws := int(w["start"].(json.Integer) or_else -1)
			we := int(w["end"].(json.Integer) or_else -1)
			wl := w["lang"].(json.String) or_else "\x00"
			if b.start != ws || b.end != we || b.lang != wl {
				testing.expectf(t, false, "%s: block %d is [%d %d %q], reference [%d %d %q]", stem, i, b.start, b.end, b.lang, ws, we, wl)
				same = false
				break
			}
		}
		if same {
			checked += 1
		}
	}
	testing.expectf(t, checked >= 10, "only %d corpus files matched", checked)
}
