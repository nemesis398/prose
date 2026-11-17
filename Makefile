# The version is the one in the plugin manifest, so a tag and a build agree.
version := $(shell sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json)

ODIN_FLAGS := -vet -o:speed
ifeq ($(shell uname -m),x86_64)
ODIN_FLAGS += -microarch:x86-64-v2
endif

TEST_DEFINES := -define:ODIN_TEST_RANDOM_SEED=1 \
	-define:ODIN_TEST_TRACK_MEMORY=true \
	-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
	-define:ODIN_TEST_FANCY=false

.PHONY: build test lint doccheck reference-test

build:
	odin build src -out:skills/prose/bin/prose-check $(ODIN_FLAGS) -define:PROSE_VERSION=$(version)

test:
	odin test tests $(ODIN_FLAGS) $(TEST_DEFINES)

lint:
	npx --yes markdownlint-cli2 "**/*.md"

# Filled in by Task 13.
doccheck:
	@echo "doccheck: not written yet" >&2; exit 1

# The reference checker against its own fixture, with no settings and no
# skill values on the machine.
reference-test:
	@dir=$$(mktemp -d); \
	RAVNIX_SKILL_VALUES=/nonexistent XDG_CONFIG_HOME=$$dir PYTHONDONTWRITEBYTECODE=1 python3 -B reference/run_tests.py; \
	status=$$?; rm -rf "$$dir"; exit $$status
