---
name: prose
description: >-
  Write and repair prose in German and English so it is free of errors and does
  not read as machine-written. Holds one opinionated style: no em dashes
  anywhere, the spaced en dash kept as the German Gedankenstrich but capped,
  emoji as literal section labels in headings only and never in body text, DIN
  5008 typography in German, American spelling in English. Bundles a checker
  that masks the markdown and runs LanguageTool when a backend is chosen, so
  correctness is verified rather than claimed. Use this whenever text is being
  produced or edited for a human reader: notes, daily notes, documentation,
  READMEs, mails, report entries, the body of a commit message, comments in
  source files, or when the user pastes text and asks to clean it up, proofread
  it, fix the German, kill the em dashes, or make it sound less like AI. Use it
  even when the request says nothing about style, because output otherwise
  drifts straight back to em dashes and machine rhythm.
license: MIT
metadata:
  languages: de, en
---

# Prose

Two jobs, same rules.

- **Compose.** Write the text, then verify it, then hand it over.
- **Repair.** Verify first, read what came back, fix, verify again.

The order matters in both directions. Composing without verifying means
shipping em dashes you did not notice writing. Repairing without verifying
first means guessing at what is wrong.

## The loop

Nothing is finished until the checker has run on the actual saved text and you
have read its output.

```bash
"${CLAUDE_SKILL_DIR}/bin/prose-check" path/to/file.md
```

If `${CLAUDE_SKILL_DIR}` above was not filled in, the checker is
`bin/prose-check` in the folder that holds this file (`bin/prose-check.exe` on
Windows).

**When the binary is missing**, after a fresh install or a plugin update (an
update lands in a new folder), run `/prose:setup`, or the `install` script
beside this file (`install.ps1` on Windows). Until the checker has run, the
text is unchecked: say so, and never report it as checked.

Useful flags: `--no-lt` skips LanguageTool and runs the rule pass only,
`--picky` turns on LanguageTool's formal-text rules for something that has to
be correct in front of other people, `--json` for parsing, `--stdin` for text
that is not in a file yet, `--strict` to fail on warnings too, `--selftest` to
see the settings and which backend answers.

Exit 0 means clean, 1 means an error was found. **Exit 2 means the check did
not run, never that the text is clean.** Read the line it printed:

- It names the settings file: the file is broken. Pass on what it says, and
  suggest `/prose:setup`, which can repair it.
- It says LanguageTool did not run and names what is missing, such as the
  Premium account or key: run again with `--no-lt`, which still checks
  everything else, and say that LanguageTool did not run.
- It names a backend and an HTTP status: the configured LanguageTool refused
  or did not answer. Say so. No other backend stands in for it.

**`LanguageTool is off` in the report means grammar was not checked.** No
backend is chosen, so nothing left the machine: the rules ran, and English
spelling was checked by hunspell at most, when it is installed. Report that
instead of a clean text, and point at `/prose:setup` to choose a backend.

`--json` prints one object per file, with that file's findings nested under
`findings`. Flatten it with
`[x for f in json.load(sys.stdin) for x in f['findings']]` and index
`x['line']`, not `.get`: a filter over the top level matches nothing and
reports a clean zero for a file with 16 errors.

Fix every `error`. Read every `warning` and decide, because some of them are
judgment calls the checker deliberately leaves open. Then run it again. Report
what the final run said rather than asserting the text is clean.

One error is not about the text at all. `LT-CHUNK-FAILED` means part of the
document was never checked, usually a rate limit or a network problem. Re-run
it, and never report a clean result from a run containing it: the unchecked
stretch is precisely where an error would go unnoticed.

A huge count is a reason to read before fixing. When one rule fires hundreds
of times in one or two files, check whether the findings cluster inside
markup (links, HTML, inline CSS). That is a masking bug in the checker, not a
discovery about the prose: five such bugs once invented 654 of 890 errors, and
obeying them would have rewritten CSS to `17 px` and broken two diagrams.

The checker covers the mechanical layer only. It cannot tell you that a
paragraph restates itself or that every bullet has the same shape. A clean run
is necessary, not sufficient.

## Dashes

**The em dash `—` is never correct here**, in either language, in headings, in
tables, in commit messages, in comments. It is the single clearest fingerprint
of generated text.

**German keeps the spaced en dash ` – `.** It is the correct Gedankenstrich,
and careful German writers already use it. It is capped at roughly one per 200
words, and the checker reports the density for the document as a whole. The
cap exists because the problem was never the character. The problem is
reaching for the same move every third sentence, so the dash stops being a
device and becomes the default rhythm.

**English restructures.** A comma, a colon, a parenthesis, or two sentences.

```text
bad     Umami runs locally — no data protection agreement needed.
good    Umami runs locally, so no data protection agreement is needed.
good    Umami runs locally. No data protection agreement needed.

bad     Umami läuft lokal — kein AVV nötig.
good    Umami läuft lokal – kein AVV nötig.
```

Ranges keep the unspaced en dash in both languages: `2020–2024`, `10–40 %`,
`Mittel–hoch`, `S. 341–356`.

## Emoji

Emoji are **labels, not decoration**. That is the whole distinction, and it is
what separates this convention from the way generated text uses them.

