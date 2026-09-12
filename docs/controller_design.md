# Controller & Accelerator Design — Σχέδιο μελέτης

Στόχος: ο **controller** που θα δρομολογεί τα (ήδη bit-exact επικυρωμένα) engines
για να τρέξει ολόκληρο το MobileNetV2 στο **ZCU104**. Το έγγραφο μαζεύει: τις
αρχιτεκτονικές επιλογές + πηγές, την ανάλυση για το συγκεκριμένο board, τον
roofline υπολογισμό, την απόφαση παραλληλισμού, και το detailed spec του
pointwise MAC array με build plan.

---

## 0. Πού βρισκόμαστε (context)

Έτοιμα & επικυρωμένα (unit + integration vs golden) leaf engines:
`requantize`, `conv1x1` (streaming MAC), `bias_add`, `dwconv3x3` (parallel 9-tap),
`conv3x3_std` (parallel 27-tap), `residual_add`, `avgpool`.

Στον δρόμο προς τον array (unit-tested, όχι ακόμα integration):
`mac_lane` (Tn=16 πλατιά lane, 2026-08-02), `pe_array` (Tm=32 lanes = 512
MAC/κύκλο, 2026-09-11).

Αρχή σχεδίασης: **τα engines κάνουν ΜΟΝΟ αριθμητική**· το addressing / windowing /
padding / stride / feeding είναι δουλειά του **controller**. Τα integration
testbenches (`pointwise_layer_tb`, `dwconv_layer_tb`, `stem_layer_tb`, …) κάνουν
ήδη χειροκίνητα αυτή τη δουλειά — δηλαδή είναι το **spec του controller**.

Datapath numerics: int8 activations/weights (symmetric, zero-point 0), 21-bit
signed accumulator, int32 M0 multiplier, per-channel requantize.

---

## 1. Αρχιτεκτονικές επιλογές για τον controller (+ πηγές)

Ο controller είναι ένα **FSMD** (FSM + Datapath). Η καθοριστική απόφαση είναι
**πού ζουν τα δεδομένα** (on-chip vs DDR streaming) — βλ. §3-4 για το ZCU104.

### Ιδέα 1 — Μονολιθικό layer-sequencer FSM (απλούστερο)
Ένα μεγάλο FSM (load weights → compute → requantize → writeback → next), address
generators = nested counters. Ξαναχρησιμοποιεί ένα instance κάθε engine.
- **Pros:** απλό, εύκολο debug. **Cons:** δεν κλιμακώνει/παραμετροποιείται για 74 ops.
- **Πηγές:** Harris & Harris (FSMD)· Pong Chu, *FPGA Prototyping by Verilog Examples*·
  Cummings SNUG FSM coding papers.

### Ιδέα 2 — Program-driven controller + per-type sub-controllers ⭐ (επιλεγμένο)
Top sequencer διαβάζει «πρόγραμμα» (μία instruction/op: op-type, shapes, stride,
pad, addresses, m0/shift, act) από ROM/BRAM και ενεργοποιεί per-type
sub-controllers (pointwise, depthwise, stem, pooling/residual), καθένας με το δικό
του address generation/windowing.
- **Pros:** καθαρός διαχωρισμός control/compute· επεκτάσιμο (νέο δίκτυο = νέο
  πρόγραμμα)· κάθε sub-controller δοκιμάζεται ανεξάρτητα (όπως τα TBs τώρα). Το
  `op_type` enum της C γίνεται opcode.
- **Cons:** περισσότερη αρχική δομή (instruction format).
- **Πηγές:** **Guo et al., "Angel-Eye", TCAD 2018** (Zynq CNN accel με instruction
  set — το πιο κοντινό)· **Qiu et al., "Going Deeper…", FPGA 2016** (πρόδρομος)·
  **Xilinx DPU (PG338)** ως εμπορικό microcode-driven παράδειγμα· Cummings (ιεραρχικά FSM).

### Ιδέα 3 — Tiled loop-nest με double buffering (data movement)
Γενικός engine με loop tiling (Tm/Tn/Tr/Tc) + ping-pong buffers από DDR. Δεν
αντικαθιστά την Ιδέα 2, τη συμπληρώνει. **Στο ZCU104 υποβαθμίζεται** (τα activations
χωράνε on-chip — βλ. §4).
- **Πηγές:** **Zhang et al., FPGA 2015** (roofline+tiling)· **Ma et al., FPGA 2017**
  (loop ordering/unrolling)· **Sze et al. survey / "Efficient Processing of DNNs"**.

