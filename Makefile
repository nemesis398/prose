# The version is the one in the plugin manifest, so a tag and a build agree.
version := $(shell sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json)

# TARGET cross-compiles, for example `make build TARGET=darwin_amd64`. Empty
# builds for the host.
TARGET ?=

ODIN_FLAGS := -vet -o:speed
ifneq ($(TARGET),)
ODIN_FLAGS += -target:$(TARGET)
endif
ifneq (,$(findstring amd64,$(TARGET)))
ODIN_FLAGS += -microarch:x86-64-v2
else ifeq ($(TARGET),)
ifeq ($(shell uname -m),x86_64)
ODIN_FLAGS += -microarch:x86-64-v2
endif
endif

TEST_DEFINES := -define:ODIN_TEST_RANDOM_SEED=1 \
	-define:ODIN_TEST_TRACK_MEMORY=true \
	-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
	-define:ODIN_TEST_FANCY=false

.PHONY: build test test-odin test-install test-install-ps1 lint doccheck

build:
	mkdir -p skills/prose/bin
	odin build src -out:skills/prose/bin/prose-check $(ODIN_FLAGS) -define:PROSE_VERSION=$(version)

# The three suites. CI runs each as a step of its own, so that one failing
# suite does not hide another's result.
test: test-odin test-install test-install-ps1

test-odin:
	odin test tests $(ODIN_FLAGS) $(TEST_DEFINES)

test-install:
	sh tests/install_test.sh

test-install-ps1:
	@if command -v pwsh >/dev/null 2>&1; then \
		pwsh -NoProfile -File tests/install_test.ps1; \
	else \
		echo "install_test.ps1: skipped, pwsh is not on PATH" >&2; \
	fi

lint:
	npx --yes markdownlint-cli2 "**/*.md"

# The repository's own prose, held to the style it teaches. The rule pass
# only: the bad examples sit in code blocks, which the checker masks.
DOCS := README.md CHANGELOG.md skills/prose/SKILL.md skills/prose/references/*.md DESIGN.md commands/setup.md

doccheck:
	skills/prose/bin/prose-check --no-lt $(DOCS)
