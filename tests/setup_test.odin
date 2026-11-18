package prose_tests

import "core:fmt"
import "core:io"
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

@(private = "file")
exists_in :: proc(dir, name: string) -> bool {
	path := join(dir, name)
	defer delete(path)
	return os.exists(path)
}

@(private = "file")
cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// read_text is `read` for a call that does not free: the result is the
// temporary allocator's.
@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "(missing)"
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
	path_of :: proc(cfg: string) -> string {
		return join(cfg, "config.json")
	}
	// A fault in the values stops before anything is made. A server backend
	// without a URL passes the values and fails the check of the merged file,
	// after the directory and the temporary file exist: both must go.
	for bad, i in ([]string{`{"languagetool": {"backend": "premuim"}}`, `{"languagetool": {"backend": "server"}}`}) {
		cfg := join(dir, "prose", fmt.tprint(i))
		defer delete(cfg)
		c := values(cfg, bad)
		defer cli_done(&c)
		testing.expectf(t, c.code == 2, "%s: exit %d", bad, c.code)
		path := path_of(cfg)
		defer delete(path)
		testing.expect(t, !os.exists(path))
		// Nothing is left of the directory this call made, and so no
		// temporary file either.
		testing.expectf(t, !os.exists(cfg), "%s was left behind", cfg)
	}
}

// The id in a leftover's name is read from a directory a user may fill: a
// number too wide for a process id is no id, and must not wrap into one.
@(test)
a_leftover_named_with_a_too_wide_process_id_is_not_ours :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir := scratch(t)
	defer scratch_done(dir)
	child, cerr := os.process_start(os.Process_Desc{command = {"true"}})
	if cerr != nil {
		return
	}
	_, _ = os.process_wait(child)
	dead := u128(child.pid)
	// Each of these is `dead` once wrapped to 64 bits or to 32.
	wide := [?]string {
		fmt.tprintf(".config.json.%d.0.tmp", (u128(1) << 64) + dead),
		fmt.tprintf(".config.json.%d.0.tmp", (u128(1) << 32) + dead),
		fmt.tprintf(".config.json.%d.0.tmp", (u128(1) << 63) + dead),
		fmt.tprintf(".config.json.0000000000000%d.0.tmp", dead),
	}
	plain := fmt.tprintf(".config.json.%d.1.tmp", dead)
	for name in wide {
		f := join(dir, name)
		defer delete(f)
		put(t, f, "not ours")
	}
	f := join(dir, plain)
	defer delete(f)
	put(t, f, "half a write")

	c := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	testing.expectf(t, !exists_in(dir, plain), "%s was not swept", plain)
	for name in wide {
		testing.expectf(t, exists_in(dir, name), "%s was swept", name)
	}
}

// Leftovers of a crashed write, `.config.json.<pid>.<n>.tmp`, are swept when
// the process that left them is gone. POSIX only; Windows cannot tell.
@(test)
temporary_files_of_dead_processes_are_swept :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir := scratch(t)
	defer scratch_done(dir)
	// A process that has ended: its id is free.
	child, cerr := os.process_start(os.Process_Desc{command = {"true"}})
	if cerr != nil {
		return
	}
	_, _ = os.process_wait(child)
	dead := child.pid
	own := os.get_pid()
	stale := fmt.tprintf(".config.json.%d.0.tmp", dead)
	stale2 := fmt.tprintf(".config.json.%d.17.tmp", dead)
	own_tmp := fmt.tprintf(".config.json.%d.5.tmp", own)
	init_tmp := ".config.json.1.0.tmp" // process 1 always lives
	// Names that are not ours stay, whoever's id they carry.
	keepers := [?]string {
		fmt.tprintf(".config.json.%d.tmp", dead),
		fmt.tprintf(".config.json.%d.0.tmp.bak", dead),
		fmt.tprintf("config.json.%d.0.tmp", dead),
		fmt.tprintf(".config.json.%d.x.tmp", dead),
		fmt.tprintf(".config.json.x.0.tmp"),
		fmt.tprintf(".config.json.%d.0.1.tmp", dead),
		"credentials",
		"dictionary.txt",
	}
	for name in ([]string{stale, stale2, own_tmp, init_tmp}) {
		f := join(dir, name)
		defer delete(f)
		put(t, f, "half a write")
	}
	for name in keepers {
		f := join(dir, name)
		defer delete(f)
		put(t, f, "other")
	}
	// A directory named like a leftover is not one.
	adir := join(dir, fmt.tprintf(".config.json.%d.3.tmp", dead))
	defer delete(adir)
	testing.expect(t, os.make_directory(adir) == nil)

	c := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	testing.expectf(t, !exists_in(dir, stale), "%s was not swept", stale)
	testing.expectf(t, !exists_in(dir, stale2), "%s was not swept", stale2)
	testing.expect(t, exists_in(dir, own_tmp), "a file of this very process was swept")
	testing.expect(t, exists_in(dir, init_tmp), "a file of a live process was swept")
	for name in keepers {
		testing.expectf(t, exists_in(dir, name), "%s was swept", name)
	}
	testing.expect(t, os.is_dir(adir))
}

