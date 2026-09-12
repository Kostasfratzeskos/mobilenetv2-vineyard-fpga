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
//  act_buffer's wr_full low with wr_sel = grp[0], and replicates the TC-byte
//  payload across the word per that module's convention. The other half is left
//  as the neighbouring group wrote it.
//
//  Run:  bash scripts/run_sim.sh dw_feeder line_buffer dw_array dwconv3x3 \
//          wgt_buffer param_buffer rq_bank bias_add requantize
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
    parameter BANK_W  = 4,      // clog2(TC)
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
    input  wire                      act,       // 0 = NONE, 1 = RELU6
    input  wire signed [7:0]         relu6_qmax,

    // ---- weight load: TC banks of K*K bytes, address = group ------------
    input  wire                      wl_en,
    input  wire [BANK_W-1:0]         wl_bank,
    input  wire [WA_W-1:0]           wl_addr,
    input  wire [K*K*DATA_W-1:0]     wl_data,

    // ---- parameter load: TC banks, address = group ----------------------
    input  wire                      pl_en,
    input  wire [BANK_W-1:0]         pl_bank,
    input  wire [PA_W-1:0]           pl_addr,
    input  wire signed [BIAS_W-1:0]  pl_bias,
    input  wire signed [M0_W-1:0]    pl_m0,
    input  wire [SHIFT_W-1:0]        pl_shift,

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
        if (!rst_n)     begin v_d1 <= 1'b0; real_d1 <= 1'b0; end
        else if (start) begin v_d1 <= 1'b0; real_d1 <= 1'b0; end
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

    wire [TC*BIAS_W-1:0]  p_bias;
    wire [TC*M0_W-1:0]    p_m0;
    wire [TC*SHIFT_W-1:0] p_shift;

    param_buffer #(
        .TM(TC), .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
        .DEPTH(PDEPTH), .ADDR_W(PA_W), .BANK_W(BANK_W)
    ) u_param (
        .clock(clock),
        .wr_en(pl_en), .wr_bank(pl_bank), .wr_addr(pl_addr),
        .wr_bias(pl_bias), .wr_m0(pl_m0), .wr_shift(pl_shift),
        .rd_en(v_d1), .rd_addr(grp_d1[PA_W-1:0]),
        .rd_bias(p_bias), .rd_m0(p_m0), .rd_shift(p_shift)
    );

    // ================= stage C+2 : the array and requantize =============
    reg [GRPW-1:0] grp_d2;
    always @(posedge clock) grp_d2 <= grp_d1;

    wire [TC*ACC_W-1:0] acc;

    dw_array #(.DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W)) u_arr (
        .win(win), .wk(wk), .acc(acc)
    );

    wire [TC*DATA_W-1:0] q;
    wire                 q_valid;

    rq_bank #(
        .TM(TC), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .DATA_W(DATA_W)
    ) u_rq (
        .clock(clock), .rst_n(rst_n),
        .en(win_valid), .act(act), .relu6_qmax(relu6_qmax),
        .acc(acc), .bias(p_bias), .m0(p_m0), .shift(p_shift),
        .q(q), .q_valid(q_valid)
    );

    // ================= stage C+3 : writeback ============================
    reg [GRPW-1:0] grp_d3;
    always @(posedge clock) grp_d3 <= grp_d2;

    reg [AA_W-1:0] opix_off;
    reg [GRPW-1:0] grp_wr_prev;
    reg            wrote_any;

    wire new_grp_wr = !wrote_any || (grp_d3 != grp_wr_prev);
    wire [AA_W-1:0] cur_off = new_grp_wr ? {AA_W{1'b0}} : opix_off;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (start) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (q_valid) begin
            opix_off    <= cur_off + n_ent;
            grp_wr_prev <= grp_d3;
            wrote_any   <= 1'b1;
        end
    end

    assign aw_en   = q_valid;
    assign aw_full = (TC == POOL_TM);           // constant: 0 for TC=16
    assign aw_sel  = grp_d3[SEL_W-1:0];
    assign aw_addr = base_out + {{(AA_W-GRPW+1){1'b0}}, grp_d3[GRPW-1:1]} + cur_off;
    // act_buffer's convention: replicate the payload, wr_sel picks the copy
    assign aw_data = {(POOL_TM/TC){q}};

    // ================= busy, including the pipeline drain ===============
    // The counters finish three stages before the last result is written, so
    // `busy` has to outlive them or the caller would start the next layer on
    // top of results still in flight - the same constraint pw_feeder documents.
    reg [2:0] drain;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)              drain <= 3'd0;
        else if (start)          drain <= 3'd0;
        else if (layer_done)     drain <= 3'd6;
        else if (drain != 3'd0)  drain <= drain - 3'd1;
    end

    assign busy = run || (drain != 3'd0);

endmodule

`default_nettype wire
