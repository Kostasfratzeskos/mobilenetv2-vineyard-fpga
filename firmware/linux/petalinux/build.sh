#!/usr/bin/env bash
#=============================================================================
#  build.sh  -  a PetaLinux 2022.2 image for the ZCU104 that can run vinecam
#
#  Run on a LINUX host with PetaLinux 2022.2 installed - it does not run on
#  Windows, and under WSL2 the project must live in the Linux filesystem (~/),
#  not under /mnt/c:
#
#      source /tools/Xilinx/PetaLinux/2022.2/settings.sh
#      bash firmware/linux/petalinux/build.sh \
#          --bsp ~/Downloads/xilinx-zcu104-v2022.2-10141622.bsp \
#          --xsa build/bd_187p5_explore/accel_bd_wrapper.xsa
#
#  Options:
#      --bsp FILE   the ZCU104 BSP from the PetaLinux download page (matching
#                   the tools: 2022.2). It brings the board's own device tree -
#                   the USB PHY, the DisplayPort clocking, the I2C muxes.
#      --xsa FILE   the hardware handoff from scripts/run_bd.sh
#      --bit FILE   the bitstream. Default: the .bit beside the .xsa, because
#                   make_bd.tcl writes the XSA WITHOUT one (see its comment).
#      --dir DIR    the project to create (default: ./vinecam-plnx). Refused
#                   if it exists, unless --reuse is given.
#      --reuse      configure and build an existing project again
#
#  What it does to the BSP's project, and nothing else:
#
#    1. imports the XSA - our PS configuration, and the accelerator at 0xA000_0000
#    2. APPENDS three things to PetaLinux's generated kernel command line:
#         uio_pdrv_genirq.of_id=generic-uio   lets UIO take the accelerator node
#         consoleblank=0                      no blank screen during the talk
#         clk_ignore_unused                   only if missing - see below
#       Appending rather than replacing: PetaLinux's line also says where the
#       console and the root filesystem are, and a guess at those is how an
#       image stops booting.
#    3. appends vinecam.dtsi to system-user.dtsi: the DMA carve-out, the UIO
#       node, USB in host mode
#    4. adds vinecam.cfg to the kernel: UIO, UVC webcams, the fbdev console
#    5. builds, and packages BOOT.BIN with the bitstream, so the FSBL programs
#       the PL before Linux starts
#
#  clk_ignore_unused matters more than it looks. No Linux driver claims the PL
#  clock, so late in boot the kernel switches "unused" clocks off - and the
#  next read of the accelerator's CSR then never completes, which hangs the
#  board instead of failing. PetaLinux's ZynqMP line normally carries it; this
#  makes sure.
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BSP="" XSA="" BIT="" DIR="vinecam-plnx" REUSE=0

die()  { echo "build.sh: $*" >&2; exit 1; }
note() { echo; echo "==== $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bsp)   BSP="$2"; shift 2 ;;
        --xsa)   XSA="$2"; shift 2 ;;
        --bit)   BIT="$2"; shift 2 ;;
        --dir)   DIR="$2"; shift 2 ;;
        --reuse) REUSE=1; shift ;;
        -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
        *) die "unknown option $1 (try --help)" ;;
    esac
done

command -v petalinux-create >/dev/null ||
    die "PetaLinux is not in this shell: source <PetaLinux>/settings.sh first"
if [[ "${PETALINUX_VER:-}" != "2022.2" ]]; then
    echo "build.sh: WARNING: PetaLinux ${PETALINUX_VER:-?} - this was written for 2022.2," \
         "the version that matches the Vivado 2022.2 the hardware was built with" >&2
