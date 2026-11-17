#!/usr/bin/env python3
"""Dump the reference's Markdown masking for each file, as the Odin port's oracle.

    PYTHONDONTWRITEBYTECODE=1 python3 -B -I reference/dump_mask.py OUT_DIR FILE...

For FILE `name.md` it writes `OUT_DIR/name.json`: the run-length encoded
`is_markup` and `suppress` arrays (`[value, count]` pairs), every segment, and
the annotations for the whole text. The file is read as the checker reads it.
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


def runs(values: list[bool]) -> list[list]:
    out: list[list] = []
    for v in values:
        if out and out[-1][0] == v:
            out[-1][1] += 1
        else:
            out.append([v, 1])
    return out


def dumps(doc: dict) -> str:
    """JSON with one list item per line, so a diff points at the segment."""
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
        doc = {
            "length": len(source),
            "is_markup": runs(m.is_markup),
            "suppress": runs(m.suppress_orig),
            "segments": [
                {"kind": s.kind, "orig_start": s.orig_start,
                 "orig_len": len(s.orig_text), "plain_text": s.plain_text,
                 "suppress": s.suppress}
                for s in m.segments
            ],
            "annotations": m.annotations_for(0, len(source)),
        }
        (out_dir / (p.stem + ".json")).write_text(dumps(doc), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
