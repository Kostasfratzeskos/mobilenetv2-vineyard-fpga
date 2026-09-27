# images/

Σχήματα για το κείμενο. Πηγή σε SVG (vector, επεξεργάσιμο σε Inkscape).

Η διάταξη ακολουθεί το πρότυπο του επιβλέποντα: `images/<όνομα-κεφαλαίου>/<αρχείο>`,
με πλήρη διαδρομή μέσα στο `\includegraphics` — το πρότυπο **δεν** ορίζει
`\graphicspath`.

| αρχείο | τι δείχνει | πηγή RTL |
|:--|:--|:--|
| `accelerator-design/pe_array.svg` | ο pointwise MAC array: Tm=32 lanes x Tn=16 MACs, broadcast activations, per-lane weights, accumulation σε ceil(IC/Tn) κύκλους | `hardware/rtl/kernels/pe_array.v`, `mac_lane.v` |
| `template/pyrforos.svg` | ο Προμηθέας Πυρφόρος, το έμβλημα του ΕΜΠ· χρησιμοποιείται δύο φορές στη σελίδα τίτλου (40mm και 28mm) | — |

Το πρότυπο ζητούσε `pyrforos.png`· εδώ χρησιμοποιείται το `.pdf` που παράγεται
από το `.svg`, γιατί είναι διανυσματικό και ακολουθεί τον ίδιο δρόμο με τα
υπόλοιπα σχήματα.

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