fi
[[ -n "$XSA" && -f "$XSA" ]] || die "--xsa: no such file '$XSA'"
XSA="$(cd "$(dirname "$XSA")" && pwd)/$(basename "$XSA")"
[[ -n "$BIT" ]] || BIT="${XSA%.xsa}.bit"
[[ -f "$BIT" ]] || die "no bitstream at '$BIT' - give it with --bit"
BIT="$(cd "$(dirname "$BIT")" && pwd)/$(basename "$BIT")"
case "$(pwd)" in /mnt/*) echo "build.sh: WARNING: building under /mnt is slow and" \
    "case-insensitive under WSL2 - use a directory in ~/" >&2 ;; esac

# ---- 1. the project ---------------------------------------------------------
if [[ -d "$DIR" ]]; then
    [[ $REUSE -eq 1 ]] || die "$DIR exists - remove it, or pass --reuse"
else
    [[ -n "$BSP" && -f "$BSP" ]] || die "--bsp: no such file '$BSP'"
    note "creating $DIR from $(basename "$BSP")"
    ( cd "$(dirname "$DIR")" && petalinux-create -t project -s "$BSP" --name "$(basename "$DIR")" )
fi
cd "$DIR"
CFG=project-spec/configs/config
[[ -f "$CFG" ]] || die "$DIR does not look like a PetaLinux project"

note "importing the hardware: $(basename "$XSA")"
rm -rf hw-in && mkdir hw-in && cp "$XSA" hw-in/
petalinux-config --get-hw-description="$(pwd)/hw-in" --silentconfig

# ---- 2. the kernel command line: PetaLinux's, plus ours -----------------------
set_cfg()   { sed -i "/^$1=/d; /^# $1 is not set/d" "$CFG"; echo "$1=$2" >> "$CFG"; }
unset_cfg() { sed -i "/^$1=/d; /^# $1 is not set/d" "$CFG"; echo "# $1 is not set" >> "$CFG"; }

base="$(sed -n 's/^CONFIG_SUBSYSTEM_BOOTARGS_GENERATED="\(.*\)"$/\1/p' "$CFG")"
if [[ -z "$base" ]]; then
    base="$(sed -n 's/^CONFIG_SUBSYSTEM_USER_CMDLINE="\(.*\)"$/\1/p' "$CFG")"
fi
if [[ -z "$base" ]]; then
    base="earlycon console=ttyPS0,115200 clk_ignore_unused init_fatal_sh=1"
    echo "build.sh: WARNING: could not read PetaLinux's generated command line;" \
         "using the ZCU104 default: $base" >&2
fi
args="$(echo "$base" | sed 's/^ *//')"
for want in clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio consoleblank=0; do
    [[ " $args " == *" $want "* ]] || args="$args $want"
done
note "kernel command line: $args"
unset_cfg CONFIG_SUBSYSTEM_BOOTARGS_AUTO
set_cfg   CONFIG_SUBSYSTEM_USER_CMDLINE "\"$args\""

# ---- 3. the device tree -----------------------------------------------------
DTS=project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi
[[ -f "$DTS" ]] || die "no $DTS in this project"
if grep -q "vine-accel@a0000000" "$DTS"; then
    echo "  system-user.dtsi already has the vinecam nodes"
else
    note "appending vinecam.dtsi to system-user.dtsi"
    { echo; echo "/* ==== appended by firmware/linux/petalinux/build.sh ==== */";
      cat "$HERE/vinecam.dtsi"; } >> "$DTS"
fi

# ---- 4. the kernel ----------------------------------------------------------
KDIR=project-spec/meta-user/recipes-kernel/linux
mkdir -p "$KDIR/linux-xlnx"
cp "$HERE/vinecam.cfg" "$KDIR/linux-xlnx/"
APPEND="$KDIR/linux-xlnx_%.bbappend"
if [[ ! -f "$APPEND" ]]; then
    echo 'FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"' > "$APPEND"
fi
grep -q "file://vinecam.cfg" "$APPEND" ||
    echo 'SRC_URI:append = " file://vinecam.cfg"' >> "$APPEND"

petalinux-config --silentconfig

# ---- 5. build and package ---------------------------------------------------
note "petalinux-build (the first run takes an hour or more)"
petalinux-build

note "BOOT.BIN: FSBL, PMU firmware, ATF, U-Boot - and the bitstream"
petalinux-package --boot --force \
    --fsbl images/linux/zynqmp_fsbl.elf \
    --pmufw images/linux/pmufw.elf \
    --fpga "$BIT" \
    --u-boot

# ---- 6. check the result says what vinecam needs ----------------------------
if command -v dtc >/dev/null && [[ -f images/linux/system.dtb ]]; then
    dts="$(dtc -I dtb -O dts images/linux/system.dtb 2>/dev/null)"
    ok=1
    for want in 'vine-accel@a0000000' 'generic-uio' 'vine-dma@38000000' 'no-map' \
                'uio_pdrv_genirq.of_id=generic-uio' 'clk_ignore_unused'; do
        if grep -q -- "$want" <<<"$dts"; then echo "  [ok ] $want"
        else echo "  [!!] $want is NOT in images/linux/system.dtb"; ok=0; fi
    done
    [[ $ok -eq 1 ]] || die "the built device tree is missing something vinecam needs"
else
    echo "  (dtc not found - skipped checking images/linux/system.dtb)"
fi

note "done. Copy to the FAT32 partition of the SD card:"
ls -la images/linux/BOOT.BIN images/linux/boot.scr images/linux/image.ub
echo
echo "  ... and, from the repository: firmware/linux/build/aarch64/vinecam and"
echo "  build/sdcard/*  (program.bin, weights.bin, params_*.bin, image_*.bin,"
echo "  EXPECTED.txt). Then see firmware/linux/README.md, 'On the board'."
