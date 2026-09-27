"""Decode each golden set's source JPEG to raw RGB, and prove the front end exact.

Two jobs, and the second is the reason this is a tracked script rather than a
scratch probe.

1.  Write `000_rgb256.bin` beside each golden set's `000_input.hex`: the decoded
    source image, 256x256x3 uint8, HWC interleaved, 196,608 bytes. That is the
    INPUT to firmware/src/preproc.c, and 000_input.hex is the expected OUTPUT, so
    the pair is a complete test vector for the C front end - and not an invented
    one: 000_input.hex is the exact tensor the hardware's 6,895,780-element check
    starts from, so verifying against it joins the two claims end to end.

2.  Re-derive 000_input.hex here, in Python, from that same RGB, and report
    whether it matches bit-for-bit. This is the measurement the whole
    preprocessing design rests on, so it belongs in the repository where anyone
    can re-run it, not in a transcript:

        crop the centre 224x224      (an integer crop - see below)
        q = clamp(rint((p/255 - mean)/std / input_scale), -128, 127)

    reproduces all five reproducible golden tensors EXACTLY, 150,528 values each.

---- why there is no resampler here, which was the surprise -----------------

predict.py's pipeline is Resize(256) -> CenterCrop(224) -> ToTensor -> Normalize.
Reimplementing Pillow's antialiased resampler in C to the last bit is not a
reasonable thing to attempt, so bit-exactness looked out of reach and a bounded
difference looked like the honest goal.

But all 13,089 images in data/grape and data/grape_clean are already 256x256.
Resize(256) is therefore the identity, and CenterCrop(224) is a pure integer crop
at offset (256-224)/2 = 16. No pixel is ever interpolated. That is checked below
per image rather than trusted, and an image of any other size is reported and
skipped - because for such an image the C front end would need a resampler that
nothing in this repository verifies, and preproc_rgb refuses it for that reason.

---- the rounding ----------------------------------------------------------

`round` in the manifest's formula is torch.round: round-half-to-EVEN, which is
numpy's rint and C's lrint in the default mode. floor(x + 0.5) is a different
function and differs on the values landing on .5.

Run: python scripts/gen_preproc_vectors.py
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GOLD_DIR = os.path.join(ROOT, "software", "golden")
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")
RGB_NAME = "000_rgb256.bin"


def load_golden_input(path):
    """000_input.hex: one byte per line, CHW row-major, int8 two's complement."""
    vals = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                vals.append(int(ln, 16))
    return np.array(vals, dtype=np.uint8).astype(np.int8)


def quantise(crop_hwc, mean, std, scale):
    """The manifest's formula, in the manifest's order.

    Kept unfused on purpose: folding 1/(255*std*scale) into one constant is
    algebraically equal but not bit-equal, and the goldens were made with this
    order. firmware/src/preproc.c writes the same three steps.
    """
    x = (crop_hwc / 255.0)
    x = (x - mean) / std
    x = x / scale
    return np.clip(np.rint(x), -128, 127).astype(np.int8)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--golden-dir", default=GOLD_DIR)
    ap.add_argument("--set", default=None,
                    help="only this golden set (default: all of them)")
    ap.add_argument("--check-only", action="store_true",
                    help="verify, but do not write the .bin files")
    args = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as fh:
        man = json.load(fh)
    size = int(man["img_size"])
    mean = np.array(man["norm_mean"], dtype=np.float64)
    std = np.array(man["norm_std"], dtype=np.float64)
    scale = float(man["input_scale"])
    src_size = 256
    off = (src_size - size) // 2

    print(f"manifest: crop {size}, input_scale {scale!r}")
    print(f"          mean {[float(v) for v in mean]}")
    print(f"          std  {[float(v) for v in std]}")
    print(f"          centre crop at offset {off} of a {src_size}x{src_size} "
          f"source (no resampling)")
    print()

    names = ([args.set] if args.set else
             sorted(d for d in os.listdir(args.golden_dir)
                    if os.path.isdir(os.path.join(args.golden_dir, d))))

    exact = 0
    wrote = 0
    problems = []
    for name in names:
        d = os.path.join(args.golden_dir, name)
        gm = os.path.join(d, "golden_manifest.json")
        gi = os.path.join(d, "000_input.hex")
        if not (os.path.exists(gm) and os.path.exists(gi)):
            print(f"  {name:16s} no golden_manifest.json/000_input.hex, skipped")
            continue
        with open(gm, encoding="utf-8") as fh:
            g = json.load(fh)
        img_path = g.get("image")
        if not img_path or not os.path.exists(img_path):
            #  image_1 is the known case: its source is gone from data/ and its
            #  checkpoint was overwritten. Nothing to do but say so.
            print(f"  {name:16s} source image not present, skipped")
            continue

        im = Image.open(img_path).convert("RGB")
        iw, ih = im.size
        if (iw, ih) != (src_size, src_size):
            #  Checked, not assumed. If this ever fires, the C front end's
            #  premise is gone for that image and preproc_rgb will refuse it.
            msg = (f"{name}: source is {iw}x{ih}, not {src_size}x{src_size} - "
                   f"a verified resampler would be needed")
            print(f"  {name:16s} {msg}")
            problems.append(msg)
            continue

        rgb = np.asarray(im, dtype=np.uint8)            # HWC
        crop = rgb[off:off + size, off:off + size, :].astype(np.float64)
        q_hwc = quantise(crop, mean, std, scale)

        #  The golden is CHW; the crop is HWC. Transposing the COMPUTED tensor
        #  rather than the golden keeps the golden byte-order authoritative.
        got = np.transpose(q_hwc, (2, 0, 1)).reshape(-1)
        want = load_golden_input(gi)

        if got.shape != want.shape:
            msg = f"{name}: computed {got.shape} but golden is {want.shape}"
            print(f"  {name:16s} {msg}")
            problems.append(msg)
            continue

        diff = got.astype(np.int32) - want.astype(np.int32)
        nbad = int((diff != 0).sum())
        if nbad:
            msg = (f"{name}: {nbad:,} of {got.size:,} values differ, "
                   f"max |diff| {int(np.abs(diff).max())}")
            print(f"  {name:16s} {msg}")
            problems.append(msg)
            continue

        exact += 1
        note = ""
        if not args.check_only:
            #  HWC uint8, C-contiguous - byte (y*256 + x)*3 + c, which is what
            #  preproc_rgb indexes and what a decoder produces.
            out = os.path.join(d, RGB_NAME)
            with open(out, "wb") as fh:
                fh.write(np.ascontiguousarray(rgb).tobytes())
            wrote += 1
            note = f"  -> {RGB_NAME} ({rgb.size:,} bytes)"
        print(f"  {name:16s} BIT-EXACT, {got.size:,} values{note}")

    print()
    print(f"{exact} golden tensor(s) reproduced bit-exactly from the source JPEG")
    if wrote:
        print(f"{wrote} RGB test vector(s) written - firmware/test/test_preproc.c "
              f"reads them")
    if problems:
        print()
        print(f"{len(problems)} PROBLEM(S):")
        for p in problems:
            print("  " + p)
        return 1
    return 0 if exact else 1


if __name__ == "__main__":
    sys.exit(main())
