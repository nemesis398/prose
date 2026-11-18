package prose

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// The command line: `prose-check`, with the reference's interface. See
// USAGE for the options and the exit codes.

// The version, set by `make build` from the plugin manifest.
PROSE_VERSION :: #config(PROSE_VERSION, "0.0.0-dev")

// The LanguageTool part of the note when no backend is chosen.
LT_OFF_NOTE :: "LanguageTool is off: run /prose:setup or prose-check --setup to choose a server"

// What --rules adds after a language rule, and says without one.
RULES_DU :: "German readers: lowercase du unless the rule says otherwise."
RULES_NONE :: "No language rule is set: write in the language of the request, and address a German reader with lowercase du."

USAGE :: `usage: prose-check [options] FILE...
       prose-check --stdin [options]

Checks prose in markdown files for the house style: dashes, emoji,
German typography, spacing and machine phrasing, then grammar and
spelling with LanguageTool when a backend is set up.

options:
  --stdin            check standard input too, named <stdin>
  --lang auto|de|en  the language of every paragraph (default: auto)
  --no-lt            skip LanguageTool
  --picky            LanguageTool's picky mode, for text that must be formal
  --json             machine-readable findings
  --strict           warnings fail the run too
  --selftest         show the settings, the backend and the dictionaries,
                     and probe the backend
  --rules            print the language rule
  --setup            ask which LanguageTool to use and write the settings
                     file; needs a terminal
  --values-stdin     with --setup: read the settings as a JSON object on
                     standard input instead (what /prose:setup does)
  --version          print the version
  -h, --help         print this help

exit status: 0 clean, 1 an error found (or a warning with --strict),
2 the check could not run.
`

// Everything `run` would otherwise take from the process, so that a test can
// give its own: the tests run in parallel threads and cannot set
// environment variables. `main` fills it with `run_env_from_os`.
//
// - `lt`: LANGUAGETOOL_SERVER, LANGUAGETOOL_USERNAME, LANGUAGETOOL_API_KEY.
// - `config_dir`: `$XDG_CONFIG_HOME/prose` (or `~/.config/prose`), which
//   holds config.json, credentials and the personal dictionary.txt; "" for
//   none, which is no settings file and none of the others.
// - `skill_dir`: the skill directory, which holds the shipped
//   dictionary.txt; "" for none.
// - `no_color`: NO_COLOR is set, to any value, empty included.
// - `stdout_is_terminal`: colors are used only when this is set and
//   `no_color` is not.
// - `stdin_is_terminal`: `--setup` without `--values-stdin` asks its
//   questions only when this and `stdout_is_terminal` are both set.
// - `hunspell_command`: the local spelling program; "" means
//   `$PROSE_HUNSPELL`, else `hunspell` on PATH.
// - `rbw`: the Premium key lookup through rbw; nil is rbw absent.
// - `lt_timing`: LanguageTool's timeouts and retries; the zero value means
//   `LT_TIMING`. Its `no_proxy` is the list of hosts that bypass a proxy.
//
// `run` only reads it; its strings belong to the caller.
Run_Env :: struct {
	lt:                 Env,
	config_dir:         string,
	skill_dir:          string,
	no_color:           bool,
	stdout_is_terminal: bool,
	stdin_is_terminal:  bool,
	hunspell_command:   string,
	rbw:                proc(item: string) -> (string, bool),
	lt_timing:          Lt_Timing,
}

// run_env_from_os fills a `Run_Env` from the process. Allocated with
// `allocator`; free with `run_env_destroy`.
run_env_from_os :: proc(allocator := context.allocator) -> Run_Env {
	_, no_color := os.lookup_env("NO_COLOR", context.temp_allocator)
	_, no_proxy_lower := os.lookup_env("no_proxy", context.temp_allocator)
	_, no_proxy_upper := os.lookup_env("NO_PROXY", context.temp_allocator)
	timing := LT_TIMING
	timing.no_proxy = loopback_no_proxy(no_proxy_lower || no_proxy_upper)
	return Run_Env {
		lt = env_from_os(allocator),
		config_dir = config_dir(allocator),
		skill_dir = skill_dir(allocator),
		no_color = no_color,
		stdout_is_terminal = os.is_tty(os.stdout),
		stdin_is_terminal = os.is_tty(os.stdin),
		hunspell_command = strings.clone(hunspell_program(), allocator),
		rbw = rbw_lookup,
		lt_timing = timing,
	}
}

