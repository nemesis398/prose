package prose

// LanguageTool runs on the JVM, so the offsets it returns count UTF-16 code
// units, not code points. Every code point above U+FFFF counts twice.

// utf16_prefix returns `len(src) + 1` entries: entry i is the UTF-16 offset
// of code point i, and the last entry is the UTF-16 length of `src`.
// The caller frees the slice with `delete`.
utf16_prefix :: proc(src: []rune, allocator := context.allocator) -> []int {
	out := make([]int, len(src) + 1, allocator)
	total := 0
	for r, i in src {
		total += 2 if r > 0xFFFF else 1
		out[i + 1] = total
	}
	return out
}

// utf16_to_codepoint maps a UTF-16 offset to a code point offset: the first
// code point whose prefix is at least `u16_offset`, capped at the last entry.
// An offset in the middle of a surrogate pair maps to the code point after
// it, as the reference's `bisect_left` does.
utf16_to_codepoint :: proc(prefix: []int, u16_offset: int) -> int {
	lo, hi := 0, len(prefix)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if prefix[mid] < u16_offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return min(lo, len(prefix) - 1)
}
