# cmodel/ - bit-exact C reference model

A C reimplementation of the quantized MobileNetV2 that uses the **exact same integer
arithmetic** as the planned hardware (int8 weights/activations, int32 accumulators,
multiply-by-`m0` + right-`shift` requantization). It is the bridge between the Python
source of truth (`../train/`) and the Verilog RTL (`../../hardware/`):

- It reproduces the Python model's per-layer integer outputs, confirming the
  fixed-point arithmetic is portable and unambiguous (no hidden float behaviour).
- Its requantization is the spec the RTL kernels are checked against, so a hardware
  block can be debugged against readable C before chasing waveforms.

## Layout
```
cmodel/
├── Makefile
├── src/                MobileNetV2 engine
│   ├── main.c          entry point
│   ├── mobilenet.{c,h} layer execution
│   └── requantize.{c,h} int32 -> int8 requantize (the arithmetic the RTL must match)
└── test/               unit tests (each .c is its own program)
    └── test_requantize.c
```

## Build & test
```sh
make        # build src/ -> build/mobilenet(.exe)
make test   # build + run every test in test/, log to build/test.log
make clean
```
`build/` is generated and gitignored.
