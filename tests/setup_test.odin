package prose_tests

import "core:os"
import "core:strings"
import "core:testing"
import prose "../src"

// `prose-check --setup --values-stdin` and the scripted `--setup`, through
// `run` and `apply_values`. Every test makes its own directory and removes
// it at the end; none touches the process environment.

@(private = "file")
NO_TERMINAL :: "prose-check --setup needs a terminal; use --values-stdin"
@(private = "file")
NEVER_IN_FILE :: "the key never goes in the settings file"

@(private = "file")
Cli :: struct {
	code:     int,
	out, err: string,
}

@(private = "file")
cli_done :: proc(c: ^Cli) {
	delete(c.out)
	delete(c.err)
}

// cli runs `args` with `stdin`, the config directory `dir` and the given
// terminal flags.
@(private = "file")
cli :: proc(args: []string, dir, stdin: string, tty := false) -> Cli {
	env := prose.Run_Env {
		config_dir         = dir,
		hunspell_command   = "/nonexistent/hunspell",
		stdin_is_terminal  = tty,
		stdout_is_terminal = tty,
	}
	out := strings.builder_make()
	errb := strings.builder_make()
	r: strings.Reader
	code := prose.run(args, strings.to_reader(&r, stdin), strings.to_writer(&out), strings.to_writer(&errb), env)
	return Cli{code, strings.to_string(out), strings.to_string(errb)}
}

@(private = "file")
values :: proc(dir, json_text: string) -> Cli {
	return cli({"--setup", "--values-stdin"}, dir, json_text)
}

@(private = "file")
scratch :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "prose-task11-*", context.allocator)
	testing.expect(t, err == nil)
	return dir
}

@(private = "file")
scratch_done :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

@(private = "file")
join :: proc(parts: ..string) -> string {
	path, _ := os.join_path(parts, context.allocator)
	return path
}

@(private = "file")
put :: proc(t: ^testing.T, path, content: string) {
	testing.expect(t, os.write_entire_file_from_string(path, content) == nil)
}

// read gives the file's text, or "(missing)" when there is none.
@(private = "file")
read :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		delete(data)
		return strings.clone("(missing)")
	}
	return string(data)
}

// names lists the entries of `dir`, sorted, joined with a space.
@(private = "file")
names :: proc(dir: string) -> string {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		return strings.clone("(unreadable)")
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	list := make([]string, len(infos), context.temp_allocator)
	for info, i in infos {
		list[i] = info.name
	}
	for i in 1 ..< len(list) {
		for j := i; j > 0 && list[j] < list[j - 1]; j -= 1 {
			list[j], list[j - 1] = list[j - 1], list[j]
		}
	}
	return strings.join(list, " ")
}

@(private = "file")
expect_file :: proc(t: ^testing.T, path, want: string, loc := #caller_location) {
	got := read(path)
	defer delete(got)
	testing.expect_value(t, got, want, loc)
}

@(private = "file")
expect_contains :: proc(t: ^testing.T, text, want: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(text, want), "%q does not contain %q", text, want, loc = loc)
}

@(private = "file")
expect_lacks :: proc(t: ^testing.T, text, unwanted: string, loc := #caller_location) {
	testing.expectf(t, !strings.contains(text, unwanted), "%q contains %q", text, unwanted, loc = loc)
}

@(test)
values_stdin_writes_the_file :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := values(dir, `{"languagetool": {"backend": "public"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	testing.expect_value(t, c.err, "")
	expect_contains(t, c.out, path)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n")
	// The checker reads what setup wrote.
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.backend, prose.Backend_Kind.Public)
}

@(test)
a_second_call_keeps_the_other_keys :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c1 := values(dir, `{"languagetool": {"backend": "public"}}`)
	defer cli_done(&c1)
	c2 := values(dir, `{"languageRule": "Sie in Mails"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"languageRule\": \"Sie in Mails\",\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n",
	)
}

@(test)
languagetool_merges_key_by_key :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languagetool": {"backend": "premium", "username": "u", "keyItem": "item"}}`)
	c := values(dir, `{"languagetool": {"username": "v"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"languagetool\": {\n    \"backend\": \"premium\",\n    \"username\": \"v\",\n    \"keyItem\": \"item\"\n  }\n}\n",
	)
}

@(test)
null_inside_a_first_languagetool_object_is_not_written :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := values(dir, `{"languagetool": {"backend": "public", "server": null}, "languageRule": null}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n")
}

