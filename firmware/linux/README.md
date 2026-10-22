# firmware/linux/ — live camera classification on the ZCU104 (Option B)

A USB webcam plugged into the **board**, Linux on the A53s, and the accelerator in
the PL classifying every frame:

```
USB webcam ─► UVC driver ─► vinecam: YUYV→RGB ─► Resize(256) window ─► preproc_rgb
     (V4L2, /dev/video0)                         (camfront.c,           (preproc.c,
                                                  bit-exact vs Pillow)   bit-exact)
                                                                 │
   DisplayPort monitor ◄── screen (ui.c) ◄── class + softmax ◄── accelerator (PL)
   browser on a laptop ◄── --http 8080                           via /dev/uioN + a
                                                                  reserved DMA region
```

The baremetal application (`firmware/src/main.c`) classifies files from the SD card or the
UART. A webcam needs a USB host stack and a UVC driver, which come with Linux, so this
directory runs the **same accelerator, driver and preprocessing** as a Linux process. The
FPGA design is unchanged: same block design, same bitstream.

```
firmware/linux/
├── README.md               this file: the whole process, in order
├── Makefile                make test (PC) · make (board) · make check · make tools
├── include/ + src/
│   ├── vinecam.c           the application
│   ├── camfront.c          YUYV→RGB, and torchvision's Resize(256) - bit-exact vs Pillow
│   ├── plat_linux.c        the driver's five platform hooks, for Linux
│   ├── dmaregion.c         the reserved DDR region: allocate, translate, write safely
│   ├── vine_uio.c          find /dev/uioN, map the CSR and the region, sanity-check them
│   ├── uio_sysfs.c         read /sys/class/uio and /proc/iomem
│   ├── v4l2cam.c           the webcam, newest frame first
│   ├── fbdev.c             the DisplayPort monitor (/dev/fb0)
│   ├── canvas.c, ui.c      the demo screen, and its 5x7 font
│   ├── httpview.c          the same screen in a browser (--http)
│   ├── ppm.c, dump.c       stills in, saved frames out
├── test/                   test_camfront, test_platform, test_ui (run on the PC)
├── tools/render_ui.c       the board's screen, rendered on a PC from a photograph
└── petalinux/
    ├── build.sh            makes the PetaLinux 2022.2 image (on a Linux host)
    ├── vinecam.dtsi        the DMA carve-out, the UIO node, USB host mode
    └── vinecam.cfg         kernel options: UIO, UVC, the fbdev console
```

---

## What is verified, and what is not

**Nothing here has run on a board.** It has been built and tested as far as a PC allows:

| what | how | result |
|:--|:--|:--|
| the resize, on test patterns | `test_camfront` against vectors from the real torchvision 0.27 + Pillow 11.1 | **15 frame sizes bit-exact**, 196,608 bytes each: VGA, 720p, 1080p, SVGA, XGA, SXGA, CIF, QVGA (an upscale), portrait, 256², odd sizes |
| the resize, on photographs | `render_ui --dump` → `check_camera_frame.py` | window **and** int8 tensor identical to torchvision + `export.py` on 4 camera-style frames of real leaves |
| the test can fail | 9 deliberate mistakes in the resampler | **8 caught**. The 9th is provably harmless (see `camfront.c`) |
| the driver's new address hook | `firmware/test/test_drv_seq` + `test_platform` | bases get **physical** addresses; a buffer outside the region is refused before anything is written |
| the region, sysfs, `/proc/iomem` logic | `test_platform`, against a fake `/sys` and fake iomem files | pass |
| the screen layout | `test_ui` at 10 sizes, 64×48 to 4K, with guard words; `render_ui` looked at | nothing drawn outside the canvas or into the bottom margin, for 4:3 and 16:9 frames; green only for Healthy |
| everything else compiles for the board | `make check`: aarch64 Linux, `-Wall -Wextra -Werror`, static | builds clean |
| the device-tree fragment | — | **not compiled here** (the Vitis `dtc` is a Linux binary). `build.sh` checks the *built* `system.dtb` with `dtc` on the build host |
| the PetaLinux build | `build.sh` on WSL2, Ubuntu 20.04 (2026-10-22) | **builds**. The first run reported failure after every task had succeeded (two sstate download time-outs); the re-run was clean - step 4 |
| the Linux port on the board: UIO, the DMA region, the address hook | step 7, all four known answers (2026-10-22) | **bit-exact**, int8 and RGB, all four classes; **6.659 ms** per image over 100 runs |
| the webcam (V4L2) and the live loop | step 8 (2026-10-22) | **runs and classifies on the board**; its per-second numbers are not recorded yet |
| DisplayPort (`/dev/fb0`), the browser view, the saved-frame check | steps 8-10 | **not yet**: no `/dev/fb0` at boot (no monitor was detected); the other two not run |

