#+build windows
package prose

import "core:os"

// There is no SIGPIPE on Windows: a write to a pipe nobody reads fails with
// an error there.
ignore_sigpipe :: proc() {}

// set_nonblocking does nothing on Windows, where the writer blocks in
// `write_some`; the child's death, or `process_kill`, ends it.
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
