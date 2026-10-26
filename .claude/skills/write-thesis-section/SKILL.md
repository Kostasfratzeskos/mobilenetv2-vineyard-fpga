---
name: write-thesis-section
description: Draft or revise a section of the thesis from the repository's own records. Every figure is a macro, and every claim traces to a DD entry, a lab-notebook entry, a report or the code. Use when asked to write, draft, extend, rewrite or fix a chapter or section in thesis/sections/.
argument-hint: "[chapter file or section label]"
---

# Write or revise a thesis section

1. **Locate.** Open the chapter in `thesis/sections/` and find the section by its label. Read the
   chapter's opening comment block, which names the `docs/` files the chapter is written from.
   Read the sections around it too, so the new text continues them instead of repeating them.
2. **Gather.** Read those sources, and the DD entries and dated notebook entries they point to.
   For anything after 2026-09-25 the sources are `docs/design_decisions.md` and
   `docs/lab_notebook.md`; `docs/claude_project/` is stale. If the records don't support something
   the section needs, stop and tell the user what is missing instead of writing around it.
3. **Numbers.** Find the macro for every figure, e.g. with
   `grep -n '<keyword>' thesis/generated/numbers.tex thesis/manual_numbers.tex`.
   - A figure that a script can derive but has no macro yet: add it to
     `scripts/thesis_numbers.py`, then run `make -C thesis numbers`.
   - A figure that can't be derived: add it to `thesis/manual_numbers.tex` with a comment naming
     its source and the tag `[MEASURED]`, `[DERIVED]` or `[ESTIMATED]`.
   - Never type the digits into the prose.
4. **Claims.** Every technical claim must rest on a record. State status exactly: which
   checkpoint, simulation or board, which platform. Work that isn't done yet keeps a
   `TODO(BOARD)`-style marker.
5. **Citations.** Reuse the keys in `thesis/references.bib`. A new entry needs a source that has
   actually been checked, with its DOI when there is one. Never invent a reference, a page number or
   a quotation.
6. **Write.** Follow the thesis rules in `.claude/rules/thesis.md`: impersonal voice, about 90
   columns, the label prefixes, written-out cross-references, and `\hyperref` for appendices.
7. **Build.** Run `/build-thesis` and fix every undefined reference or citation it reports.
8. **Report.** List the sections changed, the sources each new paragraph rests on, the macros and
   bib entries added, and the TODO markers left. Offer a review by the `thesis-fact-checker`
   agent. Don't commit unless asked.
