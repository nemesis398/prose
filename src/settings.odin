package prose

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Which LanguageTool the grammar pass talks to, if any. `None` sends
// nothing anywhere. It is the zero value, so a `Backend` or `Check_Options`
// left empty checks locally only.
Backend_Kind :: enum {
	None,
	Public,
	Premium,
	Server,
}

// What `config.json` holds. Every field is optional; a file that is absent
// reads as the zero `Settings`. Everything in it is allocated with the
// allocator given to `load_settings` and freed by `settings_destroy`.
//
// `backend` is nil when the file does not name one, which is not the same as
// `.None`: without a choice in the file the exported variables count.
// `ignore_words` are trimmed, with blank entries dropped. `unknown_keys`
// lists the keys the checker does not know, sorted, nested ones as
// "languagetool.NAME"; `--selftest` notes them, nothing else does.
Settings :: struct {
	language_rule:    string,
	ignore_words:     []string,
	backend:          Maybe(Backend_Kind),
	server, username: string,
	key_item:         string,
	unknown_keys:     []string,
}

// Why a settings file cannot be used. An empty `problem` means no error.
// `problem` states the file and what is wrong, for example
// `/x/config.json: "languagetool.backend" must be one of none, public,
// premium, server`; `path` is the file alone. Both are allocated with the
// allocator given to `load_settings`; free them with
// `settings_error_destroy`.
Settings_Error :: struct {
	path, problem: string,
}

// The three LanguageTool variables, read once. Empty means unset.
// `env_from_os` allocates; free with `env_destroy`.
Env :: struct {
	server, username, api_key: string,
}

// The chosen backend. `url` is the endpoint with no path (`/v2/check` is for
// the client to add). `username` and `key` are set for `.Premium` only: the
// public server and a self-hosted one get neither. `label` names the
// backend in a message: "free cloud", "premium cloud" or "self-hosted", the
// reference's words. A `.None` backend is all empty. The key lives here and
// nowhere else; nothing in this package prints it. Strings are allocated
// with the allocator given to `choose_backend`; free with `backend_destroy`.
Backend :: struct {
	kind:                      Backend_Kind,
	url, username, key, label: string,
}

// Where the Premium key can come from besides the environment.
//
// `rbw` reads the password of a Bitwarden item with the rbw agent and
// reports whether it got one; it must never prompt. Its string is borrowed:
// `choose_backend` copies it and never frees it, so the real `rbw_lookup`
// allocates with `context.temp_allocator`, and a test stub may return a
// literal. A nil `rbw` is rbw absent.
//
// `credentials_path` is `$XDG_CONFIG_HOME/prose/credentials`, or empty for
// none.
Key_Lookup :: struct {
	rbw:              proc(item: string) -> (string, bool),
	credentials_path: string,
}

PUBLIC_URL :: "https://api.languagetool.org"
PREMIUM_URL :: "https://api.languagetoolplus.com"

ENV_SERVER :: "LANGUAGETOOL_SERVER"
ENV_USERNAME :: "LANGUAGETOOL_USERNAME"
ENV_API_KEY :: "LANGUAGETOOL_API_KEY"

// A settings file bigger than this is refused rather than read. A real one
// is a few hundred bytes.
MAX_SETTINGS_BYTES :: 1 << 20
// The credentials file holds one line.
MAX_CREDENTIALS_BYTES :: 64 << 10

@(private = "file")
BACKEND_NAMES :: "none, public, premium, server"

settings_destroy :: proc(s: ^Settings, allocator := context.allocator) {
	delete(s.language_rule, allocator)
	for w in s.ignore_words {
		delete(w, allocator)
	}
	delete(s.ignore_words, allocator)
	delete(s.server, allocator)
	delete(s.username, allocator)
	delete(s.key_item, allocator)
	for k in s.unknown_keys {
		delete(k, allocator)
	}
	delete(s.unknown_keys, allocator)
	s^ = {}
}

