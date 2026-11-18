package prose

import "base:runtime"
import "core:slice"
import "core:strings"

// Markdown masking. Every later rule and the LanguageTool pass see the text
// only through this mask: code, links, URLs, tags and markup are marked so
// that no rule fires on them and LanguageTool reads them as markup. It is a
// port of the reference's `_MASK_PATTERNS` and `mask_markdown`, quirks
// included, so that every finding lands where the reference put it.
//
// The reference runs 23 regular expressions in order. Each one finds its
// matches left to right without overlap, as `re.finditer` does, and a match
// claims its range only when no earlier pattern claimed any of it; a match
// that loses still moves that pattern's search past it. Each pattern here is
// a hand-written scanner that answers "does the expression match at p, and
// where does the match end", with Python's backtracking worked out per
// pattern, on code points, with Python's `\s`, `\w` and `\d`.

Segment_Kind :: enum {
	Text,
	Markup,
}

// Segment is one stretch of the source: prose, or one masked construct.
// `plain_text` is the prose itself, or what LanguageTool should read in place
// of the construct ("" for nothing). `suppress` drops LanguageTool's reports
// inside it, as for code and links, whose spelling the user cannot fix.
Segment :: struct {
	kind:       Segment_Kind,
	orig_start: int,
	orig_len:   int,
	plain_text: string,
	suppress:   bool,
}

// Masked is the masked source. `src` is the caller's and is not freed; the
// rest is owned and freed by `masked_destroy`. `is_markup` and `suppress`
// hold one flag per code point of `src`.
Masked :: struct {
	src:       []rune,
	segments:  [dynamic]Segment,
	is_markup: []bool,
	suppress:  []bool,
}

// Annotation is one item of LanguageTool's `data.annotation` list: `text`
// when `is_markup` is false, else `markup` with `interpret_as` ("" when the
// reference leaves `interpretAs` out).
Annotation :: struct {
	text, markup, interpret_as: string,
	is_markup:                  bool,
}

// The reference's patterns, in its order. Two of them share the kind `url`
// and two the kind `emph`; the kind only decides suppression.
@(private = "file")
Pattern :: enum u8 {
	Frontmatter,
	Fence,
	Comment,
	Htmlblock,
	Math,
	Codespan,
	Wikilink,
	Linktarget,
	Linkopen,
	Url_Angle,
	Html,
	Url_Bare,
	Tablerule,
	Hrule,
	Headmark,
	Quotemark,
	Listmark,
	Footnote,
	Tag,
	Emph_Double,
	Emph_Single,
	Pipe,
	Strayticks,
}

// What LanguageTool reads in place of a match. Code spans and wikilinks
// keep a part of themselves instead (the reference's "KEEP").
@(private = "file", rodata)
INTERPRET := [Pattern]string {
	.Frontmatter = "\n\n",
	.Fence       = "\n\n",
	.Comment     = "",
	.Htmlblock   = "\n\n",
	.Math        = "X",
	.Codespan    = "",
	.Wikilink    = "",
	.Linktarget  = "",
	.Linkopen    = "",
	.Url_Angle   = "X",
	.Html        = "",
	.Url_Bare    = "X",
	.Tablerule   = "\n",
	.Hrule       = "\n",
	.Headmark    = "",
	.Quotemark   = "",
	.Listmark    = "",
	.Footnote    = "",
	.Tag         = "X",
	.Emph_Double = "",
	.Emph_Single = "",
	.Pipe        = "\n",
	.Strayticks  = "",
}

// The reference's `_SUPPRESS_KINDS`. A `<style>` block, a link target and
// markup such as a list marker are not among them.
@(private = "file", rodata)
SUPPRESS := #partial [Pattern]bool {
	.Frontmatter = true,
	.Fence       = true,
	.Comment     = true,
	.Math        = true,
	.Codespan    = true,
	.Wikilink    = true,
	.Url_Angle   = true,
	.Html        = true,
	.Url_Bare    = true,
	.Tag         = true,
}

