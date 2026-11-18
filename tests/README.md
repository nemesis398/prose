# Tests

`make test` runs three suites: `odin test tests` (the checker), `install_test.sh`
and, where PowerShell is installed, `install_test.ps1`. None needs a network or
Python.

| Path | Holds |
| --- | --- |
| `corpus/` | the documents the checker is tested on, bad Markdown on purpose |
| `golden/` | the findings for each corpus file with LanguageTool off, plus `fixture.txt`, the text report of `fixture.md` |
| `golden-lt/` | the findings with LanguageTool on, answered from `lt-recordings/` |
| `lt-recordings/` | LanguageTool's responses, one file per request, named by the recording key |
| `mask/` | the Markdown masking (`NAME.json`) and the language blocks (`NAME.blocks.json`) of each corpus file |
| `stub/` | stand-ins for `hunspell` and its failure modes |
| `gen/` | `pyre_tables.py`, the generator of `src/pyre_tables.odin` (see below); no test runs it |
| `fake_lt.odin` | the fake LanguageTool server; its top comment defines the recording key, with the probe's test vector |

## Where the goldens came from

The Odin checker is a port of a Python checker, the reference. Every golden,
recording and mask file was produced by running the reference, and the port
has to reproduce them exactly. They are the expected values, so a change to
one is a change of behavior and needs a reason.

The reference is gone from the tree. It lives in ravnix's history (the
`claude/skills/prose/scripts/` of the skill) and in this repository's history: the
last commit that holds `reference/` is `2db5d1a`, so
`git show 2db5d1a:reference/check.py` reads it, and
`git worktree add DIR 2db5d1a` gives the whole directory.

How each set was made, in that tree:

- `golden/` and `golden-lt/`: `reference/make_golden.sh` runs the reference
  over `corpus/` with no settings and no credentials, in an empty `HOME`
  and `XDG_CONFIG_HOME` and a clean environment. It needs a server on
  `127.0.0.1:18099`: `fake_lt.py` replays `lt-recordings/`, `record_lt.py`
  records what is missing. The script fails on a finding `LT-CHUNK-FAILED`,
  which means a recording is missing. It also writes `golden/fixture.txt`,
  the text report of `fixture.md`, and applies the two hand corrections below.
- `lt-recordings/`: `record_lt.py` forwarded each unknown request once to
  LanguageTool Premium and stored the response body unchanged. That needs a
  Premium account and key in `LANGUAGETOOL_USERNAME` and
  `LANGUAGETOOL_API_KEY`, and it spends the paid API, so it does not retry.
  `markup2.md` was added after the one recording session and has no
  `golden-lt/` file.
- `mask/`: `reference/dump_mask.py` and `reference/dump_blocks.py` write the
  masking and the blocks of every corpus file.
- Two notes are corrected by hand after the run (`empty` and `only-code` in
  `golden-lt/`), because the reference probes LanguageTool for a text with no
  prose left and the port sends nothing for one. `make_golden.sh` does it with
  `sed` at its end. A few expectations in `rules_test.odin` are hand-written
  too, where the reference crashed or was wrong; each says so in its comment.

## The Python class tables

`src/pyre_tables.odin` holds Python's `\w` and `\d` as code point ranges, so
that the mask sees a word boundary exactly where the reference did.
`gen/pyre_tables.py` writes it: it asks the running Python's `re` about every
code point but the surrogates and joins the hits into ranges.
`python3 -I tests/gen/pyre_tables.py` rewrites the file, and with `--check` it
only compares, exiting 1 when the committed file differs from what it would
write. The committed tables came from Python 3.14.10 (Unicode 16.0.0); on
another version the run says so on stderr, and a difference then means a newer
Unicode, not an error. `make test` does not run it, because the suite needs no
Python; `mask_test.odin` checks the tables at known code points instead.

## Regenerating

Needs `git`, `python3` and `bash`; no network, because `fake_lt.py` answers
from the recordings. Run it from the root of this repository. The reference is
unpacked into a scratch folder, so nothing in your checkout changes until you
copy a result back. The steps below were run against the current goldens and
reproduce every file in `golden/`, `golden-lt/` and `mask/` byte for byte.

```sh
PROSE=$PWD
REF=$(mktemp -d)
git archive 2db5d1a | tar -x -C "$REF"
cd "$REF"

# 1. The fake LanguageTool on 127.0.0.1:18099, in the background.
python3 -B reference/fake_lt.py --port 18099 &
FAKE=$!
sleep 1

# 2. golden/, golden-lt/ and golden/fixture.txt. Start from empty folders, so
# a file the script no longer writes cannot hide.
rm -rf tests/golden tests/golden-lt tests/mask
PORT=18099 bash reference/make_golden.sh

# 3. mask/: the masking and the language blocks of every corpus file.
mkdir tests/mask
PYTHONDONTWRITEBYTECODE=1 python3 -B -I reference/dump_mask.py tests/mask tests/corpus/*.md
PYTHONDONTWRITEBYTECODE=1 python3 -B -I reference/dump_blocks.py tests/mask tests/corpus/*.md

# 4. Stop the server and compare with the current files. An empty diff means
# the goldens still are what the reference writes.
kill "$FAKE"
for d in golden golden-lt mask; do diff -r "$REF/tests/$d" "$PROSE/tests/$d"; done
```

To change a golden on purpose, copy the folder from `$REF/tests/` over the one
in `tests/`, then read the diff in git: a golden that moved for no reason found
in the port is a bug in one of the two. Delete `$REF` when you are done.

To record a request that has no recording yet, start `record_lt.py` in place
of step 1, with the Premium account in the environment, and expect it to spend
the paid API:

```sh
LANGUAGETOOL_USERNAME=... LANGUAGETOOL_API_KEY=... \
  python3 -B reference/record_lt.py --port 18099 --dir "$PROSE/tests/lt-recordings" &
```