The order of operations below is designed around that: the first thing to run on the board
is a **known answer with no camera** (step 7), which tests the whole Linux port against
numbers that are already known before any of the new camera code is involved.

---

## What you need

**Hardware**

- The ZCU104, its power supply, and the micro-USB cable to the UART (the console).
- A **UVC webcam**, which is any webcam that works on a PC without a driver (Logitech C270,
  C920, …). It needs to offer YUYV at 640×480, which almost all do (`vinecam --list` shows
  this).
- A way to plug USB-A into the board's USB 3.0 port. If the port on your board is the
  **micro-AB** OTG kind, you need a micro-A/B (OTG) to USB-A adapter, or a powered hub
  behind one.
- A screen, one or both of:
  - a **DisplayPort** monitor. For an HDMI projector, use an **active** DP→HDMI adapter:
    passive ones rely on DP++ dual-mode, which this DisplayPort output does not provide.
  - an **Ethernet cable** to a laptop, for the browser view (`--http`). This is the easy
    one for a talk, because the laptop is already on the projector.
- A microSD card (8 GB or more is plenty).

**Software**

- **A Linux machine with PetaLinux 2022.2.** It has to match the Vivado 2022.2 the hardware
  was built with. PetaLinux does not run on Windows. Use a native Ubuntu (20.04 is a
  supported host for 2022.2; UG1144 has the list), a VM with ~100 GB of disk, or WSL2.
  WSL2 is unofficial but usually works if the project lives in `~/`, not under `/mnt/c`.
- **The ZCU104 BSP for 2022.2**, `xilinx-zcu104-v2022.2-*.bsp`, from the same download page
  as PetaLinux.
- Vitis 2022.2 on this PC (already installed). Its aarch64 Linux compiler builds `vinecam`.
- Python with torch/torchvision/Pillow (already installed) for the PC-side checks.

---

## The process

### 1. Build the hardware (Windows, Vivado)

If `build/bd_187p5_explore/` already holds `accel_bd_wrapper.xsa` **and** `accel_bd_wrapper.bit`,
skip this step.

```
PL_MHZ=187.5 STRATEGY=explore bash scripts/run_bd.sh
```

The XSA is written without the bitstream (`make_bd.tcl` explains why), so both files are
needed in step 4.

### 2. Generate the blobs and the known answers (Windows, Python)

```
python scripts/gen_program.py --emit
python scripts/make_sdcard.py                                        # healthy_hl6025
python scripts/make_sdcard.py --set esca_4399     --out build/sdcard_esca
python scripts/make_sdcard.py --set blackrot_0376 --out build/sdcard_blackrot
python scripts/make_sdcard.py --set blight_1461   --out build/sdcard_blight
```

Each `build/sdcard*/` then holds the five blobs, `image_q8.bin`, `image_rgb.bin` and
`EXPECTED.txt`: the four logits the RTL produced in simulation for that leaf. The three
non-default sets need their golden directories (see the `.gitignore` note on golden sets).

### 3. Build and test vinecam (Windows)

```
cd firmware/linux
make check          # the PC tests, then the static aarch64 build
```

`make check` must end with `>> all Linux-side host tests pass` and
`built build/aarch64/vinecam`. The firmware's own tests cover the driver change:

```
cd firmware && make test
```

### 4. Build the Linux image (the Linux machine)

Copy `accel_bd_wrapper.xsa`, `accel_bd_wrapper.bit` and `firmware/linux/petalinux/` to the
Linux machine (or clone the repository there), then:

```
source /tools/Xilinx/PetaLinux/2022.2/settings.sh      # wherever it is installed
cd ~
bash <repo>/firmware/linux/petalinux/build.sh \
     --bsp ~/Downloads/xilinx-zcu104-v2022.2-<date>.bsp \
     --xsa ~/hw/accel_bd_wrapper.xsa                   # the .bit beside it is found
```