@(test)
a_given_list_replaces_the_stored_one :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"ignoreWords": ["a", "b"]}`)
	c := values(dir, `{"ignoreWords": ["c"]}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, path, "{\n  \"ignoreWords\": [\n    \"c\"\n  ]\n}\n")
}

@(test)
null_deletes_a_key :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "R", "languagetool": {"backend": "server", "server": "https://lt.example.org"}}`)
	// Switching away from the server: the URL goes, the rest stays.
	c := values(dir, `{"languagetool": {"backend": "public", "server": null}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"languageRule\": \"R\",\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n",
	)
	c2 := values(dir, `{"languageRule": null}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 0)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n")
	// Deleting the last key of languagetool drops the empty object; a key
	// that is not there is no error.
	c3 := values(dir, `{"languagetool": {"backend": null, "nothing": null}, "absent": null}`)
	defer cli_done(&c3)
	testing.expect_value(t, c3.code, 0)
	expect_file(t, path, "{}\n")
	// A whole languagetool object can go at once.
	put(t, path, `{"languagetool": {"backend": "public"}, "ignoreWords": ["x"]}`)
	c4 := values(dir, `{"languagetool": null}`)
	defer cli_done(&c4)
	testing.expect_value(t, c4.code, 0)
	expect_file(t, path, "{\n  \"ignoreWords\": [\n    \"x\"\n  ]\n}\n")
}

@(test)
unknown_keys_keep_their_values_and_come_last_sorted :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(
		t,
		path,
		`{"zeta": {"b": [1, 2.5, true, null, "x\"y\nzä\u0001"], "a": {}, "e": []}, "alpha": "é", "languagetool": {"extra": {"k": 1}, "backend": "public"}, "n": -7}`,
	)
	c := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	want := `{
  "languageRule": "R",
  "languagetool": {
    "backend": "public",
    "extra": {
      "k": 1
    }
  },
  "alpha": "é",
  "n": -7,
  "zeta": {
    "a": {},
    "b": [
      1,
      2.5,
      true,
      null,
      "x\"y\nzä\u0001"
    ],
    "e": []
  }
}
`
	expect_file(t, path, want)
	// And the same again: the output is stable.
	c2 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c2)
	expect_file(t, path, want)
}

@(test)
the_key_order_does_not_depend_on_the_input_order :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := values(
		dir,
		`{"zz": 1, "languagetool": {"keyItem": "k", "username": "u", "backend": "premium"}, "ignoreWords": ["w"], "languageRule": "R"}`,
	)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"languageRule\": \"R\",\n  \"ignoreWords\": [\n    \"w\"\n  ],\n  \"languagetool\": {\n    \"backend\": \"premium\",\n    \"username\": \"u\",\n    \"keyItem\": \"k\"\n  },\n  \"zz\": 1\n}\n",
	)
}

@(test)
text_with_escapes_and_umlauts_survives :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	rule := "Sie \"Du\" \\ Tab\there\nZeile äöü \U0001F600"
	c := values(dir, `{"languageRule": "Sie \"Du\" \\ Tab\there\nZeile äöü 😀"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.language_rule, rule)
}

@(test)
a_typo_in_the_backend_exits_2_and_leaves_the_file_alone :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	before := "{\"languagetool\":   {\"backend\": \"public\"}}"
	put(t, path, before)
	c := values(dir, `{"languagetool": {"backend": "premuim"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expect_value(t, c.out, "")
	expect_contains(t, c.err, "languagetool.backend")
	// The fault is in the values, so the message names them and not the file.
	expect_contains(t, c.err, "the values on standard input")
	expect_lacks(t, c.err, path)
	expect_contains(t, c.err, "unchanged")
	expect_file(t, path, before)
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "config.json")
}

@(test)
a_failed_first_write_leaves_no_file :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cfg := join(dir, "prose")
	defer delete(cfg)
	c := values(cfg, `{"languagetool": {"backend": "premuim"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	path := join(cfg, "config.json")
	defer delete(path)
	testing.expect(t, !os.exists(path))
	// No temporary file is left behind either.
	if os.exists(cfg) {
		listing := names(cfg)
		defer delete(listing)
		testing.expect_value(t, listing, "")
	}
}

@(test)
the_server_backend_needs_a_url :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, "{}")
	c := values(dir, `{"languagetool": {"backend": "server"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, "languagetool.server")
	expect_file(t, path, "{}")
	// Taking the URL away from a server backend is refused too.
	put(t, path, `{"languagetool": {"backend": "server", "server": "https://lt.example.org"}}`)
	c2 := values(dir, `{"languagetool": {"server": null}}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 2)
	expect_file(t, path, `{"languagetool": {"backend": "server", "server": "https://lt.example.org"}}`)
}

