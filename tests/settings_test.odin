package prose_tests

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import prose "../src"

// Every test makes its own directory and removes it at the end, so the tests
// can run in parallel threads. None of them touches the process environment.
@(private = "file")
scratch :: proc(t: ^testing.T) -> string {
	dir, err := os.make_directory_temp("", "prose-task7-*", context.allocator)
	testing.expect(t, err == nil)
	return dir
}

@(private = "file")
scratch_done :: proc(dir: string) {
	_ = os.remove_all(dir)
	delete(dir)
}

@(private = "file")
put :: proc(t: ^testing.T, dir, name, content: string, mode := 0o600) -> string {
	path, _ := os.join_path({dir, name}, context.allocator)
	_ = os.change_mode(path, os.perm_number(0o600)) // a read-only leftover of the last round
	err := os.write_entire_file_from_string(path, content)
	testing.expect(t, err == nil)
	testing.expect(t, os.change_mode(path, os.perm_number(mode)) == nil)
	return path
}

// load parses `content` as a settings file; the caller destroys both results.
@(private = "file")
load :: proc(
	t: ^testing.T,
	content: string,
) -> (
	s: prose.Settings,
	err: prose.Settings_Error,
	path: string,
	dir: string,
) {
	dir = scratch(t)
	path = put(t, dir, "config.json", content)
	s, err = prose.load_settings(path)
	return
}

@(private = "file")
load_done :: proc(s: ^prose.Settings, err: ^prose.Settings_Error, path, dir: string) {
	prose.settings_destroy(s)
	prose.settings_error_destroy(err)
	delete(path)
	scratch_done(dir)
}

@(private = "file")
expect_unusable :: proc(t: ^testing.T, content, want_problem: string, loc := #caller_location) {
	s, err, path, dir := load(t, content)
	defer load_done(&s, &err, path, dir)
	testing.expectf(t, err.problem != "", "no error for %q", content, loc = loc)
	testing.expectf(t, err.path == path, "error path %q, want %q", err.path, path, loc = loc)
	testing.expectf(
		t,
		strings.contains(err.problem, want_problem),
		"problem %q lacks %q",
		err.problem,
		want_problem,
		loc = loc,
	)
	testing.expectf(t, s.backend == nil && s.server == "" && s.ignore_words == nil, "%v", s, loc = loc)
}

@(test)
a_missing_file_reads_as_no_settings :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	path, _ := os.join_path({dir, "config.json"}, context.allocator)
	defer delete(path)
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	testing.expect_value(t, err.problem, "")
	testing.expect(t, s.backend == nil)
	testing.expect_value(t, s.language_rule, "")
	testing.expect(t, len(s.ignore_words) == 0 && len(s.unknown_keys) == 0)
	// An empty path is the same: there is no config directory to look in.
	s2, err2 := prose.load_settings("")
	testing.expect(t, err2.problem == "" && s2.backend == nil)
}

@(test)
a_full_file_is_read :: proc(t: ^testing.T) {
	s, err, path, dir := load(
		t,
		`{"languageRule": "Sie in mails", "ignoreWords": ["Zorbax", " Quillnote ", "", "  "],
		"languagetool": {"backend": "premium", "server": "https://lt.example.org",
		"username": "me", "keyItem": "lt-key"}}`,
	)
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.language_rule, "Sie in mails")
	// Words are trimmed and blanks dropped, as in the reference.
	testing.expect_value(t, len(s.ignore_words), 2)
	if len(s.ignore_words) == 2 {
		testing.expect_value(t, s.ignore_words[0], "Zorbax")
		testing.expect_value(t, s.ignore_words[1], "Quillnote")
	}
	kind, ok := s.backend.?
	testing.expect(t, ok && kind == .Premium)
	testing.expect_value(t, s.server, "https://lt.example.org")
	testing.expect_value(t, s.username, "me")
	testing.expect_value(t, s.key_item, "lt-key")
	testing.expect_value(t, len(s.unknown_keys), 0)
}

@(test)
every_backend_name_is_accepted :: proc(t: ^testing.T) {
	names := [?]string{"none", "public", "premium"}
	kinds := [?]prose.Backend_Kind{.None, .Public, .Premium}
	for name, i in names {
		content := strings.concatenate({`{"languagetool": {"backend": "`, name, `"}}`})
		defer delete(content)
		s, err, path, dir := load(t, content)
		defer load_done(&s, &err, path, dir)
		testing.expect_value(t, err.problem, "")
		kind, ok := s.backend.?
		testing.expectf(t, ok && kind == kinds[i], "backend %q", name)
	}
	s, err, path, dir := load(
		t,
		`{"languagetool": {"backend": "server", "server": "http://localhost:8081"}}`,
	)
	defer load_done(&s, &err, path, dir)
	kind, ok := s.backend.?
	testing.expect(t, err.problem == "" && ok && kind == .Server)
}

