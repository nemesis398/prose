---
type: llm
weight: 1
---

The response gives a new entry about today's oven problem and a one-line
instruction for whoever opens the shop tomorrow. The facts it was given are:
the oven's left door seal tore at 5 am, the first batch came out pale, Mia
taped the seal for now, a new seal is ordered and arrives Thursday, and
whoever opens tomorrow checks the tape before the first bake. The language
rule it was given says: write notes in German even when the request is in
English, address the reader as lowercase `du`, keep headings in English. It
passes only if all of these hold:

- the entry and the instruction are written in German;
- the instruction addresses the reader with lowercase `du` or with an
  imperative that implies `du` (for example "Prüf ..."), and never uses `Sie`;
- any heading it adds is in English, and the existing English headings
  (`Oven Log`, `Maintenance`, `Suppliers`) are not translated;
- it states the facts listed above and invents no event, name or number; a
  connecting word the facts imply (such as "deshalb"), a calendar date worked
  out from today's date, a heading label, and text copied from the existing
  note are not inventions;
- the note text contains no em dash (U+2014), and at most one spaced en dash;
  the comments around it may name a character they removed;
- it does not claim that a tool checked the text.
