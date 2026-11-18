package prose

import "base:runtime"
import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode"

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
// `languagetool` left empty goes too. A key that is named like a credential
// (`apiKey`, `api-key`, `key`, `password`, `token`, `secret`, anything that
// ends in token, secret or password; see `is_key_name`), at the top or
// inside `languagetool`, is refused: the key never goes in the settings
// file.
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
	root, kind, detail := parse_object(values_json, allocator)
	defer json.destroy_value(root, allocator)
	switch kind {
	case .None:
	case .Syntax:
		return setup_fail(path, allocator, "the values on standard input are not valid JSON (%s)", detail)
	case .Not_Object:
		return setup_fail(path, allocator, "the values on standard input must be a JSON object")
	case .Unkeepable_Number:
		return setup_fail(path, allocator, "the values on standard input hold a number %s", detail)
	}
	values := &root.(json.Object)
	return apply_object(path, values, "the values on standard input", allocator)
}

// parse_object is `parse_json_object` for setup, which writes what it read
// back, so it also refuses a number it could not write as it is. See
// `find_unkeepable_number`. `detail` of that problem finishes the sentence
// "... a number ...".
@(private = "file")
parse_object :: proc(text: string, allocator: runtime.Allocator) -> (root: json.Value, kind: Json_Problem, detail: string) {
	root, kind, detail = parse_json_object(text, allocator)
	if kind != .None {
		return
	}
	body := strings.trim_prefix(text, "\xEF\xBB\xBF")
	if tok, offset, found := find_unkeepable_number(body); found {
		json.destroy_value(root, allocator)
		return nil, .Unkeepable_Number, fmt.tprintf("prose-check cannot keep exactly: %s at %s", tok, position_text(body, offset))
	}
	return
}

// find_unkeepable_number looks for a number that does not survive being
// read and written again: an integer outside 64 bits, which the parser turns
// into some other number without a word; a float that is out of range
// (1e999 is +Inf, and 1e-999 is 0); everything else is written back with the
// same value. The text has parsed already.
@(private = "file")
find_unkeepable_number :: proc(text: string) -> (number: string, offset: int, found: bool) {
	t := json.make_tokenizer(text, .JSON, true)
	for {
		tok, err := json.get_token(&t)
		if err != .None || tok.kind == .EOF {
			return
		}
		bad := false
		#partial switch tok.kind {
		case .Integer:
			bad = !fits_i64(tok.text)
		case .Float:
			f, ok := strconv.parse_f64(tok.text)
			bad = !ok || math.is_inf(f) || math.is_nan(f) || (f == 0 && has_nonzero_mantissa(tok.text))
		}
		if bad {
			return tok.text, tok.offset, true
		}
	}
}

// fits_i64 tells whether the integer literal `digits` (an optional minus,
// then digits) is within 64 bits. strconv.parse_i64 does not say: it
// returns some number for 123456789012345678901234567890.
@(private = "file")
fits_i64 :: proc(digits: string) -> bool {
	rest := digits
	limit: u64 = 1 << 63 - 1
	if strings.has_prefix(rest, "-") {
		rest = rest[1:]
		limit = 1 << 63
	}
	v: u64
	for c in transmute([]u8)rest {
		d := u64(c - '0')
		if v > (limit - d) / 10 {
			return false
		}
		v = v * 10 + d
	}
	return true
}

// has_nonzero_mantissa tells whether a float literal has a digit but 0 before
// its exponent, so that a value of 0 means it underflowed.
@(private = "file")
has_nonzero_mantissa :: proc(literal: string) -> bool {
	for c in transmute([]u8)literal {
		if c == 'e' || c == 'E' {
			break
		}
		if c >= '1' && c <= '9' {
			return true
		}
	}
	return false
}

// is_key_name tells whether `name` is a spelling of a credential's name. The
// name is read without case, dashes, underscores and dots, so `api-key`,
// `API.KEY` and `apiKey` are one. It is a credential when that is `apikey`,
// `key`, `password`, `token`, `secret`, `apitoken` or `accesstoken`, or ends
// in `token`, `secret` or `password` (`csrf_token`, `clientSecret`). `keyItem`
// (the name of an rbw item, not a key), `keyboard` and `keys` are not.
@(private = "file")
is_key_name :: proc(name: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for r in name {
		switch r {
		case '-', '_', '.':
		case:
			strings.write_rune(&b, unicode.to_lower(r))
		}
	}
	normal := strings.to_string(b)
	switch normal {
	case "apikey", "key", "password", "token", "secret", "apitoken", "accesstoken":
		return true
	}
	return strings.has_suffix(normal, "token") || strings.has_suffix(normal, "secret") || strings.has_suffix(normal, "password")
}

