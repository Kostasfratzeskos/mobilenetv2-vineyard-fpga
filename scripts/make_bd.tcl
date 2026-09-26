#=============================================================================
#  make_bd.tcl  -  the BOARD design: accel_axi wired to the ZCU104's PS
#
#  Run it through scripts/run_bd.sh, for the same reason synth.tcl and impl.tcl
#  are run through their own wrappers: that script finds Vivado and starts it
#  with the repository root as the working directory, and everything below uses
#  RELATIVE paths on purpose - this project lives under a directory with a space
#  in its name, and Vivado's read_* commands treat their argument as a Tcl LIST,
#  so an absolute path would be split into two non-existent files.
#
#  ---- why this exists, and what it is the first of ----------------------
#
#  Every area and frequency number in this project so far - all seven post-route
#  runs included - is OUT OF CONTEXT. scripts/impl.tcl:22 records the reason:
#  accel_top had 841 port bits against the ~300 PL user I/O of the package, so a
#  normal flow failed I/O placement before it reached timing. DD-030, DD-031 and
#  DD-032 removed that obstacle one interface at a time:
#
#      accel_top   846 port bits   672 of them the load side, undriven
#      accel_sys   493 port bits   + wgt_dma took the weights, params, image
#      accel_axi   313 port bits   + axi_lite_csr took control and the program
#
#  and of accel_axi's 313, every single one is an AXI interface, a clock, a reset
#  or an interrupt. Nothing needs a pin. So this is the first design in the
#  project that CAN be implemented in context, and the first number it produces
#  is the first honest answer to `08_OPEN_ITEMS` risk 1, "the board is the
#  unknown".
#
#  ---- there is no XDC here, and that is the point -----------------------
#
#  hardware/constraints/accel_*_ooc.xdc exist to invent a clock and budget pins
#  that had nothing on the other side. In a block design the clock comes from the
#  PS and every interface is internal, so none of that applies: the constraint
#  is CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ below, which is a real PLL
#  setting rather than a promise. The three OOC files stay for measuring the
#  layers in isolation, which is still worth doing.
#
#  ---- the connections, and why each port -------------------------------
#
#    S_AXI_HP0_FPD  <- accel_axi's AXI4 read master.  128-bit, and that is not a
#                      coincidence: wgt_dma.v's header says it is 128-bit
#                      "because that is BOTH the S_AXI_HP data width on the ZU+
#                      AND the pointwise bank word (TN*DATA_W)". Direct
#                      connection, no width conversion anywhere.
#    M_AXI_HPM0_FPD -> a SmartConnect -> accel_axi's AXI4-Lite slave, 32-bit,
#                      mapped at CSR_BASE below. The PS master is full AXI4 and
#                      the CSR is AXI4-Lite, which is what the SmartConnect is
#                      for.
#    pl_ps_irq0[0]  <- irq. DD-031 put it behind IRQ_EN, so a PS that prefers
#                      polling leaves the pin alone.
#    pl_clk0        -> everything. One clock domain, as wgt_dma.v and
#                      axi_lite_csr.v both state: the HP and HPM aclk inputs are
#                      driven by this same PL clock, so there is no CDC in the
#                      design and none is invented here.
#
#  ---- the frequency is a decision, not a default -----------------------
#
#  PL_MHZ defaults to 200. Seven post-route OOC runs put this design at
#  197-208 MHz (see docs/lab_notebook.md), so 200 is the honest "what it does"
#  figure and the margin is thin on purpose - if real interconnect eats it, the
#  slack number says by how much, and that IS the measurement. Override it to
#  get a bitstream that closes:
#
#      PL_MHZ=200 bash scripts/run_bd.sh          # the measurement
#      PL_MHZ=150 bash scripts/run_bd.sh          # a comfortable bitstream
#=============================================================================

set part  "xczu7ev-ffvc1156-2-e"
set board "xilinx.com:zcu104:part0:1.1"
set top   "accel_axi"

set plmhz [expr {[info exists ::env(PL_MHZ)] ? $::env(PL_MHZ) : 200}]
set tag   [expr {[info exists ::env(TAG)]    ? $::env(TAG)    : "${plmhz}mhz"}]
set out   "build/bd_$tag"

#  The AXI-Lite aperture. 0xA000_0000 is the conventional start of the
#  M_AXI_HPM0_FPD window on the ZU+, and 8 KB is what axi_lite_csr's ADDR_W=13
#  asks for: registers at 0x0000 and the 2 KB program aperture at 0x1000.
set csr_base 0xA0000000
set csr_size 8K

file mkdir $out

#  An ON-DISK project rather than `create_project -in_memory`, which is what
#  synth.tcl and impl.tcl use. The reason is specific: an in-memory project is
#  in MANUAL compile-order mode, and a block design cannot reference an RTL
#  module in that mode - Vivado says so and stops:
#
#      CRITICAL WARNING: [filemgmt 56-176] Module references are not supported
#      in manual compile order mode and will be ignored.
#      ERROR: [BD 41-1690] Unable to resolve module-source based on inputs
#
#  So the project goes under $out/proj (gitignored, regenerable) and the
#  compile order is automatic, which is what lets create_bd_cell -type module
#  find accel_axi and infer its AXI interfaces from the port names.
create_project -force accel_bd_proj "$out/proj" -part $part
set_property board_part $board  [current_project]
set_property target_language Verilog [current_project]

