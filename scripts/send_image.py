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
---- three modes, and which one to use -------------------------------------

    --rgb IMG     decode to 256x256 RGB and send THAT, 196,608 bytes. The BOARD
                  crops, normalises and quantises, with firmware/src/preproc.c.
                  This is the one that exercises the real deployed path.

    --image IMG   do the whole front end here on the PC and send the finished
                  224x224x3 int8 tensor, 150,528 bytes. Now a convenience and a
                  cross-check rather than the only correct route.

    --raw FILE    a file that is already that tensor. For bring-up: nothing
                  between the file and the DMA.

--rgb and --image should produce the same classification, and that is worth using
as a check on a live board: they take completely different paths to the same
tensor - torchvision here versus C there - and firmware/test/test_preproc.c
already proves the two agree bit-for-bit off-board.

Preprocessing used to live only on the PC because nothing in C did it and the
project's bit-exactness was measured from the quantised tensor onward. That gap
is closed: preproc.c reproduces the golden 000_input.hex exactly, all 150,528
values, and the measurement behind it is scripts/gen_preproc_vectors.py. What
stays here permanently is the JPEG DECODE, because libjpeg's IDCT is not
bit-defined and there is nothing to be exact against - one bounded step, outside
the embedded path rather than hidden inside it.

---- the framing -----------------------------------------------------------

    magic    4 bytes   b'IMG1' (int8 tensor)  or  b'IMG2' (256x256 RGB)
    length   4 bytes   little-endian, 150528 or 196608, matching the magic
    payload  length bytes
    sum      4 bytes   little-endian sum of the payload bytes

The format is in the magic AND the length is checked against it, which is
redundant on purpose: a sender and a board that disagree about the format drop
the frame and say so, instead of 196,608 RGB bytes being read as a quantised
tensor - a perfectly plausible image and a confident wrong class.

The checksum is not ceremony. A single dropped byte on a serial line shifts
every channel after it by one, which yields a plausible image and a confident
wrong classification - the failure shape this project keeps running into. The
board reports a mismatch and drops the frame.
"""
import argparse
import json
import os
import struct

MAGIC_Q8  = b"IMG1"
MAGIC_RGB = b"IMG2"
IMG_W = 224
IMG_H = 224
IMG_C = 3
IMG_BYTES = IMG_W * IMG_H * IMG_C          # 150,528

#  What preproc.c expects, and what QP_SRC_SIZE in firmware/include/quant_params.h
#  says. 256 is not a resize target here - every image in this dataset already is
#  256x256, which is exactly why the C front end can be bit-exact without a
#  resampler. An image of any other size is REFUSED by the board rather than
#  resampled, so it is refused here too rather than sent to be rejected.
SRC_SIZE = 256
RGB_BYTES = SRC_SIZE * SRC_SIZE * IMG_C    # 196,608

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "software", "export", "manifest.json")


def frame(payload: bytes, magic: bytes) -> bytes:
    want = RGB_BYTES if magic == MAGIC_RGB else IMG_BYTES
    if len(payload) != want:
        raise SystemExit(f"payload is {len(payload)} bytes, expected {want} "
                         f"for {magic.decode()}")
    return (magic + struct.pack("<I", len(payload)) + payload
            + struct.pack("<I", sum(payload) & 0xFFFFFFFF))


def decode_rgb(path: str) -> bytes:
    """Decode to 256x256 RGB and hand the bytes over untouched.

    No resizing, no cropping, no normalising - the board does all of that, and
    does it bit-exactly (firmware/test/test_preproc.c). This function's only job
    is the JPEG decode, which is the one step that cannot be verified against a
    reference because libjpeg's IDCT is not bit-defined.

    A non-256x256 image is refused rather than resized. Resizing it here would
    work, and would also silently move the unverified part of the pipeline back
    onto the PC while the command line still said --rgb. Use --image for such an
    image, which is honest about doing the front end here.
    """
    from PIL import Image

    im = Image.open(path).convert("RGB")
    if im.size != (SRC_SIZE, SRC_SIZE):
        raise SystemExit(
            f"{path} is {im.size[0]}x{im.size[1]}, not {SRC_SIZE}x{SRC_SIZE}.\n"
            f"  --rgb sends the image for the BOARD to crop and quantise, and "
            f"preproc.c\n"
            f"  refuses anything else because no resampler in this repository is\n"
            f"  verified against Pillow's. Use --image to preprocess here "
            f"instead.")
    return im.tobytes()


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
    g.add_argument("--rgb", help="a 256x256 JPEG/PNG; the BOARD preprocesses it")
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
        magic = MAGIC_Q8
        print(f"raw   : {args.raw} ({len(payload)} bytes, int8 tensor)")
    elif args.rgb:
        payload = decode_rgb(args.rgb)
        magic = MAGIC_RGB
        print(f"rgb   : {args.rgb} -> {len(payload)} bytes, "
              f"{SRC_SIZE}x{SRC_SIZE} RGB")
        print(f"        the BOARD crops, normalises and quantises this")
    else:
        payload = preprocess(args.image)
        magic = MAGIC_Q8
        print(f"image : {args.image} -> {len(payload)} bytes, HWC int8")
        print(f"        preprocessed HERE; --rgb makes the board do it instead")

    pkt = frame(payload, magic)
    with serial.Serial(args.port, args.baud, timeout=5) as ser:
        for i in range(args.repeat):
            ser.write(pkt)
            ser.flush()
            print(f"sent  : frame {i + 1}/{args.repeat}, "
                  f"{len(pkt)} bytes, checksum 0x{sum(payload) & 0xFFFFFFFF:08x}")
    print("done. The board prints the class on its own console.")


if __name__ == "__main__":
    main()
