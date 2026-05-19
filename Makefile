.PHONY: lint
lint:
	@shellcheck create-oci.sh use-oci.sh select-oci-auth.sh oras_opts.sh entrypoint.sh hack/demo.sh
	@cd acceptance && golangci-lint run ./...

.PHONY: test
test:
	@shellspec --shell bash $(shell command -v kcov >/dev/null 2>&1 && echo '--kcov')
	@cd acceptance && go test -v -coverprofile=coverage.out ./...
