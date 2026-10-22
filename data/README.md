# data/

Datasets live here but are **gitignored** (see `.gitignore`).

- The **PlantVillage grape subset**: Black Rot, ESCA, Healthy, Leaf Blight.
- **The dataset is final for this thesis** (DD-036): no field photographs. Real vine photos stay
  the natural next step — as a test set of their own, not pooled with this one (DD-034).

Do not commit large image sets. Keep them local, or use Git LFS / external storage and note the source here.

## What is here, and which one to use

| folder | what it is | use it? |
|---|---|---|
| `grape/` | the downloaded set: train/val split **per file**, with rotated/flipped copies of each image | source only - leaks copies across the split |
| `grape_clean/` | first fix: one original per image id, split 80/20 by id | **no** - PlantVillage photographed each leaf several times under different ids, so it still leaks whole leaves (532 of 910 diseased leaves on both sides) |
| `grape_leafsplit/` | train / val / test **by leaf**, 70/15/15, plus `split.csv` | **yes** - training, checkpoint selection, and the one test evaluation |
| `plantvillage_leaf_maps/` | PlantVillage's own leaf grouping for the three diseased classes | input to the split |

`grape_leafsplit/` is rebuilt from `grape/` and the leaf maps by
`software/train/resplit_dataset.py`, which also says how to fetch the maps (they are
not committed: the upstream repository declares no licence). Why each earlier split
was wrong, and how the healthy class - which has no leaf map - is cut: DD-034.
