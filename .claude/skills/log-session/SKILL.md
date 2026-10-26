---
name: log-session
description: Record a work session in the project's own records - a dated entry in docs/lab_notebook.md, a DD entry in docs/design_decisions.md for each decision, and the status lines that changed. Use when a session produced a measurement, a verification result, a board run or a decision, or when asked to log, record or write up the work.
---

# Record the session

Write facts only, each with its source. Read the latest entries of each file first and match
their form.

## Lab notebook (`docs/lab_notebook.md`)
- Append the entry at the end, headed `### YYYY-MM-DD - <what happened, stated as the finding>`.
  A second entry on the same day gets `(later)` after the date.
- Say what was done, what was found, what failed and why, and what is next. Quote the tool output
  that proves each result (logits, cycle counts, slack, pass counts) in a code block.
- Mark every number that isn't a direct measurement as derived or estimated. Record failures and
  dead ends too, because the methodology chapter is written from this file.

## Design decisions (`docs/design_decisions.md`)
- A new decision gets the next sequential id. Copy the template at the top of the file: Status,
  Date, Context, Decision, Rationale, Alternatives considered, Revisit if.
- When a decision changes, add a dated note to its entry or mark it `Superseded by DD-XXX`. Never
  rewrite what the entry originally said.
- Scope decisions (dataset, model, platforms, tiers) need the supervisor. Write them as
  `Proposed` until the author confirms they were agreed.

## Status
If a result changed, update every place that states it: the "Status" paragraph of `README.md`,
the affected sub-READMEs, and `thesis/manual_numbers.tex` for `[MEASURED]` figures.

## Finish
Show the user a summary of the edits. Don't commit unless asked.
