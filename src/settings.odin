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
// `path` is the file `load_settings` was given, "" when the settings were
// built by hand; the messages of `choose_backend` name it. `backend` is nil
// when the file does not name one, which is not the same as
// `.None`: without a choice in the file the exported variables count.
// `ignore_words` are trimmed, with blank entries dropped. `unknown_keys`
// lists the keys the checker does not know, sorted, nested ones as
// "languagetool.NAME"; `--selftest` notes them, nothing else does.
// `trailing_comma` is where the file has a comma before a closing brace or
// bracket ("line 3, column 9"), which JSON forbids and v0.1.0 took, so it is
// read; "" when there is none. `--selftest` notes it.
Settings :: struct {
	path:             string,
	language_rule:    string,
	ignore_words:     []string,
	backend:          Maybe(Backend_Kind),
	server, username: string,
	key_item:         string,
	unknown_keys:     []string,
	trailing_comma:   string,
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

// The three LanguageTool variables, read once. Empty means unset. A print
// of it shows `<redacted>` for the key too.
// `env_from_os` allocates; free with `env_destroy`.
Env :: struct {
	server, username, api_key: string,
}

// The chosen backend. A print of it, with any verb and at any depth (the
// options and the environment carry one), shows `<redacted>` where the key
// is: see `register_secret_formatters`. `url` is the endpoint with no path (`/v2/check` is for
// the client to add). `username` and `key` are set for `.Premium` only: the
// public server and a self-hosted one get neither. `label` names the
// backend in a message: "free cloud", "premium cloud" or "self-hosted", the
// reference's words. A `.None` backend is all empty. The key lives here and
// nowhere else; nothing in this package prints it, and no print can. Strings are allocated
// with the allocator given to `choose_backend`; free with `backend_destroy`.
Backend :: struct {
	kind:                      Backend_Kind,
	url, username, key, label: string,
	key_from:                  Key_Source,
	// `url` is the `LANGUAGETOOL_SERVER` value with `http://` put in front,
	// because it had no scheme; --selftest says so.
	assumed_http:              bool,
}

// Where a Premium backend's key came from, for `--selftest`. `None` for
// every other backend.
Key_Source :: enum {
	None,
	Env,
	Rbw,
	Credentials,
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

// has_http_scheme tells whether `url` starts with http:// or https://, in
// any case, as libcurl reads the scheme.
has_http_scheme :: proc(url: string) -> bool {
	for scheme in ([?]string{"http://", "https://"}) {
		if len(url) >= len(scheme) && strings.equal_fold(url[:len(scheme)], scheme) {
			return true
		}
	}
	return false
}

// has_scheme tells whether `url` starts with a URL scheme and "://", as
// RFC 3986 spells a scheme: a letter, then letters, digits, `+`, `-` or `.`.
// A "://" further on, in a path or a query string, is not a scheme.
@(private = "file")
has_scheme :: proc(url: string) -> bool {
	for c, i in transmute([]byte)url {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z':
		case '0' ..= '9', '+', '-', '.':
			if i == 0 {
				return false
			}
		case ':':
			return i > 0 && strings.has_prefix(url[i:], "://")
		case:
			return false
		}
	}
	return false
}

// settings_name is how a message names the settings file: the whole path
// when the settings came from a file, else "config.json". The string is
// `s.path` itself, not a copy.
settings_name :: proc(s: Settings) -> string {
	return s.path if s.path != "" else "config.json"
}

// register_secret_formatters makes `fmt` print a `Backend` and an `Env`
// with `<redacted>` in place of the key, so that an accidental `%v` of them,
// or of anything that holds one, cannot leak it. It runs at start, before
// any thread does, and registers what no one has registered.
@(init)
register_secret_formatters :: proc "contextless" () {
	context = runtime.default_context()
	if fmt._user_formatters == nil {
		fmt.set_user_formatters(new(map[typeid]fmt.User_Formatter))
	}
	_ = fmt.register_user_formatter(Backend, redact_backend)
	_ = fmt.register_user_formatter(Env, redact_env)
}

@(private = "file")
REDACTED :: "<redacted>"

@(private = "file")
redact_backend :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	b := (^Backend)(arg.data)^
	if b.key != "" {
		b.key = REDACTED
	}
	// The copy is printed the usual way: the formatter for its type must not
	// run again on it.
	fi.ignore_user_formatters = true
	fmt.fmt_value(fi, b, verb)
	return true
}

