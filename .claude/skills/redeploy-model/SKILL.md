---
name: redeploy-model
description: Put a different trained checkpoint on every platform, in order and verifying each step - the export, golden sets, generated headers, all testbenches, the SD-card known answers, the camera app and the thesis numbers. Manual only; run it when the deployed model changes.
disable-model-invocation: true
argument-hint: "[checkpoint .pth] [scales .json]"
---

# Redeploy a model

The 2026-10-23 entry in `docs/lab_notebook.md` is the worked example (DD-036). Read it first. Stop
at the first step that fails, and don't go on until it passes.

0. **Preconditions.** The change is agreed with the supervisor and recorded in a DD entry. The
   checkpoint, its int8 scales and its test report are in `software/runs/`, and the test split was
   scored once (DD-034). Write down the old checkpoint's sha, which every generated header names.
1. **Export.** From `software/train/`, run `export.py` with the new `--ckpt` and `--scales`. The
   command is in `.gitignore`, under "Golden vector sets". Read the exporter's output:
   - the logit scale must equal the test report's;
   - the accumulator bound must fit `ACC_W = 26` (DD-019);
   - the cross-check must agree with both the float and the fake-quant models.
2. **Golden sets.** Apply the golden-set rule (`.claude/rules/software.md`) to the new test report.
   Write the sets straight into `software/golden/`, because Windows' 260-character path limit
   breaks long scratch paths. If the default set's name changes, update its
   `!software/golden/<set>/` line in `.gitignore`, and everything that names the old set
   (`grep -rn <old_set> hardware scripts firmware software`).
3. **Generated files.** `python scripts/gen_program.py --emit` writes the program,
   `quant_params.h`, `model_scalars.svh` and `program_ops.svh`. Then run
   `python scripts/gen_preproc_vectors.py` for the preprocessing vectors of each set.
4. **Verify.**
   - Run all 35 testbenches (`/run-testbenches`).
   - Run `accel_tb` on each class set: regenerate `program_ops.svh` with
     `gen_program.py --emit --golden-dir software/golden/<set>`, then put the default back.
   - Run `make -C software/cmodel test`, `make -C firmware test` and `make -C firmware/linux test`.
   - Search the testbenches for any of the old model's scalars typed in by hand.
5. **Board staging.**
   - Restage the SD cards with `python scripts/make_sdcard.py --set <set> --out build/sdcard_<class>`
     for each set; the commands are in `.gitignore`.
   - Rebuild `vinecam` with `make -C firmware/linux`; it compiles `QP_LOGIT_SCALE` in.
   - Update the known answers in the bring-up lab guide.
6. **Thesis.** Run `make -C thesis numbers`. There must be no `WARNING` line, and `\thCkptSha` must
   equal `\thAccCkptSha`. Measure the verification figures in `manual_numbers.tex` again. Results
   the old model produced on the board stay labelled as the old model's, marked `TODO(BOARD)`
   until they are run again.
7. **Record.** Write the lab-notebook entry and the DD update (`/log-session`) and update the
   README status lines. The board re-run is a separate, later step.