// apply_object is `apply_values` for values already parsed. It takes the
// entries out of `values` and frees what it does not keep; the map itself
// stays the caller's, empty. `from` names where the values came from in a
// problem with one of them ("the values on standard input").
@(private = "file")
apply_object :: proc(path: string, values: ^json.Object, from: string, allocator: runtime.Allocator) -> Settings_Error {
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
			}
		}
	}

	// The values alone must be usable, whatever the stored file holds. A
	// fault found here is in the values, so it names where they came from and
	// not the settings file, which has done nothing wrong.
	checked, verr := read_settings(values^, from, true, allocator)
	settings_destroy(&checked, allocator)
	if verr.problem != "" {
		defer settings_error_destroy(&verr, allocator)
		return setup_fail(path, allocator, "%s", verr.problem)
	}

	if path == "" {
		return setup_fail(path, allocator, "no config directory: set XDG_CONFIG_HOME or HOME")
	}
	// A link is followed, so that the file it points to is the one written
	// and the link stays what it is.
	target, lproblem := resolve_link(path, allocator)
	defer delete(target, allocator)
	if lproblem != "" {
		return setup_fail(path, allocator, "%s: %s", path, lproblem)
	}
	// Merging needs the stored file to be a JSON object; whether the merged
	// result is usable is for the check on the temporary file to say, so a
	// file that fails validation can be repaired from here.
	stored_value, serr := read_stored(target, path, allocator)
	defer json.destroy_value(stored_value, allocator)
	if serr.problem != "" {
		return serr
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
	return write_checked(path, target, strings.to_string(b), allocator)
}

// How many links a settings file may lead through.
@(private = "file")
MAX_LINKS :: 8

// resolve_link follows `path` through symbolic links (relative ones from the
// directory of the link) to the file that holds the settings. A path that is
// no link, or does not exist, comes back as it is. The problem is "" or
// states why the end cannot be found. Allocated with `allocator`.
@(private = "file")
resolve_link :: proc(path: string, allocator: runtime.Allocator) -> (target: string, problem: string) {
	cur := strings.clone(path, allocator)
	for i in 0 ..= MAX_LINKS {
		info, err := os.lstat(cur, allocator)
		if err != nil {
			return cur, ""
		}
		is_link := info.type == .Symlink
		os.file_info_delete(info, allocator)
		if !is_link {
			return cur, ""
		}
		if i == MAX_LINKS {
			break
		}
		dest, rerr := os.read_link(cur, allocator)
		if rerr != nil {
			delete(cur, allocator)
			return "", fmt.tprintf("cannot follow the link (%s)", os.error_string(rerr))
		}
		if os.is_absolute_path(dest) {
			delete(cur, allocator)
			cur = dest
		} else {
			// The kernel reads a relative link from the directory the link is
			// really in. Cleaning `..` out of the path as written gives
			// another file when a directory on the way is a link itself, so
			// the directory is resolved first (on Windows the OS call only
			// makes it absolute).
			dir, _ := os.split_path(cur)
			base, aerr := os.get_absolute_path(dir if dir != "" else ".", allocator)
			if aerr != nil {
				base = strings.clone(dir, allocator)
			}
			joined, _ := os.join_path({base, dest}, allocator)
			delete(base, allocator)
			delete(dest, allocator)
			delete(cur, allocator)
			cur = joined
		}
	}
	delete(cur, allocator)
	return "", fmt.tprintf("leads through too many links (more than %d)", MAX_LINKS)
}

