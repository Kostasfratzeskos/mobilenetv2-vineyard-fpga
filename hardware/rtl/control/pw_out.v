`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  pw_out.v  -  the output half: accumulators -> int8 -> activation buffer
//
//  Build plan #4. Takes what pw_feeder hands over (Tm finished accumulators
//  plus the (pix, oct) tag), looks up that tile's per-channel parameters,
//  requantizes all Tm lanes at once, and writes the resulting 256-bit word
//  into act_buffer. The mirror image of pw_feeder.
//
//  ---- the write address is a plain counter ----------------------------
//
//  The obvious address is base_out + pix*ceil(OC/Tm) + oct, which wants a
//  multiplier. It is not needed, and for a nicer reason than in pw_feeder:
//  the entries per pixel on the OUTPUT side are exactly ceil(OC/Tm) = n_oc,
//  which is also how many results each pixel produces. So the results arrive
//  one per consecutive address, forever:
//
//      pix 0 -> base+0, base+1, ... base+n_oc-1
//      pix 1 -> base+n_oc, ...
//
//  A counter that increments once per write IS the address. pw_feeder_tb
//  already proved the results come out in pixel-major, oc_tile-minor order,
//  which is the assumption this rests on.
//
//  ---- so what is the tag for? -----------------------------------------
//
//  Not for addressing. `oct` indexes the parameter buffer - that is its real
//  job - and the pair is also used as a SELF-CHECK: this module keeps its own
//  expected (pix, oct) and raises a sticky `tag_error` if the incoming tag
//  ever disagrees. If the two pipelines ever drift apart, the numbers would
//  still look plausible while landing in the wrong place, so a cheap
//  comparator here is worth more than its area.
//
//  ---- pipeline --------------------------------------------------------
//
//   cycle X    acc_valid: parameter read issued with acc_oct, and the
//              accumulators are registered (the parameter memory answers a
//              cycle late, and acc is only valid for this one cycle because
//              pe_array reuses it immediately)
//   cycle X+1  parameters and acc_q meet at rq_bank
//   cycle X+2  the 256-bit word is written to act_buffer
//
//  So the stage costs two cycles of latency and none of throughput: one
//  result in, one write out. Registering the accumulators here is ONE
//  pipeline register (Tm*ACC_W = 672 bit), not the shadow register DD-015
//  avoided - what R=32 removed was the drain counter and the stall path back
//  into addr_gen, and those are still absent.
//
//  ---- what the caller must provide ------------------------------------
//
//  `start` clears the address counter, the tag expectation and tag_error.
//  n_oc, base_out, act and relu6_qmax are per layer. The parameter buffer
//  must already hold this layer's channels, loaded through pl_*.
//
//  Run:  bash scripts/run_sim.sh pw_out param_buffer rq_bank bias_add requantize
//============================================================================
module pw_out #(
    parameter TM      = 32,
    parameter ACC_W   = 21,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter DATA_W  = 8,
    parameter PIX_W   = 16,
    parameter OCT_W   = 8,
    parameter PDEPTH  = 64,     // parameter buffer depth in oc_tiles
    parameter PA_W    = 6,      // clog2(PDEPTH)
    parameter BANK_W  = 5,      // clog2(TM)
    parameter AA_W    = 16      // activation buffer address width
)(
    input  wire                     clock,
    input  wire                     rst_n,

    // ---- per-layer control ---------------------------------------------
    input  wire                     start,
    input  wire [OCT_W-1:0]         n_oc,        // ceil(OC/TM)
    input  wire [AA_W-1:0]          base_out,    // output tensor base
    input  wire                     act,         // 0 = NONE, 1 = RELU6
    input  wire signed [7:0]        relu6_qmax,

    // ---- parameter load port -------------------------------------------
    input  wire                     pl_en,
    input  wire [BANK_W-1:0]        pl_bank,
    input  wire [PA_W-1:0]          pl_addr,
    input  wire signed [BIAS_W-1:0] pl_bias,
    input  wire signed [M0_W-1:0]   pl_m0,
    input  wire [SHIFT_W-1:0]       pl_shift,

    // ---- from pw_feeder ------------------------------------------------
    input  wire [TM*ACC_W-1:0]      acc,
    input  wire                     acc_valid,
    input  wire [PIX_W-1:0]         acc_pix,
    input  wire [OCT_W-1:0]         acc_oct,

    // ---- to the act_buffer write port ----------------------------------
    output wire                     aw_en,
    output reg  [AA_W-1:0]          aw_addr,
    output wire [TM*DATA_W-1:0]     aw_data,

    // ---- diagnostic ----------------------------------------------------
    output reg                      tag_error    // sticky until `start`
);

    // ================= stage A : capture + parameter fetch ==============
    reg [TM*ACC_W-1:0] acc_q;
    reg                vA;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            acc_q <= {TM*ACC_W{1'b0}};
            vA    <= 1'b0;
        end else if (start) begin
            vA    <= 1'b0;
        end else begin
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
        .clock    (clock),
        .wr_en    (pl_en), .wr_bank(pl_bank), .wr_addr(pl_addr),
        .wr_bias  (pl_bias), .wr_m0(pl_m0), .wr_shift(pl_shift),
        .rd_en    (acc_valid),
        .rd_addr  (acc_oct[PA_W-1:0]),
        .rd_bias  (p_bias), .rd_m0(p_m0), .rd_shift(p_shift)
    );

    // ================= stage B : requantize all Tm lanes ================
    wire q_valid;

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
        .q          (aw_data),
        .q_valid    (q_valid)
    );

    // ================= stage C : write ==================================
    assign aw_en = q_valid;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)          aw_addr <= {AA_W{1'b0}};
        else if (start)      aw_addr <= base_out;
        else if (q_valid)    aw_addr <= aw_addr + 1'b1;
    end

    // ================= tag self-check ===================================
    // Mirrors the order pw_feeder emits results in. Not used for addressing:
    // purely a tripwire for the two pipelines drifting apart.
    reg [PIX_W-1:0] exp_pix;
    reg [OCT_W-1:0] exp_oct;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            exp_pix   <= {PIX_W{1'b0}};
            exp_oct   <= {OCT_W{1'b0}};
            tag_error <= 1'b0;
        end else if (start) begin
            exp_pix   <= {PIX_W{1'b0}};
            exp_oct   <= {OCT_W{1'b0}};
            tag_error <= 1'b0;
        end else if (acc_valid) begin
            if (acc_pix !== exp_pix || acc_oct !== exp_oct)
                tag_error <= 1'b1;
            if (exp_oct == n_oc - 1'b1) begin
                exp_oct <= {OCT_W{1'b0}};
                exp_pix <= exp_pix + 1'b1;
            end else begin
                exp_oct <= exp_oct + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
