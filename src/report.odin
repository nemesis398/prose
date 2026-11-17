package prose

import "core:fmt"
import "core:io"
import "core:unicode/utf8"

// The text report, a port of the reference's `report` and `paint`.

// The reference's ANSI codes, by what they mark.
Paint :: enum {
	Error,
	Warning,
	Note,
	Dim,
	Bold,
}

@(private = "file")
PAINT_CODES := [Paint]string {
	.Error   = "\x1b[31m",
	.Warning = "\x1b[33m",
	.Note    = "\x1b[36m",
	.Dim     = "\x1b[2m",
	.Bold    = "\x1b[1m",
}

@(private = "file")
PAINT_OFF :: "\x1b[0m"

// paint writes `text`, wrapped in the code for `p` when `color` is set.
paint :: proc(w: io.Writer, text: string, p: Paint, color: bool) {
	if color {
		_, _ = io.write_string(w, PAINT_CODES[p])
	}
	_, _ = io.write_string(w, text)
	if color {
		_, _ = io.write_string(w, PAINT_OFF)
	}
}

// report_text writes the findings of one file as the reference's `report`
// prints them, and returns the number of errors and of warnings:
//
//	PATH
//	  NOTE
//	       LINE:COL  SEVERITY  RULE                   MESSAGE
//	                 EXCERPT
//	                 → SUGGESTION
//	  E error(s), W warning(s), N note(s)
//
// followed by a blank line. "clean" stands in for the findings when there
// are none; the excerpt and suggestion lines appear only when they are not
// empty, and so does the note line. The location is right-aligned in 9
// columns, the severity left-aligned in 7 and the rule in 22, counted in
// code points as Python counts them. With `color` the parts are painted as
// the reference paints them; the caller decides, from whether stdout is a
// terminal and NO_COLOR is unset.
report_text :: proc(
	w: io.Writer,
	path: string,
	findings: []Finding,
	note: string,
	color: bool,
) -> (
	errors, warnings: int,
) {
	for f in findings {
		switch f.severity {
		case .Error:
			errors += 1
		case .Warning:
			warnings += 1
		case .Note:
		}
	}
	paint(w, path, .Bold, color)
	_, _ = io.write_string(w, "\n")
	if note != "" {
		_, _ = io.write_string(w, "  ")
		paint(w, note, .Dim, color)
		_, _ = io.write_string(w, "\n")
	}
	if len(findings) == 0 {
		_, _ = io.write_string(w, "  ")
		paint(w, "clean", .Note, color)
		_, _ = io.write_string(w, "\n")
	}
	for f in findings {
		loc_buf: [48]byte
		loc := fmt.bprintf(loc_buf[:], "%d:%d", f.line, f.col)
		_, _ = io.write_string(w, "  ")
		pad_left(w, loc, 9)
		_, _ = io.write_string(w, "  ")
		sev := severity_name(f.severity)
		sev_buf: [16]byte
		paint(w, pad_right_into(sev_buf[:], sev, 7), severity_paint(f.severity), color)
		_, _ = io.write_string(w, "  ")
		_, _ = io.write_string(w, f.rule)
		pad(w, 22 - utf8.rune_count_in_string(f.rule))
		_, _ = io.write_string(w, " ")
		_, _ = io.write_string(w, f.message)
		_, _ = io.write_string(w, "\n")
		if f.excerpt != "" {
			_, _ = io.write_string(w, "             ") // 2 + 9 + 2
			paint(w, f.excerpt, .Dim, color)
			_, _ = io.write_string(w, "\n")
		}
		if f.suggestion != "" {
			_, _ = io.write_string(w, "             ")
			if color {
				_, _ = io.write_string(w, PAINT_CODES[.Dim])
			}
			_, _ = io.write_string(w, "→ ")
			_, _ = io.write_string(w, f.suggestion)
			if color {
				_, _ = io.write_string(w, PAINT_OFF)
			}
			_, _ = io.write_string(w, "\n")
		}
	}
	fmt.wprintf(w, "  %d error(s), %d warning(s), %d note(s)\n\n", errors, warnings, len(findings) - errors - warnings)
	return
}

@(private = "file")
severity_paint :: proc(s: Severity) -> Paint {
	switch s {
	case .Error:
		return .Error
	case .Warning:
		return .Warning
	case .Note:
		return .Note
	}
	return .Error
}

// pad writes `n` spaces; nothing for `n` below 1.
@(private = "file")
pad :: proc(w: io.Writer, n: int) {
	for _ in 0 ..< n {
		_ = io.write_byte(w, ' ')
	}
}

// pad_left writes `s` right-aligned in `width` code points, as Python's
// `f"{s:>width}"`; a longer `s` is written as it is.
@(private = "file")
pad_left :: proc(w: io.Writer, s: string, width: int) {
	pad(w, width - utf8.rune_count_in_string(s))
	_, _ = io.write_string(w, s)
}

// pad_right_into is Python's `s.ljust(width)` for an ASCII `s` that fits
// `buf`.
@(private = "file")
pad_right_into :: proc(buf: []byte, s: string, width: int) -> string {
	n := copy(buf, s)
	for n < width && n < len(buf) {
		buf[n] = ' '
		n += 1
	}
	return string(buf[:n])
}
