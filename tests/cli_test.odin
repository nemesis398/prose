package prose_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import prose "../src"

// The command line, through `run`: arguments, input, settings and the two
// outputs, with everything the process would supply given in a `Run_Env`.
// No test touches the process environment, so they run in parallel threads.

@(private = "file")
CORPUS :: #directory + "corpus/"
@(private = "file")
GOLDEN :: #directory + "golden/"
@(private = "file")
GOLDEN_LT :: #directory + "golden-lt/"
@(private = "file")
RECORDINGS :: #directory + "lt-recordings"
@(private = "file")
SKILL :: #directory + "../skills/prose"
// A hunspell that is not there, so the local spelling pass adds nothing.
@(private = "file")
NO_HUNSPELL :: "/nonexistent/hunspell"
@(private = "file")
OFF :: "LanguageTool is off: run /prose:setup or prose-check --setup to choose a server"

@(private = "file")
Cli :: struct {
	code:     int,
	out, err: string,
}

// cli runs the command line with `args` and `stdin`. A `Run_Env` with no
// hunspell gets one that does not exist.
@(private = "file")
cli :: proc(args: []string, env: prose.Run_Env, stdin := "") -> Cli {
	env := env
	if env.hunspell_command == "" {
		env.hunspell_command = NO_HUNSPELL
	}
	out := strings.builder_make()
	errb := strings.builder_make()
	r: strings.Reader
	code := prose.run(args, strings.to_reader(&r, stdin), strings.to_writer(&out), strings.to_writer(&errb), env)
	return Cli{code, strings.to_string(out), strings.to_string(errb)}
}

@(private = "file")
cli_done :: proc(c: ^Cli) {
	delete(c.out)
	delete(c.err)
}

@(private = "file")
scratch :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "prose-task10-*", context.allocator)
	testing.expect(t, err == nil)
	return dir
}

@(private = "file")
scratch_done :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

// put writes `content` to `dir/name` and returns the path.
@(private = "file")
put :: proc(t: ^testing.T, dir, name: string, content: []byte) -> string {
	path, _ := os.join_path({dir, name}, context.allocator)
	testing.expect(t, os.write_entire_file(path, content) == nil)
	return path
}

@(private = "file")
read_file :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.allocator)
	return string(data)
}

// as_named replaces `path` in `out` with `name`, as the golden files were
// made in the corpus directory and name the file without a directory.
@(private = "file")
as_named :: proc(out, path, name: string) -> string {
	s, _ := strings.replace_all(out, path, name)
	if raw_data(s) == raw_data(out) {
		return strings.clone(out)
	}
	return s
}

