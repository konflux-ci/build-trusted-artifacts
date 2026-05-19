package main

import (
	"bufio"
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var (
	bashCoverageDir string
	repoRoot        string
)

const (
	coverageMountPath = "/coverage"
	coverageInitFile  = "coverage-init.sh"
	coverageOutput    = "bash-coverage.xml"
)

var containerToSource = map[string]string{
	"/usr/local/bin/create-archive":     "create-oci.sh",
	"/usr/local/bin/use-archive":        "use-oci.sh",
	"/usr/local/bin/entrypoint":         "entrypoint.sh",
	"/usr/local/bin/oras_opts.sh":       "oras_opts.sh",
	"/usr/local/bin/select-oci-auth.sh": "select-oci-auth.sh",
}

func initBashCoverage() error {
	root, err := filepath.Abs("..")
	if err != nil {
		return fmt.Errorf("resolving repo root: %w", err)
	}
	repoRoot = root

	dir, err := os.MkdirTemp("", "ta-bash-coverage-")
	if err != nil {
		return fmt.Errorf("creating bash coverage dir: %w", err)
	}

	initScript := `set -T
exec 7>>/coverage/trace-$$.log
trap 'printf "%s:%s\n" "${BASH_SOURCE[0]:-$0}" "${LINENO}" >&7' DEBUG
`

	if err := os.WriteFile(filepath.Join(dir, coverageInitFile), []byte(initScript), 0644); err != nil {
		_ = os.RemoveAll(dir)
		return fmt.Errorf("writing coverage init script: %w", err)
	}

	bashCoverageDir = dir
	return nil
}

func collectBashCoverage() error {
	if bashCoverageDir == "" {
		return nil
	}

	traceFiles, err := filepath.Glob(filepath.Join(bashCoverageDir, "trace-*.log"))
	if err != nil {
		return fmt.Errorf("globbing trace files: %w", err)
	}

	if len(traceFiles) == 0 {
		fmt.Fprintln(os.Stderr, "bash coverage: no trace files found, skipping report generation")
		return nil
	}

	hits := make(map[string]map[int]int)
	for _, tf := range traceFiles {
		if err := parseTraceFile(tf, hits); err != nil {
			fmt.Fprintf(os.Stderr, "bash coverage: skipping %s: %v\n", tf, err)
		}
	}

	sourceHits := make(map[string]map[int]int)
	for containerPath, lines := range hits {
		sourcePath, ok := containerToSource[containerPath]
		if !ok {
			continue
		}
		if sourceHits[sourcePath] == nil {
			sourceHits[sourcePath] = make(map[int]int)
		}
		for line, count := range lines {
			sourceHits[sourcePath][line] += count
		}
	}

	for _, sourcePath := range allSourceFiles() {
		if _, ok := sourceHits[sourcePath]; !ok {
			sourceHits[sourcePath] = make(map[int]int)
		}
	}

	report, err := generateCobertura(sourceHits)
	if err != nil {
		return fmt.Errorf("generating cobertura report: %w", err)
	}

	if err := os.WriteFile(coverageOutput, report, 0644); err != nil {
		return fmt.Errorf("writing coverage report: %w", err)
	}

	fmt.Fprintf(os.Stderr, "bash coverage: wrote %s\n", coverageOutput)
	return nil
}

func cleanupBashCoverage() {
	if bashCoverageDir != "" {
		_ = os.RemoveAll(bashCoverageDir)
		bashCoverageDir = ""
	}
}

func parseTraceFile(path string, hits map[string]map[int]int) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		lastColon := strings.LastIndex(line, ":")
		if lastColon < 0 {
			continue
		}

		filePath := line[:lastColon]
		lineNum, err := strconv.Atoi(line[lastColon+1:])
		if err != nil {
			continue
		}

		if hits[filePath] == nil {
			hits[filePath] = make(map[int]int)
		}
		hits[filePath][lineNum]++
	}
	return scanner.Err()
}