@(private = "file")
Match :: struct {
	start, end:       int,
	pattern:          Pattern,
	// The kept part of a code span or wikilink; keep_lo < 0 for the literal.
	keep_lo, keep_hi: int,
}

@(private = "file")
Link_Frame :: struct {
	pos:  int,
	next: u8,
}

// Scratch for the link target's backtracking search. `seen` is 8 bytes per
// rune, so it is allocated by the first link target and not before.
@(private = "file")
Scan_State :: struct {
	stack:     [dynamic]Link_Frame,
	seen:      []int,
	stamp:     int,
	size:      int,
	allocator: runtime.Allocator,
}

// mask_markdown masks `src`. The result borrows `src`, which must outlive
// it; everything else in it is allocated with `allocator` and freed by
// `masked_destroy`.
mask_markdown :: proc(src: []rune, allocator := context.allocator) -> Masked {
	n := len(src)
	m := Masked {
		src       = src,
		segments  = make([dynamic]Segment, allocator),
		is_markup = make([]bool, n, allocator),
		suppress  = make([]bool, n, allocator),
	}

	matches := make([dynamic]Match, allocator)
	defer delete(matches)
	st := Scan_State {
		stack     = make([dynamic]Link_Frame, allocator),
		size      = n + 1,
		allocator = allocator,
	}
	defer delete(st.stack)
	defer delete(st.seen, allocator) // nil when the text has no link target

	for pat in Pattern {
		p := 0
		for p < n {
			end, keep_lo, keep_hi, ok := scan(pat, src, p, &st)
			if !ok {
				p += 1
				continue
			}
			// A scanner that matched but did not advance would loop forever.
			assert(end > p, "a mask scanner matched without advancing")
			free := true
			for i in p ..< end {
				if m.is_markup[i] {
					free = false
					break
				}
			}
			if free {
				for i in p ..< end {
					m.is_markup[i] = true
					m.suppress[i] = SUPPRESS[pat]
				}
				append(&matches, Match{p, end, pat, keep_lo, keep_hi})
			}
			p = end
		}
	}

	slice.sort_by(matches[:], proc(a, b: Match) -> bool {return a.start < b.start})
	pos := 0
	for mt in matches {
		if mt.start > pos {
			text := runes_to_string(src[pos:mt.start], allocator)
			append(&m.segments, Segment{.Text, pos, mt.start - pos, text, false})
		}
		plain := ""
		if mt.keep_lo >= 0 {
			plain = runes_to_string(src[mt.keep_lo:mt.keep_hi], allocator)
		} else if INTERPRET[mt.pattern] != "" {
			plain = strings.clone(INTERPRET[mt.pattern], allocator)
		}
		append(&m.segments, Segment{.Markup, mt.start, mt.end - mt.start, plain, SUPPRESS[mt.pattern]})
		pos = mt.end
	}
	if pos < n {
		append(&m.segments, Segment{.Text, pos, n - pos, runes_to_string(src[pos:], allocator), false})
	}
	return m
}

// masked_destroy frees what `mask_markdown` allocated, not `m.src`. It takes
// no allocator because `m.segments`, a dynamic array, carries the one it was
// built with; `annotations_destroy` frees a plain slice, which carries none,
// and so takes the allocator again.
masked_destroy :: proc(m: ^Masked) {
	allocator := m.segments.allocator
	for s in m.segments {
		delete(s.plain_text, allocator)
	}
	delete(m.segments)
	delete(m.is_markup, allocator)
	delete(m.suppress, allocator)
	m^ = {}
}