run_env_destroy :: proc(e: ^Run_Env, allocator := context.allocator) {
	env_destroy(&e.lt, allocator)
	delete(e.config_dir, allocator)
	delete(e.skill_dir, allocator)
	delete(e.hunspell_command, allocator)
	e^ = {}
}

main :: proc() {
	os.exit(main_run())
}

@(private = "file")
main_run :: proc() -> int {
	// A reader that closes early (`| head`) must give a failed write, which
	// the flush below turns into a non-zero exit, not a SIGPIPE death.
	ignore_sigpipe()
	env := run_env_from_os()
	defer run_env_destroy(&env)
	out: bufio.Writer
	bufio.writer_init(&out, os.to_writer(os.stdout))
	defer bufio.writer_destroy(&out)
	code := run(os.args[1:], os.to_reader(os.stdin), bufio.writer_to_writer(&out), os.to_writer(os.stderr), env)
	if bufio.writer_flush(&out) != nil && code == 0 {
		// A report that did not reach its reader is not a clean run.
		code = 2
	}
	return code
}

// version_line is what --version prints for `version`, with its newline.
// Allocated with `allocator`.
version_line :: proc(version: string, allocator := context.allocator) -> string {
	return strings.concatenate({"prose-check ", version, "\n"}, allocator)
}

// The options of one run.
@(private = "file")
Cli_Args :: struct {
	files:                                                      [dynamic]string,
	stdin, no_lt, picky, json, strict, selftest, rules, version: bool,
	setup, values_stdin:                                        bool,
	help:                                                       bool,
	lang:                                                       string,
	// --lang was given, even as `auto`.
	lang_given:                                                 bool,
}

// parse_args reads the arguments as the reference's argparse does for the
// options it knows: `--lang` takes `auto`, `de` or `en`, as the next
// argument or after `=`; `--` ends the options; `-` alone is a file name.
// `problem` is a literal or allocated with `context.temp_allocator`.
@(private = "file")
parse_args :: proc(args: []string) -> (a: Cli_Args, problem: string) {
	a.lang = "auto"
	a.files = make([dynamic]string)
	only_files := false
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if only_files || arg == "-" || !strings.has_prefix(arg, "-") {
			append(&a.files, arg)
			continue
		}
		switch arg {
		case "--":
			only_files = true
		case "--stdin":
			a.stdin = true
		case "--no-lt":
			a.no_lt = true
		case "--picky":
			a.picky = true
		case "--json":
			a.json = true
		case "--strict":
			a.strict = true
		case "--selftest":
			a.selftest = true
		case "--rules":
			a.rules = true
		case "--version":
			a.version = true
		case "--setup":
			a.setup = true
		case "--values-stdin":
			a.values_stdin = true
		case "-h", "--help":
			a.help = true
		case "--lang":
			if i + 1 >= len(args) {
				return a, "--lang needs a value: auto, de or en"
			}
			i += 1
			a.lang = args[i]
			a.lang_given = true
		case:
			if strings.has_prefix(arg, "--lang=") {
				a.lang = arg[len("--lang="):]
				a.lang_given = true
			} else {
				return a, fmt.tprintf("unknown option %s", arg)
			}
		}
		switch a.lang {
		case "auto", "de", "en":
		case:
			return a, fmt.tprintf("--lang must be auto, de or en, not %q", a.lang)
		}
	}
	return a, ""
}