# ---- the RTL, same globs as synth.tcl and impl.tcl --------------------------
#  A directory missing here does not fail - it produces a clean-looking report
#  of the WRONG design, with the missing module inferred as a black box.
set srcs [concat [glob -nocomplain "hardware/rtl/kernels/*.v"] \
                 [glob -nocomplain "hardware/rtl/control/*.v"] \
                 [glob -nocomplain "hardware/rtl/axi/*.v"] \
                 [glob -nocomplain "hardware/rtl/top/*.v"]]
foreach f $srcs { add_files -norecurse -fileset sources_1 [list $f] }
update_compile_order -fileset sources_1
puts "== read [llength $srcs] Verilog files"

puts "== part     : $part"
puts "== board    : $board"
puts "== top      : $top"
puts "== PL clock : $plmhz MHz"
puts "== CSR at   : $csr_base ($csr_size)"
puts "== out      : $out"

# ============================================================================
#  the block design
# ============================================================================
create_bd_design "accel_bd"

# ---- the PS, with the board preset -----------------------------------------
#  The preset is why having the ZCU104 board files matters: it carries the DDR4
#  configuration, the MIO assignment and the clock sources. Configuring those by
#  hand is how a board design ends up subtly wrong in a way that only shows up
#  as a DDR training failure on real hardware.
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps

#  Then only what this design needs, on top of the preset.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0      {1}       \
    CONFIG.PSU__USE__M_AXI_GP1      {0}       \
    CONFIG.PSU__USE__M_AXI_GP2      {0}       \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32}      \
    CONFIG.PSU__USE__S_AXI_GP2      {1}       \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {128}     \
    CONFIG.PSU__USE__IRQ0           {1}       \
    CONFIG.PSU__FPGA_PL0_ENABLE     {1}       \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $plmhz \
] $ps

# ---- the accelerator -------------------------------------------------------
#  A module reference rather than a packaged IP: the RTL is the deliverable and
#  packaging it would add a version number to keep in step with the source for
#  no benefit while there is exactly one consumer.
set acc [create_bd_cell -type module -reference $top u_accel]

# ---- reset -----------------------------------------------------------------
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl]

# ---- AXI-Lite: PS -> SmartConnect -> the CSR -------------------------------
set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_csr]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc

# ---- clock and reset nets --------------------------------------------------
set plclk [get_bd_pins zynq_ps/pl_clk0]

connect_bd_net $plclk [get_bd_pins rst_pl/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins rst_pl/ext_reset_in]

connect_bd_net $plclk [get_bd_pins zynq_ps/maxihpm0_fpd_aclk]
connect_bd_net $plclk [get_bd_pins zynq_ps/saxihp0_fpd_aclk]
connect_bd_net $plclk [get_bd_pins sc_csr/aclk]
connect_bd_net $plclk [get_bd_pins u_accel/clock]

connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins sc_csr/aresetn]
connect_bd_net [get_bd_pins rst_pl/peripheral_aresetn] [get_bd_pins u_accel/rst_n]

# ---- the two AXI interfaces ------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_FPD] \
                    [get_bd_intf_pins sc_csr/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_csr/M00_AXI] \
                    [get_bd_intf_pins u_accel/s_axi]
connect_bd_intf_net [get_bd_intf_pins u_accel/m_axi] \
                    [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

# ---- the interrupt ---------------------------------------------------------
connect_bd_net [get_bd_pins u_accel/irq] [get_bd_pins zynq_ps/pl_ps_irq0]

# ---- the address map -------------------------------------------------------
#  Explicit rather than leaving assign_bd_address's automatic placement: the
#  PS-side driver has to be built against these numbers, so they belong in the
#  script a reader can diff rather than wherever the tool happened to put them.
assign_bd_address

#  Matched on the CELL, not on the interface name. The auto-generated segment
#  is called SEG_u_accel_reg0 or similar - a filter on *s_axi* found nothing,
#  silently, and a silently unplaced CSR is a driver that writes into the void.
set csr_seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ps/Data] \
                 -filter {NAME =~ *u_accel*}]
if {[llength $csr_seg] == 1} {
    set_property offset $csr_base $csr_seg
    set_property range  $csr_size $csr_seg
    puts "== CSR segment [get_property NAME $csr_seg] placed at $csr_base, range $csr_size"
} else {
    puts "== ERROR: expected 1 CSR address segment, found [llength $csr_seg]:"
    foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ps/Data]] {
        puts "==   [get_property NAME $s]"
    }
    error "the CSR was not placed; the PS driver would have no address to use"
}

validate_bd_design
save_bd_design

