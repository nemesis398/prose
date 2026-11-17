#+build windows
package prose

// ignore_sigpipe does nothing on Windows, which has no such signal: a write
// to a pipe nobody reads fails with an error there.
ignore_sigpipe :: proc() {}