@(test)
a_file_that_is_present_but_unusable_is_an_error_naming_it :: proc(t: ^testing.T) {
	// Invalid JSON of several shapes, an empty file included.
	expect_unusable(t, ``, "not valid JSON")
	expect_unusable(t, `{`, "not valid JSON")
	expect_unusable(t, `{"languagetool": }`, "not valid JSON")
	expect_unusable(t, `not json`, "not valid JSON")
	expect_unusable(t, `{} {}`, "not valid JSON")
	expect_unusable(t, `{"languagetool": {"backend": "public"}} x`, "not valid JSON")
	expect_unusable(t, `{"a": 1, "a": 2}`, "not valid JSON")
	// JSON that is not an object.
	expect_unusable(t, `[]`, "must be a JSON object")
	expect_unusable(t, `"text"`, "must be a JSON object")
	expect_unusable(t, `null`, "must be a JSON object")
	// A misspelled backend, the case that must not turn Premium off quietly.
	expect_unusable(
		t,
		`{"languagetool": {"backend": "premuim"}}`,
		`"languagetool.backend" must be one of none, public, premium, server`,
	)
	expect_unusable(
		t,
		`{"languagetool": {"backend": "Premium"}}`,
		`must be one of none, public, premium, server`,
	)
	expect_unusable(t, `{"languagetool": {"backend": 3}}`, `"languagetool.backend" must be`)
	// Wrong types.
	expect_unusable(t, `{"ignoreWords": "x"}`, `"ignoreWords" must be a list of strings`)
	expect_unusable(t, `{"ignoreWords": ["a", 2]}`, `"ignoreWords" must be a list of strings`)
	expect_unusable(t, `{"languageRule": 1}`, `"languageRule" must be a string`)
	expect_unusable(t, `{"languagetool": "premium"}`, `"languagetool" must be an object`)
	expect_unusable(t, `{"languagetool": {"username": 1}}`, `"languagetool.username" must be a string`)
	expect_unusable(t, `{"languagetool": {"keyItem": []}}`, `"languagetool.keyItem" must be a string`)
	expect_unusable(t, `{"languagetool": {"server": {}}}`, `"languagetool.server" must be a string`)
	// An unknown key read before the mistake must not leak with the error.
	expect_unusable(
		t,
		`{"colour": 1, "languagetool": {"backend": "premuim"}}`,
		`must be one of none, public, premium, server`,
	)
	expect_unusable(
		t,
		`{"a": 1, "languagetool": {"backend": "server"}}`,
		`"languagetool.server" is needed`,
	)
	expect_unusable(
		t,
		`{"languagetool": {"colour": 1, "backend": "premuim"}, "a": 1}`,
		`must be one of none, public, premium, server`,
	)
	// A server backend needs a URL.
	expect_unusable(
		t,
		`{"languagetool": {"backend": "server"}}`,
		`"languagetool.server" is needed`,
	)
	expect_unusable(
		t,
		`{"languagetool": {"backend": "server", "server": ""}}`,
		`"languagetool.server" is needed`,
	)
	expect_unusable(
		t,
		`{"languagetool": {"backend": "server", "server": "lt.example.org"}}`,
		`must start with http:// or https://`,
	)
}

// A JSON error says where it is. Columns count bytes from 1, lines from 1.
@(test)
a_json_error_names_the_line_and_the_column :: proc(t: ^testing.T) {
	expect_unusable(t, "{\n  \"a\": }", "line 2, column 8")
	expect_unusable(t, `{"a": 1} x`, "line 1, column 10")
	expect_unusable(t, "{\"a\": 1,\n\n  \"b\" 2}", "line 3")
	expect_unusable(t, `{`, "line 1")
	expect_unusable(t, ``, "line 1, column 1")
	// The error kind stays in the message too.
	expect_unusable(t, `{"a": }`, "Unexpected_Token")
}

