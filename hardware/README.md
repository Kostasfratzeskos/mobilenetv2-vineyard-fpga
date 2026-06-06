# hardware/ - Phases 2-3: the accelerator (Verilog-2001, tested in Vivado)

- `rtl/axi/`     - AXI-Lite control registers, AXI4 / AXI-Stream + DMA data path
- `rtl/kernels/` - 1x1 conv, 3x3 depthwise, requantize+ReLU6, residual-add, bias
- `rtl/control/` - controller / sequencer that walks the layers (paper Table 2)
- `rtl/top/`     - top-level accelerator
- `tb/`          - testbenches; verify each block bit-exact vs the golden vectors
- `constraints/` - .xdc timing / pin constraints

You reuse a small set of parameterized engines across all bottleneck blocks - not one module per layer.