// annotations_for returns the annotations covering `src[lo:hi]`, clipped at
// the boundaries. A markup segment keeps its interpretation only when it lies
// whole inside the span, since a cut one would describe text that is no
// longer all there. Every string is a copy; free the result with
// `annotations_destroy`.
annotations_for :: proc(m: ^Masked, lo, hi: int, allocator := context.allocator) -> []Annotation {
	out := make([dynamic]Annotation, allocator)
	for s in m.segments {
		s_lo, s_hi := s.orig_start, s.orig_start + s.orig_len
		if s_hi <= lo || s_lo >= hi {
			continue
		}
		clip_lo, clip_hi := max(s_lo, lo), min(s_hi, hi)
		if clip_lo >= clip_hi {
			continue
		}
		piece := runes_to_string(m.src[clip_lo:clip_hi], allocator)
		if s.kind == .Text {
			append(&out, Annotation{text = piece})
			continue
		}
		a := Annotation {
			markup    = piece,
			is_markup = true,
		}
		if s.plain_text != "" && clip_lo == s_lo && clip_hi == s_hi {
			a.interpret_as = strings.clone(s.plain_text, allocator)
		}
		append(&out, a)
	}
	return out[:]
}

// annotations_destroy frees what `annotations_for` returned. Pass the
// allocator `annotations_for` was given.
annotations_destroy :: proc(anns: []Annotation, allocator := context.allocator) {
	for a in anns {
		delete(a.text, allocator)
		delete(a.markup, allocator)
		delete(a.interpret_as, allocator)
	}
	delete(anns, allocator)
}