### Ιδέα 4 — Streaming dataflow pipeline (άλλο άκρο)
Ένα stage/layer, weights baked-in, μέγιστο throughput — αλλά δεν χωράει ολόκληρο
το δίκτυο σε embedded FPGA. Χρήσιμο ως γνώση/υβρίδιο.
- **Πηγές:** **Umuroglu et al., "FINN", FPGA 2017**· **Venieris & Bouganis,
  "fpgaConvNet", FCCM 2016**· **hls4ml (Duarte et al., 2018)**.

### Building block — Line-buffer window generator (χρειάζεται για 3×3)
2 line buffers + 3×3 shift-register window → παράγει παράθυρα καθώς τα pixels
μπαίνουν raster, διαβάζοντας κάθε pixel μία φορά· χειρίζεται stride & padding.
Αντικαθιστά το χειροκίνητο window-build των `dwconv/stem` TBs.
- **Πηγές:** Vitis/Vivado HLS 2D-conv line-buffer example (UG1399/UG902)· Pong Chu
  (image processing, shift-register line buffers)· **Bai et al., TCAS-II 2018**
  (depthwise-separable accelerator dataflow).

### Επιλεγμένη σύνθεση
**Ιδέα 2** (σκελετός) + **activations on-chip σε URAM με ping-pong** (όχι tiling) +
**MAC-array engines** (§5) + **weight streaming** από DDR ανά layer + **line-buffer
generator** για τα 3×3.

---

## 2. Target board — ZCU104 (XCZU7EV)

| Πόρος | Τιμή |
|---|---|
| DSP48E2 | **1.728** (→ 3.456 int8 MAC/cyc με packing) |
| BRAM | ~11 Mb (312 × 36Kb) |
| URAM | ~27 Mb (96 × 288Kb) |
| On-chip σύνολο | **~4,7 MB** |
| LUT / FF | ~230K / ~460K |
| PS | quad Cortex-A53 + **DDR4 2 GB**, AXI-HP προς PL |

Συνέπειες: (α) μεγάλος DSP όγκος → ο **παραλληλισμός** είναι ο μοχλός, όχι η μνήμη·
(β) 4,7 MB on-chip → τα activations χωράνε· (γ) weights (2,19 MB, βλ. §3) → streaming ανά layer.

---

## 3. Roofline analysis

### Inputs
Τα δύο πρώτα **μετρήθηκαν από το `software/export/manifest.json`** (2026-09-10), δεν
είναι εκτιμήσεις από τη βιβλιογραφία.

| | Τιμή | προέλευση |
|---|---|---|
| Workload | **299.499.392 MACs** / inference (≈300 M) | άθροισμα `OH·OW·OC·(IC/groups)·KH·KW` σε 53 conv + gap + classifier |
| Weights | **2,19 MB int8** (+0,07 MB int32 bias) | άθροισμα `OC·(IC/groups)·KH·KW` |
| Peak compute | 1.728 MAC/cyc (·2 με int8 packing) | DSP48E2 count του XCZU7EV |
| DDR BW | ~12–19 GB/s (PS-DDR4) | 64 bit × 2400 MT/s = 19,2 θεωρητικό· 12 ρεαλιστικό |
| Design clock | 250 MHz | **στόχος σχεδίασης**, όχι υπολογισμός |

> **Διόρθωση (2026-09-10).** Η προηγούμενη έκδοση έγραφε «~3,4 MB βάρη». Αυτό είναι το
> MobileNetV2 του **ImageNet** (3,4 M παράμετροι × 1 byte για int8). Το δικό μας
> classifier είναι `1280×4` αντί για `1280×1000`, δηλαδή ~1,27 M λιγότερες παράμετροι.
> Το «~300 M MACs» επιβεβαιώθηκε (σφάλμα 0,2%).

