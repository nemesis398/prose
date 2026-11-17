package prose

import "base:runtime"
import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"

// `prose-check --setup`: writes the settings file, from the questions on a
// terminal or from a JSON object on standard input (`--values-stdin`, which
// the /prose:setup command uses). Both go through `apply_values`.

// What `--setup` says without a terminal.
SETUP_NEEDS_TERMINAL :: "prose-check --setup needs a terminal; use --values-stdin"

// Why the key cannot be written.
SETUP_NO_KEY_IN_FILE :: "the key never goes in the settings file"

// The order the keys come out in, so that the file looks the same however
// the values arrived. Keys not named here follow, sorted.
@(private = "file")
TOP_ORDER := [?]string{"languageRule", "ignoreWords", "languagetool"}
@(private = "file")
LT_ORDER := [?]string{"backend", "server", "username", "keyItem"}

// The longest answer a question takes.
@(private = "file")
MAX_ANSWER_BYTES :: 64 << 10

@(private = "file")
setup_fail :: proc(path: string, allocator: runtime.Allocator, format: string, args: ..any) -> Settings_Error {
	return Settings_Error{path = strings.clone(path, allocator), problem = fmt.aprintf(format, ..args, allocator = allocator)}
}

// apply_values merges `values_json`, a JSON object, into the settings file
// at `path` and writes the result.
//
// The keys given replace the stored ones; all others are kept, unknown ones
// with their JSON values. `languagetool` is merged key by key. A key set to
// `null` is deleted, which is how a backend switch drops `server`; a
// `languagetool` left empty goes too. A key named `apiKey` (any case,
// `api_key` too), at the top or inside `languagetool`, is refused: the key
// never goes in the settings file.
//
// The result is stable, pretty JSON: two-space indent, `languageRule`,
// `ignoreWords`, `languagetool` (`backend`, `server`, `username`,
// `keyItem`), then the unknown keys sorted. It goes to a temporary file in
// the same directory (mode 0600), is read back with `load_settings`, and
// only a file that passes replaces `path`; otherwise the old file is left
// byte for byte as it was. A missing directory is created with mode 0700.
// A stored file that is not usable is not overwritten: the error is its own.
//
// Any problem comes back in the `Settings_Error` with the file untouched;
// its `problem` is ready to print after `prose: `. Allocated with
// `allocator`; free with `settings_error_destroy`.
apply_values :: proc(path, values_json: string, allocator := context.allocator) -> Settings_Error {
	if len(values_json) > MAX_SETTINGS_BYTES {
		return setup_fail(path, allocator, "the values are too big (%d bytes)", len(values_json))
	}
	root, problem := parse_object(values_json, allocator)
	if problem != "" {
		defer json.destroy_value(root, allocator)
		return setup_fail(path, allocator, "the values on standard input are %s", problem)
	}
	defer json.destroy_value(root, allocator)
	values := &root.(json.Object)
	return apply_object(path, values, allocator)
}

// parse_object parses `text` as one JSON object, and nothing after it. The
// problem is "" or a short phrase; on a problem the value is to be freed
// all the same. A byte order mark is skipped.
@(private = "file")
parse_object :: proc(text: string, allocator: runtime.Allocator) -> (root: json.Value, problem: string) {
	body := strings.trim_prefix(text, "\xEF\xBB\xBF")
	parser := json.make_parser_from_string(body, .JSON, false, allocator)
	value, jerr := json.parse_value(&parser)
	if jerr != .None {
		return value, fmt.tprintf("not valid JSON (%v)", jerr)
	}
	if parser.curr_token.kind != .EOF {
		return value, "not valid JSON (text after the closing brace)"
	}
	if _, is_obj := value.(json.Object); !is_obj {
		return value, "not a JSON object"
	}
	return value, ""
}

// is_key_name tells whether `name` is a spelling of the API key's name.
@(private = "file")
is_key_name :: proc(name: string) -> bool {
	return strings.equal_fold(name, "apiKey") || strings.equal_fold(name, "api_key")
}

