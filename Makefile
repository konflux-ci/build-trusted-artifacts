.PHONY: test
test:
	@shellspec --shell bash
	@cd acceptance && go test -v ./...
