package prose

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The deterministic rules: dashes, emoji, German typography, spacing, quotes
// and phrasing. A port of the reference's `check_deterministic`, quirks
// included, so every finding lands where the reference put it. Each regular
// expression of the reference is a hand scanner here, with Python's `\s`,
// `\w`, `\d` and `\b`, and with `re.finditer`'s rule that a search goes on
// after the end of the last match. The passes run in the reference's order,
// since the order of findings that share a line, column and rule is the
// order they were added in.

// The German budget: one spaced en dash per this many German words.
DE_ENDASH_WORDS_PER_DASH :: 200

// A phrase that marks machine-shaped prose, lower case, and why.
Phrase :: struct {
	text, why: string,
}

@(rodata)
AI_PHRASES_EN := [?]Phrase {
	{"it's not just", "Antithesis padding. State the thing you mean."},
	{"it is not just", "Antithesis padding. State the thing you mean."},
	{"this isn't about", "Antithesis padding. Say what it is about."},
	{"more than just", "Antithesis padding."},
	{"it's worth noting", "If it is worth noting, note it without the preamble."},
	{"it is worth noting", "If it is worth noting, note it without the preamble."},
	{"it's important to note", "Throat-clearing. Delete and keep the fact."},
	{"it is important to note", "Throat-clearing. Delete and keep the fact."},
	{"in today's", "Throat-clearing opener."},
	{"in the world of", "Throat-clearing opener."},
	{"when it comes to", "Filler. Name the subject directly."},
	{"let's dive", "Signposting the reader does not need."},
	{"let's take a look", "Signposting the reader does not need."},
	{"delve into", "Register mismatch with the rest of your notes."},
	{"at the end of the day", "Cliche."},
	{"the key takeaway", "If the point is the point, just make it."},
	{"in conclusion", "A note does not need a conclusion section."},
	{"to sum up", "A note does not need a summary of itself."},
	{"game-changer", "Marketing register."},
	{"game changer", "Marketing register."},
	{"seamless", "Empty intensifier. Say what actually happens."},
	{"seamlessly", "Empty intensifier. Say what actually happens."},
	{"effortless", "Empty intensifier."},
	{"unlock the", "Marketing register."},
	{"harness the power", "Marketing register."},
	{"navigate the complex", "Marketing register."},
	{"tapestry", "Marketing register."},
	{"a testament to", "Marketing register."},
	{"plays a crucial role", "Says nothing. Name the role."},
	{"plays a vital role", "Says nothing. Name the role."},
	{"robust and scalable", "Paired empty adjectives."},
	{"powerful and flexible", "Paired empty adjectives."},
	{"fast and efficient", "Paired empty adjectives."},
}

@(rodata)
AI_PHRASES_DE := [?]Phrase {
	{"in der heutigen", "Floskel-Einstieg."},
	{"in der heutigen schnelllebigen", "Floskel-Einstieg."},
	{"es ist wichtig zu beachten", "Vorgeplänkel. Die Tatsache reicht."},
	{"es sei angemerkt", "Vorgeplänkel."},
	{"es gilt zu beachten", "Vorgeplänkel."},
	{"zusammenfassend lässt sich sagen", "Wiederholt nur den Absatz davor."},
	{"abschließend lässt sich", "Wiederholt nur den Absatz davor."},
	{"tauchen wir ein", "Wegweiser, den niemand braucht."},
	{"werfen wir einen blick", "Wegweiser, den niemand braucht."},
	{"nicht nur, sondern auch", "Antithese als Füllung."},
	{"spielt eine entscheidende rolle", "Sagt nichts. Nenn die Rolle."},
	{"spielt eine wichtige rolle", "Sagt nichts. Nenn die Rolle."},
	{"ein wahrer gamechanger", "Werbesprache."},
	{"revolutioniert", "Werbesprache."},
	{"nahtlos", "Leere Verstärkung. Sag, was passiert."},
	{"leistungsstark und flexibel", "Leeres Adjektivpaar."},
	{"schnell und effizient", "Leeres Adjektivpaar."},
}

