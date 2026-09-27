"""Stage everything the board needs into one directory, with a KNOWN ANSWER.

The point is to arrive at the bench with test vectors whose correct output is
already known, rather than debugging the accelerator and the test data at the same
time. Every image in software/golden/ has been through the full simulation, so its
logits and its class are known exactly - and a board that produces different
numbers is wrong in a way that needs no interpretation.

    python scripts/make_sdcard.py

writes build/sdcard/ :

    program.bin        2,048      the 512-word program
    weights.bin    2,194,880      the weights
    params_b.bin      77,056      bias
    params_m0.bin     77,056      multiplier
    params_shift.bin  19,264      shift
    image.bin        150,528      a known-answer image, int8 HWC (= image_q8.bin)
    image_q8.bin     150,528      the same, kept under its own name
    image_rgb.bin    196,608      the same leaf as 256x256 RGB, for the board's
                                  own preprocessing
    EXPECTED.txt                  the logits and class the board must produce

Copy the whole directory to the root of a FAT32 card.

---- image.bin and the two formats -----------------------------------------

img_src infers the format from the FILE LENGTH, because the two are 150,528 and
196,608 and nothing else is accepted. There is one filename, so only one format
can be on the card at a time:

    image.bin is a copy of image_q8.bin      -> the board does NO preprocessing
    copy image_rgb.bin over image.bin        -> the board crops and quantises

Start with the Q8 copy. It puts nothing between the file and the DMA, so a wrong
answer is the accelerator and not the front end. Then switch to the RGB one, which
exercises preproc.c on the board, and the logits must be IDENTICAL - that is the
whole point of the front end being bit-exact.

Run: python scripts/make_sdcard.py --set healthy_hl6025
"""
import argparse
import json
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPORT = os.path.join(ROOT, "software", "export")
GOLD = os.path.join(ROOT, "software", "golden")
OUT = os.path.join(ROOT, "build", "sdcard")

IMG_SIZE = 224
SRC_SIZE = 256
CHANNELS = 3
Q8_BYTES = IMG_SIZE * IMG_SIZE * CHANNELS       # 150,528
RGB_BYTES = SRC_SIZE * SRC_SIZE * CHANNELS      # 196,608

BLOBS = [
    ("program.bin", 2048),
    ("weights.bin", 2194880),
    ("params_b.bin", 77056),
    ("params_m0.bin", 77056),
    ("params_shift.bin", 19264),
]

CLASS_NAME = ["Black Rot", "ESCA", "Healthy", "Leaf Blight"]


def load_chw_hex(path):
    """000_input.hex: one byte per line, hex, CHW row-major, int8 two's compl."""
    vals = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                vals.append(int(ln, 16) & 0xFF)
    return vals


