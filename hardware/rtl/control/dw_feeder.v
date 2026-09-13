`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  dw_feeder.v  -  the depthwise sub-controller, input to writeback
//
//  Build plan #5, final piece. The depthwise counterpart of pw_feeder + pw_out
//  in one module, because the depthwise output stage has no complexity of its
//  own to separate out:
//
//    counters -> act_buffer -> line_buffer -> dw_array -> rq_bank -> act_buffer
//
//  ---- the loop, and why the channel group is the OUTER level ----------
//
//      for grp in 0 .. n_grp-1                 // ceil(C/TC) channel groups
//        for y in 0 .. img_h                   // one EXTRA row  (virtual)
//          for x in 0 .. img_w                 // one EXTRA column (virtual)
//            read TC channels of pixel (y,x), feed the window generator
//
//  The group has to be outermost: line_buffer holds two rows of ONE channel
//  group, so switching groups mid-row would mean either re-reading rows or
//  keeping a line buffer per group (30 of them at C=960). The consequence is
//  that a depthwise layer re-reads its input ceil(C/TC) times - cheap, because
//  it is on-chip - and that the output is produced group-major, pixel-minor,
//  which is the opposite order from the pointwise path.
//
//  The extra row and column are the virtual edge line_buffer needs to centre
//  the last real row and column; `in_data` is driven to zero there and no
//  activation read is issued.
//
//  ---- addresses, again without multipliers -----------------------------
//
//  Input:  base_in  + (grp >> 1) + pix_off      pix_off += n_ent per real pixel
//  Output: base_out + (grp >> 1) + opix_off     opix_off += n_ent per write
//
//  `grp >> 1` because a pool entry holds 32 channels and a group is 16, so two
//  groups share an entry - the same pairing act_buffer's rd_sel already does on
//  the read side. `pix_off` is a counter reset at each group boundary, so the
//  only arithmetic is one add of a shifted 6-bit value.
//
//  ---- the pipeline, and the group-boundary hazard ----------------------
//
//   C    counters (grp,y,x); activation read issued
//   C+1  activation word back -> line_buffer fed; WEIGHT and PARAMETER reads
//        issued, addressed by the grp that travels WITH this pixel
//   C+2  window + weights + parameters all present; dw_array is combinational,
//        so rq_bank latches on win_valid
//   C+3  the TC int8 results are written back as a half entry
//
//  Reading the weights and parameters every cycle, addressed by the PIPELINED
//  group index, is what removes the group-boundary hazard. Reading them once
//  per pass would be cheaper, but at a boundary the new group's parameters
//  would overwrite the old ones while the last few windows of the previous
//  group were still in flight, and those results would be requantized with the
//  wrong scales. The alternative - draining the pipeline between groups - costs
//  4 cycles x up to 60 groups on layers that are only 64 cycles long each.
//
//  ---- writeback is a HALF entry ---------------------------------------
//
//  TC=16 channels fill half of a 32-channel pool entry, so the write asserts
//  act_buffer's wr_full low with wr_sel = grp[0]. The other half is left as the
//  neighbouring group wrote it.
//
//  The requantize stage is the SHARED out_stage (32 lanes), not a private
//  16-lane one, because only one op runs at a time. Rather than rotate the 16
//  accumulators down to lanes 0-15, they are driven into lanes (grp&1)*16 ..
//  +15 and the parameters are read at grp>>1. Both sides then line up for free:
//  a parameter entry covers 32 consecutive channels, so those banks already hold
//  channels 16g..16g+15, and `q` comes back with the results in exactly the half
//  of the word that wr_sel = grp&1 stores. No rotation, no replication.
//
//  Run:  bash scripts/run_sim.sh dw_feeder line_buffer dw_array dwconv3x3 \
//          wgt_buffer out_stage param_buffer rq_bank bias_add requantize
//============================================================================
module dw_feeder #(
    parameter DATA_W  = 8,
    parameter TC      = 16,     // channels in parallel (DD-014)
    parameter K       = 3,
    parameter ACC_W   = 21,     // provably enough for 9 taps, see dw_array
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter POOL_TM = 32,     // channels per activation-pool entry
    parameter SEL_W   = 1,      // clog2(POOL_TM/TC)
    parameter XW      = 8,      // coordinate width, covers MAX_W inclusive
    parameter MAX_W   = 112,
    parameter GRPW    = 6,      // group counter width (max 60 groups)
    parameter AA_W    = 16,     // activation pool address width
    parameter WA_W    = 6,      // depthwise weight buffer address width
    parameter PA_W    = 6,      // parameter buffer address width
    parameter BANK_W  = 4,      // clog2(TC), for the weight banks
    parameter POOL_BANK_W = 5,  // clog2(POOL_TM), for the shared param banks
    parameter WDEPTH  = 64,
    parameter PDEPTH  = 64
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- layer control -------------------------------------------------
    input  wire                      start,
    input  wire [XW-1:0]             img_w,     // INPUT width
    input  wire [XW-1:0]             img_h,     // INPUT height
    input  wire                      stride2,
    input  wire [GRPW-1:0]           n_grp,     // ceil(C/TC)
    input  wire [AA_W-1:0]           n_ent,     // ceil(C/POOL_TM) per pixel
    input  wire [AA_W-1:0]           base_in,
    input  wire [AA_W-1:0]           base_out,

    // ---- weight load: TC banks of K*K bytes, address = group ------------
    input  wire                      wl_en,
    input  wire [BANK_W-1:0]         wl_bank,
    input  wire [WA_W-1:0]           wl_addr,
    input  wire [K*K*DATA_W-1:0]     wl_data,

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

    // ---- activation pool: read -----------------------------------------
    output wire                      a_rd_en,
    output wire [AA_W-1:0]           a_addr,
    output wire [SEL_W-1:0]          a_sel,
    input  wire [TC*DATA_W-1:0]      a_word,    // one cycle after a_addr

    // ---- activation pool: write (a HALF entry) --------------------------
    output wire                      aw_en,
    output wire                      aw_full,
    output wire [SEL_W-1:0]          aw_sel,
    output wire [AA_W-1:0]           aw_addr,
    output wire [POOL_TM*DATA_W-1:0] aw_data,

    output wire                      busy,
    output reg                       layer_done
);

    localparam NT = K*K;

    // ================= stage C : the three counters =====================
    reg [GRPW-1:0] grp;
    reg [XW-1:0]   cy, cx;
    reg            run;

    wire last_x   = (cx == img_w);
    wire last_y   = last_x && (cy == img_h);
    wire last_grp = last_y && (grp == n_grp - 1'b1);
    wire step     = run;

    // a real pixel exists only inside the image; the extra row and column are
    // the virtual edge line_buffer needs
    wire is_real  = (cy < img_h) && (cx < img_w);

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            grp <= {GRPW{1'b0}}; cy <= {XW{1'b0}}; cx <= {XW{1'b0}};
            run <= 1'b0; layer_done <= 1'b0;
        end else if (start) begin
            grp <= {GRPW{1'b0}}; cy <= {XW{1'b0}}; cx <= {XW{1'b0}};
            run <= (n_grp != {GRPW{1'b0}});
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            if (step) begin
                if (last_grp) begin
                    grp <= {GRPW{1'b0}}; cy <= {XW{1'b0}}; cx <= {XW{1'b0}};
                    run <= 1'b0;
                    layer_done <= 1'b1;
                end else if (last_y) begin
                    grp <= grp + 1'b1; cy <= {XW{1'b0}}; cx <= {XW{1'b0}};
                end else if (last_x) begin
                    cy <= cy + 1'b1;   cx <= {XW{1'b0}};
                end else begin
                    cx <= cx + 1'b1;
                end
            end
        end
    end

    // ---- input address: one add, no multiplier --------------------------
    reg [AA_W-1:0] pix_off;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)          pix_off <= {AA_W{1'b0}};
        else if (start)      pix_off <= {AA_W{1'b0}};
        else if (step) begin
            if (last_y)      pix_off <= {AA_W{1'b0}};   // next group restarts
            else if (is_real) pix_off <= pix_off + n_ent;
        end
    end

    assign a_addr  = base_in + {{(AA_W-GRPW+1){1'b0}}, grp[GRPW-1:1]} + pix_off;
    assign a_sel   = grp[SEL_W-1:0];
    assign a_rd_en = step && is_real;

    // ================= stage C+1 : feed the window generator ============
    reg [GRPW-1:0] grp_d1;
    reg [XW-1:0]   y_d1, x_d1;
    reg            v_d1, real_d1;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            v_d1 <= 1'b0; real_d1 <= 1'b0;
            grp_d1 <= {GRPW{1'b0}}; y_d1 <= {XW{1'b0}}; x_d1 <= {XW{1'b0}};
        end else if (start) begin v_d1 <= 1'b0; real_d1 <= 1'b0; end
        else begin
            v_d1    <= step;
            real_d1 <= is_real;
            grp_d1  <= grp;
            y_d1    <= cy;
            x_d1    <= cx;
        end
    end

    wire [TC*DATA_W-1:0] lb_in = real_d1 ? a_word : {TC*DATA_W{1'b0}};

    wire [NT*TC*DATA_W-1:0] win;
    wire                    win_valid;
    wire [XW-1:0]           out_x, out_y;

    line_buffer #(
        .DATA_W(DATA_W), .TC(TC), .K(K), .MAX_W(MAX_W), .XW(XW)
    ) u_lb (
        .clock(clock), .rst_n(rst_n),
        .in_valid(v_d1), .in_data(lb_in), .in_x(x_d1), .in_y(y_d1),
        .stride2(stride2),
        .win(win), .win_valid(win_valid), .out_x(out_x), .out_y(out_y)
    );

    // Weights and parameters are read HERE, addressed by the group that travels
    // with this pixel, so they arrive at C+2 together with the window. See the
    // header: this is what removes the group-boundary hazard.
    wire [TC*NT*DATA_W-1:0] wk;

    wgt_buffer #(
        .DATA_W(DATA_W), .TM(TC), .TN(NT),
        .DEPTH(WDEPTH), .ADDR_W(WA_W), .BANK_W(BANK_W)
    ) u_wgt (
        .clock(clock),
        .wr_en(wl_en), .wr_bank(wl_bank), .wr_addr(wl_addr), .wr_data(wl_data),
        .rd_en(v_d1), .rd_addr(grp_d1[WA_W-1:0]), .rd_data(wk)
    );

    // ================= stage C+2 : the array and requantize =============
    reg [GRPW-1:0] grp_d2;
    always @(posedge clock or negedge rst_n)
        if (!rst_n) grp_d2 <= {GRPW{1'b0}};
        else        grp_d2 <= grp_d1;

    wire [TC*ACC_W-1:0] acc;

    dw_array #(.DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W)) u_arr (
        .win(win), .wk(wk), .acc(acc)
    );

    // Place the TC accumulators in the half of the 32-lane bus that matches this
    // group, so the parameter banks and the half write line up without any
    // rotation - see the header.
    wire [POOL_TM*ACC_W-1:0] acc_wide =
        grp_d2[0] ? {acc, {TC*ACC_W{1'b0}}} : {{TC*ACC_W{1'b0}}, acc};

    // Size the parameter address EXACTLY to the port. A narrower expression on
    // a wider input port leaves the top bits undriven in xsim, and mem[X] reads
    // X - which is what a whole word of xxxx turned out to be.
    wire [PA_W-1:0] param_addr_w =
        {{(PA_W-GRPW+1){1'b0}}, grp_d2[GRPW-1:1]};

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    assign os_acc_valid  = win_valid;
    assign os_param_addr = param_addr_w;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

    // ================= stage C+4 : writeback ============================
    // out_stage registers the accumulators before requantizing, so the result
    // lands one cycle later than a private rq_bank would have produced it, and
    // the group index needs one more stage to stay with it.
    reg [GRPW-1:0] grp_d3, grp_d4;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            grp_d3 <= {GRPW{1'b0}};
            grp_d4 <= {GRPW{1'b0}};
        end else begin
            grp_d3 <= grp_d2;
            grp_d4 <= grp_d3;
        end
    end

    reg [AA_W-1:0] opix_off;
    reg [GRPW-1:0] grp_wr_prev;
    reg            wrote_any;

    wire new_grp_wr = !wrote_any || (grp_d4 != grp_wr_prev);
    wire [AA_W-1:0] cur_off = new_grp_wr ? {AA_W{1'b0}} : opix_off;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (start) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (q_valid) begin
            opix_off    <= cur_off + n_ent;
            grp_wr_prev <= grp_d4;
            wrote_any   <= 1'b1;
        end
    end

    assign aw_en   = q_valid;
    assign aw_full = (TC == POOL_TM);           // constant: 0 for TC=16
    assign aw_sel  = grp_d4[SEL_W-1:0];
    assign aw_addr = base_out + {{(AA_W-GRPW+1){1'b0}}, grp_d4[GRPW-1:1]} + cur_off;
    // q already carries the results in the half wr_sel will store, so it goes
    // straight through - the replication convention is not needed here.
    assign aw_data = q;

    // ================= busy, including the pipeline drain ===============
    // The counters finish three stages before the last result is written, so
    // `busy` has to outlive them or the caller would start the next layer on
    // top of results still in flight - the same constraint pw_feeder documents.
    reg [2:0] drain;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)              drain <= 3'd0;
        else if (start)          drain <= 3'd0;
        else if (layer_done)     drain <= 3'd7;
        else if (drain != 3'd0)  drain <= drain - 3'd1;
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