// Strict JSON, as Python reads it: a trailing comma is an error, and so is a
// key given twice.
@(test)
a_trailing_comma_is_refused_and_a_duplicate_key_too :: proc(t: ^testing.T) {
	expect_unusable(t, `{"languageRule": "r",}`, "trailing comma at line 1, column 21")
	expect_unusable(t, `{"languagetool": {"backend": "public",}}`, "trailing comma")
	expect_unusable(t, `{"ignoreWords": ["a",]}`, "trailing comma at line 1, column 21")
	expect_unusable(t, `{"x": [1, 2,], "y": 1}`, "is not valid JSON")
	expect_unusable(t, "{\n  \"a\": 1,\n}\n", "trailing comma at line 2, column 9")
	// A comma inside a string is no trailing comma.
	s, err, path, dir := load(t, `{"languageRule": ",}", "ignoreWords": ["a,]"]}`)
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.language_rule, ",}")
	// Duplicate keys, at the top and inside "languagetool".
	expect_unusable(t, `{"languageRule": "a", "languageRule": "b"}`, "duplicate key")
	expect_unusable(t, `{"languagetool": {"backend": "none", "backend": "public"}}`, "duplicate key")
}

@(test)
the_server_url_is_checked_where_it_is_used_and_in_any_case :: proc(t: ^testing.T) {
	// The scheme is case-insensitive, as libcurl reads it.
	for url in ([?]string{"HTTPS://lt.example.org", "Http://localhost:8081", "hTTps://x"}) {
		content := strings.concatenate({`{"languagetool": {"backend": "server", "server": "`, url, `"}}`})
		defer delete(content)
		s, err, path, dir := load(t, content)
		defer load_done(&s, &err, path, dir)
		testing.expectf(t, err.problem == "" && s.server == url, "%q: %q", url, err.problem)
	}
	// A URL no backend uses is not checked: a stale value does not break a
	// file that has moved to another backend, or has none.
	for content in ([?]string {
			`{"languagetool": {"backend": "public", "server": "lt.example.org"}}`,
			`{"languagetool": {"backend": "premium", "server": "ftp://x"}}`,
			`{"languagetool": {"backend": "none", "server": "x"}}`,
			`{"languagetool": {"server": "lt.example.org"}}`,
		}) {
		s, err, path, dir := load(t, content)
		defer load_done(&s, &err, path, dir)
		testing.expectf(t, err.problem == "", "%s: %q", content, err.problem)
	}
	// Used by the server backend, a bad scheme is an error.
	expect_unusable(
		t,
		`{"languagetool": {"backend": "server", "server": "ftp://lt.example.org"}}`,
		`must start with http:// or https://`,
	)
	expect_unusable(
		t,
		`{"languagetool": {"backend": "server", "server": "httpx://lt.example.org"}}`,
		`must start with http:// or https://`,
	)
}

@(test)
load_settings_remembers_the_path_it_read :: proc(t: ^testing.T) {
	s, err, path, dir := load(t, `{}`)
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, s.path, path)
	// A missing file is no settings, and still knows where it would be.
	gone, _ := os.join_path({dir, "gone.json"}, context.allocator)
	defer delete(gone)
	s2, err2 := prose.load_settings(gone)
	defer prose.settings_destroy(&s2)
	testing.expect_value(t, err2.problem, "")
	testing.expect_value(t, s2.path, gone)
}

@(test)
a_file_that_is_too_big_or_not_a_file_is_an_error :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	big, _ := strings.repeat(" ", 2 << 20, context.allocator)
	defer delete(big)
	path := put(t, dir, "config.json", big)
	defer delete(path)
	s, err := prose.load_settings(path)
	defer prose.settings_destroy(&s)
	defer prose.settings_error_destroy(&err)
	testing.expect_value(t, err.path, path)
	testing.expect(t, strings.contains(err.problem, "too big"))

	// A directory where the file should be.
	sub, _ := os.join_path({dir, "d"}, context.allocator)
	defer delete(sub)
	testing.expect(t, os.make_directory(sub) == nil)
	s2, err2 := prose.load_settings(sub)
	defer prose.settings_destroy(&s2)
	defer prose.settings_error_destroy(&err2)
	testing.expect_value(t, err2.path, sub)
	testing.expect(t, strings.contains(err2.problem, "not a regular file"))
}

@(test)
a_byte_order_mark_is_skipped :: proc(t: ^testing.T) {
	s, err, path, dir := load(t, "\xEF\xBB\xBF{\"languageRule\": \"r\"}")
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, s.language_rule, "r")
}

@(test)
an_unknown_key_is_kept_apart_and_is_no_error :: proc(t: ^testing.T) {
	s, err, path, dir := load(
		t,
		`{"colour": 1, "apiKey": "SECRET-NEVER", "languagetool": {"backend": "public", "timeout": 3}}`,
	)
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, err.problem, "")
	testing.expect_value(t, len(s.unknown_keys), 3)
	if len(s.unknown_keys) == 3 {
		// Sorted, so the selftest note does not change from run to run.
		testing.expect_value(t, s.unknown_keys[0], "apiKey")
		testing.expect_value(t, s.unknown_keys[1], "colour")
		testing.expect_value(t, s.unknown_keys[2], "languagetool.timeout")
	}
	// The key never comes from config.json: "apiKey" is only an unknown key,
	// so a premium backend chosen later finds no key in it.
	testing.expect_value(t, s.key_item, "")
}