@(test)
wrong_types_in_the_values_are_refused :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep"}`)
	for bad in ([]string {
			`{"languageRule": 5}`,
			`{"ignoreWords": "x"}`,
			`{"ignoreWords": [1]}`,
			`{"languagetool": "public"}`,
			`{"languagetool": {"server": 3}}`,
			`{"languagetool": {"server": "lt.example.org"}}`,
			`{"languagetool": {"username": []}}`,
		}) {
		c := values(dir, bad)
		testing.expectf(t, c.code == 2, "%s: exit %d", bad, c.code)
		expect_file(t, path, `{"languageRule": "keep"}`)
		cli_done(&c)
	}
}

// A wrong type in the values is the values' fault: the message names where
// they came from. The file is named only for what is wrong in the file.
@(test)
a_wrong_type_names_its_source_not_the_settings_file :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep"}`)
	Case :: struct {
		values, want: string,
	}
	for c in ([]Case {
			{`{"languageRule": 5}`, `"languageRule" must be a string`},
			{`{"ignoreWords": "x"}`, `"ignoreWords" must be a list of strings`},
			{`{"languagetool": "public"}`, `"languagetool" must be an object`},
			{`{"languagetool": {"server": 3}}`, `"languagetool.server" must be a string`},
			{`{"languagetool": {"username": []}}`, `"languagetool.username" must be a string`},
			{`{"languagetool": {"keyItem": {}}}`, `"languagetool.keyItem" must be a string`},
			{`{"languagetool": {"backend": 3}}`, `"languagetool.backend" must be one of`},
			{`{"languagetool": {"server": "lt.example.org"}}`, `"languagetool.server" must start with http:// or https://`},
		}) {
		r := values(dir, c.values)
		defer cli_done(&r)
		testing.expectf(t, r.code == 2, "%s: exit %d", c.values, r.code)
		want := strings.concatenate({"prose: the values on standard input: ", c.want})
		defer delete(want)
		expect_contains(t, r.err, want)
		expect_lacks(t, r.err, path)
		expect_file(t, path, `{"languageRule": "keep"}`)
	}
	// What is wrong in the merged file is the file's, and it is named.
	put(t, path, `{"languagetool": {"backend": "server"}}`)
	r := values(dir, `{"languageRule": "x"}`)
	defer cli_done(&r)
	testing.expect_value(t, r.code, 2)
	expect_contains(t, r.err, path)
	// A null deletes and is not a wrong type.
	put(t, path, `{"languageRule": "r", "languagetool": {"server": "http://x", "username": "u"}}`)
	r2 := values(dir, `{"languageRule": null, "languagetool": {"server": null, "username": null}}`)
	defer cli_done(&r2)
	testing.expect_value(t, r2.code, 0)
	expect_file(t, path, "{}\n")
}

@(test)
input_that_is_not_a_json_object_is_refused :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep"}`)
	for bad in ([]string {
			``,
			`   `,
			`{`,
			`[]`,
			`"x"`,
			`null`,
			`{"languageRule": "a"} {"languageRule": "b"}`,
			`{"languageRule": "a"} trailing`,
			`{"languageRule": "a", "languageRule": "b"}`,
			"\xff\xfe",
		}) {
		c := values(dir, bad)
		testing.expectf(t, c.code == 2, "%q: exit %d", bad, c.code)
		expect_contains(t, c.err, "prose: ")
		expect_file(t, path, `{"languageRule": "keep"}`)
		cli_done(&c)
	}
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "config.json")
}

