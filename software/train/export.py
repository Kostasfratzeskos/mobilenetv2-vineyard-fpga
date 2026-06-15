"""
export.py  --  Stage 2 of the custom integer reference.

Stage 1 (quantize.py) proved the int8 scheme is sound using FAKE-QUANT: the
model still ran in float, it just rounded values to int8-representable grids.
Fake-quant is great for measuring accuracy, but it is NOT a bit-exact spec for
hardware -- float rounding along the way is not guaranteed to match RTL in the
last LSB.

This file builds the TRUE INTEGER reference: every conv runs as
    int8 activations x int8 weights -> int32 accumulator
    + int32 bias
    -> requantize  (acc * M0) >> shift   with round-half-up
    -> ReLU6 clamp (where the layer has one)
    -> int8
using to_fixed_point() / requantize_int() from quantize.py -- the exact ops
your Verilog will perform. Whatever this file computes IS the specification
the hardware must reproduce bit-for-bit.

It produces three things:

  1. WEIGHT EXPORT (--outdir, default ../export):
       <layer>_w.hex      int8 weights, (OC, IC/groups, KH, KW) row-major
       <layer>_b.hex      int32 biases (BN already folded in)
       <layer>_m0.hex     int32 per-output-channel requant multipliers
       <layer>_shift.hex  uint8 per-output-channel requant shifts
       manifest.json      shapes, strides, scales, file map -- the single
                          source of truth for testbenches and later PS code

  2. GOLDEN VECTORS (--image, written to --golden-dir/<image-stem>/):
       000_input.hex, 001_features_0_0.hex, ... one int8 dump per op,
       plus the int32 raw logits and int16 requantized logits.
       Your testbenches $readmemh these and must match them EXACTLY.

  3. CROSSCHECK (--check N): runs N validation images through the integer
       pipeline and compares predictions against (a) the float model and
       (b) the Stage-1 fake-quant model. This proves the integer reference
       is correct BEFORE any RTL exists.

Design decisions realized here (record in docs/design_decisions.md):
  DD-008  Memory layout: activations (C,H,W) row-major, weights
          (OC, IC/g, KH, KW) row-major, one value per line in $readmemh hex.
  DD-009  Residual add: both branches are requantized to the FOLLOWING
          layer's input scale (each with its own M0/shift), added as
          integers, saturated to [-128,127]. May differ from fake-quant by
          <=1 LSB per element (double rounding) -- the integer version is
          the spec.
  DD-010  features.18 (last ReLU6 conv) output uses the fixed scale
          S_RELU6 = 6/127 (full ReLU6 range, no clipping possible).
          Global average pool = integer sum over 49 values + one
          per-tensor requantize to the classifier input scale.
  DD-011  Logits are requantized to a common int16 scale S_logit
          (calibrated from float logits with 1.2x headroom) so hardware
          argmax compares like with like; per-class M0/shift exported.

Run from inside software/train/ (next to quantize.py):

    python export.py --selftest
    python export.py --data ../../data/grape --ckpt ../runs/mobilenetv2_grape.pth \
                     --scales quant_scales.json \
                     --image  path/to/a_leaf.jpg \
                     --check 32
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from model.mobilenetv2 import load_checkpoint                      # noqa: E402
from dataset import make_eval_loader                               # noqa: E402
from quantize import (fuse_conv_bn, to_fixed_point, requantize_int,  # noqa: E402
                      sym_scale_from_absmax, apply_weight_fake_quant,
                      install_act_fake_quant, QMIN, QMAX)

S_RELU6 = 6.0 / 127.0          # DD-010: fixed scale for the conv18 output
LOGIT_BITS = 16                # DD-011: logits live in int16
LOGIT_QMAX = (1 << (LOGIT_BITS - 1)) - 1   # 32767


# ----------------------------------------------------------------------------
# VECTORIZED REQUANTIZE
#   Same math as quantize.requantize_int(), applied to whole numpy arrays.
#   acc is int64 (int32 range), M0 < 2^31, so acc*M0 < 2^58 -- fits int64.
#   numpy's >> on signed ints is an ARITHMETIC shift, same as Verilog '>>>'.
# ----------------------------------------------------------------------------
def requantize_arr(acc: np.ndarray, m0: np.ndarray, shift: np.ndarray) -> np.ndarray:
    acc = acc.astype(np.int64)
    m0 = np.asarray(m0, dtype=np.int64)
    shift = np.asarray(shift, dtype=np.int64)
    assert (shift > 0).all(), "non-positive requant shift; M >= 2^31 should be impossible"
    prod = acc * m0
    rnd = np.left_shift(np.int64(1), shift - 1)
    return np.right_shift(prod + rnd, shift)


def fixed_point_per_channel(M: np.ndarray):
    """to_fixed_point() over an array of multipliers -> (M0[i], shift[i])."""
    m0 = np.empty(len(M), dtype=np.int64)
    sh = np.empty(len(M), dtype=np.int64)
    for i, m in enumerate(M):
        m0[i], sh[i] = to_fixed_point(float(m))
    return m0, sh


def clamp_i8(a: np.ndarray) -> np.ndarray:
    return np.clip(a, QMIN, QMAX).astype(np.int8)


# ----------------------------------------------------------------------------
# HEX WRITERS  ($readmemh format: one value per line, two's complement)
# ----------------------------------------------------------------------------
def write_hex(path, arr: np.ndarray, bits: int):
    digits = bits // 4
    mask = (1 << bits) - 1
    flat = arr.astype(np.int64).reshape(-1)
    with open(path, "w") as f:
        f.write("\n".join(format(int(v) & mask, f"0{digits}x") for v in flat))
        f.write("\n")


# ----------------------------------------------------------------------------
# EXECUTION PLAN
#   We walk torchvision's MobileNetV2 structure (paper Table 2) and build an
#   ordered list of ops -- exactly what your hardware sequencer will do.
#   After fuse_conv_bn(), every Conv2dNormActivation is [Conv2d, Identity,
#   ReLU6] and every projection conv is a bare Conv2d followed by Identity.
# ----------------------------------------------------------------------------
class ConvOp:
    kind = "conv"
    def __init__(self, name, mod: nn.Conv2d, relu6: bool):
        self.name, self.mod, self.relu6 = name, mod, relu6
        self.s_in = self.s_out = None       # filled by assign_scales()
        self.wq = self.bq = self.m0 = self.shift = None
        self.q6 = None

class LinearOp:
    kind = "linear"
    def __init__(self, name, mod: nn.Linear):
        self.name, self.mod = name, mod
        self.s_in = self.s_out = None
        self.wq = self.bq = self.m0 = self.shift = None

class SaveInput:
    kind = "save"
    def __init__(self, tag): self.tag = tag; self.scale = None

class ResAdd:
    kind = "res_add"
    def __init__(self, tag, name):
        self.tag, self.name = tag, name
        self.s_save = self.s_target = None
        self.m0 = self.shift = None         # rescale of the saved branch

class GlobalAvgPool:
    kind = "gap"
    name = "avgpool"
    def __init__(self):
        self.s_in = self.s_out = None
        self.m0 = self.shift = None


def _convs_of_cna(seq: nn.Sequential):
    """(conv, has_relu6) for a fused Conv2dNormActivation."""
    conv = seq[0]
    assert isinstance(conv, nn.Conv2d)
    relu6 = any(isinstance(m, (nn.ReLU6, nn.ReLU)) for m in seq)
    return conv, relu6


def build_plan(fused: nn.Module):
    plan = []
    feats = fused.features

    conv, relu6 = _convs_of_cna(feats[0])
    plan.append(ConvOp("features.0.0", conv, relu6))

    for i in range(1, len(feats) - 1):                 # the 17 bottleneck blocks
        blk = feats[i]
        res = bool(getattr(blk, "use_res_connect", False))
        if res:
            plan.append(SaveInput(tag=i))
        for j, child in blk.conv.named_children():
            if isinstance(child, nn.Conv2d):           # projection (linear bottleneck)
                plan.append(ConvOp(f"features.{i}.conv.{j}", child, relu6=False))
            elif isinstance(child, nn.Sequential):     # Conv2dNormActivation
                conv, relu6 = _convs_of_cna(child)
                plan.append(ConvOp(f"features.{i}.conv.{j}.0", conv, relu6))
            # Identity (the folded BN) -> skip
        if res:
            plan.append(ResAdd(tag=i, name=f"features.{i}.add"))

    conv, relu6 = _convs_of_cna(feats[-1])
    plan.append(ConvOp(f"features.{len(feats)-1}.0", conv, relu6))
    plan.append(GlobalAvgPool())
    plan.append(LinearOp("classifier.1", fused.classifier[1]))
    return plan


# ----------------------------------------------------------------------------
# SCALE ASSIGNMENT + WEIGHT QUANTIZATION
#   Chains the per-tensor activation scales from quant_scales.json through the
#   plan: each op's OUTPUT scale is the INPUT scale of whatever consumes it.
# ----------------------------------------------------------------------------
def _next_scale(plan, k, act, s_logit):
    """The scale at which the output of plan[k] must be delivered."""
    for op in plan[k + 1:]:
        if op.kind in ("conv", "linear"):
            return act[op.name]
        if op.kind == "gap":
            return S_RELU6                  # DD-010
        # 'save' and 'res_add' don't quantize -- keep walking
    return s_logit                          # nothing after the classifier


def assign_scales(plan, act, s_logit):
    for k, op in enumerate(plan):
        if op.kind == "conv":
            op.s_in = act[op.name]
            op.s_out = _next_scale(plan, k, act, s_logit)
            w = op.mod.weight.detach().cpu()
            dims = tuple(range(1, w.dim()))
            ws = sym_scale_from_absmax(w.abs().amax(dim=dims)).numpy().astype(np.float64)
            op.w_scale = ws
            op.wq = clamp_i8(np.rint(w.numpy() / ws.reshape([-1] + [1] * (w.dim() - 1))))
            b = op.mod.bias
            bf = b.detach().cpu().numpy() if b is not None else np.zeros(w.shape[0])
            op.bq = np.rint(bf / (op.s_in * ws)).astype(np.int64)      # int32 range
            op.m0, op.shift = fixed_point_per_channel(op.s_in * ws / op.s_out)
            op.q6 = min(QMAX, int(round(6.0 / op.s_out))) if op.relu6 else None
        elif op.kind == "save":
            op.scale = _next_scale(plan, k, act, s_logit)   # scale of the block input
        elif op.kind == "res_add":
            save = next(o for o in plan if o.kind == "save" and o.tag == op.tag)
            op.s_save = save.scale
            op.s_target = _next_scale(plan, k, act, s_logit)
            m0, sh = to_fixed_point(op.s_save / op.s_target)
            op.m0, op.shift = np.array([m0]), np.array([sh])
        elif op.kind == "gap":
            op.s_in, op.s_out = S_RELU6, act["classifier.1"]
            m0, sh = to_fixed_point(op.s_in / (49.0 * op.s_out))       # /49 folded in
            op.m0, op.shift = np.array([m0]), np.array([sh])
        elif op.kind == "linear":
            op.s_in, op.s_out = act[op.name], s_logit
            w = op.mod.weight.detach().cpu()
            ws = sym_scale_from_absmax(w.abs().amax(dim=1)).numpy().astype(np.float64)
            op.w_scale = ws
            op.wq = clamp_i8(np.rint(w.numpy() / ws.reshape(-1, 1)))
            bf = op.mod.bias.detach().cpu().numpy()
            op.bq = np.rint(bf / (op.s_in * ws)).astype(np.int64)
            op.m0, op.shift = fixed_point_per_channel(op.s_in * ws / op.s_out)


# ----------------------------------------------------------------------------
# THE INTEGER EXECUTOR
#   Convolution trick: int8 x int8 products summed in float64 are EXACT as
#   long as |acc| < 2^53 (here |acc| < 2^31), so we can reuse F.conv2d for
#   the heavy lifting and still be bit-exact. We verify integrality anyway.
# ----------------------------------------------------------------------------
class IntExecutor:
    def __init__(self, plan):
        self.plan = plan
        self.max_abs_acc = 0                 # report for RTL accumulator sizing

    def _conv(self, op: ConvOp, q: np.ndarray) -> np.ndarray:
        x = torch.from_numpy(q.astype(np.float64))
        w = torch.from_numpy(op.wq.astype(np.float64))
        acc = F.conv2d(x, w, None, op.mod.stride, op.mod.padding,
                       op.mod.dilation, op.mod.groups).numpy()
        acc_i = np.rint(acc)
        assert np.abs(acc - acc_i).max() == 0.0, "conv accumulation not exact?!"
        acc_i = acc_i.astype(np.int64) + op.bq.reshape(1, -1, 1, 1)
        self.max_abs_acc = max(self.max_abs_acc, int(np.abs(acc_i).max()))
        out = requantize_arr(acc_i, op.m0.reshape(1, -1, 1, 1),
                             op.shift.reshape(1, -1, 1, 1))
        if op.relu6:
            out = np.clip(out, 0, op.q6)
        return clamp_i8(out)

    def run(self, q_input: np.ndarray, dump=None):
        """q_input: int8 (1,3,H,W). Returns (logits_i16, raw_acc_i32, pred_idx).
        dump: optional list collecting (name, int8/int array) per op."""
        q, saved = q_input, {}
        if dump is not None:
            dump.append(("input", q.copy()))
        for op in self.plan:
            if op.kind == "save":
                saved[op.tag] = q
            elif op.kind == "conv":
                q = self._conv(op, q)
                if dump is not None:
                    dump.append((op.name, q.copy()))
            elif op.kind == "res_add":
                res = requantize_arr(saved.pop(op.tag).astype(np.int64),
                                     op.m0, op.shift)
                q = clamp_i8(q.astype(np.int64) + res)
                if dump is not None:
                    dump.append((op.name, q.copy()))
            elif op.kind == "gap":
                s = q.astype(np.int64).sum(axis=(2, 3))            # (1,C)
                q = clamp_i8(requantize_arr(s, op.m0, op.shift))
                if dump is not None:
                    dump.append((op.name, q.copy()))
            elif op.kind == "linear":
                acc = op.wq.astype(np.int64) @ q.reshape(-1).astype(np.int64) + op.bq
                self.max_abs_acc = max(self.max_abs_acc, int(np.abs(acc).max()))
                logits = np.clip(requantize_arr(acc, op.m0, op.shift),
                                 -LOGIT_QMAX - 1, LOGIT_QMAX).astype(np.int16)
                if dump is not None:
                    dump.append((op.name + ".acc_int32", acc.astype(np.int64)))
                    dump.append((op.name + ".logits_int16", logits.copy()))
                return logits, acc, int(logits.argmax())
        raise RuntimeError("plan ended without a linear layer")


# ----------------------------------------------------------------------------
# INPUT QUANTIZATION  (the contract the PS preprocessing must reproduce)
# ----------------------------------------------------------------------------
def quantize_input(x_float: torch.Tensor, s_in: float) -> np.ndarray:
    """x_float: normalized float image (1,3,H,W) -> int8 at scale s_in."""
    return clamp_i8(np.rint(x_float.cpu().numpy() / s_in))


def preprocess_image(path, ckpt):
    from PIL import Image
    from torchvision import transforms
    img_size = ckpt.get("img_size", 224)
    mean = ckpt.get("norm_mean", (0.485, 0.456, 0.406))
    std = ckpt.get("norm_std", (0.229, 0.224, 0.225))
    tf = transforms.Compose([
        transforms.Resize(int(round(img_size * 256 / 224))),
        transforms.CenterCrop(img_size),
        transforms.ToTensor(),
        transforms.Normalize(mean, std),
    ])
    return tf(Image.open(path).convert("RGB")).unsqueeze(0)


# ----------------------------------------------------------------------------
# EXPORT
# ----------------------------------------------------------------------------
def _fname(name): return name.replace(".", "_")


def export_weights(plan, outdir):
    os.makedirs(outdir, exist_ok=True)
    entries = []
    for op in plan:
        e = {"kind": op.kind, "name": getattr(op, "name", op.kind)}
        if op.kind in ("conv", "linear"):
            base = _fname(op.name)
            write_hex(os.path.join(outdir, base + "_w.hex"), op.wq, 8)
            write_hex(os.path.join(outdir, base + "_b.hex"), op.bq, 32)
            write_hex(os.path.join(outdir, base + "_m0.hex"), op.m0, 32)
            write_hex(os.path.join(outdir, base + "_shift.hex"), op.shift, 8)
            e.update({
                "files": {k: f"{base}_{k}.hex" for k in ("w", "b", "m0", "shift")},
                "weight_shape": list(op.wq.shape),
                "s_in": float(op.s_in), "s_out": float(op.s_out),
                "w_scale": [float(v) for v in op.w_scale],
            })
            if op.kind == "conv":
                e.update({"stride": list(op.mod.stride),
                          "padding": list(op.mod.padding),
                          "groups": op.mod.groups,
                          "relu6": op.relu6,
                          "relu6_qmax": op.q6})
        elif op.kind == "res_add":
            e.update({"s_save": float(op.s_save), "s_target": float(op.s_target),
                      "m0": int(op.m0[0]), "shift": int(op.shift[0])})
        elif op.kind == "gap":
            e.update({"s_in": float(op.s_in), "s_out": float(op.s_out),
                      "m0": int(op.m0[0]), "shift": int(op.shift[0]),
                      "window": 49})
        elif op.kind == "save":
            e.update({"tag": op.tag, "scale": float(op.scale)})
        entries.append(e)
    return entries


def export_golden(executor, plan, ckpt, image_path, golden_dir, s_first):
    stem = os.path.splitext(os.path.basename(image_path))[0]
    gdir = os.path.join(golden_dir, stem)
    os.makedirs(gdir, exist_ok=True)
    x = preprocess_image(image_path, ckpt)
    q_in = quantize_input(x, s_first)

    dump = []
    logits, acc, pred = executor.run(q_in, dump=dump)

    files = []
    for seq, (name, arr) in enumerate(dump):
        bits = 8 if arr.dtype == np.int8 else (16 if arr.dtype == np.int16 else 32)
        fn = f"{seq:03d}_{_fname(name)}.hex"
        write_hex(os.path.join(gdir, fn), arr, bits)
        files.append({"seq": seq, "name": name, "file": fn,
                      "shape": list(arr.shape), "bits": bits})

    classes = ckpt["classes"]
    gman = {"image": os.path.abspath(image_path),
            "predicted_class": classes[pred],
            "logits_int16": [int(v) for v in logits],
            "layout": "activations (N,C,H,W) row-major, one value/line, $readmemh",
            "files": files}
    with open(os.path.join(gdir, "golden_manifest.json"), "w") as f:
        json.dump(gman, f, indent=2)
    return gdir, classes[pred]


# ----------------------------------------------------------------------------
# CROSSCHECK  -- integer pipeline vs float vs Stage-1 fake-quant
# ----------------------------------------------------------------------------
@torch.no_grad()
def crosscheck(executor, float_model, fq_model, loader, s_first, n_images, device):
    agree_float = agree_fq = total = 0
    for x, _ in loader:
        for i in range(x.shape[0]):
            if total >= n_images:
                break
            xi = x[i:i + 1].to(device)
            _, _, p_int = executor.run(quantize_input(xi, s_first))
            p_f = int(float_model(xi).argmax(1))
            p_q = int(fq_model(xi).argmax(1))
            agree_float += int(p_int == p_f)
            agree_fq += int(p_int == p_q)
            total += 1
        if total >= n_images:
            break
    return agree_float, agree_fq, total


# ----------------------------------------------------------------------------
# SELF TEST  (no data/checkpoint needed)
# ----------------------------------------------------------------------------
def selftest():
    import random
    ok = True

    # 1. vectorized requantize == scalar requantize_int, element for element
    worst = 0
    for _ in range(200):
        M = np.array([random.uniform(1e-5, 3.0) for _ in range(8)])
        m0, sh = fixed_point_per_channel(M)
        acc = np.random.randint(-(1 << 27), 1 << 27, size=(8,), dtype=np.int64)
        vec = requantize_arr(acc, m0, sh)
        for c in range(8):
            ref = requantize_int(int(acc[c]), int(m0[c]), int(sh[c]))
            worst = max(worst, abs(int(vec[c]) - ref))
    print(f"[requant-vec] max mismatch vs scalar reference: {worst} (expect 0)")
    ok &= worst == 0

    # 2. float64 conv trick is exact vs a naive integer loop
    rng = np.random.default_rng(0)
    xq = rng.integers(-128, 128, size=(1, 4, 8, 8)).astype(np.int64)
    wq = rng.integers(-128, 128, size=(6, 4, 3, 3)).astype(np.int64)
    acc_t = F.conv2d(torch.from_numpy(xq.astype(np.float64)),
                     torch.from_numpy(wq.astype(np.float64)),
                     None, 1, 1).numpy().astype(np.int64)
    xp = np.pad(xq, ((0, 0), (0, 0), (1, 1), (1, 1)))
    acc_ref = np.zeros_like(acc_t)
    for o in range(6):
        for r in range(8):
            for c in range(8):
                acc_ref[0, o, r, c] = int((xp[0, :, r:r + 3, c:c + 3] * wq[o]).sum())
    exact = int(np.abs(acc_t - acc_ref).max())
    print(f"[conv-int]    max |float64 conv - integer loop|: {exact} (expect 0)")
    ok &= exact == 0

    # 3. depthwise (groups) path
    xq = rng.integers(-128, 128, size=(1, 6, 8, 8)).astype(np.int64)
    wd = rng.integers(-128, 128, size=(6, 1, 3, 3)).astype(np.int64)
    acc_t = F.conv2d(torch.from_numpy(xq.astype(np.float64)),
                     torch.from_numpy(wd.astype(np.float64)),
                     None, 1, 1, 1, 6).numpy().astype(np.int64)
    xp = np.pad(xq, ((0, 0), (0, 0), (1, 1), (1, 1)))
    acc_ref = np.zeros_like(acc_t)
    for ch in range(6):
        for r in range(8):
            for c in range(8):
                acc_ref[0, ch, r, c] = int((xp[0, ch, r:r + 3, c:c + 3] * wd[ch, 0]).sum())
    exact = int(np.abs(acc_t - acc_ref).max())
    print(f"[conv-dw]     max |float64 dwconv - integer loop|: {exact} (expect 0)")
    ok &= exact == 0

    # 4. hex round-trip
    import tempfile
    a = rng.integers(-128, 128, size=(37,)).astype(np.int8)
    tmp = os.path.join(tempfile.gettempdir(), "_export_selftest.hex")
    write_hex(tmp, a, 8)
    with open(tmp) as fh:
        back = np.array([int(l, 16) for l in fh if l.strip()],
                        dtype=np.uint8).astype(np.int8)
    os.remove(tmp)
    rt = int((a != back).sum())
    print(f"[hex]         int8 round-trip mismatches: {rt} (expect 0)")
    ok &= rt == 0

    print("SELFTEST", "PASSED" if ok else "FAILED")
    return ok


# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="dataset root (for crosscheck + logit calibration)")
    ap.add_argument("--ckpt", help="float checkpoint from Phase 1")
    ap.add_argument("--scales", default="quant_scales.json",
                    help="activation scales from quantize.py (Stage 1)")
    ap.add_argument("--outdir", default="../export",
                    help="where weight/M0/shift hex + manifest.json go")
    ap.add_argument("--image", help="image to dump golden vectors for")
    ap.add_argument("--golden-dir", default="../golden")
    ap.add_argument("--check", type=int, default=32,
                    help="crosscheck N val images (0 to skip)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(0 if selftest() else 1)
    if not (args.data and args.ckpt):
        ap.error("--data and --ckpt are required (or use --selftest)")

    device = "cpu"   # bit-exact reference: keep everything deterministic on CPU
    print("loading checkpoint + scales...")
    model, ckpt = load_checkpoint(args.ckpt, map_location=device)
    model.to(device).eval()
    with open(args.scales) as f:
        scales = json.load(f)
    act = {n: float(d["act_scale"]) for n, d in scales["layers"].items()}

    fused = fuse_conv_bn(model).to(device).eval()

    # ---- logit scale calibration (DD-011): float logits over a few batches ----
    loader, classes = make_eval_loader(args.data, batch_size=32,
                                       img_size=ckpt.get("img_size", 224),
                                       num_workers=0)
    absmax = 0.0
    with torch.no_grad():
        for bi, (x, _) in enumerate(loader):
            absmax = max(absmax, float(fused(x.to(device)).abs().max()))
            if bi >= 3:
                break
    s_logit = absmax * 1.2 / LOGIT_QMAX
    print(f"logit |max| = {absmax:.3f}  ->  S_logit = {s_logit:.6e} (int16)")

    # ---- build + quantize the plan ----
    plan = build_plan(fused)
    n_compute = sum(1 for op in plan if op.kind in ("conv", "linear"))
    missing = [op.name for op in plan if op.kind in ("conv", "linear")
               and op.name not in act]
    assert not missing, f"plan layers missing from {args.scales}: {missing}"
    print(f"plan: {len(plan)} ops ({n_compute} conv/linear) -- "
          f"json has {len(act)} layers")
    assign_scales(plan, act, s_logit)

    # ---- export weights + manifest ----
    entries = export_weights(plan, args.outdir)
    s_first = act["features.0.0"]
    manifest = {
        "scheme": scales["scheme"],
        "classes": classes,
        "img_size": ckpt.get("img_size", 224),
        "norm_mean": ckpt.get("norm_mean"), "norm_std": ckpt.get("norm_std"),
        "input_scale": s_first,
        "input_quant": "q = clamp(round((pixel/255 - mean)/std / input_scale), -128, 127)",
        "s_relu6": S_RELU6, "s_logit": s_logit, "logit_bits": LOGIT_BITS,
        "layout": {"activations": "(N,C,H,W) row-major",
                   "weights": "(OC, IC/groups, KH, KW) row-major",
                   "hex": "one value per line, two's complement, $readmemh"},
        "ops": entries,
    }
    with open(os.path.join(args.outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote weights + manifest.json -> {args.outdir}")

    executor = IntExecutor(plan)

    # ---- crosscheck: integer pipeline vs float vs fake-quant ----
    if args.check > 0:
        print(f"\ncrosscheck on {args.check} val images "
              f"(integer vs float vs fake-quant)...")
        fq = fuse_conv_bn(model).to(device).eval()
        apply_weight_fake_quant(fq)
        install_act_fake_quant(fq, {n: torch.tensor(s) for n, s in act.items()})
        a_f, a_q, n = crosscheck(executor, model, fq, loader, s_first,
                                 args.check, device)
        print(f"  agree with FLOAT     model: {a_f}/{n}")
        print(f"  agree with FAKE-QUANT model: {a_q}/{n}")
        bits = int(np.ceil(np.log2(max(executor.max_abs_acc, 1))) + 1)
        print(f"  max |accumulator| seen: {executor.max_abs_acc} "
              f"-> needs {bits} signed bits (record for RTL sizing)")
        if a_q < n:
            print("  NOTE: <=1-2 disagreements vs fake-quant can be legitimate "
                  "(DD-009 double-rounding); investigate if larger.")

    # ---- golden vectors ----
    if args.image:
        gdir, pred = export_golden(executor, plan, ckpt, args.image,
                                   args.golden_dir, s_first)
        print(f"\ngolden vectors -> {gdir}")
        print(f"predicted class for golden image: {pred}")
    else:
        print("\nno --image given: skipped golden vectors. Re-run with --image "
              "to dump them (takes seconds).")


if __name__ == "__main__":
    main()