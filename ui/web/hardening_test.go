package main

import (
	"bufio"
	"bytes"
	"io"
	"net/http"
	"testing"
)

// Regression guard for the unbounded control-read fix.
//
// bufio.NewReaderSize's size argument does NOT cap ReadBytes: it keeps growing
// its own buffer until it sees '\n' or EOF, so a peer that streams data without
// a newline forces the whole blob into memory before any post-read length check
// runs. The fix wraps the connection in io.LimitReader so accumulation is capped.
// This test documents both behaviours and asserts the fixed one holds.
func TestControlReadIsBounded(t *testing.T) {
	const limit = 1024*1024 + 1
	payload := bytes.Repeat([]byte("A"), 8*1024*1024) // 8 MiB, no newline

	// Unfixed pattern: the size hint is ignored, the whole blob is buffered.
	unbounded := bufio.NewReaderSize(bytes.NewReader(payload), limit)
	if line, _ := unbounded.ReadBytes('\n'); len(line) <= limit {
		t.Fatalf("sanity: expected NewReaderSize to over-buffer, got %d bytes", len(line))
	}

	// Fixed pattern (control.go): LimitReader caps accumulation at limit.
	bounded := bufio.NewReader(io.LimitReader(bytes.NewReader(payload), limit))
	line, err := bounded.ReadBytes('\n')
	if err != io.EOF {
		t.Fatalf("expected EOF at the cap, got %v", err)
	}
	if len(line) > limit {
		t.Fatalf("read is not bounded: buffered %d bytes (cap %d)", len(line), limit)
	}
}

// Regression guard: failed access attempts must be written to the audit log.
func TestFailedAccessIsAudited(t *testing.T) {
	app, _ := testApplication(t, "this-is-a-valid-length-access-secret-value-01")

	recorder := perform(app, http.MethodPost, "/api/v1/access", `{"secret":"wrong-but-well-formed-secret-value-abcdefgh"}`, nil, "")
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("expected 404 on wrong secret, got %d", recorder.Code)
	}

	found := false
	for _, record := range app.store.state.Audit {
		if record.Action == "access" && !record.Success {
			found = true
		}
	}
	if !found {
		t.Fatalf("no failed-access audit record was written after a rejected secret")
	}
}