// The checks the sweep relies on.
@(test)
a_process_id_is_alive_or_free :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	testing.expect(t, prose.process_may_be_alive(os.get_pid()))
	testing.expect(t, prose.process_may_be_alive(1))
	testing.expect(t, !prose.process_may_be_alive(0))
	testing.expect(t, !prose.process_may_be_alive(-5))
	child, cerr := os.process_start(os.Process_Desc{command = {"true"}})
	if cerr == nil {
		_, _ = os.process_wait(child)
		testing.expect(t, !prose.process_may_be_alive(child.pid))
	}
	// A directory can be synced; one that is not there reports it.
	dir := scratch(t)
	defer scratch_done(dir)
	testing.expect(t, prose.sync_directory(dir) == nil)
	gone := join(dir, "gone")
	defer delete(gone)
	testing.expect(t, prose.sync_directory(gone) != nil)
}

// A directory that cannot be made is reported with the one that failed.
@(test)
a_parent_that_cannot_be_made_is_reported :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir := scratch(t)
	defer scratch_done(dir)
	locked := join(dir, "locked")
	defer delete(locked)
	testing.expect(t, os.make_directory(locked) == nil)
	testing.expect(t, os.change_mode(locked, os.perm_number(0o500)) == nil)
	defer _ = os.change_mode(locked, os.perm_number(0o700))
	probe := join(locked, "probe")
	defer delete(probe)
	if os.write_entire_file_from_string(probe, "x") == nil {
		_ = os.remove(probe)
		return // running as a user the mode does not bind
	}
	cfg := join(locked, "deeper", "prose")
	defer delete(cfg)
	c := values(cfg, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	deeper := join(locked, "deeper")
	defer delete(deeper)
	expect_contains(t, c.err, cat("the directory ", deeper, " cannot be made"))
	expect_contains(t, c.err, "unchanged")
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

// One wording, in the checker and in setup: the text must be a JSON object.
@(test)
setup_and_the_checker_word_a_non_object_alike :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	c := values(dir, `[1]`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	expect_contains(t, c.err, "prose: the values on standard input must be a JSON object\n")
	put(t, path, `[]`)
	c2 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 2)
	expect_contains(t, c2.err, cat(path, ": must be a JSON object"))
	expect_lacks(t, c2.err, "is not a JSON object")
	expect_file(t, path, `[]`)
	// The checker says the same of the same file.
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	expect_contains(t, err.problem, "must be a JSON object")
}

// v0.1.0 took a trailing comma in the values and in the stored file, so
// both still go in, and setup writes strict JSON: a run repairs the comma. A
// duplicate key was refused by v0.1.0 too and is still, with its place.
@(test)
a_trailing_comma_is_accepted_and_repaired_and_a_duplicate_key_is_refused :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(t, path, `{"languageRule": "keep"}`)
	c := values(dir, `{"languageRule": "R",}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(t, path, "{\n  \"languageRule\": \"R\"\n}\n")
	c2 := values(dir, `{"languageRule": "R", "languageRule": "S"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 2)
	expect_contains(t, c2.err, "duplicate key")
	// A stored file with a trailing comma is read, merged and written strict.
	put(t, path, "{\n  \"languageRule\": \"r\",\n  \"ignoreWords\": [\"a\",],\n}\n")
	c3 := values(dir, `{"languagetool": {"backend": "public"}}`)
	defer cli_done(&c3)
	testing.expect_value(t, c3.code, 0)
	expect_file(
		t,
		path,
		"{\n  \"languageRule\": \"r\",\n  \"ignoreWords\": [\n    \"a\"\n  ],\n  \"languagetool\": {\n    \"backend\": \"public\"\n  }\n}\n",
	)
	// A stored duplicate key is still the file's fault, and the file stays.
	put(t, path, `{"languageRule": "a", "languageRule": "b"}`)
	c4 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c4)
	testing.expect_value(t, c4.code, 2)
	expect_contains(t, c4.err, cat(path, ": is not valid JSON (duplicate key"))
	expect_file(t, path, `{"languageRule": "a", "languageRule": "b"}`)
}