### Κατανομή του workload (μετρημένη)
| κατηγορία | % των MACs | % των βαρών |
|---|---:|---:|
| pointwise 1×1 | **89,4%** | 96,8% |
| depthwise 3×3 | 6,9% | 2,9% |
| stem 3×3 | 3,6% | ~0% |
| gap + classifier | 0,02% | 0,2% |

Αυτό δικαιολογεί ποσοτικά τη σειρά του build plan: **9 στα 10 MACs περνούν από τον
pointwise array**, άρα αυτός χτίζεται πρώτος.

### Arithmetic intensity (με activations on-chip)
DRAM traffic/inference = βάρη + bias + input ≈ 2,19 + 0,07 + 0,15 ≈ **2,41 MB**.
```
Intensity = 299,5e6 MAC / 2,41e6 B ≈ 124 MAC/byte   (πολύ υψηλό)
```
> Αν τα activations πήγαιναν στο DDR κάθε layer, το intensity θα κατέρρεε (~2–3
> MAC/byte) → memory-bound. Ο roofline **δικαιώνει ποσοτικά** το «activations on-chip».

### Ridge point → compute-bound
Χειρότερη περίπτωση (όλα τα DSP+packing = 864 GMAC/s, BW 12 GB/s):
```
Ridge = 864e9 / 12e9 ≈ 72 MAC/byte  <  124  →  compute-bound
```
**Bottleneck = DSPs, όχι μνήμη.** Με το διορθωμένο μέγεθος βαρών το περιθώριο πάνω από
το ridge point είναι **72%** (ήταν 18% με το λανθασμένο 3,4 MB) — δηλαδή το συμπέρασμα
δεν κινδυνεύει από λεπτομέρειες υλοποίησης του DMA.

### Throughput vs P (MAC/κύκλο), @250 MHz
`latency = 300e6 / (P × 250e6)`

| P | DSPs (packed) | latency ideal | fps ideal | fps @50% util |
|---:|---:|---:|---:|---:|
| 128 | 64 | 9,4 ms | 107 | ~53 |
| 256 | 128 | 4,7 ms | 213 | ~106 |
| **512** | **256** | **2,3 ms** | **427** | **~210** |
| 1024 | 512 | 1,2 ms | 853 | ~425 |
| 1728 | 864 | 0,69 ms | 1440 | ~720 |

### Reality factor (μετρημένο, όχι εκτίμηση)
Η αρχική εκτίμηση ήταν «ρεαλιστικό utilization 40–60%». Η προσομοίωση του cycle model
πάνω σε **όλα** τα pointwise layers (§5) δείχνει ότι ο **ίδιος ο array πιάνει 92,1%** —
η μόνη απώλεια είναι το tail-padding. Οι πραγματικοί κίνδυνοι είναι αλλού:

1. **Η σειριοποίηση του depthwise** — το μεγάλο πρόβλημα, βλ. §6.
2. Pipeline fill/drain και DMA stalls, που δεν μοντελοποιούνται εδώ.

### Απόφαση: **μεσαίο P = 512** (Tm=32 × Tn=16, ~256 DSPs, ~15% chip)
Ισορροπία throughput/πόρων με headroom για timing/routing.

### Weight-bandwidth sanity check @P=512
```
2,26 MB / 2,27 ms ≈ 1,0 GB/s  «  12–19 GB/s ✓   (5% της DDR, άπλετος χώρος για double-buffer)
```

---

## 4. Memory plan (ZCU104)

- **Activations: 100% on-chip σε URAM, ping-pong μεταξύ layers.** Μεγαλύτερο feature
  map = block-2 expand 112×112×96 ≈ 1,15 MB· ping-pong (input ~200KB + output
  1,15MB) ≈ 1,35 MB « 3,4 MB URAM. **Καθόλου activation tiling.**
- **Weights: DMA ανά layer** από PS-DDR4 (AXI-HP) σε on-chip weight buffer
  (max per-layer ~400 KB — το τελικό 1×1 320→1280). Double-buffer με το compute.
- **Layout:** activations **NHWC** (κανάλια contiguous — όπως ήδη κάνει το c-model
  & τα TBs) ώστε ένα read να δίνει Tn κανάλια του pixel.

---

## 5. Pointwise MAC array — detailed spec (P=512)

