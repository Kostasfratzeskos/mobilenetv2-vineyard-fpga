#=============================================================================
#  accel_sys_ooc.xdc  -  out-of-context constraints for the accelerator WITH
#                        the weight DMA
#
#  accel_top_ooc.xdc says, about the load ports:
#
#      # The load ports (program, image, weights, parameters) are fed by a DMA
#      # that does not exist yet, so there is no real launch/capture clock on
#      # the other side. Giving them a generous budget keeps their
#      # unconstrained paths out of the critical-path report, where they would
#      # hide the datapath's own timing - which is the thing being measured.
#      # Tighten these once the DMA is real.
#
#  This file is that. The DMA is real, so the tightening is not a matter of
#  choosing a smaller number - it is that those ports STOPPED BEING PORTS:
#
#      pw_wl_*  dw_wl_*  st_wl_*  pl_*  lg_pl_*  ld_done   (672 bits, 29 ports)
#
#  are all internal nets inside accel_sys now, driven by wgt_dma's output
#  registers and captured by wgt_buffer / param_buffer. They are timed as
#  ordinary register-to-register paths with no exception and no input delay,
#  which is strictly stronger than the 0.5 ns budget they had: an input delay is
#  an ASSUMPTION about a launch clock, and a register-to-register path is a
#  measurement. wgt_dma registers every one of its outputs specifically so this
#  is true - see the "why every output is REGISTERED" section of its header.
#
#  ---- what is still a port, and still needs a budget --------------------
#
#  Three groups, and all three are honest about what they are:
#
#    1. the AXI4 read channel. This is the one real system interface, and out of
#       context there is no interconnect on the other end. It gets a budget
#       rather than a false path, because unlike the old load ports it WILL be
#       a timed path on a board - against the PS's S_AXI_HP, in the same clock
#       domain (the HP port's aclk is this PL clock; there is no CDC). 1.0 ns is
#       a quarter of the 4.000 ns target, which is a deliberately pessimistic
#       stand-in for an AXI SmartConnect's own register stage.
#
#    2. pg_* and im_wr_*. The program load and the image load, which accel_sys's
#       header explains are still ports because they are the next items of work.
#       They keep accel_top_ooc.xdc's 0.5 ns for the same reason it gave it to
#       them: there is no launch clock on the other side yet. This is the one
#       remaining place in this file where a number is a placeholder, and it is
#       83 of 499 port bits.
#
#    3. the configuration and status pins: the four base addresses, start,
#       n_instr, and the answer. The bases are read once per run and latched on
#       `start`, and the status pins go to a CSR block or an LED. None of them
#       is on a per-cycle path.
#
#  ---- what has NOT changed ---------------------------------------------
#
#  The clock period, the reset treatment and the URAM expectation are the same
#  as accel_top_ooc.xdc's, deliberately: the point of measuring accel_sys is to
#  see what the DMA costs against a directly comparable accel_top number, and
#  changing the constraint at the same time would make the two incomparable.
#=============================================================================

# Same period as accel_top_ooc.xdc, so the two are comparable. Override it from
# the command line the way impl.tcl does rather than editing it here.
create_clock -period 25.000 -name clock [get_ports clock]

# ---- the AXI4 read channel: the one real system interface -------------------
set_input_delay  -clock clock 1.000 \
    [get_ports {m_axi_arready m_axi_rid* m_axi_rdata* m_axi_rresp* m_axi_rlast m_axi_rvalid}]
set_output_delay -clock clock 1.000 \
    [get_ports {m_axi_ar* m_axi_rready}]

# ---- still ports, still placeholders: the program and image load ------------
set_input_delay  -clock clock 0.500 [get_ports {pg_* im_wr_*}]

# ---- configuration and status ----------------------------------------------
set_input_delay  -clock clock 0.500 \
    [get_ports {start n_instr* wgt_base* pb_base* pm_base* ps_base* rst_n}]
set_output_delay -clock clock 0.500 \
    [get_ports {logits* argmax* pc* running done tag_error fault dma_error}]

# ---- the reset is asynchronous, and says so (T-5 / DD-020) ------------------
#
# Unchanged from accel_top_ooc.xdc, and for the same reason: rst_n reaches
# exactly two flip-flop clear pins, in accel_top's ASYNC_REG synchroniser, and
# that synchroniser is what makes the path safe rather than any constraint.
# Declared false here so it is not checked against an input delay that means
# nothing. The line above still lists rst_n so check_timing does not report it
# as unconstrained; this exception overrides it for the paths that exist.
#
# Note for accel_sys specifically: wgt_dma takes the RAW rst_n and resets
# synchronously off it, which is why this is still one false path and not two
# domains. See the comment on the u_dma instantiation.
set_false_path -from [get_ports rst_n]

# The activation pool is 50,176 x 256 bit = 12.85 Mbit, larger than every BRAM
# on the XCZU7EV put together (11.0 Mbit), so it has to land in URAM (27.0
# Mbit). Worth checking in the utilization report rather than assuming.
