# thesis/

The manuscript. **Write as you go** — draft each chapter as you finish its phase.

```bash
make            # numbers + figures + main.pdf
make numbers    # regenerate generated/numbers.tex from the repository
make todo       # what is still unwritten
```

## Before anything else: get the real template

`main.tex` and `preamble.tex` are a **placeholder** so the manuscript compiles today.
They are not the school template — that has to come from the supervisor as `.cls`/`.tex`
sources. The PDF in circulation is a render and cannot be used as a source.

When it arrives: keep the template's main file, document class and prescribed front
matter (title page, approval page, copyright page — do not retype these), `\input` the
same chapter files in the same order, and merge `preamble.tex` into its preamble.
Nothing under `chapters/` depends on the placeholder, so that is the whole port.

## Structure

| | |
|:--|:--|
| `main.tex` | document order; swap for the template's |
| `preamble.tex` | packages, language, shorthands |
| `frontmatter/` | title page, the two abstracts, acknowledgements |
| `chapters/` | one file per chapter, plus the Greek extended summary and three appendices |
| `figures/` | SVG sources; `make figures` converts them to PDF |
| `refs.bib` | 36 entries, transcribed from the template's bibliography |
| `generated/numbers.tex` | **generated** — every measured figure, as LaTeX macros |
| `manual_numbers.tex` | the few figures that are not yet derivable, each with its source |

Every chapter file opens with a comment block naming the documents in `docs/` it is
written from. The material is already written; the chapters are mostly a matter of
following those pointers.

## The rule about numbers

**No measured figure is typed into the text.** `scripts/thesis_numbers.py` recomputes
them from `software/export/manifest.json` and the Vivado reports under `build/`, and
emits `generated/numbers.tex`:

```latex
The design closes at \MHz{\thClkBoard} on the ZCU104, using \thDspAccelAxi{} DSPs
(\thDspPctAccelAxi\% of the device).
```

This is DD-019 restated for prose. That bug was an accumulator width justified by a
measurement instead of a bound: correct when taken, silently wrong five weeks later
after a retrain. A number copied by hand into a chapter fails the same way, and a
thesis is read long after the last `make`.

Anything not derivable lives in `manual_numbers.tex`, where each macro must carry a
comment naming its source and whether it is measured, derived or estimated. If a figure
is in neither file, it does not belong in the text. When something becomes derivable —
a testbench that writes its cycle count to a file — move it and delete it from there.

## Order of writing

Chapters 5 → 6 → 7 → 8 → 9 → 10 first: that work is finished and documented. Then 3 and
4, then 2, then 1 and 11. The Greek summary **last**, because it mirrors the English
chapters and writing it early guarantees rework.

Two gaps block Chapter 10 and neither is a big job:

1. **Accuracy on the leakage-free `grape_clean` split is not measured.** The only
   accuracy figures in the repository (100.00% float and int8) are from the *leaky*
   split. Run `evaluate.py` for both float and int8 and record the per-class breakdown.
2. **The 202 MHz figure is unattributed** (`docs/claude_project/05_RESULTS.md` §2).
   Either do the back-to-back re-run or quote 179.0 MHz and say why.

## Figures

Sources are SVG (vector, editable in Inkscape); `make figures` converts them to PDF,
which is what `pdflatex` wants. See [figures/README.md](figures/README.md) for the
conventions — including that the two buses in `pe_array.svg` stay distinguishable in
black and white.

`figures/` currently holds one diagram. The top-level accelerator block diagram is the
most valuable one missing.
