# ===========================================================================
# Thesis build.
#
#   make            numbers + figures + the PDF
#   make numbers    regenerate generated/numbers.tex from the repository
#   make figures    images/*/*.svg -> .pdf (needs Inkscape on PATH)
#   make pdf        latexmk only
#   make watch      rebuild on save
#   make todo       list every TODO marker left in the manuscript
#   make check      pre-submission: seal, TODOs, generated numbers
#   make wc         word count of the body text
#   make clean      remove build artefacts, keep the PDF
#   make distclean  remove the PDF and the generated figures too
#
# On Windows, run this from Git Bash (or use `mingw32-make`).
# ===========================================================================

MAIN      := main
PYTHON    ?= python
LATEXMK   ?= latexmk
INKSCAPE  ?= inkscape

# Graphics follow the template's layout: images/<chapter-name>/<file>.
SVG := $(wildcard images/*/*.svg)
PDF := $(SVG:.svg=.pdf)

TEX := $(MAIN).tex preamble_additions.tex manual_numbers.tex \
       $(wildcard sections/*.tex)

.PHONY: all pdf numbers figures watch todo check wc clean distclean

all: numbers figures pdf

# --- the PDF --------------------------------------------------------------
pdf: $(MAIN).pdf

$(MAIN).pdf: $(TEX) references.bib generated/numbers.tex $(PDF)
	$(LATEXMK) -pdf -synctex=1 -interaction=nonstopmode -halt-on-error $(MAIN).tex

watch:
	$(LATEXMK) -pdf -synctex=1 -pvc -interaction=nonstopmode $(MAIN).tex

# --- the numbers ----------------------------------------------------------
# Regenerated unconditionally: the Vivado reports and the manifest live
# outside this directory and a stale numbers.tex is exactly the failure this
# whole mechanism exists to prevent.
.PHONY: generated/numbers.tex
numbers: generated/numbers.tex

generated/numbers.tex:
	$(PYTHON) ../scripts/thesis_numbers.py

# --- figures --------------------------------------------------------------
# pdflatex cannot read SVG. Convert once here rather than relying on
# -shell-escape and the `svg' package at build time.
figures: $(PDF)

images/%.pdf: images/%.svg
	$(INKSCAPE) $< --export-type=pdf --export-filename=$@

# --- writing aids ---------------------------------------------------------
todo:
	@grep -rn "TODO" sections/ manual_numbers.tex || echo "no TODOs left"

# Run before handing the PDF in. The title page's seal is behind an
# \IfFileExists guard so drafts still build without it - which means a missing
# seal is silent, and silent is exactly how it reaches the printer.
check:
	@test -f images/template/pyrforos.svg \
	  || echo "MISSING: images/template/pyrforos.svg (the NTUA seal)"
	@test -f images/template/pyrforos.pdf \
	  || echo "MISSING: images/template/pyrforos.pdf - run 'make figures'"
	@grep -rqn "TODO" sections/ manual_numbers.tex \
	  && echo "TODOs remain - run 'make todo'" || true
	@test -f generated/numbers.tex \
	  || echo "MISSING: generated/numbers.tex - run 'make numbers'"

wc:
	@which texcount > /dev/null 2>&1 \
	  && texcount -inc -sum -q $(MAIN).tex \
	  || echo "texcount not installed"

# --- cleaning -------------------------------------------------------------
clean:
	$(LATEXMK) -c $(MAIN).tex
	rm -f $(MAIN).bbl $(MAIN).run.xml

distclean: clean
	$(LATEXMK) -C $(MAIN).tex
	rm -f $(PDF) generated/numbers.tex
