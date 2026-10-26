---
paths:
  - "software/**"
---

# Software model (`software/`)

- The quantization arithmetic in `train/quantize.py` must stay identical to the hardware's.
  `cmodel/` proves that it does: `make -C software/cmodel test`.
- The dataset is PlantVillage grape, split by leaf into `data/grape_leafsplit` (DD-034).
  `data/grape` and `data/grape_clean` leak whole leaves between splits. Never train or score on
  them.
- Train on train, choose on val, and score the test split once, after everything else is fixed
  (DD-034). Never use the test split to choose anything.
- The deployed checkpoint is the one DD-036 names. Generated headers and reports carry its sha.
  Changing the deployed model is a redeploy: use `/redeploy-model`, and never regenerate only part
  of it.
- `train/export.py` writes `export/` and `golden/`. `runs/` holds the checkpoints, training logs
  and test reports. Never edit any of them by hand.
- The golden-set rule was fixed before any image was looked at (2026-10-23): for each class, the
  first test-split photograph, in `ImageFolder` order, that the integer pipeline classifies
  correctly. `healthy_9111` is the tracked set and the testbenches' default. `image_1` is stale
  (June 2026, can't be regenerated) and is kept only for the C model's loader test.
- Run the training and evaluation commands from `software/`, exactly as `software/README.md`
  gives them.