### Διαστάσεις — **ΑΠΟΦΑΣΙΣΜΕΝΟ: Tm × Tn = 32 × 16** (2026-09-10)
- **Tn=16** input channels/κύκλο → adder-tree βάθους 4/lane· activation broadcast
  16×8b = 128 bit/κύκλο.
- **Tm=32** output channels/κύκλο → 32 lanes, δικά τους βάρη ανά lane.

Η απόφαση βγήκε τρέχοντας το cycle model σε **όλα** τα 35 pointwise layers, για κάθε
διαμόρφωση με σταθερό `Tm·Tn = 512`:

| Tm × Tn | utilization | κύκλοι | ms @250MHz |
|---|---:|---:|---:|
| 8 × 64 | 66,1% | 792k | 3,17 |
| 16 × 32 | 88,6% | 591k | 2,36 |
| **32 × 16** | **92,1%** | **568k** | **2,27** |
| 64 × 8 | 74,9% | 699k | 2,80 |

**Η υπόθεση υπέρ του Tn=8 ήταν λάθος.** Ισχύει ότι το Tn=8 διαιρεί όλα τα channel
counts — αλλά αυτό κοιτάζει μόνο τη διάσταση **εισόδου**. Με σταθερό P, το Tn=8
επιβάλλει Tm=64, που καταστρέφει τη διάσταση **εξόδου**:

| OC στο δίκτυο | 16 | 24 | 32 | 96 | 144 | 192 |
|---|---:|---:|---:|---:|---:|---:|
| lanes σε χρήση, Tm=32 | 50% | 75% | **100%** | **100%** | 90% | **100%** |
| lanes σε χρήση, Tm=64 | 25% | 38% | 50% | 75% | 75% | **100%** |

Το MobileNetV2 έχει **στενές εξόδους** στα bottleneck layers (16, 24, 32, 96) και
**πλατιές εισόδους** στα expand layers. Θέλεις λοιπόν μικρό Tm και μεγάλο Tn — και το
32×16 πέφτει ακριβώς πάνω σε αυτή την ασυμμετρία. Κερδίζει και σε κόστος έναντι του
16×32: broadcast 128 bit αντί 256, adder tree βάθους 4 αντί 5. Το weight bandwidth
(4096 bit/κύκλο) είναι ταυτόσημο σε όλες τις διαμορφώσεις, αφού το `Tm·Tn` είναι σταθερό.

### Πού πάει το υπόλοιπο 7,9%
Συγκεντρώνεται σε πέντε πρώιμα layers με μεγάλο H×W:

| layer | χαμένοι κύκλοι | αιτία |
|---|---:|---|
| `features.1.conv.1` | 12.544 | OC=16 → 32 |
| `features.3.conv.0.0` | 10.192 | OC=144→160, IC=24→32 |
| `features.4.conv.0.0` | 10.192 | OC=144→160, IC=24→32 |
| `features.3.conv.2` | 7.056 | OC=24 → 32 |
| `features.2.conv.2` | 4.704 | OC=24 → 32 |

Εξετάστηκε **pixel-parallel fallback** (όταν `OC < Tm`, οι αδρανείς lanes δουλεύουν σε
δεύτερο pixel): κερδίζει μόλις **2,2%** με σημαντική επιπλοκή στο control. **Απορρίφθηκε** —
κρατάμε το 7,9% ως γνωστό, μετρημένο κόστος.

### Dataflow (output-stationary, weights+acts on-chip)
Το 1×1 χρησιμοποιεί τον **ίδιο πίνακα βαρών σε όλα τα pixels** → τεράστιο weight
reuse· τα per-layer βάρη χωράνε on-chip.
```
per layer:  DMA weights -> on-chip weight buffer
for pixel p in H*W:                       // output-stationary
  for oc_tile in ceil(OC/Tm):
    acc[Tm] = 0
    for ic_tile in ceil(IC/Tn):           // accumulate over input channels
      broadcast a[p][ic_tile]  (Tn τιμές) σε όλες τις Tm lanes
      each lane: Σ(Tn γινόμενα) -> acc[lane] += partial
    requantize acc[Tm] -> out[p][oc_tile]
```

