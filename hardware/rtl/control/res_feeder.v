`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  res_feeder.v  -  the residual-add sub-controller
//
//  Build plan #6. Executes one RES_ADD instruction:
//
//      out[i] = clamp_i8( requantize(saved[i], m0, shift, ACT_NONE) + target[i] )
//
//  which is DD-009: the two branches carry different per-tensor scales, so the
//  skip branch is brought onto the main branch's scale before the integer add.
//
//  ---- no multiplier of its own -----------------------------------------
//
//  The rescale of `saved` IS a requantize with bias = 0 and the op's scalar
//  (m0, shift), so it runs on the shared out_stage and this module adds no
//  arithmetic hardware at all - just 16 adders and 16 saturations. Compare the
//  existing residual_add.v engine, which does its own 8x32 multiply and would
//  cost 2 DSP per lane, 64 for a 32-wide bank.
//
//  Because the (m0, shift) are per TENSOR rather than per channel, the loader
//  writes the same pair into every parameter bank. Wasteful by 31 writes, once
//  per op; not worth a scalar bypass in the datapath.
//
//  ---- two reads per slice, and why 2 cycles rather than 5 --------------
//
//  The pool has ONE read port but this op needs two operands, so a 16-channel
//  slice costs two reads. A plain state machine that waited for each result
//  would take 5 cycles per slice; measured over the 10 residual ops that is
//  15,092 slices and 6.3% of the whole network's runtime, which is too much to
//  give away for tidiness. So the reads are issued back to back, one per cycle,
//  and `target` is carried forward in a three-deep shift register to meet its
//  own result coming out of out_stage. 2 cycles per slice, 2.5% of runtime.
//
//      cycle 0   issue read of target[k]
//      cycle 1   target[k] arrives -> pushed into the delay line;
//                issue read of saved[k]
//      cycle 2   saved[k] arrives -> sign-extended into out_stage
//      cycle 4   q_valid for k; target[k] emerges from the delay line;
//                add, saturate, write
//
//  The line is shifted every cycle and pushed every other one, so its output
//  alternates between a real target and a don't-care; q_valid picks the real
//  ones. Reads alternate target/saved forever, so the port is busy every cycle.
//
//  ---- 16 channels at a time, in the matching half ---------------------
//
//  Same arrangement as dw_feeder: a slice is TN=16 channels, the accumulators
//  are placed in lanes (slice&1)*16 .. +15 of the 32-lane stage, the parameters
//  are read at slice>>1, and the result is stored as a half entry with
//  wr_sel = slice&1. Nothing needs rotating.
//
//  Run:  bash scripts/run_sim.sh res_feeder out_stage param_buffer rq_bank \
//          bias_add requantize
//============================================================================
module res_feeder #(
    parameter DATA_W  = 8,
    parameter POOL_TM = 32,     // channels per pool entry / lanes in out_stage
    parameter TN      = 16,     // channels per slice
    parameter ACC_W   = 26,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter SEL_W   = 1,      // clog2(POOL_TM/TN)
    parameter PA_W    = 6,
    parameter BANK_W  = 5,      // clog2(POOL_TM)
    parameter PDEPTH  = 64,
    parameter AA_W    = 16,
    parameter PIX_W   = 16,
    parameter SLW     = 8,      // slice counter width

    // Latency of the shared out_stage: acc_valid to q_valid. A PARAMETER
    // because the target delay line and the drain are both sized from it and
    // out_stage is not instantiated here. L-3 took it from 2 to 5.
    parameter OS_LAT  = 5
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- layer control -------------------------------------------------
    input  wire                      start,
    input  wire [PIX_W-1:0]          n_pix,      // H*W
    input  wire [SLW-1:0]            n_sl,       // ceil(C/TN) slices per pixel
    input  wire [AA_W-1:0]           n_ent,      // ceil(C/POOL_TM) per pixel
    input  wire [AA_W-1:0]           base_in,    // the main path (target)
    input  wire [AA_W-1:0]           base_saved, // the skip branch
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


    // ================= the walk: pixel-major, slice-minor ================
    reg [PIX_W-1:0] pix;
    reg [SLW-1:0]   sl;
    reg [AA_W-1:0]  pix_off;      // pix * n_ent, kept by accumulation
    reg             ph;           // 0 = issue target read, 1 = issue saved
    reg             run;

    // ================= C-3 : shape and bases latched at start ===========
    //  `addr_gen` deliberately latches its shape at `start` so the caller may
    //  change the inputs while a layer runs - that is what makes prefetching the
    //  next instruction possible, and its header says so. No feeder honoured it:
    //  all five read the raw ports for the whole layer. Masked today only because
    //  `top_seq` does not refetch `w[]` until `!op_busy`, so the inputs happen to
    //  be stable - i.e. implementing the advertised prefetch would have broken all
    //  five feeders SILENTLY, as wrong addresses rather than as an error.
    //
    //  `base_out` is the worst of them: it is consumed during the DRAIN, after
    //  `run` has dropped, so it has to outlive the layer by more than the rest.
    //
    //  Same shape as addr_gen: the RAW ports are read only in the `start` branch,
    //  which is the cycle the caller presents them, and every other reader -
    //  including the simulation checks - uses the latched copy.
    reg [PIX_W-1:0] n_pix_q;
    reg [SLW-1:0]   n_sl_q;
    reg [AA_W-1:0]  n_ent_q, base_in_q, base_saved_q, base_out_q;

    always @(posedge clock) begin
        if (!rst_n) begin
            n_pix_q <= {PIX_W{1'b0}};  n_sl_q <= {SLW{1'b0}};
            n_ent_q <= {AA_W{1'b0}};   base_in_q <= {AA_W{1'b0}};
            base_saved_q <= {AA_W{1'b0}};  base_out_q <= {AA_W{1'b0}};
        end else if (start) begin
            n_pix_q <= n_pix;  n_sl_q <= n_sl;  n_ent_q <= n_ent;
            base_in_q <= base_in;  base_saved_q <= base_saved;
            base_out_q <= base_out;
        end
    end

    wire last_sl  = (sl  == n_sl_q  - 1'b1);
    wire last_pix = last_sl && (pix == n_pix_q - 1'b1);
    wire slice_hi = ph;                       // second phase of this slice

    always @(posedge clock) begin
        if (!rst_n) begin
            pix <= {PIX_W{1'b0}}; sl <= {SLW{1'b0}};
            pix_off <= {AA_W{1'b0}}; ph <= 1'b0;
            run <= 1'b0; layer_done <= 1'b0;
        end else if (start) begin
            pix <= {PIX_W{1'b0}}; sl <= {SLW{1'b0}};
            pix_off <= {AA_W{1'b0}}; ph <= 1'b0;
            run <= (n_pix != {PIX_W{1'b0}}) && (n_sl != {SLW{1'b0}});
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            if (run) begin
                if (!ph) begin
                    ph <= 1'b1;               // target issued, saved next
                end else begin
                    ph <= 1'b0;
                    if (last_pix) begin
                        run <= 1'b0;
                        layer_done <= 1'b1;
                        pix <= {PIX_W{1'b0}}; sl <= {SLW{1'b0}};
                        pix_off <= {AA_W{1'b0}};
                    end else if (last_sl) begin
                        sl  <= {SLW{1'b0}};
                        pix <= pix + 1'b1;
                        pix_off <= pix_off + n_ent_q;
                    end else begin
                        sl <= sl + 1'b1;
                    end
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
    // both operands live at the same offset inside their own tensors
    wire [31:0]     sl_wide   = {{(32-SLW){1'b0}}, sl} >> SEL_W;
    wire [AA_W-1:0] sl_ent    = sl_wide[AA_W-1:0];
    wire [AA_W-1:0] slice_off = pix_off + sl_ent;

    assign a_rd_en = run;
    assign a_addr  = (ph ? base_saved_q : base_in_q) + slice_off;
    assign a_sel   = sl[SEL_W-1:0];

    // ================= the target delay line ============================
    // Pushed on the phase where the target word is on the bus, shifted every
    // cycle, so its LAST stage lines up with that slice's q_valid.
    //  It was three named registers (tgt0/1/2) because the distance was 1 - the
    //  push leads sav_valid by a cycle - plus OS_LAT, and OS_LAT was 2. L-3 made
    //  OS_LAT 5, so this is a shift register of a DERIVED depth now. Three names
    //  would have had to become six, which is exactly the kind of edit that gets
    //  done wrong once and is then invisible.
    localparam TGT_LAT = 1 + OS_LAT;            // 6

    reg [TN*DATA_W-1:0] tgt_sr [0:TGT_LAT-1];
    reg [AA_W-1:0]      wa_sr  [0:TGT_LAT-1];
    reg [SEL_W-1:0]     ws_sr  [0:TGT_LAT-1];

    integer ts;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (ts = 0; ts < TGT_LAT; ts = ts + 1) begin
                tgt_sr[ts] <= {TN*DATA_W{1'b0}};
                wa_sr [ts] <= {AA_W{1'b0}};
                ws_sr [ts] <= {SEL_W{1'b0}};
            end
        end else begin
            if (slice_hi) begin
                // the target word issued last cycle is on the bus now, and the
                // counters still hold this slice's indices
                tgt_sr[0] <= a_word;
                wa_sr [0] <= base_out_q + slice_off;
                ws_sr [0] <= sl[SEL_W-1:0];
            end
            for (ts = 1; ts < TGT_LAT; ts = ts + 1) begin
                tgt_sr[ts] <= tgt_sr[ts-1];
                wa_sr [ts] <= wa_sr [ts-1];
                ws_sr [ts] <= ws_sr [ts-1];
            end
        end
    end

    wire [TN*DATA_W-1:0] tgt2 = tgt_sr[TGT_LAT-1];   // aligned with q_valid
    wire [AA_W-1:0]      wa2  = wa_sr [TGT_LAT-1];
    wire [SEL_W-1:0]     ws2  = ws_sr [TGT_LAT-1];

    // ================= feed the shared requantize stage =================
    // `saved` arrives one cycle after the second read is issued, i.e. on the
    // phase-0 cycle of the next slice.
    // The slice index that travels with the accumulators, kept at FULL width so
    // the parameter address is exactly the port width. An under-wide expression
    // on a wider port leaves the top bits undriven and the memory reads X -
    // that cost an afternoon in dw_feeder, so it is explicit here.
    reg             sav_valid;
    reg [SLW-1:0]   sav_sl;

    always @(posedge clock) begin
        if (!rst_n)     begin sav_valid <= 1'b0; sav_sl <= {SLW{1'b0}}; end
        else if (start) begin sav_valid <= 1'b0; end
        else begin
            sav_valid <= run && slice_hi;      // the saved word lands next cycle
            if (run && slice_hi) sav_sl <= sl;
        end
    end

    // sign-extend the slice's int8 channels into accumulators
    wire [TN*ACC_W-1:0] ext16;
    genvar m;
    generate
        for (m = 0; m < TN; m = m + 1) begin : sx
            wire signed [DATA_W-1:0] b = a_word[m*DATA_W +: DATA_W];
            assign ext16[m*ACC_W +: ACC_W] =
                   {{(ACC_W-DATA_W){b[DATA_W-1]}}, b};
        end
    endgenerate

    wire [POOL_TM*ACC_W-1:0] acc_wide =
        sav_sl[0] ? {ext16, {TN*ACC_W{1'b0}}} : {{TN*ACC_W{1'b0}}, ext16};

    // sav_sl >> 1, resized to EXACTLY the port width. Done through a wide
    // intermediate because SLW and PA_W are independent: a concatenation with
    // {(PA_W-SLW+1){1'b0}} is a negative repetition when SLW > PA_W, and a bare
    // slice would be too narrow the other way. Both halves of that mistake read
    // as X at the parameter memory.
    wire [31:0]     sl_half    = {{(32-SLW){1'b0}}, sav_sl} >> SEL_W;  // C-5
    wire [PA_W-1:0] param_addr = sl_half[PA_W-1:0];

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    assign os_acc_valid  = sav_valid;
    assign os_param_addr = param_addr;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

    // ================= add the main branch and saturate =================
    wire [TN*DATA_W-1:0] q_half = ws2[0] ? q[POOL_TM*DATA_W-1 : TN*DATA_W]
                                         : q[TN*DATA_W-1 : 0];

    wire [TN*DATA_W-1:0] sum16;
    generate
        for (m = 0; m < TN; m = m + 1) begin : addc
            wire signed [DATA_W:0] s =
                 $signed(q_half[m*DATA_W +: DATA_W]) +
                 $signed(tgt2  [m*DATA_W +: DATA_W]);
            //  L-15: the bounds are written as 8-bit signed CONSTANTS now.
            //  The lower one used to be `-8'sd128`, which is correct only by
            //  accident: 8'sd128 does not fit an 8-bit signed literal so it
            //  wraps to -128, and the unary minus then overflows back to -128.
            //  Two cancelling overflows that happen to land on the right value
            //  is not something the next reader should have to re-derive.
            //  The fall-through is $signed()-cast because a part-select is
            //  UNSIGNED whatever its parent, and one unsigned arm makes the
            //  whole conditional expression unsigned.
            assign sum16[m*DATA_W +: DATA_W] =
                   (s >  127) ? 8'sh7F :              // +127
                   (s < -128) ? 8'sh80                // -128
                              : $signed(s[DATA_W-1:0]);
        end
    endgenerate

    assign aw_en   = q_valid;
    assign aw_full = (TN == POOL_TM);
    assign aw_sel  = ws2;
    assign aw_addr = wa2;
    assign aw_data = ws2[0] ? {sum16, {TN*DATA_W{1'b0}}}
                            : {{TN*DATA_W{1'b0}}, sum16};

    // ================= busy, including the drain ========================
    //  Derived: sav_valid is high in the SAME cycle as layer_done - both are one
    //  cycle after the last counter step - so the last write lands OS_LAT cycles
    //  after the layer_done cycle, and `busy` covers layer_done plus `drain`.
    localparam DRAIN_CYC = OS_LAT;                  // 5
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
