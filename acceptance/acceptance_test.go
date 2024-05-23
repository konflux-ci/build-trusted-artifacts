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
const mountedPath = "/data"

const testRegistryID = "registryID"

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
		if err := createNetwork(ctx); err != nil {
			panic(err)
		}
		if err := buildContainerImage(ctx); err != nil {
			panic(err)
		}
	})
}

func setupScenario(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
	tempDir, err := os.MkdirTemp("", "ec-policies-")
	if err != nil {
		return ctx, fmt.Errorf("setting up scenario - mktemp dir: %w", err)
	}

	ts, err := newTestState(tempDir)
	if err != nil {
		return ctx, fmt.Errorf("setting up scenario - newTestState: %w", err)
	}

	// generate self-signed certs and place in temp directory on the local machine
	if err := generateSelfSignedCert(ts.domainCert(), ts.domainKey()); err != nil {
		return ctx, err
	}

	binds, err := containerBinds(ts)
	if err != nil {
		return ctx, err
	}

	mountedTS := ts.forMount(mountedPath)
	registryID, err := runRegistry(ctx, binds, mountedTS.domainCert(), mountedTS.domainKey())
	if err != nil {
		return ctx, fmt.Errorf("setting up scenario: %w", err)
	}
	ctx = context.WithValue(ctx, testRegistryID, registryID)

	return setTestState(ctx, ts), nil
}

func teardownScenario(ctx context.Context, sc *godog.Scenario, _ error) (context.Context, error) {
	// Purposely ignore errors here to prevent a teardown error to mask a test error.
	if registryID, ok := ctx.Value(testRegistryID).(string); ok {
		cleanupContainer(ctx, registryID)
	}

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
	// resultFile = where the image:sha is stored
	// sourceFile = the files that are tarred and zipped
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("createArtifact get test state: %w", err)
	}

	// Set up the file paths as they will be seen within the container.
	storePath := fmt.Sprintf("%s:%s/%s", registryHost, registryPort, artifactContainer)
	mountedTS := ts.forMount(mountedPath)
	sourceFile := filepath.Join(mountedTS.sourceDir(), path)
	resultFile := filepath.Join(mountedTS.resultsDir(), result)

	binds, err := containerBinds(ts)
	if err != nil {
		return ctx, err
	}

	cmd := []string{
		"create",
		"--store",
		storePath,
		fmt.Sprintf("%s=%s", resultFile, sourceFile),
	}

	if ctx, err := runContainer(ctx, cmd, binds, mountedTS.domainCert()); err != nil {
		return ctx, fmt.Errorf("creating artifact: %w", err)
	}

	return ctx, nil
}

func useArtifactForFile(ctx context.Context, result, path string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return nil, fmt.Errorf("useArtifactForFile get test state: %w", err)
	}

	binds, err := containerBinds(ts)
	if err != nil {
		return ctx, err
	}

	cmd, err := useCmd(ts, result)
	if err != nil {
		return ctx, err
	}

	mountedTS := ts.forMount(mountedPath)
	if ctx, err = runContainer(ctx, cmd, binds, mountedTS.domainCert()); err != nil {
		return ctx, fmt.Errorf("use artifact: %w", err)
	}

	return ctx, nil
}

func containerBinds(ts testState) ([]string, error) {
	mountedTS := ts.forMount(mountedPath)
	return []string{
		// TODO: The ":Z" option is required on Linux systems because of selinux. This might not
		// work on a mac, for example.
		fmt.Sprintf("%s:%s:Z", ts.contextDir, mountedTS.contextDir),
	}, nil
}

// return command and binds
func useCmd(ts testState, result string) ([]string, error) {
	// read the result file for the oci location and artifact sha
	resultInfo, err := os.ReadFile(filepath.Join(ts.resultsDir(), result))
	if err != nil {
		return nil, fmt.Errorf("reading result file: %w", err)
	}

	// Set up the file paths as they will be seen within the container.
	mountedTS := ts.forMount(mountedPath)
	restoredPath := mountedTS.restoredDir()

	return []string{
		"use",
		fmt.Sprintf("%s=%s", resultInfo, restoredPath),
	}, nil
}

func restoredFileShouldMatchSource(ctx context.Context, fname string) (context.Context, error) {
	ts, err := getTestState(ctx)
	if err != nil {
		return ctx, fmt.Errorf("restoredFileShouldMatchSource get test state: %w", err)
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

	// The use-oci.sh script fetches the arvhive and outputs to stdout,
	// so all we can do is check the restored dir for contents. We can also
	// assume that since the extraction function succeeded, that the files,
	// if any exist are restored.
	entries, err := os.ReadDir(ts.restoredDir())
	if err != nil {
		return ctx, err
	}

	if len(entries) != 0 {
		return ctx, fmt.Errorf("there are files in the restored dir: %q, %v", ts.restoredDir(), err)
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
	mountedTS := ts.forMount(mountedPath)
	restoredPath := mountedTS.restoredDir()

	binds := []string{
		// TODO: The ":Z" option is required on Linux systems because of to selinux. This might not
		// work on a mac, for example.
		fmt.Sprintf("%s:%s:Z", ts.contextDir, mountedTS.contextDir),
	}

	cmd := []string{
		"use",
		fmt.Sprintf("%s=%s", archiveUri, restoredPath),
	}

	if ctx, err = runContainer(ctx, cmd, binds, mountedTS.domainCert()); err != nil {
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
