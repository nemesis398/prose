# prose

A [Claude Code](https://claude.com/claude-code) skill with one writing style
for German and English, the reasons for each rule, and a checker,
`prose-check`, that proves a text follows it.

Text written with a language model reads as generated: em dashes in every
other sentence, sentences of one length, bullets of one shape, and a closing
line that restates the paragraph. A list of banned words does not fix that,
because the output dodges the words and keeps the habit. prose teaches the
style with its reasons, and checks the mechanical part instead of trusting it.

The style is the product. It has no switches for its rules: the reasons are
what make it worth installing.

## What it does

- **Bans the em dash** in both languages. English restructures with a comma,
  a colon, a parenthesis, or two sentences. German keeps the spaced en dash
  as the Gedankenstrich, capped at about one per 200 words.
- **Uses emoji as labels**, one at the start of a heading a reader scans for,
  matched to the content, and never in body text.
- **Writes German to DIN 5008**: `5.000`, `3,5`, `40 %`, `z. B.`, and
  compounds as one word. English is American: `organize`, `color`, `40%`.
- **Teaches the voice** that no checker can test: varied sentence length,
  ragged bullets, no sentence that restates the paragraph, the verb before
  the noun.
- **Checks the result.** `prose-check` masks the Markdown (code, links,
  markup), runs its own rules, detects the language of each paragraph, and
  sends each stretch to LanguageTool under its own language, once you have
  chosen a LanguageTool server. Until then nothing leaves your machine.

It governs prose for a human reader: notes, documentation, READMEs, mails,
the body of a commit message, and comments in source. It does not govern chat
replies.

## Install

In Claude Code, add the repository as a marketplace, install the plugin, and
run its setup:

```text
/plugin marketplace add nemesis398/prose
/plugin install prose@prose
/prose:setup
```

`/prose:setup` downloads the `prose-check` binary for your platform from the
release that matches the plugin's version, checks it against the release's
`SHA256SUMS`, and puts it in `skills/prose/bin/`. Then it asks where
LanguageTool may send your text, and writes your answers to the settings
file. Run it again after a plugin update, which lands in a new folder.

Without the plugin system, clone the repository and run the installer inside
the clone, where it reads the version from the plugin manifest. Then copy
`skills/prose/`, with the `bin/` the installer filled, into
`~/.claude/skills/` (remove an older copy first), and choose a backend:

```sh
git clone https://github.com/nemesis398/prose.git
sh prose/skills/prose/install
mkdir -p ~/.claude/skills
cp -R prose/skills/prose ~/.claude/skills/
~/.claude/skills/prose/bin/prose-check --setup
```

On Windows, run the PowerShell installer. The default execution policy
blocks scripts, hence the flag:

```powershell
git clone https://github.com/nemesis398/prose.git
powershell -NoProfile -ExecutionPolicy Bypass -File prose\skills\prose\install.ps1
New-Item -ItemType Directory -Force "$HOME\.claude\skills" | Out-Null
Copy-Item -Recurse prose\skills\prose "$HOME\.claude\skills\"
& "$HOME\.claude\skills\prose\bin\prose-check.exe" --setup
```

When `main` is ahead of the latest release, the installer finds no release
for its version. Check out the latest release tag first, or build the checker
from source (see below).

Binaries exist for Linux x86_64, Linux arm64, macOS arm64 and Windows x86_64.
The installers need `curl` and `sha256sum` or `shasum` (PowerShell brings its
own). A binary that already reports the right version is kept; `--force`
(`-Force` in PowerShell) replaces it.

## Use

Ask in your own words. The skill fires whenever text is written or edited for
a reader, and on requests such as:

- "proofread this README"
- "fix the German in this note"
- "kill the em dashes"
- "make this sound less like AI"

Claude checks what it wrote and reports what the checker said. You can run the
checker yourself. It is `bin/prose-check` inside the skill folder: for a
copied folder that is `~/.claude/skills/prose/bin/prose-check`, and for the
plugin `/prose:setup` names the path, which changes with every plugin update.
The examples put the copied folder's `bin/` on `PATH` first:

```sh
export PATH="$HOME/.claude/skills/prose/bin:$PATH"
prose-check notes/*.md            # check files
prose-check --stdin < draft.md    # check standard input
prose-check --no-lt README.md     # the rules only, without LanguageTool
prose-check --json README.md      # findings as JSON
prose-check --selftest            # show the settings and probe the backend
prose-check --rules               # print your language rule
```

More flags: `--lang auto|de|en` fixes the language, `--picky` turns on
LanguageTool's rules for formal text, and `--strict` fails on warnings too.
Exit 0 means clean, 1 means an error was found (or a warning, with
`--strict`), and 2 means the check could not run.

## LanguageTool backends

The rules run locally. Grammar and spelling need LanguageTool, and you choose
where your text goes:

| Backend | Where your text goes | Grammar and spelling |
| --- | --- | --- |
| `none` (the default) | nowhere | not checked; English spelling through hunspell when it is installed |
| `public` | LanguageTool's free server, `api.languagetool.org` | free rules, rate-limited |
| `premium` | LanguageTool's Premium API, `api.languagetoolplus.com`, under your account | premium rules |
| `server` | the server at the URL you give, such as your own | the rules that server runs |

With `none`, every report says `LanguageTool is off`, and the skill tells you
that grammar was not checked instead of calling the text clean. A backend
that refuses or does not answer stops the check with exit 2; no other backend
stands in for it.

## Settings

`/prose:setup` and `prose-check --setup` write
`$XDG_CONFIG_HOME/prose/config.json`, which is `~/.config/prose/config.json`
by default. Every key is optional:

```json
{
  "languageRule": "German for notes, English for code; Sie for customers",
  "ignoreWords": ["Proxmox", "Grafana"],
  "languagetool": {
    "backend": "premium",
    "username": "you@example.org",
    "keyItem": "LanguageTool"
  }
}
```

- `languageRule` says which language a text is written in, and when a German
  reader gets `Sie`. Claude reads it with `prose-check --rules` before it
  writes. Without it, Claude writes in the language of your request and
  addresses a German reader with lowercase `du`.
- `ignoreWords` are words LanguageTool should accept. Your own list,
  `$XDG_CONFIG_HOME/prose/dictionary.txt` with one word per line, takes the
  place of the one that ships with the skill; `ignoreWords` adds to either.
- `languagetool.backend` is one of the four above. `server` takes the URL in
  `languagetool.server`, and `premium` the account's login in
  `languagetool.username`.

The backend set in the file wins. Without one, `LANGUAGETOOL_SERVER` chooses
`server`, and `LANGUAGETOOL_API_KEY` together with `LANGUAGETOOL_USERNAME`
choose `premium`. Without either, the backend is `none`. A settings file that
is present but broken, such as a backend spelled `"premuim"`, stops the check
with exit 2 instead of quietly turning LanguageTool off.

### The Premium key

The API key never goes into `config.json`, and setup never asks for it. The
checker takes the first of:

1. the environment variable `LANGUAGETOOL_API_KEY`;
2. the password of the Bitwarden item named in `languagetool.keyItem`, read
   with `rbw` when it is installed and unlocked
   (the checker never prompts);
3. the file `$XDG_CONFIG_HOME/prose/credentials`, holding only the key, at
   mode 600. A file with a wider mode is refused.

`skills/prose/references/languagetool.md` has the details: limits, filters,
self-hosting, and what to do when the server will not answer.

## Building from source

`prose-check` is written in [Odin](https://odin-lang.org), with the `core`
and `vendor` libraries only. It links libcurl, which Linux and macOS ship.

```sh
make build    # builds skills/prose/bin/prose-check
```

## Tests

```sh
make test       # the Odin tests, then the tests of both installers
make lint       # markdownlint over the Markdown
make doccheck   # prose-check --no-lt over this repository's own prose
```

The Odin tests run offline. They check every rule against a corpus of
documents with known findings, and the LanguageTool pass against recorded
server answers replayed by a fake server: the Markdown masking, the UTF-16
offsets after an emoji, the split by language, a refused chunk, and the rule
that `none` sends no request. A leak fails a test. The PowerShell installer's
tests run when `pwsh` is on `PATH`.

## Where it comes from

It is a leaf of [ravnix](https://github.com/nemesis398/ravnix): one of the
projects that grew inside that NixOS flake and now stands on its own, so it
can be used without the rest. [DESIGN.md](DESIGN.md) records why each rule is
what it is, and what changed when it left.

## License

[MIT](LICENSE)
