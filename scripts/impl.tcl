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

#  TOP selects what is implemented, and the XDC follows it - the same override
#  scripts/synth.tcl takes. Left unset it is accel_top, which is every
#  post-route number in the docs up to and including Phase 6.
#
#      PERIOD=4.000 bash scripts/run_impl.sh                    # accel_top
#      TOP=accel_sys PERIOD=4.000 bash scripts/run_impl.sh      # + the DMA
#      TOP=accel_axi PERIOD=4.000 bash scripts/run_impl.sh      # + the CSR
#
#  Why this matters more here than in synth.tcl: a post-route Fmax carries real
#  placement noise. docs/lab_notebook.md records Phase 3 -> 4 swinging +23 MHz
#  "on placement alone with no timing-directed change in it", so comparing two
#  tops means running them through the SAME flow in the same session, not
#  quoting one against a number from a previous day. Three runs, one command
#  each, is the only honest way to say what a layer cost.
set top  [expr {[info exists ::env(TOP)] ? $::env(TOP) : "accel_top"}]

# TAG names the output directory so two constraints - or two tops - can be
# compared without one overwriting the other. run_impl.sh defaults it to
# <top>_<period>.
set tag  [expr {[info exists ::env(TAG)] ? $::env(TAG) : $top}]
set out  "build/impl_$tag"

file mkdir $out

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

# ---- constraints: the committed XDC, or a period-overridden copy of it ------
#  One XDC per top. All three keep the same period, reset treatment and URAM
#  expectation on purpose, so the three numbers stay comparable - see the header
#  of accel_axi_ooc.xdc.
set xdc "hardware/constraints/${top}_ooc.xdc"
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
    set xdc "$out/${top}_ooc_${per}.xdc"
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

# ---- stop here if only synthesis was asked for ------------------------------
#  SYNTH_ONLY=1 exists for experiments that a synthesis run already answers, so
#  they cost 12 minutes instead of 50. The one it was added for: whether Vivado
#  will absorb a register into a DSP48E2 once that register stops carrying an
#  asynchronous reset (DD-020). That is decided at SYNTHESIS - the register
#  either disappears into the DSP or it does not - and the methodology check
#  that names the failure, DPIR-2, only reports after placement, so watching
#  DPIR-2 is the slow way to see it. What to compare instead: the flip-flop
#  count of the module that owns the register, and the source of the worst path.
if {[info exists ::env(SYNTH_ONLY)] && $::env(SYNTH_ONLY) == 1} {
    report_utilization -hierarchical -file "$out/synth_utilization_hier.rpt"
    puts ""
    puts "================== SYNTHESIS ONLY ($tag) =================="
    set clk [lindex [get_clocks] 0]
    set per [get_property PERIOD $clk]
    set p   [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]
    puts [format "  constraint       : %.3f ns" $per]
    puts "  WNS (setup)      : [get_property SLACK $p]"
    puts "  worst path from  : [get_property STARTPOINT_PIN $p]"
    puts "               to  : [get_property ENDPOINT_PIN   $p]"
    puts "  reports in $out/  (post-route ones NOT produced)"
    puts "=========================================================="
    return
}

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

# report_methodology is here because DPIR-2 is now a number this project tracks,
# not a curiosity. It says how many registers Vivado cannot merge into a DSP
# block because they carry an asynchronous reset - 10,940 at the Phase 0
# baseline - and that count is the thing DD-020 is about and the thing L-1's
# pipelining depends on. It was measured by hand once and that is exactly how a
# number stops being measured, so it is in the flow.
report_methodology -file "$out/methodology.rpt"

write_checkpoint -force "$out/post_route.dcp"

#---- a summary on stdout, so the shell does not have to parse reports --------
puts ""
puts "================== POST-ROUTE SUMMARY ($top, $tag) =================="

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

# DPIR-2 on stdout too, so "can a register enter a DSP yet" is visible without
# opening a 6 MB report. Zero is the goal; see DD-020.
set dpir [llength [get_methodology_violations -filter {CHECK_NAME == DPIR-2}]]
puts [format "  DPIR-2 (async driver blocking DSP register merge) : %d" $dpir]
puts ""
puts "  full reports in $out/"
puts "=============================================================="
