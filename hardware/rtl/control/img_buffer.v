`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  img_buffer.v  -  the input image, in its own region
//
//  Build plan #6. 224x224x3 int8, one pixel per entry, filled by the PS and
//  read only by the stem.
//
//  ---- why it is not in the activation pool -----------------------------
//
//  Pool entries hold POOL_TM=32 channels. The image has 3, so storing it there
//  would waste 91% of the space: 1.53 MB of pool to hold 147 KB of data, which
//  is more than the largest feature map in the network. gen_program.py
//  therefore leaves the image out of the allocator entirely and the stem reads
//  from here instead. 224*224 entries of 3 bytes = 147 KB.
//
//  Read latency is ONE cycle, matching act_buffer, wgt_buffer and
//  param_buffer, so the stem's pipeline alignment is the same as everyone
//  else's.
//
//  Address is simply y*img_w + x. The stem walks raster order, so it keeps a
//  counter rather than multiplying.
//
//  No testbench of its own: it is a plain memory with the same shape as
//  wgt_buffer's banks, and stem_datapath_tb drives every address of it with
//  real image data and checks the result against the golden.
//============================================================================
module img_buffer #(
    parameter DATA_W = 8,
    parameter CIN    = 3,       // channels per pixel
    parameter DEPTH  = 50176,   // 224*224
    parameter ADDR_W = 16
)(
    input  wire                    clock,

    // ---- fill port (the PS / DMA) --------------------------------------
    input  wire                    wr_en,
    input  wire [ADDR_W-1:0]       wr_addr,
    input  wire [CIN*DATA_W-1:0]   wr_data,

    // ---- read port (the stem) ------------------------------------------
    input  wire                    rd_en,
    input  wire [ADDR_W-1:0]       rd_addr,
    output reg  [CIN*DATA_W-1:0]   rd_data
);

    localparam PIX_BITS = CIN*DATA_W;      // 24

    reg [PIX_BITS-1:0] mem [0:DEPTH-1];

    // deterministic power-up, as in the other on-chip memories
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = {PIX_BITS{1'b0}};
        rd_data = {PIX_BITS{1'b0}};
    end

    always @(posedge clock) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        if (rd_en) rd_data      <= mem[rd_addr];
    end

endmodule

`default_nettype wire