// apply_object is `apply_values` for values already parsed. It takes the
// entries out of `values` and frees what it does not keep; the map itself
// stays the caller's, empty.
@(private = "file")
apply_object :: proc(path: string, values: ^json.Object, allocator: runtime.Allocator) -> Settings_Error {
	for key, value in values {
		if is_key_name(key) {
			return setup_fail(path, allocator, SETUP_NO_KEY_IN_FILE + " (refused %q)", key)
		}
		if key == "languagetool" {
			if lt, is_obj := value.(json.Object); is_obj {
				for k in lt {
					if is_key_name(k) {
						return setup_fail(path, allocator, SETUP_NO_KEY_IN_FILE + " (refused %q in \"languagetool\")", k)
					}
				}
			} else if _, is_null := value.(json.Null); !is_null {
				return setup_fail(path, allocator, "%s: \"languagetool\" must be an object", path)
			}
		}
	}

	if path == "" {
		return setup_fail(path, allocator, "no config directory: set XDG_CONFIG_HOME or HOME")
	}
	// The stored file must be usable before it is rewritten.
	stored_settings, lerr := load_settings(path, allocator)
	settings_destroy(&stored_settings, allocator)
	if lerr.problem != "" {
		return lerr
	}
	stored_value: json.Value
	defer json.destroy_value(stored_value, allocator)
	data, rerr := os.read_entire_file(path, allocator)
	defer delete(data, allocator)
	switch {
	case rerr == nil:
		parsed, problem := parse_object(string(data), allocator)
		stored_value = parsed
		if problem != "" {
			return setup_fail(path, allocator, "%s: is %s", path, problem)
		}
	case rerr == .Not_Exist:
		stored_value = make(json.Object, allocator)
	case:
		return setup_fail(path, allocator, "%s: cannot be read (%s)", path, os.error_string(rerr))
	}
	stored := &stored_value.(json.Object)

	merge(stored, values, allocator)
	if lt, ok := &stored["languagetool"]; ok {
		if obj, is_obj := lt^.(json.Object); is_obj && len(obj) == 0 {
			delete_entry(stored, "languagetool", allocator)
		}
	}

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	emit_object(&b, stored^, 0, TOP_ORDER[:], true)
	strings.write_byte(&b, '\n')
	return write_checked(path, strings.to_string(b), allocator)
}

// delete_entry removes `key` from `obj`, freeing the key and its value.
@(private = "file")
delete_entry :: proc(obj: ^json.Object, key: string, allocator: runtime.Allocator) {
	if key in obj^ {
		k, v := delete_key(obj, key)
		delete(k, allocator)
		json.destroy_value(v, allocator)
	}
}

@(private = "file")
is_object :: proc(v: json.Value) -> bool {
	_, ok := v.(json.Object)
	return ok
}

// merge moves the entries of `values` into `stored`. Entries in `stored`
// that they replace are freed; `null` deletes. At the top, a `languagetool`
// object is merged key by key.
@(private = "file")
merge :: proc(stored, values: ^json.Object, allocator: runtime.Allocator, top := true) {
	keys := make([]string, len(values^), context.temp_allocator)
	i := 0
	for k in values^ {
		keys[i] = k
		i += 1
	}
	for key in keys {
		new_key, new_value := delete_key(values, key)
		_, is_null := new_value.(json.Null)
		if top && key == "languagetool" {
			if new_obj, new_is_obj := &new_value.(json.Object); new_is_obj {
				// Into the stored object, or into a new one when there is
				// none, so that a `null` inside still deletes.
				if old, have := &stored[key]; !have || !is_object(old^) {
					delete_entry(stored, key, allocator)
					stored[strings.clone(key, allocator)] = make(json.Object, allocator)
				}
				slot := &stored[key]
				old_obj := &slot.(json.Object)
				merge(old_obj, new_obj, allocator, false)
				delete(new_key, allocator)
				json.destroy_value(new_value, allocator)
				continue
			}
		}
		delete_entry(stored, key, allocator)
		if is_null {
			delete(new_key, allocator)
			continue
		}
		stored[new_key] = new_value
	}
}