// What setup does not know it keeps as it was. Numbers used to pass through
// f64: 9007199254740993 lost its last digit, 1.0 came back as 1 and 1e999 as
// +Inf, which made the new file invalid JSON.
@(test)
unknown_numbers_round_trip_exactly :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	put(
		t,
		path,
		`{"big": 9007199254740993, "min": -9223372036854775808, "max": 9223372036854775807, "one": 1.0, "half": 0.5, "exp": 1e21, "neg": -0.0, "list": [1, 1.0, 2.50]}`,
	)
	c := values(dir, `{"languageRule": "R", "late": 18014398509481985, "lf": 3.0}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 0)
	expect_file(
		t,
		path,
		`{
  "languageRule": "R",
  "big": 9007199254740993,
  "exp": 1e+21,
  "half": 0.5,
  "late": 18014398509481985,
  "lf": 3.0,
  "list": [
    1,
    1.0,
    2.5
  ],
  "max": 9223372036854775807,
  "min": -9223372036854775808,
  "neg": -0.0,
  "one": 1.0
}
`,
	)
	// And again: stable.
	c2 := values(dir, `{"languageRule": "R"}`)
	defer cli_done(&c2)
	testing.expect_value(t, c2.code, 0)
	expect_contains(t, read_text(path), `"big": 9007199254740993`)
}

// A number that cannot be kept is refused with a clear message, not turned
// into something else; the file stays as it was.
@(test)
a_number_that_cannot_be_kept_is_refused_clearly :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	for bad in ([]string{`1e999`, `-1e999`, `123456789012345678901234567890`, `9223372036854775808`, `-9223372036854775809`, `1e-999`}) {
		stored := strings.concatenate({`{"x": `, bad, `}`})
		defer delete(stored)
		put(t, path, stored)
		c := values(dir, `{"languageRule": "R"}`)
		defer cli_done(&c)
		testing.expectf(t, c.code == 2, "%s: exit %d", bad, c.code)
		expect_contains(t, c.err, bad)
		expect_contains(t, c.err, "line 1, column 7")
		expect_contains(t, c.err, "cannot keep")
		expect_contains(t, c.err, "unchanged")
		expect_file(t, path, stored)
		// The same number in the values.
		put(t, path, `{"languageRule": "keep"}`)
		values_text := strings.concatenate({`{"y": `, bad, `}`})
		defer delete(values_text)
		c2 := values(dir, values_text)
		defer cli_done(&c2)
		testing.expectf(t, c2.code == 2, "%s in the values: exit %d", bad, c2.code)
		expect_contains(t, c2.err, "the values on standard input")
		expect_contains(t, c2.err, "cannot keep")
		expect_file(t, path, `{"languageRule": "keep"}`)
	}
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

// The guard reads a name the way a person would: case, dashes, underscores
// and dots do not matter, and a name that ends in token, secret or password
// is a credential whatever comes before.
@(test)
the_key_guard_normalizes_names :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path := join(dir, "config.json")
	defer delete(path)
	before := `{"languageRule": "keep"}`
	put(t, path, before)
	refused := [?]string {
		"apiKey", "api_key", "api-key", "API.KEY", "Api_Key", "key", "Key", "password", "PassWord", "token", "TOKEN",
		"secret", "Secret", "apiToken", "api_token", "api-token", "accessToken", "access_token", "access.token", "authToken",
		"csrf-token", "bearer_token", "refreshToken", "clientSecret", "client_secret", "dbPassword", "db.password", "x-secret",
	}
	for name in refused {
		for shape in ([][2]string{{`{"`, `": "SECRET-KEY"}`}, {`{"languagetool": {"`, `": "SECRET-KEY"}}`}}) {
			text := strings.concatenate({shape[0], name, shape[1]})
			defer delete(text)
			c := values(dir, text)
			testing.expectf(t, c.code == 2, "%s: exit %d", text, c.code)
			expect_contains(t, c.err, NEVER_IN_FILE)
			expect_lacks(t, c.err, "SECRET-KEY")
			expect_file(t, path, before)
			cli_done(&c)
		}
	}
	// Names that only look like one pass.
	passed := [?]string{"keyItem", "keyboard", "keys", "keyring", "monkey", "tokens", "secrets", "passwords", "passphrase", "tokenizer", "secretary", "item"}
	for name in passed {
		for shape in ([][2]string{{`{"`, `": "x"}`}, {`{"languagetool": {"`, `": "x"}}`}}) {
			text := strings.concatenate({shape[0], name, shape[1]})
			defer delete(text)
			c := values(dir, text)
			testing.expectf(t, c.code == 0, "%s: exit %d: %s", text, c.code, c.err)
			cli_done(&c)
		}
	}
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

// --setup does one thing: every other option, and --values-stdin without
// --setup, is refused before anything runs or is written.
@(test)
setup_takes_no_other_option_and_values_stdin_needs_setup :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	with_setup := [][]string {
		{"--setup", "--rules"},
		{"--setup", "--json"},
		{"--setup", "--strict"},
		{"--setup", "--no-lt"},
		{"--setup", "--picky"},
		{"--setup", "--lang", "de"},
		{"--setup", "--lang=auto"},
		{"--setup", "--values-stdin", "--rules"},
		{"--setup", "--values-stdin", "--lang=en"},
	}
	for args in with_setup {
		c := cli(args, dir, `{"languageRule": "R"}`)
		defer cli_done(&c)
		testing.expectf(t, c.code == 2, "%v: exit %d", args, c.code)
		testing.expectf(t, strings.has_prefix(c.err, "prose: "), "%v: stderr %q", args, c.err)
		expect_contains(t, c.err, "--setup takes no files and no other option")
		testing.expectf(t, c.out == "", "%v: stdout %q", args, c.out)
	}
	c := cli({"--values-stdin", "--rules"}, dir, `{"languageRule": "R"}`)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	testing.expect_value(t, c.err, "prose: --values-stdin goes with --setup\n")
	testing.expect_value(t, c.out, "")
	listing := names(dir)
	defer delete(listing)
	testing.expect_value(t, listing, "")
}

// A reader that fails.
@(private = "file")
broken_reader :: proc() -> io.Reader {
	return io.Reader {
		procedure = proc(
			stream_data: rawptr,
			mode: io.Stream_Mode,
			p: []byte,
			offset: i64,
			whence: io.Seek_From,
		) -> (
			n: i64,
			err: io.Error,
		) {
			if mode == .Query {
				return io.query_utility({.Read, .Query})
			}
			return 0, .Unknown
		},
	}
}

@(test)
standard_input_that_cannot_be_read_or_is_too_big_is_told_apart :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	env := prose.Run_Env {
		config_dir = dir,
	}
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	errb := strings.builder_make()
	defer strings.builder_destroy(&errb)
	code := prose.run({"--setup", "--values-stdin"}, broken_reader(), strings.to_writer(&out), strings.to_writer(&errb), env)
	testing.expect_value(t, code, 2)
	testing.expect_value(t, strings.to_string(errb), "prose: cannot read the values on standard input\n")

	big, _ := strings.repeat(" ", prose.MAX_SETTINGS_BYTES + 1)
	defer delete(big)
	c := values(dir, big)
	defer cli_done(&c)
	testing.expect_value(t, c.code, 2)
	want := fmt.tprintf("prose: the values on standard input are bigger than %d bytes\n", prose.MAX_SETTINGS_BYTES)
	testing.expect_value(t, c.err, want)
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

// The kernel reads a relative link from the directory the link is really in.
// Through a symlinked directory that is not the directory in the path, and
// cleaning `..` out of the path by hand gives another file.
@(test)
a_relative_link_is_read_from_the_directory_it_is_really_in :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		real := join(dir, "real", "inner")
		defer delete(real)
		testing.expect(t, os.make_directory_all(real) == nil)
		via := join(dir, "via") // a symlink to real/inner
		defer delete(via)
		testing.expect(t, os.symlink("real/inner", via) == nil)
		target := join(dir, "real", "target.json")
		defer delete(target)
		put(t, target, `{"languageRule": "keep"}`)
		// real/inner/config.json -> ../target.json, which is real/target.json
		link := join(real, "config.json")
		defer delete(link)
		testing.expect(t, os.symlink("../target.json", link) == nil)
		decoy := join(dir, "target.json") // where the cleaned path would go
		defer delete(decoy)

		// Reached through the symlinked directory.
		cfg := join(dir, "via")
		defer delete(cfg)
		c := values(cfg, `{"languagetool": {"backend": "public"}}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 0)
		testing.expect(t, !os.exists(decoy), "the file beside the symlinked directory was made")
		got := read(target)
		defer delete(got)
		expect_contains(t, got, `"languageRule": "keep"`)
		expect_contains(t, got, `"backend": "public"`)
		info, err := os.lstat(link, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
	}
}

