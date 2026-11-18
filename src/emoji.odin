package prose

import "core:unicode/utf8"

// Emoji is one emoji as the reader sees it: a flag or a joined family is one
// Emoji, not several. `offset` is in code points. `cluster` is UTF-8 and is
// owned by the Emoji; free the slice with `emoji_destroy`.
Emoji :: struct {
	offset:  int,
	cluster: string,
}

// Arrows (U+2190..U+21FF) are deliberately not emoji: arrows are prose
// punctuation. The ranges, © ® and ™ included, are the reference's.
@(private = "file")
EMOJI_RANGES := [?][2]rune {
	{0x1F000, 0x1FAFF},
	{0x1F1E6, 0x1F1FF},
	{0x2600, 0x26FF},
	{0x2700, 0x27BF},
	{0x2B00, 0x2BFF},
	{0x231A, 0x231B},
	{0x23E9, 0x23FA},
	{0x2049, 0x2049},
	{0x203C, 0x203C},
	{0x00A9, 0x00A9},
	{0x00AE, 0x00AE},
	{0x2122, 0x2122},
}

is_emoji_rune :: proc(r: rune) -> bool {
	for rng in EMOJI_RANGES {
		if rng[0] <= r && r <= rng[1] {
			return true
		}
	}
	return false
}

@(private = "file")
is_regional :: proc(r: rune) -> bool {
	return 0x1F1E6 <= r && r <= 0x1F1FF
}

// A zero-width joiner, a variation selector and the keycap mark.
@(private = "file")
is_emoji_joiner :: proc(r: rune) -> bool {
	return r == 0x200D || r == 0xFE0F || r == 0xFE0E || r == 0x20E3
}

// A skin-tone modifier, the five Fitzpatrick types.
@(private = "file")
is_skin_tone :: proc(r: rune) -> bool {
	return 0x1F3FB <= r && r <= 0x1F3FF
}

// The base of a keycap: a digit, "#" or "*". None is in an emoji range.
@(private = "file")
is_keycap_base :: proc(r: rune) -> bool {
	return ('0' <= r && r <= '9') || r == '#' || r == '*'
}

// keycap_length is how many code points the keycap at `src[0]` takes: the
// base, U+FE0F and U+20E3 (3), or 0. UTS #51 makes only that sequence a
// keycap; a base with U+20E3 alone is unqualified, and many fonts draw it as
// text, so it is no emoji here.
@(private = "file")
keycap_length :: proc(src: []rune) -> int {
	if len(src) < 2 || !is_keycap_base(src[0]) {
		return 0
	}
	if len(src) >= 3 && src[1] == 0xFE0F && src[2] == 0x20E3 {
		return 3
	}
	return 0
}

// emoji_clusters returns every emoji in `src` with its code point offset, one
// per emoji the reader sees. A flag is two regional indicators; a keycap is a
// digit, "#" or "*" with U+FE0F and U+20E3; a skin-tone modifier belongs to
// the emoji before it; a family or a person at work is several emoji joined by
// zero-width joiners, toned members included. A cluster takes any joiner
// after an emoji, and an emoji only straight after a zero-width joiner, so a
// trailing joiner stays in the cluster. In this the checker follows Unicode
// where the reference does not (it counted a toned emoji as two and found no
// keycap); no golden file holds one. Free the result with `emoji_destroy`.
emoji_clusters :: proc(src: []rune, allocator := context.allocator) -> []Emoji {
	out := make([dynamic]Emoji, allocator)
	i, n := 0, len(src)
	for i < n {
		keycap := keycap_length(src[i:])
		if keycap == 0 && !is_emoji_rune(src[i]) {
			i += 1
			continue
		}
		start := i
		switch {
		case keycap > 0:
			i += keycap
		case is_regional(src[i]) && i + 1 < n && is_regional(src[i + 1]):
			i += 2
		case:
			i += 1
		}
		for i < n {
			prev := src[i - 1]
			if is_emoji_joiner(src[i]) {
				i += 1
			} else if prev == 0x200D && is_emoji_rune(src[i]) {
				i += 1
			} else if is_skin_tone(src[i]) && is_emoji_rune(prev) && !is_skin_tone(prev) && !is_regional(prev) {
				i += 1
			} else {
				break
			}
		}
		append(&out, Emoji{start, runes_to_string(src[start:i], allocator)})
	}
	return out[:]
}

// emoji_destroy frees what `emoji_clusters` returned.
emoji_destroy :: proc(emoji: []Emoji, allocator := context.allocator) {
	for e in emoji {
		delete(e.cluster, allocator)
	}
	delete(emoji, allocator)
}

// runes_to_string encodes `src` as UTF-8 in a new string the caller frees. If
// the allocator cannot supply the bytes the result is "", which is also the
// result for an empty `src`.
runes_to_string :: proc(src: []rune, allocator := context.allocator) -> string {
	size := 0
	for r in src {
		_, w := utf8.encode_rune(r)
		size += w
	}
	buf, err := make([]byte, size, allocator)
	if err != nil {
		return ""
	}
	at := 0
	for r in src {
		b, w := utf8.encode_rune(r)
		copy(buf[at:], b[:w])
		at += w
	}
	return string(buf)
}