// run is the command line. `args` are the arguments without the program's
// name; `stdin` is read only with --stdin. The report goes to `stdout`,
// every problem to `stderr`, and the result is the exit code: 0 clean, 1 an
// error found (or a warning with --strict), 2 the check could not run.
// Everything the process would supply comes from `env`.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer, env: Run_Env) -> int {
	a, problem := parse_args(args)
	defer delete(a.files)
	if problem != "" {
		fmt.wprintf(stderr, "prose: %s\nprose: prose-check --help lists the options\n", problem)
		return 2
	}
	if a.help {
		_, _ = io.write_string(stdout, USAGE)
		return 0
	}
	if a.version {
		line := version_line(PROSE_VERSION)
		defer delete(line)
		_, _ = io.write_string(stdout, line)
		return 0
	}
	color := env.stdout_is_terminal && !env.no_color
	// Before anything runs: --setup writes the settings file, so an option it
	// would silently ignore is a mistake worth refusing.
	if a.values_stdin && !a.setup {
		fmt.wprintf(stderr, "prose: --values-stdin goes with --setup\n")
		return 2
	}
	if a.setup && (a.rules || a.json || a.strict || a.lang_given || a.no_lt || a.picky) {
		fmt.wprintf(stderr, "prose: --setup takes no files and no other option\n")
		return 2
	}
	if a.rules {
		return print_rules(stdout, stderr, env)
	}
	if a.setup {
		if len(a.files) > 0 || a.stdin || a.selftest {
			fmt.wprintf(stderr, "prose: --setup takes no files and no other action\n")
			return 2
		}
		return setup(a.values_stdin, stdin, stdout, stderr, env)
	}
	if a.selftest {
		return selftest(stdout, env, color)
	}
	return check_sources(a, stdin, stdout, stderr, env, color)
}

// print_rules is --rules: the `languageRule` and the du line, or the line
// for no rule.
@(private = "file")
print_rules :: proc(stdout, stderr: io.Writer, env: Run_Env) -> int {
	path := config_file_in(env.config_dir, "config.json")
	defer delete(path)
	s, err := load_settings(path)
	defer settings_destroy(&s)
	defer settings_error_destroy(&err)
	if err.problem != "" {
		fmt.wprintf(stderr, "prose: %s\n", err.problem)
		return 2
	}
	rule := strings.trim_space(s.language_rule)
	if rule == "" {
		fmt.wprintf(stdout, "%s\n", RULES_NONE)
	} else {
		fmt.wprintf(stdout, "%s\n%s\n", rule, RULES_DU)
	}
	return 0
}

// One input: its name as given, and its text after `input_text`.
@(private = "file")
Source :: struct {
	name, text: string,
}

// check_sources reads every input, checks each and reports. Every input is
// read and validated before the first is checked, so a file that is missing
// or not UTF-8 stops the run with nothing reported.
@(private = "file")
check_sources :: proc(a: Cli_Args, stdin: io.Reader, stdout, stderr: io.Writer, env: Run_Env, color: bool) -> int {
	sources := make([dynamic]Source)
	defer {
		for src in sources {
			delete(src.text)
		}
		delete(sources)
	}
	if a.stdin {
		data, ok := read_all(stdin)
		if !ok {
			delete(data)
			fmt.wprintf(stderr, "prose: cannot read <stdin>\n")
			return 2
		}
		text, valid := input_text(data)
		if !valid {
			delete(data)
			fmt.wprintf(stderr, "prose: <stdin> is not UTF-8\n")
			return 2
		}
		append(&sources, Source{"<stdin>", text})
	}
	for f in a.files {
		if !os.is_file(f) {
			fmt.wprintf(stderr, "prose: not a file: %s\n", f)
			return 2
		}
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			delete(data)
			fmt.wprintf(stderr, "prose: cannot read %s: %s\n", f, os.error_string(err))
			return 2
		}
		text, valid := input_text(data)
		if !valid {
			delete(data)
			fmt.wprintf(stderr, "prose: %s is not UTF-8\n", f)
			return 2
		}
		append(&sources, Source{f, text})
	}
	if len(sources) == 0 {
		_, _ = io.write_string(stderr, USAGE)
		return 2
	}

	use_lt := !a.no_lt
	settings: Settings
	defer settings_destroy(&settings)
	backend: Backend
	defer backend_destroy(&backend)
	words: Word_Set
	defer word_set_destroy(&words)
	if use_lt {
		path := config_file_in(env.config_dir, "config.json")
		defer delete(path)
		serr: Settings_Error
		settings, serr = load_settings(path)
		defer settings_error_destroy(&serr)
		if serr.problem != "" {
			fmt.wprintf(stderr, "prose: %s\n", serr.problem)
			return 2
		}
		cred := config_file_in(env.config_dir, "credentials")
		defer delete(cred)
		bproblem: string
		backend, bproblem = choose_backend(settings, env.lt, Key_Lookup{rbw = env.rbw, credentials_path = cred})
		defer delete(bproblem)
		if bproblem != "" {
			fmt.wprintf(stderr, "prose: %s\nprose: LanguageTool did not run; --no-lt runs the other checks alone\n", bproblem)
			return 2
		}
		words = load_words_in(settings, env.config_dir, env.skill_dir)
	}

	opts := Check_Options {
		lang             = a.lang,
		use_lt           = use_lt,
		picky            = a.picky,
		backend          = backend,
		words            = words,
		hunspell_command = env.hunspell_command,
	}
	timing := env.lt_timing if env.lt_timing != {} else LT_TIMING

	results := make([dynamic]File_Result)
	defer {
		for &r in results {
			file_result_destroy(&r)
		}
		delete(results)
	}
	errors, warnings := 0, 0
	for src in sources {
		r, cerr := check_text_timed(src.text, opts, timing)
		if cerr.message != "" {
			// What was reported so far must reach stdout before the error
			// reaches stderr, or a terminal shows the error first.
			_ = io.flush(stdout)
			fmt.wprintf(stderr, "prose: LanguageTool %s; the check stops rather than use another backend\n", cerr.message)
			delete(cerr.message)
			return 2
		}
		r.file = src.name
		if use_lt && backend.kind == .None {
			off := strings.concatenate({r.note, " | ", LT_OFF_NOTE})
			delete(r.note)
			r.note = off
		}
		append(&results, r)
		if a.json {
			continue
		}
		note := text_note(r.note, backend)
		defer delete(note)
		e, w := report_text(stdout, r.file, r.findings, note, color)
		errors += e
		warnings += w
	}
	if a.json {
		write_json(stdout, results[:])
		for r in results {
			for f in r.findings {
				switch f.severity {
				case .Error:
					errors += 1
				case .Warning:
					warnings += 1
				case .Note:
				}
			}
		}
	}
	if errors > 0 || (a.strict && warnings > 0) {
		return 1
	}
	return 0
}