// German connectives that are fine once and grating four times in a row.
@(rodata)
DE_GLUE_WORDS := [?]string {
	"darüber hinaus",
	"des weiteren",
	"ferner",
	"zudem",
	"überdies",
	"nicht zuletzt",
	"in diesem zusammenhang",
}

// The dashes that are never correct here, by the name a finding gives them.
Dash :: struct {
	char: rune,
	name: string,
}

@(rodata)
EM_DASHES := [?]Dash {
	{'\u2014', "em dash"},
	{'\u2015', "horizontal bar"},
	{'\u2e3a', "two-em dash"},
	{'\u2e3b', "three-em dash"},
}

// The units of DE-UNIT-SPACE and of DE-DECIMAL, each tried in this order,
// the first that matches winning, as in the reference's alternations.
@(private = "file", rodata)
UNIT_SPACE_UNITS := [?]string{"%", "‰", "°C", "°F", "€", "kg", "km", "MB", "GB", "TB"}

@(private = "file", rodata)
DECIMAL_UNITS := [?]string {
	"%", "‰", "°C", "°F", "€", "EUR", "kg", "g", "km", "m", "cm", "mm",
	"GB", "MB", "TB", "KB", "Mbit", "Gbit", "h", "min", "s",
}

@(private = "file", rodata)
ABBREVIATIONS := [?]string{"z.B.", "d.h.", "u.a.", "u.U.", "i.d.R.", "z.T."}

// What one run of the rules shares, in place of the reference's closures.
@(private = "file")
Rules :: struct {
	src:       []rune,
	m:         ^Masked,
	blocks:    []Block,
	starts:    []int,
	tables:    map[int]struct{},
	out:       [dynamic]Finding,
	// Scratch for formatting a message and a suggestion; `add` copies both.
	msg, sug:  strings.Builder,
	allocator: mem.Allocator,
}

// check_deterministic runs every deterministic rule over `src`, which `m`
// masks and `blocks` splits into paragraphs, and returns the findings sorted
// by line and column, stably. Every string of every finding is allocated
// with `allocator`; free them with `findings_destroy`.
check_deterministic :: proc(
	src: []rune,
	m: ^Masked,
	blocks: []Block,
	allocator := context.allocator,
) -> [dynamic]Finding {
	r := Rules {
		src       = src,
		m         = m,
		blocks    = blocks,
		starts    = line_index(src, allocator),
		tables    = table_rows(src, m.is_markup, allocator),
		out       = make([dynamic]Finding, allocator),
		msg       = strings.builder_make(allocator),
		sug       = strings.builder_make(allocator),
		allocator = allocator,
	}
	defer delete(r.starts, allocator)
	defer delete(r.tables)
	defer strings.builder_destroy(&r.msg)
	defer strings.builder_destroy(&r.sug)

	rule_dashes(&r)
	rule_emoji(&r)
	rule_typography(&r)
	rule_spacing(&r)
	rule_phrasing(&r)

	slice.stable_sort_by(r.out[:], proc(a, b: Finding) -> bool {
		if a.line != b.line {
			return a.line < b.line
		}
		return a.col < b.col
	})
	return r.out
}

// add records a finding at `offset`, with an excerpt around `length` code
// points from there. It copies `rule`, `message` and `suggestion`.
@(private = "file")
add :: proc(r: ^Rules, offset: int, sev: Severity, rule, message: string, suggestion := "", length := 1) {
	line, col := to_line_col(r.starts, offset)
	append(
		&r.out,
		Finding {
			line = line,
			col = col,
			severity = sev,
			rule = strings.clone(rule, r.allocator),
			message = strings.clone(message, r.allocator),
			excerpt = excerpt_at(r.src, offset, length, 34, r.allocator),
			suggestion = strings.clone(suggestion, r.allocator),
		},
	)
}

