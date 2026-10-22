# firmware/ — the PS application (Zynq UltraScale+ APU, baremetal)

Reads an image, hands it to the accelerator in the PL, and prints the disease class.

**For a live USB camera on the board, see [`linux/README.md`](linux/README.md)**: the same
driver and preprocessing, run as a Linux process (DD-035).

```
firmware/
├── include/accel_csr.h    the AXI-Lite register map (DD-031, DD-032)
├── include/accel_drv.h    the driver's contract, and the coherency requirement
├── include/img_src.h      where the image comes from: SD, UART or DDR
├── include/preproc.h      RGB → the int8 tensor, and why it is bit-exact
├── include/quant_params.h GENERATED from manifest.json — do not edit
├── src/accel_drv.c        the driver. Portable C — builds and is TESTED on a PC
├── src/preproc.c          crop, normalise, quantise. Also TESTED on a PC
├── src/plat_zynq.c        the five platform hooks (Xil_Out32, cache flush, …)
├── src/img_src.c          the three image sources, in two formats
├── src/main.c             the application
├── test/test_csr_map.c    the header must match hardware/rtl/axi/axi_lite_csr.v
├── test/test_drv_seq.c    the driver against a mock of the CSR's guards
├── test/test_preproc.c    the front end against the golden tensor, bit for bit
├── test/stubs/            fake BSP headers, so `make lint` can compile main.c
├── linux/                 the live-camera application for Linux (its own README)
└── Makefile               the HOST build, which runs the tests and the lint
```

The fifth hook, `accel_plat_phys`, came with the Linux port: the driver used to write
`(uint32_t)pointer` into the base registers, which is only right where a pointer is
a physical address. Baremetal returns the pointer unchanged; Linux translates, and
the driver refuses (`ACCEL_ERR_ADDR`) a buffer that has no 32-bit physical address
the DMA can use.

## What is tested, and what is not

**It has run on the board once** — 2026-10-07, the ZCU104 booted over JTAG with the
int8 `healthy_hl6025` image: logits `-4950 -6177 15185 -5486`, class 2 (Healthy), the
same four integers as `EXPECTED.txt` (`docs/lab_notebook.md`, that date). The other
bring-up checks — the RGB image through `preproc.c`, the other three classes, the UART
source, booting from the SD card — are not recorded yet.

The code was written before there was a board, so it is split so that the part most
likely to be wrong can be checked without one:

```
cd firmware && make test
```

All three tests, and the lint, run on a PC with gcc. No board, no bitstream, no
Vivado.

- **`test_csr_map`** parses `hardware/rtl/axi/axi_lite_csr.v` and fails if any
  offset, the aperture size, the program length or the ID magic in
  `accel_csr.h` disagrees with the RTL. A wrong offset does not fail to compile
  and does not crash — it writes a base address into the wrong register and the
  accelerator computes on whatever was there before, giving a confident wrong
  class with no error anywhere. This turns that into a failed `make`.
- **`test_drv_seq`** runs the driver against a mock that implements the CSR's
  *behaviour*: `CTRL` is write-1-to-pulse and reads back zero, `STATUS`'s live
  and sticky bits behave as the RTL's do, events appear only after several polls,
  and **every guard the RTL answers `SLVERR` to is recorded as a violation**. The
  test asserts zero violations, so the driver cannot pass by doing something the
  hardware would refuse.

- **`test_preproc`** runs the C front end over a golden set's decoded source
  image and requires all **150,528** values to match that set's
  `000_input.hex` **exactly**. That file is where `accel_axi_tb.sv`'s
  6,895,780-element check *starts*, so this is what joins the two halves: RGB in
  → the golden tensor → 6.9 M elements bit-exact → the argmax. 11 cases, and it
  is verified to bite — shifting the crop by one pixel breaks 142,927 values, and
  swapping RGB for BGR breaks 97,576.
- **`make lint`** compile-checks `main.c`, `img_src.c` and `plat_zynq.c` against
  stub BSP headers (`test/stubs/`). They cannot *link* on a host, so nothing used
  to touch them at all — and the first run of this target found that `main.c` and
  `plat_zynq.c` **could not compile**: each had a glob in a path inside a block
  comment (`build/bd_*/…`), whose `*/` closed the comment early. A Vitis build
  would have been the first thing to notice.

What none of them can check is whether the real DDR, the real caches and the real
interconnect behave as expected. That needs a board.

## The one thing that will bite on real hardware

**`S_AXI_HP0_FPD` is not cache-coherent.** The accelerator reads the blobs and
the image out of DDR over a port that does not snoop the APU's caches. Freshly
written data sits dirty in L1/L2 while DDR still holds the previous contents, so
the DMA reads stale bytes, the run completes, and the answer is wrong with no
error raised — a stale read is a perfectly valid AXI transaction.

`accel_set_blobs` and `accel_load_image` therefore flush the buffers themselves
rather than trusting the caller, which is why they take lengths as well as
addresses, and why they refuse buffers that are not 64-byte aligned (a cache
flush works on whole lines). Nothing in simulation can catch this class of bug:
`hardware/tb/axi_ddr_model.svh` has no caches to be incoherent with.

