`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  gap_feeder.v  -  the global-average-pool sub-controller
//
//  Build plan #6. Executes one GAP instruction: HxWxC -> 1x1xC.
//
//  Per channel, sum the H*W spatial int8 samples and requantize once. There is
//  NO divider: DD-010 folds the 1/(H*W) into the requantize multiplier, so
//  M = S_in / (49 * S_out) and the average comes out of a multiply-shift that
//  was needed anyway.
//
//  ---- reuses two things whole -----------------------------------------
//
//  The accumulator is TN=16 copies of the existing avgpool.v - a plain adder
//  with the same first/last/done handshake as conv1x1, no MAC and no DSP,
//  which is the resource-appropriate choice for pooling. The tail is the shared
//  out_stage. So this module contributes counters and wiring only.
//
//  ---- the loop ---------------------------------------------------------
//
//      for slice in 0 .. n_sl-1               // ceil(C/TN) channel slices
//        for p in 0 .. n_pix-1                // H*W spatial positions
//          read TN channels of position p, add into the 16 accumulators
//        requantize the 16 sums, store as a half entry
//
//  The slice is outermost because 16 accumulators is all the state there is:
//  going spatial-outer would need C of them. At 7x7x1280 that is 80 slices of
//  49 reads = 3,920 cycles, which is noise next to the 568k of the pointwise
//  array, so there is nothing to optimise here.
//
//  ---- widths -----------------------------------------------------------
//
//  ACC_W=26 is PROVABLY enough, like the depthwise and unlike the pointwise
//  array: the worst case is 49 * 128 = 6,272, which needs 14 bits. The input to
//  a GAP is always a ReLU6 output too, so in practice it is non-negative and
//  even smaller.
//
//  Output addressing: the result is 1x1xC, so slice s lands in entry s>>1 of
//  the output tensor, half s&1 - the same pairing as everywhere else.
//
//  Run:  bash scripts/run_sim.sh gap_feeder avgpool out_stage param_buffer \
//          rq_bank bias_add requantize
//============================================================================
module gap_feeder #(
    parameter DATA_W  = 8,
    parameter POOL_TM = 32,     // channels per pool entry
    parameter TN      = 16,     // channels accumulated in parallel
    parameter ACC_W   = 26,     // provably sufficient, see above
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter SEL_W   = 1,
    parameter PA_W    = 6,
    parameter BANK_W  = 5,
    parameter PDEPTH  = 64,
    parameter AA_W    = 16,
    parameter PIX_W   = 16,
    parameter SLW     = 8,      // slice counter width (up to 80 slices)

    // Latency of the shared out_stage: acc_valid to q_valid. A PARAMETER
    // because the slice tag and the drain are both sized from it. L-3 took it
    // from 2 to 5.
    parameter OS_LAT  = 5
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- layer control -------------------------------------------------
    input  wire                      start,
    input  wire [PIX_W-1:0]          n_pix,     // H*W of the INPUT
    input  wire [SLW-1:0]            n_sl,      // ceil(C/TN)
    input  wire [AA_W-1:0]           n_ent,     // ceil(C/POOL_TM) per input pixel
    input  wire [AA_W-1:0]           base_in,
    input  wire [AA_W-1:0]           base_out,

    // ---- the ONE shared requantize stage, which lives in accel_top -------
    // Only one op runs at a time, so the accelerator has a single out_stage and
    // every feeder drives it through these ports instead of carrying its own
    // copy. `act` and `relu6_qmax` come from the instruction word now, so they
    // are not this module's business either. See out_stage.v for the reasoning.
    output wire [POOL_TM*ACC_W-1:0]  os_acc,
    output wire                      os_acc_valid,
    output wire [PA_W-1:0]           os_param_addr,
    input  wire [POOL_TM*DATA_W-1:0] os_q,
    input  wire                      os_q_valid,

    // ---- pool read -----------------------------------------------------
    output wire                      a_rd_en,
    output wire [AA_W-1:0]           a_addr,
    output wire [SEL_W-1:0]          a_sel,
    input  wire [TN*DATA_W-1:0]      a_word,

    // ---- pool write (a half entry) -------------------------------------
    output wire                      aw_en,
    output wire                      aw_full,
    output wire [SEL_W-1:0]          aw_sel,
    output wire [AA_W-1:0]           aw_addr,
    output wire [POOL_TM*DATA_W-1:0] aw_data,

    output wire                      busy,
    output reg                       layer_done
);

    //  Used to size the drain counter from the drain length rather than from a
    //  guess. Same function as in the other three feeders.
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction


    // ================= stage 0 : slice-major, spatial-minor =============
    reg [SLW-1:0]   sl;
    reg [PIX_W-1:0] pp;
    reg [AA_W-1:0]  p_off;        // pp * n_ent, kept by accumulation
    reg             run;

    wire last_p  = (pp == n_pix - 1'b1);
    wire last_sl = last_p && (sl == n_sl - 1'b1);

    always @(posedge clock) begin
        if (!rst_n) begin
            sl <= {SLW{1'b0}}; pp <= {PIX_W{1'b0}}; p_off <= {AA_W{1'b0}};
            run <= 1'b0; layer_done <= 1'b0;
        end else if (start) begin
            sl <= {SLW{1'b0}}; pp <= {PIX_W{1'b0}}; p_off <= {AA_W{1'b0}};
            run <= (n_pix != {PIX_W{1'b0}}) && (n_sl != {SLW{1'b0}});
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            if (run) begin
                if (last_sl) begin
                    run <= 1'b0;
                    layer_done <= 1'b1;
                    sl <= {SLW{1'b0}}; pp <= {PIX_W{1'b0}}; p_off <= {AA_W{1'b0}};
                end else if (last_p) begin
                    sl    <= sl + 1'b1;
                    pp    <= {PIX_W{1'b0}};
                    p_off <= {AA_W{1'b0}};        // next slice restarts the sweep
                end else begin
                    pp    <= pp + 1'b1;
                    p_off <= p_off + n_ent;
                end
            end
        end
    end

    // ---- C-5: SEL_W is the ONE encoding of the entry/word ratio ---------
    //  Every one of these used to pair a SEL_W-derived half-select with a
    //  literal divide-by-two - `x[W-1:1]` or `x >> 1` - and the two agreed only
    //  because POOL_TM/TN happens to be 2, so SEL_W happens to be 1. At ratio 4
    //  the `*_sel` port would widen correctly and every address would still
    //  divide by 2, so three quarters of the reads would land on the wrong entry
    //  with no width mismatch and nothing to say so. The shift is `>> SEL_W`
    //  now, which is the same value today and the right one at any ratio.
    //
    //  Done through a 32-bit intermediate and then resized to exactly the port
    //  width: a bare shift keeps the operand's own width, so the result would be
    //  silently truncated or zero-extended at the assignment depending on which
    //  side was wider.
    // for both the parameter index and the output entry
    wire [31:0]     sl_half_w = {{(32-SLW){1'b0}}, sl} >> SEL_W;
    wire [AA_W-1:0] sl_ent    = sl_half_w[AA_W-1:0];

    assign a_rd_en = run;
    assign a_addr  = base_in + p_off + sl_ent;
    assign a_sel   = sl[SEL_W-1:0];

    // ================= stage 1 : the 16 accumulators ====================
    reg           v_d1, first_d1, last_d1;
    reg [SLW-1:0] sl_d1;

    always @(posedge clock) begin
        if (!rst_n) begin
            v_d1 <= 1'b0; first_d1 <= 1'b0; last_d1 <= 1'b0;
            sl_d1 <= {SLW{1'b0}};
        end else if (start) begin
            v_d1 <= 1'b0;
        end else begin
            v_d1     <= run;
            first_d1 <= (pp == {PIX_W{1'b0}});
            last_d1  <= last_p;
            sl_d1    <= sl;
        end
    end

    wire [TN*ACC_W-1:0] acc;
    wire [TN-1:0]       ap_done;

    genvar c;
    generate
        for (c = 0; c < TN; c = c + 1) begin : ch
            // one plain adder per channel - avgpool.v, not a MAC
            avgpool #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_ap (
                .clock (clock),
                .rst_n (rst_n),
                .valid (v_d1),
                .first (first_d1),
                .last  (last_d1),
                .a     (a_word[c*DATA_W +: DATA_W]),
                .acc   (acc[c*ACC_W +: ACC_W]),
                .done  (ap_done[c])
            );
        end
    endgenerate

    // all TN run in lockstep, so lane 0's done speaks for the bank
    wire sums_ready = ap_done[0];

    // ================= stage 2 : the shared requantize ==================
    reg [SLW-1:0] sl_d2;
    always @(posedge clock) begin
        if (!rst_n) sl_d2 <= {SLW{1'b0}};
        else        sl_d2 <= sl_d1;
    end

    wire [POOL_TM*ACC_W-1:0] acc_wide =
        sl_d2[0] ? {acc, {TN*ACC_W{1'b0}}} : {{TN*ACC_W{1'b0}}, acc};

    wire [31:0]     sl2_half   = {{(32-SLW){1'b0}}, sl_d2} >> SEL_W;   // C-5
    wire [PA_W-1:0] param_addr = sl2_half[PA_W-1:0];

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    assign os_acc_valid  = sums_ready;
    assign os_param_addr = param_addr;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

    // ================= stage 3 : writeback ==============================
    // The output is 1x1xC, so there is no pixel index: slice s lands in entry
    // s>>1, half s&1.
    //  It was sl_d3/sl_d4, two named registers, because sl_d2 is aligned with
    //  sums_ready and OS_LAT was 2. L-3 made OS_LAT 5, so this is a shift
    //  register of a DERIVED depth: `sl_d4` is whatever is aligned with q_valid,
    //  at any requantize depth.
    reg [SLW-1:0] sl_sr [0:OS_LAT-1];

    integer ss;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (ss = 0; ss < OS_LAT; ss = ss + 1) sl_sr[ss] <= {SLW{1'b0}};
        end else begin
            sl_sr[0] <= sl_d2;
            for (ss = 1; ss < OS_LAT; ss = ss + 1) sl_sr[ss] <= sl_sr[ss-1];
        end
    end

    wire [SLW-1:0] sl_d4 = sl_sr[OS_LAT-1];         // aligned with q_valid

    wire [31:0]     sl4_half = {{(32-SLW){1'b0}}, sl_d4} >> SEL_W;     // C-5
    wire [AA_W-1:0] out_ent  = sl4_half[AA_W-1:0];

    assign aw_en   = q_valid;
    assign aw_full = (TN == POOL_TM);
    assign aw_sel  = sl_d4[SEL_W-1:0];
    assign aw_addr = base_out + out_ent;
    assign aw_data = q;              // already in the half wr_sel stores

    // ================= busy, including the drain ========================
    //  Derived: sums_ready is one cycle after the layer_done cycle - the avgpool
    //  bank answers one cycle after its last sample - and the write is OS_LAT
    //  after that.
    localparam DRAIN_CYC = 1 + OS_LAT;              // 6
    localparam DRAIN_W   = clog2(DRAIN_CYC + 1);

    reg [DRAIN_W-1:0] drain;
    always @(posedge clock) begin
        if (!rst_n)          drain <= {DRAIN_W{1'b0}};
        else if (start)      drain <= {DRAIN_W{1'b0}};
        else if (layer_done) drain <= DRAIN_CYC[DRAIN_W-1:0];
        else if (drain != {DRAIN_W{1'b0}}) drain <= drain - 1'b1;
    end

    // `layer_done` is in here for a reason that only shows up at the top level.
    // It pulses in the SAME cycle `run` drops, but `drain` is not loaded until
    // the edge at the END of that cycle - so without it there is exactly one
    // cycle where run=0 and drain=0 and `busy` reads low. top_seq leaves S_RUN
    // on the first !busy it sees, so that one-cycle hole made it start the next
    // op's weight load while this one still had its whole drain to go. Found by
    // accel_tb; invisible to a standalone testbench, which waits on layer_done
    // rather than on busy falling.
    assign busy = run || layer_done || (drain != {DRAIN_W{1'b0}});

endmodule

`default_nettype wire
