# LanguageTool

The second pass of `prose-check`. It exists because it fails independently:
it catches comma placement and agreement inside long German sentences, which
is exactly the class of error a language model is worst at spotting in its own
output.

It is off until you choose a backend. A fresh install runs the rule pass, sends
nothing anywhere, and says `LanguageTool is off` in the report.

## The settings file

`$XDG_CONFIG_HOME/prose/config.json`, which is `~/.config/prose/config.json`
when `XDG_CONFIG_HOME` is not set. `/prose:setup` writes it, and so does
`prose-check --setup` on a terminal. Every key is optional, and a missing file
means no settings.

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

| Key | Holds |
| --- | --- |
| `languageRule` | which language a text is written in, and when a German reader gets `Sie`; `prose-check --rules` prints it |
| `ignoreWords` | words LanguageTool should accept, on top of the dictionary |
| `languagetool.backend` | `none`, `public`, `premium` or `server` |
| `languagetool.server` | the URL, for `server` |
| `languagetool.username` | the Premium account's login, for `premium` |
| `languagetool.keyItem` | the name or id of the Bitwarden item that holds the Premium key, read with `rbw` |

**A file that is present but cannot be used stops the check** with exit 2,
naming the file and the problem: invalid JSON, a key of the wrong type, an
unknown `backend` such as `"premuim"`, or `server` without a URL. Reading such
a file as "no settings" would turn Premium off after one typo while every run
stayed green. An unknown key is ignored, and `--selftest` lists it.

`prose-check --setup --values-stdin` merges a JSON object into the file: the
keys given replace the stored ones, a key set to `null` is deleted, and the
others stay. When `config.json` is a symlink, the file it points to is
written and the link stays.

## The backend

| Backend | Where the text goes |
| --- | --- |
| `none` | nowhere; grammar is not checked |
| `public` | LanguageTool's free server, `https://api.languagetool.org`, rate-limited |
| `premium` | LanguageTool's Premium API, `https://api.languagetoolplus.com`, under your account |
| `server` | the server at the URL you give, such as your own |

The checker uses one backend, the one chosen, and never falls to another: a
backend standing in silently would turn a refused login into a run that reads
as clean. It is chosen in this order:

1. `languagetool.backend` in the file. The environment only fills in its
   values: with `backend: public` and a key exported, the check stays on the
   public server.
2. Without a backend in the file, the environment: `LANGUAGETOOL_SERVER`
   means `server` with that URL, and `LANGUAGETOOL_API_KEY` together with
   `LANGUAGETOOL_USERNAME` mean `premium`.
3. Neither: `none`, and nothing leaves the machine.

For the chosen backend a variable beats the file's value:
`LANGUAGETOOL_SERVER` beats `server`, `LANGUAGETOOL_USERNAME` beats
`username`, and `LANGUAGETOOL_API_KEY` beats the other key sources.

If the backend refuses the probe (HTTP 401, 403, any HTTP error) or cannot be
reached, the check exits 2 with one line naming the backend, its address and
the HTTP status or why it was unreachable. `--no-lt` runs the other checks
without LanguageTool.

`--selftest` prints the settings file, the backend and why it was chosen,
where the key came from, the dictionaries, and whether the backend answers and
what tier it actually gives. It exits 2 when the backend does not answer.

## The Premium key

The API key is a secret and never sits in `config.json`; setup refuses an
`apiKey`. The checker looks for it in this order:

1. **`LANGUAGETOOL_API_KEY`** in the environment, for a shell that already
   holds it.
2. **The rbw item named by `keyItem`**: the key in its password field. It is
   read only when `rbw` is installed and unlocked. The checker probes
   `rbw unlocked` first and moves on when the vault is locked, so an
   unattended run never blocks on a pinentry prompt.
3. **`$XDG_CONFIG_HOME/prose/credentials`**, holding only the key on one
   line. A line in the form `LANGUAGETOOL_API_KEY=KEY` works too. The file
   must have mode 600; with a wider mode it is refused with a message (the
   mode is not checked on Windows).

Premium without the account or without a key exits 2 with one line that names
what is missing and all three key sources.

The key must never go into a notes vault or any other synced tree, because
those sync to other devices.

LanguageTool documents the API as a separate plan from the consumer Premium
subscription, and their own help pages point Premium holders at support for a
private-use key. **In practice the key from the account settings authenticates
against `api.languagetoolplus.com` directly**, verified 2026-07-27: the probe
comes back without a `premiumHint`, which is the field that actually proves
premium rules ran. No support request was needed. If that ever changes the
probe shows it: `--selftest` reports "free rules only".

## Without a backend