// The JSON of every corpus file, LanguageTool off, is its golden file byte
// for byte, and the exit code is 1 exactly when it holds an error.
@(test)
json_without_lt_is_the_golden_file :: proc(t: ^testing.T) {
	entries, err := os.read_all_directory_by_path(CORPUS, context.allocator)
	testing.expect_value(t, err, nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	checked := 0
	for e in entries {
		if !strings.has_suffix(e.name, ".md") {
			continue
		}
		checked += 1
		path := strings.concatenate({CORPUS, e.name})
		defer delete(path)
		golden := strings.concatenate({GOLDEN, e.name[:len(e.name) - 3], ".json"})
		defer delete(golden)
		want := read_file(golden)
		defer delete(want)

		c := cli({"--no-lt", "--json", path}, {})
		defer cli_done(&c)
		got := as_named(c.out, path, e.name)
		defer delete(got)
		testing.expectf(t, got == want, "%s: JSON differs from the golden file:\n%s", e.name, got)
		want_code := 1 if strings.contains(want, `"severity": "error"`) else 0
		testing.expectf(t, c.code == want_code, "%s: exit %d, want %d", e.name, c.code, want_code)
		testing.expectf(t, c.err == "", "%s: stderr %q", e.name, c.err)
	}
	testing.expect(t, checked >= 10)
}

// The text report of fixture.md is the reference's, captured with
// NO_COLOR=1 into tests/golden/fixture.txt.
@(test)
text_without_lt_is_the_references_report :: proc(t: ^testing.T) {
	path := CORPUS + "fixture.md"
	want := read_file(GOLDEN + "fixture.txt")
	defer delete(want)
	c := cli({"--no-lt", path}, {})
	defer cli_done(&c)
	got := as_named(c.out, path, "fixture.md")
	defer delete(got)
	testing.expectf(t, got == want, "text report differs:\n%s", got)
	testing.expect_value(t, c.code, 1)
	testing.expect_value(t, c.err, "")
}

// Colors only for a terminal, and never with NO_COLOR.
@(test)
colors_only_on_a_terminal_without_no_color :: proc(t: ^testing.T) {
	path := CORPUS + "fixture.md"
	plain := cli({"--no-lt", path}, {})
	defer cli_done(&plain)
	testing.expect(t, !strings.contains(plain.out, "\x1b["))
	muted := cli({"--no-lt", path}, {stdout_is_terminal = true, no_color = true})
	defer cli_done(&muted)
	testing.expect_value(t, muted.out, plain.out)
	painted := cli({"--no-lt", path}, {stdout_is_terminal = true})
	defer cli_done(&painted)
	head := fmt.aprintf("\x1b[1m%s\x1b[0m\n  \x1b[2mlanguage: de, en\x1b[0m\n", path)
	defer delete(head)
	testing.expectf(t, strings.has_prefix(painted.out, head), "%q", painted.out[:min(len(painted.out), 120)])
	testing.expect(t, strings.contains(painted.out, "\x1b[31merror  \x1b[0m"))
	testing.expect(t, strings.contains(painted.out, "\x1b[33mwarning\x1b[0m"))
}

// A clean file says so.
@(test)
a_clean_text_reports_clean :: proc(t: ^testing.T) {
	c := cli({"--no-lt", "--stdin"}, {}, "A short and plain sentence.\n")
	defer cli_done(&c)
	testing.expect_value(t, c.out, "<stdin>\n  language: en\n  clean\n  0 error(s), 0 warning(s), 0 note(s)\n\n")
	testing.expect_value(t, c.code, 0)
}

// Exit 1 for an error, 0 for warnings alone, 1 for a warning with --strict.
// The same sentence is a warning in English and an error in German.
@(test)
exit_codes_follow_the_severities :: proc(t: ^testing.T) {
	text := "Let's dive into the numbers. We lost 40% of it.\n"
	en := cli({"--no-lt", "--stdin", "--lang", "en"}, {}, text)
	defer cli_done(&en)
	testing.expect_value(t, en.code, 0)
	testing.expect(t, strings.contains(en.out, "AI-PHRASE"))
	testing.expect(t, strings.contains(en.out, "0 error(s), 1 warning(s), 0 note(s)"))

	strict := cli({"--no-lt", "--stdin", "--lang=en", "--strict"}, {}, text)
	defer cli_done(&strict)
	testing.expect_value(t, strict.code, 1)

	de := cli({"--no-lt", "--stdin", "--lang", "de", "--json"}, {}, text)
	defer cli_done(&de)
	testing.expect_value(t, de.code, 1)
	testing.expect(t, strings.contains(de.out, `"file": "<stdin>"`))
	testing.expect(t, strings.contains(de.out, `"note": "language: de"`))
	testing.expect(t, strings.contains(de.out, `"rule": "DE-UNIT-SPACE"`))
}

// Several files, standard input first, one result each.
@(test)
stdin_comes_first_then_the_files :: proc(t: ^testing.T) {
	path := CORPUS + "empty.md"
	c := cli({"--no-lt", "--json", path, "--stdin"}, {}, "Plain.\n")
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	a := strings.index(c.out, `"file": "<stdin>"`)
	b := strings.index(c.out, path)
	testing.expectf(t, a >= 0 && b > a, "%s", c.out)
}

// Every way the check cannot run is exit 2 with a message on stderr.
@(test)
exit_2_when_the_check_cannot_run :: proc(t: ^testing.T) {
	{
		c := cli({"--no-lt", "/nonexistent/x.md"}, {})
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		testing.expect_value(t, c.err, "prose: not a file: /nonexistent/x.md\n")
		testing.expect_value(t, c.out, "")
	}
	{
		// A directory is not a file either.
		c := cli({"--no-lt", CORPUS}, {})
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		testing.expect(t, strings.has_prefix(c.err, "prose: not a file: "))
	}
	{
		c := cli({}, {})
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		testing.expect(t, strings.contains(c.err, "usage: prose-check"))
		testing.expect_value(t, c.out, "")
	}
	for args in ([][]string{{"--bogus"}, {"--lang"}, {"--lang", "fr", "x"}, {"--lang=", "x"}, {"-x"}}) {
		c := cli(args, {})
		defer cli_done(&c)
		testing.expectf(t, c.code == 2, "%v: exit %d", args, c.code)
		testing.expectf(t, strings.has_prefix(c.err, "prose: "), "%v: %q", args, c.err)
	}
}

// A settings file that cannot be used stops a check with LanguageTool, and
// the message names the file. With --no-lt the settings are not read, as the
// reference reads no credentials then, so --no-lt still checks.
@(test)
a_broken_settings_file_is_exit_2_naming_it :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cfg := put(t, dir, "config.json", transmute([]byte)string("{\"languagetool\": "))
	defer delete(cfg)
	path := CORPUS + "empty.md"
	env := prose.Run_Env{config_dir = dir}

	c := cli({path}, env)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	want := fmt.aprintf("prose: %s:", cfg)
	defer delete(want)
	testing.expectf(t, strings.has_prefix(c.err, want), "%q", c.err)
	testing.expect_value(t, c.out, "")

	r := cli({"--rules"}, env)
	defer cli_done(&r)
	testing.expect_value(t, r.code, 2)
	testing.expectf(t, strings.has_prefix(r.err, want), "%q", r.err)

	n := cli({"--no-lt", path}, env)
	defer cli_done(&n)
	testing.expect_value(t, n.code, 0)
}

