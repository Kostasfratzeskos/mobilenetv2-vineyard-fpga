# firmware/ - Phase 4: PS application (Zynq ARM side)

Reads an image from the SD card, preprocesses and quantizes it to int8, writes it to DDR,
configures the PL accelerator over AXI-Lite, runs inference, reads the result, and reports the disease class.
