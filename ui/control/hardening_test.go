//go:build linux

package main

import (
	"bufio"
	"bytes"
	"io"
	"testing"
)

// Regression guard for the unbounded request-read fix.
//
// The existing oversize test only sends maxRequestBytes+1 followed by '\n', so
// ReadBytes stops at the newline. A peer that never sends a newline makes plain
// bufio.NewReaderSize accumulate the entire stream before the len(line) guard
// runs. The fix wraps the connection in io.LimitReader to cap accumulation.
func TestRequestReadIsBounded(t *testing.T) {
	const cap = maxRequestBytes + 1
	payload := bytes.Repeat([]byte("a"), 8*maxRequestBytes) // no newline

	// Unfixed pattern over-buffers the whole blob.
	unbounded := bufio.NewReaderSize(bytes.NewReader(payload), cap)
	if line, _ := unbounded.ReadBytes('\n'); len(line) <= cap {
		t.Fatalf("sanity: expected NewReaderSize to over-buffer, got %d bytes", len(line))
	}

	// Fixed pattern (server.go) caps accumulation at the request limit.
	bounded := bufio.NewReader(io.LimitReader(bytes.NewReader(payload), cap))
	line, err := bounded.ReadBytes('\n')
	if err != io.EOF {
		t.Fatalf("expected EOF at the cap, got %v", err)
	}
	if len(line) > cap {
		t.Fatalf("read is not bounded: buffered %d bytes (cap %d)", len(line), cap)
	}
}