@(test)
oversized_values_are_refused :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	big := strings.repeat("a", prose.MAX_SETTINGS_BYTES)
	defer delete(big)
	text := strings.concatenate({`{"languageRule": "`, big, `"}`})
	defer delete(text)
	c := values(dir, text)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expect(t, !os.exists(path))
}

@(test)
the_key_never_goes_in_the_file :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	before := `{"languageRule": "keep"}`
	put(t, path, before)
	for bad in ([]string {
			`{"apiKey": "SECRET-KEY"}`,
			`{"languagetool": {"apiKey": "SECRET-KEY"}}`,
			`{"languagetool": {"backend": "premium", "apiKey": null}}`,
			`{"apikey": "SECRET-KEY"}`,
			`{"languageRule": "x", "api_key": "SECRET-KEY"}`,
			`{"key": "SECRET-KEY"}`,
			`{"KEY": "SECRET-KEY"}`,
			`{"password": "SECRET-KEY"}`,
			`{"Password": "SECRET-KEY"}`,
			`{"token": "SECRET-KEY"}`,
			`{"TOKEN": "SECRET-KEY"}`,
			`{"languagetool": {"key": "SECRET-KEY"}}`,
			`{"languagetool": {"apikey": "SECRET-KEY"}}`,
			`{"languagetool": {"PassWord": "SECRET-KEY"}}`,
			`{"languagetool": {"backend": "premium", "token": "SECRET-KEY"}}`,
		}) {
		c := values(dir, bad)
		testing.expectf(t, c.code == 2, "%s: exit %d", bad, c.code)
		expect_contains(t, c.err, NEVER_IN_FILE)
		expect_lacks(t, c.err, "SECRET-KEY")
		expect_lacks(t, c.out, "SECRET-KEY")
		expect_file(t, path, before)
		cli_done(&c)
	}
	// Nothing at all is created for a refused first call.
	fresh := join(dir, "fresh")
	defer delete(fresh)
	c := values(fresh, `{"apiKey": "SECRET-KEY"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expect(t, !os.exists(fresh))
}

@(test)
a_missing_config_directory_is_created :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cfg := join(dir, "xdg", "prose")
	defer delete(cfg)
	path := join(cfg, "config.json")
	defer delete(path)
	c := values(cfg, `{"languagetool": {"backend": "none"}, "languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	// A second call with one key keeps the others.
	c2 := values(cfg, `{"ignoreWords": ["Proxmox"]}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 0)
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.backend, prose.Backend_Kind.None)
	testing.expect_value(t, s.language_rule, "R")
	testing.expect_value(t, len(s.ignore_words), 1)
	when ODIN_OS != .Windows {
		info, serr := os.stat(cfg, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, serr == nil)
		testing.expect_value(t, info.mode, os.perm_number(0o700))
		finfo, ferr := os.stat(path, context.allocator)
		defer os.file_info_delete(finfo, context.allocator)
		testing.expect(t, ferr == nil)
		testing.expect_value(t, finfo.mode, os.perm_number(0o600))
	}
	listing := names(cfg)
	defer delete(listing)
	testing.expect_value(t, listing, "config.json")
}

@(test)
an_existing_directory_keeps_its_mode_and_the_other_files :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cred := join(dir, "credentials")
	defer delete(cred)
	put(t, cred, "the-key")
	c := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, cred, "the-key")
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "config.json credentials")
}

@(test)
a_broken_settings_file_is_not_overwritten :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languagetool": {"backend": "premuim"}}`)
	c := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, path)
	expect_contains(t, c.err, "languagetool.backend")
	expect_file(t, path, `{"languagetool": {"backend": "premuim"}}`)
	// Not JSON at all.
	put(t, path, "{")
	c2 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 2)
	expect_file(t, path, "{")
	// A directory where the file should be.
	_ = os.remove(path)
	testing.expect(t, os.make_directory(path) == nil)
	c3 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c3)
	testing.expect_value(t, c3.code, 2)
	testing.expect(t, os.is_dir(path))
}

