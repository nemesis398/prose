#!/usr/bin/env bash
# Write the golden findings of the reference checker for every corpus file.
#
#   reference/make_golden.sh
#
# tests/golden/NAME.json        --no-lt, nothing leaves the machine
# tests/golden-lt/NAME.json     with LanguageTool, from a server on 127.0.0.1:PORT
# tests/golden-lt/de-note.picky.json   de-note.md with --picky
# tests/golden/fixture.txt      fixture.md's text report, --no-lt, NO_COLOR=1
#
# The script fails, naming the file, when a LanguageTool run holds an
# LT-CHUNK-FAILED finding: that is the reference's answer to a request the
# server could not serve, such as a missing recording, and it must never be
# taken for a golden result.
#
# A server must already listen on PORT (default 18099): fake_lt.py replays the
# recordings, record_lt.py records the missing ones. The reference runs with no
# settings and no credentials: an empty HOME and XDG_CONFIG_HOME, no skill
# values, and only LANGUAGETOOL_SERVER set. The file name in each result is
# the bare name, because the script runs inside tests/corpus.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-18099}
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/config" "$root/tests/golden" "$root/tests/golden-lt"

# Run the reference isolated; status 0 (clean) and 1 (findings) both count.
reference() {
    local status=0
    env -i PATH="$PATH" LC_ALL=C.UTF-8 HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" \
        RAVNIX_SKILL_VALUES=/nonexistent PYTHONDONTWRITEBYTECODE=1 \
        "$@" || status=$?
    if [ "$status" -gt 1 ]; then
        echo "make_golden: the reference exited $status" >&2
        return "$status"
    fi
}

# Files that get no LanguageTool run, so no golden-lt file: their kinds of
# markup were added after the one Premium recording session, and a new
# recording would need a new paid run.
lt_excluded=" markup2.md "

# Fail when the output of a LanguageTool run says a chunk went unchecked.
no_failed_chunk() {
    if command grep -q '"LT-CHUNK-FAILED"' "$2"; then
        echo "make_golden: $1 has an LT-CHUNK-FAILED finding, a recording is missing" >&2
        return 1
    fi
}

cd "$root/tests/corpus"
for file in *.md; do
    name=${file%.md}
    reference python3 -B "$root/reference/check.py" --no-lt --json "$file" \
        > "$root/tests/golden/$name.json"
    case "$lt_excluded" in *" $file "*) continue ;; esac
    reference LANGUAGETOOL_SERVER="http://127.0.0.1:$port" \
        python3 -B "$root/reference/check.py" --json "$file" \
        > "$root/tests/golden-lt/$name.json"
    no_failed_chunk "$file" "$root/tests/golden-lt/$name.json"
done
reference LANGUAGETOOL_SERVER="http://127.0.0.1:$port" \
    python3 -B "$root/reference/check.py" --picky --json de-note.md \
    > "$root/tests/golden-lt/de-note.picky.json"
no_failed_chunk de-note.md "$root/tests/golden-lt/de-note.picky.json"

# The text report, for the command line's test.
reference NO_COLOR=1 python3 -B "$root/reference/check.py" --no-lt fixture.md \
    > "$root/tests/golden/fixture.txt"

# Hand-corrected notes. The reference probes LanguageTool even for a text
# with no prose left after masking; the port sends nothing for one, so its
# note has no LanguageTool part.
set_note() {
    sed "s/^    \"note\": .*/    \"note\": \"$2\",/" "$root/tests/golden-lt/$1.json" > "$scratch/note.json"
    mv "$scratch/note.json" "$root/tests/golden-lt/$1.json"
}
set_note empty "language: unknown"
set_note only-code "language: en"
