# Deutsch

The rules below are the ones that actually go wrong in generated German, not a
grammar course. LanguageTool catches a good share of them, which is why the
checker exists, but it misses compounds and register almost entirely.

## Komma

German commas are structural, not rhythmic. English puts a comma where the
sentence breathes. German puts one where a clause ends. Copying English habits
is the most common failure.

**Every subordinate clause is fenced off**, on both sides if it sits in the
middle.

```text
Ich weiß, dass es funktioniert.
Der Server, der im Keller steht, läuft seit Monaten.
Wenn das Backup durchläuft, ist alles gut.
```

**No comma before `und` or `oder` in a list.** The English serial comma does
not exist here and is the clearest sign of translated text.

```text
falsch   Äpfel, Birnen, und Bananen
richtig  Äpfel, Birnen und Bananen
```

Between two full main clauses joined by `und`, a comma is optional. Use it only
when the sentence is genuinely hard to parse without it.

**Always a comma before `aber`, `sondern`, `doch`, `jedoch`, `allerdings`.**

**Infinitive with `zu`** takes a comma when introduced by `um`, `ohne`,
`statt`, `anstatt`, `außer`, `als`, when it depends on a noun, or when a
correlate points at it. Otherwise it is optional, and a comma is still allowed
for clarity.

```text
Wir haben umgestellt, um Kosten zu sparen.
Er hat vergessen(,) das Backup zu prüfen.
```

**`als` and `wie`** take a comma only in front of a full clause.

```text
Er ist größer als ich.
Es dauerte länger, als ich gedacht hatte.
```

**`sowie` never takes one.**

## das und dass

`das` is an article, a demonstrative or a relative pronoun, and can always be
swapped for `dieses`, `jenes` or `welches`. `dass` is a conjunction and cannot.
That substitution is the whole test.

```text
Das Backup, das gestern lief, war vollständig.   (dieses / welches)
Ich weiß, dass das Backup gelaufen ist.          (no substitution possible)
```

## ss und ß

After a **short** vowel: `ss`. After a **long** vowel or a diphthong: `ß`.

```text
ss   dass, muss, Fluss, Kuss, wissen, lassen, Prozess, Adresse
ß    Straße, Fuß, groß, heißen, weiß, außer, Maß, schließen
```

This style writes German German, so `ß` stays. Swiss orthography drops it,
which is not the convention here.

## Groß- und Kleinschreibung

Nominalizations are capitalized, and this is where generated German slips
most often.

```text
das Wichtigste, das Beste, alles Gute, etwas Neues, nichts Besonderes
im Folgenden, im Allgemeinen, im Einzelnen, im Voraus, des Weiteren
beim Schreiben, zum Testen, das Laufen, ohne Zögern
```

After `etwas`, `nichts`, `viel`, `wenig`, `alles`, the following adjective is a
noun and is capitalized.

Times of day after a day reference are capitalized: `heute Morgen`, `gestern
Abend`. The adverbs are not: `morgens`, `abends`, `montags`.

Adjectives derived from proper names stay lowercase unless they are part of a
name: `die deutsche Sprache`, but `die Deutsche Bahn`.

Address form: `du`, `dich`, `dein` lowercase, per current Duden and per this
style. `Sie`, `Ihnen`, `Ihr` capitalized. The language rule that
`prose-check --rules` prints says when a reader gets `Sie`.

## Komposita

German compounds are written as **one word**. Splitting them is the
Deppenleerzeichen, and it is the single most visible German error in text that
was drafted in English.

```text
falsch   Netzwerk Übersicht, Datenbank Server, Sicherheits Konzept
richtig  Netzwerkübersicht, Datenbankserver, Sicherheitskonzept
```

Hyphenate when the compound contains an abbreviation, a proper name, a number,
or when three or more parts would become unreadable.

```text
E-Mail-Adresse, IT-Sicherheit, Linux-Kernel, 24-Stunden-Dienst
Cookie-Banner, Error-Tracking, DSGVO-Konformität
```