// msgf and sugf format into the scratch builders. The result is valid until
// the next call of the same one.
@(private = "file")
msgf :: proc(r: ^Rules, format: string, args: ..any) -> string {
	strings.builder_reset(&r.msg)
	fmt.sbprintf(&r.msg, format, ..args)
	return strings.to_string(r.msg)
}

@(private = "file")
sugf :: proc(r: ^Rules, format: string, args: ..any) -> string {
	strings.builder_reset(&r.sug)
	fmt.sbprintf(&r.sug, format, ..args)
	return strings.to_string(r.sug)
}

// lang_at is the language of the block holding `offset`. An offset between
// two blocks gets the last block's language, not the one before it, as in
// the reference; no block at all means English.
@(private = "file")
lang_at :: proc(r: ^Rules, offset: int) -> string {
	for b in r.blocks {
		if b.start <= offset && offset < b.end {
			return b.lang
		}
	}
	if len(r.blocks) > 0 {
		return r.blocks[len(r.blocks) - 1].lang
	}
	return "en"
}

@(private = "file")
in_table :: proc(r: ^Rules, offset: int) -> bool {
	line, _ := to_line_col(r.starts, offset)
	return line in r.tables
}

// ---------------------------------------------------------------------------
// Dashes and the German budget.
// ---------------------------------------------------------------------------

@(private = "file")
rule_dashes :: proc(r: ^Rules) {
	src, n := r.src, len(r.src)
	for ch, i in src {
		name := ""
		for d in EM_DASHES {
			if d.char == ch {
				name = d.name
			}
		}
		if name == "" || r.m.is_markup[i] {
			continue
		}
		if in_table(r, i) && lone_cell_value(src, i) {
			add(
				r,
				i,
				.Warning,
				"EM-DASH-CELL",
				msgf(r, "%s as an empty-cell placeholder. Not prose, but it is still the character we are keeping out of these files.", name),
				"use \u2013 or leave the cell empty",
			)
			continue
		}
		de := lang_at(r, i) == "de"
		add(
			r,
			i,
			.Error,
			"EM-DASH",
			msgf(r, "%s in %s prose. This character is never correct here.", name, "German" if de else "English"),
			"replace with a spaced en dash: \u2013" if de else "restructure into a comma, colon, parenthesis or two sentences",
		)
	}

	// `(?<=\s)\u2013(?=\s)`: a spaced en dash.
	de_dashes := make([dynamic]int, r.allocator)
	defer delete(de_dashes)
	for i in 1 ..< n - 1 {
		if src[i] != '\u2013' || !is_py_space(src[i - 1]) || !is_py_space(src[i + 1]) || r.m.is_markup[i] {
			continue
		}
		if lang_at(r, i) == "de" {
			append(&de_dashes, i)
		} else {
			add(
				r,
				i,
				.Error,
				"EN-DASH-EN",
				"Spaced en dash as a sentence interrupter in English prose.",
				"restructure into a comma, colon, parenthesis or two sentences",
			)
		}
	}

	// The budget is never below one, so a single dash cannot exceed it.
	if len(de_dashes) <= 1 {
		return
	}
	// The German words are counted in the blocks' visible text, with the
	// masked markup blanked out.
	visible := make([]rune, n, r.allocator)
	defer delete(visible, r.allocator)
	for c, i in src {
		visible[i] = ' ' if r.m.is_markup[i] else c
	}
	de_words := 0
	for b in r.blocks {
		if b.lang == "de" {
			de_words += count_words(visible[b.start:b.end])
		}
	}
	budget := max(1, de_words / DE_ENDASH_WORDS_PER_DASH)
	if len(de_dashes) <= budget {
		return
	}

	Dense :: struct {
		hits, line: int,
	}
	dense := make([dynamic]Dense, r.allocator)
	defer delete(dense)
	for b in r.blocks {
		if b.lang != "de" {
			continue
		}
		hits := 0
		for i in de_dashes {
			if b.start <= i && i < b.end {
				hits += 1
			}
		}
		if hits >= 2 {
			line, _ := to_line_col(r.starts, b.start)
			append(&dense, Dense{hits, line})
		}
	}
	// Python's `sort(reverse=True)` on (hits, line) tuples.
	slice.sort_by(dense[:], proc(a, b: Dense) -> bool {
		if a.hits != b.hits {
			return a.hits > b.hits
		}
		return a.line > b.line
	})

	msgf(
		r,
		"%d spaced en dashes in %d German words. Budget is %d, one per %d. Each one is correct German, but at this density the Gedankenstrich stops being a device and becomes the default rhythm.",
		len(de_dashes),
		de_words,
		budget,
		DE_ENDASH_WORDS_PER_DASH,
	)
	if len(dense) > 0 {
		strings.write_string(&r.msg, " Densest: ")
		for d, k in dense[:min(len(dense), 6)] {
			if k > 0 {
				strings.write_string(&r.msg, ", ")
			}
			fmt.sbprintf(&r.msg, "line %d (%d\u00d7)", d.line, d.hits)
		}
		strings.write_string(&r.msg, ".")
	}
	add(
		r,
		de_dashes[0],
		.Warning,
		"EN-DASH-BUDGET",
		strings.to_string(r.msg),
		sugf(r, "rewrite about %d of them as commas, colons or sentence breaks", len(de_dashes) - budget),
	)
}

