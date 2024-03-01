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

const emptyFilePath = "sha256-85cea451eec057fa7e734548ca3ba6d779ed5836a3f9de14b8394575ef0d7d8e.tar.gz"

func TestFeatures(t *testing.T) {
	suite := godog.TestSuite{
		ScenarioInitializer:  initializeScenario,
		TestSuiteInitializer: initializeTestSuite,
		Options: &godog.Options{
			Format:   "pretty",
			Paths:    []string{"features"},
			Strict:   true,
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
	sc.Step(`^artifact "([^"]*)" is created for (?:file|path) "([^"]*)"$`, createArtifact)
	sc.Step(`^artifact "([^"]*)" is extracted for file "([^"]*)"$`, useArtifactForFile)
	sc.Step(`^the restored file "([^"]*)" should match its source$`, restoredFileShouldMatchSource)
	sc.Step(`^the created archive is empty$`, createdArchiveIsEmpty)
	sc.Step(`^files:$`, createFiles)
	sc.Step(`^artifact "([^"]*)" contains:$`, artifactContains)
	sc.Step(`^artifact "([^"]*)" is used$`, artifactIsUsed)
	sc.Step(`^running in debug mode$`, runningInDebugMode)
	sc.Step(`^the logs contain words: "([^"]*)"$`, theLogsContainWords)
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

func createArtifact(ctx context.Context, result string, path string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createArtifact get test state: %w", err)
	}

	// Set up the file paths as they will be seen within the container.
	mountedTS := ts.forMount("/data")
	sourceFile := filepath.Join(mountedTS.sourceDir(), path)
	resultFile := filepath.Join(mountedTS.resultsDir(), result)
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

	if ctx, err = runContainer(ctx, cmd, binds); err != nil {
		return ctx, fmt.Errorf("creating artifact: %w", err)
	}

	return ctx, nil
}

func useArtifactForFile(ctx context.Context, result, path string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("useArtifactForFile get test state: %w", err)
	}

	resultInfo, err := os.ReadFile(filepath.Join(ts.resultsDir(), result))
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

	if ctx, err = runContainer(ctx, cmd, binds); err != nil {
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

func createdArchiveIsEmpty(ctx context.Context) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createdArchiveIsEmpty no test state: %w", err)
	}

	if _, err := os.Stat(filepath.Join(ts.artifactsDir(), emptyFilePath)); err != nil {
		return ctx, fmt.Errorf("the empty archive is not present: %v", err)
	}

	return ctx, nil
}

func createFiles(ctx context.Context, files *godog.Table) (context.Context, error) {
	if files == nil {
		return ctx, nil
	}
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createFiles no test state: %w", err)
	}

	sourceDir := ts.sourceDir()

	for _, row := range files.Rows[1:] {
		path := row.Cells[0].Value
		content := row.Cells[1].Value

		fpath := filepath.Join(sourceDir, path)

		if err := os.MkdirAll(filepath.Dir(fpath), 0700); err != nil {
			return ctx, err
		}

		if err := os.WriteFile(fpath, []byte(content), 0400); err != nil {
			return ctx, err
		}
	}

	return ctx, nil
}

func artifactContains(ctx context.Context, result string, files *godog.Table) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("artifactContains no test state: %w", err)
	}

	archiveUri, err := os.ReadFile(filepath.Join(ts.resultsDir(), result))
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
		fmt.Sprintf("%s=%s", archiveUri, restoredPath),
	}

	if ctx, err = runContainer(ctx, cmd, binds); err != nil {
		return ctx, fmt.Errorf("using artifact: %w", err)
	}

	restoredDir := ts.restoredDir()

	for _, row := range files.Rows[1:] {
		path := row.Cells[0].Value
		expected := row.Cells[1].Value

		fpath := filepath.Join(restoredDir, path)

		bytes, err := os.ReadFile(fpath)
		if err != nil {
			return ctx, err
		}

		got := string(bytes)
		if !cmp.Equal(expected, got) {
			return ctx, fmt.Errorf("file %q does not match restored file: \n%s", path, cmp.Diff(expected, got))
		}
	}

	return ctx, nil
}

func artifactIsUsed(ctx context.Context, name string) (context.Context, error) {
	return useArtifactForFile(ctx, name, "")
}

func runningInDebugMode(ctx context.Context) (context.Context, error) {
	return context.WithValue(ctx, environmentKey, []string{"DEBUG=1"}), nil
}

func theLogsContainWords(ctx context.Context, expected string) (context.Context, error) {
	logs := ctx.Value(logsKey).(string)

	for _, keyword := range strings.Fields(expected) {
		if strings.Index(logs, keyword) == -1 {
			return ctx, fmt.Errorf("logs do not contain the keyword: %q", keyword)
		}
	}

	return ctx, nil
}
