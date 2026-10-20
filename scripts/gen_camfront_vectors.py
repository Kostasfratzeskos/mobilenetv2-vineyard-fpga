"""The camera front end's known answers, made with the real torchvision and Pillow.

firmware/linux/src/camfront.c claims to compute torchvision's Resize(256) - which
on a PIL image is Pillow's antialiased BILINEAR resampler - bit-exactly, on the
256x256 window whose centre is CenterCrop(224). This script is what that claim is
checked against. For each case it

    1. builds a test frame from an integer formula that the C test reproduces
       exactly (so no frames need to be stored, only their digests),
    2. runs the deployed pipeline on it: transforms.Resize(256), as predict.py
       and export.py construct it, on a PIL RGB image,
    3. computes the crop offsets with torchvision's formula and then CHECKS them
       against transforms.CenterCrop(224)'s actual output, pixel for pixel - so
       the offsets are measured, not trusted,
    4. cross-checks torchvision's resize against a direct Image.resize(...,
       BILINEAR), so a future torchvision that stopped delegating to Pillow
       would be noticed rather than silently become the reference,
    5. records the geometry and an FNV-1a 64 digest of the input frame and of the
       256x256 window.

and writes firmware/linux/test/camfront_vectors.txt, which test_camfront.c reads.
The file is small and tracked; the C test needs nothing but gcc.

---- why digests and not the windows themselves ---------------------------

Fourteen 196,608-byte windows would be 2.7 MB of binary in the repository for a
pass/fail answer. A digest gives the same answer. For the case where it is not
enough - a failing case, where you want to know HOW MANY bytes differ - the C test
writes its window to firmware/build/linux-test/, and

    python scripts/gen_camfront_vectors.py --diff <that .bin>

regenerates the expected window for that case and counts the differences.

---- what is and is not the reference --------------------------------------

The REFERENCE is torchvision on this machine, with the versions recorded in the
file header. Pillow's resampler has been stable since 4.x, but a different version
could in principle differ, which is why the versions are written down and why
--check exists: it re-derives every digest and compares, without writing.

Run: python scripts/gen_camfront_vectors.py           (writes the vectors)
     python scripts/gen_camfront_vectors.py --check   (verifies them)
"""
import argparse
import json
import os
import re
import sys

import numpy as np
import PIL
import torch
import torchvision
from PIL import Image
from torchvision import transforms

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "software", "export", "manifest.json")
OUT = os.path.join(ROOT, "firmware", "linux", "test", "camfront_vectors.txt")

WIN = 256              # the window preproc_rgb accepts (QP_SRC_SIZE)
CROP_OFF = 16          # preproc_rgb's crop offset (QP_CROP_OFFSET)

#  (w, h, pattern, seed, what the case is for). Every common UVC size is here,
#  because those are what a camera will actually deliver; the rest are the
#  corners of the geometry.
CASES = [
    (640, 480, "noise", 1, "VGA: what most UVC webcams default to"),
    (640, 480, "smooth", 0, "VGA, a gradient: a rounding slip shows as a step"),
    (640, 480, "bars", 0, "VGA, hard edges: the filter support is exercised"),
    (1280, 720, "noise", 2, "720p: 455 wide, and 115.5 rounds to 116 (even)"),
    (1920, 1080, "noise", 3, "1080p: a 4.2x reduction, 11 coefficient slots"),
    (800, 600, "noise", 4, "SVGA"),
    (1024, 768, "noise", 5, "XGA"),
    (1280, 1024, "noise", 6, "SXGA: 5:4"),
    (352, 288, "noise", 7, "CIF: 312 wide, an even crop offset"),
    (320, 240, "noise", 8, "QVGA: an UPscale, filterscale clamps to 1"),
    (480, 640, "noise", 9, "portrait: the long side is the height"),
    (256, 256, "noise", 10, "the dataset's own size: no pass runs at all"),
    (257, 256, "noise", 11, "short side 256: no pass, and 16.5 rounds to 16"),
    (300, 255, "noise", 12, "short side 255: a slight upscale on both axes"),
    (1001, 777, "noise", 13, "odd sizes"),
]

