# prose Design Record

Written 2026-07-27, when the skill lived in the author's notes vault, which is
not a git repository. It moved into this repository with the skill, and
"Since the leaf" at the end records what changed then. The vault-specific
numbers stay as the evidence they are.

## Problem

The vault held 1179 em dashes against 268 en dashes. The em dashes are almost
entirely in AI-written files. The author's own hand-written German uses the
spaced en dash correctly as Gedankenstrich. So the complaint is not about dashes in
general, it is about generated text having a recognizable fingerprint, and
about German and English both needing to come out correct.

## Decisions

**One bilingual skill, not two.** The vault mixes languages inside single
files: today's daily note has English headings over German prose. Two
language-scoped skills would duplicate most of their content and compete to
trigger on exactly the files that matter most.

**Two layers, kept apart.** Mechanical rules are script-enforced and provable.
Voice is taught with reasons. Collapsing them into one banned-word list is why
that genre of skill fails: the output dodges the listed words and keeps the
underlying tic, which is structural.

**Dash policy, per language.** German keeps ` – ` capped at roughly one per 200
words, because it is correct German and it is how the author writes; the cap
targets the habit, not the character. English restructures. `—` is zero everywhere.
Ranges keep the unspaced en dash in both.

**Emoji are labels, not decoration.** Derived from the vault rather than
assumed: leading the heading, one per heading, semantically literal, only on
headings a reader scans for, none in body text. A repeated emoji, or one that
also labels a heading, is recognized as a deliberate legend and left alone.

**Verification is part of the skill, not a suggestion.** The skill is not
finished until the checker has run on the saved text and its output has been
read. Without that it is advice, and advice does not deliver "free of errors".

## Settled from evidence, not preference

- American spelling. `organize` 7/0, `behavior` 11/1, `color` 30/3, `center`
  8/0 across the vault. The `analyse` hits are the German noun.
- Lowercase `du`, confirmed by the author. The vault had no real convention,
  six `Du` against three `du`, all in generated files.
- Emoji concentrate at H1 and H2 and appear on a minority of headings, so the
  rule is "headings a reader scans for", not "every heading".

## Scope

Files, commit message bodies, comments and identifiers. Not chat replies, so
the global `CLAUDE.md` was left untouched. In source files only the spelling
and dash rules apply.

## Empirical findings that shaped the implementation

Three things were established against the live LanguageTool API because
assuming them the other way produces confidently wrong output.

1. **Offsets are UTF-16 code units.** LanguageTool is a JVM program. Each emoji
   before a finding shifts its reported position by one and the error
   accumulates. In this vault every file is affected.
2. **`interpretAs` does not shift offsets.** Markup counts at full original
   length and the replacement contributes nothing, so offsets are positions in
   the original document once converted from UTF-16. The plaintext mapping
   layer originally built for this was wrong and was deleted.
3. **`software.premium` is not the tier signal.** It is `true` even on the free
   endpoint because it describes the build. `premiumHint` is present exactly
   when premium rules were not applied.

## Rejected

- Sending a mixed document under one language code. It looks like a clean
  result and is not one: the English paragraphs get German grammar rules and no
  English spellcheck at all.
- Flagging each dash past the budget. The budget is a document property, so the
  cutoff position is arbitrary and the report is noise. It is one finding that
  names the densest paragraphs.
- Repeating an identical emoji warning per occurrence. On a note with an emoji
  legend that produced 22 warnings for the legend and buried everything else.

## Closed 2026-07-27

**The premium key works.** The consumer Premium key authenticates against
`api.languagetoolplus.com` with no support request, despite LanguageTool's own
docs implying otherwise. It lives in a password manager and reaches the checker
through the environment or rbw.

**Premium needed three filters before it was usable.** More findings turned out
not to mean better findings:

- `LT_RECOMMENDATION_*` are adverts, not errors, and are dropped.
- `QB_NEW_*` declare `issueType=grammar` but are rephrasing suggestions. On one
  real note they arrived as 23 errors, including capitalizing `restic` and
  lowercasing a vendor's product name "Cloud Storage". Demoted to warnings, which
  took that note to 0 errors and 15 warnings.