## Getting the blobs onto the board

```
python scripts/gen_program.py --emit
```

writes, alongside the `.hex` files the simulation reads, the packed binaries the
PS loads — 2.26 MB instead of 8.8 MB of ASCII, and no parsing on the A53:

| file | bytes | goes to |
|:--|--:|:--|
| `program.bin` | 2,048 | the AXI-Lite aperture, 512 words |
| `weights.bin` | 2,194,880 | DDR, `WGT_BASE` |
| `params_b.bin` | 77,056 | DDR, `PB_BASE` |
| `params_m0.bin` | 77,056 | DDR, `PM_BASE` |
| `params_shift.bin` | 19,264 | DDR, `PS_BASE` |

They are *derived* from the same lists that produce the `.hex`, in the same run,
and round-trip-checked against them before being written — so unlike the fourth
encoding DD-030 rejected, there is no second source of truth to keep in step.
Copy them to the root of a FAT32 SD card.

## Getting images onto the board

Three sources behind one interface (`img_src.h`), because the practical answer
depends on what is plugged in:

| source | how | when |
|:--|:--|:--|
| **UART** | `python scripts/send_image.py --port COM5 --rgb leaf.jpg` | trying different leaves — the *same* USB cable that programs the board, ~2.1 s per image at 921600 baud |
| **SD** | `image.bin` at the card root | a standalone demo with no PC |
| **DDR** | `mwr -bin -file leaf.bin 0x10000000 37632` from `xsct` | first bring-up: no protocol code, so a failure is the accelerator and not the transport |

Each source delivers one of **two** formats and says which:

| format | bytes | what it is | who preprocesses |
|:--|--:|:--|:--|
| `IMG_FMT_RGB256` | 196,608 | 256×256×3 uint8 RGB, decoded but untouched | **the board**, `preproc.c` |
| `IMG_FMT_Q8` | 150,528 | 224×224×3 int8, already quantised | the PC, or nobody |

Both are HWC interleaved — byte `(y*W + x)*3 + c` holds channel `c`. DD-032
explains the layout; briefly, it makes the DMA one sequential read, *and* it is
what an image decoder produces anyway, *and* it lets `preproc.c` walk both
buffers forwards.

`RGB256` is the real deployed path and `Q8` is for bring-up — with `Q8` there is
nothing at all between the PC and the DMA, so a failure is unambiguous.

How the format is determined, per source:

- **UART** — the frame magic. `'IMG1'` is `Q8`, `'IMG2'` is `RGB256`, and the
  length field is checked against it. The redundancy is deliberate: a sender and a
  board that disagree drop the frame and say so, rather than reading 196,608 RGB
  bytes as a quantised tensor — which would be a plausible image and a confident
  wrong class.
- **SD** — the file's length, which is unambiguous (the two differ). One filename,
  and any other size is refused outright rather than read as far as it goes.
- **DDR** — memory carries no length, so it is a build-time knob,
  `-DIMG_SRC_MEM_FMT=IMG_FMT_RGB256`. `Q8` by default, since that source exists
  for bring-up.

The UART frame is the magic, a little-endian length, the payload, and a
little-endian sum of the payload bytes. The checksum earns its place: one dropped
byte on a serial line shifts every channel after it, which yields a plausible
image and a confident wrong classification.

## Preprocessing — implemented, and bit-exact

`preproc.c` turns a decoded 256×256 RGB image into the tensor the accelerator
reads:

```
crop the centre 224×224 at offset 16
q = clamp(round((p/255 − mean[c]) / std[c] / input_scale), −128, 127)
```

and it reproduces `software/golden/<set>/000_input.hex` **exactly** — all 150,528
values. Since that file is where the hardware's 6,895,780-element check begins,
the end-to-end claim is now supported: **RGB in → the golden tensor → 6.9 M
elements bit-exact → the argmax**.

### Why bit-exactness was available at all

It should not have been. The reference pipeline is `Resize(256) →
CenterCrop(224) → ToTensor → Normalize`, and reimplementing Pillow's antialiased
resampler in C to the last bit is not a reasonable thing to attempt — so the
expected outcome was a *bounded difference*.

Then measured: **all 13,089 images** in `data/grape` and `data/grape_clean` are
already 256×256. `Resize(256)` is therefore the **identity**, and
`CenterCrop(224)` is a pure integer crop. No pixel is ever interpolated, so the
whole front end is a crop plus a per-pixel map, and both are exactly
reproducible. `scripts/gen_preproc_vectors.py` is that measurement, kept as a
script so it can be re-run.

### What is still not claimed

The **JPEG decode**. `libjpeg`'s IDCT is not bit-defined, two decoders may
legitimately differ in the last bit, and there is nothing to be exact *against*.
It stays on the PC and the board is handed decoded RGB — one clearly-bounded
step, outside the embedded path rather than hidden inside it.