// text_note is the note as the text report shows it: the JSON note with the
// backend's URL after its label, so the reader sees where the text went.
// The JSON note keeps the reference's shape, which has no URL. Allocated
// with `context.allocator`.
@(private = "file")
text_note :: proc(note: string, backend: Backend) -> string {
	if backend.kind == .None || backend.label == "" {
		return strings.clone(note)
	}
	pass := strings.concatenate({" | ", backend.label, ": "}, context.temp_allocator)
	at := strings.index(note, pass)
	if at < 0 {
		return strings.clone(note)
	}
	return strings.concatenate({note[:at], " | ", backend.label, " (", backend.url, "): ", note[at + len(pass):]})
}

// The most standard input may hold: far beyond any document, and short of
// running out of memory on an endless stream.
@(private = "file")
MAX_STDIN_BYTES :: 256 << 20

// read_all reads `r` to its end. `ok` is false on a read error or past
// `limit` bytes. The data is allocated with `context.allocator`.
read_all :: proc(r: io.Reader, limit := MAX_STDIN_BYTES) -> (data: []byte, ok: bool) {
	buf := make([dynamic]byte)
	chunk: [64 << 10]byte
	for {
		n, err := io.read(r, chunk[:])
		append(&buf, ..chunk[:n])
		if len(buf) > limit {
			return buf[:], false
		}
		if err == .EOF || (err == nil && n == 0) {
			return buf[:], true
		}
		if err != nil {
			return buf[:], false
		}
	}
}

// input_text checks that `data` is UTF-8 and turns it into the text the
// reference's `read_text` sees: the line endings of Python's universal
// newlines, "\r\n" and a lone "\r" each becoming "\n". A leading byte
// order mark is dropped too, which the reference does not do: there it
// hides a front matter block from the masking (fixture.md then counts 279
// German words instead of 277) and shifts the first line's columns.
// It works in place: `text` starts where `data` does and is freed with it,
// by `delete(text)`. On invalid UTF-8 `ok` is false and `data` untouched.
@(private = "file")
input_text :: proc(data: []byte) -> (text: string, ok: bool) {
	if !utf8.valid_string(string(data)) {
		return "", false
	}
	i, j := 0, 0
	if len(data) >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf {
		i = 3
	}
	for ; i < len(data); i += 1 {
		c := data[i]
		if c == '\r' {
			c = '\n'
			if i + 1 < len(data) && data[i + 1] == '\n' {
				i += 1
			}
		}
		data[j] = c
		j += 1
	}
	return string(data[:j]), true
}

