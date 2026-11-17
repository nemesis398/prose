---
title: Markup stress test
tags: [fixture, markup]
author: Example Author
---

# Markup Handling

See [[Some Wikilink Targt]] and [[Another Note|an aliass]] for background. The
page https://example.org/a_path/with_underscore?x=1 is a bare URL, and so is
<https://example.org/angle> in angle brackets. A [markdown link](https://example.org/linkk "A Titel")
sits inside the sentence, and an ![image](https://example.org/imgg.png) too.

Inline math $x^2 + y^2 = z^2$ and display math:

$$
\sum_{i=0}^{n} a_i  =  b
$$

Tags like #project/alpha and #todo stay out of the way. Inline code such as
`teh_function(arg)` is skipped, and `a
wrapped span` too.

<div class="note" style="margin: 0 auto">
Inside an HTML block the text is still prose, with a typo: recieve.
</div>

<!-- a comment with a speling error and a — dash -->

<style>
.box { width: 10px; margin: 5px; }
</style>

A stray backtick ` hangs here and the rest of this line is still prose with a
mistke in it.

Footnote reference[^1] and a task list:

- [ ] open task with a typo: definately
- [x] done task
> A quote with a sentense error.

[^1]: The footnote text has an erorr too.

Final paragraph with   three spaces and a nbsp.