// lone_cell_value reports whether the code point at `offset` is all there is
// of its table cell, white space aside. The cell runs from the last "|" or
// line break before it to the first "|" or line break after it.
@(private = "file")
lone_cell_value :: proc(src: []rune, offset: int) -> bool {
	lo := 0
	for k := offset - 1; k >= 0; k -= 1 {
		if src[k] == '|' || src[k] == '\n' {
			lo = k + 1
			break
		}
	}
	hi := len(src)
	for k in offset ..< len(src) {
		if src[k] == '|' || src[k] == '\n' {
			hi = k
			break
		}
	}
	for lo < hi && is_py_space(src[lo]) {
		lo += 1
	}
	for hi > lo && is_py_space(src[hi - 1]) {
		hi -= 1
	}
	return hi - lo == 1
}

// ---------------------------------------------------------------------------
// Emoji and the legend.
// ---------------------------------------------------------------------------

@(private = "file")
rule_emoji :: proc(r: ^Rules) {
	src, n := r.src, len(r.src)
	a := r.allocator

	// An emoji that occurs more than once anywhere is a marker, not
	// decoration; a heading may carry it at its end.
	doc := emoji_clusters(src, a)
	defer emoji_destroy(doc, a)
	count := make(map[string]int, a)
	defer delete(count)
	for e in doc {
		count[e.cluster] += 1
	}

	// The heading each first emoji labels, by line. The keys are copies.
	seen := make(map[string]int, a)
	defer {
		for k in seen {
			delete(k, a)
		}
		delete(seen)
	}
	in_heading := make([]bool, n, a)
	defer delete(in_heading, a)

	// `^(#{1,6})[ \t]+(.*)$`, multiline: one candidate per line.
	for ls, k in r.starts {
		le := r.starts[k + 1] - 1 if k + 1 < len(r.starts) else n
		hashes := 0
		for ls + hashes < le && src[ls + hashes] == '#' {
			hashes += 1
		}
		j := ls + hashes
		if hashes < 1 || hashes > 6 || j >= le || (src[j] != ' ' && src[j] != '\t') {
			continue
		}
		for j < le && (src[j] == ' ' || src[j] == '\t') {
			j += 1
		}
		if heading_is_code(r, ls) {
			continue
		}
		text_start := j
		for i in ls ..< le {
			in_heading[i] = true
		}

		found := emoji_clusters(src[text_start:le], a)
		defer emoji_destroy(found, a)
		if len(found) == 0 {
			continue
		}
		first := found[0]
		if first.offset != 0 && count[first.cluster] > 1 {
			continue
		}
		if first.offset != 0 {
			add(
				r,
				text_start + first.offset,
				.Error,
				"EMOJI-POSITION",
				"Emoji inside a heading but not leading it.",
				"move it to the front: `## ✅ Title`",
				utf8.rune_count_in_string(first.cluster),
			)
		}
		if len(found) > 1 {
			add(
				r,
				text_start + found[1].offset,
				.Warning,
				"EMOJI-COUNT",
				msgf(r, "%d emoji in one heading. One label reads as a label, two read as decoration.", len(found)),
				"keep the one that names the section",
			)
		}
		if earlier, ok := seen[first.cluster]; ok {
			add(
				r,
				text_start,
				.Warning,
				"EMOJI-DUPLICATE",
				msgf(r, "%s already labels the heading on line %d. Repeating it stops it working as a landmark.", first.cluster, earlier),
				"pick a different, equally literal icon",
			)
		} else {
			seen[strings.clone(first.cluster, a)] = k + 1
		}
	}

	// The body emoji by cluster, in the order each first appears.
	Body :: struct {
		cluster: string,
		offsets: [dynamic]int,
	}
	bodies := make([dynamic]Body, a)
	index := make(map[string]int, a)
	defer {
		for b in bodies {
			delete(b.offsets)
		}
		delete(bodies)
		delete(index)
	}
	for e in doc {
		if in_heading[e.offset] || r.m.is_markup[e.offset] {
			continue
		}
		k, ok := index[e.cluster]
		if !ok {
			k = len(bodies)
			index[e.cluster] = k
			append(&bodies, Body{e.cluster, make([dynamic]int, a)})
		}
		append(&bodies[k].offsets, e.offset)
	}

	for b in bodies {
		length := utf8.rune_count_in_string(b.cluster)
		_, in_headings := seen[b.cluster]
		// Repetition of one identical marker is systematic. Decoration varies.
		if in_headings || len(b.offsets) >= 2 {
			message: string
			if in_headings {
				message = msgf(r, "%s also labels a heading here, so it reads as a pointer to that section. Left alone.", b.cluster)
			} else {
				message = msgf(r, "%s appears %d\u00d7 in body text, so it reads as a legend rather than decoration. Left alone.", b.cluster, len(b.offsets))
			}
			add(r, b.offsets[0], .Note, "EMOJI-LEGEND", message, "no action unless you meant it as decoration", length)
			continue
		}
		for offset in b.offsets {
			add(
				r,
				offset,
				.Warning,
				"EMOJI-BODY",
				msgf(r, "%s outside a heading. Emoji label sections here, they are not inline punctuation.", b.cluster),
				"move it to the nearest heading, or drop it",
				length,
			)
		}
	}
}

