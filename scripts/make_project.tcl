#=============================================================================
#  make_project.tcl  -  build a Vivado GUI project from the repository
#
#  The scripts here are batch-first on purpose: run_sim.sh and run_synth.sh are
#  reproducible and need no project. This is for what a project is genuinely
#  better at - browsing the hierarchy, reading schematics, and above all running
#  IMPLEMENTATION, which is the only thing that produces a real Fmax. Synthesis
#  reports an ESTIMATED route delay from a wireload model; DD-018's -17.357 ns
#  is 91% logic, so it stands on its own, but the final number needs place and
#  route.
#
#  Usage, from the repository root:
#      vivado -mode batch -source scripts/make_project.tcl
#  then open the .xpr path it prints.
#
#  ---- PARENTHESES IN THE PATH, which is the whole complication ---------
#
#  Vivado rejects parentheses in BOTH the project path and every source path,
#  and this repo sits under ".../Διπλωματική(Grape IoT)/...":
#
#      ERROR: [ProjectBase 2-104] Project name '...' is illegal.
#                                 Invalid character ( found.
#      ERROR: [Vivado 12-385]     Illegal file or directory name '.../avgpool.v'
#
#  The batch flow does not care - xvlog, xelab and synth_design all take these
#  paths happily - so this is purely a project-mode restriction. Two ways out:
#
#  1. Rename the folder so it has no parentheses. Cleanest, and it also removes
#     the space, which caused its own trouble in synth.tcl (Vivado splits
#     list-typed arguments on whitespace). git does not care: the repo is the
#     inner directory, so its history is untouched.
#
#  2. Make a directory junction with a clean name and drive Vivado through it.
#     No admin rights needed, nothing moves, reversible with rmdir:
#
#         cmd /c mklink /J C:\grape_iot "C:\...\Διπλωματική(Grape IoT)\mobilenetv2-vineyard-fpga"
#         cd /c/grape_iot
#         REPO_DIR=C:/grape_iot vivado -mode batch -source scripts/make_project.tcl
#
#     REPO_DIR is needed because Tcl's [pwd] resolves the junction back to its
#     real target, which would put the parentheses straight back in.
#
#  The project itself defaults to C:/vivado_prj (override with PRJ_DIR) and
#  REFERENCES sources where they live, so editing in the GUI edits the real
#  file and git sees it. Nothing in the project is a source of truth - delete
#  it and re-run whenever.
#
#  ---- why out-of-context ------------------------------------------------
#
#  accel_top has 841 port bits. The XCZU7EV package has roughly 300 PL user
#  I/O, so a normal project flow - which inserts an I/O buffer per port - fails
#  I/O placement before it ever gets to timing. That is not a flaw in the
#  design: those ports are the weight/program/image load buses, which will be
#  driven by a DMA inside the fabric once that exists. Until then the honest
#  way to measure the accelerator is out of context, so synth_1 is configured
#  that way here, exactly as scripts/run_synth.sh does it.
#
#  ---- one caveat about simulation in the GUI ---------------------------
#
#  13 of the 31 testbenches read golden vectors with paths like
#  "../../software/golden/...", resolved against the SIMULATION WORKING
#  DIRECTORY. run_sim.sh runs them from sim/xsim_<module>/, two levels below the
#  root, so they resolve. A Vivado project simulates from
#  <proj>/<proj>.sim/sim_1/behav/xsim/ - five levels down - so those will not
#  find their data. For waveforms use the batch flow, which gets this right:
#
#      WAVES=1 bash scripts/run_sim.sh accel accel_top top_seq ...
#
#  The other 18 generate their own stimulus and run fine in the project.
#=============================================================================

set part  "xczu7ev-ffvc1156-2-e"
set pname "mobilenetv2_accel"

# REPO_DIR exists because Tcl's [pwd] resolves a Windows junction back to its
# real target, which puts the parentheses straight back into the path. Point it
# at the junction and Vivado never sees them. See the header.
if {[info exists ::env(REPO_DIR)]} {
    set root [string map {\\ /} $::env(REPO_DIR)]
} else {
    set root [pwd]
}

if {[info exists ::env(PRJ_DIR)]} {
    set pdir $::env(PRJ_DIR)
} elseif {[regexp {[()]} $root]} {
    set pdir "C:/vivado_prj/$pname"
} else {
    set pdir "$root/build/vivado"
}

puts "== repo : $root"
puts "== part : $part"
puts "== proj : $pdir"

file mkdir $pdir
create_project -force $pname $pdir -part $part
set_property target_language Verilog [current_project]

# Absolute paths, each wrapped in a list: Vivado's file commands treat their
# argument as a Tcl list, and this repo's path contains a space.
# NOT [file normalize]: that resolves the junction and reintroduces the
# parentheses. The paths built from $root are already absolute.
proc add_abs {fileset paths} {
    foreach p $paths {
        add_files -norecurse -fileset $fileset [list $p]
    }
}

# ---- design sources -------------------------------------------------------
set rtl [concat [glob -nocomplain "$root/hardware/rtl/kernels/*.v"] \
                [glob -nocomplain "$root/hardware/rtl/control/*.v"]]
add_abs sources_1 $rtl
set_property top accel_top [get_filesets sources_1]
puts "== added [llength $rtl] RTL files, top = accel_top"

# ---- constraints ----------------------------------------------------------
add_abs constrs_1 [list "$root/hardware/constraints/accel_top_ooc.xdc"]

# ---- simulation sources ---------------------------------------------------
set tbs [glob -nocomplain "$root/hardware/tb/*_tb.sv"]
add_abs sim_1 $tbs
set_property file_type SystemVerilog [get_files -of [get_filesets sim_1] *.sv]

# program_ops.svh is `include-d by accel_tb and is GENERATED:
#     python scripts/gen_program.py --emit
if {[file exists "$root/hardware/tb/program_ops.svh"]} {
    add_abs sim_1 [list "$root/hardware/tb/program_ops.svh"]
    set_property file_type {Verilog Header} \
        [get_files -of [get_filesets sim_1] *program_ops.svh]
} else {
    puts "== WARNING: hardware/tb/program_ops.svh is missing."
    puts "==          run: python scripts/gen_program.py --emit"
}
set_property include_dirs [list "$root/hardware/tb"] [get_filesets sim_1]
set_property top accel_tb [get_filesets sim_1]
puts "== added [llength $tbs] testbenches, sim top = accel_tb"

# A whole inference is ~13.8 ms of simulated time. The 1000ns default would
# stop during the image load, before the first op even starts.
set_property -name {xsim.simulate.runtime} -value {20ms} \
    -objects [get_filesets sim_1]

# ---- out of context, for the reason in the header -------------------------
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-mode out_of_context} -objects [get_runs synth_1]

puts ""
puts "=============================================================="
puts "  open with:  vivado $pdir/$pname.xpr"
puts ""
puts "  Run Synthesis      reproduces DD-018 (944 DSP, 52 URAM, WNS -17.4 ns)"
puts "  Run Implementation place and route - the first REAL Fmax"
puts ""
puts "  Waveforms are better from the batch flow:"
puts "      WAVES=1 bash scripts/run_sim.sh <module> <sources...>"
puts "=============================================================="
