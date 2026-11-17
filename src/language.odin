package prose

// Language detection. A port of the reference's `detect_language` and
// `language_blocks`: a paragraph is German or English by which language has
// more of its common function words in it, with each umlaut or sharp s
// counting for three German ones. The word sets are the reference's, and so
// is its word pattern `[A-Za-zÄÖÜäöüßÀ-ÿ']+`, so the same text gets the same
// label.

// Block is one paragraph of the source: `src[start:end]`, with `lang` "de" or
// "en". The text between two blocks is the blank line that separates them.
Block :: struct {
	start, end: int,
	lang:       string,
}

// A paragraph needs this many words before its own guess is believed.
@(private = "file")
MIN_WORDS :: 6

@(private = "file")
is_word_rune :: #force_inline proc(r: rune) -> bool {
	switch r {
	case 'A' ..= 'Z', 'a' ..= 'z', '\'', 0xC0 ..= 0xFF:
		return true
	}
	return false
}

// next_word finds the next match of the word pattern at or after `from`. It
// returns `lo == hi == len(text)` when there is none.
@(private = "file")
next_word :: proc(text: []rune, from: int) -> (lo, hi: int) {
	i := from
	for i < len(text) && !is_word_rune(text[i]) {
		i += 1
	}
	lo = i
	for i < len(text) && is_word_rune(text[i]) {
		i += 1
	}
	return lo, i
}

@(private = "file")
count_words :: proc(text: []rune) -> int {
	n := 0
	for p := 0; true; {
		lo, hi := next_word(text, p)
		if lo == hi {
			break
		}
		n += 1
		p = hi
	}
	return n
}

// lower_word lowercases a word into `buf` as UTF-8, as far as it can matter
// for a marker word: ASCII letters and Ü. Any other non-ASCII rune is kept
// as is, since no marker contains one. It reports false for a word too long
// to be a marker.
@(private = "file")
lower_word :: proc(word: []rune, buf: ^[16]u8) -> (s: string, ok: bool) {
	n := 0
	for r in word {
		if n + 2 > len(buf) {
			return "", false
		}
		switch r {
		case 'A' ..= 'Z':
			buf[n] = u8(r) + 32
			n += 1
		case 'a' ..= 'z', '\'':
			buf[n] = u8(r)
			n += 1
		case 0xDC, 0xFC:
			buf[n] = 0xC3
			buf[n + 1] = 0xBC
			n += 2
		case:
			// A byte no marker has.
			buf[n] = 0xFF
			n += 1
		}
	}
	return string(buf[:n]), true
}

@(private = "file")
is_de_marker :: proc(w: string) -> bool {
	switch w {
	case "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines",
	     "und", "oder", "aber", "nicht", "ist", "sind", "wird", "werden", "wurde",
	     "auch", "noch", "nur", "schon", "wenn", "dann", "als", "bei", "für",
	     "mit", "von", "zu", "aus", "nach", "über", "unter", "durch", "ohne",
	     "dass", "weil", "damit", "jedoch", "allerdings", "zudem", "kein", "keine",
	     "sich", "sein", "seine", "ihre", "man", "wie", "was", "wo", "sehr",
	     "mehr", "viele", "alle", "jede", "beim", "zum", "zur", "im", "am":
		return true
	}
	return false
}

@(private = "file")
is_en_marker :: proc(w: string) -> bool {
	switch w {
	case "the", "and", "of", "to", "is", "are", "was", "were", "that", "this",
	     "these", "those", "with", "from", "for", "have", "has", "had", "will",
	     "would", "not", "but", "you", "your", "our", "their", "them", "they",
	     "which", "when", "where", "why", "how", "about", "into", "through",
	     "there", "here", "than", "then", "each", "any", "all", "one", "it":
		return true
	}
	return false
}

// detect_language returns "de" or "en" for the language with more marker
// words in `text`, or "" when there is no word or the two tie.
detect_language :: proc(text: []rune) -> string {
	de, en, words := 0, 0, 0
	buf: [16]u8
	for p := 0; true; {
		lo, hi := next_word(text, p)
		if lo == hi {
			break
		}
		words += 1
		if w, ok := lower_word(text[lo:hi], &buf); ok {
			if is_de_marker(w) {
				de += 1
			}
			if is_en_marker(w) {
				en += 1
			}
		}
		p = hi
	}
	if words == 0 {
		return ""
	}
	for r in text {
		switch r {
		case 'ä', 'ö', 'ü', 'ß', 'Ä', 'Ö', 'Ü':
			de += 3
		}
	}
	if de == en {
		return ""
	}
	return "de" if de > en else "en"
}

// separator_at finds the paragraph separator that starts at `i`, the
// expression `\n\s*\n` with Python's `\s`: a newline, then white space up to
// and including its last newline. It returns the end of the separator, or -1.
@(private = "file")
separator_at :: proc(src: []rune, i: int) -> int {
	if src[i] != '\n' {
		return -1
	}
	last := -1
	for j := i + 1; j < len(src) && is_py_space(src[j]); j += 1 {
		if src[j] == '\n' {
			last = j
		}
	}
	return last + 1 if last >= 0 else -1
}

// language_blocks splits the source at blank lines into blocks and labels
// each with a language. `forced` is "de" or "en" to label them all so, or
// "auto". Automatically, a block takes its own language, read with the
// masked text blanked out; one that has fewer than six words or no clear
// winner takes the language of the block before it, and the first the
// language of the whole text, English when that is unclear too. The blocks
// are in a new slice the caller frees with `delete`.
language_blocks :: proc(m: ^Masked, forced: string, allocator := context.allocator) -> []Block {
	src := m.src
	blocks := make([dynamic]Block, allocator)

	chunk := 0
	emit :: proc(blocks: ^[dynamic]Block, src: []rune, lo, hi: int) {
		for i in lo ..< hi {
			if !is_py_space(src[i]) {
				append(blocks, Block{lo, hi, ""})
				return
			}
		}
	}
	for i := 0; i < len(src); {
		if end := separator_at(src, i); end >= 0 {
			emit(&blocks, src, chunk, i)
			chunk = end
			i = end
		} else {
			i += 1
		}
	}
	emit(&blocks, src, chunk, len(src))

	if forced == "de" || forced == "en" {
		for &b in blocks {
			b.lang = forced
		}
		return blocks[:]
	}

	visible := make([]rune, len(src), allocator)
	defer delete(visible, allocator)
	for r, i in src {
		visible[i] = ' ' if m.is_markup[i] else r
	}
	previous := detect_language(visible)
	if previous == "" {
		previous = "en"
	}
	for &b in blocks {
		text := visible[b.start:b.end]
		guess := detect_language(text)
		if guess == "" || count_words(text) < MIN_WORDS {
			guess = previous
		}
		b.lang = guess
		previous = guess
	}
	return blocks[:]
}