@(private = "file")
redact_env :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	e := (^Env)(arg.data)^
	if e.api_key != "" {
		e.api_key = REDACTED
	}
	fi.ignore_user_formatters = true
	fmt.fmt_value(fi, e, verb)
	return true
}

settings_destroy :: proc(s: ^Settings, allocator := context.allocator) {
	delete(s.path, allocator)
	delete(s.language_rule, allocator)
	for w in s.ignore_words {
		delete(w, allocator)
	}
	delete(s.ignore_words, allocator)
	delete(s.server, allocator)
	delete(s.username, allocator)
	delete(s.key_item, allocator)
	delete(s.trailing_comma, allocator)
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
// not start with http:// or https://, in any case), a file bigger than a MiB,
// or something that is not a regular file. A URL is checked only when the
// file's backend is `server`; for any other backend it is not used. Reading it as "no settings" would
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
	} else {
		s.path = strings.clone(path, allocator)
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
	root, kind, detail, comma := parse_json_object(string(data), allocator)
	defer json.destroy_value(root, allocator)
	switch kind {
	case .None:
	case .Syntax:
		err = fail(path, allocator, "is not valid JSON (%s)", detail)
		return
	case .Not_Object:
		err = fail(path, allocator, "must be a JSON object")
		return
	case .Unkeepable_Number:
		// Only setup makes this one: the checker reads no number.
		err = fail(path, allocator, "holds a number that cannot be kept")
		return
	}
	obj := root.(json.Object)
	s, err = read_settings(obj, path, false, allocator)
	if err.problem == "" && comma != "" {
		s.trailing_comma = strings.clone(comma, allocator)
	}
	return
}

// read_settings reads the settings from the parsed object `obj`. `path`
// names where the object came from in a problem: the file's path, or for
// `values_mode` (the values `--setup` is given) the words for their source.
// In `values_mode` a `null` is a key to delete and is skipped, a `server` is
// checked for its scheme whatever the backend, and a server backend without
// a URL is not a problem yet, as the stored file may hold it.
@(private)
read_settings :: proc(
	obj: json.Object,
	path: string,
	values_mode: bool,
	allocator: runtime.Allocator,
) -> (
	s: Settings,
	err: Settings_Error,
) {
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
		if _, is_null := value.(json.Null); is_null && values_mode {
			continue
		}
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
			if !read_languagetool(&s, lt, &unknown, path, values_mode, &err, allocator) {
				return
			}
		case:
			append(&unknown, strings.clone(key, allocator))
		}
	}

	if kind, ok := s.backend.?; ok && kind == .Server && !values_mode {
		if s.server == "" {
			err = fail(path, allocator, `"languagetool.server" is needed when "languagetool.backend" is "server"`)
			return
		}
		if !has_http_scheme(s.server) {
			err = fail(path, allocator, `"languagetool.server" must start with http:// or https://`)
			return
		}
	}
	slice.sort(unknown[:])
	s.unknown_keys = unknown[:]
	return
}

// What is wrong with a text that should be one JSON object.
@(private)
Json_Problem :: enum {
	None,
	Syntax, // not valid JSON; `detail` says what and where
	Not_Object, // valid JSON, but not an object
	Unkeepable_Number, // a number that setup cannot write back as it is (setup.odin)
}

