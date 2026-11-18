#+build windows
package prose

import "core:os"

// There is no SIGPIPE on Windows: a write to a pipe nobody reads fails with
// an error there.
ignore_sigpipe :: proc() {}

// set_nonblocking does nothing on Windows, where the writer blocks in
// `write_some` until the child reads or the pipe breaks. Killing the child
// breaks it only when no other process holds the read end: a wrapper's own
// child that inherited it keeps the write waiting for ever, and the writer
// never sees `stop`. That matters only when the input exceeds the pipe
// buffer: a smaller one goes in at once. Then `command_with_input` is not
// bounded here, and the hunspell pass does not run on Windows.
set_nonblocking :: proc(f: ^os.File) {}

Write_Result :: enum {
	Ok,
	Full,
	Gone,
}

// write_some writes all of `data`, waiting for room.
write_some :: proc(f: ^os.File, data: []byte) -> (n: int, res: Write_Result) {
	got, err := os.write(f, data)
	if err != nil {
		return int(got), .Gone
	}
	return int(got), .Ok
}