### Δομή
```
             a[0..Tn-1]  (broadcast, 128 bit)
   ┌──────────┼──────────┐ ... (Tm=32 lanes)
   ▼          ▼
 lane0      lane1
 Tn mults   Tn mults
 adder tree adder tree
 +acc(21b)  +acc(21b)
   │          │
 acc[0]     acc[1] ... acc[31]  ->  Tm-wide requantize
```
Κάθε **lane = parallel εκδοχή του `conv1x1.v`** (Tn πολλαπλασιασμοί + adder tree +
accumulate αντί για 1 MAC/κύκλο). Οι Tm lanes μοιράζονται τα ίδια Tn activations.

### Cycle model
```
cycles/layer ≈ H*W × ceil(OC/Tm) × ceil(IC/Tn)
```
Παράδειγμα `features.2.conv.2` (IC=96, OC=24, 56×56):
```
cycles = 3136 × ceil(24/32) × ceil(96/16) = 3136 × 1 × 6 = 18.816
useful MACs = 3136×24×96 = 7,2 M ; ideal = 512×18.816 = 9,6 M
utilization = 75%  (OC=24 padded σε 32) ; @250MHz ≈ 75 µs
```
(Δείχνει το κόστος του tail-padding· το Tn=8/Tm=64 θα ήταν καθαρότερο εδώ.)

### Buffer bandwidth
- **Activation buffer:** Tn=16 int8/κύκλο = 128 bit → τετριμμένο (μία URAM word).
  Banking μέσω NHWC (κανάλια contiguous).
- **Weight buffer:** Tm×Tn = 512 int8/κύκλο = **4096 bit/κύκλο** → το βαρύ. Λύση:
  Tm=32 παράλληλα weight banks × Tn=16 πλατιά. Per-layer βάρη cached on-chip.

### DSP48E2 mapping
- **int8 packing (WP486):** 2 MAC/DSP → 512 MACs = **256 DSPs**.
- **DSP cascade (PCOUT→PCIN)** για το adder-tree κάθε lane (προσθέσεις μέσα στα DSP,
  όχι σε LUTs → καλύτερο timing).

### Tail handling
Zero-pad κανάλια στο tile boundary (βάρη=0 → συνεισφορά 0). Bit-exact· χάνεις μόνο
utilization στο tail tile.

---

## 6. Depthwise engine — το πραγματικό bottleneck

Εύρημα της 2026-09-10, από το ίδιο cycle model. Με τα engines **όπως είναι σήμερα**
(το `dwconv3x3.v` παράγει 1 στοιχείο εξόδου/κύκλο, 9 taps παράλληλα):

| τμήμα | κύκλοι | ms @250MHz | % χρόνου | % των MACs |
|---|---:|---:|---:|---:|
| pointwise array (P=512) | 568k | 2,27 | 17% | **89,4%** |
| **depthwise @ 1 καν./κύκλο** | **2.302k** | **9,21** | **70%** | **6,9%** |
| stem @ 1 στοιχ./κύκλο | 401k | 1,61 | 12% | 3,6% |
| **σειριακό σύνολο** | **3.271k** | **13,09** | | → **76 fps** |

**Το depthwise είναι 6,9% της αριθμητικής αλλά θα γινόταν 70% του χρόνου.** Χωρίς
παραλληλισμό εκεί, ο array των 256 DSP κάθεται και περιμένει. Είναι το κλασικό
πρόβλημα των depthwise-separable δικτύων (πρβλ. Bai et al., TCAS-II 2018): το
depthwise έχει **μηδενικό channel reuse** — κάθε κανάλι εξόδου βλέπει μόνο το
ομώνυμο κανάλι εισόδου, άρα δεν υπάρχει άθροιση κατά μήκος καναλιών να παραλληλοποιηθεί.
Ο μόνος διαθέσιμος άξονας είναι **Tc κανάλια ταυτόχρονα**.

| Tc (κανάλια/κύκλο) | DSPs* | depthwise | σύνολο | fps | % χρόνου |
|---:|---:|---:|---:|---:|---:|
| 1 (σήμερα) | 5 | 14,96 ms | 18,84 ms | 53 | 79% |
| 8 | 36 | 1,87 ms | 5,75 ms | 174 | 33% |
| **16** | **72** | **0,94 ms** | **4,81 ms** | **208** | **19%** |
| 32 | 144 | 0,48 ms | 4,36 ms | 229 | 11% |