// suppressed reports whether a LanguageTool match at `offset` with `length`
// code points touches a suppressed rune. A zero length still looks at one.
suppressed :: proc(m: ^Masked, offset, length: int) -> bool {
	hi := min(len(m.src), offset + max(length, 1))
	for i in max(0, offset) ..< hi {
		if m.suppress[i] {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The scanners. Each comment names the reference's expression. `^` and `$`
// are multiline where the reference passes re.M: a line start is 0 or after
// "\n", a line end is before "\n" or the end of the text.
// ---------------------------------------------------------------------------

@(private = "file")
scan :: proc(pat: Pattern, src: []rune, p: int, st: ^Scan_State) -> (end, keep_lo, keep_hi: int, ok: bool) {
	keep_lo, keep_hi = -1, -1
	switch pat {
	case .Frontmatter:
		end, ok = scan_frontmatter(src, p)
	case .Fence:
		end, ok = scan_fence(src, p)
	case .Comment:
		end, ok = scan_comment(src, p)
	case .Htmlblock:
		end, ok = scan_htmlblock(src, p)
	case .Math:
		end, ok = scan_math(src, p)
	case .Codespan:
		end, ok = scan_codespan(src, p)
		keep_lo, keep_hi = p + 1, end - 1
	case .Wikilink:
		end, keep_lo, keep_hi, ok = scan_wikilink(src, p)
	case .Linktarget:
		end, ok = scan_linktarget(src, p, st)
	case .Linkopen:
		end, ok = scan_linkopen(src, p)
	case .Url_Angle:
		end, ok = scan_url_angle(src, p)
	case .Html:
		end, ok = scan_html(src, p)
	case .Url_Bare:
		end, ok = scan_url_bare(src, p)
	case .Tablerule:
		end, ok = scan_tablerule(src, p)
	case .Hrule:
		end, ok = scan_hrule(src, p)
	case .Headmark:
		end, ok = scan_headmark(src, p)
	case .Quotemark:
		end, ok = scan_quotemark(src, p)
	case .Listmark:
		end, ok = scan_listmark(src, p)
	case .Footnote:
		end, ok = scan_footnote(src, p)
	case .Tag:
		end, ok = scan_tag(src, p)
	case .Emph_Double:
		end, ok = scan_emph_double(src, p)
	case .Emph_Single:
		end, ok = scan_emph_single(src, p)
	case .Pipe:
		end, ok = p + 1, src[p] == '|'
	case .Strayticks:
		end, ok = scan_strayticks(src, p)
	}
	return
}

// `\A---\n.*?\n---\n` (dotall)
@(private = "file")
scan_frontmatter :: proc(src: []rune, p: int) -> (int, bool) {
	if p != 0 || !has_prefix(src, 0, "---\n") {
		return 0, false
	}
	k := find(src, 4, "\n---\n")
	return k + 5, k >= 0
}

// `^(?: {0,3})(```|~~~).*?^(?: {0,3})\1[^\n]*$` (multiline, dotall): an
// opening line with at most three spaces of indent, up to the first later
// line that opens with the same delimiter, through the end of that line.
@(private = "file")
scan_fence :: proc(src: []rune, p: int) -> (int, bool) {
	if !at_line_start(src, p) {
		return 0, false
	}
	d, body := fence_delimiter(src, p)
	if d == 0 {
		return 0, false
	}
	for k in body ..< len(src) {
		if src[k] != '\n' {
			continue
		}
		if c, after := fence_delimiter(src, k + 1); c == d {
			e := after
			for e < len(src) && src[e] != '\n' {
				e += 1
			}
			return e, true
		}
	}
	return 0, false
}

// fence_delimiter reads ` {0,3}(```|~~~)` at `p` and returns the delimiter's
// character (0 for none) and the offset after it.
@(private = "file")
fence_delimiter :: proc(src: []rune, p: int) -> (rune, int) {
	i := p
	for i < len(src) && i - p < 3 && src[i] == ' ' {
		i += 1
	}
	if i + 3 > len(src) {
		return 0, 0
	}
	d := src[i]
	if (d != '`' && d != '~') || src[i + 1] != d || src[i + 2] != d {
		return 0, 0
	}
	return d, i + 3
}

// `<!--.*?-->` (dotall)
@(private = "file")
scan_comment :: proc(src: []rune, p: int) -> (int, bool) {
	if !has_prefix(src, p, "<!--") {
		return 0, false
	}
	k := find(src, p + 4, "-->")
	return k + 3, k >= 0
}

// `<(style|script)\b[^>]*>.*?</\1>` (dotall, ignorecase). Python's ignorecase
// lets `s` match U+017F and `i` match U+0130 and U+0131, while the
// backreference compares simple lowercase, where U+0130 is `i` and U+017F and
// U+0131 are only themselves.
@(private = "file")
scan_htmlblock :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '<' {
		return 0, false
	}
	name: string
	for cand in ([]string{"style", "script"}) {
		if p + 1 + len(cand) > n {
			continue
		}
		matched := true
		for i in 0 ..< len(cand) {
			if !ignorecase_is(src[p + 1 + i], rune(cand[i])) {
				matched = false
				break
			}
		}
		if matched {
			name = cand
			break
		}
	}
	if name == "" {
		return 0, false
	}
	k := p + 1 + len(name)
	if k < n && is_py_word(src[k]) {
		return 0, false
	}
	for k < n && src[k] != '>' {
		k += 1
	}
	if k == n {
		return 0, false
	}
	group := src[p + 1:p + 1 + len(name)]
	for q in k + 1 ..< n {
		if src[q] != '<' || q + 3 + len(name) > n || src[q + 1] != '/' || src[q + 2 + len(name)] != '>' {
			continue
		}
		same := true
		for g, i in group {
			if simple_lower(g) != simple_lower(src[q + 2 + i]) {
				same = false
				break
			}
		}
		if same {
			return q + 3 + len(name), true
		}
	}
	return 0, false
}

// ignorecase_is reports whether `r` matches the lowercase ASCII letter `want`
// under Python's re.IGNORECASE.
@(private = "file")
ignorecase_is :: proc(r: rune, want: rune) -> bool {
	switch {
	case r == want || r == want - 32:
		return true
	case want == 's':
		return r == 0x17F
	case want == 'i':
		return r == 0x130 || r == 0x131
	}
	return false
}

// simple_lower is Python's simple lowercase mapping on the runes that can
// reach it from `ignorecase_is`.
@(private = "file")
simple_lower :: proc(r: rune) -> rune {
	switch {
	case 'A' <= r && r <= 'Z':
		return r + 32
	case r == 0x130:
		return 'i'
	}
	return r
}

// `\$\$.*?\$\$` (dotall)
@(private = "file")
scan_math :: proc(src: []rune, p: int) -> (int, bool) {
	if !has_prefix(src, p, "$$") {
		return 0, false
	}
	k := find(src, p + 2, "$$")
	return k + 2, k >= 0
}

// `` `[^`\n]*(?:\n[^`\n]*)?` ``: a code span over at most one line break.
@(private = "file")
scan_codespan :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '`' {
		return 0, false
	}
	a := p + 1
	for a < n && src[a] != '`' && src[a] != '\n' {
		a += 1
	}
	if a == n {
		return 0, false
	}
	if src[a] == '`' {
		return a + 1, true
	}
	b := a + 1
	for b < n && src[b] != '`' && src[b] != '\n' {
		b += 1
	}
	if b < n && src[b] == '`' {
		return b + 1, true
	}
	return 0, false
}

// `!?\[\[([^\]|]*)(?:\|([^\]]*))?\]\]`. It keeps the target when it is not
// empty, else the alias when that is not empty, else the whole match.
@(private = "file")
scan_wikilink :: proc(src: []rune, p: int) -> (end, keep_lo, keep_hi: int, ok: bool) {
	n := len(src)
	b := p + 1 if src[p] == '!' else p
	if !has_prefix(src, b, "[[") {
		return
	}
	a := b + 2
	for a < n && src[a] != ']' && src[a] != '|' {
		a += 1
	}
	if a == n {
		return
	}
	keep_lo, keep_hi = b + 2, a
	alias_lo, alias_hi := -1, -1
	if src[a] == '|' {
		c := a + 1
		for c < n && src[c] != ']' {
			c += 1
		}
		if c == n {
			return
		}
		alias_lo, alias_hi = a + 1, c
		a = c
	}
	if a + 1 >= n || src[a + 1] != ']' {
		return
	}
	end = a + 2
	if keep_lo == keep_hi {
		if alias_lo >= 0 && alias_lo < alias_hi {
			keep_lo, keep_hi = alias_lo, alias_hi
		} else {
			keep_lo, keep_hi = p, end
		}
	}
	return end, keep_lo, keep_hi, true
}

// `(?<!\\)\]\((?:\\.|[^)\s])*(?:\s+\"[^\"]*\")?\)`. The body's two
// alternatives overlap on a backslash, and Python backtracks through them:
// when the greedy body finds no closing paren, the match may end at an
// escaped `\)` after all. This is that search, depth first in Python's order
// (escape, then single rune, then stop), skipping offsets already tried.
@(private = "file")
scan_linktarget :: proc(src: []rune, p: int, st: ^Scan_State) -> (int, bool) {
	n := len(src)
	if src[p] != ']' || p + 1 >= n || src[p + 1] != '(' || (p > 0 && src[p - 1] == '\\') {
		return 0, false
	}
	if st.seen == nil {
		st.seen = make([]int, st.size, st.allocator)
	}
	st.stamp += 1
	clear(&st.stack)
	st.seen[p + 2] = st.stamp
	append(&st.stack, Link_Frame{p + 2, 0})
	for len(st.stack) > 0 {
		f := &st.stack[len(st.stack) - 1]
		y := f.pos
		switch f.next {
		case 0:
			f.next = 1
			if y + 1 < n && src[y] == '\\' && src[y + 1] != '\n' && st.seen[y + 2] != st.stamp {
				st.seen[y + 2] = st.stamp
				append(&st.stack, Link_Frame{y + 2, 0})
			}
		case 1:
			f.next = 2
			if y < n && src[y] != ')' && !is_py_space(src[y]) && st.seen[y + 1] != st.stamp {
				st.seen[y + 1] = st.stamp
				append(&st.stack, Link_Frame{y + 1, 0})
			}
		case:
			if end, ok := linktarget_tail(src, y); ok {
				return end, true
			}
			pop(&st.stack)
		}
	}
	return 0, false
}

// `(?:\s+\"[^\"]*\")?\)` at `y`.
@(private = "file")
linktarget_tail :: proc(src: []rune, y: int) -> (int, bool) {
	n := len(src)
	if y < n && is_py_space(src[y]) {
		w := spaces_end(src, y)
		if w < n && src[w] == '"' {
			q := w + 1
			for q < n && src[q] != '"' {
				q += 1
			}
			if q + 1 < n && src[q + 1] == ')' {
				return q + 2, true
			}
		}
	}
	if y < n && src[y] == ')' {
		return y + 1, true
	}
	return 0, false
}

// `!?\[(?=[^\]]*\]\()`: an opening bracket whose first closing one is
// followed by a paren.
@(private = "file")
scan_linkopen :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	b := p
	if src[p] == '!' {
		if p + 1 >= n || src[p + 1] != '[' {
			return 0, false
		}
		b = p + 1
	} else if src[p] != '[' {
		return 0, false
	}
	k := b + 1
	for k < n && src[k] != ']' {
		k += 1
	}
	return b + 1, k + 1 < n && src[k + 1] == '('
}