@(test)
no_config_directory_exits_2 :: proc(t: ^testing.T) {
	c := values("", `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, "no config directory")
}

@(test)
setup_without_a_terminal_exits_2 :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	c := cli({"--setup"}, dir, "public\n")
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expect_value(t, c.err, NO_TERMINAL + "\n")
	testing.expect_value(t, c.out, "")
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "")
	// A terminal on stdin alone is not enough: the prompts go to stdout.
	env := prose.Run_Env {
		config_dir        = dir,
		stdin_is_terminal = true,
	}
	errb := strings.builder_make()
	defer strings.builder_destroy(&errb)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	r: strings.Reader
	code := prose.run({"--setup"}, strings.to_reader(&r, ""), strings.to_writer(&out), strings.to_writer(&errb), env)
	testing.expect_value(t, code, 2)
	testing.expect_value(t, strings.to_string(errb), NO_TERMINAL + "\n")
}

@(test)
values_stdin_needs_setup_and_setup_takes_no_files :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	c := cli({"--values-stdin"}, dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, "--values-stdin")
	c2 := cli({"--setup", "--values-stdin", "some.md"}, dir, `{"languageRule": "R"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 2)
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "")
}

@(test)
apply_values_is_callable_on_its_own :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	err := prose.apply_values(path, `{"languageRule": "R"}`)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.problem, "")
	expect_file(t, path, "{\n  \"languageRule\": \"R\"\n}\n")
	bad := prose.apply_values(path, `{"languagetool": {"backend": "x"}}`)
	defer prose.settings_error_destroy(&bad)
	testing.expect(t, bad.problem != "")
	testing.expect_value(t, bad.path, path)
}

@(test)
a_directory_that_cannot_be_written_leaves_the_old_file :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		path := join(dir, "config.json")
		defer delete(path)
		put(t, path, `{"languageRule": "keep"}`)
		testing.expect(t, os.change_mode(dir, os.perm_number(0o500)) == nil)
		defer _ = os.change_mode(dir, os.perm_number(0o700))
		probe := join(dir, "probe")
		defer delete(probe)
		if os.write_entire_file_from_string(probe, "x") == nil {
			// Running as a user the mode does not bind (root): nothing to test.
			_ = os.remove(probe)
			return
		}
		c := values(dir, `{"languageRule": "new"}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		expect_contains(t, c.err, "unchanged")
		expect_file(t, path, `{"languageRule": "keep"}`)
	}
}

// ---- the questions on a terminal ----

@(private = "file")
Tty :: struct {
	code:     int,
	out, err: string,
}

@(private = "file")
tty_done :: proc(c: ^Tty) {
	delete(c.out)
	delete(c.err)
}

// ask runs `--setup` on a terminal that answers with `answers`.
@(private = "file")
ask :: proc(dir, answers: string) -> Tty {
	c := cli({"--setup"}, dir, answers, tty = true)
	return Tty{c.code, c.out, c.err}
}

@(test)
setup_asks_and_writes_premium :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	cred := join(dir, "credentials")
	defer delete(cred)
	// The line after the rule is what a user must never type here: nothing
	// reads it, and nothing prints it.
	c := ask(dir, "premium\nsomeone@example.org\nvault-item\n\nSECRET-KEY\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	testing.expect_value(t, c.err, "")
	// Where each backend sends the text.
	expect_contains(t, c.out, "nothing leaves this machine")
	expect_contains(t, c.out, "your text goes to LanguageTool's free public server")
	expect_contains(t, c.out, "your text goes to LanguageTool's Premium API under your account")
	expect_contains(t, c.out, "your text goes to the server you name")
	// The three key sources, as --selftest names them, and no question for the key.
	expect_contains(t, c.out, "LANGUAGETOOL_API_KEY")
	expect_contains(t, c.out, "languagetool.keyItem")
	expect_contains(t, c.out, "rbw")
	expect_contains(t, c.out, cred)
	expect_contains(t, c.out, "mode 600")
	expect_lacks(t, c.out, "SECRET-KEY")
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.backend, prose.Backend_Kind.Premium)
	testing.expect_value(t, s.username, "someone@example.org")
	testing.expect_value(t, s.key_item, "vault-item")
	testing.expect_value(t, s.language_rule, "")
	testing.expect_value(t, s.server, "")
	got := read(path)
	defer delete(got)
	expect_lacks(t, got, "SECRET-KEY")
	expect_lacks(t, got, "languageRule")
}

@(test)
setup_asks_for_a_server_and_a_rule :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	// A server that is no URL is asked again.
	c := ask(dir, "server\nlt.example.org\nhttps://lt.example.org\nSie in Mails\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_contains(t, c.out, "http://")
	expect_lacks(t, c.out, "LANGUAGETOOL_API_KEY")
	expect_file(
		t,
		path,
		"{\n  \"languageRule\": \"Sie in Mails\",\n  \"languagetool\": {\n    \"backend\": \"server\",\n    \"server\": \"https://lt.example.org\"\n  }\n}\n",
	)
}

@(test)
setup_takes_a_url_scheme_in_any_case :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := ask(dir, "server\nHTTPS://lt.example.org\n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_lacks(t, c.out, "has to start with")
	expect_file(
		t,
		path,
		"{\n  \"languagetool\": {\n    \"backend\": \"server\",\n    \"server\": \"HTTPS://lt.example.org\"\n  }\n}\n",
	)
}

@(test)
setup_drops_the_server_when_switching_to_another_backend :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"ignoreWords": ["x"], "languagetool": {"backend": "server", "server": "https://lt.example.org"}}`)
	c := ask(dir, "public\n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"ignoreWords\": [\n    \"x\"\n  ],\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n",
	)
}