settings_error_destroy :: proc(e: ^Settings_Error, allocator := context.allocator) {
	delete(e.path, allocator)
	delete(e.problem, allocator)
	e^ = {}
}

env_destroy :: proc(e: ^Env, allocator := context.allocator) {
	delete(e.server, allocator)
	delete(e.username, allocator)
	delete(e.api_key, allocator)
	e^ = {}
}

backend_destroy :: proc(b: ^Backend, allocator := context.allocator) {
	delete(b.url, allocator)
	delete(b.username, allocator)
	delete(b.key, allocator)
	delete(b.label, allocator)
	b^ = {}
}

// env_from_os reads the three LanguageTool variables. Allocates with
// `allocator`; free with `env_destroy`.
env_from_os :: proc(allocator := context.allocator) -> Env {
	return Env {
		server = os.get_env(ENV_SERVER, allocator),
		username = os.get_env(ENV_USERNAME, allocator),
		api_key = os.get_env(ENV_API_KEY, allocator),
	}
}

// config_dir is `$XDG_CONFIG_HOME/prose`, or `~/.config/prose` when that
// variable is empty or unset. It is "" when neither is known, and the file
// helpers below then name no file. Allocated with `allocator`.
config_dir :: proc(allocator := context.allocator) -> string {
	xdg := os.get_env("XDG_CONFIG_HOME", allocator)
	defer delete(xdg, allocator)
	home, _ := os.user_home_dir(allocator)
	defer delete(home, allocator)
	return config_dir_from(xdg, home, allocator)
}

// config_dir_from is `config_dir` with the two inputs given, for tests.
config_dir_from :: proc(xdg_config_home, home: string, allocator := context.allocator) -> string {
	base := xdg_config_home
	joined: string
	if base != "" {
		joined, _ = os.join_path({base, "prose"}, allocator)
	} else if home != "" {
		joined, _ = os.join_path({home, ".config", "prose"}, allocator)
	}
	return joined
}

// config_file is NAME inside the config directory ("config.json",
// "credentials", "dictionary.txt"), or "" when there is no config directory.
// Allocated with `allocator`.
config_file :: proc(name: string, allocator := context.allocator) -> string {
	dir := config_dir(allocator)
	defer delete(dir, allocator)
	return config_file_in(dir, name, allocator)
}

// config_file_in is `config_file` for a given config directory.
config_file_in :: proc(dir, name: string, allocator := context.allocator) -> string {
	if dir == "" {
		return ""
	}
	path, _ := os.join_path({dir, name}, allocator)
	return path
}

@(private = "file")
fail :: proc(path: string, allocator: runtime.Allocator, format: string, args: ..any) -> Settings_Error {
	what := fmt.tprintf(format, ..args)
	return Settings_Error {
		path = strings.clone(path, allocator),
		problem = strings.concatenate({path, ": ", what}, allocator),
	}
}

// load_settings reads the settings file at `path`. A file that does not
// exist, or an empty `path`, is no settings and no error. A file that exists
// but cannot be used is an error, and `Settings` is then empty: invalid
// JSON, a top level that is not an object, a key of the wrong type, an
// unknown `backend`, a `server` backend without a URL (or with one that does
// not start with http:// or https://), a file bigger than a MiB, or
// something that is not a regular file. Reading it as "no settings" would
// turn Premium off after one typo.
//
// A key the checker does not know is no error; it lands in `unknown_keys`.
// The Premium key is never read from here. Free the results with
// `settings_destroy` and `settings_error_destroy`.
load_settings :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	s: Settings,
	err: Settings_Error,
) {
	s, err = parse_settings(path, allocator)
	if err.problem != "" {
		// Not a deferred cleanup: Odin copies the named results before it
		// runs a defer, so a defer cannot empty them.
		settings_destroy(&s, allocator)
	}
	return
}