// key_description is how --selftest shows a key: "(unset)", or its length
// in code points and where it came from. Never the key itself. Allocated
// with `allocator`.
key_description :: proc(key: string, from: Key_Source, key_item, credentials_path: string, allocator := context.allocator) -> string {
	if key == "" {
		return strings.clone("(unset)", allocator)
	}
	source: string
	switch from {
	case .Env:
		source = ENV_API_KEY
	case .Rbw:
		source = fmt.tprintf("the rbw item \"%s\"", key_item)
	case .Credentials:
		source = credentials_path
	case .None:
		source = "an unknown source"
	}
	return fmt.aprintf("set, %d chars, from %s", utf8.rune_count_in_string(key), source, allocator = allocator)
}

@(private = "file")
backend_name :: proc(kind: Backend_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Public:
		return "public"
	case .Premium:
		return "premium"
	case .Server:
		return "server"
	}
	return "none"
}

@(private = "file")
selftest_label :: proc(w: io.Writer, name: string) {
	fmt.wprintf(w, "  %-14s: ", name)
}

@(private = "file")
selftest_heading :: proc(w: io.Writer, name: string, color: bool) {
	paint(w, name, .Bold, color)
	_, _ = io.write_string(w, "\n")
}

// selftest is --selftest: the settings file, the backend and where its
// values came from, the key by length only, the dictionary files, and a
// probe of the backend. Exit 2 when the settings file is unusable, the
// backend is not set up, or the probe fails; else 0.
@(private = "file")
selftest :: proc(w: io.Writer, env: Run_Env, color: bool) -> int {
	selftest_heading(w, "Settings", color)
	path := config_file_in(env.config_dir, "config.json")
	defer delete(path)
	s, serr := load_settings(path)
	defer settings_destroy(&s)
	defer settings_error_destroy(&serr)
	selftest_label(w, "file")
	switch {
	case path == "":
		_, _ = io.write_string(w, "(no config directory)\n")
	case serr.problem != "":
		fmt.wprintf(w, "%s (broken)\n", path)
	case os.exists(path):
		fmt.wprintf(w, "%s (found)\n", path)
	case:
		fmt.wprintf(w, "%s (not present)\n", path)
	}
	if serr.problem != "" {
		_, _ = io.write_string(w, "\n")
		selftest_heading(w, "Not usable", color)
		fmt.wprintf(w, "  %s\n", serr.problem)
		return 2
	}
	if len(s.unknown_keys) > 0 {
		selftest_label(w, "unknown keys")
		for k, i in s.unknown_keys {
			if i > 0 {
				_, _ = io.write_string(w, ", ")
			}
			_, _ = io.write_string(w, k)
		}
		_, _ = io.write_string(w, "\n")
	}
	_, _ = io.write_string(w, "\n")

	selftest_heading(w, "Backend", color)
	cred := config_file_in(env.config_dir, "credentials")
	defer delete(cred)
	// The key is looked for once, here; a refused Premium setup still hands
	// back the key it found, so the rbw agent is asked once.
	b, problem := choose_backend(s, env.lt, Key_Lookup{rbw = env.rbw, credentials_path = cred})
	defer backend_destroy(&b)
	defer delete(problem)
	kind, kind_from := backend_kind(s, env.lt)
	selftest_label(w, "chosen")
	fmt.wprintf(w, "%s, from %s\n", backend_name(kind), kind_from)
	switch kind {
	case .None:
	case .Server:
		if b.url != "" {
			selftest_label(w, "url")
			from := ENV_SERVER if env.lt.server != "" else "config.json"
			note := " (http:// assumed: the value has no scheme)" if b.assumed_http else ""
			fmt.wprintf(w, "%s, from %s%s\n", b.url, from, note)
		}
	case .Public, .Premium:
		selftest_label(w, "url")
		fmt.wprintf(w, "%s, built in\n", PUBLIC_URL if kind == .Public else PREMIUM_URL)
	}
	selftest_label(w, "username")
	switch {
	case kind != .Premium:
		_, _ = io.write_string(w, "(not used by this backend)\n")
	case env.lt.username != "":
		fmt.wprintf(w, "%s, from %s\n", env.lt.username, ENV_USERNAME)
	case s.username != "":
		fmt.wprintf(w, "%s, from config.json\n", s.username)
	case:
		_, _ = io.write_string(w, "(unset)\n")
	}
	selftest_label(w, "api key")
	if kind != .Premium {
		_, _ = io.write_string(w, "(not used by this backend)\n")
	} else {
		desc := key_description(b.key, b.key_from, s.key_item, cred)
		defer delete(desc)
		fmt.wprintf(w, "%s\n", desc)
	}
	_, _ = io.write_string(w, "\n")

	selftest_heading(w, "Dictionaries", color)
	selftest_label(w, "built-in")
	fmt.wprintf(w, "%d words\n", len(BUILTIN_WORDS))
	mine := config_file_in(env.config_dir, "dictionary.txt")
	defer delete(mine)
	have_mine := mine != "" && os.is_file(mine)
	selftest_label(w, "personal")
	switch {
	case mine == "":
		_, _ = io.write_string(w, "(no config directory)\n")
	case have_mine:
		fmt.wprintf(w, "%s (found)\n", mine)
	case:
		fmt.wprintf(w, "%s (not present, the shipped list instead)\n", mine)
	}
	shipped := shipped_dictionary_path(env.skill_dir)
	defer delete(shipped)
	selftest_label(w, "shipped")
	switch {
	case shipped == "":
		_, _ = io.write_string(w, "(skill directory unknown)\n")
	case !os.is_file(shipped):
		fmt.wprintf(w, "%s (not present)\n", shipped)
	case have_mine:
		fmt.wprintf(w, "%s (found, not read: the personal list wins)\n", shipped)
	case:
		fmt.wprintf(w, "%s (found, read)\n", shipped)
	}
	selftest_label(w, "ignoreWords")
	fmt.wprintf(w, "%d words\n", len(s.ignore_words))
	_, _ = io.write_string(w, "\n")

	if problem != "" {
		selftest_heading(w, "Not set up", color)
		fmt.wprintf(w, "  %s\n", problem)
		return 2
	}
	selftest_heading(w, "LanguageTool", color)
	if b.kind == .None {
		fmt.wprintf(w, "  %s\n", LT_OFF_NOTE)
		return 0
	}
	timing := env.lt_timing if env.lt_timing != {} else LT_TIMING
	ok, detail, _ := probe(b, timing)
	defer delete(detail)
	_, _ = io.write_string(w, "  ")
	paint(w, "PASS" if ok else "FAIL", .Note if ok else .Error, color)
	fmt.wprintf(w, "  %-14s %s\n        ", b.label, b.url)
	paint(w, detail, .Dim, color)
	_, _ = io.write_string(w, "\n")
	return 0 if ok else 2
}

