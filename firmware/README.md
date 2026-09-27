# firmware/ — the PS application (Zynq UltraScale+ APU, baremetal)

Reads an image, hands it to the accelerator in the PL, and prints the disease class.

```
firmware/
├── include/accel_csr.h    the AXI-Lite register map (DD-031, DD-032)
├── include/accel_drv.h    the driver's contract, and the coherency requirement
├── include/img_src.h      where the image comes from: SD, UART or DDR
├── src/accel_drv.c        the driver. Portable C — builds and is TESTED on a PC
├── src/plat_zynq.c        the four platform hooks (Xil_Out32, cache flush, …)
├── src/img_src.c          the three image sources
├── src/main.c             the application
├── test/test_csr_map.c    the header must match hardware/rtl/axi/axi_lite_csr.v
├── test/test_drv_seq.c    the driver against a mock of the CSR's guards
└── Makefile               the HOST build, which exists to run the two tests
```

## What is tested, and what is not

**Nothing here has run on hardware.** There is no board. So the code is split so
that the part most likely to be wrong can still be checked:

```
cd firmware && make test
```

Both tests run on a PC with gcc. No board, no bitstream, no Vivado.

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

What neither can check is whether the real DDR, the real caches and the real
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
| **UART** | `python scripts/send_image.py --port COM5 --image leaf.jpg` | trying different leaves — the *same* USB cable that programs the board, ~1.6 s per image at 921600 baud |
| **SD** | `image.bin` at the card root | a standalone demo with no PC |
| **DDR** | `mwr -bin -file leaf.bin 0x10000000 37632` from `xsct` | first bring-up: no protocol code, so a failure is the accelerator and not the transport |

The image must be **224×224×3 int8, HWC interleaved** — byte `(y*224 + x)*3 + c`
holds channel `c`. DD-032 explains the layout; briefly, it makes the DMA one
sequential read *and* it is what an image decoder produces anyway.

The UART frame is `'IMG1'`, a little-endian length, the payload, and a
little-endian sum of the payload bytes. The checksum earns its place: one dropped
byte on a serial line shifts every channel after it, which yields a plausible
image and a confident wrong classification.

## Preprocessing — not implemented here, and that is a gap worth naming

`main.c` expects an image that is **already** 224×224×3 int8, quantised with the
scale `export.py` used. Decoding, resizing, centre-cropping, normalising by the
ImageNet mean/std and quantising is **not** implemented in C anywhere in this
repository — `software/predict.py` does it with torchvision, and the C reference
model (`software/cmodel`) reads an already-quantised
`software/golden/*/000_input.hex` at `main.c:22`.

That is also a gap in the project's verification. "6,895,780 elements bit-exact"
is measured **from the quantised tensor onward**. The resize and the
quantisation in front of it are covered by no check in this repository, so an
end-to-end claim is not yet supported.

Until it is implemented and verified, `scripts/send_image.py --image` does the
front end **on the PC**, with every constant read from
`software/export/manifest.json` — which is the honest place for an unverified
step to live: outside the embedded path rather than hidden inside it.

One trap recorded for whoever writes it: the manifest's `round` is
`torch.round`, i.e. **round-half-to-even**. In C, `lrintf()` in the default
rounding mode matches; `floorf(x + 0.5f)` does not, and differs on exactly the
values landing on `.5` — enough to flip a borderline classification.

## Building the baremetal application

`make` here builds only the driver and the tests, for a PC. The application needs
a Vitis workspace:

1. Build the hardware and its handoff:
   `PL_MHZ=187.5 STRATEGY=explore bash scripts/run_bd.sh` →
   `build/bd_187p5_explore/accel_bd_wrapper.xsa`
2. In Vitis, create a **platform** from that XSA, `standalone` on `psu_cortexa53_0`,
   and enable **`xilffs`** in the BSP for the SD card.
3. Create an application, add `src/*.c` and `include/` to it.
4. Pick an image source, e.g. `-DIMG_SRC_DEFAULT=IMG_SRC_UART`.
5. Program the bitstream (`accel_bd_wrapper.bit`) and run.

`main.c` takes the CSR base from `XPAR_ACCEL_AXI_0_BASEADDR` when the BSP
defines it, falling back to `0xA0000000` — the address
`scripts/make_bd.tcl` assigns and records in `build/bd_*/address_map.rpt`. Taking
it from the BSP means a change in the block design reaches the firmware through
the platform rather than by someone remembering to edit a literal.

## The sequence, and where it is verified

```
read ID  →  load 512 program words  →  write N_INSTR
         →  write the four blob bases (flushed)
         →  write IMG_BASE, pulse LOAD_IMAGE, poll STATUS[7]
         →  pulse START, poll STATUS[1]
         →  read RESULT_LO/HI and ARGMAX
```

This is not a fresh guess at the protocol. `hardware/tb/accel_axi_tb.sv` drives
the same register sequence against the actual RTL and gets all 64 golden tensors
bit-exact plus the argmax, and `test_drv_seq` drives the same *driver calls* in
the same order against the CSR's guards.
