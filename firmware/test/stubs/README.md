# `test/stubs/` — fake BSP headers, for a syntax check only

These are **not** a BSP and are never linked. They exist so that `main.c`,
`img_src.c` and `plat_zynq.c` can be **compiled** on a PC, with
`gcc -fsyntax-only`, which is what `make lint` does.

## Why

Those three files need `xilffs`, `xuartps` and `xil_cache` from a standalone
Vitis BSP, so `firmware/Makefile` excludes them and nothing on the host touched
them at all. That meant the application and the image sources — about 600 lines,
including every change made to them — were not even **compile**-checked. Not by
the tests, not by `make`, not by anything.

That is a worse gap than it sounds, and this project has already been bitten by
its exact shape once: a change to `axi_lite_csr.v` added four ports, the unit
testbench left them unconnected, `xvlog` printed a warning nobody read, and nine
checks failed for a reason that took a while to find. A wrong argument count or a
stale function signature in `img_src.c` is the same kind of error, and without
this it would be discovered in Vitis, on a board, at the least convenient moment.

## What this does and does not catch

Caught: undeclared identifiers, wrong argument counts and types, bad struct
members, missing includes, signature drift between a header and its
implementation, most typos.

**Not** caught: anything about the real BSP's behaviour. These stubs return
nothing useful and have no state. A successful `make lint` says the code is
well-formed C against the API it claims to use — not that it works. Only a board
can say that.

## Keeping them honest

Each declaration here is copied from the Xilinx header's actual signature. If a
stub's signature drifts from the real one, `make lint` passes and the Vitis build
fails — the opposite of useful. So the stubs are deliberately minimal: only what
the firmware actually calls, so there is less to get wrong.