@(test)
a_link_to_a_directory_is_refused_clearly :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		cfg := join(dir, "cfg")
		defer delete(cfg)
		store := join(dir, "store")
		defer delete(store)
		testing.expect(t, os.make_directory(cfg) == nil)
		testing.expect(t, os.make_directory(store) == nil)
		link := join(cfg, "config.json")
		defer delete(link)
		testing.expect(t, os.symlink(store, link) == nil)
		c := values(cfg, `{"languageRule": "R"}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 2)
		expect_contains(t, c.err, "is not a regular file")
		expect_contains(t, c.err, link)
		expect_contains(t, c.err, store)
		expect_contains(t, c.err, "unchanged")
		listing := names(store)
		defer delete(listing)
		testing.expect_value(t, listing, "")
		info, err := os.lstat(link, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
	}
}

// A chain of `..` in a link, and a link whose target is not there yet: the
// target and the directories on its way are made, which is intended, and the
// link stays a link.
@(test)
a_link_with_dot_dots_and_a_dangling_link_are_followed :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		cfg := join(dir, "a", "b", "cfg")
		defer delete(cfg)
		testing.expect(t, os.make_directory_all(cfg) == nil)
		store := join(dir, "a", "store")
		defer delete(store)
		testing.expect(t, os.make_directory(store) == nil)
		target := join(store, "real.json")
		defer delete(target)
		put(t, target, `{"languageRule": "keep"}`)
		link := join(cfg, "config.json")
		defer delete(link)
		testing.expect(t, os.symlink("../../store/real.json", link) == nil)
		c := values(cfg, `{"ignoreWords": ["w"]}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 0)
		got := read(target)
		defer delete(got)
		expect_contains(t, got, `"languageRule": "keep"`)
		expect_contains(t, got, `"w"`)
		listing := names(cfg)
		defer delete(listing)
		testing.expect_value(t, listing, "config.json")

		// Dangling: nothing at the end of the link, not even its directories.
		cfg2 := join(dir, "cfg2")
		defer delete(cfg2)
		testing.expect(t, os.make_directory(cfg2) == nil)
		link2 := join(cfg2, "config.json")
		defer delete(link2)
		testing.expect(t, os.symlink("../data/nested/real.json", link2) == nil)
		made := join(dir, "data", "nested", "real.json")
		defer delete(made)
		testing.expect(t, !os.exists(made))
		c2 := values(cfg2, `{"languageRule": "R"}`)
		defer cli_done(&c2)
		testing.expect_value(t, c2.code, 0)
		expect_file(t, made, "{\n  \"languageRule\": \"R\"\n}\n")
		info, err := os.lstat(link2, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.type, os.File_Type.Symlink)
		// The directories it made keep the owner to themselves.
		nested := join(dir, "data", "nested")
		defer delete(nested)
		ninfo, nerr := os.stat(nested, context.allocator)
		defer os.file_info_delete(ninfo, context.allocator)
		testing.expect(t, nerr == nil)
		testing.expect_value(t, ninfo.mode, os.perm_number(0o700))
	}
}

