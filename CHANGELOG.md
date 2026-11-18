# Changelog

All notable changes to prose are listed here. The format follows [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-11-18

A patch release. A setup or a settings file that worked on 0.1.0 keeps
working.

### Added

- The plugin has an icon.
- `--selftest` notes a trailing comma in `config.json` with its line and
  column, and says that `--setup` writes strict JSON.
- `--selftest` says when it put `http://` in front of a `LANGUAGETOOL_SERVER`
  value that had no scheme, and shows the URL it uses.

### Changed

- Emoji are counted as the reader sees them: one finding per visible emoji.
  A skin tone belongs to the emoji before it, a joined sequence such as a
  person at work or a family is one emoji even with toned members, and a
  keycap is one emoji. Only a fully qualified keycap counts: a digit, `#` or
  `*`, then U+FE0F, then U+20E3. A bare digit with U+20E3 is no emoji.
- A keycap in a heading is an `EMOJI-POSITION` finding unless it is the
  heading's first-character label. This is by design: a keycap is an emoji,
  and the position rule applies to every emoji.
- `--setup` refuses options it would ignore (`--rules`, `--json`, `--strict`,
  `--lang`, `--no-lt`, `--picky`) and `--values-stdin` without `--setup`, with
  exit 2 and nothing written. Standard input that cannot be read is told apart
  from standard input that is too big.
- The probe names its tier from `software.premium`: "premium rules active"
  only when the server says premium and carries no `premiumHint`, "free rules
  only" otherwise, which includes a self-hosted open-source server.
- A server that answers but is not checking (no `matches` list, no match on the
  probe sentence, an answer that is not JSON) is reported as "answered but is
  not checking", not as unreachable. The check still stops with exit 2.
- A failure of the libcurl on this machine (a missing feature, a refused
  option) is reported as such: "libcurl on this machine refused ...; the check
  stops". It no longer reads as an unreachable server. The exit code stays 2.
- A loopback server (`localhost`, `127.0.0.1`, `::1`) bypasses a proxy unless
  you set `no_proxy` or `NO_PROXY` yourself, in which case your list wins. A
  libcurl built without proxy support, which refuses that option, works.
- What a retry cannot fix is not retried: a certificate that does not verify,
  a bad URL, an answer that is too big, a refused libcurl option. Every libcurl
  option is checked, so a timeout that silently vanished is now an error.
- A server URL is checked where it is used, case-insensitively, and the message
  says whether it came from `LANGUAGETOOL_SERVER` or from `config.json`
  (never the value, which may hold a login). A message that names the settings
  file gives its whole path, `--selftest` included.
- JSON errors in `config.json` and in the values given to `--setup` name the
  line and the column.
- Setup refuses every spelling of a credential's name (`apiKey`, `api-key`,
  `API_KEY`, `password`, anything ending in token, secret or password), at the
  top and under `languagetool`. The key never goes in the settings file.
- Numbers in `config.json` are kept exactly. Setup writes an integer as an
  integer and a float with its `.0`, and refuses a number it cannot keep: an
  integer beyond 64 bits, or a float that overflows or underflows.
- The credentials file is checked on the file that is read: a mode wider than
  600 or a size beyond the limit is refused, and a FIFO is no key and no hang.
- `--selftest` asks the rbw agent for the Premium key once.
- Setup syncs the directory after the rename, sweeps the temporary files of
  dead processes, reports a directory it cannot make, and reads a relative
  symbolic link from the directory it is really in.
- The checker gives up on a hunspell run when no writer thread starts, and
  reads the command's output while it runs, so its 64 KiB cap applies. A lone
  carriage return ends a line in a dictionary.
- The installer reads the top-level version of `plugin.json`, treats a shell
  under Rosetta on Apple silicon as arm64, and sweeps the temporary folders of
  killed runs. The probe of an installed binary's `--version` gets a
  `timeout -k 2 10` where `timeout` exists (and runs without it where `-k` is
  not understood), so a hung binary cannot hang the install.
- The PowerShell installer bounds idle reads on PowerShell 7.4 and later, and
  accepts a 32-bit PowerShell on 64-bit Windows.

### Fixed

- An answer with no HTTP status line is a failed request that is not retried.
  libcurl before 7.66 took such a reply as HTTP/0.9 and as a success, so the
  check went on with an empty answer.
- A keycap whose digit is in no emoji range no longer slips through
  `EMOJI-BODY` in body text, and a keycap on `*` is found although the mask
  reads a lone `*` as markup.
- Output reaches standard output before the error that ends a run with exit 2.
- An answer from LanguageTool that holds an integer beyond 64 bits is a failed
  chunk, not a finding at a wrong place.

## [0.1.0] - 2026-11-17

First release.
