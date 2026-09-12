`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  param_buffer.v  -  per-output-channel requantize parameters, Tm at a time
//
//  Build plan #4. rq_bank needs bias, m0 and shift for all Tm lanes at once,
//  and those are PER OUTPUT CHANNEL: lane m of tile `oct` is channel
//  oct*Tm + m. So the store is banked exactly like wgt_buffer - Tm banks read
//  at one shared address - and `oct` IS that address.
//
//  Structurally this is the same banked-memory pattern as wgt_buffer, but it
//  is a separate module rather than a reuse because its job is the TYPED
//  unpacking: it stores one packed word per bank and hands out three properly
//  sized buses. Packing bias/m0/shift into something called a weight word
//  would save 40 lines of memory and cost the reader the meaning.
//
//  Sizing is trivial next to everything else: the deepest layer needs
//  ceil(1280/32) = 40 entries, so DEPTH 64 covers the network with
//  32 banks x 64 x 70 bit = 143 Kbit. That is small enough to be LUTRAM.
//
//  Read latency is ONE cycle, matching wgt_buffer and act_buffer, so the same
//  alignment rule applies: whoever reads must delay the data it travels with.
//  pw_out does that by registering the accumulators for one cycle.
//
//  Loading: one bank per cycle, like wgt_buffer, because the PS writes these
//  over the same narrow path as the weights. Unwritten entries read as zero.
//
//  Verified through pw_out_tb rather than a testbench of its own: its only
//  client is pw_out, and pw_out's parameter load path drives every write port
//  and its results depend on every read field, so a separate testbench would
//  duplicate that coverage without adding any.
//============================================================================
module param_buffer #(
    parameter TM      = 32,    // banks = lanes
    parameter BIAS_W  = 32,    // int32 bias
    parameter M0_W    = 32,    // int32 fixed-point multiplier
    parameter SHIFT_W = 6,     // right-shift amount
    parameter DEPTH   = 64,    // oc_tiles (max needed: 40)
    parameter ADDR_W  = 6,     // clog2(DEPTH)
    parameter BANK_W  = 5      // clog2(TM)
)(
    input  wire                     clock,

    // ---- load port: one channel per cycle ------------------------------
    input  wire                     wr_en,
    input  wire [BANK_W-1:0]        wr_bank,
    input  wire [ADDR_W-1:0]        wr_addr,
    input  wire signed [BIAS_W-1:0] wr_bias,
    input  wire signed [M0_W-1:0]   wr_m0,
    input  wire [SHIFT_W-1:0]       wr_shift,

    // ---- read port: all Tm channels of one oc_tile ---------------------
    input  wire                     rd_en,
    input  wire [ADDR_W-1:0]        rd_addr,     // = oct
    output wire [TM*BIAS_W-1:0]     rd_bias,
    output wire [TM*M0_W-1:0]       rd_m0,
    output wire [TM*SHIFT_W-1:0]    rd_shift
);

    localparam PACK_W = BIAS_W + M0_W + SHIFT_W;    // 70

    genvar b;
    generate
        for (b = 0; b < TM; b = b + 1) begin : bank
            reg [PACK_W-1:0] mem [0:DEPTH-1];
            reg [PACK_W-1:0] dout;

            // deterministic power-up; also makes an unwritten tile read as
            // bias=0, m0=0, shift=0, which produces 0 rather than X
            integer i;
            initial begin
                for (i = 0; i < DEPTH; i = i + 1) mem[i] = {PACK_W{1'b0}};
                dout = {PACK_W{1'b0}};
            end

            always @(posedge clock) begin
                if (wr_en && (wr_bank == b[BANK_W-1:0]))
                    mem[wr_addr] <= {wr_shift, wr_m0, wr_bias};
                if (rd_en)
                    dout <= mem[rd_addr];
            end

            // typed unpack - the reason this module exists
            assign rd_bias [b*BIAS_W  +: BIAS_W ] = dout[BIAS_W-1:0];
            assign rd_m0   [b*M0_W    +: M0_W   ] = dout[BIAS_W+M0_W-1 : BIAS_W];
            assign rd_shift[b*SHIFT_W +: SHIFT_W] = dout[PACK_W-1 : BIAS_W+M0_W];
        end
    endgenerate

endmodule

`default_nettype wire
