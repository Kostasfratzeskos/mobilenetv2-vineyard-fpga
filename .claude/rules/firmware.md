---
paths:
  - "firmware/**"
---

# PS firmware and the Linux camera app (`firmware/`)

- `src/accel_drv.c` and `src/preproc.c` are portable C that the bare-metal app and the Linux app
  (`linux/`) share. Test them on the PC with `make -C firmware test` (it also lints `main.c`
  against the stub BSP headers) and `make -C firmware/linux test`.
- Platform-specific code goes through the five platform hooks (`src/plat_zynq.c`,
  `linux/src/plat_linux.c`), never into the driver.
- `include/quant_params.h` is generated (`python scripts/gen_program.py --emit`). Never edit it.
- `include/accel_csr.h` must match `hardware/rtl/axi/axi_lite_csr.v` (DD-031, DD-032).
  `test/test_csr_map.c` checks that it does.
- A Linux build host reads `linux/petalinux/**`, so those files stay LF (pinned in
  `.gitattributes`). Any new file a Linux host must read needs the same pinning.
- PetaLinux builds run in WSL2. Follow `linux/README.md` in order.
- Record every board result with the checkpoint that produced it. The known answers are in
  `build/sdcard*/EXPECTED.txt`, which `scripts/make_sdcard.py` writes.