@(test)
setup_asks_again_after_an_answer_it_does_not_know :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := ask(dir, "premuim\r\nPublic \n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_contains(t, c.out, "premuim")
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n")
}

@(test)
setup_with_empty_answers_chooses_none_or_keeps_what_is_stored :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := ask(dir, "\n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"none\"\n  }\n}\n")
	put(t, path, `{"languagetool": {"backend": "premium", "username": "u", "keyItem": "k"}, "languageRule": "old"}`)
	c2 := ask(dir, "\n\n\n\n")
	defer tty_done(&c2)
	testing.expect_value(t, c2.code, 0)
	// Every empty answer keeps what is stored, the rule too.
	want := "{\n  \"languageRule\": \"old\",\n  \"languagetool\": {\n    \"backend\": \"premium\",\n    \"username\": \"u\",\n    \"keyItem\": \"k\"\n  }\n}\n"
	expect_file(t, path, want)
	expect_contains(t, c2.out, "old")
	expect_contains(t, c2.out, "empty keeps")
	// A single dash clears the rule and the item.
	c3 := ask(dir, "\n\n-\n-\n")
	defer tty_done(&c3)
	testing.expect_value(t, c3.code, 0)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"premium\",\n    \"username\": \"u\"\n  }\n}\n")
}

@(test)
setup_stops_when_the_input_ends :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep"}`)
	for answers in ([]string{"", "premium\n", "premium\nu", "server\n", "public"}) {
		c := ask(dir, answers)
		testing.expectf(t, c.code == 2, "%q: exit %d", answers, c.code)
		expect_contains(t, c.err, "prose: ")
		expect_file(t, path, `{"languageRule": "keep"}`)
		tty_done(&c)
	}
}

@(test)
setup_refuses_an_unusable_settings_file :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, "{")
	c := ask(dir, "public\n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, path)
	expect_file(t, path, "{")
}

@(test)
run_setup_tty_takes_a_reader_and_a_writer :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	errb := strings.builder_make()
	defer strings.builder_destroy(&errb)
	r: strings.Reader
	code := prose.run_setup_tty(strings.to_reader(&r, "none\n\n"), strings.to_writer(&out), strings.to_writer(&errb), path)
	testing.expect_value(t, code, 0)
	expect_file(t, path, "{\n  \"languagetool\": {\n    \"backend\": \"none\"\n  }\n}\n")
	// A very long answer is refused, not buffered without end.
	long := strings.repeat("x", 200 << 10)
	defer delete(long)
	text := strings.concatenate({"none\n", long, "\n"})
	defer delete(text)
	r2: strings.Reader
	out2 := strings.builder_make()
	defer strings.builder_destroy(&out2)
	err2 := strings.builder_make()
	defer strings.builder_destroy(&err2)
	code2 := prose.run_setup_tty(strings.to_reader(&r2, text), strings.to_writer(&out2), strings.to_writer(&err2), path)
	testing.expect_value(t, code2, 2)
	expect_contains(t, strings.to_string(err2), "too long")
}