> **Διόρθωση (2026-09-12).** Η προηγούμενη έκδοση μέτραγε pixels **εξόδου**.
> Ένας line-buffer generator πρέπει να καταναλώσει **κάθε pixel εισόδου** για να
> γλιστρήσει το παράθυρο, ακόμα και στο stride 2 όπου εκπέμπεται κάθε δεύτερο.
> Τέσσερα depthwise layers έχουν stride 2, άρα 4× πλέον pixels εισόδου. Το
> κόστος είναι **1,63×** μεγαλύτερο. Η απόφαση Tc=16 δεν αλλάζει.

<sub>*Tc × 9 taps ÷ 2 με int8 packing</sub>

### Απόφαση: **Tc = 16, σε ξεχωριστό engine** (2026-09-10)
Στο Tc=16 το depthwise πέφτει στο 13% του χρόνου με 72 DSPs· πάνω από εκεί οι
αποδόσεις φθίνουν (το Tc=32 δίνει +7% throughput για διπλάσιους πόρους).

**Ξεχωριστό engine, όχι διαμοιρασμός DSPs με τον pointwise array.** Το MobileNetV2
εναλλάσσει `pw → dw → pw`, οπότε τα δύο δεν τρέχουν ποτέ ταυτόχρονα μέσα στο ίδιο
layer και *θα μπορούσαν* να μοιράζονται πόρους — αλλά το συνολικό budget είναι
`256 + 72 + ~50 (stem) ≈ 380 DSPs, μόλις 22% του chip`. Ο διαμοιρασμός θα κόστιζε
πολύπλοκα mux στο datapath για να γλιτώσει πόρους που περισσεύουν.

> **Πλαισίωση.** Ο Core στόχος είναι μία εικόνα από SD κάρτα, και το stretch goal
> κάμερας θέλει 30 fps — ακόμα και το σημερινό 76 fps τα καλύπτει. Η αξία του Tc=16
> δεν είναι ότι κάνει το έργο εφικτό, αλλά ότι δίνει υπερασπίσιμο νούμερο throughput
> και δείχνει ότι εντοπίστηκε το πραγματικό bottleneck.

---

## 7. Build plan (μεθοδολογία engine → unit test → integrate)

1. ~~**`mac_lane.v`**~~ — **ΕΤΟΙΜΟ (2026-08-02).** Μία lane: Tn-wide parallel MAC +
   adder tree + accumulate (first/last/done). Το `conv1x1.v` «πλατύ». Επικυρώθηκε
   bit-exact απέναντι σε δύο oracles ταυτόχρονα (ανεξάρτητο reference άθροισμα **και**
   το single-MAC `conv1x1`), 24/24 cases.
2. ~~**`pe_array.v`**~~ — **ΕΤΟΙΜΟ (2026-09-11).** Tm=32 instances του `mac_lane`,
   κοινό activation broadcast, Tm-wide acc έξοδος — 512 MAC/κύκλο. Καθαρή
   καλωδίωση, χωρίς δική του αριθμητική. 19 cases / 608 lane-checks PASS, με
   τα δύο oracles (ανεξάρτητο reference σε όλες τις lanes + `conv1x1`). Το TB
   επαληθεύτηκε με **mutation testing**: τρεις σκόπιμες βλάβες καλωδίωσης
   (μετατόπιση weight slice, μετατόπιση acc slice, σπασμένο broadcast) πιάστηκαν
   και οι τρεις.
3. ~~**Feeder/buffers**~~ — **ΕΤΟΙΜΟ (2026-09-11).** `addr_gen` (οι τρεις μετρητές),
   `wgt_buffer` (32 τράπεζες = 4096 bit/κύκλο), `act_buffer` (entries 256 bit, μία
   δεξαμενή), `pw_feeder` (η κόλλα + ευθυγράμμιση pipeline). Καμία διεύθυνση
   δεν χρειάζεται πολλαπλασιαστή.