- Suggestion-class rules read a markdown table row as prose and would corrupt
  it, so they are dropped on table rows.

German came back at 0 errors and 1 arguable warning per document even in picky
mode, so the German side needed no tuning.

## Heading case, a finding that turned out to be a misreading

Flagged during the eval review as an inconsistency between runs. It was not.
Measured across the vault, excluding German headings and single proper nouns:

| | Title Case | sentence case |
| --- | --- | --- |
| note filenames | 26 | 1 |
| `#` | 29 | 11 |
| `##` | 25 | 61 |
| `###` | 19 | 31 |

The convention is Title Case for the note name and its H1, sentence case for
headings inside, which is ordinary editorial practice. Both English runs
followed it correctly. The apparent disagreement was an H1 compared against an
H2, which is the convention working rather than failing.

The initial claim was drawn from *note titles* rather than from headings
inside documents, which is why it pointed the wrong way.

It is now stated in SKILL.md so the behavior is instructed rather than
incidental, and deliberately left out of the checker: separating a wrongly
capitalized heading from a run of proper nouns needs judgment the script does
not have, and a rule that fired on `Proxmox Backup Server` would do more harm
than the rule prevents.

## Since the leaf

Decided 2026-11-17, when the skill left the author's configuration and became
a plugin of its own, a leaf of ravnix that strangers install.

**The style is the product.** One style for German and English, with the
reasons for each rule, and no switches for the rules themselves. Every switch
is a code path the checker and its tests must carry, and the reasons are what
make the style worth installing.

**The checker is written in Odin**, as `prose-check`, and released as a binary
for Linux x86_64, Linux arm64, macOS arm64 and Windows x86_64, so a user needs
no Python, no Nix and no compiler. It keeps the Python checker's interface,
flags, exit codes, JSON shape and rule names. The port ran against the Python
checker as its reference: a corpus of documents went through both, offline and
against recorded LanguageTool answers, and the findings had to be identical.
The corpus and its expected findings stay as golden tests, and the Python
checker left the tree once the port matched it; `tests/README.md` says how the
goldens were made and where the reference lives in history.

**The settings live in one file of its own**, `config.json` under
`$XDG_CONFIG_HOME/prose/`. Claude Code's plugin settings were weighed and
rejected: they reach a skill's text but not a program it runs, and a copied
folder gets none. The language rule moved out of the skill's text into that
file, and `prose-check --rules` prints it.

**Nothing leaves the machine until the user chooses a backend.** A fresh
install runs the rule pass, checks English spelling with hunspell when it is
installed (not on Windows, where the checker cannot bound a hung hunspell
wrapper), and says that LanguageTool is off. A backend set in the file wins
over the environment; without one, exported variables still choose, so a setup
that only exports them keeps working. No backend ever stands in for another.

**A broken settings file stops the check** with exit 2. Reading it as "no
settings" would turn Premium off after one typo while every run stayed green.

**The key never sits in the settings file.** It comes from the environment,
from an rbw item, or from a credentials file at mode 600, in that order, and
setup never asks for it.

**The built-in word list holds only names every Claude Code user meets**, such
as Claude, LanguageTool and GitHub. Without it LanguageTool flags "Claude" for
every stranger. A user's own words go into their dictionary or `ignoreWords`.

**`install` downloads the release binary** for the platform and checks it
against `SHA256SUMS`, reading the version from the plugin manifest.
`/prose:setup` runs it, then asks for the backend in the question dialog,
naming where each one sends the text.

**The repository is held to its own rule.** The checker runs over the
repository's prose with `--no-lt`, and the bad examples sit in code blocks,
which it masks, so no exemption is needed.

**Dropped from the earlier checker:** `--unlock`, because the checker never
prompts; the chain of fallback backends, because a stand-in reads as clean;
and the username read from the Bitwarden item and the login keyring, which
hid where a value came from.

## Open

Nothing blocking.