// emit_object writes `obj` as pretty JSON at `depth`: the keys of `order`
// first, in that order, then the rest sorted. With `lt_aware`, a
// `languagetool` object follows `LT_ORDER`.
@(private = "file")
emit_object :: proc(b: ^strings.Builder, obj: json.Object, depth: int, order: []string, lt_aware: bool) {
	if len(obj) == 0 {
		strings.write_string(b, "{}")
		return
	}
	rest := make([dynamic]string, context.temp_allocator)
	for k in obj {
		if !slice.contains(order, k) {
			append(&rest, k)
		}
	}
	slice.sort(rest[:])
	keys := make([dynamic]string, context.temp_allocator)
	for k in order {
		if k in obj {
			append(&keys, k)
		}
	}
	append(&keys, ..rest[:])

	strings.write_string(b, "{\n")
	for key, i in keys {
		indent(b, depth + 1)
		write_json_string(b, key)
		strings.write_string(b, ": ")
		value := obj[key]
		if lt, is_obj := value.(json.Object); is_obj && lt_aware && key == "languagetool" {
			emit_object(b, lt, depth + 1, LT_ORDER[:], false)
		} else {
			emit_value(b, value, depth + 1)
		}
		strings.write_string(b, ",\n" if i + 1 < len(keys) else "\n")
	}
	indent(b, depth)
	strings.write_byte(b, '}')
}

@(private = "file")
emit_value :: proc(b: ^strings.Builder, value: json.Value, depth: int) {
	switch v in value {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, "true" if v else "false")
	case json.Integer:
		strings.write_i64(b, v)
	case json.Float:
		strings.write_float(b, v, 'g', -1, 64)
	case json.String:
		write_json_string(b, string(v))
	case json.Array:
		if len(v) == 0 {
			strings.write_string(b, "[]")
			return
		}
		strings.write_string(b, "[\n")
		for item, i in v {
			indent(b, depth + 1)
			emit_value(b, item, depth + 1)
			strings.write_string(b, ",\n" if i + 1 < len(v) else "\n")
		}
		indent(b, depth)
		strings.write_byte(b, ']')
	case json.Object:
		emit_object(b, v, depth, nil, false)
	}
}

@(private = "file")
indent :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
}

// write_json_string writes `s` as a JSON string: the quote, the backslash
// and the control characters escaped, everything else as it is.
@(private = "file")
write_json_string :: proc(b: ^strings.Builder, s: string) {
	hex := "0123456789abcdef"
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case 0 ..< 0x20, 0x7f:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, hex[c >> 4])
			strings.write_byte(b, hex[c & 15])
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// write_checked writes `text` to `path` through a temporary file next to it
// and replaces `path` only when `load_settings` accepts what was written.
// Creates the directory (mode 0700) when it is missing.
@(private = "file")
write_checked :: proc(path, text: string, allocator: runtime.Allocator) -> Settings_Error {
	dir, _ := os.split_path(path)
	created := false
	if dir != "" && !os.exists(dir) {
		parent, _ := os.split_path(dir)
		if parent != "" {
			_ = os.make_directory_all(parent)
		}
		if merr := os.make_directory(dir, os.perm_number(0o700)); merr != nil && merr != .Exist {
			return setup_fail(path, allocator, "%s: the directory cannot be made (%s)", path, os.error_string(merr))
		}
		created = true
	}
	// A directory this call made is removed again when nothing is written;
	// it only goes if it is empty.
	failed := true
	defer if failed && created {
		_ = os.remove(dir)
	}

	file, tmp, cerr := create_temp(dir, allocator)
	if cerr != nil {
		return setup_fail(path, allocator, "%s: cannot write the settings (%s)", path, os.error_string(cerr))
	}
	defer delete(tmp, allocator)
	n, werr := os.write(file, transmute([]byte)text)
	if werr == nil && n != len(text) {
		werr = io.Error.Short_Write
	}
	if werr == nil {
		werr = os.sync(file)
	}
	cl := os.close(file)
	if werr == nil {
		werr = cl
	}
	if werr != nil {
		_ = os.remove(tmp)
		return setup_fail(path, allocator, "%s: cannot write the settings (%s)", path, os.error_string(werr))
	}

	checked, verr := load_settings(tmp, allocator)
	settings_destroy(&checked, allocator)
	if verr.problem != "" {
		defer settings_error_destroy(&verr, allocator)
		_ = os.remove(tmp)
		what := strings.trim_prefix(verr.problem, strings.concatenate({tmp, ": "}, context.temp_allocator))
		return setup_fail(path, allocator, "%s: %s", path, what)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return setup_fail(path, allocator, "%s: cannot replace the settings (%s)", path, os.error_string(rerr))
	}
	failed = false
	return {}
}