// parse_json_object parses `text` as one JSON object and nothing after it.
// A byte order mark is skipped. A comma before a closing brace or bracket
// is taken, as core:encoding/json takes it and v0.1.0 did, and `comma` says
// where the first one is ("line L, column C", `context.temp_allocator`; ""
// when there is none). A key given twice is refused by the parser, as it
// was in v0.1.0.
//
// On a problem `root` is nil (everything is freed) and `detail` says what
// and where, with the line and the column; it is allocated with
// `context.temp_allocator`. Otherwise `root` is an object, to be freed with
// `json.destroy_value`.
//
// Numbers are parsed as integers where they are integers, as the parser
// reads them.
@(private)
parse_json_object :: proc(text: string, allocator: runtime.Allocator) -> (root: json.Value, kind: Json_Problem, detail, comma: string) {
	body := strings.trim_prefix(text, "\xEF\xBB\xBF")
	// A parser of our own rather than `json.parse`, which stops after the
	// first value and would let anything after it through.
	parser := json.make_parser_from_string(body, .JSON, true, allocator)
	value, jerr := json.parse_value(&parser)
	if jerr != .None {
		// The offending token is the one the parser has just stepped over.
		where_ := position_text(body, parser.prev_token.offset)
		if jerr == .Duplicate_Object_Key {
			return nil, .Syntax, fmt.tprintf("duplicate key, near %s", where_), ""
		}
		return nil, .Syntax, fmt.tprintf("%v at %s", jerr, where_), ""
	}
	if parser.curr_token.kind != .EOF {
		json.destroy_value(value, allocator)
		return nil, .Syntax, fmt.tprintf("text after the end of the value, at %s", position_text(body, parser.curr_token.offset)), ""
	}
	if offset, found := find_trailing_comma(body); found {
		comma = position_text(body, offset)
	}
	if _, is_obj := value.(json.Object); !is_obj {
		json.destroy_value(value, allocator)
		return nil, .Not_Object, "", ""
	}
	return value, .None, "", comma
}

// position_text is "line L, column C" for the byte `offset` of `text`,
// counting from 1; the column counts bytes. It is worked out here because
// the tokenizer's own columns count from 0 on the first line and from 1 on
// the others.
@(private)
position_text :: proc(text: string, offset: int) -> string {
	before := text[:clamp(offset, 0, len(text))]
	line := 1 + strings.count(before, "\n")
	column := len(before) - (strings.last_index_byte(before, '\n') + 1) + 1
	return fmt.tprintf("line %d, column %d", line, column)
}

