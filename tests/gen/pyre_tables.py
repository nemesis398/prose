#!/usr/bin/env python3
"""Generate src/pyre_tables.odin: Python's `\\w` and `\\d` as code point ranges.

The committed tables came from Python 3.14.10 (Unicode 16.0.0), the
interpreter the reference ran on. The generator reads the same two regular
expressions, `re.match(r"\\w", chr(c))` and `re.match(r"\\d", chr(c))`, over
every code point but the surrogates, and joins the hits into ranges. It
writes the file, or with --check compares the file with what it would write
and exits 1 when they differ.

A different Python or Unicode version gives different tables. The committed
file is then not wrong, only older, and the run says which versions differ.

    python3 -I tests/gen/pyre_tables.py            # rewrite src/pyre_tables.odin
    python3 -I tests/gen/pyre_tables.py --check    # exit 1 when it is out of date
    python3 -I tests/gen/pyre_tables.py --output PATH
"""

import argparse
import os
import re
import sys
import unicodedata

# What the committed tables came from. Keep in step with the header text
# written below.
COMMITTED_PYTHON = "3.14.10"
COMMITTED_UNICODE = "16.0.0"

HEADER = """package prose

// Generated, not written: the code point ranges that Python's `re` matches
// with `\\w` and `\\d` on a `str`, taken from Python 3.14.10 (Unicode 16.0.0),
// the interpreter the reference ran on. Odin's `core:unicode` differs from
// both: its letters are the Alphabetic property, and its tables are newer.
// The mask has to see a word boundary exactly where the reference saw one.
// The ranges join the hits of `re.match(r"\\w", chr(c))` and
// `re.match(r"\\d", chr(c))` over every code point but the surrogates.
"""

PER_LINE = 4


def ranges(pattern):
    """Return the [lo, hi] runs of code points that `pattern` matches."""
    rx = re.compile(pattern)
    out = []
    for c in range(0x110000):
        if 0xD800 <= c <= 0xDFFF:
            continue
        if rx.match(chr(c)):
            if out and out[-1][1] == c - 1:
                out[-1][1] = c
            else:
                out.append([c, c])
    return out


def table(name, runs):
    lines = ["", "@(rodata)", f"{name} := [?][2]rune {{"]
    cells = [f"{{0x{lo:X}, 0x{hi:X}}}," for lo, hi in runs]
    for i in range(0, len(cells), PER_LINE):
        lines.append("\t" + " ".join(cells[i : i + PER_LINE]))
    lines.append("}")
    return "\n".join(lines) + "\n"


def render():
    return HEADER + table("PY_WORD_RANGES", ranges(r"\w")) + table(
        "PY_DECIMAL_RANGES", ranges(r"\d")
    ) + "\n"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default = os.path.join(here, "..", "..", "src", "pyre_tables.odin")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if the file differs")
    ap.add_argument("--output", default=default, help="the file to write or check")
    args = ap.parse_args()

    running = ".".join(str(v) for v in sys.version_info[:3])
    if running != COMMITTED_PYTHON or unicodedata.unidata_version != COMMITTED_UNICODE:
        print(
            f"prose: running Python {running} (Unicode {unicodedata.unidata_version}), "
            f"the committed tables came from Python {COMMITTED_PYTHON} "
            f"(Unicode {COMMITTED_UNICODE})",
            file=sys.stderr,
        )

    text = render()
    if args.check:
        with open(args.output, encoding="utf-8", newline="") as f:
            have = f.read()
        if have != text:
            print(f"prose: {args.output} differs from the generated tables", file=sys.stderr)
            return 1
        return 0
    with open(args.output, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