var nonExecutablePattern = regexp.MustCompile(
	`^\s*$` +
		`|^\s*#` +
		`|^\s*(then|else|fi|do|done|esac|;;)\s*$` +
		`|^\s*[{}]\s*$` +
		`|^\s*\)\s*$`,
)

func isExecutableLine(line string) bool {
	return !nonExecutablePattern.MatchString(line)
}

type coberturaReport struct {
	XMLName  xml.Name          `xml:"coverage"`
	LineRate string            `xml:"line-rate,attr"`
	Version  string            `xml:"version,attr"`
	Sources  coberturaSources  `xml:"sources"`
	Packages coberturaPackages `xml:"packages"`
}

type coberturaSources struct {
	Source []string `xml:"source"`
}

type coberturaPackages struct {
	Package []coberturaPackage `xml:"package"`
}

type coberturaPackage struct {
	Name     string           `xml:"name,attr"`
	LineRate string           `xml:"line-rate,attr"`
	Classes  coberturaClasses `xml:"classes"`
}

type coberturaClasses struct {
	Class []coberturaClass `xml:"class"`
}

type coberturaClass struct {
	Name     string         `xml:"name,attr"`
	Filename string         `xml:"filename,attr"`
	LineRate string         `xml:"line-rate,attr"`
	Lines    coberturaLines `xml:"lines"`
}

type coberturaLines struct {
	Line []coberturaLine `xml:"line"`
}

type coberturaLine struct {
	Number int `xml:"number,attr"`
	Hits   int `xml:"hits,attr"`
}

func generateCobertura(sourceHits map[string]map[int]int) ([]byte, error) {
	var totalLines, totalHit int
	var classes []coberturaClass

	sourceFiles := make([]string, 0, len(sourceHits))
	for sf := range sourceHits {
		sourceFiles = append(sourceFiles, sf)
	}
	sort.Strings(sourceFiles)

	for _, sourcePath := range sourceFiles {
		hitMap := sourceHits[sourcePath]

		content, err := os.ReadFile(filepath.Join(repoRoot, sourcePath))
		if err != nil {
			fmt.Fprintf(os.Stderr, "bash coverage: cannot read source %s: %v\n", sourcePath, err)
			continue
		}

		lines := strings.Split(string(content), "\n")
		var classLines []coberturaLine
		var fileTotal, fileHit int

		for i, lineText := range lines {
			lineNum := i + 1
			if !isExecutableLine(lineText) {
				continue
			}
			fileTotal++
			hits := hitMap[lineNum]
			if hits > 0 {
				fileHit++
			}
			classLines = append(classLines, coberturaLine{
				Number: lineNum,
				Hits:   hits,
			})
		}

		totalLines += fileTotal
		totalHit += fileHit

		lineRate := "0"
		if fileTotal > 0 {
			lineRate = fmt.Sprintf("%.4f", float64(fileHit)/float64(fileTotal))
		}

		classes = append(classes, coberturaClass{
			Name:     sourcePath,
			Filename: sourcePath,
			LineRate: lineRate,
			Lines:    coberturaLines{Line: classLines},
		})
	}

	overallRate := "0"
	if totalLines > 0 {
		overallRate = fmt.Sprintf("%.4f", float64(totalHit)/float64(totalLines))
	}

	report := coberturaReport{
		LineRate: overallRate,
		Version:  "1.0",
		Sources:  coberturaSources{Source: []string{"."}},
		Packages: coberturaPackages{
			Package: []coberturaPackage{
				{
					Name:     "bash-scripts",
					LineRate: overallRate,
					Classes:  coberturaClasses{Class: classes},
				},
			},
		},
	}

	output, err := xml.MarshalIndent(report, "", "  ")
	if err != nil {
		return nil, err
	}

	return append([]byte(xml.Header), output...), nil
}

func allSourceFiles() []string {
	files := make([]string, 0, len(containerToSource))
	for _, sf := range containerToSource {
		files = append(files, sf)
	}
	sort.Strings(files)
	return files
}
