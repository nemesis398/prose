#+build !windows
package prose

import "core:sys/posix"

// ignore_sigpipe turns the broken-pipe signal into an error on `write`, so a
// child that dies before it has read its input cannot kill this process.
// The child inherits the setting, which does it no harm.
ignore_sigpipe :: proc() {
	_ = posix.sigignore(.SIGPIPE)
}