// The new file replaces the old one and is made 0600, whatever the old mode
// was: the file names a user name, and the replacement is a new file.
@(test)
the_rewritten_file_is_0600_whatever_it_was :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows {
		dir := scratch(t)
		defer scratch_done(dir)
		path := join(dir, "config.json")
		defer delete(path)
		put(t, path, `{"languageRule": "keep"}`)
		testing.expect(t, os.change_mode(path, os.perm_number(0o644)) == nil)
		c := values(dir, `{"ignoreWords": ["w"]}`)
		defer cli_done(&c)
		testing.expect_value(t, c.code, 0)
		info, err := os.stat(path, context.allocator)
		defer os.file_info_delete(info, context.allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, info.mode, os.perm_number(0o600))
		// Through a link, the target is the one replaced, and it is 0600 too.
		store := join(dir, "store.json")
		defer delete(store)
		put(t, store, `{}`)
		testing.expect(t, os.change_mode(store, os.perm_number(0o666)) == nil)
		link := join(dir, "linked", "config.json")
		defer delete(link)
		linked := join(dir, "linked")
		defer delete(linked)
		testing.expect(t, os.make_directory(linked) == nil)
		testing.expect(t, os.symlink(store, link) == nil)
		c2 := values(linked, `{"languageRule": "R"}`)
		defer cli_done(&c2)
		testing.expect_value(t, c2.code, 0)
		sinfo, serr := os.stat(store, context.allocator)
		defer os.file_info_delete(sinfo, context.allocator)
		testing.expect(t, serr == nil)
		testing.expect_value(t, sinfo.mode, os.perm_number(0o600))
	}
}
