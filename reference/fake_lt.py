#!/usr/bin/env python3
"""A fake LanguageTool server that replays recorded answers.

    python3 fake_lt.py [--port 18099] [--dir tests/lt-recordings]

It listens on 127.0.0.1 and answers `POST /v2/check` with the recording for the
request, so the checker's tests run offline and reproduce byte for byte. The
Odin port's fake server computes the same key from the same request.

The recording key
-----------------
    key = hex(sha256(language + "\\x00" + level + "\\x00" + canonical))

with the three parts taken from the form body of the POST (it is
`application/x-www-form-urlencoded`, UTF-8, decoded as usual):

language
    The form field `language`, as sent (`de-DE` or `en-US`).

level
    The form field `level`. The checker sends `picky` or `default`. When the
    field is absent (the probe, `text=This are a test.&language=en-US`, sends
    none) the level is `default`.

canonical
    The annotation items joined with "\\x01" (U+0001), no separator at the end.
    The items come from one of two fields:

    * `data`, a JSON document `{"annotation": [ITEM, ...]}`. An ITEM is an
      object with either a `text` string or a `markup` string, and for a
      markup item possibly an `interpretAs` string. A text item becomes
      "t:" + text. A markup item becomes "m:" + markup + "\\x02" + interpretAs,
      where interpretAs is the empty string when the item has none.
      The JSON is decoded first, so how it was escaped does not matter.
    * `text`, plain text, used only when there is no `data` field. It is one
      text item: "t:" + text.

All strings are UTF-8 when hashed. The fields `username`, `apiKey` and
`disabledRules` take no part in the key: the first two must never reach a
recording, the last one is constant.

The recording
-------------
`<dir>/<key>.json` holds the response body of LanguageTool, byte for byte as
received. The fake sends it back unchanged with status 200 and
`Content-Type: application/json`. A key without a file answers 404 with
`no recording for key <key>` as the body. Any other path answers 404, and a
GET on `/v2/check` answers 405.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_PORT = 18099
DEFAULT_DIR = Path(__file__).resolve().parent.parent / "tests" / "lt-recordings"


def canonical_items(form: dict[str, str]) -> str:
    """The annotation items of a request, joined as the module docstring says."""
    if "data" in form:
        items = json.loads(form["data"]).get("annotation", [])
        parts = []
        for item in items:
            if "markup" in item:
                parts.append("m:" + item["markup"] + "\x02"
                             + (item.get("interpretAs") or ""))
            else:
                parts.append("t:" + item.get("text", ""))
        return "\x01".join(parts)
    return "t:" + form.get("text", "")


def recording_key(form: dict[str, str]) -> str:
    language = form.get("language", "")
    level = form.get("level") or "default"
    raw = language + "\x00" + level + "\x00" + canonical_items(form)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def parse_form(body: bytes) -> dict[str, str]:
    pairs = urllib.parse.parse_qs(body.decode("utf-8"), keep_blank_values=True)
    return {k: v[0] for k, v in pairs.items()}


class Handler(BaseHTTPRequestHandler):
    recordings: Path = DEFAULT_DIR
    lock = threading.Lock()

    def log_message(self, fmt: str, *args) -> None:     # keep the output quiet
        pass

    def _send(self, status: int, body: bytes,
              ctype: str = "application/json") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        self._send(405 if self.path.split("?")[0] == "/v2/check" else 404,
                   b"not found", "text/plain")

    def do_POST(self) -> None:
        if self.path.split("?")[0] != "/v2/check":
            self._send(404, b"not found", "text/plain")
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            form = parse_form(self.rfile.read(length))
            key = recording_key(form)
        except (ValueError, UnicodeDecodeError, AttributeError):
            self._send(400, b"malformed request", "text/plain")
            return
        self._answer(form, key)

    def _answer(self, form: dict[str, str], key: str) -> None:
        path = self.recordings / f"{key}.json"
        try:
            body = path.read_bytes()
        except OSError:
            self._send(404, f"no recording for key {key}".encode(), "text/plain")
            return
        self._send(200, body)


def make_server(port: int, recordings: Path,
                handler: type[Handler] = Handler) -> ThreadingHTTPServer:
    handler.recordings = recordings
    return ThreadingHTTPServer(("127.0.0.1", port), handler)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    args = ap.parse_args()
    server = make_server(args.port, args.dir)
    print(f"fake LanguageTool on 127.0.0.1:{args.port}, recordings {args.dir}",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
