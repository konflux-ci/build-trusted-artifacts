package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cucumber/godog"
	"github.com/google/go-cmp/cmp"
)

func TestFeatures(t *testing.T) {
	suite := godog.TestSuite{
		ScenarioInitializer:  initializeScenario,
		TestSuiteInitializer: initializeTestSuite,
		Options: &godog.Options{
			Format:   "pretty",
			Paths:    []string{"features"},
			TestingT: t,
		},
	}

	if suite.Run() != 0 {
		t.Fatal("non-zero status returned, failed to run feature tests")
	}
}

func initializeScenario(sc *godog.ScenarioContext) {
	sc.Before(setupScenario)
	sc.After(teardownScenario)

	sc.Step(`^a source file "([^"]*)":$`, createSourceFile)
	sc.Step(`^artifact is created for file "([^"]*)"$`, createArtifactForFile)
	sc.Step(`^artifact is extracted for file "([^"]*)"$`, useArtifactForFile)
	sc.Step(`^the restored file "([^"]*)" should match its source$`, restoredFileShouldMatchSource)
}

func initializeTestSuite(suite *godog.TestSuiteContext) {
	ctx := context.Background()
	suite.BeforeSuite(func() {
		if err := buildContainerImage(ctx); err != nil {
			panic(err)
		}
	})
}

func setupScenario(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
	tempDir, err := os.MkdirTemp("", "ec-policies-")
	if err != nil {
		return ctx, fmt.Errorf("setting up scenario: %w", err)
	}

	ts, err := newTestState(tempDir)
	if err != nil {
		return ctx, fmt.Errorf("setting up scenario: %w", err)
	}

	return setTestState(ctx, ts), nil
}

func teardownScenario(ctx context.Context, sc *godog.Scenario, _ error) (context.Context, error) {
	// Purposely ignore errors here to prevent a teardown error to mask a test error.
	ts, _ := getTestState(ctx)
	_ = ts.teardown()
	return ctx, nil
}

func createSourceFile(ctx context.Context, fname string, content *godog.DocString) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createSourceTextFile get test state: %w", err)
	}

	fpath := filepath.Join(ts.sourceDir(), fname)
	return ctx, os.WriteFile(fpath, []byte(content.Content), 0400)
}

func createArtifactForFile(ctx context.Context, fname string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createArtifactForFile get test state: %w", err)
	}

	// Set up the file paths as they will be seen within the container.
	mountedTS := ts.forMount("/data")
	sourceFile := filepath.Join(mountedTS.sourceDir(), fname)
	resultFile := filepath.Join(mountedTS.resultsDir(), fname)
	storePath := mountedTS.artifactsDir()

	binds := []string{
		// TODO: The ":Z" option is required on Linux systems because of to selinux. This might not
		// work on a mac, for example.
		fmt.Sprintf("%s:%s:Z", ts.contextDir, mountedTS.contextDir),
	}

	cmd := []string{
		"create",
		"--store",
		storePath,
		fmt.Sprintf("%s=%s", resultFile, sourceFile),
	}

	if err := runContainer(ctx, cmd, binds); err != nil {
		return ctx, fmt.Errorf("creating artifact: %w", err)
	}

	return ctx, nil
}

func useArtifactForFile(ctx context.Context, fname string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("useArtifactForFile get test state: %w", err)
	}

	resultInfo, err := os.ReadFile(filepath.Join(ts.resultsDir(), fname))
	if err != nil {
		return ctx, fmt.Errorf("reading result file: %w", err)
	}

	// Set up the file paths as they will be seen within the container.
	mountedTS := ts.forMount("/data")
	storePath := mountedTS.artifactsDir()
	restoredPath := mountedTS.restoredDir()

	binds := []string{
		// TODO: The ":Z" option is required on Linux systems because of to selinux. This might not
		// work on a mac, for example.
		fmt.Sprintf("%s:%s:Z", ts.contextDir, mountedTS.contextDir),
	}

	cmd := []string{
		"use",
		"--store",
		storePath,
		fmt.Sprintf("%s=%s", resultInfo, restoredPath),
	}

	if err := runContainer(ctx, cmd, binds); err != nil {
		return ctx, fmt.Errorf("creating artifact: %w", err)
	}

	return ctx, nil
}

func restoredFileShouldMatchSource(ctx context.Context, fname string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("useArtifactForFile get test state: %w", err)
	}

	// To make diffs easier to read, convert []byte to string and split content by line.
	toStringList := cmp.Transformer("toStringList", func(in []byte) []string {
		return strings.Split(string(in), "\n")
	})

	sourceContent, err := os.ReadFile(filepath.Join(ts.sourceDir(), fname))
	if err != nil {
		return ctx, fmt.Errorf("reading source file: %w", err)
	}

	restoredContent, err := os.ReadFile(filepath.Join(ts.restoredDir(), fname))
	if err != nil {
		return ctx, fmt.Errorf("reading restored file: %w", err)
	}

	// When comparing for equality, don't "prettify" the file to ensure the restored content is an
	// identical match to the source. Only use the `toList` transformer when displaying the diff to
	// help debug issues.
	if !cmp.Equal(sourceContent, restoredContent) {
		return ctx, fmt.Errorf("source file does not match restored file: \n%s",
			cmp.Diff(sourceContent, restoredContent, toStringList))
	}

	return ctx, nil
}
