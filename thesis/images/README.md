# images/

Σχήματα για το κείμενο. Πηγή σε SVG (vector, επεξεργάσιμο σε Inkscape).

Η διάταξη ακολουθεί το πρότυπο του επιβλέποντα: `images/<όνομα-κεφαλαίου>/<αρχείο>`,
με πλήρη διαδρομή μέσα στο `\includegraphics` — το πρότυπο **δεν** ορίζει
`\graphicspath`.

| αρχείο | τι δείχνει | πηγή RTL |
|:--|:--|:--|
| `accelerator-design/pe_array.svg` | ο pointwise MAC array: Tm=32 lanes x Tn=16 MACs, broadcast activations, per-lane weights, accumulation σε ceil(IC/Tn) κύκλους | `hardware/rtl/kernels/pe_array.v`, `mac_lane.v` |

**Λείπει:** `template/pyrforos.png`, το έμβλημα του ΕΜΠ που ζητάει το
`sections/template.tex`. Μέχρι να μπει, τα δύο `\includegraphics` της σελίδας
τίτλου είναι σχολιασμένα.

## Μετατροπή σε PDF

Το `pdflatex` **δεν** δέχεται SVG απευθείας. Το `make figures` τρέχει:

```bash
inkscape images/<κεφάλαιο>/<αρχείο>.svg --export-type=pdf \
         --export-filename=images/<κεφάλαιο>/<αρχείο>.pdf
```

Τα παραγόμενα `.pdf` δεν μπαίνουν στο git — πηγή είναι τα `.svg`.

```latex
\begin{figure}[t]
  \centering
  \includegraphics[width=\linewidth]{images/accelerator-design/pe_array.pdf}
  \caption{Ο pointwise MAC array. Τα Tm=32 lanes μοιράζονται το ίδιο
           broadcast των Tn=16 activations, ενώ κάθε lane κρατάει τα δικά
           του βάρη· P = Tm$\cdot$Tn = 512 MAC/κύκλο.}
  \label{fig:pe-array}
\end{figure}
```

## Σημειώσεις

- Το σχήμα είναι σε landscape 1240x700· σε μονόστηλο κείμενο θέλει `width=\linewidth`.
- Οι δύο δίαυλοι ξεχωρίζουν και σε ασπρόμαυρη εκτύπωση: τα activations είναι
  **συνεχής** γραμμή, τα βάρη **διακεκομμένη**.
- Τα κενά στη γραμμή των βαρών εκεί που την τέμνουν οι κατακόρυφες των activations
  σημαίνουν **μη σύνδεση** (συμβατική σημειογραφία σχηματικών).
