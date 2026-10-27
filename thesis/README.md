# thesis/

The manuscript. **Write as you go** — draft each chapter as you finish its phase.

```bash
make            # numbers + figures + main.pdf
make numbers    # regenerate generated/numbers.tex from the repository
make todo       # what is still unwritten
```

## Relationship to the supervisor's template

`main.tex` **is** the template's `main.tex`, changed in four places — three marked
`<<< ADDED >>>`, one `<<< FIXED >>>`:

1. `\input{preamble_additions}` at the end of the preamble — siunitx and all the
   number macros this manuscript needs. Keeping them in their own file means a new
   version of the template costs you three marked lines, not a preamble merge.
2. The `\hypersetup` title, author and subject. The template shipped with the previous
   author's metadata (*Dataflow Optimized Reconfigurable Acceleration for FEM-based CFD
   Simulations*, Ferikoglou Aggelos), which would otherwise be embedded in your
   submitted PDF.
3. Three extra `\input` lines — verification, timing closure and integration are
   chapters of their own. See *Structure* below.
4. `\usepackage{algorithmic}` commented out. **The template does not compile as
   shipped**: it loads both `algorithmic` and `algpseudocode`, and algpseudocode
   (algorithmicx) defines its own `algorithmic` environment, so the build aborts
   with `Command \algorithmic already defined`. Nothing here uses either package.

`sections/template.tex` is the template's prescribed front matter — title page,
approval page, copyright page, both abstracts, acknowledgements and the contents
lists — with the names, title, committee and dates changed to yours. The structure
and wording are the school's; do not restyle them. Three things there still need
filling in: the two other committee members and their ranks, the approval date, and
the abstracts themselves.

It carries one `<<< FIXED >>>` of its own: the English abstract had `\\` followed by
`\linebreak\linebreak`, which need a line to act on. With the abstract still a
`% TODO` there is none, so the build aborted with *There's no line here to end.*
The Greek abstract above it has no such pair, and the English one now matches.

### Conventions taken from the template's example chapters

These are the supervisor's house style, followed throughout the scaffold:

- **Labels** are `chap:`, `sec:`, `ssec:`, `sssec:`, `tab:`, `fig:`, `eq:`, `alg:`.
- **Cross references are written out**: `Chapter~\ref{chap:timing}`,
  `Figure~\ref{fig:pe-array}`. cleveref is *not* loaded and *not* used.
- **Graphics live at `images/<chapter-name>/<file>`**, referenced by full path.
  The template sets no `\graphicspath`.
- **Appendices** use `\appendix` then `\chapter*{Appendix A: …}` with an explicit
  `\addcontentsline`, not the `appendices` environment — even though the `appendix`
  package is loaded.
- **Greek** goes in `\textgreek{…}` inside English text; a whole Greek chapter uses
  `\selectlanguage{greek}` with Latin runs in `\en{…}`.

The NTUA seal lives at `images/template/pyrforos.svg` and is converted to PDF by
`make figures`, like every other figure. The template's original referenced a `.png`;
vector prints better and needs no second pipeline.

## Structure

| | |
|:--|:--|
| `main.tex` | the template's, plus three marked additions |
| `preamble_additions.tex` | siunitx, the number macros, shorthands |
| `sections/` | front matter (`template.tex`), one file per chapter, the Greek summary, three appendices |
| `images/` | SVG sources under `images/<chapter>/`; `make figures` converts them to PDF |
| `references.bib` | 58 entries: the 36 transcribed from the template's bibliography, plus the edge-device platforms, runtimes and the closest related deployment (DD-036), and the sources of the introduction's motivation (Chapter 1) |
| `generated/numbers.tex` | **generated** — every measured figure, as LaTeX macros |
| `manual_numbers.tex` | the few figures that are not yet derivable, each with its source |

Every chapter file opens with a comment block naming the documents in `docs/` it is
written from. The material is already written; the chapters are mostly a matter of
following those pointers.

One caution about those pointers: some name files in `docs/claude_project/`. That
folder is a gitignored summary written for a claude.ai Project, derived from the records
and dated in its `00_START_HERE.md`; it may lag or simplify them, so it is never a
source. Follow it to the DD entries and notebook dates it cites. For anything after 25
September, `docs/design_decisions.md` and `docs/lab_notebook.md` are the sources.

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

`profiling` → `accelerator_design` → `verification` → `timing_closure` → `integration`
→ `exper_eval` first: that work is finished and documented. Then `background` and
`exper_setup_dev_tools`, then `related_work`, then `introduction` and
`conclusion_and_future_work`. `extended_greek` **last**, because it mirrors the English
chapters and writing it early guarantees rework.

Two gaps block Chapter 10:

1. **The 202 MHz figure is unattributed** (`docs/lab_notebook.md`, 2026-09-24, Phase 4).
   Either do the back-to-back re-run or quote 179.0 MHz and say why.
2. **Part of Chapter 10 is not measured yet.** Measured on the board so far: the
   bare-metal known answer (2026-10-07) and, under Linux (2026-10-22), all four known
   answers bit-exact at 6.659 ms per image, with the live camera running. Those numbers
   are `[MEASURED]` macros in `manual_numbers.tex` (`\thBoard*`). They were taken with
   the previous model: repeating the known answers on the board with the redeployed one
   is marked `TODO(BOARD)`. Still missing: the live loop's own numbers (`\thCamFps`,
   `\thCamFrontMs` print as red TODOs until the console output of a live run is copied
   in), the power of all three platforms, and the Raspberry Pi 4 and Jetson Nano
   comparison (DD-036). Each edge-device figure needs a report `scripts/thesis_numbers.py`
   can read before it can appear in the text.

A third gap closed on 2026-10-23: the accuracy (DD-034) was measured on a retrained
checkpoint the hardware did not run. The redeploy of DD-036 put that checkpoint on every
platform. `\thCkptSha` and `\thAccCkptSha` are the same now, the WARNING line in
`numbers.tex` is gone, and the accumulator figures that used to be copied by hand are
generated by `thesis_numbers.py` from the export.

The comparison adds to the order above rather than changing it: its setup goes into
`exper_setup_dev_tools`, its results into `exper_eval`, and its literature into
`related_work`.

## Figures

Sources are SVG (vector, editable in Inkscape); `make figures` converts them to PDF,
which is what `pdflatex` wants. See [images/README.md](images/README.md) for the
conventions — including that the two buses in `pe_array.svg` stay distinguishable in
black and white.

`images/accelerator-design/` holds the seven figures of the architecture chapter,
the top-level block diagram among them. Still missing: the board's Linux camera path
(DD-035) for the integration chapter, and the comparison charts — latency and energy
per inference across the three platforms (DD-036) — for the evaluation.
