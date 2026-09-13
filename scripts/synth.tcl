#=============================================================================
#  synth.tcl  -  out-of-context synthesis of accel_top for the ZCU104
#
#  Run it through scripts/run_synth.sh rather than directly: that script finds
#  Vivado and, importantly, starts it with the repository root as the working
#  directory. Everything below uses RELATIVE paths on purpose - this project
#  lives under a directory with a space in its name, and Vivado's read_*
#  commands treat their argument as a Tcl LIST, so an absolute path would be
#  split into two non-existent files. Relative paths inside the repo have no
#  spaces, which sidesteps the whole problem.
#
#  Everything the docs say about area and frequency so far is a target derived
#  from a spreadsheet: ~442 DSP, 26% of the device, 250 MHz. This is the first
#  thing in the project that can contradict any of it.
#
#  Out of context because the PS, the DMA and the AXI plumbing do not exist
#  yet. That is honest about what is being measured - the accelerator's own
#  logic - and does not pretend to be a system-level result.
#=============================================================================

set part "xczu7ev-ffvc1156-2-e"
set top  "accel_top"
set out  "build/synth"

file mkdir $out

puts "== part : $part"
puts "== top  : $top"
puts "== cwd  : [pwd]"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]

set srcs [concat [glob -nocomplain "hardware/rtl/kernels/*.v"] \
                 [glob -nocomplain "hardware/rtl/control/*.v"]]
foreach f $srcs { read_verilog [list $f] }
puts "== read [llength $srcs] Verilog files"

read_xdc [list "hardware/constraints/accel_top_ooc.xdc"]

synth_design -top $top -part $part -mode out_of_context

report_utilization               -file "$out/utilization.rpt"
report_utilization -hierarchical -file "$out/utilization_hier.rpt"
report_timing_summary -max_paths 10 -file "$out/timing_summary.rpt"
report_timing -max_paths 25 -sort_by group -file "$out/timing_paths.rpt"
write_checkpoint -force "$out/accel_top_synth.dcp"

#---- a short summary on stdout, so the shell does not have to parse reports --
puts ""
puts "================== SYNTHESIS SUMMARY =================="

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} {
    set p   [lindex $paths 0]
    set wns [get_property SLACK $p]
    puts [format "  WNS (setup)      : %s ns   (target period 4.000 ns = 250 MHz)" $wns]
    set fmax [expr {1000.0 / (4.000 - $wns)}]
    if {$wns < 0} {
        puts [format "  => Fmax          : %.1f MHz   - DOES NOT MEET 250 MHz" $fmax]
    } else {
        puts [format "  => Fmax          : %.1f MHz   - meets 250 MHz" $fmax]
    }
    puts "  worst path from  : [get_property STARTPOINT_PIN $p]"
    puts "               to  : [get_property ENDPOINT_PIN   $p]"
}

#  Resource counts are NOT printed here. Counting the netlist with
#  get_cells -filter PRIMITIVE_TYPE looked tidier than parsing a report, and it
#  was wrong: it reported 8,496 DSPs and 0 LUTs for a design report_utilization
#  put at 944 and 32,387. The filter matches sub-cells of a macro, not the macro.
#  run_synth.sh greps utilization.rpt instead, which is the authoritative count.
puts ""
puts "  full reports in build/synth/"
puts "======================================================"