// Premium without a key stops the check, names what is missing and how to
// run without LanguageTool, and sends nothing.
@(test)
premium_without_a_key_is_exit_2 :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cfg := put(t, dir, "config.json", transmute([]byte)string(`{"languagetool": {"backend": "premium", "username": "u"}}`))
	defer delete(cfg)
	c := cli({CORPUS + "fixture.md"}, {config_dir = dir})
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expectf(t, strings.has_prefix(c.err, "prose: LanguageTool Premium has no key"), "%q", c.err)
	testing.expect(t, strings.contains(c.err, "prose: LanguageTool did not run; --no-lt runs the other checks alone\n"))
	testing.expect_value(t, c.out, "")
}

// --version prints the name and the version built in.
@(test)
version_prints_the_built_in_version :: proc(t: ^testing.T) {
	c := cli({"--version"}, {})
	defer cli_done(&c)
	want := fmt.aprintf("prose-check %s\n", prose.PROSE_VERSION)
	defer delete(want)
	testing.expect_value(t, c.out, want)
	testing.expect_value(t, c.code, 0)
	// What `make build` gives with -define:PROSE_VERSION=0.1.0.
	line := prose.version_line("0.1.0")
	defer delete(line)
	testing.expect_value(t, line, "prose-check 0.1.0\n")
}

// --help is not an error.
@(test)
help_is_exit_0 :: proc(t: ^testing.T) {
	c := cli({"--help"}, {})
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	testing.expect(t, strings.has_prefix(c.out, "usage: prose-check"))
}

// --rules prints the language rule and the du line, or the default.
@(test)
rules_prints_the_language_rule :: proc(t: ^testing.T) {
	none := cli({"--rules"}, {})
	defer cli_done(&none)
	testing.expect_value(t, none.code, 0)
	testing.expect_value(
		t,
		none.out,
		"No language rule is set: write in the language of the request, and address a German reader with lowercase du.\n",
	)

	dir := scratch(t)
	defer scratch_done(dir)
	cfg := put(t, dir, "config.json", transmute([]byte)string(`{"languageRule": "Notes in German, code comments in English."}`))
	defer delete(cfg)
	set := cli({"--rules"}, {config_dir = dir})
	defer cli_done(&set)
	testing.expect_value(t, set.code, 0)
	testing.expect_value(
		t,
		set.out,
		"Notes in German, code comments in English.\nGerman readers: lowercase du unless the rule says otherwise.\n",
	)
}

