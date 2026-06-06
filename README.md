# MobileNetV2 → Vineyard Disease Detection on Zynq UltraScale+

Hardware-accelerated MobileNetV2 inference on a Zynq UltraScale+ MPSoC for classifying vineyard
leaf diseases, written in **Verilog-2001** and tested in **Vivado**. A software int8 model is the
source of truth; the accelerator is built and verified against it, layer by layer, until the full
network matches.

## Success tiers
- **Core (committee bar):** image loaded from the SD card → FPGA → disease class.
- **Foundation:** full MobileNetV2 running bit-exact against the software model in simulation.
- **Stretch:** live camera → disease result, in real time.

## The verification spine
The software int8 model produces the exact integer output of every layer — the *golden vectors*.
Every hardware block is checked against those numbers bit-for-bit before moving on, and the
assembled network is compared end-to-end. This thread keeps the whole project honest.
See `docs/design_decisions.md` (DD-006) and `software/golden/`.

## Layout
```
.
├── README.md
├── .gitignore
├── init_repo.sh            one-time git setup
├── docs/
│   ├── design_decisions.md why each non-trivial choice was made (start here)
│   ├── lab_notebook.md     running progress log
│   └── references/         papers + notes
├── software/               Phase 1: Python reference model (the source of truth)
│   ├── model/  train/  quantize/  export/  golden/
│   └── requirements.txt
├── data/                   datasets (gitignored)
├── hardware/               Phases 2–3: Verilog-2001 RTL
│   ├── rtl/ (axi/ kernels/ control/ top/)
│   ├── tb/                 testbenches, layer-by-layer verification
│   └── constraints/        .xdc files
├── vivado/                 project rebuild scripts (generated files gitignored)
├── firmware/               Phase 4: PS app (SD image → DDR → PL → result)
├── sim/                    simulation + golden-vs-hardware logs (gitignored)
├── scripts/                helpers, e.g. compare_golden.py
└── thesis/                 manuscript — write as you go
```

## Getting started
1. `bash init_repo.sh` — initialize git and make the first commit.
2. Create an empty repository on GitHub or GitLab (no README), then:
   ```
   git remote add origin <your-repo-url>
   git push -u origin main
   ```
3. Software, Phase 1 → `software/README.md`
4. Hardware, Phases 2–3 → `hardware/README.md`
5. On-board, Phase 4 → `firmware/README.md`

## Pointers
- Week-by-week plan: drop a copy of your `thesis_plan` file in `docs/`.
- Design decisions: `docs/design_decisions.md` — add an entry whenever you make a choice you might defend.
- Progress: `docs/lab_notebook.md`.