def chw_to_hwc(chw):
    """(3,224,224) -> (224,224,3), which is what the DMA reads (DD-032).

    Written as an explicit index rather than with numpy so that this script has
    no dependencies - it may well be run on a lab machine that has Python and
    nothing else.
    """
    out = bytearray(Q8_BYTES)
    for c in range(CHANNELS):
        base = c * IMG_SIZE * IMG_SIZE
        for y in range(IMG_SIZE):
            row = base + y * IMG_SIZE
            dst = (y * IMG_SIZE) * CHANNELS + c
            for x in range(IMG_SIZE):
                out[dst + x * CHANNELS] = chw[row + x]
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--set", default="healthy_hl6025",
                    help="which golden set to use as the known-answer image")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()

    gdir = os.path.join(GOLD, args.set)
    gman = os.path.join(gdir, "golden_manifest.json")
    ghex = os.path.join(gdir, "000_input.hex")

    if not os.path.exists(gman):
        print(f"no such golden set: {gdir}")
        print(f"available: {', '.join(sorted(os.listdir(GOLD)))}")
        return 1
    if not os.path.exists(ghex):
        print(f"{ghex} is missing")
        return 1

    with open(gman, encoding="utf-8") as fh:
        g = json.load(fh)

    os.makedirs(args.out, exist_ok=True)
    problems = []

    # ---- the blobs -------------------------------------------------------
    print("blobs:")
    for name, want in BLOBS:
        src = os.path.join(EXPORT, name)
        if not os.path.exists(src):
            problems.append(f"{name} is missing - run "
                            f"`python scripts/gen_program.py --emit` first")
            print(f"  {name:18s} MISSING")
            continue
        sz = os.path.getsize(src)
        if sz != want:
            problems.append(f"{name} is {sz:,} bytes, expected {want:,}")
        shutil.copy2(src, os.path.join(args.out, name))
        print(f"  {name:18s} {sz:>9,} bytes"
              f"{'' if sz == want else '   <-- WRONG SIZE'}")

    # ---- the known-answer image, int8 ------------------------------------
    print()
    print("known-answer image:")
    chw = load_chw_hex(ghex)
    if len(chw) != Q8_BYTES:
        problems.append(f"{ghex} has {len(chw):,} values, expected {Q8_BYTES:,}")
    else:
        q8 = chw_to_hwc(chw)
        for name in ("image_q8.bin", "image.bin"):
            with open(os.path.join(args.out, name), "wb") as fh:
                fh.write(q8)
        print(f"  image_q8.bin       {len(q8):>9,} bytes  int8 HWC, from "
              f"{args.set}/000_input.hex")
        print(f"  image.bin          {len(q8):>9,} bytes  a copy - the board does "
              f"NO preprocessing")

    # ---- the same leaf as RGB, for the board's own front end -------------
    rgb_src = os.path.join(gdir, "000_rgb256.bin")
    if os.path.exists(rgb_src):
        sz = os.path.getsize(rgb_src)
        if sz != RGB_BYTES:
            problems.append(f"000_rgb256.bin is {sz:,} bytes, "
                            f"expected {RGB_BYTES:,}")
        shutil.copy2(rgb_src, os.path.join(args.out, "image_rgb.bin"))
        print(f"  image_rgb.bin      {sz:>9,} bytes  256x256 RGB - copy over "
              f"image.bin to test preproc.c")
    else:
        problems.append("000_rgb256.bin is missing - run "
                        "`python scripts/gen_preproc_vectors.py`")
        print("  image_rgb.bin      MISSING")

    # ---- what the board must produce ------------------------------------
    logits = g.get("logits_int16")
    pred = g.get("predicted_class")
    argmax = None
    if logits and len(logits) == 4:
        argmax = max(range(4), key=lambda i: logits[i])

    lines = []
    lines.append("EXPECTED RESULT - what the board must print")
    lines.append("=" * 60)
    lines.append("")
    lines.append(f"golden set   : {args.set}")
    lines.append(f"source image : {os.path.basename(g.get('image', '?'))}")
    lines.append(f"checkpoint   : {g.get('ckpt_sha256', '?')}")
    lines.append("")
    if logits:
        lines.append(f"logits       : {logits[0]:>7} {logits[1]:>7} "
                     f"{logits[2]:>7} {logits[3]:>7}")
        lines.append(f"argmax       : {argmax} = "
                     f"{CLASS_NAME[argmax] if argmax is not None else '?'}")
        lines.append(f"manifest says: {pred}")
    lines.append("")
    lines.append("These are not a prediction - they are what the RTL produced in")
    lines.append("simulation for this exact input, bit-exact against the C model")
    lines.append("over all 64 layers. The board must produce the SAME FOUR")
    lines.append("INTEGERS. Anything else is a bug, not a rounding difference:")
    lines.append("there is no floating point anywhere in the datapath.")
    lines.append("")
    lines.append("Both image.bin formats must give the same numbers. If the int8")
    lines.append("one is right and the RGB one is not, the fault is preproc.c or")
    lines.append("the cache flush of the image buffer - not the accelerator.")
    txt = "\n".join(lines) + "\n"

    with open(os.path.join(args.out, "EXPECTED.txt"), "w",
              encoding="utf-8") as fh:
        fh.write(txt)

    print()
    print(txt)

    total = sum(os.path.getsize(os.path.join(args.out, f))
                for f in os.listdir(args.out))
    print(f"staged in {args.out}")
    print(f"  {len(os.listdir(args.out))} files, {total:,} bytes total")
    print("  copy the whole directory to the root of a FAT32 card")

    if problems:
        print()
        print(f"{len(problems)} PROBLEM(S):")
        for p in problems:
            print("  " + p)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