4. ~~**Integration**~~ — **ΕΤΟΙΜΟ (2026-09-12).** Το output half (`rq_bank` με R=32 — DD-015,
   `param_buffer`, `pw_out`) και το `pw_datapath_tb`: **ολόκληρο το `features.1.conv.1`
   (200.704 στοιχεία) bit-exact** απέναντι στο golden, στα 512 MAC/κύκλο και με
   `ACC_W=21`. Μετρήθηκε και το περιθώριο του accumulator: max |acc+bias| = 20.888
   έναντι ορίου ±1.048.576 → **5 bits headroom**. Η προϋπόθεση των 21 bit έγινε
   μετρημένο περιθώριο.
5. ~~**Depthwise engine (Tc=16, §6) + line-buffer**~~ — **ΕΤΟΙΜΟ (2026-09-12).**
   `line_buffer` (κάθε pixel διαβάζεται ΜΙΑ φορά αντί για εννέα), `dw_array`
   (16 παράλληλα `dwconv3x3`), `dw_feeder` (οι τρεις μετρητές + output stage).
   Integration: **ολόκληρο το `features.1.conv.0.0` (401.408 στοιχεία) bit-exact**.
   Το output stage ξαναχρησιμοποιεί `rq_bank` και `param_buffer` με TM=16 —
   μηδέν νέο RTL (DD-003 στην πράξη). Για το depthwise τα 21 bit είναι
   **αποδείξιμα** αρκετά (9 taps → max 146.304), όχι προϋπόθεση.
6. **Top sequencer** (Ιδέα 2) που δρομολογεί τα 74 ops.

---

## 8. Ανοιχτές αποφάσεις / next

- [x] ~~Οριστικοποίηση Tm/Tn~~ → **32×16** (§5). Μετρήθηκε σε όλα τα pointwise layers:
      92,1% vs 74,9% για το 64×8. Το `mac_lane.v` δεν αλλάζει.
- [x] ~~Depthwise parallelism & διαμοιρασμός DSPs~~ → **Tc=16, ξεχωριστό engine** (§6).
- [x] ~~Instruction format του top sequencer~~ → ορίστηκε, βλ. §9 (8 λέξεις × 32 bit).
- [x] ~~Ping-pong activation buffer management~~ → **στατική κατανομή**, βλ. §9.
- [x] ~~Χειρισμός residual~~ → το `save` είναι μόνο σήμανση διάρκειας ζωής, βλ. §9.
- [ ] URAM banking scheme για το activation buffer (Tn/κύκλο) & το weight buffer (Tm×Tn/κύκλο).
- [ ] Παραλληλισμός του stem (1,61 ms στο 1 στοιχείο/κύκλο = 12% του χρόνου· ~50 DSPs
      το κάνουν αμελητέο). Χαμηλή προτεραιότητα — τρέχει μία φορά.