// --selftest with nothing set up: no settings file, backend none, nothing
// probed, exit 0.
@(test)
selftest_with_nothing_set_up :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	c := cli({"--selftest"}, {config_dir = dir, skill_dir = SKILL})
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	cfg, _ := os.join_path({dir, "config.json"}, context.allocator)
	defer delete(cfg)
	mine, _ := os.join_path({dir, "dictionary.txt"}, context.allocator)
	defer delete(mine)
	shipped, _ := os.join_path({SKILL, "dictionary.txt"}, context.allocator)
	defer delete(shipped)
	for want in ([]string {
			fmt.tprintf("  file          : %s (not present)\n", cfg),
			"  chosen        : none, from the default\n",
			"  api key       : (not used by this backend)\n",
			"  built-in      : 19 words\n",
			fmt.tprintf("  personal      : %s (not present, the shipped list instead)\n", mine),
			fmt.tprintf("  shipped       : %s (found, read)\n", shipped),
			"  ignoreWords   : 0 words\n",
			"  " + OFF + "\n",
		}) {
		testing.expectf(t, strings.contains(c.out, want), "lacks %q in:\n%s", want, c.out)
	}
	testing.expect(t, !strings.contains(c.out, "unknown keys"))
}

// --selftest against a server that answers: the file is found, its unknown
// keys listed, the URL's source named, the probe PASSes. One that refuses
// FAILs with exit 2.
@(test)
selftest_probes_the_backend :: proc(t: ^testing.T) {
	for mode in ([]Fake_Mode{.Replay, .Refuse_403}) {
		fake, port := fake_lt_start(RECORDINGS, mode)
		defer fake_lt_stop(fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		dir := scratch(t)
		defer scratch_done(dir)
		url := fmt.aprintf("http://127.0.0.1:%d", port)
		defer delete(url)
		body := fmt.aprintf(`{{"colour": 1, "ignoreWords": ["Huginn", "Muninn"], "languagetool": {{"backend": "server", "server": "%s", "extra": true}}}}`, url)
		defer delete(body)
		cfg := put(t, dir, "config.json", transmute([]byte)body)
		defer delete(cfg)
		put_mine := put(t, dir, "dictionary.txt", transmute([]byte)string("Ravnix\n"))
		defer delete(put_mine)

		c := cli({"--selftest"}, {config_dir = dir, skill_dir = SKILL})
		defer cli_done(&c)
		wants := make([dynamic]string)
		defer delete(wants)
		append(
			&wants,
			fmt.tprintf("  file          : %s (found)\n", cfg),
			"  unknown keys  : colour, languagetool.extra\n",
			"  chosen        : server, from config.json\n",
			fmt.tprintf("  url           : %s, from config.json\n", url),
			fmt.tprintf("  personal      : %s (found)\n", put_mine),
			"(found, not read: the personal list wins)\n",
			"  ignoreWords   : 2 words\n",
		)
		if mode == .Replay {
			testing.expect_value(t, c.code, 0)
			append(&wants, fmt.tprintf("  PASS  self-hosted    %s\n        ok, 1 match(es) on the probe sentence", url))
		} else {
			testing.expect_value(t, c.code, 2)
			append(&wants, fmt.tprintf("  FAIL  self-hosted    %s\n        HTTP 403", url))
		}
		for want in wants {
			testing.expectf(t, strings.contains(c.out, want), "%v: lacks %q in:\n%s", mode, want, c.out)
		}
	}
}

// LANGUAGETOOL_SERVER chooses and names the server; it beats the file's URL.
@(test)
selftest_names_the_variable_that_chose :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d", port)
	defer delete(url)
	c := cli({"--selftest"}, {lt = {server = url}})
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	for want in ([]string {
			"  file          : (no config directory)\n",
			"  chosen        : server, from LANGUAGETOOL_SERVER\n",
			fmt.tprintf("  url           : %s, from LANGUAGETOOL_SERVER\n", url),
		}) {
		testing.expectf(t, strings.contains(c.out, want), "lacks %q in:\n%s", want, c.out)
	}
}

