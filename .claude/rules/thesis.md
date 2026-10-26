---
paths:
  - "thesis/**"
---

# Thesis manuscript (`thesis/`)

The full conventions are in `thesis/README.md`. The rules below are the ones that break the build,
or the thesis's credibility, when they are missed.

## Numbers
- Never type a measured figure into the text. Use the `\th…` macros from `generated/numbers.tex`
  (written by `scripts/thesis_numbers.py`) or `manual_numbers.tex`.
- A figure a script can derive goes into `scripts/thesis_numbers.py`. Anything else goes into
  `manual_numbers.tex`, with a comment naming its source and one of the tags `[MEASURED]`,
  `[DERIVED]` or `[ESTIMATED]`. A figure that is in neither file doesn't belong in the text.
- After changing either source, run `make numbers` and check that `generated/numbers.tex` has no
  `WARNING` line. That line appears when the export and the accuracy report name different
  checkpoints.

## The template's house style
- Label prefixes: `chap:`, `sec:`, `ssec:`, `sssec:`, `tab:`, `fig:`, `eq:`, `alg:`.
- Write cross-references out: `Chapter~\ref{chap:timing}`, `Figure~\ref{fig:pe-array}`. cleveref
  isn't loaded.
- The appendices are `\chapter*`, so `\ref{appendix:…}` prints a wrong number ("11.2"). Write
  `Appendix~\hyperref[appendix:isa]{A}`, with B or C for the other two.
- Figures: the SVG source lives at `images/<chapter>/<name>.svg`. Include it by full path as the
  `.pdf` that `make figures` produces (`images/accelerator-design/pe_array.pdf`). There is no
  `\graphicspath`.
- Greek inside English text goes in `\textgreek{…}`. The Greek summary (`extended_greek.tex`)
  uses `\selectlanguage{greek}` with Latin runs in `\en{…}`. It mirrors the English chapters, so
  it is written last.
- `sections/template.tex` (the front matter) and `main.tex` belong to the school's template. Don't
  restyle them. Changes to `main.tex` are marked `<<< ADDED >>>` or `<<< FIXED >>>`.
- Never put a manual line break (`\\`, `\linebreak`) after a placeholder that is still unwritten.
  The build aborts with "There's no line here to end".

## Writing
- The chapters are impersonal: no "we", "our" or "I". Keep that voice.
- Prose is hard-wrapped at about 90 columns. Keep the wrapping of the lines you edit.
- Each chapter file opens with a comment block naming the `docs/` files it is written from. Read
  those files before writing. For anything after 2026-09-25 the sources are
  `docs/design_decisions.md` and `docs/lab_notebook.md`.
- State status exactly: which checkpoint and which platform (simulation or board) produced each
  result. Unfinished work keeps its `TODO(BOARD)` or `TODO(COMPARISON)` marker.
- Every `\cite` key must exist in `references.bib` (IEEEtran style, built with bibtex). Add a DOI
  when one exists. Cite only sources that have been checked, and never invent a reference, a page
  number or a quotation.

## Building
- Build with `make` (numbers, figures, PDF). Running latexmk directly skips the regeneration of
  `generated/numbers.tex`.
- After editing, build and read the log. `/build-thesis` has the checks.