@(private = "file")
parse_settings :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> (
	s: Settings,
	err: Settings_Error,
) {
	if path == "" {
		return
	}

	info, serr := os.stat(path, allocator)
	if serr == .Not_Exist {
		return
	}
	if serr != nil {
		err = fail(path, allocator, "cannot be read (%s)", os.error_string(serr))
		return
	}
	size, is_regular := info.size, info.type == .Regular
	os.file_info_delete(info, allocator)
	if !is_regular {
		err = fail(path, allocator, "is not a regular file")
		return
	}
	if size > MAX_SETTINGS_BYTES {
		err = fail(path, allocator, "is too big for a settings file (%d bytes)", size)
		return
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		err = fail(path, allocator, "cannot be read (%s)", os.error_string(rerr))
		return
	}
	defer delete(data, allocator)
	text := string(data)
	text = strings.trim_prefix(text, "\xEF\xBB\xBF")

	// A parser of our own rather than `json.parse`, which stops after the
	// first value and would let anything after it through.
	parser := json.make_parser_from_string(text, .JSON, false, allocator)
	root, jerr := json.parse_value(&parser)
	if jerr != .None {
		err = fail(path, allocator, "is not valid JSON (%v)", jerr)
		return
	}
	defer json.destroy_value(root, allocator)
	if parser.curr_token.kind != .EOF {
		err = fail(path, allocator, "is not valid JSON (text after the closing brace)")
		return
	}
	obj, is_obj := root.(json.Object)
	if !is_obj {
		err = fail(path, allocator, "must be a JSON object")
		return
	}

	unknown: [dynamic]string
	unknown.allocator = allocator
	defer if err.problem != "" {
		for k in unknown {
			delete(k, allocator)
		}
		delete(unknown)
	}
	// Sorted keys, so that with two mistakes the message does not depend on
	// the map's order.
	for key in sorted_keys(obj) {
		value := obj[key]
		switch key {
		case "languageRule":
			str, ok := value.(json.String)
			if !ok {
				err = fail(path, allocator, `"languageRule" must be a string`)
				return
			}
			s.language_rule = strings.clone(string(str), allocator)
		case "ignoreWords":
			words, ok := read_words(value, allocator)
			if !ok {
				err = fail(path, allocator, `"ignoreWords" must be a list of strings`)
				return
			}
			s.ignore_words = words
		case "languagetool":
			lt, ok := value.(json.Object)
			if !ok {
				err = fail(path, allocator, `"languagetool" must be an object`)
				return
			}
			if !read_languagetool(&s, lt, &unknown, path, &err, allocator) {
				return
			}
		case:
			append(&unknown, strings.clone(key, allocator))
		}
	}

	if kind, ok := s.backend.?; ok && kind == .Server {
		if s.server == "" {
			err = fail(path, allocator, `"languagetool.server" is needed when "languagetool.backend" is "server"`)
			return
		}
	}
	slice.sort(unknown[:])
	s.unknown_keys = unknown[:]
	return
}

@(private = "file")
sorted_keys :: proc(obj: json.Object) -> []string {
	keys := make([]string, len(obj), context.temp_allocator)
	i := 0
	for k in obj {
		keys[i] = k
		i += 1
	}
	slice.sort(keys)
	return keys
}

// read_words reads a JSON list of strings, trimmed, blanks dropped. On a
// wrong type it frees what it made and returns false.
@(private = "file")
read_words :: proc(value: json.Value, allocator: runtime.Allocator) -> (words: []string, ok: bool) {
	list, is_list := value.(json.Array)
	if !is_list {
		return nil, false
	}
	out: [dynamic]string
	out.allocator = allocator
	for item in list {
		str, is_str := item.(json.String)
		if !is_str {
			for w in out {
				delete(w, allocator)
			}
			delete(out)
			return nil, false
		}
		word := strings.trim_space(string(str))
		if word != "" {
			append(&out, strings.clone(word, allocator))
		}
	}
	return out[:], true
}

