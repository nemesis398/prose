package prose_tests

import "base:runtime"
import "core:mem"
import "core:net"
import "core:testing"
import "core:thread"
import "core:time"

// An allocator whose every resize moves the block and fills the old one with
// 0xAA before freeing it, so a pointer into a block that a growing array has
// left reads as garbage on every run, not only when the heap happens to
// reuse the memory.
poisoning_allocator :: proc() -> runtime.Allocator {
	return runtime.Allocator{procedure = poisoning_allocator_proc, data = nil}
}

poisoning_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	heap := runtime.heap_allocator()
	#partial switch mode {
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			return heap.procedure(heap.data, .Alloc, size, alignment, nil, 0, loc)
		}
		fresh, err := heap.procedure(heap.data, .Alloc, size, alignment, nil, 0, loc)
		if err != nil {
			return nil, err
		}
		mem.copy(raw_data(fresh), old_memory, min(size, old_size))
		mem.set(old_memory, 0xAA, old_size)
		heap.procedure(heap.data, .Free, 0, 0, old_memory, old_size, loc)
		return fresh, nil
	case .Free:
		if old_size > 0 {
			mem.set(old_memory, 0xAA, old_size)
		}
	}
	return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private = "file")
Slow_Sender :: struct {
	port: int,
	body: []byte,
}

// Sends the head, waits, then the body in small chunks, so the reader sees
// the body arrive in several receives.
@(private = "file")
slow_send :: proc(th: ^thread.Thread) {
	s := (^Slow_Sender)(th.data)
	sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = s.port})
	if err != nil {
		return
	}
	defer net.close(sock)
	head := "POST /v2/check HTTP/1.1\r\nHost: x\r\nContent-Length: 300000\r\n\r\n"
	net.send_tcp(sock, transmute([]byte)head)
	time.sleep(50 * time.Millisecond)
	for off := 0; off < len(s.body); off += 20000 {
		net.send_tcp(sock, s.body[off:min(off + 20000, len(s.body))])
		time.sleep(time.Millisecond)
	}
}

// The method and the path are read from the buffer that the body then grows.
// The buffer may move while it grows; a request read in several receives must
// still give "POST" and "/v2/check".
@(test)
a_big_body_in_several_receives_keeps_the_method_and_the_path :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if !testing.expect(t, lerr == nil) {
		return
	}
	defer net.close(listener)
	ep, _ := net.bound_endpoint(listener)

	body := make([]byte, 300000)
	defer delete(body)
	for &b, i in body {
		b = byte('a' + i % 26)
	}
	sender := Slow_Sender{port = ep.port, body = body}
	th := thread.create(slow_send)
	th.data = &sender
	thread.start(th)
	defer {
		thread.join(th)
		thread.destroy(th)
	}

	client, _, aerr := net.accept_tcp(listener)
	if !testing.expect(t, aerr == nil) {
		return
	}
	defer net.close(client)
	net.set_option(client, .Receive_Timeout, 5 * time.Second)

	raw := make([dynamic]byte, poisoning_allocator())
	defer delete(raw)
	req, ok := read_request(client, &raw)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, req.method, "POST")
	testing.expect_value(t, req.path, "/v2/check")
	testing.expect_value(t, len(req.body), len(body))
	testing.expect(t, req.body == string(body), "the body is not what was sent")
}
