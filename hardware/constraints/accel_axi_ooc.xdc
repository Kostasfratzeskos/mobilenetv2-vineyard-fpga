#=============================================================================
#  accel_axi_ooc.xdc  -  out-of-context constraints for the accelerator with
#                        BOTH the weight DMA and the control registers
#
#  Third of three, and the last one that will need to be out of context for a
#  reason other than convenience. The progression, and what each file stopped
#  having to guess about:
#
#    accel_top_ooc.xdc   672 load-port bits with a 0.5 ns placeholder, because
#                        nothing drove them.
#    accel_sys_ooc.xdc   those 672 became internal register-to-register paths.
#                        pg_*, im_wr_* and the config pins kept placeholders.
#    accel_axi_ooc.xdc   pg_* and the config pins are gone too. What is left is
#                        two real AXI interfaces, an interrupt, and the image.
#
#  Measured port bits: 846 -> 499 -> 354, of which 196 are the AXI4 master, 114
#  the AXI-Lite slave, 41 the image load, and 3 are clock, reset and irq.
#
#  ---- so ONE placeholder remains, and it is 41 bits ----------------------
#
#  im_wr_*. The image load path is the next item of work (see accel_axi.v's
#  header for why it was not folded into the CSR), and until it exists there is
#  still no launch clock on the other side of those pins. Everything else in
#  this file is either a genuine interface budget or an exception with a stated
#  reason. That is the honest state: one placeholder, named, with its size.
#
#  ---- why the AXI-Lite budget is the same as the AXI4 one -----------------
#
#  1.000 ns on both, and for the same reason: out of context there is no
#  interconnect on the far end, but on a board both WILL be timed paths against
#  the PS in this same clock domain. On the ZU+ the M_AXI_HPM and S_AXI_HP aclk
#  inputs are both driven by the PL clock, so there is no CDC in either
#  direction - the same statement wgt_dma.v's header makes, applied to the
#  control path. A quarter of the 4.000 ns target is a deliberately pessimistic
#  stand-in for an AXI SmartConnect's own register stage.
#
#  AXI-Lite is also nowhere near critical by construction: every register is a
#  flop with a decode in front of it, and the read data mux is 13 entries wide.
#  If it ever appears in a timing report, something is wrong with the decode,
#  not with the budget.
#
#  ---- what has NOT changed, deliberately ---------------------------------
#
#  The clock period, the reset treatment and the URAM expectation are identical
#  to accel_top_ooc.xdc and accel_sys_ooc.xdc. The whole value of having three
#  tops is that their numbers are comparable, and changing a constraint at the
#  same time as adding a layer would throw that away.
#=============================================================================

# Same period as the other two, so all three numbers are comparable. Override it
# from the command line the way impl.tcl does rather than editing it here.
create_clock -period 25.000 -name clock [get_ports clock]

# ---- the AXI4 read master: weights and parameters from PS-DDR ---------------
set_input_delay  -clock clock 1.000 \
    [get_ports {m_axi_arready m_axi_rid* m_axi_rdata* m_axi_rresp* m_axi_rlast m_axi_rvalid}]
set_output_delay -clock clock 1.000 \
    [get_ports {m_axi_ar* m_axi_rready}]

# ---- the AXI4-Lite slave: control, status and the program aperture ----------
set_input_delay  -clock clock 1.000 \
    [get_ports {s_axi_awaddr* s_axi_awprot* s_axi_awvalid s_axi_wdata* s_axi_wstrb* \
                s_axi_wvalid s_axi_bready s_axi_araddr* s_axi_arprot* s_axi_arvalid \
                s_axi_rready}]
set_output_delay -clock clock 1.000 \
    [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid s_axi_arready \
                s_axi_rdata* s_axi_rresp* s_axi_rvalid}]

# ---- the one remaining placeholder: 41 bits of image load -------------------
set_input_delay  -clock clock 0.500 [get_ports {im_wr_*}]

# ---- the interrupt ---------------------------------------------------------
# Goes to the PS's interrupt controller, which is not a per-cycle path. A budget
# rather than a false path because it IS a real destination, unlike the old load
# ports, and 0.5 ns of a 25 ns period costs nothing to promise.
set_output_delay -clock clock 0.500 [get_ports irq]

# ---- the reset is asynchronous, and says so (T-5 / DD-020) -----------------
#
# Unchanged from the other two files, and for the same reason: rst_n reaches
# exactly two flip-flop clear pins, in accel_top's ASYNC_REG synchroniser, and
# that synchroniser is what makes the path safe rather than any constraint.
# wgt_dma and axi_lite_csr both take the raw rst_n and reset synchronously off
# it, which is why this is still one false path and not three domains.
set_false_path -from [get_ports rst_n]

# The activation pool is 50,176 x 256 bit = 12.85 Mbit, larger than every BRAM
# on the XCZU7EV put together (11.0 Mbit), so it has to land in URAM (27.0
# Mbit). Worth checking in the utilization report rather than assuming.
