# Phase 2 — Quantization & Export: Plain-Language Technical Notes

> **Purpose:** These notes explain what Phase 2 of the project does, why each decision was made,
> and what files it produces. Written in my own words so I truly understand it before
> building the Verilog. This document lives in the repo and doubles as thesis reference material.
>
> **Status:** [ ] Draft in progress  [ ] Complete  
> **Date:** 15/06/2026  
> **Git tag / commit:** ___________

---

## 1. What is the problem Phase 2 is solving?

*Write 3–5 sentences answering: why can't we just load the trained PyTorch model onto the FPGA directly? What has to happen to the model before hardware can run it?*

Fpgas have limited recources we can use to build our model. That's why we use quantization, which float32 becomes int8 in all parameters loadable data. Float32 units are 4 times bigger that int8, something that will dicrease the memory drastically. We know that the MobileNet V2 has 2.22M + 0.05M --> 2,228,996 parameters so the overall memory layout will dicrease from 8.9MB to 2.3MB.

---

## 2. The two inputs that export.py needs

*Fill in what each input is, where it came from, and what information it carries.*

**Input 1 — `mobilenetv2_grape.pth` (the float checkpoint)**

What it is: This is what train.py saved in phase 1, basically the best validation epochs snapshot. Also the values that are saved inside this file are:
1) Conv and linear weights. These are the actual learned parameters (every filter in every layer).
2) Batch Norm weights. These are the weights that the model uses for batch normalization (gamma, betta, running_mean, running_var). We don't use them in hardware implamentation but we need them for export.py in order to provide the same outputs as the original-sofware model.
3) Bias values. These get combined with the folded Batch Norm contribution and we get the float32 bias values.
_______________________________________________________________________________

Where it came from: It was provided by the train.py file
_______________________________________________________________________________

Why export.py needs it (what it extracts from it): export.py needs this file because it takes the parameters to make the quantization.
_______________________________________________________________________________

---

**Input 2 — `quant_scales.json` (the activation scales)**

What it is: Its the result of quantize.py and this file contains the information about the weights for each layer that we need to make quantization. More specifically it has the max and min values for weights in each layer, which the scale is computed and all the weight values in float32.
_______________________________________________________________________________

Where it came from (which script produced it and how): quantize.py produced it.
_______________________________________________________________________________

Why export.py needs it (what it contributes that the checkpoint doesn't have): Computing M0/shift, running integer forward pass
_______________________________________________________________________________

---

## 3. The five stages inside export.py

*Describe each stage in one or two plain-English sentences. No code. Focus on what goes in, what comes out, and why the stage exists.*

**Stage 1 — Fold BatchNorm (`fuse_conv_bn`)**

What it does: It combines the batch norm operation with conv.
_______________________________________________________________________________

Why we do this (what would happen if we didn't): We do this because in harware we dont have this operation, so the outputs activations from each layer will differ.
_______________________________________________________________________________

---

**Stage 2 — Linearize the network (`build_plan`)**

What it does: Basically it makes a pipeline of all operations. It tryes to mymic the hardware implemantation, so we can compare the results from each layer.
_______________________________________________________________________________

Why we do this (what does "linearize" mean here): We do this because we want to test our hardware implemantation with a sofware one that is working correcltly.
_______________________________________________________________________________

---

**Stage 3 — Attach the quantization numbers (`assign_scales`)**

What it does:
_______________________________________________________________________________

What the "numbers" are (name them):
_______________________________________________________________________________

---

**Stage 4 — Integer forward pass (`IntExecutor`)**

What it does:
_______________________________________________________________________________

Why this stage exists instead of just using PyTorch's fake-quant output:
_______________________________________________________________________________

*This is the most important stage. Write the exact arithmetic sequence that happens per layer (in your own words, not symbols):*

_______________________________________________________________________________
_______________________________________________________________________________

---

**Stage 5 — Emit files**

What files are written out:
_______________________________________________________________________________

---

## 4. The three outputs that export.py produces

*For each output, explain what it contains and who/what uses it.*

**Output A — Weight hex files (per layer)**

Contents:
_______________________________________________________________________________

Who uses them:
_______________________________________________________________________________

Why `.hex` format specifically:
_______________________________________________________________________________

---

**Output B — `manifest.json`**

Contents:
_______________________________________________________________________________

Who uses it:
_______________________________________________________________________________

Why a single manifest instead of hardcoding numbers in the Verilog:
_______________________________________________________________________________

---

**Output C — Golden vectors (per layer)**

Contents:
_______________________________________________________________________________

How the testbench will use them:
_______________________________________________________________________________

What it means if the golden vector and the RTL output don't match:
_______________________________________________________________________________

---

## 5. The crosscheck: why it exists and what it proves

*Explain in 3–4 sentences what the crosscheck does and what "8/8 agreement" means.*

_______________________________________________________________________________
_______________________________________________________________________________
_______________________________________________________________________________

---

## 6. The four design decisions (DD-008 through DD-011)e

*For each decision, write one sentence explaining the choice and one sentence explaining the hardware consequence.*

**DD-008 — File formats for weights and manifest**

Choice:
_______________________________________________________________________________

Hardware consequence:
_______________________________________________________________________________

---

**DD-009 — Residual add via integer rescale**

Choice:
_______________________________________________________________________________

Hardware consequence (including the ≤1 LSB issue):
_______________________________________________________________________________

---

**DD-010 — Global average pool with folded division**

Choice:
_______________________________________________________________________________

Hardware consequence (why this matters for the Verilog):
_______________________________________________________________________________

---

**DD-011 — Integer logits and argmax**

Choice:
_______________________________________________________________________________

Hardware consequence:
_______________________________________________________________________________

---

## 7. The key number: accumulator bit-width

*What is the accumulator, and why does its bit-width matter for Verilog? What happens if you get it wrong?*

_______________________________________________________________________________
_______________________________________________________________________________

*What command tells you the actual required bit-width from your trained model?*

_______________________________________________________________________________

*Write the actual number from your run here when you have it:*

Max |accumulator|: _____  → requires _____ signed bits in the Verilog accumulator register.

---

## 8. The `M0` / `shift` insight

*Explain in plain words why M0 and shift must be loadable from files rather than hardcoded constants in the RTL. Connect it to what happens when the model is retrained.*

_______________________________________________________________________________
_______________________________________________________________________________
_______________________________________________________________________________

---

## 9. How this connects to the Verilog (Phase 3 preview)

*Complete this sentence for each file type:*

When I implement a conv layer in Verilog, I will load `_w.hex` by:
_______________________________________________________________________________

The testbench will verify correctness by:
_______________________________________________________________________________

If the testbench shows a mismatch at layer N, the first thing I check is:
_______________________________________________________________________________

---

## 10. Things I still don't fully understand (honest gaps)

*List any concepts that still feel unclear. These become questions for the next session.*

-
-
-

---

*End of document. Push to repo at: `docs/phase2_export_explained.md`*