@(test)
setup_repairs_a_stored_value_that_fails_validation :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep", "languagetool": {"backend": "premuim"}}`)
	c := ask(dir, "public\n\n")
	defer tty_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, path, "{\n  \"languageRule\": \"keep\",\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n")
}

@(test)
values_stdin_repairs_a_stored_typo :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languagetool": {"backend": "premuim"}, "ignoreWords": ["x"]}`)
	c := values(dir, `{"languagetool": {"backend": "premium", "username": "u"}}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"ignoreWords\": [\n    \"x\"\n  ],\n  \"languagetool\": {\n    \"backend\": \"premium\",\n    \"username\": \"u\"\n  }\n}\n",
	)
}

// ---- a settings file that is a link ----

@(test)
a_linked_settings_file_stays_a_link :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		store := join(dir, "store")
		defer delete(store)
		cfg := join(dir, "cfg")
		defer delete(cfg)
		testing.expect(t, os.make_directory(store) == nil)
		testing.expect(t, os.make_directory(cfg) == nil)
		target := join(store, "real.json")
		defer delete(target)
		mid := join(store, "mid.json")
		defer delete(mid)
		link := join(cfg, "config.json")
		defer delete(link)
		put(t, target, `{"languageRule": "keep"}`)
		// A chain: cfg/config.json -> (absolute) store/mid.json -> (relative) real.json
		testing.expect(t, os.symlink("real.json", mid) == nil)
		testing.expect(t, os.symlink(mid, link) == nil)
		c := values(cfg, `{"languagetool": {"backend": "public"}}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 0)
		info, err := os.lstat(link, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
		minfo, merr := os.lstat(mid, context.allocator)
		defer os.file_info_delete(minfo, context.allocator)
		testing.expect(t, merr == nil)
		testing.expect_value(t, minfo.type, os.File_Type.Symlink)
		expect_file(
			t,
			target,
			"{\n  \"languageRule\": \"keep\",\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n",
		)
		listing := names(store)
		defer delete(listing)
		testing.expect_value(t, listing, "mid.json real.json")
		// A relative link in the config directory itself.
		rel := join(cfg, "other.json")
		defer delete(rel)
		testing.expect(t, os.symlink("../store/real.json", rel) == nil)
		err2 := prose.apply_values(rel, `{"ignoreWords": ["w"]}`)
		defer prose.settings_error_destroy(&err2)
		testing.expect_value(t, err2.problem, "")
		got := read(target)
		defer delete(got)
		expect_contains(t, got, `"w"`)
		expect_contains(t, got, `"languageRule"`)
	}
}

@(test)
a_link_into_a_read_only_directory_fails_cleanly :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		store := join(dir, "store")
		defer delete(store)
		cfg := join(dir, "cfg")
		defer delete(cfg)
		testing.expect(t, os.make_directory(store) == nil)
		testing.expect(t, os.make_directory(cfg) == nil)
		target := join(store, "real.json")
		defer delete(target)
		link := join(cfg, "config.json")
		defer delete(link)
		put(t, target, `{"languageRule": "keep"}`)
		testing.expect(t, os.symlink(target, link) == nil)
		testing.expect(t, os.change_mode(store, os.perm_number(0o500)) == nil)
		defer _ = os.change_mode(store, os.perm_number(0o700))
		probe := join(store, "probe")
		defer delete(probe)
		if os.write_entire_file_from_string(probe, "x") == nil {
			_ = os.remove(probe)
			return
		}
		c := values(cfg, `{"languageRule": "new"}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		expect_contains(t, c.err, "cannot write")
		expect_contains(t, c.err, target)
		expect_file(t, target, `{"languageRule": "keep"}`)
		info, err := os.lstat(link, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
		listing := names(cfg)
		defer delete(listing)
		testing.expect_value(t, listing, "config.json")
	}
}

@(test)
a_link_loop_is_refused :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		link := join(dir, "config.json")
		defer delete(link)
		testing.expect(t, os.symlink("config.json", link) == nil)
		c := values(dir, `{"languageRule": "R"}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		expect_contains(t, c.err, "too many links")
		info, err := os.lstat(link, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
	}
}