// scheme_end reads `https?://` at `p` and returns the offset after it, or -1.
@(private = "file")
scheme_end :: proc(src: []rune, p: int) -> int {
	if !has_prefix(src, p, "http") {
		return -1
	}
	i := p + 4
	if i < len(src) && src[i] == 's' {
		i += 1
	}
	return i + 3 if has_prefix(src, i, "://") else -1
}

// `<https?://[^>\s]+>`
@(private = "file")
scan_url_angle :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '<' {
		return 0, false
	}
	i := scheme_end(src, p + 1)
	if i < 0 {
		return 0, false
	}
	j := i
	for j < n && src[j] != '>' && !is_py_space(src[j]) {
		j += 1
	}
	return j + 1, j > i && j < n && src[j] == '>'
}

// `<\/?[a-zA-Z][^>]*>`, which may span lines.
@(private = "file")
scan_html :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '<' {
		return 0, false
	}
	i := p + 1
	if i < n && src[i] == '/' {
		i += 1
	}
	if i >= n || !is_ascii_letter(src[i]) {
		return 0, false
	}
	k := i + 1
	for k < n && src[k] != '>' {
		k += 1
	}
	return k + 1, k < n
}

// `https?://(?:[^\s()\[\]]|\([^\s()]*\)|\[[^\s\[\]]*\])*` then one of
// `[^\s.,;:!?()\[\]{}<>'\"]|\([^\s()]*\)|\[[^\s\[\]]*\]`. The body's pieces
// are a rune or a balanced `(…)` or `[…]`; backtracking ends the match after
// the last piece that may also end it, which is any group, or a rune that is
// not trailing punctuation.
@(private = "file")
scan_url_bare :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	x := scheme_end(src, p)
	if x < 0 {
		return 0, false
	}
	last := -1
	loop: for x < n {
		c := src[x]
		if is_py_space(c) {
			break
		}
		switch c {
		case '(', '[':
			close: rune = ')' if c == '(' else ']'
			k := x + 1
			for k < n && src[k] != c && src[k] != close && !is_py_space(src[k]) {
				k += 1
			}
			if k == n || src[k] != close {
				break loop
			}
			x = k + 1
			last = x
		case ')', ']':
			break loop
		case:
			x += 1
			if !strings.contains_rune(".,;:!?{}<>'\"", c) {
				last = x
			}
		}
	}
	return last, last >= 0
}