// --selftest on a broken file, and on Premium without a key: exit 2, the
// problem shown, nothing probed. The key is never printed.
@(test)
selftest_reports_what_is_not_set_up :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cfg := put(t, dir, "config.json", transmute([]byte)string(`{"languagetool": {"backend": "nope"}}`))
	defer delete(cfg)
	broken := cli({"--selftest"}, {config_dir = dir})
	defer cli_done(&broken)
	testing.expect_value(t, broken.code, 2)
	want := fmt.tprintf("  file          : %s (broken)\n", cfg)
	testing.expectf(t, strings.contains(broken.out, want), "%s", broken.out)
	want = fmt.tprintf("  %s: \"languagetool.backend\" must be one of", cfg)
	testing.expectf(t, strings.contains(broken.out, want), "%s", broken.out)

	delete(put(t, dir, "config.json", transmute([]byte)string(`{"languagetool": {"backend": "premium", "username": "u"}}`)))
	nokey := cli({"--selftest"}, {config_dir = dir})
	defer cli_done(&nokey)
	testing.expect_value(t, nokey.code, 2)
	for line in ([]string{"  chosen        : premium, from config.json\n", "  api key       : (unset)\n", "Not set up\n  LanguageTool Premium has no key"}) {
		testing.expectf(t, strings.contains(nokey.out, line), "lacks %q in:\n%s", line, nokey.out)
	}

	// A key but no account: the key is reported by length only.
	delete(put(t, dir, "config.json", transmute([]byte)string(`{"languagetool": {"backend": "premium"}}`)))
	nouser := cli({"--selftest"}, {config_dir = dir, lt = {api_key = "SECRET-KEY-42"}})
	defer cli_done(&nouser)
	testing.expect_value(t, nouser.code, 2)
	testing.expectf(t, strings.contains(nouser.out, "  api key       : set, 13 chars, from LANGUAGETOOL_API_KEY\n"), "%s", nouser.out)
	testing.expectf(t, strings.contains(nouser.out, "needs the account"), "%s", nouser.out)
	testing.expect(t, !strings.contains(nouser.out, "SECRET"))
	testing.expect(t, !strings.contains(nouser.err, "SECRET"))
	free_all(context.temp_allocator)
}

// How --selftest words a key: by length and source, never the key.
@(test)
the_key_is_described_not_shown :: proc(t: ^testing.T) {
	Case :: struct {
		key:  string,
		from: prose.Key_Source,
		want: string,
	}
	for c in ([]Case {
			{"", .None, "(unset)"},
			{"abcdefgh", .Env, "set, 8 chars, from LANGUAGETOOL_API_KEY"},
			{"äöü", .Rbw, `set, 3 chars, from the rbw item "lt key"`},
			{"k", .Credentials, "set, 1 chars, from /c/credentials"},
		}) {
		got := prose.key_description(c.key, c.from, "lt key", "/c/credentials")
		defer delete(got)
		testing.expect_value(t, got, c.want)
	}
}

// Review Focus 1: CRLF, a lone CR and a BOM change no finding: the output
// is the golden file's.
@(test)
crlf_and_a_bom_change_nothing :: proc(t: ^testing.T) {
	md := read_file(CORPUS + "fixture.md")
	defer delete(md)
	want := read_file(GOLDEN + "fixture.json")
	defer delete(want)
	crlf, _ := strings.replace_all(md, "\n", "\r\n")
	defer delete(crlf)
	cr, _ := strings.replace_all(md, "\n", "\r")
	defer delete(cr)
	bom := strings.concatenate({"\uFEFF", md})
	defer delete(bom)
	bom_crlf := strings.concatenate({"\uFEFF", crlf})
	defer delete(bom_crlf)

	dir := scratch(t)
	defer scratch_done(dir)
	Case :: struct {
		name, text: string,
	}
	for c in ([]Case{{"crlf", crlf}, {"cr", cr}, {"bom", bom}, {"bom-crlf", bom_crlf}}) {
		path := put(t, dir, "fixture.md", transmute([]byte)c.text)
		defer delete(path)
		r := cli({"--no-lt", "--json", path}, {})
		defer cli_done(&r)
		got := as_named(r.out, path, "fixture.md")
		defer delete(got)
		testing.expectf(t, got == want, "%s: differs from the golden file:\n%s", c.name, got)
		testing.expectf(t, r.code == 1, "%s: exit %d", c.name, r.code)
		// The same through standard input.
		s := cli({"--no-lt", "--json", "--stdin"}, {}, c.text)
		defer cli_done(&s)
		sgot := as_named(s.out, "<stdin>", "fixture.md")
		defer delete(sgot)
		testing.expectf(t, sgot == want, "%s on stdin: differs from the golden file:\n%s", c.name, sgot)
	}
}