Loanwords take either form as long as one is held consistently within a
document: `Cloud-Dienst` or `Clouddienst`, `Software-Entwicklung` or
`Softwareentwicklung`.

Watch the Fugen-s: `Sicherheitskonzept`, `Arbeitsplatz`, `Betriebssystem`.

## Fälle

`wegen`, `während`, `trotz`, `statt`, `aufgrund`, `innerhalb`, `außerhalb` take
the genitive in written German. The dative is spoken usage and reads as
careless in a document.

```text
falsch   wegen dem Wetter, trotz dem Fehler, während dem Betrieb
richtig  wegen des Wetters, trotz des Fehlers, während des Betriebs
```

## Zahlen, Einheiten, Daten

Per DIN 5008, and the checker enforces the first three.

| | |
| --- | --- |
| Tausender | `5.000`, `1.250.000` |
| Dezimal | `3,5` |
| Prozent | `40 %` with a space |
| Temperatur | `20 °C` with a space |
| Währung | `35 €`, in tables `35,00 €` |
| Datum | `27.07.2026` or ISO `2026-07-27` |
| Uhrzeit | `14:30 Uhr` |
| Bereiche | `10–40 %`, en dash without spaces |
| Paragraf | `§ 25 TDDDG`, space after the sign |
| Abkürzungen | `z. B.`, `d. h.`, `u. a.`, `i. d. R.` with spaces |

## Anführungszeichen

German uses `„Text“`, low-high. The alternative is `»Text«`. Nested quotes use
the single form `‚Text‘`.

In markdown notes straight quotes are fine and are what most notes use. What
matters is not mixing both inside one document, which the checker reports.

## Anglizismen

Keep established technical terms. Nobody says `Rechnerwolke`, and forcing a
translation reads worse than the loanword.

Genders worth having right: `der Server`, `der Router`, `der Container`, `der
Host`, `die Cloud`, `die Firewall`, `die Pipeline`, `das Backup`, `das Update`,
`das Deployment`.

Plurals stay German: `die Server`, `die Router`, `die Container`. Not
`Servers`.

Where an English verb produces an ugly participle, use the German verb:
`heruntergeladen` rather than `gedownloadet`.

## Maschinelles Deutsch

These are structural, so a word filter will not remove them.

**Floskel-Einstiege.** `In der heutigen schnelllebigen Zeit`, `Es ist wichtig
zu beachten, dass`, `Es gilt zu beachten`. Delete the opener and keep the fact.

**Nominalstil.** German makes this easy and it drains every sentence. Prefer
the verb.

```text
schwer   Die Durchführung der Migration erfolgt am Freitag.
gut      Wir migrieren am Freitag.
schwer   Eine Überprüfung der Konfiguration ist erforderlich.
gut      Wir prüfen die Konfiguration.
```

**Bindewörter als Füllung.** `darüber hinaus`, `des Weiteren`, `zudem`,
`ferner`, `überdies`. One is fine. Four in a row and they stop connecting
anything. The checker counts them.

**Zusammenfassungen, die nichts hinzufügen.** `Zusammenfassend lässt sich
sagen`, and a `## Fazit` heading on a note that is already six lines long.

**Passiv ohne Grund.** `Es wird empfohlen, das Backup zu prüfen` hides who
recommends it. Write `Prüf das Backup` or `Ich empfehle, das Backup zu prüfen`.

**Paarformeln.** `sowohl ... als auch`, `nicht nur ... sondern auch` used as
default sentence architecture rather than because the contrast is real.

**Unverbindliche Adjektive.** `umfangreich`, `leistungsstark`, `nahtlos`,
`vielfältig`. Replace with the number.

## Register

The German register to match is terse and decision-first. A comparison goes
in a table. The decision goes in bold. Something superseded gets a `→` line pointing at
what replaced it, rather than being deleted. Match that shape and resist
turning a note into an essay.
