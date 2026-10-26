---
name: build-thesis
description: Build the thesis PDF and check the result. Regenerates the number macros and the figures, runs latexmk, then reads the log for errors and undefined references or citations and lists the TODO markers. Use after editing anything in thesis/, after scripts/thesis_numbers.py or manual_numbers.tex changes, or when asked to build, compile or check the thesis.
---

# Build and check the thesis

Run in the Bash tool (Git Bash) from the repository root. PowerShell has no `make`.

1. **Build:** `make -C thesis`. It regenerates `generated/numbers.tex`, converts changed SVGs to
   PDF, and runs latexmk with `-halt-on-error`.
2. **If the build fails,** find the first error with `grep -n -m5 '^!' thesis/main.log`, read the
   lines after it, fix the cause, and build again. Known causes:
   - `Command \algorithmic already defined`: `algorithmic` was re-enabled in `main.tex`. It
     clashes with `algpseudocode`.
   - `There's no line here to end`: a `\\` or `\linebreak` follows an empty placeholder.
   - `CreateProcess ... failed` during `make figures`: Inkscape isn't on PATH. Its directory is
     `C:\Program Files\Inkscape\bin`.
   - latexmk can't find Perl: build by hand inside `thesis/` with `pdflatex main`, then
     `bibtex main`, then `pdflatex main` twice. The bibliography uses bibtex, not biber.
3. **Check the log of a successful build:**
   - `grep -n -i 'undefined' thesis/main.log` lists undefined references and citations. Fix each
     one; they are errors, not warnings to report.
   - The page count: `grep -o 'Output written on main.pdf ([0-9]* pages' thesis/main.log`.
   - One known warning is harmless: "destination with the same identifier (name{page.3})" comes
     from the template's front matter.
4. **Check the numbers:** `grep -n WARNING thesis/generated/numbers.tex` must print nothing. A
   WARNING means the export and the accuracy report name different checkpoints.
5. **List open work:** `make -C thesis todo` shows what is still unwritten. Before submission, run
   `make -C thesis check`.
6. **Report** the page count, every error or new warning with its line, and the number of TODOs.
   Show the commands and their output. "It builds" alone isn't evidence.
