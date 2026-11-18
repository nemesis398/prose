---
max_turns: 6
allowed_tools: [Skill]
---

Add a short entry to my bakery note about today's oven problem, and a one-line
instruction for whoever opens the shop tomorrow. Below is my current note, and
the output of `prose-check --rules` that you would run before writing. You
cannot run anything here.

`prose-check --rules` printed:

```text
Write notes in German, even when my request is in English, and address the reader as du. Keep headings in English. Write READMEs and code comments in English.
German readers: lowercase du unless the rule says otherwise.
```

The note, `Bäckerei Ofen.md` (German prose under English headings):

```markdown
# Oven Log

## Maintenance

Der Ofen wird alle zwei Wochen entkalkt. Das machst du am Montagmorgen vor
dem ersten Backen.

## Suppliers

Das Mehl kommt von der Mühle im Nachbardorf, geliefert wird dienstags.
```

What happened today, in my own shorthand:

- 🔧 Problem: the oven's left door seal tore at 5 am, so the first batch came
  out pale.
- 🩹 Now: Mia taped it for now.
- 📦 Next: a new seal is ordered and arrives Thursday.
- ✅ Tomorrow: whoever opens should check the tape before the first bake.
