package prose

import "core:io"

// A finding's severity. Its JSON name is the lower-case word.
Severity :: enum {
	Error,
	Warning,
	Note,
}

// One problem the checker found. `line` and `col` are 1-based, and `col`
// counts code points, not bytes. The checker's passes allocate all four
// strings with the allocator they are given; `findings_destroy` frees them.
Finding :: struct {
	line, col:                              int,
	severity:                               Severity,
	rule, message, excerpt, suggestion:     string,
}

// The findings of one input. `file` is the name as given on the command line.
File_Result :: struct {
	file, note: string,
	findings:   []Finding,
}

// severity_name is the word the reference prints for a severity.
severity_name :: proc(s: Severity) -> string {
	switch s {
	case .Error:
		return "error"
	case .Warning:
		return "warning"
	case .Note:
		return "note"
	}
	return "error"
}

// write_json writes `results` exactly as the reference prints it:
// `print(json.dumps(payload, indent=2, ensure_ascii=False))`. That is two
// spaces of indent, `"key": value`, `[]` for an empty list, `"`, `\` and
// control characters escaped as Python escapes them, and everything else,
// non-ASCII included, written as is.
//
// The output ends with a newline, because the reference's `print` adds one
// and the golden files in `tests/golden` carry it. So the CLI writes the
// result of `write_json` as it is and adds nothing. A write error on `w` is
// not reported; the caller's writer owns that.
write_json :: proc(w: io.Writer, results: []File_Result) {
	if len(results) == 0 {
		_, _ = io.write_string(w, "[]\n")
		return
	}
	_, _ = io.write_string(w, "[\n")
	for r, i in results {
		_, _ = io.write_string(w, "  {\n")
		_, _ = io.write_string(w, "    \"file\": ")
		json_string(w, r.file)
		_, _ = io.write_string(w, ",\n    \"note\": ")
		json_string(w, r.note)
		_, _ = io.write_string(w, ",\n    \"findings\": ")
		if len(r.findings) == 0 {
			_, _ = io.write_string(w, "[]\n")
		} else {
			_, _ = io.write_string(w, "[\n")
			for f, j in r.findings {
				json_finding(w, f)
				_, _ = io.write_string(w, j + 1 < len(r.findings) ? ",\n" : "\n")
			}
			_, _ = io.write_string(w, "    ]\n")
		}
		_, _ = io.write_string(w, i + 1 < len(results) ? "  },\n" : "  }\n")
	}
	_, _ = io.write_string(w, "]\n")
}

@(private = "file")
json_finding :: proc(w: io.Writer, f: Finding) {
	_, _ = io.write_string(w, "      {\n        \"line\": ")
	json_int(w, f.line)
	_, _ = io.write_string(w, ",\n        \"col\": ")
	json_int(w, f.col)
	_, _ = io.write_string(w, ",\n        \"severity\": ")
	json_string(w, severity_name(f.severity))
	_, _ = io.write_string(w, ",\n        \"rule\": ")
	json_string(w, f.rule)
	_, _ = io.write_string(w, ",\n        \"message\": ")
	json_string(w, f.message)
	_, _ = io.write_string(w, ",\n        \"excerpt\": ")
	json_string(w, f.excerpt)
	_, _ = io.write_string(w, ",\n        \"suggestion\": ")
	json_string(w, f.suggestion)
	_, _ = io.write_string(w, "\n      }")
}

@(private = "file")
json_int :: proc(w: io.Writer, n: int) {
	buf: [24]byte
	i := len(buf)
	neg := n < 0
	// Work on the negative so the most negative int does not overflow.
	v := n if neg else -n
	for {
		i -= 1
		buf[i] = byte('0' - v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	_, _ = io.write_string(w, string(buf[i:]))
}

// json_string writes `s` as Python's json.dumps(s, ensure_ascii=False) does:
// `"`, `\`, \n, \r, \t, \b and \f get their short escape, the other control
// characters below 0x20 become \u00XX, and every other byte goes through.
// The LanguageTool pass writes its request's `data` with it too.
@(private)
json_string :: proc(w: io.Writer, s: string) {
	HEX := "0123456789abcdef"
	_ = io.write_byte(w, '"')
	run := 0 // start of the bytes not yet written
	for i in 0 ..< len(s) {
		c := s[i]
		short: string
		switch c {
		case '"':
			short = "\\\""
		case '\\':
			short = "\\\\"
		case '\n':
			short = "\\n"
		case '\r':
			short = "\\r"
		case '\t':
			short = "\\t"
		case '\b':
			short = "\\b"
		case '\f':
			short = "\\f"
		case:
			if c >= 0x20 {
				continue
			}
		}
		_, _ = io.write_string(w, s[run:i])
		run = i + 1
		if short != "" {
			_, _ = io.write_string(w, short)
		} else {
			esc := [6]byte{'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]}
			_, _ = io.write_string(w, string(esc[:]))
		}
	}
	_, _ = io.write_string(w, s[run:])
	_ = io.write_byte(w, '"')
}
