# hardware/ - Phases 2-3: the accelerator (Verilog-2001, tested in Vivado)

- `rtl/axi/`     - `wgt_dma.v`, the read-only AXI4 master that answers `top_seq`'s weight /
                   parameter load handshake. AXI-Lite control registers are not written yet.
- `rtl/kernels/` - 1x1 conv, 3x3 depthwise, requantize+ReLU6, residual-add, bias
- `rtl/control/` - controller / sequencer that walks the layers (paper Table 2), plus the
                   feeders, the buffers and `accel_top`
- `rtl/top/`     - `accel_sys.v`, `accel_top` + `wgt_dma` presenting the AXI master. Not the
                   board top: `pg_*` and `im_wr_*` are still ports, which its header explains.
- `tb/`          - testbenches; verify each block bit-exact vs the golden vectors.
                   `accel_tb` is the fast path (a task answers the load handshake);
                   `accel_dma_tb` is the same network with the real DMA over AXI4. They share
                   `accel_check.svh` so the pass criterion cannot drift between them.
- `constraints/` - .xdc timing / pin constraints, one per synthesis top

You reuse a small set of parameterized engines across all bottleneck blocks - not one module per layer.