// read_languagetool reads the "languagetool" object into `s`. It returns
// false, with `err` set, on the first problem.
@(private = "file")
read_languagetool :: proc(
	s: ^Settings,
	lt: json.Object,
	unknown: ^[dynamic]string,
	path: string,
	err: ^Settings_Error,
	allocator: runtime.Allocator,
) -> bool {
	for key in sorted_keys(lt) {
		value := lt[key]
		switch key {
		case "backend":
			str, ok := value.(json.String)
			kind: Backend_Kind
			switch string(str) if ok else "" {
			case "none":
				kind = .None
			case "public":
				kind = .Public
			case "premium":
				kind = .Premium
			case "server":
				kind = .Server
			case:
				err^ = fail(path, allocator, `"languagetool.backend" must be one of ` + BACKEND_NAMES)
				return false
			}
			s.backend = kind
		case "server":
			str, ok := value.(json.String)
			if !ok {
				err^ = fail(path, allocator, `"languagetool.server" must be a string`)
				return false
			}
			if str != "" && !(strings.has_prefix(string(str), "http://") || strings.has_prefix(string(str), "https://")) {
				err^ = fail(path, allocator, `"languagetool.server" must start with http:// or https://`)
				return false
			}
			s.server = strings.clone(string(str), allocator)
		case "username":
			str, ok := value.(json.String)
			if !ok {
				err^ = fail(path, allocator, `"languagetool.username" must be a string`)
				return false
			}
			s.username = strings.clone(string(str), allocator)
		case "keyItem":
			str, ok := value.(json.String)
			if !ok {
				err^ = fail(path, allocator, `"languagetool.keyItem" must be a string`)
				return false
			}
			s.key_item = strings.clone(string(str), allocator)
		case:
			append(unknown, strings.concatenate({"languagetool.", key}, allocator))
		}
	}
	return true
}

// choose_backend picks the backend and fills in its values.
//
// The file wins: `s.backend`, when set, is the backend, and the variables
// only fill in its values. Without it, `env.server` means `.Server`, and
// `env.api_key` together with `env.username` mean `.Premium`; with neither,
// `.None`. For the chosen backend `env.server` beats `s.server`,
// `env.username` beats `s.username`, and the key comes from the first of:
// `env.api_key`; the rbw item `s.key_item`, when `key_lookup.rbw` is set;
// the credentials file `key_lookup.credentials_path`, holding only the key
// and refused when its mode is wider than 600 (the mode is not checked on
// Windows). The key is never taken from the
// settings file.
//
// The second result is the problem that stops the check with exit 2: a
// premium backend without an account or a key (the message names all three
// key sources), a wider credentials file, a server backend without a URL.
// It is "" when all is well, and then `Backend` is set. On a problem
// `Backend` is empty. The message never holds the key.
//
// Both results are allocated with `allocator`; free the backend with
// `backend_destroy` and the problem with `delete`.
choose_backend :: proc(
	s: Settings,
	env: Env,
	key_lookup: Key_Lookup,
	allocator := context.allocator,
) -> (
	b: Backend,
	problem: string,
) {
	kind: Backend_Kind
	if chosen, ok := s.backend.?; ok {
		kind = chosen
	} else if env.server != "" {
		kind = .Server
	} else if env.api_key != "" && env.username != "" {
		kind = .Premium
	}

	switch kind {
	case .None:
		return
	case .Public:
		b = Backend {
			kind  = .Public,
			url   = strings.clone(PUBLIC_URL, allocator),
			label = strings.clone("free cloud", allocator),
		}
	case .Server:
		url := env.server if env.server != "" else s.server
		if url == "" {
			problem = strings.clone(
				"the server backend needs a URL: set " + ENV_SERVER + " or \"languagetool.server\" in config.json",
				allocator,
			)
			return
		}
		b = Backend {
			kind  = .Server,
			url   = strings.clone(url, allocator),
			label = strings.clone("self-hosted", allocator),
		}
	case .Premium:
		username := env.username if env.username != "" else s.username
		key, key_problem := find_key(s, env, key_lookup, allocator)
		defer delete(key_problem, allocator)
		if username == "" || key_problem != "" {
			problem = premium_problem(username == "", key_problem, allocator)
			delete(key, allocator)
			return
		}
		b = Backend {
			kind     = .Premium,
			url      = strings.clone(PREMIUM_URL, allocator),
			username = strings.clone(username, allocator),
			key      = key,
			label    = strings.clone("premium cloud", allocator),
		}
	}
	return
}

