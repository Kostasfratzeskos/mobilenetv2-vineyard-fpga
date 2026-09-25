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

#  TOP selects what is synthesised, and the XDC follows it. Left unset it is
#  accel_top, which is every number in the docs up to and including Phase 6.
#  Set it to accel_sys to measure the accelerator WITH the weight DMA, against
#  hardware/constraints/accel_sys_ooc.xdc:
#
#      TOP=accel_sys bash scripts/run_synth.sh
#
#  The outputs go to build/synth_<top>/ so two tops can be compared without one
#  overwriting the other. accel_top keeps build/synth/ so the existing reports
#  and everything quoting them stay where they are.
set top [expr {[info exists ::env(TOP)] ? $::env(TOP) : "accel_top"}]
set out [expr {$top eq "accel_top" ? "build/synth" : "build/synth_$top"}]
set xdc "hardware/constraints/${top}_ooc.xdc"

file mkdir $out

puts "== part : $part"
puts "== top  : $top"
puts "== xdc  : $xdc"
puts "== cwd  : [pwd]"

create_project -in_memory -part $part
set_property target_language Verilog [current_project]

# hardware/rtl/axi and hardware/rtl/top are in this list because leaving them
# out does not fail - it produces a clean-looking report of the WRONG design,
# with the missing module inferred as a black box. Whatever is added under
# hardware/rtl/ has to be added here, to scripts/impl.tcl and to
# scripts/make_project.tcl, all three.
set srcs [concat [glob -nocomplain "hardware/rtl/kernels/*.v"] \
                 [glob -nocomplain "hardware/rtl/control/*.v"] \
                 [glob -nocomplain "hardware/rtl/axi/*.v"] \
                 [glob -nocomplain "hardware/rtl/top/*.v"]]
foreach f $srcs { read_verilog [list $f] }
puts "== read [llength $srcs] Verilog files"

read_xdc [list $xdc]

synth_design -top $top -part $part -mode out_of_context

report_utilization               -file "$out/utilization.rpt"
report_utilization -hierarchical -file "$out/utilization_hier.rpt"
report_timing_summary -max_paths 10 -file "$out/timing_summary.rpt"
report_timing -max_paths 25 -sort_by group -file "$out/timing_paths.rpt"
write_checkpoint -force "$out/${top}_synth.dcp"

#---- a short summary on stdout, so the shell does not have to parse reports --
puts ""
puts "================== SYNTHESIS SUMMARY =================="

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} {
    set p   [lindex $paths 0]
    set wns [get_property SLACK $p]
    # The period comes from the constraint file, not from a literal here. It was
    # 4.000 once, the xdc moved to 25.000, and this line kept dividing by 4 -
    # which turned a healthy +3.706 ns of slack into "Fmax 3401 MHz, meets
    # 250 MHz". A summary that cannot be wrong is worth more than one that is
    # short.
    set per  [get_property PERIOD [lindex [get_clocks] 0]]
    set fmax [expr {1000.0 / ($per - $wns)}]
    puts [format "  WNS (setup)      : %s ns   (constraint %.3f ns = %.1f MHz)" \
              $wns $per [expr {1000.0 / $per}]]
    if {$wns < 0} {
        puts [format "  => Fmax          : %.1f MHz   - DOES NOT MEET the constraint" $fmax]
    } else {
        puts [format "  => Fmax          : %.1f MHz   - meets the constraint" $fmax]
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
puts "  full reports in $out/"
puts "======================================================"