- One per heading, as the first character, single space after.
- Literal, matched to the content. `🍪` for the cookie banner, `🐞` for error
  tracking, `📊` for analytics, `🏫` for school. Never `🚀` for getting
  started, never `✨` for features, never `🎯` for goals.
- Only on headings a reader scans for. Sub-headings that exist as internal
  scaffolding get none.
- Never the same emoji twice in one document. A landmark that repeats is not a
  landmark.
- None in body text, tables or bullets.

```text
## 📊 Analytics          section anchor, gets one
### Vergleich            internal scaffolding, none
#### 🍪 Cookie-Banner    scan target, gets one
##### Empfehlung         internal, none
```

The exception is a document that already runs a legend, the way a reference
note may mark its rows with the same few emoji throughout. Follow the
convention already in the file instead of stripping it. The checker recognizes
this: an emoji that repeats, or that also labels a heading, is reported as a
legend and left alone.

## Heading case

In English, **Title Case for the note's name and its `#` heading, sentence
case for every heading inside it.** Proper nouns keep their capitals either
way, which is why `## ☁️ Tier 2: restic to B2 Cloud Storage` is already
correct: `restic` is lowercase because that is the tool's name, and Backblaze
sells a product actually called B2 Cloud Storage.

```text
Backup Plan.md                          filename, Title Case
# Backup Plan                           H1, Title Case
## 🔢 3-2-1 in one paragraph            H2, sentence case
## 🧪 Open: none of this is restore-tested
```

German needs no rule here, because German capitalizes nouns regardless.

This one is deliberately not in the checker. Telling a wrongly capitalized
heading from a run of proper nouns needs judgment the checker does not have,
and a rule that fires on `Proxmox Backup Server` would be worse than no rule.

## Voice

The mechanical rules above are enforced by the checker. This part is not, and
it is where the actual work is. A banned-word list produces text that dodges
the words and keeps the tic, because the tell is structural.

**Vary sentence length on purpose.** Uniform length is the strongest single
signal of generated prose, because every sentence gets written to the same
target. A four-word sentence after a thirty-word one is what a person sounds
like.

**Commit to a sentence before writing it.** The dash habit is a symptom: the
sentence finished, something else occurred to the writer, and a dash glued it
on. Decide what the sentence is about first, then the punctuation follows.

**Delete the sentence that restates the paragraph.** Sections that end by
summarizing themselves add length and no information. If the point was made,
it was made.

**Let bullets be ragged.** If every bullet has the same length and the same
grammatical shape, it was generated rather than observed. Real notes have a
two-word bullet next to a three-line one, because reality is uneven.

**Bold is a landmark, not emphasis.** More than roughly one bold phrase per
paragraph and nothing stands out any more.

**Two or four, not always three.** The rule of three is real, and reaching for
it every single time is a tell.

**Say the thing instead of announcing it.** Cut `let's look at the options`
and give the options. Cut `it's worth noting` and note it.

**Prefer the verb to the noun**, especially in German. `Wir migrieren am
Freitag` beats `Die Durchführung der Migration erfolgt am Freitag`.

**Name who does it.** Passive hides the actor, and in a work note the actor is
usually the useful part.

**Be concrete.** Numbers, names and dates instead of "significant" and
"umfangreich". The register to match looks like this: `2–4 h`, `5.000
Fehler/Monat`, `ab 35 €/Monat`, `14 Monate Aufbewahrung`.

The same goes for the shape of a note: terse, decision-first, tables for
comparisons, bold on the decision itself, `→` for something superseded. Do not
inflate a note into an essay.

## Language

Before writing, run `"${CLAUDE_SKILL_DIR}/bin/prose-check" --rules` and follow
the language rule it prints: which language a text is written in, and when a
German reader gets `Sie`. Without a rule, write in the language of the
request, keep an existing text in its own language, and address a German
reader with lowercase `du`, held consistently through a document.

Mixed files are normal and correct. English headings over German prose in one
note is a real pattern, not a mistake to clean up. The checker detects
language per paragraph and sends each stretch to LanguageTool under its own
language, so leave the mixture alone.

English is **American** spelling: `organize`, `behavior`, `color`, `center`.

## References

Load these when the work is actually in that language. They carry the detail
that does not belong in this file.

- `references/german.md` for German. Komma rules that matter, `das`/`dass`,
  `ss`/`ß`, Groß- und Kleinschreibung, Komposita and the Deppenleerzeichen,
  numbers and units per DIN 5008, quotation marks, and the German phrasings
  that read as machine-written.
- `references/english.md` for English. The dash policy in detail, the
  structural AI tells, and a section on German interference errors that
  survive proofreading because they are real English words. Read this one even
  when the English looks fine, because that is exactly when those slip through.
- `references/languagetool.md` for the checker's settings file, its backends
  and key sources, self-hosting, and what to do when it will not connect.

## Scope

This governs prose written for a human reader. It applies to files, to the body
of a commit message, and to comments and identifiers in source.

In source files, apply the spelling and dash rules and nothing else. The emoji
convention and the register guidance are for documents, not for code. For the
shape of a commit message, `conventional-commits` decides; this skill only
makes the prose inside it correct.

It does not govern chat replies.