// find_trailing_comma looks for a comma right before a closing brace or
// bracket. It reads the tokens, so a comma inside a string does not count.
// The text has parsed already.
@(private = "file")
find_trailing_comma :: proc(text: string) -> (offset: int, found: bool) {
	t := json.make_tokenizer(text, .JSON, true)
	prev: json.Token
	for {
		tok, err := json.get_token(&t)
		if err != .None || tok.kind == .EOF {
			return 0, false
		}
		if (tok.kind == .Close_Brace || tok.kind == .Close_Bracket) && prev.kind == .Comma {
			return prev.offset, true
		}
		prev = tok
	}
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
	values_mode: bool,
	err: ^Settings_Error,
	allocator: runtime.Allocator,
) -> bool {
	for key in sorted_keys(lt) {
		value := lt[key]
		if _, is_null := value.(json.Null); is_null && values_mode {
			continue
		}
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
			if values_mode && str != "" && !has_http_scheme(string(str)) {
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
// `Backend` is empty, except that a Premium setup keeps the key it found in
// `key` and its source in `key_from` (both zero when no source gave one), the
// kind staying `.None`. The message never holds the key.
//
// A `env.server` without "://" is read as http, as curl does and as v0.1.0
// did: `localhost:8081` becomes `http://localhost:8081` and `assumed_http` is
// set. Any other scheme, and a scheme-less value in the file, are refused.
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
	kind, _ := backend_kind(s, env)
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
		// Spaces around the variable's value are a quoting slip, not part
		// of the URL.
		env_server := strings.trim_space(env.server)
		url := env_server if env_server != "" else s.server
		if url == "" {
			problem = fmt.aprintf(
				"the server backend needs a URL: set " + ENV_SERVER + " or \"languagetool.server\" in %s",
				settings_name(s),
				allocator = allocator,
			)
			return
		}
		assumed_http := false
		if env_server != "" && !has_scheme(url) {
			// v0.1.0 gave the variable to curl as it was, and curl reads
			// `localhost:8081` as http. Any other scheme is still refused.
			url = strings.concatenate({"http://", url}, context.temp_allocator)
			assumed_http = true
		}
		if !has_http_scheme(url) {
			// Say where the bad value is, so that it is not looked for in the
			// wrong place. The value itself stays out: a URL may hold a login.
			source := ENV_SERVER + " (environment variable)"
			if env_server == "" {
				source = fmt.tprintf("\"languagetool.server\" in %s", settings_name(s))
			}
			problem = fmt.aprintf("%s must start with http:// or https://", source, allocator = allocator)
			return
		}
		b = Backend {
			kind  = .Server,
			url   = strings.clone(url, allocator),
			label = strings.clone("self-hosted", allocator),
			assumed_http = assumed_http,
		}
	case .Premium:
		username := env.username if env.username != "" else s.username
		key, key_from, key_problem := find_key(s, env, key_lookup, allocator)
		defer delete(key_problem, allocator)
		if username == "" || key_problem != "" {
			problem = premium_problem(s, username == "", key_problem, allocator)
			// Nothing to run, but the key found stays, with where it came from:
			// --selftest tells the user which source answered.
			b = Backend {
				key      = key,
				key_from = key_from,
			}
			return
		}
		b = Backend {
			kind     = .Premium,
			url      = strings.clone(PREMIUM_URL, allocator),
			username = strings.clone(username, allocator),
			key      = key,
			label    = strings.clone("premium cloud", allocator),
			key_from = key_from,
		}
	}
	return
}

// backend_kind is the backend `choose_backend` picks, and why: `from` is
// the settings file's path (`settings_name`) when the file names it, the
// variable or variables that chose it, or "the default" for `.None` with
// neither.
backend_kind :: proc(s: Settings, env: Env) -> (kind: Backend_Kind, from: string) {
	if chosen, ok := s.backend.?; ok {
		return chosen, settings_name(s)
	} else if env.server != "" {
		return .Server, ENV_SERVER
	} else if env.api_key != "" && env.username != "" {
		return .Premium, ENV_API_KEY + " and " + ENV_USERNAME
	}
	return .None, "the default"
}

// premium_problem words what keeps Premium from running.
@(private = "file")
premium_problem :: proc(s: Settings, no_username: bool, key_problem: string, allocator: runtime.Allocator) -> string {
	parts: [2]string
	n := 0
	if no_username {
		parts[n] = fmt.tprintf(
			"LanguageTool Premium needs the account: set " + ENV_USERNAME + " or \"languagetool.username\" in %s",
			settings_name(s),
		)
		n += 1
	}
	if key_problem != "" {
		parts[n] = key_problem
		n += 1
	}
	return strings.join(parts[:n], "; ", allocator)
}

// find_key walks the key sources in order. It returns the key (allocated)
// and where it came from, or "" and the problem to show.
@(private = "file")
find_key :: proc(
	s: Settings,
	env: Env,
	lookup: Key_Lookup,
	allocator: runtime.Allocator,
) -> (
	key: string,
	from: Key_Source,
	problem: string,
) {
	if env.api_key != "" {
		return strings.clone(env.api_key, allocator), .Env, ""
	}
	if s.key_item != "" && lookup.rbw != nil {
		if k, ok := lookup.rbw(s.key_item); ok && k != "" {
			return strings.clone(k, allocator), .Rbw, ""
		}
	}
	if lookup.credentials_path != "" {
		k, wide := read_credentials(lookup.credentials_path, allocator)
		if wide != "" {
			return "", .None, wide
		}
		if k != "" {
			return k, .Credentials, ""
		}
	}

	item := fmt.tprintf("an rbw item named in \"languagetool.keyItem\" in %s", settings_name(s))
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
	// One open file for the mode, the size and the contents: a file swapped
	// between a stat and a read would be checked as one and read as another.
	// Not blocking, so that a FIFO in its place is seen as no regular file
	// instead of waiting for a writer.
	flags := os.File_Flags{.Read}
	when ODIN_OS != .Windows {
		flags += {.Non_Blocking}
	}
	f, oerr := os.open(path, flags)
	if oerr != nil {
		return
	}
	defer os.close(f)
	info, serr := os.fstat(f, allocator)
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
	} else {
		// The mode is not checked on Windows, and -vet refuses an unused
		// variable.
		_ = mode
	}
	data, rerr := os.read_entire_file(f, allocator)
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
