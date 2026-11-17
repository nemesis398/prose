---
max_turns: 6
allowed_tools: [Skill]
---

Clean up this README excerpt for my tool. Return the full repaired text. You
cannot run anything here, so work from the text alone.

````markdown
# crumbtray

crumbtray is a small command line tool for bakeries — it turns a day's orders
into a baking plan. It reads a CSV file — one line per order — and prints a
sorted list of what to bake first.

## Install

Download the binary from the releases page and put it on your PATH — no
installer is needed. It runs on Linux and macOS — Windows is not supported yet.

## Usage

Run `crumbtray orders.csv` and it prints the plan. Add `--oven 2` to plan for
two ovens at once. The default is one.
````