// line_end_before returns the last line end (`$`) at or before `r`: `r` when
// it is the end of the text, else the last "\n" in `src[p:r]`, or -1.
@(private = "file")
line_end_before :: proc(src: []rune, p, r: int) -> int {
	if r == len(src) {
		return r
	}
	for k := r - 1; k >= p; k -= 1 {
		if src[k] == '\n' {
			return k
		}
	}
	return -1
}

// `^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$` (multiline). Every piece is white
// space, `:`, `|` or `-`, and `\s` takes "\n", so the match runs from a line
// start over the whole run of those runes to the last line end in it, and
// needs `---` before that end. From a blank line it takes the blank line too.
@(private = "file")
scan_tablerule :: proc(src: []rune, p: int) -> (int, bool) {
	if !at_line_start(src, p) {
		return 0, false
	}
	r := p
	for r < len(src) && (is_py_space(src[r]) || src[r] == ':' || src[r] == '|' || src[r] == '-') {
		r += 1
	}
	e := line_end_before(src, p, r)
	if e < 0 {
		return 0, false
	}
	run := 0
	for k in p ..< e {
		run = run + 1 if src[k] == '-' else 0
		if run == 3 {
			return e, true
		}
	}
	return 0, false
}

// `^\s*(?:[-*_]\s*){3,}$` (multiline): like the table rule, over white space
// and `-`, `*`, `_`, with three of those before the last line end.
@(private = "file")
scan_hrule :: proc(src: []rune, p: int) -> (int, bool) {
	if !at_line_start(src, p) {
		return 0, false
	}
	r := p
	for r < len(src) && (is_py_space(src[r]) || src[r] == '-' || src[r] == '*' || src[r] == '_') {
		r += 1
	}
	e := line_end_before(src, p, r)
	if e < 0 {
		return 0, false
	}
	marks := 0
	for k in p ..< e {
		if !is_py_space(src[k]) {
			marks += 1
		}
	}
	return e, marks >= 3
}