// ---------------------------------------------------------------------------
// The backend choice.

@(private = "file")
rbw_none :: proc(item: string) -> (string, bool) {
	return "", false
}

@(private = "file")
rbw_key :: proc(item: string) -> (string, bool) {
	return "RBW-KEY", true
}

// Answers with the item it was asked for, to show which item is read.
@(private = "file")
rbw_echo :: proc(item: string) -> (string, bool) {
	return strings.concatenate({"item:", item}, context.temp_allocator), true
}

@(private = "file")
choose :: proc(
	t: ^testing.T,
	s: prose.Settings,
	env: prose.Env,
	lookup: prose.Key_Lookup,
) -> (
	b: prose.Backend,
	problem: string,
) {
	return prose.choose_backend(s, env, lookup)
}

@(private = "file")
done :: proc(b: ^prose.Backend, problem: string) {
	prose.backend_destroy(b)
	delete(problem)
}

@(test)
the_file_wins_and_the_variables_only_fill_in :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend = prose.Backend_Kind.Public,
	}
	b, problem := choose(t, s, {api_key = "ENV-KEY", username = "u", server = "https://x"}, {})
	defer done(&b, problem)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, b.kind, prose.Backend_Kind.Public)
	testing.expect_value(t, b.url, "https://api.languagetool.org")
	// The public server gets neither key nor account.
	testing.expect_value(t, b.key, "")
	testing.expect_value(t, b.username, "")
	testing.expect_value(t, b.label, "free cloud")
}

@(test)
backend_none_in_the_file_wins_over_exported_variables :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend = prose.Backend_Kind.None,
	}
	b, problem := choose(t, s, {api_key = "k", username = "u", server = "https://x"}, {})
	defer done(&b, problem)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, b.kind, prose.Backend_Kind.None)
	testing.expect(t, b.url == "" && b.key == "" && b.username == "")
}

@(test)
without_a_file_the_variables_count_as_a_choice :: proc(t: ^testing.T) {
	{
		b, problem := choose(t, {}, {server = "https://lt.example.org"}, {})
		defer done(&b, problem)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, b.kind, prose.Backend_Kind.Server)
		testing.expect_value(t, b.url, "https://lt.example.org")
		testing.expect_value(t, b.label, "self-hosted")
	}
	{
		// A server wins over a key and an account.
		b, problem := choose(t, {}, {server = "https://s", api_key = "k", username = "u"}, {})
		defer done(&b, problem)
		testing.expect_value(t, b.kind, prose.Backend_Kind.Server)
	}
	{
		b, problem := choose(t, {}, {api_key = "ENV-KEY", username = "me"}, {})
		defer done(&b, problem)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, b.kind, prose.Backend_Kind.Premium)
		testing.expect_value(t, b.url, "https://api.languagetoolplus.com")
		testing.expect_value(t, b.username, "me")
		testing.expect_value(t, b.key, "ENV-KEY")
		testing.expect_value(t, b.label, "premium cloud")
	}
	{
		// A key without an account, or an account without a key, is no choice.
		b, problem := choose(t, {}, {api_key = "k"}, {})
		defer done(&b, problem)
		testing.expect_value(t, b.kind, prose.Backend_Kind.None)
		testing.expect_value(t, problem, "")
		b2, problem2 := choose(t, {}, {username = "u"}, {})
		defer done(&b2, problem2)
		testing.expect_value(t, b2.kind, prose.Backend_Kind.None)
	}
	{
		b, problem := choose(t, {}, {}, {})
		defer done(&b, problem)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, b.kind, prose.Backend_Kind.None)
	}
	{
		// A file without "backend" does not choose by its other values.
		b, problem := choose(t, {server = "https://x", username = "u", key_item = "i"}, {}, {rbw = rbw_key})
		defer done(&b, problem)
		testing.expect_value(t, b.kind, prose.Backend_Kind.None)
	}
}

@(test)
a_server_variable_beats_the_files_server :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend = prose.Backend_Kind.Server,
		server  = "https://file.example.org",
	}
	b, problem := choose(t, s, {server = "https://env.example.org"}, {})
	defer done(&b, problem)
	testing.expect_value(t, b.url, "https://env.example.org")
	b2, problem2 := choose(t, s, {}, {})
	defer done(&b2, problem2)
	testing.expect_value(t, b2.url, "https://file.example.org")
	// Built by hand without a URL anywhere: a problem, never an empty URL.
	b3, problem3 := choose(t, {backend = prose.Backend_Kind.Server}, {}, {})
	defer done(&b3, problem3)
	testing.expect(t, problem3 != "" && strings.contains(problem3, "LANGUAGETOOL_SERVER"))
}