**Επόμενο RTL βήμα:** top sequencer για τα 74 ops (build plan #6).

---

## 9. Πρόγραμμα και κατανομή μνήμης (build plan #6)

Το `scripts/gen_program.py` είναι ο compiler: διαβάζει το `manifest.json`, κατανέμει
διευθύνσεις σε όλα τα feature maps και εκπέμπει το instruction stream.

### Δύο ευρήματα από το C reference model

**Το `save` δεν μετακινεί δεδομένα.** Η `run_inference()` κρατά κάθε έξοδο layer ζωντανή
και το `residual_add` διαβάζει απευθείας το buffer του layer που την παρήγαγε. Άρα στο
hardware το `save` είναι **μόνο σήμανση διάρκειας ζωής**: λέει στον allocator «αυτό το
tensor πρέπει να ζήσει μέχρι το αντίστοιχο res_add». Κοστίζει **μηδέν κύκλους και καμία
εντολή**: **74 ops → 64 instructions**.

**Η είσοδος δεν μπαίνει στη δεξαμενή.** Το 224×224×3 ως entries των 32 καναλιών θα
σπαταλούσε 91% του χώρου (1,53 MB για 147 KB δεδομένων). Η εικόνα ζει σε δική της περιοχή
147 KB που γεμίζει το PS, και τη διαβάζει μόνο ο stem.

### Στατική κατανομή, όχι ping-pong

Το κλασικό ping-pong με δύο σταθερά μισά θέλει 2× το μεγαλύτερο feature map. Επειδή όμως
ολόκληρο το πρόγραμμα είναι **γνωστό στατικά**, ο generator κάνει κανονικό register
allocation: υπολογίζει διάρκειες ζωής και τοποθετεί με first-fit.

| | entries | MB |
|---|---:|---:|
| μεγαλύτερο μεμονωμένο tensor | 37.632 | 1,15 |
| **κορύφωση δεξαμενής** | **50.176** | **1,53** |
| αντί για 2× με ping-pong | 75.264 | 2,30 |

Η κορύφωση προκύπτει στο op 3 (`features.2.conv.0.0`), όπου η έξοδος των 37.632 entries
κάθεται αμέσως μετά τη ζωντανή είσοδο των 12.544.

Ο generator **επαληθεύει** την κατανομή: κανένα ζεύγος ταυτόχρονα ζωντανών tensors δεν
επικαλύπτεται, και κανένα op δεν γράφει εκεί που διαβάζει.

### Instruction word — 8 λέξεις × 32 bit

Η πυκνότητα είναι αδιάφορη (64 ops = 2 KB όπως και να το κάνεις), οπότε η διάταξη
επιλέχθηκε να διαβάζεται σε hex dump και να κόβεται εύκολα στο RTL.

| word | bits | πεδίο |
|---|---|---|
| w0 | [3:0] | opcode: 1=STEM 2=PW 3=DW 4=RES_ADD 5=GAP 6=LINEAR |
| | [11:4] / [19:12] | `img_w` / `img_h` (διαστάσεις **εισόδου**) |
| | [20] / [21] | `stride2` / `act` (0=NONE, 1=RELU6) |
| | [31:24] | `relu6_qmax` |
| w1 | [15:0] / [23:16] / [31:24] | `n_pix` / `n_oc` / `n_ic` |
| w2 | [7:0] / [15:8] / [23:16] | `n_grp` / `n_ent_in` / `n_ent_out` |
| w3 | [15:0] / [31:16] | `base_in` / `base_out` |
| w4 | [15:0] | `base_saved` (μόνο RES_ADD) |
| w5 | [23:0] | `wgt_off` — byte offset στο weight blob |
| w6 | [19:0] | `wgt_bytes` |
| w7 | [15:0] | `pchan` — κανάλια per-channel παραμέτρων προς φόρτωση |

Έξοδος: `software/export/program.hex` (512 λέξεις, για `$readmemh`) και `program.txt`
(αναγνώσιμο listing — αυτό διαβάζεις όταν το hardware διαφωνεί με το C model).

---

## 10. Πηγές (συγκεντρωτικά)

**CNN-on-FPGA controllers / accelerators**
- Guo et al., *Angel-Eye: A Complete Design Flow for Mapping CNN onto Embedded FPGA*, TCAD 2018. *(PDF στο docs/references/)*
- Qiu et al., *Going Deeper with Embedded FPGA Platform for CNN*, FPGA 2016.
- Zhang et al., *Optimizing FPGA-based Accelerator Design for Deep CNN*, FPGA 2015.
- Ma et al., *Optimizing Loop Operation and Dataflow in FPGA Acceleration of DNNs*, FPGA 2017.
- Umuroglu et al., *FINN*, FPGA 2017 · Venieris & Bouganis, *fpgaConvNet*, FCCM 2016 · hls4ml (Duarte et al., 2018).
- Bai et al., *A CNN Accelerator on FPGA Using Depthwise Separable Convolution*, TCAS-II 2018.
- Sze et al., *Efficient Processing of Deep Neural Networks* (survey/book).
- Chen et al., *Eyeriss* (dataflow taxonomy).

**Xilinx / board-specific**
- WP486, *Deep Learning with INT8 Optimization on Xilinx Devices* (DSP int8 packing).
- UG579, *UltraScale Architecture DSP48E2 User Guide*.
- UG573, *UltraScale Architecture Memory Resources* (BRAM/URAM).
- PG338, *DPUCZDX8G / Zynq DPU* + Vitis AI (baseline σύγκρισης στο ZCU104).
- UG1085, *Zynq UltraScale+ MPSoC TRM* (AXI-HP, DMA, PS-PL).

**RTL / FSM design**
- Harris & Harris, *Digital Design and Computer Architecture* (FSMD).
- Pong P. Chu, *FPGA Prototyping by Verilog Examples*.
- Cummings, SNUG FSM coding-style papers.
