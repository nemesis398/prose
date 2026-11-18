package prose

import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// The most `command_output` keeps of what a command printed.
@(private = "file")
MAX_COMMAND_OUTPUT :: 64 << 10

// command_output runs `command` and reports whether it exited 0 within
// `timeout`. A command that is missing, fails to start, exits non-zero, or is
// still running when the time is up (it is then killed) gives `ok == false`.
// stdin is empty and stderr is dropped, as it may name the item. With
// `capture`, `out` is what the command printed to stdout, the first 64 KiB of
// it, read without waiting for a grandchild that still holds the pipe; the
// caller deletes it. Without, `out` is nil.
//
// The output is read while the command runs, not after it has exited: a
// command that prints more than a pipe holds blocks on its write until
// someone reads, and would never exit. What is past the cap is read and
// dropped, so that such a command still finishes.
//
// Only the process is killed on a timeout, not its process group, and a
// grandchild outlives it. That is deliberate: `rbw` starts `rbw-agent` as
// its own child, and the agent must survive a lookup that ran out of time.
command_output :: proc(
	command: []string,
	timeout: time.Duration,
	capture: bool,
) -> (
	out: []byte,
	ok: bool,
) {
	desc := os.Process_Desc {
		command = command,
	}
	r, w: ^os.File
	if capture {
		perr: os.Error
		r, w, perr = os.pipe()
		if perr != nil {
			return nil, false
		}
		desc.stdout = w
	}
	defer if capture {
		_ = os.close(r)
	}
	proc_, serr := os.process_start(desc)
	if capture {
		// The parent's copy of the write end; with it open the pipe never ends.
		_ = os.close(w)
	}
	if serr != nil {
		return nil, false
	}
	kill :: proc(proc_: os.Process) {
		_ = os.process_kill(proc_)
		_, _ = os.process_wait(proc_, time.Second)
	}

	if !capture {
		state, werr := os.process_wait(proc_, timeout)
		if werr != nil {
			if werr == .Timeout {
				kill(proc_)
			}
			return nil, false
		}
		return nil, state.exited && state.exit_code == 0
	}

	buf: [dynamic]byte
	chunk: [4096]byte
	deadline := time.time_add(time.now(), timeout)
	state: os.Process_State
	exited := false
	for {
		// What is in the pipe now. Looked at before the process, and once more
		// after it is seen to have exited: what it wrote before exiting is in
		// the pipe by then.
		for {
			has, perr := os.pipe_has_data(r)
			if !has || perr != nil {
				break
			}
			n, rerr := os.read(r, chunk[:])
			if n > 0 {
				room := MAX_COMMAND_OUTPUT - len(buf)
				append(&buf, ..chunk[:min(n, max(room, 0))])
			}
			if n <= 0 || rerr != nil {
				break
			}
		}
		if exited {
			break
		}
		st, werr := os.process_wait(proc_, 0)
		if werr == nil && st.exited {
			state, exited = st, true
			continue
		}
		if time.diff(time.now(), deadline) <= 0 {
			kill(proc_)
			delete(buf)
			return nil, false
		}
		time.sleep(time.Millisecond)
	}
	if state.exit_code != 0 {
		delete(buf)
		return nil, false
	}
	return buf[:], true
}

// Who feeds a child's stdin, and what: the writer thread's work order.
// `stop` is set by the reader, with `sync.atomic_store`, when the writer must
// give up.
@(private = "file")
Stdin_Feed :: struct {
	w:    ^os.File,
	data: []byte,
	stop: bool,
}

// feed_stdin writes all of the order's data into the pipe and closes it, so
// the child sees the end of its input. It stops at the first write error
// (the child has gone away) and when `stop` is set. On POSIX the pipe is
// non-blocking and a full pipe is retried every millisecond, so the writer
// never sits in a write that nothing will end. On Windows a write waits for
// room, and a writer stuck in it never looks at `stop` (see
// pipe_windows.odin). It owns `w` and closes it.
@(private = "file")
feed_stdin :: proc(t: ^thread.Thread) {
	feed := (^Stdin_Feed)(t.data)
	data := feed.data
	for len(data) > 0 && !sync.atomic_load(&feed.stop) {
		n, res := write_some(feed.w, data)
		if res == .Gone {
			break
		}
		if res == .Full {
			time.sleep(time.Millisecond)
		}
		data = data[n:]
	}
	_ = os.close(feed.w)
}