M32 = 0xFFFFFFFF
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


def lowbias32(x):
    """Chris Wellons' lowbias32 hash, on a uint32 array. test_camfront.c has
    the same function; uint32 numpy arithmetic wraps exactly as C's does."""
    x = x ^ (x >> np.uint32(16))
    x = x * np.uint32(0x7FEB352D)
    x = x ^ (x >> np.uint32(15))
    x = x * np.uint32(0x846CA68B)
    x = x ^ (x >> np.uint32(16))
    return x


def make_frame(w, h, pattern, seed):
    """An h x w x 3 uint8 frame, HWC. Integer arithmetic only, so the C test
    builds the identical bytes."""
    if pattern == "noise":
        idx = np.arange(w * h * 3, dtype=np.uint32)
        key = np.uint32((seed * 0x9E3779B9) & M32)
        return (lowbias32(idx ^ key) >> np.uint32(24)).astype(np.uint8).reshape(h, w, 3)

    y, x, c = np.meshgrid(np.arange(h), np.arange(w), np.arange(3), indexing="ij")
    if pattern == "smooth":
        v = ((x * 255) // (w - 1) * (c + 1) + (y * 255) // (h - 1) * (3 - c)) // 4
    elif pattern == "bars":
        v = ((x // 3 + y // 5 + c) & 1) * 255
    else:
        raise ValueError(pattern)
    return v.astype(np.uint8)


def fnv1a64(data: bytes) -> int:
    h = FNV_OFFSET
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF
    return h


def center_offset(outer, inner):
    """torchvision's CenterCrop offset, with Python's round (half to even)."""
    return int(round((outer - inner) / 2.0))


def resize_tf():
    """transforms.Resize exactly as predict.py and export.py build it."""
    with open(MANIFEST, encoding="utf-8") as fh:
        img_size = int(json.load(fh)["img_size"])
    return transforms.Resize(int(round(img_size * 256 / 224))), img_size


def run_case(w, h, pattern, seed, resize, img_size):
    """Returns (geometry dict, input digest, window ndarray). Raises on any
    disagreement inside the reference itself."""
    frame = make_frame(w, h, pattern, seed)
    pil = Image.fromarray(frame, "RGB")
    rs = resize(pil)
    rs_w, rs_h = rs.size
    rs_arr = np.asarray(rs, dtype=np.uint8)

    #  torchvision returns the image itself when no resize is needed; Pillow's
    #  resize would return a copy. Either way the bytes must be the source's.
    direct = pil.resize((rs_w, rs_h), Image.BILINEAR) if (rs_w, rs_h) != (w, h) else pil
    if not np.array_equal(np.asarray(direct, dtype=np.uint8), rs_arr):
        raise RuntimeError(f"{w}x{h} {pattern}: torchvision's resize is NOT "
                           f"Pillow's BILINEAR any more - the reference has moved")

    crop_x = center_offset(rs_w, img_size)
    crop_y = center_offset(rs_h, img_size)
    cc = np.asarray(transforms.CenterCrop(img_size)(rs), dtype=np.uint8)
    if not np.array_equal(cc, rs_arr[crop_y:crop_y + img_size, crop_x:crop_x + img_size]):
        raise RuntimeError(f"{w}x{h} {pattern}: CenterCrop is not at ({crop_x}, {crop_y})")

    win_x, win_y = crop_x - CROP_OFF, crop_y - CROP_OFF
    win = rs_arr[win_y:win_y + WIN, win_x:win_x + WIN]
    if win.shape != (WIN, WIN, 3):
        raise RuntimeError(f"{w}x{h}: the window does not fit in {rs_w}x{rs_h}")
    #  The window's centre IS the network's input crop. Stated as a check
    #  because it is the reason the window can go to preproc_rgb unchanged.
    assert np.array_equal(win[CROP_OFF:CROP_OFF + img_size, CROP_OFF:CROP_OFF + img_size], cc)

    geom = dict(rs_w=rs_w, rs_h=rs_h, crop_x=crop_x, crop_y=crop_y, win_x=win_x, win_y=win_y)
    return geom, fnv1a64(frame.tobytes()), np.ascontiguousarray(win)


def fmt_line(w, h, pattern, seed, g, in_d, win_d):
    return (f"{w} {h} {pattern} {seed} {g['rs_w']} {g['rs_h']} {g['crop_x']} "
            f"{g['crop_y']} {g['win_x']} {g['win_y']} {in_d:016x} {win_d:016x}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="re-derive every digest and compare with the file; write nothing")
    ap.add_argument("--diff", metavar="BIN",
                    help="a window the C test wrote; count how it differs from the reference")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    resize, img_size = resize_tf()
    versions = (f"torchvision {torchvision.__version__}, torch {torch.__version__}, "
                f"Pillow {PIL.__version__}, numpy {np.__version__}")

    if args.diff:
        m = re.search(r"(\d+)x(\d+)_([a-z]+)_(\d+)\.bin$", os.path.basename(args.diff))
        if not m:
            ap.error("expected a file named <w>x<h>_<pattern>_<seed>.bin")
        w, h, pattern, seed = int(m[1]), int(m[2]), m[3], int(m[4])
        _, _, want = run_case(w, h, pattern, seed, resize, img_size)
        got = np.fromfile(args.diff, dtype=np.uint8)
        if got.size != want.size:
            print(f"size {got.size}, expected {want.size}")
            return 1
        d = got.astype(np.int32) - want.reshape(-1).astype(np.int32)
        bad = np.flatnonzero(d)
        print(f"{w}x{h} {pattern}: {bad.size:,} of {d.size:,} bytes differ, "
              f"max |diff| {int(np.abs(d).max()) if bad.size else 0}")
        for i in bad[:10]:
            px, c = divmod(int(i), 3)
            print(f"  window ({px % WIN}, {px // WIN}) channel {c}: "
                  f"C {got[i]}  reference {want.reshape(-1)[i]}")
        return 1 if bad.size else 0

    lines = []
    for (w, h, pattern, seed, why) in CASES:
        g, in_d, win = run_case(w, h, pattern, seed, resize, img_size)
        lines.append(fmt_line(w, h, pattern, seed, g, in_d, fnv1a64(win.tobytes())))
        print(f"  {w:5d}x{h:<5d} {pattern:6s} -> {g['rs_w']}x{g['rs_h']}, crop "
              f"({g['crop_x']},{g['crop_y']}), window ({g['win_x']},{g['win_y']})   {why}")

    if args.check:
        with open(args.out, encoding="utf-8") as fh:
            have = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
        if have != lines:
            for a, b in zip(have, lines):
                if a != b:
                    print(f"  file : {a}\n  now  : {b}")
            print(f"\nMISMATCH against {os.path.relpath(args.out, ROOT)} ({versions})")
            return 1
        print(f"\n{len(lines)} cases match {os.path.relpath(args.out, ROOT)} ({versions})")
        return 0

    head = [
        "# camfront known answers - GENERATED by scripts/gen_camfront_vectors.py, do not edit",
        f"# reference: {versions}",
        "# transforms.Resize(256) on a PIL RGB image, then the 256x256 window at",
        "# (win_x, win_y) = CenterCrop(224)'s offset minus 16. Digests are FNV-1a 64.",
        "#",
        "# w h pattern seed rs_w rs_h crop_x crop_y win_x win_y input_fnv window_fnv",
    ]
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(head + lines) + "\n")
    print(f"\n{len(lines)} cases -> {os.path.relpath(args.out, ROOT)}")
    print(f"reference: {versions}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