#  Written by hand rather than with report_bd_address_map, which does not
#  exist in 2022.2. This is the file the PS application is written against, so
#  it is worth producing deliberately rather than not at all.
set fh [open "$out/address_map.rpt" w]
puts $fh "Address map - accel_bd at $plmhz MHz"
puts $fh ""
puts $fh [format "%-34s %-14s %-10s %s" "segment" "offset" "range" "slave"]
foreach sp [get_bd_addr_spaces] {
    foreach sg [get_bd_addr_segs -of_objects $sp] {
        puts $fh [format "%-34s %-14s %-10s %s" \
            [get_property NAME $sg] [get_property OFFSET $sg] \
            [get_property RANGE $sg] $sp]
    }
}
close $fh
puts "== address map written to $out/address_map.rpt"

#  BD_ONLY exists because the block design is the part that gets iterated: a
#  wrong CONFIG name or a mis-named interface pin is a two-minute fix and a
#  fifteen-minute wait if you have to go through synthesis to see it. Same
#  reasoning as impl.tcl's SYNTH_ONLY, one stage earlier.
if {[info exists ::env(BD_ONLY)] && $::env(BD_ONLY) == 1} {
    puts ""
    puts "================== BLOCK DESIGN ONLY ($tag) =================="
    puts "  validated and saved; address map in $out/address_map.rpt"
    puts "============================================================="
    return
}

# ---- wrap it and build -----------------------------------------------------
set bd_file [get_files accel_bd.bd]
make_wrapper -files $bd_file -top -import

puts ""
puts "== block design built; starting synthesis"
puts ""

set_property top accel_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
synth_design -top accel_bd_wrapper -part $part
report_utilization                       -file "$out/synth_utilization.rpt"
report_timing_summary -max_paths 10      -file "$out/synth_timing_summary.rpt"
write_checkpoint -force                        "$out/post_synth.dcp"

if {[info exists ::env(SYNTH_ONLY)] && $::env(SYNTH_ONLY) == 1} {
    puts ""
    puts "================== SYNTHESIS ONLY ($tag) =================="
    set p [lindex [get_timing_paths -max_paths 1 -nworst 1 -setup] 0]
    puts "  WNS (setup)      : [get_property SLACK $p]"
    puts "  reports in $out/  (post-route ones NOT produced)"
    puts "=========================================================="
    return
}

opt_design
place_design
phys_opt_design
route_design

report_utilization               -file "$out/utilization.rpt"
report_utilization -hierarchical -file "$out/utilization_hier.rpt"
report_timing_summary -max_paths 10 -file "$out/timing_summary.rpt"
report_timing -max_paths 25 -sort_by group -file "$out/timing_paths.rpt"
report_methodology -file "$out/methodology.rpt"
write_checkpoint -force "$out/post_route.dcp"

write_bitstream -force "$out/accel_bd_wrapper.bit"

#  The hardware handoff. This is what a PS application is compiled against - it
#  carries the address map, the clock configuration and the PS settings - so it
#  is an output of this flow rather than something to be exported by hand later.
write_hw_platform -fixed -include_bit -force "$out/accel_bd_wrapper.xsa"

# ============================================================================
#  the summary, on stdout so the shell does not have to parse reports
# ============================================================================
puts ""
puts "================== BOARD POST-ROUTE SUMMARY ($tag) =================="

#  The period is read back from the CLOCK, never from a literal - synth.tcl's
#  header records what a hardcoded 4 cost once ("Fmax 3401 MHz, meets 250 MHz").
set clk [get_clocks -of_objects [get_ports -quiet -scoped_to_current_instance *]]
if {[llength $clk] == 0} { set clk [lindex [get_clocks] 0] }
set paths [get_timing_paths -max_paths 1 -nworst 1 -setup]
if {[llength $paths] > 0} {
    set p   [lindex $paths 0]
    set wns [get_property SLACK $p]
    set grp [get_property GROUP $p]
    set per [get_property PERIOD [get_clocks $grp]]
    puts [format "  PL clock         : %s MHz requested" $plmhz]
    puts [format "  clock group      : %s at %.3f ns" $grp $per]
    puts [format "  WNS (setup)      : %s ns" $wns]
    puts [format "  => Fmax          : %.1f MHz   - %s" \
              [expr {1000.0 / ($per - $wns)}] \
              [expr {$wns < 0 ? "DOES NOT MEET" : "meets the constraint"}]]
    puts "  worst path from  : [get_property STARTPOINT_PIN $p]"
    puts "               to  : [get_property ENDPOINT_PIN   $p]"
    puts "  logic levels     : [get_property LOGIC_LEVELS $p]"
}

set dpir [llength [get_methodology_violations -filter {CHECK_NAME == DPIR-2}]]
puts [format "  DPIR-2           : %d" $dpir]
puts ""
puts "  bitstream : $out/accel_bd_wrapper.bit"
puts "  handoff   : $out/accel_bd_wrapper.xsa   (what the PS app builds against)"
puts "  reports   : $out/"
puts "===================================================================="
