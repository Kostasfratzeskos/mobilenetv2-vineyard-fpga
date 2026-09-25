# hardware/ - Phases 2-3: the accelerator (Verilog-2001, tested in Vivado)

- `rtl/axi/`     - `wgt_dma.v`, the read-only AXI4 master that answers `top_seq`'s weight /
                   parameter load handshake, and `axi_lite_csr.v`, the control and status
                   registers a PS drives it with (register map in DD-031).
- `rtl/kernels/` - 1x1 conv, 3x3 depthwise, requantize+ReLU6, residual-add, bias
- `rtl/control/` - controller / sequencer that walks the layers (paper Table 2), plus the
                   feeders, the buffers and `accel_top`
- `rtl/top/`     - three layered tops, each separately measurable and each with its own
                   `.xdc`: `accel_sys.v` (`accel_top` + `wgt_dma`, 499 port bits) and
                   `accel_axi.v` (+ `axi_lite_csr`, 354 bits). `accel_axi` is one port group -
                   the image load - away from being the board top.
- `tb/`          - testbenches; verify each block bit-exact vs the golden vectors. Three
                   integration runs of the SAME network, each adding one real interface:
                   `accel_tb` (a task answers the load handshake - the fast path),
                   `accel_dma_tb` (+ the real DMA over AXI4) and `accel_axi_tb` (+ the real
                   CSR over AXI-Lite, so nothing but two AXI interfaces). All three share
                   `accel_check.svh`, so the pass criterion cannot drift between them.
- `constraints/` - .xdc timing / pin constraints, one per synthesis top

You reuse a small set of parameterized engines across all bottleneck blocks - not one module per layer.
