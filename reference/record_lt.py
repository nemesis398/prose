#!/usr/bin/env python3
"""The fake LanguageTool server, but it records what it does not know.

    LANGUAGETOOL_USERNAME=... LANGUAGETOOL_API_KEY=... \\
        python3 record_lt.py [--port 18099] [--dir tests/lt-recordings]

Same server and same recording key as fake_lt.py. A request whose recording is
missing is sent once to LanguageTool Premium, with the account from
LANGUAGETOOL_USERNAME and the key from LANGUAGETOOL_API_KEY, and the response
body is stored byte for byte under the key. Neither value is ever written to
a recording or printed.

It spends the paid API, so it does not retry: after the first failed upstream
call it answers every unknown request with 400 (which the checker does not
retry either) and never calls upstream again. Delete the recordings and start
it again by hand to record anew.
"""
from __future__ import annotations

import argparse
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

import fake_lt

PREMIUM = "https://api.languagetoolplus.com"


class Recorder(fake_lt.Handler):
    username = ""
    api_key = ""
    failed = False
    upstream_calls = 0

    def _answer(self, form: dict[str, str], key: str) -> None:
        path = self.recordings / f"{key}.json"
        with self.lock:
            if not path.exists():
                if Recorder.failed:
                    self._send(400, b"recorder stopped after an upstream failure",
                               "text/plain")
                    return
                try:
                    body = self._fetch(form)
                except Exception as e:                    # noqa: BLE001
                    Recorder.failed = True
                    detail = getattr(e, "code", type(e).__name__)
                    print(f"record_lt: upstream failed ({detail}); "
                          "no further upstream calls", file=sys.stderr, flush=True)
                    self._send(400, b"upstream failed", "text/plain")
                    return
                self.recordings.mkdir(parents=True, exist_ok=True)
                path.write_bytes(body)
        super()._answer(form, key)

    def _fetch(self, form: dict[str, str]) -> bytes:
        body = dict(form)
        body["username"] = self.username
        body["apiKey"] = self.api_key
        Recorder.upstream_calls += 1
        req = urllib.request.Request(
            PREMIUM + "/v2/check",
            data=urllib.parse.urlencode(body).encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded",
                     "Accept": "application/json",
                     "User-Agent": "prose-recorder/1.0"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--port", type=int, default=fake_lt.DEFAULT_PORT)
    ap.add_argument("--dir", type=fake_lt.Path, default=fake_lt.DEFAULT_DIR)
    args = ap.parse_args()
    Recorder.username = os.environ.get("LANGUAGETOOL_USERNAME", "")
    Recorder.api_key = os.environ.get("LANGUAGETOOL_API_KEY", "")
    if not (Recorder.username and Recorder.api_key):
        print("record_lt: set LANGUAGETOOL_USERNAME and LANGUAGETOOL_API_KEY",
              file=sys.stderr)
        return 2
    server = fake_lt.make_server(args.port, args.dir, Recorder)
    print(f"recording LanguageTool on 127.0.0.1:{args.port} into {args.dir}",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
