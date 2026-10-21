# software/ - Phase 1: reference models (the source of truth)

Python pipeline that produces the golden vectors every hardware block is checked
against, plus a bit-exact C reimplementation that bridges the Python model and the RTL.

- `model/`      - MobileNetV2 definition / checkpoint loading (`mobilenetv2.py`)
- `train/`      - the full pipeline: `train.py`, `dataset.py`, `quantize.py`
  (int8 + fixed-point model), `export.py` (dump weights), `evaluate.py`
- `cmodel/`     - bit-exact C reference model: same integer arithmetic as the
  hardware, used to cross-check the Python golden vectors before the RTL exists
- `export/`     - quantized weights (`.hex`) and per-layer scales for the RTL
- `golden/`     - per-layer golden activation vectors
- `predict.py`  - run inference on a single image
- `runs/`       - trained checkpoints (only the two named in `.gitignore` are kept, in
  Git LFS), each with its training log (`.csv`); and for the leaf-split model its
  int8 scales and the test-set report the thesis numbers come from

Install deps: `pip install -r requirements.txt`

## Measuring accuracy (DD-034)

Train on train, choose on val, and score the test split **once**, after everything
else is fixed. Run from `software/`:

```
python train/resplit_dataset.py --src ../data/grape --leaf-maps ../data/plantvillage_leaf_maps --dst ../data/grape_leafsplit
python train/train.py    --data ../data/grape_leafsplit --out runs/mobilenetv2_grape_leafsplit.pth
python train/quantize.py --data ../data/grape_leafsplit --ckpt runs/mobilenetv2_grape_leafsplit.pth --dump-scales runs/quant_scales_grape_leafsplit.json
python train/evaluate.py --data ../data/grape_leafsplit --split test --ckpt runs/mobilenetv2_grape_leafsplit.pth --scales runs/quant_scales_grape_leafsplit.json --report runs/mobilenetv2_grape_leafsplit_test.json
```

`evaluate.py` scores the float model and the integer pipeline (the arithmetic the
accelerator reproduces bit for bit), with per-class precision / recall / F1, the
confusion matrix, and 95% intervals per image and per leaf. `scripts/thesis_numbers.py`
turns its report into the `\thAcc*` macros.

The quantization arithmetic (`train/quantize.py`) must stay identical to the
hardware; `cmodel/` exists to prove it does. See `cmodel/README.md`.
