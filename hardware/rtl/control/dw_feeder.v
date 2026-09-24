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
    parameter ACC_W   = 26,     // provably enough for 9 taps, see dw_array
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
    parameter PDEPTH  = 64,

    // Latency of the shared out_stage, which lives in accel_top: acc_valid to
    // q_valid. A PARAMETER because this module's writeback tag and drain are
    // both sized from it and out_stage is not instantiated here.
    // Default is the REAL value, not a placeholder. It was 2 while requantize
    // was one register; L-3 made it 5, and the standalone testbenches
    // instantiate this module directly and take the default - so a stale
    // default is not a cosmetic issue, it silently desynchronises this feeder
    // from the out_stage sitting next to it. dw_datapath_tb caught exactly that
    // via the C-2 witness: a 3-cycle gap showed up as a 3-pixel shift.
    parameter OS_LAT  = 5
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

    // ---- the latencies this module is defined against -------------------
    //  DW_LAT is dw_array's, restated from the same inputs it derives it from -
    //  one registered product stage plus clog2(K*K) adder-tree levels, and no
    //  accumulate stage, because a depthwise window completes in one pass. The
    //  simulation check at the bottom MEASURES the real distance from win_valid
    //  to the array's valid_out and fails if the two disagree, which is what
    //  makes restating it safe rather than a second opinion.
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam DW_LAT = 1 + clog2(NT);          // 5 at K=3

    //  Every depth in this module, in one place and all derived from DW_LAT and
    //  OS_LAT. They are declared together because they move together - that is
    //  the whole content of docs/latency_map.md's checklist for this feeder.
    localparam GRP_ARR   = 2 + DW_LAT;              // counters -> array output
    localparam GRP_WR    = GRP_ARR + OS_LAT;        //          -> q_valid
    localparam WIT_LAT   = DW_LAT + OS_LAT;         // C-2 witness, win_valid ->
    localparam DRAIN_CYC = 1 + DW_LAT + OS_LAT;     // layer_done -> last write
    localparam DRAIN_W   = clog2(DRAIN_CYC + 1);

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

    always @(posedge clock) begin
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

    always @(posedge clock) begin
        if (!rst_n)          pix_off <= {AA_W{1'b0}};
        else if (start)      pix_off <= {AA_W{1'b0}};
        else if (step) begin
            if (last_y)      pix_off <= {AA_W{1'b0}};   // next group restarts
            else if (is_real) pix_off <= pix_off + n_ent;
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
    wire [31:0]     grp_wide = {{(32-GRPW){1'b0}}, grp} >> SEL_W;
    wire [AA_W-1:0] grp_ent  = grp_wide[AA_W-1:0];

    assign a_addr  = base_in + grp_ent + pix_off;
    assign a_sel   = grp[SEL_W-1:0];
    assign a_rd_en = step && is_real;

    // ================= stage C+1 : feed the window generator ============
    reg [GRPW-1:0] grp_d1;
    reg [XW-1:0]   y_d1, x_d1;
    reg            v_d1, real_d1;

    always @(posedge clock) begin
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

    // ================= the array, and the group tag beside it ============
    //
    //  The group index used to be three named registers - grp_d2 aligned with a
    //  COMBINATIONAL array, grp_d3 and grp_d4 walking it out to the writeback.
    //  dw_array is a DW_LAT-stage pipeline now (L-1), so the two points that
    //  need a tag are further away and further apart:
    //
    //      grp_sr[GRP_ARR-1]  aligned with the array's `valid_out`, which is
    //                         what selects the accumulator half and addresses
    //                         the parameter banks
    //      grp_sr[GRP_WR-1]   aligned with out_stage's q_valid, which is the
    //                         write
    //
    //  Both indices are DERIVED from DW_LAT and OS_LAT, so they move when the
    //  array or the requantize stage does. That is the whole point of
    //  docs/latency_map.md: grp_d4 was a name, GRP_WR is an expression.
    reg [GRPW-1:0] grp_sr [0:GRP_WR-1];

    integer gs;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (gs = 0; gs < GRP_WR; gs = gs + 1) grp_sr[gs] <= {GRPW{1'b0}};
        end else begin
            grp_sr[0] <= grp_d1;
            for (gs = 1; gs < GRP_WR; gs = gs + 1) grp_sr[gs] <= grp_sr[gs-1];
        end
    end

    wire [GRPW-1:0] grp_arr = grp_sr[GRP_ARR-2];   // grp_sr[0] is already 2 deep
    wire [GRPW-1:0] grp_wr  = grp_sr[GRP_WR-2];

    wire [TC*ACC_W-1:0] acc;
    wire                arr_valid;

    dw_array #(.DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W)) u_arr (
        .clock(clock), .rst_n(rst_n),
        .valid(win_valid),
        .win(win), .wk(wk),
        .acc(acc), .valid_out(arr_valid)
    );

    // Place the TC accumulators in the half of the 32-lane bus that matches this
    // group, so the parameter banks and the half write line up without any
    // rotation - see the header.
    wire [POOL_TM*ACC_W-1:0] acc_wide =
        grp_arr[0] ? {acc, {TC*ACC_W{1'b0}}} : {{TC*ACC_W{1'b0}}, acc};

    // Size the parameter address EXACTLY to the port. A narrower expression on
    // a wider input port leaves the top bits undriven in xsim, and mem[X] reads
    // X - which is what a whole word of xxxx turned out to be.
    //  C-5: >> SEL_W, not a literal halving - see the note at a_addr above.
    wire [31:0]     grp_arr_wide = {{(32-GRPW){1'b0}}, grp_arr} >> SEL_W;
    wire [PA_W-1:0] param_addr_w = grp_arr_wide[PA_W-1:0];

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    // A-2, and this is the line the finding is about. It used to be
    // `assign os_acc_valid = win_valid;` - correct only while dw_array was
    // combinational, and wrong by DW_LAT cycles the moment it was not, with no
    // width mismatch and no elaboration error to say so. It is a WIRE from the
    // array's own valid output now, so the latency cannot be asserted wrongly:
    // it is whatever the array says it is.
    assign os_acc_valid  = arr_valid;
    assign os_param_addr = param_addr_w;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

    // ================= writeback =========================================
    reg [AA_W-1:0] opix_off;
    reg [GRPW-1:0] grp_wr_prev;
    reg            wrote_any;

    wire new_grp_wr = !wrote_any || (grp_wr != grp_wr_prev);
    wire [AA_W-1:0] cur_off = new_grp_wr ? {AA_W{1'b0}} : opix_off;

    always @(posedge clock) begin
        if (!rst_n) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (start) begin
            opix_off <= {AA_W{1'b0}}; wrote_any <= 1'b0;
        end else if (q_valid) begin
            opix_off    <= cur_off + n_ent;
            grp_wr_prev <= grp_wr;
            wrote_any   <= 1'b1;
        end
    end

    assign aw_en   = q_valid;
    assign aw_full = (TC == POOL_TM);           // constant: 0 for TC=16
    //  C-5: >> SEL_W, not a literal halving - see the note at a_addr above.
    wire [31:0]     grp_wr_wide = {{(32-GRPW){1'b0}}, grp_wr} >> SEL_W;
    wire [AA_W-1:0] grp_wr_ent  = grp_wr_wide[AA_W-1:0];

    assign aw_sel  = grp_wr[SEL_W-1:0];
    assign aw_addr = base_out + grp_wr_ent + cur_off;
    // q already carries the results in the half wr_sel will store, so it goes
    // straight through - the replication convention is not needed here.
    assign aw_data = q;

    // ---- C-2: the witness that was being thrown away ---------------------
    //
    //  line_buffer emits out_x / out_y in OUTPUT coordinates alongside every
    //  window. They are declared above, connected, and never read. Meanwhile
    //  the writeback address comes from `opix_off`, a free-running count of
    //  q_valid pulses - so a single spurious or missing win_valid shifts the
    //  ENTIRE output feature map by one pixel, and every value in it is still a
    //  plausible activation. Two independent derivations of the same quantity
    //  exist, the fragile one is used, and the witness is discarded.
    //
    //  The datapath is unchanged: everything below is inside `ifndef SYNTHESIS`,
    //  so it does not synthesise and cannot alter a single address. What it does
    //  is delay out_x/out_y to the write stage and check that the counter agrees
    //  with them. Cheap, and it converts "the map is shifted by one pixel, good
    //  luck" into a line naming the pixel where they diverged.
    //
    //  The output width is not a port here, but it is derivable: the feeder
    //  walks img_w+1 input columns and line_buffer emits a window on every
    //  second centre at stride 2.
`ifndef SYNTHESIS
    // ---- DW_LAT is restated here, so MEASURE it (L-1, A-2) --------------
    //  This module computes DW_LAT from K with the same arithmetic dw_array
    //  uses, and its group tag, its witness depth and its drain are all sized
    //  from the result. A-2's whole point is that a wrong answer here has no
    //  width mismatch and no elaboration error, so time the real thing: the
    //  distance from `win_valid` going into the array to `arr_valid` coming out.
    //  One measurement per layer, then stop.
    reg [7:0] lat_cnt;
    reg       lat_arm, lat_seen;
    always @(posedge clock) begin
        if (!rst_n || start) begin
            lat_arm  <= 1'b0;
            lat_seen <= 1'b0;
            lat_cnt  <= 8'd0;
        end else if (!lat_seen) begin
            if (!lat_arm) begin
                if (win_valid) begin
                    lat_arm <= 1'b1;
                    lat_cnt <= 8'd1;
                end
            end else if (arr_valid) begin
                lat_seen <= 1'b1;
            end else begin
                lat_cnt <= lat_cnt + 8'd1;
            end
        end
    end

    always @(posedge clock) begin
        if (rst_n && lat_arm && !lat_seen && arr_valid && (lat_cnt != DW_LAT[7:0])) begin
            $display("ERROR: %m L-1/A-2 dw_array answered %0d cycles after the window entered it, but this module's DW_LAT says %0d at time %0t. The group tag (arr %0d, wr %0d), the C-2 witness (%0d) and the drain (%0d) are all sized from DW_LAT, so they are wrong too.",
                     lat_cnt, DW_LAT, $time, GRP_ARR, GRP_WR, WIT_LAT, DRAIN_CYC);
            $finish;
        end
    end

    //  Alignment, which is the whole difficulty and worth writing down because
    //  Phase 2 will have to redo it: out_x/out_y are line_buffer OUTPUTS, valid
    //  in the same cycle as win_valid. grp_d2 is a delayed copy of a signal from
    //  two cycles EARLIER, so it is valid in that same cycle too - but capturing
    //  out_x into a register already costs one cycle. So the witness needs
    //  OS_LAT registers to reach q_valid, where grp_* needed OS_LAT+1 stages
    //  counting from grp. Getting this wrong is what the check itself caught on
    //  its first run: it reported the counter at pixel 1 against a witness at
    //  pixel 0, which is a lagging witness, not a wrong address.
    //  The witness depth moves with the array, exactly like the group tag: it
    //  was two registers when dw_array was combinational and is DW_LAT + OS_LAT
    //  now. Capturing a line_buffer OUTPUT already costs one of them, which is
    //  the off-by-one this check caught on its first run in Phase 1.
    reg [XW-1:0] ox_sr [0:WIT_LAT-1];
    reg [XW-1:0] oy_sr [0:WIT_LAT-1];

    integer ws;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (ws = 0; ws < WIT_LAT; ws = ws + 1) begin
                ox_sr[ws] <= {XW{1'b0}};
                oy_sr[ws] <= {XW{1'b0}};
            end
        end else begin
            if (win_valid) begin ox_sr[0] <= out_x; oy_sr[0] <= out_y; end
            for (ws = 1; ws < WIT_LAT; ws = ws + 1) begin
                ox_sr[ws] <= ox_sr[ws-1];
                oy_sr[ws] <= oy_sr[ws-1];
            end
        end
    end

    wire [XW-1:0] ox_w = ox_sr[WIT_LAT-1];   // aligned with q_valid
    wire [XW-1:0] oy_w = oy_sr[WIT_LAT-1];

    // output geometry, from the input shape and the stride
    wire [XW-1:0] out_w_e = stride2 ? ((img_w + 1'b1) >> 1) : img_w;

    // what the counter says, and what the witness says
    wire [31:0] cnt_pix  = (n_ent == {AA_W{1'b0}}) ? 32'd0 : (cur_off / n_ent);
    wire [31:0] wit_pix  = (oy_w * out_w_e) + ox_w;

    //  The check is qualified by `busy`, and finding out why was worth more than
    //  the check itself. Without it, accel_tb reported a mismatch on the FIRST
    //  depthwise op, one cycle before that op had even started - because
    //  `os_q_valid` is broadcast to all five feeders unconditionally (T-9), so
    //  the STEM's last two results advanced this feeder's opix_off while it was
    //  idle. T-9 calls that "functionally correct", and it is, but only because
    //  `start` resets opix_off and wrote_any before the counter next matters.
    //  That is a second coincidence on top of the write mux, and it is not in
    //  the finding. `busy` is exactly "I am in my own op", which is the window
    //  in which this feeder's addresses mean anything.
    always @(posedge clock) begin
        if (rst_n && busy && q_valid && (n_ent != {AA_W{1'b0}})) begin
            if (cnt_pix != wit_pix) begin
                $display("ERROR: %m C-2 writeback address disagrees with line_buffer's own coordinates at time %0t: the q_valid counter says output pixel %0d (cur_off=%0d, n_ent=%0d), the window says (y=%0d, x=%0d) = pixel %0d with out_w=%0d. The whole feature map is shifted from here on.",
                         $time, cnt_pix, cur_off, n_ent, oy_w, ox_w, wit_pix, out_w_e);
                $finish;
            end
            if (cur_off % n_ent != {AA_W{1'b0}}) begin
                $display("ERROR: %m C-2 cur_off = %0d is not a whole multiple of n_ent = %0d at time %0t: the writeback offset has slipped off the pixel grid.",
                         cur_off, n_ent, $time);
                $finish;
            end
        end
    end
`endif

    // ================= busy, including the pipeline drain ===============
    // The counters finish three stages before the last result is written, so
    // `busy` has to outlive them or the caller would start the next layer on
    // top of results still in flight - the same constraint pw_feeder documents.
    //  ---- the drain is DERIVED now (L-1) -----------------------------
    //  It used to be the literal 3'd7, chosen with slack while dw_array was
    //  combinational. Counting from the cycle `layer_done` is high, which is one
    //  cycle after the last counter step:
    //
    //      +1          ... line_buffer emits that pixel's window (win_valid)
    //      +DW_LAT     ... dw_array's valid_out for it
    //      +OS_LAT     ... out_stage's q_valid, i.e. the write
    //
    //  `busy` is high during the layer_done cycle and for `drain` cycles after
    //  it, so DRAIN_CYC = 1 + DW_LAT + OS_LAT covers exactly to the last write.
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