@(test)
a_server_url_is_checked_wherever_it_comes_from :: proc(t: ^testing.T) {
	// From the variable: the message names the variable, not the file, and
	// not the value, which may hold a login.
	s := prose.Settings {
		path    = "/x/prose/config.json",
		backend = prose.Backend_Kind.Server,
		server  = "https://file.example.org",
	}
	b, problem := choose(t, s, {server = "user:secret@lt.example.org"}, {})
	defer done(&b, problem)
	testing.expect(t, b.kind == .None && b.url == "")
	testing.expect(t, strings.contains(problem, "LANGUAGETOOL_SERVER"), problem)
	testing.expect(t, strings.contains(problem, "http:// or https://"), problem)
	testing.expect(t, !strings.contains(problem, "secret"), problem)
	testing.expect(t, !strings.contains(problem, "/x/prose/config.json"), problem)
	// A good variable beats a bad file value: only the chosen URL is checked.
	bad_file := s
	bad_file.server = "lt.example.org"
	b2, problem2 := choose(t, bad_file, {server = "https://env.example.org"}, {})
	defer done(&b2, problem2)
	testing.expect_value(t, problem2, "")
	testing.expect_value(t, b2.url, "https://env.example.org")
	// From the file: the message names the file by its whole path.
	b3, problem3 := choose(t, bad_file, {}, {})
	defer done(&b3, problem3)
	testing.expect(t, strings.contains(problem3, "\"languagetool.server\""), problem3)
	testing.expect(t, strings.contains(problem3, "/x/prose/config.json"), problem3)
	testing.expect(t, b3.kind == .None && b3.url == "")
	// The scheme is not case-sensitive here either.
	b4, problem4 := choose(t, {}, {server = "HTTPS://lt.example.org"}, {})
	defer done(&b4, problem4)
	testing.expect_value(t, problem4, "")
	testing.expect_value(t, b4.url, "HTTPS://lt.example.org")
	// The variable alone chooses the server backend, and is checked too.
	b5, problem5 := choose(t, {}, {server = "lt.example.org"}, {})
	defer done(&b5, problem5)
	testing.expect(t, strings.contains(problem5, "LANGUAGETOOL_SERVER"), problem5)
}

@(test)
the_problems_of_the_backend_choice_name_the_settings_file_by_its_path :: proc(t: ^testing.T) {
	PATH :: "/x/prose/config.json"
	// No URL.
	b, problem := choose(t, {path = PATH, backend = prose.Backend_Kind.Server}, {}, {})
	defer done(&b, problem)
	testing.expect(t, strings.contains(problem, PATH), problem)
	// No account.
	b2, problem2 := choose(t, {path = PATH, backend = prose.Backend_Kind.Premium}, {api_key = "k"}, {})
	defer done(&b2, problem2)
	testing.expect(t, strings.contains(problem2, PATH), problem2)
	// No key and no item.
	b3, problem3 := choose(t, {path = PATH, backend = prose.Backend_Kind.Premium, username = "u"}, {}, {})
	defer done(&b3, problem3)
	testing.expect(t, strings.contains(problem3, PATH), problem3)
	// Settings built by hand have no path and say "config.json".
	b4, problem4 := choose(t, {backend = prose.Backend_Kind.Server}, {}, {})
	defer done(&b4, problem4)
	testing.expect(t, strings.contains(problem4, "in config.json"), problem4)
	// The same through a loaded file.
	s, err, path, dir := load(t, `{"languagetool": {"backend": "premium", "username": "u"}}`)
	defer load_done(&s, &err, path, dir)
	b5, problem5 := choose(t, s, {}, {})
	defer done(&b5, problem5)
	testing.expect(t, strings.contains(problem5, path), problem5)
}

@(test)
premium_takes_the_username_from_the_variable_first :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "file-user",
	}
	b, problem := choose(t, s, {username = "env-user", api_key = "k"}, {})
	defer done(&b, problem)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, b.username, "env-user")
	b2, problem2 := choose(t, s, {api_key = "k"}, {})
	defer done(&b2, problem2)
	testing.expect_value(t, b2.username, "file-user")
}

@(test)
premium_without_an_account_is_a_problem :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend = prose.Backend_Kind.Premium,
	}
	b, problem := choose(t, s, {api_key = "k"}, {})
	defer done(&b, problem)
	testing.expect(t, strings.contains(problem, "LANGUAGETOOL_USERNAME"))
	testing.expect(t, strings.contains(problem, "languagetool.username"))
	testing.expect(t, b.key == "" && b.url == "")
}

