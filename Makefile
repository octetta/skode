.PHONY: default help all build test test-beam test-js format format-check check editor editor-build editor-serve serve editor-clean clean sync-from-sk3 sync-from-pulp

GLEAM ?= gleam

default: help

help:
	@echo "Skode Build & Tooling Targets:"
	@echo "  make help         - Show this list of targets (default)"
	@echo "  make serve        - Build and launch the Lustre voice editor on http://localhost:8000"
	@echo "  make build        - Build skode library (BEAM + JS)"
	@echo "  make all          - Build skode library and compile editor app"
	@echo "  make test         - Run test suite on BEAM and JS runtimes"
	@echo "  make test-beam    - Run tests on Erlang BEAM"
	@echo "  make test-js      - Run tests on Node.js JavaScript target"
	@echo "  make format       - Format all Gleam code (library + editor)"
	@echo "  make format-check - Verify Gleam code formatting"
	@echo "  make check        - Run Gleam compiler type check"
	@echo "  make editor-build - Build Lustre editor web application"
	@echo "  make sync-from-sk3 - Synchronize schema bindings & WASM engine from ../sk3"
	@echo "  make sync-from-pulp - Backward-compatible alias for sync-from-sk3"
	@echo "  make clean        - Clean build artifacts"

all: build editor-build

editor: editor-serve
serve: editor-serve

build:
	$(GLEAM) build
	$(GLEAM) build --target javascript

test: test-beam test-js

test-beam:
	$(GLEAM) test --target erlang

test-js:
	$(GLEAM) test --target javascript

format:
	$(GLEAM) format
	cd app/editor && $(GLEAM) format

format-check:
	$(GLEAM) format --check
	cd app/editor && $(GLEAM) format --check

check:
	$(GLEAM) check
	cd app/editor && $(GLEAM) check

editor-build:
	cd app/editor && $(GLEAM) build --target javascript

editor-serve: editor-build
	cd app/editor && ./serve.sh 8000

sync-from-sk3:
	$(MAKE) -C ../sk3 sync-skode

sync-from-pulp: sync-from-sk3

clean:
	$(GLEAM) clean
	cd app/editor && $(GLEAM) clean