// `^#{1,6}[ \t]+` (multiline)
@(private = "file")
scan_headmark :: proc(src: []rune, p: int) -> (int, bool) {
	if !at_line_start(src, p) {
		return 0, false
	}
	k := p
	for k < len(src) && src[k] == '#' {
		k += 1
	}
	if k == p || k - p > 6 {
		return 0, false
	}
	j := blanks_end(src, k)
	return j, j > k
}

// `^\s*>[ \t]?` (multiline); the white space may span blank lines.
@(private = "file")
scan_quotemark :: proc(src: []rune, p: int) -> (int, bool) {
	if !at_line_start(src, p) {
		return 0, false
	}
	w := spaces_end(src, p)
	if w == len(src) || src[w] != '>' {
		return 0, false
	}
	end := w + 1
	if end < len(src) && (src[end] == ' ' || src[end] == '\t') {
		end += 1
	}
	return end, true
}

// `^\s*(?:[-*+]|\d{1,3}[.)])[ \t]+(?:\[[ xX~/-]\][ \t]+)?` (multiline)
@(private = "file")
scan_listmark :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if !at_line_start(src, p) {
		return 0, false
	}
	w := spaces_end(src, p)
	if w == n {
		return 0, false
	}
	x: int
	if src[w] == '-' || src[w] == '*' || src[w] == '+' {
		x = w + 1
	} else {
		k := w
		for k < n && is_py_decimal(src[k]) {
			k += 1
		}
		if k == w || k - w > 3 || k == n || (src[k] != '.' && src[k] != ')') {
			return 0, false
		}
		x = k + 1
	}
	y := blanks_end(src, x)
	if y == x {
		return 0, false
	}
	if y + 3 < n && src[y] == '[' && strings.contains_rune(" xX~/-", src[y + 1]) && src[y + 2] == ']' &&
	   (src[y + 3] == ' ' || src[y + 3] == '\t') {
		return blanks_end(src, y + 3), true
	}
	return y, true
}

// `\[\^[^\]]+\]:?`
@(private = "file")
scan_footnote :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if !has_prefix(src, p, "[^") {
		return 0, false
	}
	k := p + 2
	for k < n && src[k] != ']' {
		k += 1
	}
	if k == n || k == p + 2 {
		return 0, false
	}
	end := k + 1
	if end < n && src[end] == ':' {
		end += 1
	}
	return end, true
}