// create_temp creates a new file in `dir` with mode 0600, under a name no
// other run uses: the process id and a counter, tried until one is free.
@(private = "file")
create_temp :: proc(dir: string, allocator: runtime.Allocator) -> (file: ^os.File, name: string, err: os.Error) {
	pid := os.get_pid()
	for i in 0 ..< 1000 {
		leaf := fmt.tprintf(".config.json.%d.%d.tmp", pid, i)
		full := leaf
		if dir != "" {
			full, _ = os.join_path({dir, leaf}, allocator)
		} else {
			full = strings.clone(leaf, allocator)
		}
		file, err = os.open(full, {.Write, .Create, .Excl}, os.perm_number(0o600))
		if err == nil {
			return file, full, nil
		}
		delete(full, allocator)
		if err != .Exist {
			return nil, "", err
		}
	}
	return nil, "", .Exist
}

// ---- the questions on a terminal ----

// The backends in the order the question lists them, with where each one
// sends the text.
@(private = "file")
Choice :: struct {
	name, sends: string,
}

@(private = "file")
CHOICES := [?]Choice {
	{"none", "nothing leaves this machine"},
	{"public", "your text goes to LanguageTool's free public server"},
	{"premium", "your text goes to LanguageTool's Premium API under your account"},
	{"server", "your text goes to the server you name"},
}

@(private = "file")
Answer :: enum {
	Ok,
	Eof,
	Too_Long,
	Failed,
}

// ask writes `prompt`, flushes so that it shows before the user answers, and
// reads one line, trimmed. A last line without a newline counts. The answer
// is allocated with `allocator`.
@(private = "file")
ask :: proc(r: ^bufio.Reader, w: io.Writer, prompt: string, allocator: runtime.Allocator) -> (string, Answer) {
	_, _ = io.write_string(w, prompt)
	_ = io.flush(w)
	line, err := bufio.reader_read_slice(r, '\n')
	switch {
	case err == .Buffer_Full:
		return "", .Too_Long
	case err == .EOF && len(line) == 0:
		return "", .Eof
	case err != nil && err != .EOF:
		return "", .Failed
	}
	return strings.clone(strings.trim_space(string(line)), allocator), .Ok
}