What it changes in the BSP's project, and why, is at the top of `build.sh`. In short: our
XSA, three kernel arguments **appended** to PetaLinux's own, `vinecam.dtsi`, `vinecam.cfg`,
and a `BOOT.BIN` that carries the bitstream. The first build takes an hour or more. It ends
by checking that the built device tree contains the accelerator node, the carve-out with
`no-map`, and the boot arguments, and then lists the three files for the card.

On Ubuntu 20.04 - WSL2 works; that is how it was built on 2026-10-22 - install `libtinfo5` and
`libncurses5` first. If `petalinux-build` ends with `Failed to build project` although every
task succeeded, look for `ConnectionError` in the log: the sstate mirror timed out on a package,
which was then built locally anyway. `build.sh` stops there, before `BOOT.BIN`; run it again.

### 5. Prepare the SD card

One FAT32 partition, everything in its root:

| file | from |
|:--|:--|
| `BOOT.BIN`, `boot.scr`, `image.ub` | `<plnx-project>/images/linux/` |
| `vinecam` | `firmware/linux/build/aarch64/vinecam` |
| `program.bin`, `weights.bin`, `params_b.bin`, `params_m0.bin`, `params_shift.bin` | `build/sdcard/` |
| `image_q8.bin`, `image_rgb.bin`, `EXPECTED.txt` | `build/sdcard/` (the healthy known answer) |
| optional: one folder per other class, e.g. `esca/` with its `image_*.bin` + `EXPECTED.txt` | `build/sdcard_esca/` etc. |

`vinecam` looks for the blobs in its own directory, so keeping them together needs no options.

**Use a card whose only partition is this FAT32 one.** The card in the ZCU104 kit also carries
an ext4 partition with PetaLinux 2022.1, and `image.ub`'s ramdisk switches into any root
filesystem it finds there. The board then runs the old system (the prompt says
`xilinx-zcu104-20221`) and no `vine-accel` appears. Either use a clean card, or leave
`image.ub` off this one and copy `Image`, `system.dtb` and `rootfs.cpio.gz.u-boot` from
`images/linux/` instead: `boot.scr` then boots the kernel with the full root filesystem in RAM.
That is how the board ran on 2026-10-22.

### 6. Boot