With `none`, English spelling is still checked locally by hunspell when it is
installed: `$PROSE_HUNSPELL`, else `hunspell` on `PATH`. Its findings are
warnings named `HUNSPELL`. German spelling and all grammar wait for a backend.

## Limits

| | Free | Premium |
| --- | --- | --- |
| Requests per minute | 20 | 80 |
| Characters per minute | 75,000 | 300,000 |
| Characters per request | 20,000 | 60,000 |

The checker chunks at 18,000 characters, under the lower ceiling, so the same
code path works on either tier.

A long document therefore spans several requests and can brush the per-minute
limit. Transient failures, 429 and the 5xx family, are retried twice with a
backoff. If a chunk still fails it becomes an `LT-CHUNK-FAILED` **error**
naming the line range that went unchecked, and the run exits non-zero.

That severity is deliberate. This was caught in practice: one run of this very
file reported 1 warning where every other run reported 40, because a chunk had
quietly dropped. A verification tool that reports fewer problems when it is
partly broken is worse than one that refuses to answer.

## Self-hosting

Worth doing for anything confidential, since nothing then leaves the network.

```bash
docker run -d --name languagetool -p 8081:8010 \
  -e langtool_languageModel=/ngrams \
  -v /path/to/ngrams:/ngrams \
  erikvl87/languagetool
```

Then choose `server` with `http://localhost:8081` in `/prose:setup`, or export
`LANGUAGETOOL_SERVER=http://localhost:8081`. A self-hosted server runs the
open source rules only, so the premium rules are not available this way. The
n-gram data is optional and improves confusion-pair detection, which is the
part that catches `das` against `dass`.

## Filtering

The checker turns off LanguageTool rules that argue with this skill's own
policy, chiefly `DASH_RULE`, which suggests em dashes, and the rules that fire
constantly on note-shaped markdown such as bullets that legitimately start
lowercase and carry no full stop.

Three more filters exist specifically because of what premium returns. All
three were measured on real notes, not guessed at.

**`LT_RECOMMENDATION_*` is dropped entirely.** Premium injects adverts for the
browser plugin and the login as if they were matches. Showing those beside real
errors is how a checker loses its credibility.

**`QB_NEW_*` is demoted to a warning.** These QuillBot-derived premium rules
declare `issueType=grammar` or `misspelling`, so at face value they arrive as
errors, and this skill says to fix every error. On one real note that would
have forced 23 wrong edits: capitalizing `restic`, lowercasing a vendor's actual
product name "Cloud Storage", and turning a statement into a question. They are
still worth reading, so they stay, as warnings. After the demotion that same
note reports 0 errors and 15 warnings.

**Casing complaints go through the dictionary, case-insensitively.** A term
the checker accepts keeps whatever casing it was written with, which is what
stops `restic` becoming `Restic`.

Premium also reads a markdown table row as running prose and suggests
rewriting `| 3 copies | Live data |` into `3 copies: live`, which would corrupt
the table. Suggestion-class rules are therefore dropped on table rows.

Spelling complaints are filtered against the accepted words, which come from
three places:

- a built-in list of names every Claude Code user meets: Claude, Anthropic,
  LanguageTool, Markdown, GitHub and the like;
- your dictionary, `$XDG_CONFIG_HOME/prose/dictionary.txt`, one word per line,
  which is the place to add terms as they come up. When it does not exist, the
  `dictionary.txt` beside the skill is read instead;
- `ignoreWords` in `config.json`, which adds to either.

Anything LanguageTool flags inside masked regions is dropped, because a
spelling error inside a command name or a wikilink target cannot be fixed
without breaking the thing it names.

## Two findings worth keeping written down

Both were established empirically against the live API, and both silently
corrupt results if assumed the other way.

**Offsets are UTF-16 code units, not code points.** LanguageTool runs on the
JVM. Every emoji before a finding shifts its reported position by one, and the
error accumulates down the document. In notes where headings are labeled
with emoji this is not a corner case, it is every file. The checker converts
with `utf16_prefix` and `utf16_to_codepoint`.

**`interpretAs` does not shift offsets.** When the `data` parameter is used,
markup counts toward offsets at its full original length and the `interpretAs`
replacement contributes nothing. So offsets are simply positions in the
original document, once the UTF-16 conversion above is applied. No plaintext
mapping layer is needed, and building one produces wrong answers.

One more, smaller: `software.premium` in the response is `true` even on the
free endpoint, because it describes the build rather than the request. The
field that actually tells you is `premiumHint`, which is present exactly when
premium rules were **not** applied.

## Mixed-language documents

The checker splits the document into paragraphs, detects the language of each,
merges neighbors that agree, and sends each stretch under its own language
code. Sending a mixed file as one language means the English paragraphs get
German grammar rules and no English spellcheck at all, which looks like a clean
result and is not one.
