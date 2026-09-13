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

create_clock -period 4.000 -name clock [get_ports clock]

# The load ports (program, image, weights, parameters) are fed by a DMA that
# does not exist yet, so there is no real launch/capture clock on the other
# side. Giving them a generous budget keeps their unconstrained paths out of
# the critical-path report, where they would hide the datapath's own timing -
# which is the thing being measured. Tighten these once the DMA is real.
set_input_delay  -clock clock 0.500 [get_ports {pg_* im_wr_* pw_wl_* dw_wl_* st_wl_* pl_* lg_pl_* ld_done start n_instr rst_n}]
set_output_delay -clock clock 0.500 [get_ports {ld_req ld_off ld_bytes ld_pchan logits* argmax* pc running done tag_error}]

# The activation pool is 50,176 x 256 bit = 12.85 Mbit, which is larger than
# every BRAM on the XCZU7EV put together (11.0 Mbit). It has to land in URAM
# (27.0 Mbit). If synthesis maps it to BRAM instead the design will not fit,
# so this is worth checking in the utilization report rather than assuming.