// Review Focus 2: a file that is not UTF-8 is exit 2, named, and no file is
// checked, not even one before it.
@(test)
a_file_that_is_not_utf8_is_exit_2 :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	bad := put(t, dir, "bad.md", []byte{'O', 'k', ' ', 0xff, '\n'})
	defer delete(bad)
	// A lone surrogate and a truncated sequence are not UTF-8 either.
	surrogate := put(t, dir, "surrogate.md", []byte{'a', 0xed, 0xa0, 0x80, '\n'})
	defer delete(surrogate)
	cut := put(t, dir, "cut.md", []byte{'a', 0xc3})
	defer delete(cut)
	good := CORPUS + "fixture.md"
	for path in ([]string{bad, surrogate, cut}) {
		for json in ([]bool{false, true}) {
			args := make([dynamic]string)
			defer delete(args)
			append(&args, "--no-lt", good, path)
			if json {
				append(&args, "--json")
			}
			c := cli(args[:], {})
			defer cli_done(&c)
			testing.expect_value(t, c.code, 2)
			want := fmt.tprintf("prose: %s is not UTF-8\n", path)
			testing.expect_value(t, c.err, want)
			testing.expect_value(t, c.out, "")
		}
	}
	s := cli({"--no-lt", "--stdin"}, {}, "Ok \xff\n")
	defer cli_done(&s)
	testing.expect_value(t, s.code, 2)
	testing.expect_value(t, s.err, "prose: <stdin> is not UTF-8\n")
	free_all(context.temp_allocator)
}

// A server backend through the command line: the JSON is the golden-lt
// file, and the text report's note line names the URL, which the JSON
// note does not.
@(test)
a_server_backend_gives_the_golden_lt_output :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d", port)
	defer delete(url)
	env := prose.Run_Env{lt = {server = url}, skill_dir = SKILL}
	path := CORPUS + "fixture.md"
	want := read_file(GOLDEN_LT + "fixture.json")
	defer delete(want)

	j := cli({"--json", path}, env)
	defer cli_done(&j)
	got := as_named(j.out, path, "fixture.md")
	defer delete(got)
	testing.expectf(t, got == want, "differs from golden-lt:\n%s", got)
	testing.expect_value(t, j.code, 1)
	testing.expect(t, !strings.contains(j.out, url))

	x := cli({path}, env)
	defer cli_done(&x)
	line := fmt.aprintf(
		"  language: de, en | self-hosted (%s): ok, 1 match(es) on the probe sentence, LanguageTool 6.9-SNAPSHOT, premium rules active\n",
		url,
	)
	defer delete(line)
	testing.expectf(t, strings.contains(x.out, line), "%s", x.out)
	testing.expect_value(t, x.code, 1)
}