// run_setup_tty asks the questions of `--setup` on `stdin` and `stdout`
// and writes the settings file at `path`: the backend (naming where each one
// sends the text), then the server URL or the Premium user name, then the
// language rule. An empty answer keeps the stored backend (else `none`) and
// the stored URL or user name; an empty rule means no rule and drops a
// stored one. For Premium it says where the key goes and never asks for it.
// Problems go to `stderr`. Returns the exit code: 0 written, 2 not.
run_setup_tty :: proc(stdin: io.Reader, stdout, stderr: io.Writer, path: string, allocator := context.allocator) -> int {
	stored, lerr := load_settings(path, allocator)
	defer settings_destroy(&stored, allocator)
	defer settings_error_destroy(&lerr, allocator)
	if lerr.problem != "" {
		fmt.wprintf(stderr, "prose: %s\nprose: the settings file is unchanged\n", lerr.problem)
		return 2
	}

	buf := make([]byte, MAX_ANSWER_BYTES, allocator)
	defer delete(buf, allocator)
	reader: bufio.Reader
	bufio.reader_init_with_buf(&reader, stdin, buf)

	problem :: proc(stderr: io.Writer, what: Answer) -> int {
		switch what {
		case .Eof:
			fmt.wprintf(stderr, "prose: the input ended before the questions did; the settings file is unchanged\n")
		case .Too_Long:
			fmt.wprintf(stderr, "prose: an answer is too long; the settings file is unchanged\n")
		case .Failed:
			fmt.wprintf(stderr, "prose: cannot read the answer; the settings file is unchanged\n")
		case .Ok:
		}
		return 2
	}

	default_backend := "none"
	if kind, ok := stored.backend.?; ok {
		default_backend = CHOICES[int(kind)].name
	}
	_, _ = io.write_string(stdout, "Where may your text go when it is checked?\n")
	for c in CHOICES {
		fmt.wprintf(stdout, "  %-8s %s\n", c.name, c.sends)
	}
	backend: string
	defer delete(backend, allocator)
	for {
		answer, got := ask(&reader, stdout, fmt.tprintf("Backend [%s]: ", default_backend), allocator)
		if got != .Ok {
			return problem(stderr, got)
		}
		if answer == "" {
			delete(answer, allocator)
			answer = strings.clone(default_backend, allocator)
		}
		lowered := strings.to_lower(answer, context.temp_allocator)
		known := false
		for c in CHOICES {
			known ||= c.name == lowered
		}
		if known {
			backend = strings.clone(lowered, allocator)
			delete(answer, allocator)
			break
		}
		fmt.wprintf(stdout, "%q is not one of none, public, premium, server.\n", answer)
		delete(answer, allocator)
	}

	values := make(json.Object, allocator)
	defer json.destroy_value(values, allocator)
	lt := make(json.Object, allocator)
	set :: proc(obj: ^json.Object, key: string, value: json.Value, allocator: runtime.Allocator) {
		obj[strings.clone(key, allocator)] = value
	}
	set(&lt, "backend", json.String(strings.clone(backend, allocator)), allocator)
	// `server` only belongs with the server backend; a stored one goes when
	// the backend changes.
	if backend != "server" {
		set(&lt, "server", json.Null{}, allocator)
	}

	switch backend {
	case "server":
		for {
			now := stored.server
			prompt := fmt.tprintf("Server URL (http:// or https://) [%s]: ", now) if now != "" else "Server URL (http:// or https://): "
			answer, got := ask(&reader, stdout, prompt, allocator)
			if got != .Ok {
				json.destroy_value(lt, allocator)
				return problem(stderr, got)
			}
			if answer == "" {
				delete(answer, allocator)
				answer = strings.clone(now, allocator)
			}
			if strings.has_prefix(answer, "http://") || strings.has_prefix(answer, "https://") {
				set(&lt, "server", json.String(answer), allocator)
				break
			}
			fmt.wprintf(stdout, "The URL has to start with http:// or https://.\n")
			delete(answer, allocator)
		}
	case "premium":
		dir, _ := os.split_path(path)
		cred := config_file_in(dir, "credentials", context.temp_allocator)
		if cred == "" {
			cred = "$XDG_CONFIG_HOME/prose/credentials"
		}
		item := `the rbw item named in "languagetool.keyItem" (rbw installed and unlocked)`
		if stored.key_item != "" {
			item = fmt.tprintf(`the rbw item "%s" (rbw installed and unlocked)`, stored.key_item)
		}
		fmt.wprintf(stdout, "\nPremium needs your API key. prose-check never asks for it and never writes it to the settings file.\n")
		fmt.wprintf(stdout, "It looks for the key in this order:\n")
		fmt.wprintf(stdout, "  1. the environment variable %s\n", ENV_API_KEY)
		fmt.wprintf(stdout, "  2. %s\n", item)
		fmt.wprintf(stdout, "  3. the file %s, holding only the key (mode 600)\n\n", cred)
		now := stored.username
		prompt := fmt.tprintf("Premium account user name [%s]: ", now) if now != "" else "Premium account user name: "
		answer, got := ask(&reader, stdout, prompt, allocator)
		if got != .Ok {
			json.destroy_value(lt, allocator)
			return problem(stderr, got)
		}
		if answer == "" {
			delete(answer, allocator)
		} else {
			set(&lt, "username", json.String(answer), allocator)
		}
	}

	prompt := `Language rule, empty for none: `
	if r := strings.trim_space(stored.language_rule); r != "" {
		prompt = fmt.tprintf("Language rule, empty for none [now: %s]: ", r)
	}
	rule, got := ask(&reader, stdout, prompt, allocator)
	if got != .Ok {
		json.destroy_value(lt, allocator)
		return problem(stderr, got)
	}
	if rule == "" {
		delete(rule, allocator)
		set(&values, "languageRule", json.Null{}, allocator)
	} else {
		set(&values, "languageRule", json.String(rule), allocator)
	}
	set(&values, "languagetool", lt, allocator)

	err := apply_object(path, &values, allocator)
	defer settings_error_destroy(&err, allocator)
	if err.problem != "" {
		fmt.wprintf(stderr, "prose: %s\nprose: the settings file is unchanged\n", err.problem)
		return 2
	}
	fmt.wprintf(stdout, "\nwrote %s\n", path)
	return 0
}
