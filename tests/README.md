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
| `fake_lt.odin` | the fake LanguageTool server; its top comment defines the recording key, with the probe's test vector |

## Where the goldens came from

The Odin checker is a port of a Python checker, the reference. Every golden,
recording and mask file was produced by running the reference, and the port
has to reproduce them exactly. They are the expected values, so a change to
one is a change of behavior and needs a reason.

The reference is gone from the tree. It lives in ravnix's history (the
`skills/prose/scripts/` of the skill) and in this repository's history: the
last commit that holds `reference/` is `2db5d1a`, so
`git show 2db5d1a:reference/check.py` reads it, and
`git worktree add DIR 2db5d1a` gives the whole directory.

How each set was made, in that tree:

- `golden/` and `golden-lt/`: `reference/make_golden.sh` runs the reference
  over `corpus/` with no settings and no credentials. It needs a server on
  `127.0.0.1:18099`: `fake_lt.py` replays `lt-recordings/`, `record_lt.py`
  records what is missing. The script fails on a finding `LT-CHUNK-FAILED`,
  which means a recording is missing.
- `lt-recordings/`: `record_lt.py` forwarded each unknown request once to
  LanguageTool Premium and stored the response body unchanged. That needs a
  Premium account and key in `LANGUAGETOOL_USERNAME` and
  `LANGUAGETOOL_API_KEY`, and it spends the paid API, so it does not retry.
  `markup2.md` was added after the one recording session and has no
  `golden-lt/` file.
- `mask/`: `reference/dump_mask.py` and `reference/dump_blocks.py`, run with
  `python3 -B -I`, wrote the masking and the blocks of every corpus file.
- Two notes were corrected by hand after the run (`empty` and `only-code` in
  `golden-lt/`), because the reference probes LanguageTool for a text with no
  prose left and the port sends nothing for one. `make_golden.sh` shows how.
  A few expectations in `rules_test.odin` are hand-written too, where the
  reference crashed or was wrong; each says so in its comment.

To regenerate, check out `2db5d1a`, run the scripts there, and copy the output
into `tests/`. Then read the diff: a golden that moved for no reason found in
the port is a bug in one of the two.
