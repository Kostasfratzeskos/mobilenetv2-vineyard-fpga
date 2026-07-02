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
- `runs/`       - trained checkpoints (gitignored)

Install deps: `pip install -r requirements.txt`

The quantization arithmetic (`train/quantize.py`) must stay identical to the
hardware; `cmodel/` exists to prove it does. See `cmodel/README.md`.
