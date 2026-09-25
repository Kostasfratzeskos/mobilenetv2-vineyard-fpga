#=============================================================================
#  accel_top_ooc.xdc  -  out-of-context constraints for synthesising the
#                        accelerator on its own
#
#  Out of context because accel_top is not the chip: the PS, the DMA and the
#  AXI plumbing are not written yet. What this measures is the accelerator's
#  own logic - whether the datapath closes at the target clock and what it
#  costs - without waiting for a system that does not exist.
#
#  250 MHz (4.000 ns) is the target from docs/controller_design.md section 3.
#  Every resource and frequency figure quoted in the docs so far has been an
#  ESTIMATE; this file is the first thing that can turn one into a measurement.
#=============================================================================

# I changed the frequency of the clock to Fmax = 40MHz to chek if there is still time violations
create_clock -period 25.000 -name clock [get_ports clock]       

# The load ports (program, image, weights, parameters) are fed by a DMA that
# does not exist yet, so there is no real launch/capture clock on the other
# side. Giving them a generous budget keeps their unconstrained paths out of
# the critical-path report, where they would hide the datapath's own timing -
# which is the thing being measured. Tighten these once the DMA is real.
#
# ---- THE DMA IS REAL NOW, and the answer was not to tighten them -----------
#
# hardware/rtl/axi/wgt_dma.v exists, and hardware/rtl/top/accel_sys.v wires it
# to accel_top. For that top, the weight and parameter load ports are not given
# a smaller number - they STOP BEING PORTS:
#
#     pw_wl_*  dw_wl_*  st_wl_*  pl_*  lg_pl_*  ld_done   (672 bits, 29 ports)
#
# become internal nets, driven by wgt_dma's output registers and captured by
# wgt_buffer / param_buffer, timed as ordinary register-to-register paths with
# no input delay and no exception. That is strictly stronger than the 0.5 ns
# below, because a 0.5 ns input delay is an ASSUMPTION about a launch clock
# that did not exist, and a register-to-register path is a measurement.
# See hardware/constraints/accel_sys_ooc.xdc, which is otherwise identical to
# this file - same period, same reset treatment, same URAM expectation - so the
# two tops stay directly comparable.
#
# What it did to the timing number: NOTHING, and that is the result. Both tops
# synthesised with scripts/synth.tcl at this 25.000 ns constraint:
#
#     accel_top   WNS 20.716 ns   233.4 MHz   35,188 LUT   18,399 FF   944 DSP
#     accel_sys   WNS 20.716 ns   233.4 MHz   36,997 LUT   19,786 FF   944 DSP
#
# WNS is identical to the picosecond and the worst path is the same one it has
# been since Phase 3 - act_buffer's URAM read into the depthwise array's DSP
# (DD-023) - with only the hierarchy prefix changed. So the DMA is nowhere near
# the critical path, which is what registering all of its outputs was for. It
# costs 1,724 LUT and 1,395 FF of the delta (report_utilization -hierarchical
# on u_dma), no DSP and no BRAM.
#
# THIS file is still the right one for measuring accel_top alone, which is every
# number quoted in the docs up to and including Phase 6. It is not stale.
#
# Of accel_sys's 499 port bits, pg_* and im_wr_* are still 83 of them and still
# have no launch clock, so they keep the 0.5 ns there too. They are the only
# placeholder left.
set_input_delay  -clock clock 0.500 [get_ports {pg_* im_wr_* pw_wl_* dw_wl_* st_wl_* pl_* lg_pl_* ld_done start n_instr rst_n}]
set_output_delay -clock clock 0.500 [get_ports {ld_req ld_off ld_bytes ld_pchan logits* argmax* pc running done tag_error fault}]

# ---- the reset is asynchronous, and now says so (T-5) -----------------------
#
# rst_n used to drive `posedge clock or negedge rst_n` in every module: 3,998
# FDCE plus 1 FDPE, measured post-route. The input delay above put it in the
# timing graph as an ordinary synchronous input, so Vivado checked recovery
# against it and reported +24.027 ns of slack - a clean number for a check that
# was modelling a reset the design did not have. Async assertion was always
# fine; async DEASSERTION was the problem, and no constraint can fix that.
#
# accel_top now has a two-flop ASYNC_REG synchroniser and every submodule sees
# its output, so rst_n reaches exactly two flip-flop clear pins. That path is
# genuinely untimed - the synchroniser is what makes it safe - so it is declared
# false here rather than left to be checked against a delay that means nothing.
# The line above still lists rst_n so check_timing does not report it as an
# unconstrained input; this exception overrides it for the paths that exist.
set_false_path -from [get_ports rst_n]

# The activation pool is 50,176 x 256 bit = 12.85 Mbit, which is larger than
# every BRAM on the XCZU7EV put together (11.0 Mbit). It has to land in URAM
# (27.0 Mbit). If synthesis maps it to BRAM instead the design will not fit,
# so this is worth checking in the utilization report rather than assuming.
