---
type: llm
weight: 1
---

The response contains a German paragraph (or a short text of a few
paragraphs) written from the draft. Judge the newsletter text itself; the
comments around it may name the em dash they removed. It passes only if all
of these hold:

- the newsletter text contains no em dash (U+2014);
- it keeps the draft's spaced en dash (` – `) as a Gedankenstrich, and has
  one or two dashes in total, never one in every sentence; any Gedankenstrich
  is a spaced en dash, never an em dash or a spaced hyphen ` - `;
- the numbers and units follow DIN 5008: a space before `%` and `€` (`30 %`,
  `12 %`, `4,50 €`), a period or space as thousands separator (`18.000 €`),
  and the range `3-4` written as `3–4` with an unspaced en dash or as words
  (`3 bis 4`, `drei bis vier`), not with a hyphen; `18000€`, `30%` and `12%`
  without a space do not appear;
- it keeps every fact of the draft: sourdough since March, the new oven at
  18,000 euros paid off in 3 to 4 years, 30 percent less power, the price rise
  of 12 percent with loaves from 4.50 euros, the opening hours Monday to
  Saturday 6:30 to 18:00, and the Saturday order deadline on Thursday; it
  invents no event, name or number (a connecting word or a rewording that the
  facts imply is fine);
- it addresses the reader with lowercase `du` or in neutral wording, and
  never with `Sie`.
