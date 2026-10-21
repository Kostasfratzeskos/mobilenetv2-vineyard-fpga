"""Check a frame the board saved: same window, same tensor, same four logits.

    python scripts/check_camera_frame.py <dir>/vinecam_0003

reads the four files vinecam wrote when S was pressed (firmware/linux/include/
dump.h) and re-derives every number from the picture alone, on the PC, with the
reference implementations:

    1. the WINDOW   torchvision's Resize(256), exactly as predict.py and export.py
                    build it, on _frame.ppm; the 256x256 window at the dump's
                    offsets must equal _rgb256.bin byte for byte. This is
                    firmware/linux/src/camfront.c checked on a REAL camera
                    frame, not a test pattern.
    2. the TENSOR   export.py's preprocess_image + quantize_input on the same
                    frame must equal _input.bin, all 150,528 values. This is
                    camfront + preproc.c together.
    3. the LOGITS   export.py's IntExecutor - the integer source of truth - on
                    that tensor must give the four logits the accelerator
                    returned. This is the accelerator on this frame.

So a frame that passes is one where the board's answer is, provably, the model's
answer for that picture. What it does NOT check is the step before the picture:
the camera's YUV to RGB conversion, which has no reference to be exact against
(camfront.h). The frame is saved after it, so every check starts from the RGB
the board actually used.

A dump made on a PC by tools/render_ui --dump has no logits; step 3 then prints
the reference logits instead of comparing.

---- why step 2 can demand bit-equality -------------------------------------

The reference normalises in float32 (ToTensor, Normalize) and preproc.c in
float64. They could disagree near a rounding tie. They do not: the map has only
768 inputs (3 channels x 256 byte values), and all 768 agree - the float32 path
never comes closer than 6.6e-05 to a .5. (Measured; recorded in DD-035.)
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")
CKPT = os.path.join(ROOT, "software", "runs", "mobilenetv2_grape.pth")
SCALES = os.path.join(ROOT, "software", "train", "quant_scales.json")

WIN = 256
CROP_OFF = 16


def read_dump_txt(path):
    info = {}
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            if ":" not in ln:
                continue
            k, v = ln.split(":", 1)
            info[k.strip()] = v.strip()
    ints = lambda k: [int(t) for t in info[k].split()] if k in info else None
    return {k: ints(k) for k in ("frame", "resize", "crop", "window", "logits")}, info


def count_diff(a, b, what):
    a = np.asarray(a).reshape(-1).astype(np.int32)
    b = np.asarray(b).reshape(-1).astype(np.int32)
    if a.size != b.size:
        print(f"  [FAIL] {what}: {a.size:,} values on the board, {b.size:,} in the reference")
        return False
    n = int((a != b).sum())
    if n:
        print(f"  [FAIL] {what}: {n:,} of {a.size:,} values differ, max |diff| "
              f"{int(np.abs(a - b).max())}")
        return False
    print(f"  [ ok ] {what}: all {a.size:,} values identical")
    return True


def reference_executor(manifest):
    """export.py's IntExecutor, built the way export.py builds it, with the
    manifest's logit scale. Refuses a checkpoint that is not the one the
    exported blobs - the ones on the board - were made from."""
    sys.path.insert(0, os.path.join(ROOT, "software", "train"))
    import export  # noqa: E402  (software/train/export.py)

    sha = export.sha256_file(CKPT)
    if sha != manifest["ckpt_sha256"]:
        raise SystemExit(f"  {CKPT} is not the checkpoint the board's blobs come from "
                         f"(sha {sha[:12]} vs manifest {manifest['ckpt_sha256'][:12]})")
    model, ckpt = export.load_checkpoint(CKPT, map_location="cpu")
    model.eval()
    with open(SCALES, encoding="utf-8") as fh:
        scales = json.load(fh)
    act = {n: float(d["act_scale"]) for n, d in scales["layers"].items()}
    plan = export.build_plan(export.fuse_conv_bn(model).eval())
    export.assign_scales(plan, act, float(manifest["s_logit"]))
    return export, export.IntExecutor(plan), ckpt


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dump", help="the prefix, e.g. dumps/vinecam_0003")
    ap.add_argument("--no-model", action="store_true",
                    help="check the window and tensor only (no torch model load)")
    args = ap.parse_args()

    geo, info = read_dump_txt(args.dump + ".txt")
    with open(MANIFEST, encoding="utf-8") as fh:
        manifest = json.load(fh)
    img_size = int(manifest["img_size"])
    s_in = float(manifest["input_scale"])

    frame_path = args.dump + "_frame.ppm"
    pil = Image.open(frame_path).convert("RGB")
    print(f"frame  : {frame_path}  {pil.size[0]}x{pil.size[1]}  ({info.get('source', '?')})")
    ok = True

    if list(pil.size) != geo["frame"]:
        print(f"  [FAIL] the .txt says {geo['frame']}, the picture is {list(pil.size)}")
        return 1

    # ---- 1: the window ---------------------------------------------------
    from torchvision import transforms
    rs = transforms.Resize(int(round(img_size * 256 / 224)))(pil)
    rs_arr = np.asarray(rs, dtype=np.uint8)
    cx = int(round((rs.size[0] - img_size) / 2.0))
    cy = int(round((rs.size[1] - img_size) / 2.0))
    if list(rs.size) != geo["resize"] or [cx, cy] != geo["crop"]:
        print(f"  [FAIL] geometry: board resize {geo['resize']} crop {geo['crop']}, "
              f"torchvision {list(rs.size)} crop {[cx, cy]}")
        ok = False
    wx, wy = cx - CROP_OFF, cy - CROP_OFF
    want_win = rs_arr[wy:wy + WIN, wx:wx + WIN]
    got_win = np.fromfile(args.dump + "_rgb256.bin", dtype=np.uint8)
    ok &= count_diff(got_win, want_win, "window  (camfront.c vs torchvision Resize)")

    # ---- 2: the tensor ---------------------------------------------------
    import torch  # noqa: E402
    tf = transforms.Compose([
        transforms.Resize(int(round(img_size * 256 / 224))),
        transforms.CenterCrop(img_size),
        transforms.ToTensor(),
        transforms.Normalize(manifest["norm_mean"], manifest["norm_std"]),
    ])
    x = tf(pil).unsqueeze(0)
    q_chw = np.clip(np.rint(x.numpy() / s_in), -128, 127).astype(np.int8)   # (1,3,H,W)
    got_q = np.fromfile(args.dump + "_input.bin", dtype=np.int8)
    if got_q.size == img_size * img_size * 3:
        got_chw = got_q.reshape(img_size, img_size, 3).transpose(2, 0, 1)[None]   # HWC -> CHW
    else:
        got_chw = got_q
    ok &= count_diff(got_chw, q_chw, "tensor  (camfront + preproc.c vs torchvision + export.py)")

    # ---- 3: the logits ---------------------------------------------------
    if not args.no_model:
        export, ex, ckpt = reference_executor(manifest)
        q_ref = export.quantize_input(export.preprocess_image(frame_path, ckpt), s_in)
        if not np.array_equal(q_ref, q_chw):
            print("  [FAIL] export.preprocess_image disagrees with the pipeline above")
            ok = False
        logits, _, pred = ex.run(q_ref)
        names = manifest["classes"]
        ref = [int(v) for v in logits]
        if geo["logits"] is None:
            print(f"  [info] reference logits {ref}, class {pred} = {names[pred]} "
                  f"(this dump has no board logits to compare)")
        elif geo["logits"] == ref:
            print(f"  [ ok ] logits  {ref} = the accelerator's, class {pred} = {names[pred]}")
        else:
            print(f"  [FAIL] logits: board {geo['logits']}, reference {ref}")
            ok = False

    if not ok:
        print("FAIL")
    elif geo["logits"] is not None and not args.no_model:
        print("PASS - the board's answer for this frame is the model's answer")
    else:
        print("PASS - the C front end produced torchvision's window and tensor "
              "for this frame")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
