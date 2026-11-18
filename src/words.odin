package prose

import "base:runtime"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// The words the checker accepts, lowercased. Matching a word is
// `word_set_has`, which lowercases the candidate the same way. The keys are
// allocated with the allocator given to `load_words`; free the set with
// `word_set_destroy`. The zero value is the empty set.
Word_Set :: map[string]struct{}

// Names every Claude Code user meets; without them LanguageTool flags
// "Claude" for every stranger. The same 19 words as the reference's
// IGNORE_WORDS. A person's own words go in `ignoreWords` or their
// dictionary.txt.
BUILTIN_WORDS := [?]string {
	"Claude", "Anthropic", "Opus", "Sonnet", "Haiku", "LanguageTool",
	"hunspell", "Markdown", "GitHub", "GitLab", "Odin", "systemd", "nginx",
	"Docker", "Kubernetes", "Postgres", "PostgreSQL", "Obsidian", "npm",
}

// A word list bigger than this is skipped, as one that cannot be read is.
@(private = "file")
MAX_DICTIONARY_BYTES :: 8 << 20

// load_words is the set of accepted words: the built-in list, the user's
// `$XDG_CONFIG_HOME/prose/dictionary.txt` or, only when the user has none,
// the `dictionary.txt` that ships next to `bin/` in the skill, and
// `s.ignore_words`. Allocated with `allocator`; free with `word_set_destroy`.
load_words :: proc(s: Settings, allocator := context.allocator) -> Word_Set {
	cfg := config_dir(allocator)
	defer delete(cfg, allocator)
	skill := skill_dir(allocator)
	defer delete(skill, allocator)
	return load_words_in(s, cfg, skill, allocator)
}

// load_words_in is `load_words` with the config directory and the skill
// directory given; either may be "" for none. Dictionary files are read as
// the reference reads them: one word per line, surrounding whitespace
// trimmed, blank lines and lines that start with `#` ignored. A file that
// cannot be read or is not UTF-8 adds nothing; that does not bring the
// shipped list back in its place. A leading byte order mark is ignored. A line
// ends at \n, \r\n or a lone \r.
load_words_in :: proc(
	s: Settings,
	config_dir, skill_dir: string,
	allocator := context.allocator,
) -> Word_Set {
	words := make(Word_Set, allocator)
	for w in BUILTIN_WORDS {
		word_set_add(&words, w, allocator)
	}

	mine := config_file_in(config_dir, "dictionary.txt", allocator)
	defer delete(mine, allocator)
	if mine != "" && os.is_file(mine) {
		read_dictionary(&words, mine, allocator)
	} else {
		shipped := shipped_dictionary_path(skill_dir, allocator)
		defer delete(shipped, allocator)
		if shipped != "" {
			read_dictionary(&words, shipped, allocator)
		}
	}

	for w in s.ignore_words {
		if word := strings.trim_space(w); word != "" {
			word_set_add(&words, word, allocator)
		}
	}
	return words
}

// skill_dir is the directory of the skill, found from the executable: the
// binary is `skills/prose/bin/prose-check`, so it is the directory of the
// executable and then `..`. "" when the executable is not known.
skill_dir :: proc(allocator := context.allocator) -> string {
	exe_dir, err := os.get_executable_directory(allocator)
	if err != nil {
		return ""
	}
	defer delete(exe_dir, allocator)
	return skill_dir_from_exe_dir(exe_dir, allocator)
}

// skill_dir_from_exe_dir is `skill_dir` for a given directory of the
// executable. A trailing separator is ignored.
skill_dir_from_exe_dir :: proc(exe_dir: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_right(exe_dir, "/\\")
	if trimmed == "" {
		return ""
	}
	parent, _ := os.split_path(trimmed)
	return strings.clone(strings.trim_right(parent, "/\\") if len(parent) > 1 else parent, allocator)
}

// shipped_dictionary_path is the `dictionary.txt` in a skill directory, or
// "" for an empty `skill_dir`.
shipped_dictionary_path :: proc(skill_dir: string, allocator := context.allocator) -> string {
	return config_file_in(skill_dir, "dictionary.txt", allocator)
}

@(private = "file")
read_dictionary :: proc(words: ^Word_Set, path: string, allocator: runtime.Allocator) {
	info, serr := os.stat(path, allocator)
	if serr != nil {
		return
	}
	size, is_regular := info.size, info.type == .Regular
	os.file_info_delete(info, allocator)
	if !is_regular || size > MAX_DICTIONARY_BYTES {
		return
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return
	}
	defer delete(data, allocator)
	if !utf8.valid_string(string(data)) {
		return
	}
	text := strings.trim_prefix(string(data), "\xEF\xBB\xBF")
	// A line ends at \n, \r\n or a lone \r. The \n of a \r\n ends an empty
	// line, and an empty line is skipped.
	rest := text
	for rest != "" {
		end := strings.index_any(rest, "\r\n")
		line := rest
		if end < 0 {
			rest = ""
		} else {
			line, rest = rest[:end], rest[end + 1:]
		}
		word := strings.trim_space(line)
		if word != "" && !strings.has_prefix(word, "#") {
			word_set_add(words, word, allocator)
		}
	}
}

// word_set_add adds `word`, lowercased, to the set. The set's keys are
// allocated with `allocator`, which must be the one the set was made with.
word_set_add :: proc(ws: ^Word_Set, word: string, allocator := context.allocator) {
	lower := strings.to_lower(word, allocator)
	if lower in ws {
		delete(lower, allocator)
		return
	}
	ws[lower] = {}
}

// word_set_has reports whether `word` is in the set, ignoring case.
word_set_has :: proc(ws: Word_Set, word: string) -> bool {
	if word == "" || len(ws) == 0 {
		return false
	}
	// Short words lowercase on the stack: this runs for every candidate word.
	// A rune is at most 3 bytes after lowercasing an invalid byte or 4 after
	// a code point, and the guard keeps 128 bytes of input within 512.
	if len(word) <= 128 {
		buf: [512]u8
		n := 0
		for r in word {
			enc, w := utf8.encode_rune(unicode.to_lower(r))
			copy(buf[n:], enc[:w])
			n += w
		}
		_, found := ws[string(buf[:n])]
		return found
	}
	lower := strings.to_lower(word, context.temp_allocator)
	_, found := ws[lower]
	return found
}

// word_set_destroy frees the keys and the set. `allocator` is the one
// `load_words` was given.
word_set_destroy :: proc(ws: ^Word_Set, allocator := context.allocator) {
	for k in ws {
		delete(k, allocator)
	}
	delete(ws^)
	ws^ = nil
}