And **any image that is not 256×256**. `preproc_rgb` takes `w` and `h` precisely
so it can **refuse** one, rather than fall back on a naive bilinear that does not
match Pillow. A camera, or an arbitrary photograph, needs a verified resampler -
which now exists, for the Linux camera path: `linux/src/camfront.c` computes
torchvision's `Resize(256)` bit-exactly against Pillow and hands `preproc_rgb` a
256×256 window, so `preproc_rgb` itself still refuses everything else (DD-035).
A refusal is a visible failure; a plausible wrong tensor is not.

### The rounding, and a claim this README previously got wrong

The manifest's `round` is `torch.round` — round-half-to-**even** — and `preproc.c`
uses `lrint`, which matches.

This file used to warn that `floorf(x + 0.5f)` "differs on exactly the values
landing on `.5` — enough to flip a borderline classification". **For these
constants that is false**, and the domain is small enough to settle rather than
argue about: the map depends only on `(channel, byte)`, so there are exactly
3 × 256 = 768 possible inputs, and enumerating all of them shows the two
spellings **agree at every one**. Nothing comes close — the nearest approach to a
`.5` tie is `6.4e-05`, some `3e11` double ulp away. Substituting
`floor(x + 0.5)` passes `test_preproc` bit-for-bit, which was verified by doing
it.

`lrint` is kept anyway, for a better reason than the old one: it matches the
reference **by construction** rather than by a margin, and that margin is a
property of *this* `input_scale`. Requantise the model and a value could land on a
tie.

What *would* bite is a target FPU left in **round-toward-zero**: truncation
differs from rounding across most of the domain, not just at ties. A host test can
never catch that, because the host is in `FE_TONEAREST`. So
`preproc_self_test()` checks `fegetround()` as well as all 768 table entries, and
`main.c` calls it at start-up.

### The constants are generated, not copied

`include/quant_params.h` is written by `python scripts/gen_program.py --emit`
from `software/export/manifest.json` — the crop offset, the ImageNet mean/std, the
input scale and the **class-name order**. A second hand-written copy of a scale is
how a deployed tensor ends up silently different from the one the goldens were
made with, which is the same reasoning DD-030 applied to the blobs. The class
order matters for a different reason: getting it wrong renames every prediction
while changing no number anywhere.

### Generating the test vector

```
python scripts/gen_preproc_vectors.py
```

writes `000_rgb256.bin` (the decoded source image) into each golden set that has
its source JPEG, and re-derives that set's `000_input.hex` in Python to confirm
the match. `test_preproc` reads the vector for `healthy_hl6025`, which is the
tracked set. If it is missing the test **fails** and says so rather than skipping
— a silently skipped front-end check is how the bit-exactness claim quietly stops
covering the input.

### Checking the two paths against each other on a live board

`--rgb` and `--image` reach the same tensor by completely different routes — C on
the board versus torchvision on the PC — so they should classify identically:

```
python scripts/send_image.py --port COM5 --rgb   leaf.jpg
python scripts/send_image.py --port COM5 --image leaf.jpg
```

`test_preproc` already proves those two agree bit-for-bit off-board; this is the
on-board version of the same check.

## Building the baremetal application

`make` here builds only the driver and the tests, for a PC. The application needs
a Vitis workspace:

1. Build the hardware and its handoff:
   `PL_MHZ=187.5 STRATEGY=explore bash scripts/run_bd.sh` →
   `build/bd_187p5_explore/accel_bd_wrapper.xsa`
2. In Vitis, create a **platform** from that XSA, `standalone` on `psu_cortexa53_0`,
   and enable **`xilffs`** in the BSP for the SD card.
3. Run `python scripts/gen_program.py --emit` first, so that
   `include/quant_params.h` exists — it is generated, and not tracked.
4. Create an application, add `src/*.c` and `include/` to it. Do **not** add
   `test/stubs/` to the include path: those are fake headers for `make lint`
   only, and putting them ahead of the BSP's would compile against declarations
   with no implementations.
5. Pick an image source, e.g. `-DIMG_SRC_DEFAULT=IMG_SRC_UART`.
6. Enable the FPU and link `-lm`: `preproc.c` uses `lrint`.
7. Program the bitstream (`accel_bd_wrapper.bit`) and run.

`main.c` takes the CSR base from `XPAR_ACCEL_AXI_0_BASEADDR` when the BSP
defines it, falling back to `0xA0000000` — the address
`scripts/make_bd.tcl` assigns and records in `build/bd_*/address_map.rpt`. Taking
it from the BSP means a change in the block design reaches the firmware through
the platform rather than by someone remembering to edit a literal.

## The sequence, and where it is verified

```
preproc self-test (768 entries, rounding mode)
         →  read ID  →  load 512 program words  →  write N_INSTR
         →  write the four blob bases (flushed)
         →  per image: get a frame, preproc_rgb if it is RGB256
         →  write IMG_BASE, pulse LOAD_IMAGE, poll STATUS[7]
         →  pulse START, poll STATUS[1]
         →  read RESULT_LO/HI and ARGMAX
```

This is not a fresh guess at the protocol. `hardware/tb/accel_axi_tb.sv` drives
the same register sequence against the actual RTL and gets all 64 golden tensors
bit-exact plus the argmax, and `test_drv_seq` drives the same *driver calls* in
the same order against the CSR's guards.
