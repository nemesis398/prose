package prose

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

// Pass 3: the local spelling pass. A port of the reference's `run_hunspell`:
// with LanguageTool off, the masked English text goes through
// `hunspell -d en_US -a` and every word it does not know becomes a warning.
// It only finds words, so a finding has the line and column 1; for the
// reference's reasons it says nothing about where in the line, and gives no
// suggestion.

// How long hunspell may take for a whole text; a large file is a few
// seconds, so this only catches a hung process.
HUNSPELL_TIMEOUT :: 60 * time.Second

// The most hunspell's answer may hold. It prints about 100 bytes for each
// misspelled word, so this is a million of them; more is not hunspell.
@(private = "file")
MAX_HUNSPELL_OUTPUT :: 128 << 20

// hunspell_program is the program to run: `$PROSE_HUNSPELL` when it is set
// and not empty, else `hunspell`, found on PATH. Allocated with
// `context.temp_allocator`.
hunspell_program :: proc() -> string {
	if p, found := os.lookup_env("PROSE_HUNSPELL", context.temp_allocator); found && p != "" {
		return p
	}
	return "hunspell"
}

// run_hunspell_with runs the local spelling pass with the program `command`,
// which may take `timeout` for the whole text. The caller chooses the
// program (`hunspell_program` is the default); `check_text` is the one place
// that does.
//
// The input is the masked text: every character that is markup, or that is
// not in an English block, becomes a space, and the line breaks stay, so a
// line of the input is a line of the file. Only English is sent, as hunspell
// is run with the English dictionary only; a text with no English in it
// starts no process at all. (The reference sends every block and loses the
// line breaks that sit in markup, such as a fenced block's, so its lines run
// early after one; this port does neither.) Each line is escaped with a
// leading `^`, which stops hunspell reading a line that starts with `*`, `#`,
// `%`, `!` and the like as a command that has no answer, which would shift
// every following line.
//
// hunspell answers each input line with one result line per word and then a
// blank line, so the number of blank lines seen is the line. A result line
// starting with `&` (a miss with suggestions) or `#` (a miss without) names
// its word second. The word is skipped when `words` has it, ignoring case, or
// when it is not made of letters only, and a word is reported once per line.
// The finding is a warning, rule `HUNSPELL`, column 1. Its message differs
// from the reference's, which blamed an unreachable LanguageTool: this pass
// runs only when no backend is chosen, so it says LanguageTool is off.
//
// A program that is missing, fails to start, runs out of time or gives too
// much is no findings and no error. What hunspell printed before a failing
// exit still counts. Allocated with `allocator`; free the findings with
// `findings_destroy` on `found[:]`. `starts` is not needed and is part of the
// signature of the passes.
//
// On Windows the pass does nothing and starts no process, so backend `none`
// checks no spelling there. `command_with_input` cannot bound the run on
// Windows when hunspell is a wrapper whose own child holds the pipe: the
// writer thread then blocks in a write that nothing ends, and the checker
// would hang with it.
run_hunspell_with :: proc(
	command: string,
	timeout: time.Duration,
	src: []rune,
	m: ^Masked,
	blocks: []Block,
	starts: []int,
	words: Word_Set,
	allocator := context.allocator,
) -> (
	found: [dynamic]Finding,
) {
	found = make([dynamic]Finding, allocator)
	when ODIN_OS == .Windows {
		return
	}

	input, any_english := hunspell_input(src, m, blocks)
	defer delete(input)
	if !any_english {
		return
	}

	argv := [?]string{command, "-i", "utf-8", "-d", "en_US", "-a"}
	out, ok := command_with_input(argv[:], input[:], timeout, MAX_HUNSPELL_OUTPUT)
	if !ok {
		return
	}
	defer delete(out)

	line_no := 0
	seen := make(map[string]struct{})
	defer delete(seen)
	rest := string(out)
	for out_line in strings.split_lines_iterator(&rest) {
		if is_blank(out_line) {
			line_no += 1
			clear(&seen)
			continue
		}
		if out_line[0] != '&' && out_line[0] != '#' {
			continue
		}
		word := second_field(out_line)
		if word == "" || word_set_has(words, word) || !is_alpha_word(word) {
			continue
		}
		if word in seen {
			continue
		}
		seen[word] = {}
		append(
			&found,
			Finding {
				line = line_no + 1,
				col = 1,
				severity = .Warning,
				rule = strings.clone("HUNSPELL", allocator),
				message = fmt.aprintf(
					"Unknown word “%s” (local hunspell check, LanguageTool is off)",
					word,
					allocator = allocator,
				),
				excerpt = strings.clone("", allocator),
				suggestion = strings.clone("", allocator),
			},
		)
	}
	return
}

// hunspell_input builds the text hunspell reads, as `run_hunspell_with`
// describes, and says whether it holds any English at all. Free it with
// `delete`.
@(private = "file")
hunspell_input :: proc(src: []rune, m: ^Masked, blocks: []Block) -> (input: [dynamic]u8, any_english: bool) {
	english := make([]bool, len(src))
	defer delete(english)
	for b in blocks {
		if b.lang != "en" {
			continue
		}
		for i in max(b.start, 0) ..< min(b.end, len(src)) {
			english[i] = true
		}
	}

	line_start := true
	for r, i in src {
		if line_start {
			append(&input, '^')
			line_start = false
		}
		out := r
		switch {
		case r == '\n':
			line_start = true
		case m.is_markup[i] || !english[i]:
			out = ' '
		case !is_py_space(r):
			any_english = true
		}
		buf, n := utf8.encode_rune(out)
		append(&input, ..buf[:n])
	}
	return
}

// is_blank is Python's `not line.strip()`.
@(private = "file")
is_blank :: proc(s: string) -> bool {
	for r in s {
		if !is_py_space(r) {
			return false
		}
	}
	return true
}

// second_field is the second white-space separated field of `s`, as
// `s.split()[1]` in Python, or "" when there is none.
@(private = "file")
second_field :: proc(s: string) -> string {
	rest := s
	skipped := false
	for {
		rest = strings.trim_left_proc(rest, is_py_space)
		if rest == "" {
			return ""
		}
		end := strings.index_proc(rest, is_py_space)
		if end < 0 {
			end = len(rest)
		}
		if skipped {
			return rest[:end]
		}
		skipped = true
		rest = rest[end:]
	}
}

// is_alpha_word is Python's `str.isalpha()`: not empty, and only letters.
@(private = "file")
is_alpha_word :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for r in s {
		if !unicode.is_letter(r) {
			return false
		}
	}
	return true
}