// read_stored reads the settings file at `target` as a JSON object. A file
// that is not there is an empty object. `path` is the name to use in a
// problem. The value is to be freed in every case.
@(private = "file")
read_stored :: proc(target, path: string, allocator: runtime.Allocator) -> (value: json.Value, err: Settings_Error) {
	info, serr := os.stat(target, allocator)
	if serr == .Not_Exist {
		return make(json.Object, allocator), {}
	}
	if serr != nil {
		return nil, setup_fail(path, allocator, "%s: cannot be read (%s)", path, os.error_string(serr))
	}
	size, regular := info.size, info.type == .Regular
	os.file_info_delete(info, allocator)
	if !regular {
		if target != path {
			return nil, setup_fail(path, allocator, "%s: is not a regular file (it is a link to %s)", path, target)
		}
		return nil, setup_fail(path, allocator, "%s: is not a regular file", path)
	}
	if size > MAX_SETTINGS_BYTES {
		return nil, setup_fail(path, allocator, "%s: is too big for a settings file (%d bytes)", path, size)
	}
	data, rerr := os.read_entire_file(target, allocator)
	defer delete(data, allocator)
	if rerr != nil {
		return nil, setup_fail(path, allocator, "%s: cannot be read (%s)", path, os.error_string(rerr))
	}
	parsed, kind, detail := parse_object(string(data), allocator)
	switch kind {
	case .None:
	case .Syntax:
		return parsed, setup_fail(path, allocator, "%s: is not valid JSON (%s)", path, detail)
	case .Not_Object:
		return parsed, setup_fail(path, allocator, "%s: must be a JSON object", path)
	case .Unkeepable_Number:
		return parsed, setup_fail(path, allocator, "%s: holds a number %s", path, detail)
	}
	return parsed, {}
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
		// The shortest text that reads back as the same number, and still a
		// float: 1.0 stays 1.0 and does not become the integer 1.
		buf: [32]byte
		text := strconv.write_float(buf[:], v, 'g', -1, 64)
		text = strings.trim_prefix(text, "+") // JSON has no plus sign
		strings.write_string(b, text)
		if !strings.contains_any(text, ".eE") {
			strings.write_string(b, ".0")
		}
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
write_checked :: proc(path, target, text: string, allocator: runtime.Allocator) -> Settings_Error {
	dir, _ := os.split_path(target)
	created := false
	if dir != "" && !os.exists(dir) {
		parent, _ := os.split_path(dir)
		if parent != "" && !os.exists(parent) {
			if merr := os.make_directory_all(parent); merr != nil && merr != .Exist {
				return setup_fail(
					path,
					allocator,
					"cannot write %s: the directory %s cannot be made (%s)",
					target,
					parent,
					os.error_string(merr),
				)
			}
		}
		if merr := os.make_directory(dir, os.perm_number(0o700)); merr != nil && merr != .Exist {
			return setup_fail(path, allocator, "cannot write %s: the directory cannot be made (%s)", target, os.error_string(merr))
		}
		created = true
	}
	// A directory this call made is removed again when nothing is written;
	// it only goes if it is empty.
	failed := true
	defer if failed && created {
		_ = os.remove(dir)
	}

	sweep_stale_temps(dir, allocator)
	file, tmp, cerr := create_temp(dir, allocator)
	if cerr != nil {
		return setup_fail(path, allocator, "cannot write %s (%s)", target, os.error_string(cerr))
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
		return setup_fail(path, allocator, "cannot write %s (%s)", target, os.error_string(werr))
	}

	checked, verr := load_settings(tmp, allocator)
	settings_destroy(&checked, allocator)
	if verr.problem != "" {
		defer settings_error_destroy(&verr, allocator)
		_ = os.remove(tmp)
		what := strings.trim_prefix(verr.problem, strings.concatenate({tmp, ": "}, context.temp_allocator))
		return setup_fail(path, allocator, "%s: %s", path, what)
	}
	if rerr := os.rename(tmp, target); rerr != nil {
		_ = os.remove(tmp)
		return setup_fail(path, allocator, "cannot write %s: cannot replace it (%s)", target, os.error_string(rerr))
	}
	// The rename is in the directory's entries; without this sync a crash
	// right after could bring the old file back. Best effort: a file system
	// that cannot sync a directory has nothing more to give.
	_ = sync_directory(dir)
	failed = false
	return {}
}

@(private = "file")
TEMP_PREFIX :: ".config.json."
@(private = "file")
TEMP_SUFFIX :: ".tmp"

// sweep_stale_temps removes the temporary files that a crashed write left in
// `dir`: `.config.json.<pid>.<n>.tmp` (see `create_temp`), regular files
// whose process is gone. Not those of this process, which may be writing in
// another thread, and nothing on Windows, which cannot tell a live process
// from a dead one (`process_may_be_alive`). Problems are ignored: a leftover
// is clutter, not a fault of this write.
@(private = "file")
sweep_stale_temps :: proc(dir: string, allocator: runtime.Allocator) {
	entries, err := os.read_all_directory_by_path(dir if dir != "" else ".", allocator)
	if err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, allocator)
	for entry in entries {
		if entry.type != .Regular {
			continue
		}
		pid, ours := temp_file_pid(entry.name)
		if !ours || pid == os.get_pid() || process_may_be_alive(pid) {
			continue
		}
		path: string
		if dir != "" {
			path, _ = os.join_path({dir, entry.name}, allocator)
		} else {
			path = strings.clone(entry.name, allocator)
		}
		_ = os.remove(path)
		delete(path, allocator)
	}
}

