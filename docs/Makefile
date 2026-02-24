# Makefile for LaTeX presentation

# File names
TARGET = presentation
TEXFILE = $(TARGET).tex
PDFFILE = $(TARGET).pdf

# Compiler settings
LATEX = pdflatex
LATEX_FLAGS = -interaction=nonstopmode -halt-on-error

.PHONY: all clean clean-all show

# Default target
all: $(PDFFILE)

# Build the PDF
$(PDFFILE): $(TEXFILE)
	$(LATEX) $(LATEX_FLAGS) $(TEXFILE)
	# Run twice to resolve references and TOC
	$(LATEX) $(LATEX_FLAGS) $(TEXFILE)

# Show the presentation (macOS specific, adjust for Linux/Windows)
show: $(PDFFILE)
	open $(PDFFILE)

# Clean auxiliary files
clean:
	rm -f *.aux *.log *.nav *.out *.snm *.toc *.vrb

# Clean all generated files
clean-all: clean
	rm -f $(PDFFILE)