// command_with_input runs `command`, writes `input` into its stdin and
// returns what it printed to stdout, up to `max_output` bytes. It reports
// false when the command is missing or fails to start, when it is still
// running after `timeout` (it is then killed and reaped), or when it prints
// more than `max_output`. It does not look at the exit code: what a command
// printed before it failed counts, as the reference's `hunspell` run counts
// it. stderr is dropped. The result is allocated with `allocator`; the caller
// deletes it.
//
// The input goes in from a thread of its own while this one reads the
// output with a deadline, because a command that answers as it reads, as
// hunspell does, blocks on a full output pipe while we block on a full input
// pipe if one thread does both. The writer ends when the command ends early
// (its write fails with a broken pipe), when it has written everything, and
// otherwise when this procedure tells it to stop, which it does before it
// returns. That last is what bounds the run when the command is a wrapper
// whose own child holds the pipes: killing the wrapper breaks nothing.
//
// On POSIX only. On Windows the writer blocks in its write and never sees
// the order to stop, so for such a wrapper this procedure waits in the
// join for as long as the wrapper's child lives, whatever `timeout` says.
// The timeout bounds the run there only for a command that holds its pipes
// itself. That is why the hunspell pass does not run on Windows.
command_with_input :: proc(
	command: []string,
	input: []byte,
	timeout: time.Duration,
	max_output: int,
	allocator := context.allocator,
) -> (
	out: []byte,
	ok: bool,
) {
	in_r, in_w, e1 := os.pipe()
	if e1 != nil {
		return nil, false
	}
	out_r, out_w, e2 := os.pipe()
	if e2 != nil {
		_ = os.close(in_r)
		_ = os.close(in_w)
		return nil, false
	}
	ignore_sigpipe()
	proc_, serr := os.process_start(os.Process_Desc{command = command, stdin = in_r, stdout = out_w})
	// The parent's copies of the child's ends; with them open neither pipe
	// ever ends.
	_ = os.close(in_r)
	_ = os.close(out_w)
	if serr != nil {
		_ = os.close(in_w)
		_ = os.close(out_r)
		return nil, false
	}

	set_nonblocking(in_w)
	feed := Stdin_Feed {
		w    = in_w,
		data = input,
	}
	writer := thread.create(feed_stdin)
	if writer == nil {
		// No thread to feed the child: no run. The child is ended before the
		// pipes close, so that it does not linger on a stdin that never ends.
		_ = os.process_kill(proc_)
		_, _ = os.process_wait(proc_, time.Second)
		_ = os.close(in_w)
		_ = os.close(out_r)
		return nil, false
	}
	writer.data = &feed
	writer.init_context = context
	thread.start(writer)
	done := false
	defer {
		// Whatever happened, end the writer before the join. Killing the child
		// does not do it: a wrapper script's own child may hold the read end
		// of the pipe, so the pipe never breaks, and the writer is told to stop
		// instead (which a writer blocked on Windows does not see). The output
		// pipe closes first so a child blocked on it can go.
		if !done {
			_ = os.process_kill(proc_)
			_, _ = os.process_wait(proc_, time.Second)
		}
		sync.atomic_store(&feed.stop, true)
		_ = os.close(out_r)
		thread.join(writer)
		thread.destroy(writer)
	}

	buf := make([dynamic]byte, allocator)
	chunk: [4096]byte
	deadline := time.time_add(time.now(), timeout)
	exited := false
	for {
		if time.diff(time.now(), deadline) <= 0 {
			delete(buf)
			return nil, false
		}
		// Look at the process before the pipe: data written before it exited
		// is in the pipe when it is seen to have exited.
		if !exited {
			st, werr := os.process_wait(proc_, 0)
			exited = werr == nil && st.exited
			done = exited
		}
		has, perr := os.pipe_has_data(out_r)
		if perr != nil {
			break // the write end is closed: the end of the output
		}
		if !has {
			if exited {
				break // nothing more is coming, a grandchild may hold the pipe
			}
			time.sleep(time.Millisecond)
			continue
		}
		n, rerr := os.read(out_r, chunk[:])
		if n > 0 {
			if len(buf) + n > max_output {
				delete(buf)
				return nil, false
			}
			append(&buf, ..chunk[:n])
		}
		if n <= 0 || rerr != nil {
			break
		}
	}

	if !exited {
		// The output ended; the exit follows at once, or it is killed.
		_, werr := os.process_wait(proc_, max(time.diff(time.now(), deadline), 0))
		if werr != nil {
			delete(buf)
			return nil, false
		}
		done = true
	}
	return buf[:], true
}