// `(?<!\w)#[A-Za-zÄÖÜäöüß][\w/-]*`
@(private = "file")
scan_tag :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '#' || (p > 0 && is_py_word(src[p - 1])) || p + 1 >= n {
		return 0, false
	}
	c := src[p + 1]
	if !is_ascii_letter(c) && !strings.contains_rune("ÄÖÜäöüß", c) {
		return 0, false
	}
	j := p + 2
	for j < n && (is_py_word(src[j]) || src[j] == '/' || src[j] == '-') {
		j += 1
	}
	return j, true
}

// `\*\*|__|~~`
@(private = "file")
scan_emph_double :: proc(src: []rune, p: int) -> (int, bool) {
	c := src[p]
	return p + 2, (c == '*' || c == '_' || c == '~') && p + 1 < len(src) && src[p + 1] == c
}

// `(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)`
@(private = "file")
scan_emph_single :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	c := src[p]
	if c != '*' && c != '_' {
		return 0, false
	}
	opens := (p == 0 || !is_py_word(src[p - 1])) && p + 1 < n && !is_py_space(src[p + 1])
	closes := p > 0 && !is_py_space(src[p - 1]) && (p + 1 >= n || !is_py_word(src[p + 1]))
	return p + 1, opens || closes
}

// `` `[^`\n]*$ `` (multiline): a backtick with no other one on the rest of
// its line.
@(private = "file")
scan_strayticks :: proc(src: []rune, p: int) -> (int, bool) {
	n := len(src)
	if src[p] != '`' {
		return 0, false
	}
	x := p + 1
	for x < n && src[x] != '`' && src[x] != '\n' {
		x += 1
	}
	return x, x == n || src[x] == '\n'
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

@(private = "file")
at_line_start :: #force_inline proc(src: []rune, p: int) -> bool {
	return p == 0 || src[p - 1] == '\n'
}

// has_prefix reports whether the ASCII `lit` occurs in `src` at `p`.
@(private = "file")
has_prefix :: proc(src: []rune, p: int, lit: string) -> bool {
	if p < 0 || p + len(lit) > len(src) {
		return false
	}
	for i in 0 ..< len(lit) {
		if src[p + i] != rune(lit[i]) {
			return false
		}
	}
	return true
}

// find returns the first offset at or after `from` where the ASCII `lit`
// occurs, or -1.
@(private = "file")
find :: proc(src: []rune, from: int, lit: string) -> int {
	for k := from; k + len(lit) <= len(src); k += 1 {
		if has_prefix(src, k, lit) {
			return k
		}
	}
	return -1
}

// spaces_end returns the end of the run of `\s` from `p`.
@(private = "file")
spaces_end :: proc(src: []rune, p: int) -> int {
	i := p
	for i < len(src) && is_py_space(src[i]) {
		i += 1
	}
	return i
}

// blanks_end returns the end of the run of `[ \t]` from `p`.
@(private = "file")
blanks_end :: proc(src: []rune, p: int) -> int {
	i := p
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	return i
}

@(private = "file")
is_ascii_letter :: proc(r: rune) -> bool {
	return ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z')
}

// is_py_word is Python's `\w` on a `str`.
is_py_word :: proc(r: rune) -> bool {
	if r < 0x80 {
		return is_ascii_letter(r) || ('0' <= r && r <= '9') || r == '_'
	}
	return in_ranges(r, PY_WORD_RANGES[:])
}

// is_py_decimal is Python's `\d` on a `str`.
is_py_decimal :: proc(r: rune) -> bool {
	if r < 0x80 {
		return '0' <= r && r <= '9'
	}
	return in_ranges(r, PY_DECIMAL_RANGES[:])
}

@(private = "file")
in_ranges :: proc(r: rune, ranges: [][2]rune) -> bool {
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		switch {
		case r < ranges[mid][0]:
			hi = mid
		case r > ranges[mid][1]:
			lo = mid + 1
		case:
			return true
		}
	}
	return false
}
