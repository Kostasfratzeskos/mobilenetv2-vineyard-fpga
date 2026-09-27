# ===========================================================================
# Thesis build.
#
#   make            numbers + figures + the PDF
#   make numbers    regenerate generated/numbers.tex from the repository
#   make figures    figures/*.svg -> figures/*.pdf (needs Inkscape on PATH)
#   make pdf        latexmk only
#   make watch      rebuild on save
#   make todo       list every TODO marker left in the manuscript
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

SVG := $(wildcard figures/*.svg)
PDF := $(SVG:.svg=.pdf)

TEX := $(MAIN).tex preamble_additions.tex manual_numbers.tex \
       $(wildcard sections/*.tex) $(wildcard frontmatter/*.tex)

.PHONY: all pdf numbers figures watch todo wc clean distclean

all: numbers figures pdf

# --- the PDF --------------------------------------------------------------
pdf: $(MAIN).pdf

$(MAIN).pdf: $(TEX) references.bib generated/numbers.tex $(PDF)
	$(LATEXMK) -pdf -interaction=nonstopmode -halt-on-error $(MAIN).tex

watch:
	$(LATEXMK) -pdf -pvc -interaction=nonstopmode $(MAIN).tex

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

figures/%.pdf: figures/%.svg
	$(INKSCAPE) $< --export-type=pdf --export-filename=$@

# --- writing aids ---------------------------------------------------------
todo:
	@grep -rn "TODO" sections/ frontmatter/ manual_numbers.tex || echo "no TODOs left"

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
