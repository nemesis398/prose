#!/usr/bin/env python3
"""Dump the reference's language blocks for each file, as the Odin port's oracle.

    PYTHONDONTWRITEBYTECODE=1 python3 -B -I reference/dump_blocks.py OUT_DIR FILE...

For FILE `name.md` it writes `OUT_DIR/name.blocks.json`: the text length and
every block with its `start`, `end` and `lang`, as `language_blocks` returns
them for `forced = "auto"`. The file is read as the checker reads it.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


def load_check():
    path = Path(__file__).resolve().parent / "check.py"
    spec = importlib.util.spec_from_file_location("check", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["check"] = mod
    spec.loader.exec_module(mod)
    return mod


def dumps(doc: dict) -> str:
    """JSON with one list item per line, so a diff points at the block."""
    def one(v) -> str:
        return json.dumps(v, ensure_ascii=False, separators=(", ", ": "))
    parts = []
    for key, value in doc.items():
        if isinstance(value, list) and value:
            items = ",\n  ".join(one(v) for v in value)
            parts.append(f" {one(key)}: [\n  {items}\n ]")
        else:
            parts.append(f" {one(key)}: {one(value)}")
    return "{\n" + ",\n".join(parts) + "\n}\n"


def main() -> int:
    check = load_check()
    out_dir = Path(sys.argv[1])
    for f in sys.argv[2:]:
        p = Path(f)
        source = p.read_text(encoding="utf-8")
        m = check.mask_markdown(source)
        blocks = check.language_blocks(m, "auto")
        doc = {
            "length": len(source),
            "blocks": [{"start": b.start, "end": b.end, "lang": b.lang}
                       for b in blocks],
        }
        (out_dir / (p.stem + ".blocks.json")).write_text(dumps(doc), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
