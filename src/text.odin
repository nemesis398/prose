package prose

import "core:strings"

// Positions in a source text. All offsets are in code points into a `[]rune`,
// like the reference's `str` indices, so line and column match it exactly.

// line_index returns the offset at which each line starts: 0, then one past
// every "\n". The caller frees the slice with `delete`.
line_index :: proc(src: []rune, allocator := context.allocator) -> []int {
	starts := make([dynamic]int, allocator)
	append(&starts, 0)
	for r, i in src {
		if r == '\n' {
			append(&starts, i + 1)
		}
	}
	return starts[:]
}

// to_line_col maps an offset to a 1-based line and a 1-based column in code
// points. `starts` is the result of `line_index`.
to_line_col :: proc(starts: []int, offset: int) -> (line, col: int) {
	lo, hi := 0, len(starts) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if starts[mid] <= offset {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo + 1, offset - starts[lo] + 1
}

// is_py_space is true for what Python's `str.strip()` strips, which is also
// what its `re` matches with `\s`.
is_py_space :: proc(r: rune) -> bool {
	switch r {
	case 0x09 ..= 0x0D, 0x1C ..= 0x20, 0x85, 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
		return true
	}
	return false
}

// excerpt_at returns a one-line excerpt around `offset`: `width` code points
// before it and `length` plus `width` after it, never across a line break,
// stripped of white space, and with an ellipsis (U+2026) on each side where
// it was cut. The result is UTF-8 in a new string the caller frees. If the
// allocator fails the excerpt is "" rather than a cut one.
excerpt_at :: proc(
	src: []rune,
	offset: int,
	length := 1,
	width := 34,
	allocator := context.allocator,
) -> string {
	off := clamp(offset, 0, len(src))
	line_lo := 0
	for i := off - 1; i >= 0; i -= 1 {
		if src[i] == '\n' {
			line_lo = i + 1
			break
		}
	}
	line_hi := len(src)
	for i in off ..< len(src) {
		if src[i] == '\n' {
			line_hi = i
			break
		}
	}
	lo := max(line_lo, off - width)
	hi := min(line_hi, off + length + width)
	body := src[lo:hi] if lo < hi else src[:0]
	for len(body) > 0 && is_py_space(body[0]) {
		body = body[1:]
	}
	for len(body) > 0 && is_py_space(body[len(body) - 1]) {
		body = body[:len(body) - 1]
	}
	text := runes_to_string(body, allocator)
	if text == "" && len(body) > 0 {
		return ""
	}
	pre := "\u2026" if lo > line_lo else ""
	post := "\u2026" if hi < line_hi else ""
	if pre == "" && post == "" {
		return text
	}
	defer delete(text, allocator)
	out, err := strings.concatenate({pre, text, post}, allocator)
	if err != nil {
		return ""
	}
	return out
}

// table_rows returns the 1-based numbers of the lines that are markdown table
// rows: a line with two or more "|" that starts with one, or any line with
// three or more. Cell padding in an aligned table is layout, so the
// whitespace rules leave those lines alone. `is_markup` is unused, as in the
// reference. The caller frees the set with `delete`.
table_rows :: proc(
	src: []rune,
	is_markup: []bool,
	allocator := context.allocator,
) -> map[int]struct{} {
	rows := make(map[int]struct{}, allocator)
	n := 1
	start := 0
	for i in 0 ..= len(src) {
		if i == len(src) || src[i] == '\n' {
			line := src[start:i]
			bars := 0
			for r in line {
				if r == '|' {
					bars += 1
				}
			}
			first := 0
			for first < len(line) && is_py_space(line[first]) {
				first += 1
			}
			leads := first < len(line) && line[first] == '|'
			if (bars >= 2 && leads) || bars >= 3 {
				rows[n] = {}
			}
			n += 1
			start = i + 1
		}
	}
	return rows
}