// temp_file_pid reads the process id out of the name of a temporary file,
// `.config.json.<pid>.<n>.tmp` with two numbers. It is false for any other
// name.
@(private = "file")
temp_file_pid :: proc(name: string) -> (pid: int, ok: bool) {
	if !strings.has_prefix(name, TEMP_PREFIX) || !strings.has_suffix(name, TEMP_SUFFIX) {
		return 0, false
	}
	middle := name[len(TEMP_PREFIX):len(name) - len(TEMP_SUFFIX)]
	dot := strings.index_byte(middle, '.')
	if dot <= 0 {
		return 0, false
	}
	pid_text, count_text := middle[:dot], middle[dot + 1:]
	if !all_digits(pid_text) || !all_digits(count_text) {
		return 0, false
	}
	return strconv.parse_int(pid_text, 10)
}

@(private = "file")
all_digits :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// create_temp creates a new file in `dir` with mode 0600, under a name no
// other run uses: the process id and a counter, tried until one is free.
@(private = "file")
create_temp :: proc(dir: string, allocator: runtime.Allocator) -> (file: ^os.File, name: string, err: os.Error) {
	pid := os.get_pid()
	for i in 0 ..< 1000 {
		leaf := fmt.tprintf(TEMP_PREFIX + "%d.%d" + TEMP_SUFFIX, pid, i)
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
// rbw item name (Premium) and the language rule. An empty answer keeps what is
// stored (the backend: else `none`); a single `-` clears the rbw item or the
// rule. For Premium it says where the key goes and never asks for the key.
// Problems go to `stderr`. Returns the exit code: 0 written, 2 not.
run_setup_tty :: proc(stdin: io.Reader, stdout, stderr: io.Writer, path: string, allocator := context.allocator) -> int {
	stored, lerr := load_settings(path, allocator)
	defer settings_destroy(&stored, allocator)
	defer settings_error_destroy(&lerr, allocator)
	if lerr.problem != "" {
		// A stored value that fails validation is what setup is there to
		// repair: ask with the defaults, and let the check on the new file
		// decide. Only a file that is no JSON object stops the questions.
		target, lproblem := resolve_link(path, allocator)
		defer delete(target, allocator)
		stored_json, serr := read_stored(target, path, allocator)
		json.destroy_value(stored_json, allocator)
		defer settings_error_destroy(&serr, allocator)
		if lproblem != "" {
			fmt.wprintf(stderr, "prose: %s: %s\nprose: the settings file is unchanged\n", path, lproblem)
			return 2
		}
		if serr.problem != "" {
			fmt.wprintf(stderr, "prose: %s\nprose: the settings file is unchanged\n", serr.problem)
			return 2
		}
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
			if has_http_scheme(answer) {
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
		// The rbw item that holds the key: its name, never the key.
		now_item := stored.key_item
		item_prompt := fmt.tprintf("rbw item name for the key, empty keeps, - clears [%s]: ", now_item) if now_item != "" else "rbw item name for the key, empty for none: "
		item_answer, item_got := ask(&reader, stdout, item_prompt, allocator)
		if item_got != .Ok {
			json.destroy_value(lt, allocator)
			return problem(stderr, item_got)
		}
		switch item_answer {
		case "":
			delete(item_answer, allocator)
		case "-":
			delete(item_answer, allocator)
			set(&lt, "keyItem", json.Null{}, allocator)
		case:
			set(&lt, "keyItem", json.String(item_answer), allocator)
		}
	}

	prompt := `Language rule, empty for none: `
	if r := strings.trim_space(stored.language_rule); r != "" {
		prompt = fmt.tprintf("Language rule, empty keeps, - clears [now: %s]: ", r)
	}
	rule, got := ask(&reader, stdout, prompt, allocator)
	if got != .Ok {
		json.destroy_value(lt, allocator)
		return problem(stderr, got)
	}
	switch rule {
	case "":
		delete(rule, allocator)
	case "-":
		delete(rule, allocator)
		set(&values, "languageRule", json.Null{}, allocator)
	case:
		set(&values, "languageRule", json.String(rule), allocator)
	}
	set(&values, "languagetool", lt, allocator)

	err := apply_object(path, &values, "the answers", allocator)
	defer settings_error_destroy(&err, allocator)
	if err.problem != "" {
		fmt.wprintf(stderr, "prose: %s\nprose: the settings file is unchanged\n", err.problem)
		return 2
	}
	fmt.wprintf(stdout, "\nwrote %s\n", path)
	return 0
}
