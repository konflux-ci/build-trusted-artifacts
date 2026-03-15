.PHONY: test
test:
	@shellspec --shell bash $(shell command -v kcov >/dev/null 2>&1 && echo '--kcov')
	@cd acceptance && go test -v -coverprofile=coverage.out ./...
