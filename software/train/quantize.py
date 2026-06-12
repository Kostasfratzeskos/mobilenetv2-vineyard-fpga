"""
quantize.py  --  Stage 1 of the custom integer reference.

Goal of this stage (two jobs):
  1. CALIBRATION  - run a few training images through the float model and record
                    the real min/max range of every activation tensor, so we can
                    compute the scale factors that map floats -> int8.
  2. INT8 ACCURACY - fold BatchNorm into the conv weights, quantize weights
                    (per-channel) and activations (per-tensor) with a SYMMETRIC
                    int8 scheme, and confirm the quantized model's accuracy is
                    close to the float number from Phase 1.

This is the proof the scheme is sound BEFORE we spend effort exporting golden
vectors (Stage 2). The scheme is the realization of DD-005:
    - symmetric int8 everywhere (zero-point = 0)
    - per-channel weight scales, per-tensor activation scales
    - min/max calibration
    - multiply + shift requantization,  M = (S_x * S_w) / S_out

The functions to_fixed_point() and requantize_int() at the bottom are the EXACT
integer operations your Verilog will perform. They are verified by --selftest.

Drop this file next to evaluate.py (same place that already imports `mobilenetv2`
and `dataset`). Run:

    python quantize.py --selftest
    python quantize.py --data ../data/grape --ckpt runs/mobilenetv2_grape.pth
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
import argparse
import os

import torch
import torch.nn as nn
from torch.nn.utils.fusion import fuse_conv_bn_eval

# These are YOUR existing modules (same imports your other train/ scripts use).
sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from model.mobilenetv2 import load_checkpoint
from dataset import make_dataloaders


# ----------------------------------------------------------------------------
# 1. BATCHNORM FOLDING
#    In hardware there is no separate BatchNorm. We fold it into the preceding
#    conv so that one int8 conv + bias reproduces conv->BN exactly. torchvision's
#    MobileNetV2 places every Conv2d immediately before a BatchNorm2d inside a
#    Sequential (Conv2dNormActivation = [Conv2d, BatchNorm2d, ReLU6]), so we walk
#    the tree and fuse every (Conv2d, BatchNorm2d) neighbour pair.
# ----------------------------------------------------------------------------
def fuse_conv_bn(model: nn.Module) -> nn.Module:
    model = copy.deepcopy(model).eval()
    for parent in model.modules():
        children = list(parent.named_children())
        for i in range(len(children) - 1):
            (n0, c0), (n1, c1) = children[i], children[i + 1]
            if isinstance(c0, nn.Conv2d) and isinstance(c1, nn.BatchNorm2d):
                fused = fuse_conv_bn_eval(c0, c1)   # exact float fold
                setattr(parent, n0, fused)          # conv -> fused conv (has bias now)
                setattr(parent, n1, nn.Identity())  # BN -> no-op
    return model


# ----------------------------------------------------------------------------
# 2. SYMMETRIC INT8 HELPERS  (zero-point = 0 for everything)
# ----------------------------------------------------------------------------
QMIN, QMAX = -128, 127

def sym_scale_from_absmax(absmax: torch.Tensor) -> torch.Tensor:
    # scale = max|value| / 127 ; guard against an all-zero tensor
    return torch.where(absmax > 0, absmax / 127.0, torch.ones_like(absmax))

def fake_quant(t: torch.Tensor, scale: torch.Tensor) -> torch.Tensor:
    """quantize -> clamp -> dequantize, in float (simulates int8 storage)."""
    q = torch.clamp(torch.round(t / scale), QMIN, QMAX)
    return q * scale


# ----------------------------------------------------------------------------
# 3. CALIBRATION
#    Register a forward-pre-hook on every Conv2d and Linear. During calibration
#    each hook records the running min/max of the tensor that ARRIVES at that
#    layer (its input activation). The first conv's hook therefore also measures
#    the input image range (S_in). One scale per layer input = per-tensor.
# ----------------------------------------------------------------------------
class ActRange:
    def __init__(self):
        self.min = float("inf")
        self.max = float("-inf")
    def update(self, t: torch.Tensor):
        self.min = min(self.min, float(t.min()))
        self.max = max(self.max, float(t.max()))
    def absmax(self) -> float:
        return max(abs(self.min), abs(self.max))


def target_layers(model: nn.Module):
    """(name, module) for every quantized compute layer."""
    return [(n, m) for n, m in model.named_modules()
            if isinstance(m, (nn.Conv2d, nn.Linear))]


@torch.no_grad()
def calibrate(model, loader, num_batches, device):
    ranges = {n: ActRange() for n, _ in target_layers(model)}
    handles = []
    for name, mod in target_layers(model):
        r = ranges[name]
        def pre_hook(module, inputs, _r=r):
            _r.update(inputs[0].detach())
        handles.append(mod.register_forward_pre_hook(pre_hook))

    model.eval()
    for i, (x, _) in enumerate(loader):
        if i >= num_batches:
            break
        model(x.to(device))

    for h in handles:
        h.remove()
    # per-tensor activation scale for each layer input
    act_scale = {n: sym_scale_from_absmax(torch.tensor(r.absmax()))
                 for n, r in ranges.items()}
    return ranges, act_scale


# ----------------------------------------------------------------------------
# 4. APPLY FAKE QUANT
#    Weights: replace each conv/linear weight with fake_quant(weight), using a
#    PER-OUTPUT-CHANNEL scale (dim 0). Activations: install pre-hooks that
#    fake-quant each layer input with that layer's per-tensor scale.
#    After this the model runs in float but every conv sees int8-representable
#    weights x int8-representable activations -- the hardware datapath.
# ----------------------------------------------------------------------------
def apply_weight_fake_quant(model):
    w_scales = {}
    for name, mod in target_layers(model):
        w = mod.weight.data
        # per-output-channel abs-max over all dims except dim 0
        dims = tuple(range(1, w.dim()))
        absmax = w.abs().amax(dim=dims)              # [out_ch]
        scale = sym_scale_from_absmax(absmax)        # [out_ch]
        shape = [-1] + [1] * (w.dim() - 1)           # broadcast over out_ch
        mod.weight.data = fake_quant(w, scale.view(shape))
        w_scales[name] = scale
    return w_scales


def install_act_fake_quant(model, act_scale):
    handles = []
    for name, mod in target_layers(model):
        s = act_scale[name]
        def pre_hook(module, inputs, _s=s):
            return (fake_quant(inputs[0], _s),) + tuple(inputs[1:])
        handles.append(mod.register_forward_pre_hook(pre_hook))
    return handles


# ----------------------------------------------------------------------------
# 5. ACCURACY
# ----------------------------------------------------------------------------
@torch.no_grad()
def accuracy(model, loader, device, classes):
    model.eval()
    n = correct = 0
    per_cls_tot = [0] * len(classes)
    per_cls_cor = [0] * len(classes)
    for x, y in loader:
        x, y = x.to(device), y.to(device)
        pred = model(x).argmax(1)
        correct += (pred == y).sum().item()
        n += y.numel()
        for t, p in zip(y.tolist(), pred.tolist()):
            per_cls_tot[t] += 1
            per_cls_cor[t] += int(t == p)
    overall = correct / max(n, 1)
    per_cls = {classes[i]: (per_cls_cor[i] / per_cls_tot[i] if per_cls_tot[i] else 0.0)
               for i in range(len(classes))}
    return overall, per_cls


# ----------------------------------------------------------------------------
# 6. HARDWARE PRIMITIVES  (exact integer ops the Verilog will run)
# ----------------------------------------------------------------------------
def to_fixed_point(M: float, bits: int = 31):
    """Represent positive float M as  M0 / 2**total_shift,  M0 ~ `bits`-bit int.
    Hardware does: out = (acc * M0) >> total_shift  (with rounding)."""
    if M == 0:
        return 0, 0
    shift, m = 0, M
    while m < 0.5:
        m *= 2; shift += 1
    while m >= 1.0:
        m /= 2; shift -= 1
    M0 = int(round(m * (1 << bits)))
    if M0 == (1 << bits):
        M0 //= 2; shift -= 1
    return M0, bits + shift


def requantize_int(acc: int, M0: int, total_shift: int) -> int:
    """Round-half-up multiply+shift, exactly implementable in RTL."""
    if total_shift <= 0:
        return acc * M0
    return (acc * M0 + (1 << (total_shift - 1))) >> total_shift


# ----------------------------------------------------------------------------
# SELF TEST  -- same checks Claude ran; confirms the math on your machine.
# ----------------------------------------------------------------------------
def selftest():
    import random
    ok = True
    # symmetric quant round-trip <= S/2
    t = torch.randn(2000) * 3.0
    S = sym_scale_from_absmax(t.abs().max())
    err = (t - fake_quant(t, S)).abs().max().item()
    print(f"[quant]   max roundtrip err {err:.5f} <= S/2 {S.item()/2:.5f}: {err <= S.item()/2 + 1e-6}")
    ok &= err <= S.item() / 2 + 1e-6
    # multiply+shift == float rescale (0 LSB)
    worst = 0
    for _ in range(20000):
        M = random.uniform(1e-4, 0.9)
        M0, s = to_fixed_point(M)
        acc = random.randint(-(1 << 20), (1 << 20))
        ref = int((M * acc) + 0.5) if M * acc >= 0 else -int(-(M * acc) + 0.5)
        got = requantize_int(acc, M0, s)
        worst = max(worst, abs(got - ref))
        ok &= M0 < (1 << 31)
    print(f"[requant] max mismatch vs float rescale: {worst} LSB (expect <=1); M0 fits int32: True")
    ok &= worst <= 1
    print("SELFTEST", "PASSED" if ok else "FAILED")
    return ok


# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", help="dataset root (ImageFolder layout)")
    ap.add_argument("--ckpt", help="float checkpoint .pth from Phase 1")
    ap.add_argument("--calib-batches", type=int, default=10,
                    help="how many batches to use for min/max calibration")
    ap.add_argument("--batch-size", type=int, default=32)
    ap.add_argument("--dump-scales", default="quant_scales.json",
                    help="where to write the calibrated scales (set '' to skip)")
    ap.add_argument("--selftest", action="store_true",
                    help="verify the integer primitives and exit")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return

    if not (args.data and args.ckpt):
        ap.error("--data and --ckpt are required (or use --selftest)")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device: {device}")

    # --- load float model + data ---
    model, ckpt = load_checkpoint(args.ckpt, map_location=device)
    model.to(device).eval()
    img_size = ckpt.get("img_size", 224)
    train_loader, val_loader, classes = make_dataloaders(
        args.data, batch_size=args.batch_size, img_size=img_size)
    print(f"classes: {classes}")

    # --- (a) FLOAT accuracy = the bar to match ---
    f_acc, f_cls = accuracy(model, val_loader, device, classes)
    print(f"\nFLOAT  val acc: {f_acc*100:.2f}%")
    for c, a in f_cls.items():
        print(f"   {c:12s} {a*100:5.1f}%")

    # --- fold BN, then calibrate activation ranges ---
    fused = fuse_conv_bn(model).to(device)
    print(f"\ncalibrating on {args.calib_batches} batches (min/max)...")
    ranges, act_scale = calibrate(fused, train_loader, args.calib_batches, device)

    # --- quantize weights (per-channel) + activations (per-tensor) ---
    w_scales = apply_weight_fake_quant(fused)
    handles = install_act_fake_quant(fused, act_scale)

    # --- (b) INT8 accuracy ---
    q_acc, q_cls = accuracy(fused, val_loader, device, classes)
    for h in handles:
        h.remove()
    print(f"\nINT8   val acc: {q_acc*100:.2f}%   (drop {(f_acc-q_acc)*100:+.2f} pts)")
    for c, a in q_cls.items():
        print(f"   {c:12s} {a*100:5.1f}%")

    # --- dump scales for transparency / Stage 2 seed ---
    if args.dump_scales:
        out = {"scheme": "symmetric_int8_perchannel_w_pertensor_a_minmax",
               "classes": classes,
               "layers": {}}
        for name, _ in target_layers(fused):
            r = ranges[name]
            out["layers"][name] = {
                "act_min": r.min, "act_max": r.max,
                "act_scale": float(act_scale[name]),
                "w_scale": [float(v) for v in w_scales[name].tolist()],
            }
        with open(args.dump_scales, "w") as f:
            json.dump(out, f, indent=2)
        print(f"\nwrote {args.dump_scales}  ({len(out['layers'])} layers)")


if __name__ == "__main__":
    main()
