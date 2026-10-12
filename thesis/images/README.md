# images/

Σχήματα για το κείμενο. Πηγή σε SVG (vector, επεξεργάσιμο σε Inkscape).

Η διάταξη ακολουθεί το πρότυπο του επιβλέποντα: `images/<όνομα-κεφαλαίου>/<αρχείο>`,
με πλήρη διαδρομή μέσα στο `\includegraphics` — το πρότυπο **δεν** ορίζει
`\graphicspath`.

| αρχείο | τι δείχνει | πηγή RTL |
|:--|:--|:--|
| `accelerator-design/accel_top.svg` | το top-level block diagram, το **πρώτο** σχήμα του κεφαλαίου: ο sequencer, οι πέντε μηχανές (μία ενεργή ανά εντολή), το ένα κοινό output stage και η μία activation pool που ξαναδιαβάζεται ως είσοδος του επόμενου layer | `hardware/rtl/control/accel_top.v`, `top_seq.v` |
| `accelerator-design/pe_array.svg` | ο pointwise MAC array: Tm=32 lanes x Tn=16 πολλαπλασιαστές, ένα broadcast των activations, ένα bank βαρών ανά lane, και το κοινό output stage που γράφει πίσω στην activation pool | `hardware/rtl/kernels/pe_array.v`, `mac_lane.v`, `hardware/rtl/control/wgt_buffer.v` |
| `accelerator-design/dw_array.svg` | ο depthwise array: Tc=16 ανεξάρτητα lanes, ένα ανά κανάλι, με 9 πολλαπλασιαστές και adder tree το καθένα — **χωρίς** accumulator και **χωρίς** καμία σύνδεση μεταξύ τους· δείχνει και τη μετάθεση των δύο διατάξεων (window tap-major από το line buffer, βάρη channel-major) | `hardware/rtl/control/dw_array.v`, `hardware/rtl/kernels/dwconv3x3.v`, `hardware/rtl/control/line_buffer.v` |
| `accelerator-design/stem_array.svg` | ο stem engine: TS=8 lanes που διαβάζουν **το ίδιο** παράθυρο 27 taps (3 κανάλια x 3x3) — broadcast όπως το `pe_array`, όχι ανά lane όπως το `dw_array`· η μετάθεση γίνεται **μία φορά** πριν το broadcast, και κάθε παράθυρο σαρώνεται σε 4 oc-tiles που συναρμολογούνται σε μία εγγραφή 32 καναλιών | `hardware/rtl/control/stem_array.v`, `stem_feeder.v`, `hardware/rtl/kernels/conv3x3_std.v` |
| `accelerator-design/requantize.svg` | μία requantization lane ως τέσσερα register stages (acc+bias, xM0, round+shift, clamp)· κάθε παράμετρος μπαίνει στο stage που την καταναλώνει (L-7), και μόνο το clamp στενεύει τον datapath από τα 59 bits στα int8 | `hardware/rtl/kernels/requantize.v`, `bias_add.v`, `hardware/rtl/control/rq_bank.v`, `out_stage.v` |
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

Χωρίς Inkscape, το `pe_array.pdf` βγήκε με headless Chrome (`--print-to-pdf`):
το SVG μπαίνει inline σε μια σελίδα HTML με `@page { size: <W>px <H>px; margin: 0 }`.
Ίδια κλίμακα 96 dpi με το Inkscape (1 px = 0.75 pt), μία σελίδα, διανυσματικό
κείμενο με ενσωματωμένη Arial.

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

- Το `pe_array.svg` είναι σε landscape 1000x576· σε μονόστηλο κείμενο θέλει `width=\linewidth`.
- Οι δύο δίαυλοι ξεχωρίζουν και σε ασπρόμαυρη εκτύπωση: τα activations είναι
  **συνεχής** γραμμή, τα βάρη **διακεκομμένη**.
- Στο `pe_array.svg` οι δύο δίαυλοι δεν τέμνονται πουθενά: κάθε bank βαρών κάθεται
  πάνω από το lane του, και οι κατακόρυφες των activations περνούν ανάμεσα στα banks.

## Το μέγεθος της γραμματοσειράς — ο περιορισμός που είναι εύκολο να χαθεί

Το Inkscape εξάγει τα SVG px στα 96 dpi, άρα ένας καμβάς `W` μονάδων βγαίνει PDF
πλάτους `W x 0.2646` mm. Το `width=\linewidth` το συμπιέζει στα **170 mm**
(A4 με περιθώρια 2 cm). Το τυπωμένο μέγεθος είναι λοιπόν:

```
τυπωμένα pt = font_px x 481.9 / W
```

Για να μη πέσει κανένα γράμμα κάτω από **8 pt**, το κατώφλι είναι
`font_px >= 8 x W / 482`:

| καμβάς `W` | ελάχιστο `font-size` |
|--:|--:|
| 1000 | 17 px |
| 1200 | 20 px |
| 1240 | 21 px |

Το `accel_top.svg`, το `pe_array.svg`, το `dw_array.svg` , το `stem_array.svg` και το `requantize.svg` (W=1000, ελάχιστο
17 px → 8.2 pt) το τηρούν. Το παλιό `pe_array.svg` (W=1240, κείμενο 9.5–15 px) έβγαινε **3.7–5.8 pt**
τυπωμένο. Ένα σχήμα που δεν το τηρεί θέλει μεγαλύτερες γραμματοσειρές, όχι
μικρότερο `width` — το μικρότερο `width` το κάνει χειρότερο.

Έλεγχος χωρίς Inkscape, με headless Chrome:

```bash
chrome --headless --screenshot=out.png --window-size=1000,770 \
       --default-background-color=FFFFFFFF file:///<πλήρης διαδρομή>.svg
```
