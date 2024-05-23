package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type testState struct {
	contextDir string
	certs      string
}

const certs = "certs"

// Used to set/get state from a context.
type testStateKey struct{}

func getTestState(ctx context.Context) (testState, error) {
	ts, ok := ctx.Value(testStateKey{}).(testState)
	if !ok {
		return testState{}, errors.New("test state not set")
	}
	return ts, ts.mkdirs()
}

func setTestState(ctx context.Context, ts testState) context.Context {
	return context.WithValue(ctx, testStateKey{}, ts)
}

func newTestState(contextDir string) (testState, error) {
	ts := testState{contextDir: contextDir}
	return ts, ts.mkdirs()
}

func (ts *testState) mkdirs() error {
	for _, d := range []string{ts.sourceDir(), ts.artifactsDir(), ts.resultsDir(), ts.restoredDir(), ts.certsDir()} {
		if err := os.MkdirAll(d, 0700); err != nil {
			return fmt.Errorf("newTestState creating %s: %w", d, err)
		}
	}
	return nil
}

func (ts *testState) sourceDir() string {
	return filepath.Join(ts.contextDir, "source")
}

func (ts *testState) artifactsDir() string {
	return filepath.Join(ts.contextDir, "artifacts")
}

func (ts *testState) resultsDir() string {
	return filepath.Join(ts.contextDir, "results")
}

func (ts *testState) restoredDir() string {
	return filepath.Join(ts.contextDir, "restored")
}

func (ts *testState) certsDir() string {
	return filepath.Join(ts.contextDir, "certs")
}

func (ts *testState) domainCert() string {
	return fmt.Sprintf("%s/domain.crt", ts.certsDir())
}

func (ts *testState) domainKey() string {
	return fmt.Sprintf("%s/domain.key", ts.certsDir())
}

func (ts *testState) forMount(mountDir string) testState {
	// Do not create the required directories because this is meant to represent the directory
	// structure within a container.
	return testState{contextDir: mountDir}
}

func (ts *testState) teardown() error {
	var err error

	if ts.contextDir != "" {
		err = os.RemoveAll(ts.contextDir)
	}

	return err
}