// premium_problem words what keeps Premium from running.
@(private = "file")
premium_problem :: proc(no_username: bool, key_problem: string, allocator: runtime.Allocator) -> string {
	parts: [2]string
	n := 0
	if no_username {
		parts[n] = "LanguageTool Premium needs the account: set " + ENV_USERNAME + " or \"languagetool.username\" in config.json"
		n += 1
	}
	if key_problem != "" {
		parts[n] = key_problem
		n += 1
	}
	return strings.join(parts[:n], "; ", allocator)
}

// find_key walks the key sources in order. It returns the key (allocated),
// or "" and the problem to show.
@(private = "file")
find_key :: proc(
	s: Settings,
	env: Env,
	lookup: Key_Lookup,
	allocator: runtime.Allocator,
) -> (
	key: string,
	problem: string,
) {
	if env.api_key != "" {
		return strings.clone(env.api_key, allocator), ""
	}
	if s.key_item != "" && lookup.rbw != nil {
		if k, ok := lookup.rbw(s.key_item); ok && k != "" {
			return strings.clone(k, allocator), ""
		}
	}
	if lookup.credentials_path != "" {
		k, wide := read_credentials(lookup.credentials_path, allocator)
		if wide != "" {
			return "", wide
		}
		if k != "" {
			return k, ""
		}
	}

	item := "no rbw item named in \"languagetool.keyItem\""
	if s.key_item != "" {
		item = fmt.tprintf("the rbw item \"%s\" (rbw installed and unlocked)", s.key_item)
	}
	cred := lookup.credentials_path
	if cred == "" {
		cred = "$XDG_CONFIG_HOME/prose/credentials"
	}
	problem = fmt.aprintf(
		"LanguageTool Premium has no key: set " + ENV_API_KEY + ", or use %s, or put the key alone in %s (mode 600)",
		item,
		cred,
		allocator = allocator,
	)
	return
}

// read_credentials reads the key from the credentials file. A file that is
// missing, unreadable or without the line gives "" and no problem. A file
// whose mode is wider than 600 gives a problem naming it; the file is then
// not read at all.
@(private = "file")
read_credentials :: proc(path: string, allocator: runtime.Allocator) -> (key: string, problem: string) {
	info, serr := os.stat(path, allocator)
	if serr != nil {
		return
	}
	mode, size, is_regular := info.mode, info.size, info.type == .Regular
	os.file_info_delete(info, allocator)
	if !is_regular || size > MAX_CREDENTIALS_BYTES {
		return
	}
	when ODIN_OS != .Windows {
		others := os.Permissions{.Read_Group, .Write_Group, .Execute_Group, .Read_Other, .Write_Other, .Execute_Other}
		if mode & others != {} {
			problem = fmt.aprintf(
				"%s has mode %03o, wider than 600, so it is not read: run chmod 600 on it",
				path,
				transmute(u32)mode & 0o777,
				allocator = allocator,
			)
			return
		}
	}
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return
	}
	defer delete(data, allocator)
	return parse_credentials_key(string(data), allocator), ""
}

// parse_credentials_key reads the key from the credentials file's text,
// which holds only the key: the first non-blank line, with surrounding
// whitespace (a CRLF's carriage return too) trimmed. A line in the shape of
// a dotenv line, `LANGUAGETOOL_API_KEY=KEY`, is tolerated and loses its
// prefix. Nothing is executed or expanded. A blank file is no key.
@(private = "file")
parse_credentials_key :: proc(text: string, allocator: runtime.Allocator) -> string {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		value := strings.trim_space(line)
		if value == "" {
			continue
		}
		value = strings.trim_space(strings.trim_prefix(value, ENV_API_KEY + "="))
		return strings.clone(value, allocator) if value != "" else ""
	}
	return ""
}

