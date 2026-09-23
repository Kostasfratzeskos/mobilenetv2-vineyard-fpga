#=============================================================================
#  impl.tcl  -  out-of-context synthesis AND place-and-route of accel_top
#
#  Run it through scripts/run_impl.sh, for the same reason synth.tcl is run
#  through run_synth.sh: that script finds Vivado and starts it with the
#  repository root as the working directory, and everything below uses RELATIVE
#  paths on purpose (Vivado's read_* commands treat their argument as a Tcl
#  LIST, so a path containing a space would be split into two non-existent
#  files).
#
#  ---- why this exists next to synth.tcl --------------------------------
#
#  synth.tcl stops at synthesis, where the route delay is an estimate from a
#  wireload model. make_project.tcl can run implementation, but only through the
#  GUI project flow, which is not reproducible from a shell and cannot be put in
#  a report. DD-018's conclusion ("the final number needs place and route") and
#  the review's acceptance test ("until the constraint says 4.000 ns, no timing
#  claim is measured") both need a batch post-route number, so this is that:
#  synth_design -> opt -> place -> phys_opt -> route, then the reports.
#
#  Out of context for the same reason as synth.tcl: the PS, the DMA and the AXI
#  plumbing do not exist yet, and accel_top's 841 port bits exceed the ~300 PL
#  user I/O of the package, so a normal flow fails I/O placement before it ever
#  reaches timing.
#
#  ---- the period comes from the XDC, never from here -------------------
#
#  PERIOD is an OVERRIDE, not the constraint. Left unset, the checked-in
#  hardware/constraints/accel_top_ooc.xdc is used exactly as committed. Set it
#  and this script rewrites only the create_clock line, into a copy under
#  build/impl_<tag>/, and says so in the log. That keeps "which constraint was
#  this measured at" a fact in the report rather than a memory:
#
#      PERIOD=4.000 bash scripts/run_impl.sh          # the 250 MHz target
#      bash scripts/run_impl.sh                       # whatever the XDC says
#=============================================================================

set part "xczu7ev-ffvc1156-2-e"
set top  "accel_top"

# TAG names the output directory so two constraints can be compared without one
# overwriting the other.
set tag  [expr {[info exists ::env(TAG)] ? $::env(TAG) : "default"}]
set out  "build/impl_$tag"

file mkdir $out

create_project -in_memory -part $part
set_property target_language Verilog [current_project]

set srcs [concat [glob -nocomplain "hardware/rtl/kernels/*.v"] \
                 [glob -nocomplain "hardware/rtl/control/*.v"]]
foreach f $srcs { read_verilog [list $f] }
puts "== read [llength $srcs] Verilog files"

# ---- constraints: the committed XDC, or a period-overridden copy of it ------
set xdc "hardware/constraints/accel_top_ooc.xdc"
if {[info exists ::env(PERIOD)]} {
    set per $::env(PERIOD)
    set fh [open $xdc r]; set txt [read $fh]; close $fh
    # Rewrite ONLY the create_clock period. Substituting the whole line would
    # drop the -name/-add options a future XDC might carry.
    set n [regsub -all {create_clock\s+-period\s+[0-9.]+} $txt \
                       "create_clock -period $per" txt]
    if {$n != 1} {
        error "PERIOD override expected exactly 1 create_clock in $xdc, found $n"
    }
    set xdc "$out/accel_top_ooc_${per}.xdc"
    set fh [open $xdc w]; puts -nonewline $fh $txt; close $fh
    puts "== PERIOD OVERRIDE: create_clock -period $per  (copy at $xdc)"
} else {
    puts "== constraints as committed: $xdc"
}
read_xdc [list $xdc]

puts "== part : $part"
puts "== top  : $top"
puts "== out  : $out"
puts "== cwd  : [pwd]"

# ---- synthesis -------------------------------------------------------------
synth_design -top $top -part $part -mode out_of_context
report_utilization                       -file "$out/synth_utilization.rpt"
report_timing_summary -max_paths 10      -file "$out/synth_timing_summary.rpt"
write_checkpoint -force                        "$out/post_synth.dcp"

# ---- implementation --------------------------------------------------------
# phys_opt_design is included because the GUI project flow that produced the
# baseline ran it too, so leaving it out here would compare two different flows.
opt_design
place_design
phys_opt_design
route_design

report_utilization               -file "$out/utilization.rpt"
report_utilization -hierarchical -file "$out/utilization_hier.rpt"
report_timing_summary -max_paths 10 -file "$out/timing_summary.rpt"
report_timing -max_paths 25 -sort_by group -file "$out/timing_paths.rpt"
write_checkpoint -force "$out/post_route.dcp"

#---- a summary on stdout, so the shell does not have to parse reports --------
puts ""
puts "================== POST-ROUTE SUMMARY ($tag) =================="

# The period is read back from the CLOCK, not from a literal and not from the
# PERIOD variable - synth.tcl's header records what a hardcoded 4 cost once
# ("Fmax 3401 MHz, meets 250 MHz" from dividing by the wrong number).
set clk [lindex [get_clocks] 0]
set per [get_property PERIOD $clk]

set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} {
    set p   [lindex $paths 0]
    set wns [get_property SLACK $p]
    set fmax [expr {1000.0 / ($per - $wns)}]
    puts [format "  constraint       : %.3f ns = %.1f MHz" $per [expr {1000.0/$per}]]
    puts [format "  WNS (setup)      : %s ns" $wns]
    puts [format "  => Fmax          : %.1f MHz   - %s" $fmax \
              [expr {$wns < 0 ? "DOES NOT MEET the constraint" : "meets the constraint"}]]
    puts "  worst path from  : [get_property STARTPOINT_PIN $p]"
    puts "               to  : [get_property ENDPOINT_PIN   $p]"
    puts [format "  data path delay  : %s ns  (logic %s, route %s)" \
              [get_property DATAPATH_DELAY $p] \
              [get_property DATAPATH_LOGIC_DELAY $p] \
              [get_property DATAPATH_NET_DELAY   $p]]
    puts "  logic levels     : [get_property LOGIC_LEVELS $p]"
}
puts ""
puts "  full reports in $out/"
puts "=============================================================="
