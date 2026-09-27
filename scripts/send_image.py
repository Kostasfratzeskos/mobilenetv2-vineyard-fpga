#!/usr/bin/env python3
"""send_image.py - stream an image to the board's PS application over USB-UART.

The PC half of firmware/include/img_src.h's IMG_SRC_UART. The ZCU104's CP2108
USB-UART bridge makes the PS UART a COM port on the PC, so the same USB cable
that programs the board carries images to it - which is what makes trying
different leaves practical without touching the SD card.

    python scripts/send_image.py --port COM5 --image leaf.jpg
    python scripts/send_image.py --port /dev/ttyUSB1 --raw preprocessed.bin

150,528 bytes at 921600 baud is about 1.6 s.

---- what this does and does not do ---------------------------------------

With --raw it sends a file that is ALREADY 224x224x3 int8 in HWC order,
unchanged. That path is exact and is what the board expects.

With --image it preprocesses on the PC, using the same torchvision pipeline
predict.py uses (Resize -> CenterCrop(224) -> ToTensor -> Normalize) and the
input scale from software/export/manifest.json. That is convenient, and it is
ALSO the honest place for preprocessing to live until it is implemented and
verified in C: the accelerator's bit-exactness is measured from the quantised
tensor onward, so doing the front end here on the PC keeps the one unverified
step out of the embedded path rather than hiding it inside it.

When preprocessing is implemented in C and checked against torchvision, --image
becomes a convenience rather than the only correct route.

---- the framing -----------------------------------------------------------

    magic    4 bytes   b'IMG1'
    length   4 bytes   little-endian, must be 150528
    payload  length bytes
    sum      4 bytes   little-endian sum of the payload bytes

The checksum is not ceremony. A single dropped byte on a serial line shifts
every channel after it by one, which yields a plausible image and a confident
wrong classification - the failure shape this project keeps running into. The
board reports a mismatch and drops the frame.
"""
import argparse
import json
import os
import struct

MAGIC = b"IMG1"
IMG_W = 224
IMG_H = 224
IMG_C = 3
IMG_BYTES = IMG_W * IMG_H * IMG_C

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "software", "export", "manifest.json")


def frame(payload: bytes) -> bytes:
    if len(payload) != IMG_BYTES:
        raise SystemExit(f"payload is {len(payload)} bytes, expected {IMG_BYTES}")
    return (MAGIC + struct.pack("<I", len(payload)) + payload
            + struct.pack("<I", sum(payload) & 0xFFFFFFFF))


def preprocess(path: str) -> bytes:
    """The front end, exactly as software/export/manifest.json specifies it.

    Every constant comes from the manifest rather than from a literal here or an
    import out of software/train: the manifest IS the export contract, it carries
    the formula it was produced with, and a second copy of a scale is how an
    input tensor ends up silently different from the one the golden vectors were
    made with.

    The manifest states it as:

        input_quant: q = clamp(round((pixel/255 - mean)/std / input_scale),
                               -128, 127)

    which is ToTensor (pixel/255) then Normalize(mean, std) then a scale, round
    and clamp - i.e. the pipeline below.

    NOTE for whoever implements this in C. `round` here is torch.round, which is
    round-half-to-EVEN, not half-away-from-zero. In C, lrintf() in the default
    rounding mode matches it; floorf(x + 0.5f) does NOT, and differs on exactly
    the values that land on .5. It will disagree on a small number of pixels per
    image, which is enough to change a borderline classification and is precisely
    the kind of difference no test in this repository currently covers - the
    bit-exactness starts at the quantised tensor.
    """
    try:
        import numpy as np
        import torch
        from PIL import Image
        from torchvision import transforms
    except ImportError as e:
        raise SystemExit(f"--image needs torch/torchvision/pillow ({e}). "
                         f"Use --raw with an already-preprocessed file instead.")

    with open(MANIFEST, encoding="utf-8") as fh:
        man = json.load(fh)
    size  = int(man["img_size"])
    mean  = tuple(man["norm_mean"])
    std   = tuple(man["norm_std"])
    scale = float(man["input_scale"])

    if size != IMG_W:
        raise SystemExit(f"the manifest says img_size {size}, the hardware is "
                         f"built for {IMG_W}")

    #  predict.py's resize rule, kept identical: 256/224 of the crop size.
    resize = int(round(size * 256 / 224))

    tf = transforms.Compose([
        transforms.Resize(resize),
        transforms.CenterCrop(size),
        transforms.ToTensor(),
        transforms.Normalize(mean, std),
    ])
    x = tf(Image.open(path).convert("RGB"))          # CHW float

    q = torch.clamp(torch.round(x / scale), -128, 127).to(torch.int8)

    #  CHW -> HWC, because the DMA reads the image interleaved (DD-032).
    hwc = q.permute(1, 2, 0).contiguous().numpy().astype(np.uint8)
    return hwc.tobytes()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", required=True, help="COM5, /dev/ttyUSB1, ...")
    ap.add_argument("--baud", type=int, default=921600)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--image", help="a JPEG/PNG; preprocessed here on the PC")
    g.add_argument("--raw", help="a file that is already 224x224x3 int8, HWC")
    ap.add_argument("--repeat", type=int, default=1, help="send it N times")
    args = ap.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit("needs pyserial:  pip install pyserial")

    if args.raw:
        with open(args.raw, "rb") as fh:
            payload = fh.read()
        print(f"raw   : {args.raw} ({len(payload)} bytes)")
    else:
        payload = preprocess(args.image)
        print(f"image : {args.image} -> {len(payload)} bytes, HWC int8")

    pkt = frame(payload)
    with serial.Serial(args.port, args.baud, timeout=5) as ser:
        for i in range(args.repeat):
            ser.write(pkt)
            ser.flush()
            print(f"sent  : frame {i + 1}/{args.repeat}, "
                  f"{len(pkt)} bytes, checksum 0x{sum(payload) & 0xFFFFFFFF:08x}")
    print("done. The board prints the class on its own console.")


if __name__ == "__main__":
    main()