@(test)
the_key_from_the_variable_beats_rbw :: proc(t: ^testing.T) {
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
		key_item = "lt",
	}
	b, problem := choose(t, s, {api_key = "ENV-KEY"}, {rbw = rbw_key})
	defer done(&b, problem)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, b.key, "ENV-KEY")
	testing.expect_value(t, b.key_from, prose.Key_Source.Env)
}

@(test)
rbw_beats_the_credentials_file_and_gets_the_item_name :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cred := put(t, dir, "credentials", "FILE-KEY\n")
	defer delete(cred)
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
		key_item = "my item",
	}
	b, problem := choose(t, s, {}, {rbw = rbw_echo, credentials_path = cred})
	defer done(&b, problem)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, b.key, "item:my item")
	testing.expect_value(t, b.key_from, prose.Key_Source.Rbw)
	b2, problem2 := choose(t, s, {}, {rbw = rbw_key, credentials_path = cred})
	defer done(&b2, problem2)
	testing.expect_value(t, b2.key, "RBW-KEY")
}

@(test)
rbw_is_not_asked_without_an_item_and_may_be_absent :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cred := put(t, dir, "credentials", "FILE-KEY\n")
	defer delete(cred)
	// No keyItem: rbw (which would answer) is never consulted.
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
	}
	b, problem := choose(t, s, {}, {rbw = rbw_key, credentials_path = cred})
	defer done(&b, problem)
	testing.expect_value(t, b.key, "FILE-KEY")
	testing.expect_value(t, b.key_from, prose.Key_Source.Credentials)
	// An item that rbw cannot give (not installed, locked, no such item)
	// falls through to the file; so does a lookup that is not set at all.
	s.key_item = "lt"
	b2, problem2 := choose(t, s, {}, {rbw = rbw_none, credentials_path = cred})
	defer done(&b2, problem2)
	testing.expect_value(t, b2.key, "FILE-KEY")
	b3, problem3 := choose(t, s, {}, {credentials_path = cred})
	defer done(&b3, problem3)
	testing.expect_value(t, b3.key, "FILE-KEY")
}

@(test)
the_credentials_file_holds_the_bare_key :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
	}
	Case :: struct {
		content, key: string,
	}
	cases := [?]Case {
		// The file holds only the key.
		{"abc\n", "abc"},
		{"abc", "abc"},
		{"  abc \t\n", "abc"},
		// The first non-blank line; blank lines before it do not count.
		{"\n  \n\nabc\nsecond\n", "abc"},
		// A CRLF file does not put the carriage return into the key.
		{"abc\r\n", "abc"},
		// The dotenv shape is tolerated: the prefix goes.
		{"LANGUAGETOOL_API_KEY=abc\n", "abc"},
		{"LANGUAGETOOL_API_KEY=abc", "abc"},
		{"  LANGUAGETOOL_API_KEY=abc  \r\n", "abc"},
		// Nothing is expanded or cut: an inner "=", "#" and space stay.
		{"a=b#c d\n", "a=b#c d"},
		{"OTHER=1\n", "OTHER=1"},
	}
	for c, i in cases {
		cred := put(t, dir, "credentials", c.content)
		defer delete(cred)
		b, problem := choose(t, s, {}, {credentials_path = cred})
		defer done(&b, problem)
		testing.expectf(t, problem == "", "case %d: %s", i, problem)
		testing.expectf(t, b.key == c.key, "case %d: key %q, want %q", i, b.key, c.key)
	}
	// An empty or blank file, or a prefix with nothing after it, is no key.
	for content in ([?]string{"", "\n", "  \r\n\t\n", "LANGUAGETOOL_API_KEY=\n", "LANGUAGETOOL_API_KEY= \n"}) {
		cred := put(t, dir, "credentials", content)
		defer delete(cred)
		b, problem := choose(t, s, {}, {credentials_path = cred})
		defer done(&b, problem)
		testing.expectf(t, problem != "" && b.key == "", "content %q", content)
	}
}

