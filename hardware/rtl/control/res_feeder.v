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
    parameter ACC_W   = 21,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter SEL_W   = 1,      // clog2(POOL_TM/TN)
    parameter PA_W    = 6,
    parameter BANK_W  = 5,      // clog2(POOL_TM)
    parameter PDEPTH  = 64,
    parameter AA_W    = 16,
    parameter PIX_W   = 16,
    parameter SLW     = 8       // slice counter width
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


    // ================= the walk: pixel-major, slice-minor ================
    reg [PIX_W-1:0] pix;
    reg [SLW-1:0]   sl;
    reg [AA_W-1:0]  pix_off;      // pix * n_ent, kept by accumulation
    reg             ph;           // 0 = issue target read, 1 = issue saved
    reg             run;

    wire last_sl  = (sl  == n_sl  - 1'b1);
    wire last_pix = last_sl && (pix == n_pix - 1'b1);
    wire slice_hi = ph;                       // second phase of this slice

    always @(posedge clock or negedge rst_n) begin
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
                        pix_off <= pix_off + n_ent;
                    end else begin
                        sl <= sl + 1'b1;
                    end
                end
            end
        end
    end

    // both operands live at the same offset inside their own tensors
    wire [AA_W-1:0] slice_off = pix_off + {{(AA_W-SLW+1){1'b0}}, sl[SLW-1:1]};

    assign a_rd_en = run;
    assign a_addr  = (ph ? base_saved : base_in) + slice_off;
    assign a_sel   = sl[SEL_W-1:0];

    // ================= the target delay line ============================
    // Pushed on the phase where the target word is on the bus, shifted every
    // cycle, so its third stage lines up with that slice's q_valid.
    reg [TN*DATA_W-1:0] tgt0, tgt1, tgt2;
    reg [AA_W-1:0]      wa0, wa1, wa2;
    reg [SEL_W-1:0]     ws0, ws1, ws2;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            tgt0 <= {TN*DATA_W{1'b0}}; tgt1 <= {TN*DATA_W{1'b0}}; tgt2 <= {TN*DATA_W{1'b0}};
            wa0  <= {AA_W{1'b0}};  wa1 <= {AA_W{1'b0}};  wa2 <= {AA_W{1'b0}};
            ws0  <= {SEL_W{1'b0}}; ws1 <= {SEL_W{1'b0}}; ws2 <= {SEL_W{1'b0}};
        end else begin
            if (slice_hi) begin
                // the target word issued last cycle is on the bus now, and the
                // counters still hold this slice's indices
                tgt0 <= a_word;
                wa0  <= base_out + slice_off;
                ws0  <= sl[SEL_W-1:0];
            end
            tgt1 <= tgt0;  wa1 <= wa0;  ws1 <= ws0;
            tgt2 <= tgt1;  wa2 <= wa1;  ws2 <= ws1;
        end
    end

    // ================= feed the shared requantize stage =================
    // `saved` arrives one cycle after the second read is issued, i.e. on the
    // phase-0 cycle of the next slice.
    // The slice index that travels with the accumulators, kept at FULL width so
    // the parameter address is exactly the port width. An under-wide expression
    // on a wider port leaves the top bits undriven and the memory reads X -
    // that cost an afternoon in dw_feeder, so it is explicit here.
    reg             sav_valid;
    reg [SLW-1:0]   sav_sl;

    always @(posedge clock or negedge rst_n) begin
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
    wire [31:0]     sl_half    = {{(32-SLW){1'b0}}, sav_sl} >> 1;
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
            assign sum16[m*DATA_W +: DATA_W] =
                   (s >  127) ? 8'sd127 :
                   (s < -128) ? -8'sd128 : s[DATA_W-1:0];
        end
    endgenerate

    assign aw_en   = q_valid;
    assign aw_full = (TN == POOL_TM);
    assign aw_sel  = ws2;
    assign aw_addr = wa2;
    assign aw_data = ws2[0] ? {sum16, {TN*DATA_W{1'b0}}}
                            : {{TN*DATA_W{1'b0}}, sum16};

    // ================= busy, including the drain ========================
    reg [2:0] drain;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)             drain <= 3'd0;
        else if (start)         drain <= 3'd0;
        else if (layer_done)    drain <= 3'd6;
        else if (drain != 3'd0) drain <= drain - 3'd1;
    end

    // `layer_done` is in here for a reason that only shows up at the top level.
    // It pulses in the SAME cycle `run` drops, but `drain` is not loaded until
    // the edge at the END of that cycle - so without it there is exactly one
    // cycle where run=0 and drain=0 and `busy` reads low. top_seq leaves S_RUN
    // on the first !busy it sees, so that one-cycle hole made it start the next
    // op's weight load while this one still had its whole drain to go. Found by
    // accel_tb; invisible to a standalone testbench, which waits on layer_done
    // rather than on busy falling.
    assign busy = run || layer_done || (drain != 3'd0);

endmodule

`default_nettype wire