// A server that answers JSON without matches is not checking. The probe
// fails and the run is exit 2, with nothing reported clean; --selftest FAILs
// it too. After a good probe, a check answer without matches is a failed
// chunk: exit 1 and LT-CHUNK-FAILED in the JSON.
@(test)
a_server_that_does_not_check_is_never_clean :: proc(t: ^testing.T) {
	path := CORPUS + "fixture.md"
	for mode in ([]Fake_Mode{.No_Matches, .Empty_Matches}) {
		fake, port := fake_lt_start(RECORDINGS, mode)
		defer fake_lt_stop(fake)
		if !testing.expect(t, fake != nil) {
			return
		}
		url := fmt.aprintf("http://127.0.0.1:%d", port)
		defer delete(url)
		env := prose.Run_Env{lt = {server = url}, skill_dir = SKILL}

		c := cli({path}, env)
		defer cli_done(&c)
		testing.expectf(t, c.code == 2, "%v: exit %d, out %q", mode, c.code, c.out)
		testing.expectf(t, strings.contains(c.err, "self-hosted"), "%v: stderr %q", mode, c.err)
		testing.expect_value(t, c.out, "")

		s := cli({"--selftest"}, env)
		defer cli_done(&s)
		testing.expectf(t, s.code == 2, "%v: selftest exit %d", mode, s.code)
		testing.expectf(t, strings.contains(s.out, "FAIL  self-hosted"), "%v: %s", mode, s.out)
	}

	fake, port := fake_lt_start(RECORDINGS, .No_Matches_After_Probe)
	defer fake_lt_stop(fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d", port)
	defer delete(url)
	c := cli({"--json", path}, prose.Run_Env{lt = {server = url}, skill_dir = SKILL})
	defer cli_done(&c)
	testing.expect_value(t, c.code, 1)
	testing.expect(t, strings.contains(c.out, `"rule": "LT-CHUNK-FAILED"`), c.out)
}

// Review Focus 3: an empty file and one that is only a code block find
// nothing, exit 0, and send no request at all; their JSON is the (hand
// corrected) golden-lt file.
@(test)
no_prose_sends_nothing :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Replay)
	defer fake_lt_stop(fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d", port)
	defer delete(url)
	for name in ([]string{"empty.md", "only-code.md"}) {
		path := strings.concatenate({CORPUS, name})
		defer delete(path)
		golden := strings.concatenate({GOLDEN_LT, name[:len(name) - 3], ".json"})
		defer delete(golden)
		want := read_file(golden)
		defer delete(want)
		c := cli({"--json", path}, {lt = {server = url}})
		defer cli_done(&c)
		got := as_named(c.out, path, name)
		defer delete(got)
		testing.expectf(t, got == want, "%s:\n%s", name, got)
		testing.expect_value(t, c.code, 0)
		testing.expect_value(t, c.err, "")
	}
	testing.expect_value(t, fake_lt_requests(fake), 0)
}

// A refusing backend stops the check with exit 2; it never reads as clean.
@(test)
a_refusing_backend_is_exit_2 :: proc(t: ^testing.T) {
	fake, port := fake_lt_start(RECORDINGS, .Refuse_403)
	defer fake_lt_stop(fake)
	if !testing.expect(t, fake != nil) {
		return
	}
	url := fmt.aprintf("http://127.0.0.1:%d", port)
	defer delete(url)
	for json in ([]bool{false, true}) {
		args := make([dynamic]string)
		defer delete(args)
		append(&args, CORPUS + "fixture.md")
		if json {
			append(&args, "--json")
		}
		c := cli(args[:], {lt = {server = url}})
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		want := fmt.aprintf(
			"prose: LanguageTool self-hosted (%s) answered HTTP 403; the check stops rather than use another backend\n",
			url,
		)
		defer delete(want)
		testing.expect_value(t, c.err, want)
		testing.expect_value(t, c.out, "")
	}
}

// Backend none with LanguageTool asked for: the note says it is off, in
// both outputs, and the local spelling pass runs, except on Windows.
@(test)
backend_none_says_languagetool_is_off :: proc(t: ^testing.T) {
	text := "This is the colr that you will have.\n"
	j := cli({"--json", "--stdin"}, {hunspell_command = #directory + "stub/hunspell"}, text)
	defer cli_done(&j)
	testing.expectf(t, strings.contains(j.out, `"note": "language: en | ` + OFF + `"`), "%s", j.out)
	testing.expectf(t, strings.contains(j.out, `"rule": "HUNSPELL"`) == (ODIN_OS != .Windows), "%s", j.out)
	testing.expect_value(t, j.code, 0)
	x := cli({"--stdin"}, {}, text)
	defer cli_done(&x)
	testing.expectf(t, strings.contains(x.out, "\n  language: en | " + OFF + "\n"), "%s", x.out)
	// With --no-lt there is no LanguageTool part at all.
	n := cli({"--json", "--stdin", "--no-lt"}, {}, text)
	defer cli_done(&n)
	testing.expect(t, strings.contains(n.out, `"note": "language: en",`))
}
