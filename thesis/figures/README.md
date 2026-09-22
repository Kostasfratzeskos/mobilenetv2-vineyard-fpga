# thesis/figures/

Σχήματα για το κείμενο. Πηγή σε SVG (vector, επεξεργάσιμο σε Inkscape).

| αρχείο | τι δείχνει | πηγή RTL |
|:--|:--|:--|
| `pe_array.svg` | ο pointwise MAC array: Tm=32 lanes x Tn=16 MACs, broadcast activations, per-lane weights, accumulation σε ceil(IC/Tn) κύκλους | `hardware/rtl/kernels/pe_array.v`, `mac_lane.v` |

## Ένταξη σε LaTeX

Το `pdflatex` **δεν** δέχεται SVG απευθείας. Δύο δρόμοι:

**1. Μετατροπή σε PDF μία φορά** (προτιμότερο — δεν χρειάζεται `-shell-escape`):

```bash
inkscape pe_array.svg --export-type=pdf --export-filename=pe_array.pdf
```

```latex
\begin{figure}[t]
  \centering
  \includegraphics[width=\linewidth]{figures/pe_array.pdf}
  \caption{Ο pointwise MAC array. Τα Tm=32 lanes μοιράζονται το ίδιο
           broadcast των Tn=16 activations, ενώ κάθε lane κρατάει τα δικά
           του βάρη· P = Tm$\cdot$Tn = 512 MAC/κύκλο.}
  \label{fig:pe_array}
\end{figure}
```

**2. Απευθείας SVG** με το πακέτο `svg` (θέλει `pdflatex -shell-escape` και Inkscape στο PATH):

```latex
\usepackage{svg}
...
\includesvg[width=\linewidth]{figures/pe_array}
```

## Σημειώσεις

- Το σχήμα είναι σε landscape 1240x700· σε μονόστηλο κείμενο θέλει `width=\linewidth`
  και πιθανόν `\begin{figure*}` αν το κείμενο είναι δίστηλο.
- Οι δύο δίαυλοι ξεχωρίζουν και σε ασπρόμαυρη εκτύπωση: τα activations είναι
  **συνεχής** γραμμή, τα βάρη **διακεκομμένη**.
- Τα κενά στη γραμμή των βαρών εκεί που την τέμνουν οι κατακόρυφες των activations
  σημαίνουν **μη σύνδεση** (συμβατική σημειογραφία σχηματικών).
