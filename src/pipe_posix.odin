#+build !windows
package prose

import "core:os"
import "core:sys/posix"

// ignore_sigpipe turns the broken-pipe signal into an error on `write`, so a
// child that dies before it has read its input cannot kill this process.
// The child inherits the setting: a program of ours that writes into a closed
// pipe (hunspell, rbw) gets EPIPE instead of dying, which they report.
ignore_sigpipe :: proc() {
	// The previous handler comes back, or SIG_ERR; neither matters here.
	_ = posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

// set_nonblocking makes a write to `f` return at once instead of waiting
// for room. Only this end of the pipe is affected, not the child's.
set_nonblocking :: proc(f: ^os.File) {
	fd := posix.FD(os.fd(f))
	flags := posix.fcntl(fd, .GETFL)
	if flags >= 0 {
		_ = posix.fcntl(fd, .SETFL, flags | transmute(i32)posix.O_Flags{.NONBLOCK})
	}
}

Write_Result :: enum {
	Ok, // some bytes went in, or the call was interrupted
	Full, // the pipe has no room now; try again later
	Gone, // nobody reads the pipe any more, or it failed
}

// write_some writes as much of `data` as a non-blocking pipe takes and says
// how many bytes that was.
write_some :: proc(f: ^os.File, data: []byte) -> (n: int, res: Write_Result) {
	got := posix.write(posix.FD(os.fd(f)), raw_data(data), len(data))
	if got >= 0 {
		return int(got), .Ok
	}
	#partial switch posix.errno() {
	case .EAGAIN:
		// EWOULDBLOCK is the same value on every supported system.
		return 0, .Full
	case .EINTR:
		return 0, .Ok
	}
	return 0, .Gone
}
