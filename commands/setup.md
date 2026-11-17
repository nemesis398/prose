---
description: Install the prose checker and choose where LanguageTool may send your text
---

# Set up prose

Install `prose-check` if it is missing or out of date, then ask the user where
LanguageTool may send their text, and write the answers to the settings file.
Ask every question in the question dialog (`AskUserQuestion`), never as prose
in a message. The dialog needs two to four options per question, and adds a
free-text answer (Other) on its own, which is how the user types a URL or a
name. Where a question below lists fewer than two options, as on a fresh
install, add "Type it in Other" with the description "pick Other below and
type the value"; if the user picks that option itself, ask again.

## 1. The binary

Run this to see what is installed and what the plugin expects:

```sh
root="${CLAUDE_PLUGIN_ROOT}"
want=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$root/.claude-plugin/plugin.json" | sed 1q)
case $(uname -s) in
MINGW* | MSYS* | CYGWIN*) bin="$root/skills/prose/bin/prose-check.exe" ;;
*) bin="$root/skills/prose/bin/prose-check" ;;
esac
have=$("$bin" --version 2>/dev/null)
printf 'want: %s\nhave: %s\nbin:  %s\n' "$want" "${have:-nothing}" "$bin"
```

Shell variables do not carry over from one command to the next. In the
commands below, `<want>` stands for the version printed after `want:`, and
`<bin>` for the path printed after `bin:`.

If `have` is exactly `prose-check <want>`, go on to step 2. Otherwise install
the plugin's version. Always pass `PROSE_VERSION=<want>`: the installers
prefer `PROSE_VERSION` over the manifest, so one left in the user's
environment would install another version, and the comparison would never
match.

- Linux and macOS:

  ```sh
  PROSE_VERSION=<want> sh "${CLAUDE_PLUGIN_ROOT}/skills/prose/install"
  ```

- Windows, where `uname -s` starts with `MINGW`, `MSYS` or `CYGWIN`. The
  POSIX `install` refuses Windows, and the default execution policy blocks
  scripts, so call PowerShell like this:

  ```sh
  PROSE_VERSION=<want> powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/skills/prose/install.ps1"
  ```

Then run the first block again, once. If the versions still differ, or the
installer failed, stop: show the installer's last line and say that the
checker is not installed, so no text can be checked yet. Do not retry in a
loop. When the installer says there is no release for this version, the
checkout is newer than its release; `make build` in the plugin's repository
builds the checker from source.

## 2. What is stored

Read the settings file, if it exists, so that each question can offer the
stored value as its first option:

```sh
cat "${XDG_CONFIG_HOME:-$HOME/.config}/prose/config.json" 2>/dev/null || echo "no settings file yet"
```

Then run `"<bin>" --rules`. If it exits 2, the file is broken, and the line
it printed says how:

- **Setup cannot repair it** when the line says "is not valid JSON", "must be
  a JSON object", "cannot be read", "is not a regular file" or "is too big",
  or names `ignoreWords`. Setup merges into the stored file, and it never
  writes a result that still fails, so it refuses these. Stop here: show the
  line, and tell the user to fix the file or move it aside by hand, then run
  `/prose:setup` again.
- **The questions below repair it** when the line names `languageRule` or a
  key under `languagetool`. For the key it names, do not offer the stored
  value: step 6 must write a new value for that key, or `null`. A broken
  `username` or `keyItem` under another backend than `premium` gets `null`.

## 3. The backend

Ask which backend checks grammar and spelling. Give each option one line on
where the text goes, as below. Mark the stored backend "(current)". Mark no
option as recommended: where the user's text may go is their decision.

| Option | Line to show |
| --- | --- |
| `none` | Nothing leaves this machine. The rules run; grammar is not checked, and English spelling only through hunspell when it is installed (never on Windows). |
| `public` | Your text goes to LanguageTool's free public server, `api.languagetool.org`. No account; rate-limited, free rules only. |
| `premium` | Your text goes to LanguageTool's Premium API, `api.languagetoolplus.com`, under your account. Needs the account's login and API key. |
| `server` | Your text goes to the LanguageTool server at the URL you give, such as one you run yourself. |

## 4. The backend's values

For `server`, ask for the URL. Offer the stored URL first when there is one,
then `http://localhost:8081`, where the Docker command in
`skills/prose/references/languagetool.md` publishes a local server, then
"Type it in Other". The user types any other URL as free text. It must start with `http://` or `https://`;
ask again if it does not.

For `premium`, ask two questions.

1. **The account's login.** Offer the stored username when there is one,
   then "Type it in Other", then "Leave it unset, I export
   `LANGUAGETOOL_USERNAME`". The user types the login as free text.
2. **Where the API key comes from.** Never ask for the key, never show it, and
   never write it anywhere. The checker reads it from the first of these
   sources that holds it:
   - **The environment variable `LANGUAGETOOL_API_KEY`.** Nothing to write.
     The variable has to be set where Claude Code starts.
   - **A Bitwarden item, read with `rbw`.** Ask for the item's name or id as a
     follow-up question, offering the stored `keyItem` first, then
     `LanguageTool` (an item named after the service), then "Type it in
     Other". The key is the item's password. The checker reads it only while `rbw` is unlocked, and
     never prompts.
   - **The file `credentials`** beside `config.json`, holding only the key, at
     mode 600. Tell the user to create it in their own terminal, not in this
     session, for example with
     `( umask 077; cat > "${XDG_CONFIG_HOME:-$HOME/.config}/prose/credentials" )`,
     pasting the key and ending with Ctrl-D.

If the user pastes a key into the conversation anyway, do not store it or
repeat it. Say that it is now in the transcript, and that they may want to
replace it in their LanguageTool account.

## 5. The language rule

Ask for the rule that `prose-check --rules` prints before every text: which
language a text is written in, and when a German reader gets `Sie`. Offer the
stored rule first when there is one, then "No rule", which means: write in the
language of the request, with lowercase `du` for German readers. Then offer an
example the user may take as it is: "German for notes and mails, English for
code and commit messages; Sie for customers". The user types any other rule as
free text.

## 6. Writing the file

Build one JSON object with the answers and pipe it to the checker. It merges
the object into the settings file and keeps every key the object leaves out.
A key set to `null` is deleted.

- Always set `languagetool.backend`.
- Set `languagetool.server` to the URL for `server`, and to `null` for every
  other backend.
- For `premium`, set `username` when the user gave one, and `keyItem` when the
  key comes from rbw.
- Set `languageRule` to the rule, or to `null` for "No rule". Leave it out
  when the user kept the stored one.
- Write every key that step 2 found broken, as it says there.
- Never add a key such as `apiKey`, `key`, `password` or `token`; the checker
  refuses them.

Escape `"` and `\` in every string, so that the object is valid JSON. For
example:

```sh
"<bin>" --setup --values-stdin <<'JSON'
{"languagetool": {"backend": "server", "server": "http://localhost:8081"}, "languageRule": null}
JSON
```

It prints `wrote <path>` and exits 0. On exit 2 the file is unchanged; show
what it printed.

## 7. Checking the result

Run `"<bin>" --selftest` and show its output. It names the backend and where
each value came from. For any backend but `none` it sends one fixed test
sentence, never the user's text, to see whether the backend answers. If it
exits 2, say which value is missing and where to set it, using the line it
printed.

Finish with what the setup changed: the backend, where the text now goes,
and the language rule. Name the checker's path (`<bin>`) too, for a user who
wants to run it in a terminal; it changes with every plugin update.