// heading_is_code is the reference's `_heading_is_code`: the heading's first
// code point is masked, by a segment whose text starts with a fence.
@(private = "file")
heading_is_code :: proc(r: ^Rules, start: int) -> bool {
	if !r.m.is_markup[start] {
		return false
	}
	for s in r.m.segments {
		if s.kind != .Markup || start < s.orig_start || start >= s.orig_start + s.orig_len || s.orig_len < 3 {
			continue
		}
		c := r.src[s.orig_start]
		if (c == '`' || c == '~') && r.src[s.orig_start + 1] == c && r.src[s.orig_start + 2] == c {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// German typography.
// ---------------------------------------------------------------------------

@(private = "file")
rule_typography :: proc(r: ^Rules) {
	src, n := r.src, len(r.src)

	// `(\d)(%|‰|°C|°F|€|kg|km|MB|GB|TB)`
	for p := 0; p < n; {
		w := -1
		unit := ""
		if is_py_decimal(src[p]) {
			unit, w = first_literal(src, p + 1, UNIT_SPACE_UNITS[:])
		}
		if w < 0 {
			p += 1
			continue
		}
		if !r.m.is_markup[p] && lang_at(r, p) == "de" {
			add(
				r,
				p,
				.Error,
				"DE-UNIT-SPACE",
				msgf(r, "German typography puts a space between number and unit: %c %s.", src[p], unit),
				sugf(r, "%c %s", src[p], unit),
				1 + w,
			)
		}
		p += 1 + w
	}

	// `\b\d{1,3},\d{3}\b(?!\d)`
	for p := 0; p < n; {
		end := thousands_at(src, p)
		if end < 0 {
			p += 1
			continue
		}
		if !r.m.is_markup[p] && lang_at(r, p) == "de" {
			add(
				r,
				p,
				.Warning,
				"DE-THOUSANDS",
				"Looks like an English thousands separator in German text. German writes 5.000, not 5,000.",
				replaced(r, src[p:end], ',', "."),
				end - p,
			)
		}
		p = end
	}

	// `(?<![\d.\w])\d+\.\d+(?![\d.])\s*(?:UNITS)\b`. Only a real unit after
	// it counts, and never a version number or an IP address.
	for p := 0; p < n; {
		end, number_end := decimal_at(src, p)
		if end < 0 {
			p += 1
			continue
		}
		if !r.m.is_markup[p] && lang_at(r, p) == "de" {
			add(
				r,
				p,
				.Warning,
				"DE-DECIMAL",
				"Decimal point in German text. German uses the comma: 3,5.",
				replaced(r, src[p:number_end], '.', ","),
				end - p,
			)
		}
		p = end
	}

	// `\b(z\.B\.|d\.h\.|u\.a\.|u\.U\.|i\.d\.R\.|z\.T\.)`
	for p := 0; p < n; {
		w := -1
		if p == 0 || !is_py_word(src[p - 1]) {
			_, w = first_literal(src, p, ABBREVIATIONS[:])
		}
		if w < 0 {
			p += 1
			continue
		}
		if !r.m.is_markup[p] && lang_at(r, p) == "de" {
			// `.replace(".", ". ").rstrip()`
			spaced := strings.trim_right_space(replaced(r, src[p:p + w], '.', ". "))
			add(r, p, .Warning, "DE-ABBREV-SPACE", msgf(r, "DIN 5008 spaces multi-part abbreviations: %s", spaced), spaced, w)
		}
		p += w
	}
}

// thousands_at returns the end of a match of `\b\d{1,3},\d{3}\b(?!\d)` at
// `p`, or -1. The leading digits must be the whole run of one to three, and
// the three after the comma must end at a word boundary.
@(private = "file")
thousands_at :: proc(src: []rune, p: int) -> int {
	n := len(src)
	if !is_py_decimal(src[p]) || (p > 0 && is_py_word(src[p - 1])) {
		return -1
	}
	k := p
	for k < n && is_py_decimal(src[k]) {
		k += 1
	}
	if k - p > 3 || k >= n || src[k] != ',' {
		return -1
	}
	q := k + 1
	for _ in 0 ..< 3 {
		if q >= n || !is_py_decimal(src[q]) {
			return -1
		}
		q += 1
	}
	if q < n && is_py_word(src[q]) {
		return -1
	}
	return q
}

// decimal_at returns the end of a match of the DE-DECIMAL expression at `p`
// and the end of its number, or -1. Backtracking cannot help it: a shorter
// digit run leaves a digit where a "." or the lookahead wants none, and a
// shorter `\s*` leaves white space where a unit must start. So the digit
// runs and the white space are taken whole, and the units are tried in
// order, each with the `\b` after it.
@(private = "file")
decimal_at :: proc(src: []rune, p: int) -> (end, number_end: int) {
	n := len(src)
	if !is_py_decimal(src[p]) {
		return -1, -1
	}
	if p > 0 {
		prev := src[p - 1]
		if is_py_decimal(prev) || prev == '.' || is_py_word(prev) {
			return -1, -1
		}
	}
	k := p
	for k < n && is_py_decimal(src[k]) {
		k += 1
	}
	if k >= n || src[k] != '.' || k + 1 >= n || !is_py_decimal(src[k + 1]) {
		return -1, -1
	}
	q := k + 1
	for q < n && is_py_decimal(src[q]) {
		q += 1
	}
	if q < n && src[q] == '.' {
		return -1, -1
	}
	s := q
	for s < n && is_py_space(src[s]) {
		s += 1
	}
	for u in DECIMAL_UNITS {
		w := literal_at(src, s, u)
		if w >= 0 && word_boundary(src, s + w) {
			return s + w, q
		}
	}
	return -1, -1
}

// word_boundary is Python's `\b` at `i`.
@(private = "file")
word_boundary :: proc(src: []rune, i: int) -> bool {
	before := i > 0 && is_py_word(src[i - 1])
	after := i < len(src) && is_py_word(src[i])
	return before != after
}

// literal_at returns the length in code points of `lit` when it occurs in
// `src` at `p`, or -1.
@(private = "file")
literal_at :: proc(src: []rune, p: int, lit: string) -> int {
	k := p
	for c in lit {
		if k >= len(src) || src[k] != c {
			return -1
		}
		k += 1
	}
	return k - p
}

// first_literal tries `lits` in order at `p` and returns the first that
// occurs there with its length, or a length of -1.
@(private = "file")
first_literal :: proc(src: []rune, p: int, lits: []string) -> (string, int) {
	for lit in lits {
		if w := literal_at(src, p, lit); w >= 0 {
			return lit, w
		}
	}
	return "", -1
}

// replaced writes `text` with every `from` replaced by `to` into the
// suggestion builder and returns it.
@(private = "file")
replaced :: proc(r: ^Rules, text: []rune, from: rune, to: string) -> string {
	strings.builder_reset(&r.sug)
	for c in text {
		if c == from {
			strings.write_string(&r.sug, to)
		} else {
			strings.write_rune(&r.sug, c)
		}
	}
	return strings.to_string(r.sug)
}

// ---------------------------------------------------------------------------
// Spacing and quotes.
// ---------------------------------------------------------------------------

@(private = "file")
rule_spacing :: proc(r: ^Rules) {
	src, n := r.src, len(r.src)

	// `\S  +\S`. The match takes the word character after the spaces, so
	// "a  b  c" reports only the first gap, as the reference does.
	for p := 0; p < n; {
		q := p + 1
		for q < n && src[q] == ' ' {
			q += 1
		}
		if is_py_space(src[p]) || q - (p + 1) < 2 || q >= n || is_py_space(src[q]) {
			p += 1
			continue
		}
		i := p + 1
		if !r.m.is_markup[i] && !in_table(r, i) {
			add(r, i, .Warning, "DOUBLE-SPACE", "More than one space between words.", "single space", q + 1 - p)
		}
		p = q + 1
	}

	// `[ \t]+([,;:!?](?:[ \t]|$))`, multiline.
	for p := 0; p < n; {
		q := p
		for q < n && (src[q] == ' ' || src[q] == '\t') {
			q += 1
		}
		if q == p || q >= n || !strings.contains_rune(",;:!?", src[q]) {
			p += 1
			continue
		}
		end := q + 1
		if end < n && (src[end] == ' ' || src[end] == '\t') {
			end += 1
		} else if end < n && src[end] != '\n' {
			p += 1
			continue
		}
		lang := lang_at(r, p)
		if !r.m.is_markup[p] && !in_table(r, p) && (lang == "de" || lang == "en") {
			add(r, p, .Error, "SPACE-BEFORE-PUNCT", "Space before punctuation.", sugf(r, "%c", src[q]), end - p)
		}
		p = end
	}

	// Both kinds of quote in one document. The count is over the whole
	// source, masked parts included.
	typographic, straight, first_straight := 0, 0, -1
	for c, i in src {
		switch c {
		case '\u201e', '\u201c', '\u201d':
			typographic += 1
		case '"':
			straight += 1
			if first_straight < 0 {
				first_straight = i
			}
		}
	}
	if typographic > 0 && straight > 2 {
		add(
			r,
			first_straight,
			.Warning,
			"QUOTE-MIX",
			msgf(r, "Both typographic quotes (%d) and straight quotes (%d) in one document. Pick one and hold it.", typographic, straight),
			"\u201e\u2026\u201c for polished German, straight quotes for notes",
		)
	}
}

// ---------------------------------------------------------------------------
// Phrasing.
// ---------------------------------------------------------------------------

@(private = "file")
rule_phrasing :: proc(r: ^Rules) {
	n := len(r.src)
	a := r.allocator
	lowered := py_lower(r.src, a)
	defer delete(lowered, a)

	// A shorter phrase matches inside a longer one ("seamless" inside
	// "seamlessly"), so the longest hit at each position wins, the first
	// listed among equals.
	Hit :: struct {
		length: int,
		why:    string,
	}
	hits := make(map[int]Hit, a)
	defer delete(hits)
	Phrases :: struct {
		lang: string,
		list: []Phrase,
	}
	sets := [?]Phrases{{"en", AI_PHRASES_EN[:]}, {"de", AI_PHRASES_DE[:]}}
	for set in sets {
		for ph in set.list {
			length := utf8.rune_count_in_string(ph.text)
			for p := 0; p < len(lowered); {
				if literal_at(lowered, p, ph.text) < 0 {
					p += 1
					continue
				}
				// `lowered` is as long as the source, so `p < n` always
				// holds; it stays as a guard. The reference's lowered text
				// could be longer and raised IndexError here.
				if p < n && !r.m.is_markup[p] && lang_at(r, p) == set.lang {
					if old, ok := hits[p]; !ok || length > old.length {
						hits[p] = Hit{length, ph.why}
					}
				}
				p += length
			}
		}
	}
	positions, _ := slice.map_keys(hits, a)
	defer delete(positions, a)
	slice.sort(positions)
	for p in positions {
		h := hits[p]
		strings.builder_reset(&r.msg)
		strings.write_string(&r.msg, "\u201c")
		for c in r.src[p:min(p + h.length, n)] {
			strings.write_rune(&r.msg, c)
		}
		fmt.sbprintf(&r.msg, "\u201d reads as machine prose. %s", h.why)
		add(r, p, .Warning, "AI-PHRASE", strings.to_string(r.msg), "", h.length)
	}

	glue := make([dynamic]int, a)
	defer delete(glue)
	for w in DE_GLUE_WORDS {
		length := utf8.rune_count_in_string(w)
		for p := 0; p < len(lowered); {
			if literal_at(lowered, p, w) < 0 {
				p += 1
				continue
			}
			if p < n && !r.m.is_markup[p] && lang_at(r, p) == "de" {
				append(&glue, p)
			}
			p += length
		}
	}
	if len(glue) >= 3 {
		slice.sort(glue[:])
		for p in glue[2:] {
			add(
				r,
				p,
				.Warning,
				"DE-GLUE",
				msgf(r, "%d additive connectives in one document. Used this often they stop connecting and start padding.", len(glue)),
				"drop it, or replace with a real logical link",
			)
		}
	}
}

// py_lower lowercases `src` as far as Python's `str.lower()` matters to the
// phrase lists: ASCII and the German capitals, the capital sharp s, and the
// Kelvin sign (which lowers to "k"). No other code point lowers to a
// character of a phrase, so the rest are kept as they are. The result has
// one code point per code point of `src`, so an offset in it is an offset in
// the source. Python lowers the dotted capital I to two code points, which
// shifted every later hit in the reference (a reference bug); here it lowers
// to "i" alone. The caller frees the result with `delete`.
@(private = "file")
py_lower :: proc(src: []rune, allocator := context.allocator) -> []rune {
	out := make([dynamic]rune, 0, len(src), allocator)
	for c in src {
		switch c {
		case 'A' ..= 'Z', '\u00c4', '\u00d6', '\u00dc':
			append(&out, c + 32)
		case '\u1e9e':
			append(&out, '\u00df')
		case '\u212a':
			append(&out, 'k')
		case '\u0130':
			append(&out, 'i')
		case:
			append(&out, c)
		}
	}
	return out[:]
}