@(test)
a_credentials_file_wider_than_600_is_refused :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir := scratch(t)
	defer scratch_done(dir)
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
	}
	for mode in ([?]int{0o644, 0o640, 0o604, 0o660, 0o666, 0o610, 0o601}) {
		cred := put(t, dir, "credentials", "FILE-SECRET\n", mode)
		defer delete(cred)
		b, problem := choose(t, s, {}, {credentials_path = cred})
		defer done(&b, problem)
		testing.expectf(t, strings.contains(problem, cred), "mode %o: problem %q", mode, problem)
		testing.expectf(t, strings.contains(problem, "600"), "mode %o: problem %q", mode, problem)
		testing.expectf(t, b.key == "", "mode %o gave a key", mode)
		// The key is never in the message.
		testing.expect(t, !strings.contains(problem, "FILE-SECRET"))
	}
	// 600, 400 and 700 are fine: only group and other count.
	for mode in ([?]int{0o600, 0o400, 0o700}) {
		cred := put(t, dir, "credentials", "FILE-SECRET\n", mode)
		defer delete(cred)
		b, problem := choose(t, s, {}, {credentials_path = cred})
		defer done(&b, problem)
		testing.expectf(t, problem == "" && b.key == "FILE-SECRET", "mode %o: %q", mode, problem)
	}
	// A wider file is not looked at when a better source has the key.
	cred := put(t, dir, "credentials", "FILE-SECRET\n", 0o644)
	defer delete(cred)
	b, problem := choose(t, s, {api_key = "ENV-KEY"}, {credentials_path = cred})
	defer done(&b, problem)
	testing.expect(t, problem == "" && b.key == "ENV-KEY")
}

// The credentials file is opened once and checked on that descriptor. A FIFO
// in its place is no regular file and must not make the open wait for a writer.
@(test)
a_fifo_as_the_credentials_file_is_no_key_and_no_hang :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	dir := scratch(t)
	defer scratch_done(dir)
	fifo, _ := os.join_path({dir, "credentials"}, context.allocator)
	defer delete(fifo)
	state, _, _, perr := os.process_exec(os.Process_Desc{command = {"mkfifo", fifo}}, context.allocator)
	if perr != nil || !state.success {
		return // no mkfifo here: nothing to test
	}
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
	}
	start := time.tick_now()
	b, problem := choose(t, s, {}, {credentials_path = fifo})
	defer done(&b, problem)
	testing.expect(t, b.key == "" && strings.contains(problem, "has no key"), problem)
	testing.expectf(t, time.tick_since(start) < 5 * time.Second, "took %v", time.tick_since(start))
}

@(test)
no_key_anywhere_names_the_three_sources :: proc(t: ^testing.T) {
	dir := scratch(t)
	defer scratch_done(dir)
	cred, _ := os.join_path({dir, "credentials"}, context.allocator) // does not exist
	defer delete(cred)
	s := prose.Settings {
		backend  = prose.Backend_Kind.Premium,
		username = "u",
		key_item = "lt-premium",
	}
	b, problem := choose(t, s, {}, {rbw = rbw_none, credentials_path = cred})
	defer done(&b, problem)
	testing.expect(t, b.key == "" && b.url == "")
	testing.expect(t, strings.contains(problem, "LANGUAGETOOL_API_KEY"), problem)
	testing.expect(t, strings.contains(problem, "rbw"), problem)
	testing.expect(t, strings.contains(problem, "lt-premium"), problem)
	testing.expect(t, strings.contains(problem, cred), problem)

	// Without a keyItem the message says so instead of naming an item.
	s.key_item = ""
	b2, problem2 := choose(t, s, {}, {credentials_path = cred})
	defer done(&b2, problem2)
	testing.expect(t, strings.contains(problem2, "languagetool.keyItem"), problem2)
	testing.expect(t, strings.contains(problem2, cred), problem2)
	testing.expect(t, strings.contains(problem2, "LANGUAGETOOL_API_KEY"), problem2)
	want2 := strings.concatenate(
		{
			`LanguageTool Premium has no key: set LANGUAGETOOL_API_KEY, or use an rbw item named in "languagetool.keyItem" in config.json, or put the key alone in `,
			cred,
			" (mode 600)",
		},
		context.temp_allocator,
	)
	testing.expectf(t, problem2 == want2, "got  %q\nwant %q", problem2, want2)
}

@(test)
the_key_is_not_read_from_the_settings_file :: proc(t: ^testing.T) {
	// A "apiKey" in config.json is an unknown key, and with no other source
	// the premium backend has no key.
	s, err, path, dir := load(
		t,
		`{"apiKey": "IN-THE-FILE", "languagetool": {"backend": "premium", "username": "u"}}`,
	)
	defer load_done(&s, &err, path, dir)
	testing.expect_value(t, err.problem, "")
	b, problem := choose(t, s, {}, {})
	defer done(&b, problem)
	testing.expect(t, b.key == "" && problem != "")
	testing.expect(t, !strings.contains(problem, "IN-THE-FILE"))
}

@(test)
the_environment_reads_without_a_leak :: proc(t: ^testing.T) {
	env := prose.env_from_os()
	prose.env_destroy(&env)
}

