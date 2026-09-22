`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  out_stage.v  -  the ONE requantize stage, shared by every feeder
//
//  Build plan #6. Only one op executes at a time - the sequencer is sequential
//  - so there is no reason for each feeder to carry its own requantize bank and
//  parameter memory. This is that pair, factored out once:
//
//      acc[TM] + (bias, m0, shift)[TM]  ->  bias_add -> requantize  ->  q[TM]
//
//  Before this existed, pw_out held a 32-lane bank (64 DSP) and dw_feeder a
//  16-lane one (32 DSP), and the stem, residual and pooling feeders were each
//  about to add another. Sharing takes the DSP budget from roughly 634 (37% of
//  the XCZU7EV) to 442 (26%), and leaves one block to verify instead of five.
//
//  ---- what stayed OUT of here, and why --------------------------------
//
//  No address generation. Each feeder walks its own tensors in its own order -
//  the pointwise path is pixel-major with a stride of one entry, the depthwise
//  is group-major with a stride of n_ent - so the write address belongs to the
//  feeder that knows the order. This block is pure datapath: accumulators and a
//  parameter index in, int8 out.
//
//  ---- how a TC=16 feeder uses a TM=32 bank ---------------------------
//
//  The depthwise produces 16 channels per result, for channels 16g..16g+15 of
//  group g. Rather than rotate them down to lanes 0-15, the feeder drives them
//  into lanes (g&1)*16 .. +15 and reads parameters at address g>>1. Then:
//    - the parameter banks already hold exactly those channels in exactly those
//      positions, because a parameter entry covers 32 consecutive channels; and
//    - `q` comes back with the results in the same half of the word that
//      act_buffer's half write expects for wr_sel = g&1.
//  So no rotation, no replication, no muxing - the 32-channel entry granularity
//  lines the three sides up by itself. The unused 16 lanes compute on whatever
//  is on the bus and their output is discarded by the half write.
//
//  Timing, identical to what pw_out used to do inline:
//    cycle X    acc_valid: parameter read issued, accumulators registered
//    cycle X+1  parameters and acc meet at the requantize bank
//    cycle X+2  q_valid, and `q` is the word to store
//
//  No testbench of its own: param_buffer and rq_bank are each verified, and the
//  wiring between them plus the capture register is exercised bit-exact by both
//  pw_datapath_tb and dw_datapath_tb. A separate one would only re-run those.
//============================================================================
module out_stage #(
    parameter TM      = 32,
    parameter ACC_W   = 26,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter DATA_W  = 8,
    parameter PDEPTH  = 64,
    parameter PA_W    = 6,
    parameter BANK_W  = 5
)(
    input  wire                      clock,
    input  wire                      rst_n,
    input  wire                      flush,       // drop anything in flight

    // ---- per-op --------------------------------------------------------
    input  wire                      act,         // 0 = NONE, 1 = RELU6
    input  wire signed [7:0]         relu6_qmax,

    // ---- parameter load port -------------------------------------------
    input  wire                      pl_en,
    input  wire [BANK_W-1:0]         pl_bank,
    input  wire [PA_W-1:0]           pl_addr,
    input  wire signed [BIAS_W-1:0]  pl_bias,
    input  wire signed [M0_W-1:0]    pl_m0,
    input  wire [SHIFT_W-1:0]        pl_shift,

    // ---- from whichever feeder is active -------------------------------
    input  wire [TM*ACC_W-1:0]       acc,
    input  wire                      acc_valid,
    input  wire [PA_W-1:0]           param_addr,  // oc_tile, or group>>1

    // ---- result --------------------------------------------------------
    output wire [TM*DATA_W-1:0]      q,
    output wire                      q_valid
);

    // ================= stage A : capture + parameter fetch ==============
    // The accumulators have to be registered here: the arrays reuse them the
    // moment the next result starts, and the parameter memory answers a cycle
    // late. One pipeline register, not a drain buffer - see DD-015.
    reg [TM*ACC_W-1:0] acc_q;
    reg                vA;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)      vA <= 1'b0;
        else if (flush)  vA <= 1'b0;
        else begin
            vA <= acc_valid;
            if (acc_valid) acc_q <= acc;
        end
    end

    wire [TM*BIAS_W-1:0]  p_bias;
    wire [TM*M0_W-1:0]    p_m0;
    wire [TM*SHIFT_W-1:0] p_shift;

    param_buffer #(
        .TM(TM), .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
        .DEPTH(PDEPTH), .ADDR_W(PA_W), .BANK_W(BANK_W)
    ) u_param (
        .clock   (clock),
        .wr_en   (pl_en), .wr_bank(pl_bank), .wr_addr(pl_addr),
        .wr_bias (pl_bias), .wr_m0(pl_m0), .wr_shift(pl_shift),
        .rd_en   (acc_valid),
        .rd_addr (param_addr),
        .rd_bias (p_bias), .rd_m0(p_m0), .rd_shift(p_shift)
    );

    // ================= stage B : requantize all TM lanes ================
    rq_bank #(
        .TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .DATA_W(DATA_W)
    ) u_rq (
        .clock      (clock),
        .rst_n      (rst_n),
        .en         (vA),
        .act        (act),
        .relu6_qmax (relu6_qmax),
        .acc        (acc_q),
        .bias       (p_bias),
        .m0         (p_m0),
        .shift      (p_shift),
        .q          (q),
        .q_valid    (q_valid)
    );

endmodule

`default_nettype wire