1. Set the boot-mode switch **SW6 to SD** (check UG1267's boot-mode table for your board revision).
2. Connect the UART micro-USB, and open a terminal at **115200** on the board's first COM port.
3. Plug in the monitor *before* power-on (`/dev/fb0` is created at boot), and the webcam.
4. Power on. Linux boots to a login prompt. PetaLinux 2022.2 logs in as `petalinux` and asks
   you to set a password on the first login. Root commands use `sudo`.
5. Become root and load the UIO driver. Both are needed after every boot, for now:
   ```
   sudo -s                       # the card is mounted root-only (fmask=0007)
   modprobe uio_pdrv_genirq      # this build makes it a module, despite vinecam.cfg (DD-035)
   ```
6. Find the SD card: `mount | grep mmcblk`. It is usually `/run/media/mmcblk0p1` (or
   `…/mmcblk1p1`). Then `cd` there. Not `…p2`: on the kit's card that is the old system.

Quick checks before vinecam:

```
ls /sys/class/uio/              # a uioN whose name is vine-accel:
cat /sys/class/uio/uio*/name
ls /dev/video*                  # the camera (video0; video1 is its metadata node)
ls /dev/fb0                     # the monitor - absent if none was detected at boot
cat /proc/cmdline               # contains clk_ignore_unused and uio_pdrv_genirq.of_id=...
```

### 7. The known answer, with no camera (the first real test)

```
sudo ./vinecam --image image_q8.bin  --expect EXPECTED.txt
sudo ./vinecam --image image_rgb.bin --expect EXPECTED.txt
```

Both must print `PASS - all four logits equal EXPECTED.txt, bit for bit`. This is the whole
Linux port checked against numbers that existed before it: UIO, the DMA region, the
virtual-to-physical translation, the ordering barrier, `preproc_rgb` on the board. Run the
other classes the same way (`--image esca/image_rgb.bin --expect esca/EXPECTED.txt`).

How long the accelerator takes:

```
sudo ./vinecam --image image_q8.bin --repeat 100
```

prints mean/min/max over 100 runs. Simulation says start-to-done is 1,151,347 cycles, which
is **6.14 ms at 187.5 MHz**, plus the image load. The board's number is the one to quote.

If the first command fails, stop here and see *Troubleshooting*. The camera path cannot work
if this does not.

### 8. Live

```
sudo ./vinecam --list            # what the camera offers (look for YUYV 640x480)
sudo ./vinecam                   # camera -> FPGA -> DisplayPort monitor
```

On the screen: the camera picture with the **224×224 square the network actually sees** left
bright and the rest dimmed, the class in green (Healthy) or red (a disease), a softmax per
class, the FPGA's time per image and the whole loop's frame rate.

Keys on the console (the serial terminal, or SSH):

| key | does |
|:--|:--|
| `SPACE` | freeze/unfreeze the picture and the answer, while you talk about it |
| `S` | save the current frame for checking on the PC (step 10) |
| `Q` | quit (Ctrl-C also restores the screen) |

Once a second the console prints a status line: class, confidence, FPGA time, front-end time
and frame rate. Without a monitor, use `sudo ./vinecam --no-display`.

### 9. The browser view (recommended for the presentation)

A direct Ethernet cable between the board and the laptop, with fixed addresses:

```
# on the board
sudo ip addr add 192.168.10.2/24 dev eth0
sudo ip link set eth0 up
sudo ./vinecam --http 8080
```

On the laptop, set the Ethernet adapter's IPv4 address to `192.168.10.1`, mask
`255.255.255.0`, and open **http://192.168.10.2:8080/**. The page shows the board's screen
full-window and refreshes itself, so it is one Alt-Tab away from the slides. Use `--http`
together with a monitor or alone; the camera loop never waits for the browser.

### 10. Check saved frames on the PC

Every `S` writes `vinecam_NNNN_frame.ppm`, `_rgb256.bin`, `_input.bin` and `.txt` to the
current directory (`--dump-dir` to change it). Copy them to the PC, then:

```
python scripts/check_camera_frame.py vinecam_0003
```

It re-derives the window (torchvision's `Resize`), the int8 tensor (`export.py`'s
preprocessing) and the four logits (`export.py`'s integer model), from the saved picture
alone, and requires all of them to equal what the board produced. A frame that passes is one
where the board's answer is provably the model's answer **for that picture**. That turns "it
looked right in the demo" into a statement about specific frames, which is worth one slide.

What it cannot check is the camera's YUV→RGB conversion, which has nothing to be exact
against (see `camfront.h`). The frame is saved after that conversion, so every check starts
from the RGB the board actually used.

---

## For the presentation

- **The model was trained on single leaves photographed on plain backgrounds** (the
  PlantVillage style). That is what it recognises best. Hold the leaf, or a print or tablet
  showing a test-split leaf, **flat against a plain light background, filling the bright
  square**. A leaf on a busy background, or a live vine, is a different distribution, and a
  wrong answer then is the data, not the hardware.
- **Light.** In dim light webcams lengthen the exposure and drop to 15 fps or less. Bring a
  desk lamp.
- **Rehearse in the room**, with the projector and the leaves you will use. `S` on a good
  frame gives you a saved, PC-verified example to show if anything misbehaves live.
- **Freeze** (`SPACE`) when you want to talk about one answer. The screen says FROZEN.
- **Fallbacks:** the baremetal SD-card path from `firmware/README.md`, and a screen recording
  of a good run.

---

## Troubleshooting

| symptom | likely cause |
|:--|:--|
| the prompt says `xilinx-zcu104-20221`, and `/sys/class/uio` lists only `axi-pmon` | the board booted the old system from the card's ext4 partition - see step 5 |
| `petalinux-build` says `Failed to build project`, but every task succeeded | sstate download time-outs (`ConnectionError` in the log): run `build.sh` again - see step 4 |
| `no UIO device called vine-accel` | first `modprobe uio_pdrv_genirq` (step 6): this build makes it a module. If that does not help, the image was not built with `vinecam.dtsi`: check `ls /proc/device-tree/ \| grep vine`. If the node is there but no uio, vinecam binds it itself and says so |
| the board **freezes** at `reading the accelerator's ID` | the PL is not clocked or not programmed: a read of a dead AXI slave never completes. Check `cat /proc/cmdline` for `clk_ignore_unused`, and that `BOOT.BIN` was packaged with `--fpga` (step 4 does) |
| `the ID register did not read VINE` | the PL is clocked but holds another design: wrong `.bit` in `BOOT.BIN` |
| `the DMA region ... is listed as System RAM` | the carve-out is missing or lacks `no-map`: the kernel is using that memory |
| `--expect` FAILS with `image_q8.bin` | look at the DMA region before the accelerator: the `reg` in `vinecam.dtsi`, or `/proc/iomem` |
| `image_q8.bin` passes, `image_rgb.bin` fails | the board's `preproc_rgb`: the FPU rounding mode (the self-test should already have said so) |
| `offers neither YUYV nor UYVY` | an MJPEG-only camera: use another webcam |
| `no frames from the camera` on screen | the USB cable/adapter, or a USB 2 camera on a marginal hub. `dmesg \| tail` shows UVC errors |
| no picture on the monitor, or no `/dev/fb0` | no monitor was detected at boot: DisplayPort **P11** (HDMI P7 is not driven), an *active* adapter if the screen is HDMI, the monitor on before power-on. `cat /sys/class/drm/card*-DP-*/status` says whether it is seen. Meanwhile run with `--no-display`, or `--http` |
| the text console looks dead after a crash | `sudo ./vinecam --restore-console` |
| `Permission denied` on `/dev/uio*`, `/dev/fb0`, or inside the card's folder | run as root (`sudo -s`): the card is mounted root-only |

---

## How it works

### The accelerator under Linux: UIO and a carve-out

The baremetal driver relies on two things an operating system takes away: **a pointer is a
physical address**, and **the program owns the caches**. Under Linux a pointer is virtual,
and the kernel decides what is cached. `S_AXI_HP0_FPD` does neither address translation nor
cache snooping.

So `vinecam.dtsi` reserves 16 MB at `0x3800_0000` with **`no-map`**, which takes it out of
the kernel's memory map entirely, and exposes it together with the CSR as **one UIO device
with two maps**. The process maps both. UIO maps physical memory as Device-nGnRnE: never
cached anywhere. That gives three guarantees:

- **No stale data.** No cache can hold a line of the region, so the baremetal
  `Xil_DCacheFlushRange` becomes a **DSB**: wait until the writes have reached DDR, then
  tell the accelerator. This is `plat_linux.c`'s flush.
- **No wrong addresses.** The driver now asks the platform for each buffer's physical
  address (`accel_plat_phys`, a fifth hook; baremetal returns the pointer unchanged).
  `plat_linux.c` translates through the region and **refuses anything outside it**, so a
  `malloc`'d image can never reach the DMA. The driver also refuses addresses that would
  not fit its 32-bit registers.
- **No faults.** Device memory faults on unaligned accesses, which `memcpy` and `memset`
  make. Every write into the region is an aligned 64-bit store (`dmaregion_write`), and the
  blobs are read back once at start-up (`dmaregion_verify`), so a wrong mapping fails at
  start-up instead of as a wrong class.

`vine_uio.c` refuses a region that is above 2 GB (HP0 only reaches DDR_LOW), not
page-aligned, or listed as System RAM in `/proc/iomem`.

### The camera's front end: why the resize had to be exact

The reference pipeline is `Resize(256) → CenterCrop(224) → ToTensor → Normalize`. For the
dataset's 256×256 images `Resize` does nothing, which is why `preproc.c` could be exact
without a resampler (DD-033). A camera frame needs a real resize: 640×480 becomes 341×256
through **Pillow's antialiased BILINEAR**, whose filter widens with the reduction ratio.
`camfront.c` is a transcription of Pillow's `Resample.c`, evaluated only on the 256×256
window whose centre is `CenterCrop(224)`, and handed to `preproc_rgb` unchanged. The details
that make it exact rather than close, and the mistakes it was tested against, are in
`camfront.c`'s header. DD-035 records the decision.

### Timing

Per frame: the camera delivers YUYV, `camfront` converts and resizes (CPU), `preproc_rgb`
quantises (CPU, a table lookup), the tensor is copied into the region (CPU), and the
accelerator loads the image and runs (PL). The console's status line reports the FPGA time,
the front end's time and the copy separately, so a slow frame rate can be traced to its
stage. The FPGA's share is fixed: **6.659 ms**, measured on the board on 2026-10-22 (mean of
100 runs, 6.657 to 6.663 ms), against 6.41 ms predicted from simulation. The copy into the
region adds 0.160 ms. The rest depends on the camera resolution
(640×480 is the default and the fastest that is still sharp enough) and on the monitor's
resolution, since the whole screen is redrawn every frame.