@(test)
the_real_rbw_lookup_refuses_an_item_that_looks_like_an_option :: proc(t: ^testing.T) {
	// It must not even start rbw for these.
	_, ok := prose.rbw_lookup("--help")
	testing.expect(t, !ok)
	_, ok = prose.rbw_lookup("")
	testing.expect(t, !ok)
}

@(test)
a_command_that_outruns_its_timeout_is_not_available :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	start := time.tick_now()
	out, ok := prose.command_output({"sh", "-c", "sleep 5"}, time.Second, false)
	defer delete(out)
	elapsed := time.tick_since(start)
	testing.expect(t, !ok)
	testing.expectf(t, elapsed < 3 * time.Second, "took %v", elapsed)
	// With capture too; the killed command's output is dropped.
	start = time.tick_now()
	out2, ok2 := prose.command_output({"sh", "-c", "echo partial; sleep 5"}, time.Second, true)
	defer delete(out2)
	testing.expect(t, !ok2 && len(out2) == 0)
	testing.expect(t, time.tick_since(start) < 3 * time.Second)
}

@(test)
command_output_reports_success_failure_and_absence :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	out, ok := prose.command_output({"sh", "-c", "printf 'key\\n'"}, 5 * time.Second, true)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect_value(t, string(out), "key\n")
	// Without capture nothing is returned, and the exit status still counts.
	out2, ok2 := prose.command_output({"sh", "-c", "echo dropped"}, 5 * time.Second, false)
	testing.expect(t, ok2 && out2 == nil)
	out3, ok3 := prose.command_output({"sh", "-c", "echo x; exit 1"}, 5 * time.Second, true)
	testing.expect(t, !ok3 && out3 == nil)
	out4, ok4 := prose.command_output({"/nonexistent/prose-no-such-command"}, 5 * time.Second, true)
	testing.expect(t, !ok4 && out4 == nil)
	// No stdin: a command that reads it sees the end at once, not a hang.
	out5, ok5 := prose.command_output({"sh", "-c", "cat"}, 5 * time.Second, true)
	defer delete(out5)
	testing.expect(t, ok5 && len(out5) == 0)
	// A grandchild that keeps the pipe open does not hold the read back.
	start := time.tick_now()
	out6, ok6 := prose.command_output({"sh", "-c", "echo hi; sleep 3 &"}, 5 * time.Second, true)
	defer delete(out6)
	testing.expect(t, ok6 && string(out6) == "hi\n")
	testing.expect(t, time.tick_since(start) < 2 * time.Second)
}

// A child that writes far more than a pipe holds (64 KiB) used to block on
// its write while `command_output` waited for it to exit, until the timeout
// killed it. The output is read while waiting now, and the cap applies.
@(test)
command_output_keeps_the_first_64_kib_of_a_bigger_output :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	start := time.tick_now()
	out, ok := prose.command_output({"sh", "-c", "head -c 204800 /dev/zero | tr '\\0' x"}, 10 * time.Second, true)
	defer delete(out)
	testing.expect(t, ok)
	testing.expect_value(t, len(out), 64 << 10)
	testing.expectf(t, time.tick_since(start) < 5 * time.Second, "took %v", time.tick_since(start))
	if len(out) > 0 {
		testing.expect_value(t, out[0], 'x')
		testing.expect_value(t, out[len(out) - 1], 'x')
	}
}

// ---------------------------------------------------------------------------
// The config directory.

// On Windows `os.join_path` keeps a root only with a drive or a share: a
// path that starts with a bare separator comes back relative, so the inputs
// there are drive paths and the results use the platform separator.
@(test)
the_config_directory_follows_xdg_then_home :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		XDG :: `C:\x\cfg`
		HOME :: `C:\home\u`
		WANT_XDG :: `C:\x\cfg\prose`
		WANT_HOME :: `C:\home\u\.config\prose`
	} else {
		XDG :: "/x/cfg"
		HOME :: "/home/u"
		WANT_XDG :: "/x/cfg/prose"
		WANT_HOME :: "/home/u/.config/prose"
	}
	d := prose.config_dir_from(XDG, HOME)
	defer delete(d)
	testing.expect_value(t, d, WANT_XDG)
	d2 := prose.config_dir_from("", HOME)
	defer delete(d2)
	testing.expect_value(t, d2, WANT_HOME)
	testing.expect_value(t, prose.config_dir_from("", ""), "")
}

@(test)
the_public_config_directory_ends_in_prose_or_is_empty :: proc(t: ^testing.T) {
	d := prose.config_dir()
	defer delete(d)
	testing.expect(t, d == "" || strings.has_suffix(d, "prose"))
}