// How long the rbw calls may take. A hung rbw-agent must not hang a check
// that runs unattended in a hook, and `rbw get` must not sit in a pinentry
// that the vault locking between the two calls would open.
RBW_UNLOCKED_TIMEOUT :: 20 * time.Second
RBW_GET_TIMEOUT :: 30 * time.Second

// rbw_lookup is the real `Key_Lookup.rbw`: it asks the rbw agent for the
// password of the Bitwarden item `item`, by name or id. It runs
// `rbw unlocked` first (at most `RBW_UNLOCKED_TIMEOUT`) and gives up when
// that exits non-zero, then `rbw get` (at most `RBW_GET_TIMEOUT`). A locked
// vault, a missing rbw, a failed `rbw get`, an empty answer and a call that
// runs out of time are all "not available", and nothing ever prompts (the
// child has no stdin). The trailing newline is trimmed. The result is
// allocated with `context.temp_allocator`, as `Key_Lookup` says. An item
// that starts with a dash is refused, so that it cannot be read as an
// option.
rbw_lookup :: proc(item: string) -> (string, bool) {
	if item == "" || item[0] == '-' {
		return "", false
	}
	if _, ok := command_output({"rbw", "unlocked"}, RBW_UNLOCKED_TIMEOUT, false); !ok {
		return "", false
	}
	out, ok := command_output({"rbw", "get", item}, RBW_GET_TIMEOUT, true)
	if !ok {
		return "", false
	}
	defer delete(out)
	key := strings.trim_right(string(out), "\r\n")
	if key == "" {
		return "", false
	}
	return strings.clone(key, context.temp_allocator), true
}

// The most `command_output` keeps of what a command printed.
@(private = "file")
MAX_COMMAND_OUTPUT :: 64 << 10

// command_output runs `command` and reports whether it exited 0 within
// `timeout`. A command that is missing, fails to start, exits non-zero, or is
// still running when the time is up (it is then killed) gives `ok == false`.
// stdin is empty and stderr is dropped, as it may name the item. With
// `capture`, `out` is what the command printed to stdout, up to 64 KiB, read
// without waiting for a grandchild that still holds the pipe; the caller
// deletes it. Without, `out` is nil.
command_output :: proc(
	command: []string,
	timeout: time.Duration,
	capture: bool,
) -> (
	out: []byte,
	ok: bool,
) {
	desc := os.Process_Desc {
		command = command,
	}
	r, w: ^os.File
	if capture {
		perr: os.Error
		r, w, perr = os.pipe()
		if perr != nil {
			return nil, false
		}
		desc.stdout = w
	}
	defer if capture {
		_ = os.close(r)
	}
	proc_, serr := os.process_start(desc)
	if capture {
		// The parent's copy of the write end; with it open the pipe never ends.
		_ = os.close(w)
	}
	if serr != nil {
		return nil, false
	}
	state, werr := os.process_wait(proc_, timeout)
	if werr != nil {
		if werr == .Timeout {
			_ = os.process_kill(proc_)
			_, _ = os.process_wait(proc_, time.Second)
		}
		return nil, false
	}
	if !state.exited || state.exit_code != 0 {
		return nil, false
	}
	if !capture {
		return nil, true
	}

	buf: [dynamic]byte
	chunk: [4096]byte
	for len(buf) < MAX_COMMAND_OUTPUT {
		has, perr := os.pipe_has_data(r)
		if !has || perr != nil {
			break
		}
		n, rerr := os.read(r, chunk[:])
		append(&buf, ..chunk[:n])
		if n == 0 || rerr != nil {
			break
		}
	}
	return buf[:], true
}
