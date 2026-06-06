# software/ - Phase 1: reference model (the source of truth)

Python pipeline that produces the golden vectors every hardware block is checked against.

- `model/`    - load / define MobileNetV2
- `train/`    - fine-tune on the grape-disease dataset
- `quantize/` - int8 quantization + the bit-exact fixed-point model (must match the hardware arithmetic)
- `export/`   - dump quantized weights (hex/coe/bin) and per-layer scales for the RTL
- `golden/`   - generate and store per-layer golden activation vectors

Install deps: `pip install -r requirements.txt`