// setup is --setup: the questions on a terminal, or with `values_stdin` the
// JSON object on standard input. Both write config.json in the config
// directory. Exit 0 written, 2 not.
@(private = "file")
setup :: proc(values_stdin: bool, stdin: io.Reader, stdout, stderr: io.Writer, env: Run_Env) -> int {
	if !values_stdin && !(env.stdin_is_terminal && env.stdout_is_terminal) {
		fmt.wprintf(stderr, SETUP_NEEDS_TERMINAL + "\n")
		return 2
	}
	path := config_file_in(env.config_dir, "config.json")
	defer delete(path)
	if path == "" {
		fmt.wprintf(stderr, "prose: no config directory: set XDG_CONFIG_HOME or HOME\n")
		return 2
	}
	if !values_stdin {
		return run_setup_tty(stdin, stdout, stderr, path)
	}
	data, ok := read_all(stdin, MAX_SETTINGS_BYTES)
	defer delete(data)
	if !ok {
		// read_all hands the data back on failure: more than the limit is "too big".
		if len(data) > MAX_SETTINGS_BYTES {
			fmt.wprintf(stderr, "prose: the values on standard input are bigger than %d bytes\n", MAX_SETTINGS_BYTES)
		} else {
			fmt.wprintf(stderr, "prose: cannot read the values on standard input\n")
		}
		return 2
	}
	err := apply_values(path, string(data))
	defer settings_error_destroy(&err)
	if err.problem != "" {
		fmt.wprintf(stderr, "prose: %s\nprose: the settings file is unchanged\n", err.problem)
		return 2
	}
	fmt.wprintf(stdout, "wrote %s\n", path)
	return 0
}
