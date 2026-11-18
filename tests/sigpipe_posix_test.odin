#+build !windows
package prose_tests

import "core:sys/posix"
import "core:testing"
import prose "../src"

// A reader that closes early must not kill the process: SIGPIPE is ignored,
// and a write to a closed pipe fails instead.
@(test)
sigpipe_is_ignored :: proc(t: ^testing.T) {
	prose.ignore_sigpipe()
	current: posix.sigaction_t
	testing.expect_value(t, posix.sigaction(.SIGPIPE, nil, &current), posix.result.OK)
	testing.expect(t, cast(rawptr)current.sa_handler == posix.SIG_IGN, "SIGPIPE is not ignored")
}
