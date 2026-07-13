//go:build linux

package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestExecRunnerCapturesSuccessfulStderr(t *testing.T) {
	output, err := (execRunner{timeout: 5 * time.Second}).Run(
		[]string{os.Args[0], "-test.run=^TestExecRunnerStderrHelper$", "--", "emit-ocserv-version"},
		"",
	)
	if err != nil {
		t.Fatal(err)
	}
	if output.stdout != "" || !strings.HasPrefix(output.stderr, "ocserv 1.5.0\n") {
		t.Fatalf("unexpected command output: %#v", output)
	}
}

func TestExecRunnerStderrHelper(t *testing.T) {
	if len(os.Args) == 0 || os.Args[len(os.Args)-1] != "emit-ocserv-version" {
		return
	}
	_, _ = os.Stderr.WriteString("ocserv 1.5.0\n\nCompiled with: seccomp\n")
	os.Exit(0)
}
