#+build !windows
package prose

import "core:os"
import "core:sys/posix"

// process_may_be_alive tells whether a process with the id `pid` may exist.
// It is false only when the system says there is none (kill with signal 0
// gives ESRCH); a process of another user, which answers EPERM, exists.
process_may_be_alive :: proc(pid: int) -> bool {
	if pid <= 0 {
		return false
	}
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK {
		return true
	}
	return posix.errno() != .ESRCH
}

// sync_directory makes the entries of the directory `dir` durable, so that a
// rename in it survives a crash. The file's own sync does not cover its
// name.
sync_directory :: proc(dir: string) -> os.Error {
	f, err := os.open(dir if dir != "" else ".", {.Read})
	if err != nil {
		return err
	}
	defer os.close(f)
	return os.sync(f)
}
