`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  stem_feeder.v  -  the stem sub-controller, image in to pool out
//
//  Build plan #6, the last opcode. Executes features.0.0:
//  224x224x3 -> 112x112x32, 3x3 stride 2 pad 1, ReLU6.
//
//      counters -> img_buffer -> line_buffer(CIN) -> stem_array
//               -> wgt_buffer -> out_stage -> assemble -> act_buffer
//
//  ---- the rate mismatch, and the stall --------------------------------
//
//  The line buffer consumes one input pixel per cycle and emits a window only
//  where both output coordinates are even, so windows arrive every 2 cycles
//  INSIDE an odd row and not at all on even rows - bursty, not evenly spread.
//  Each window needs ceil(OC/TS) = 4 cycles of compute (DD-016). So the input
//  stream is stalled while a window is swept.
//
//      C      counters; image read issued
//      C+1    pixel arrives; line_buffer fed
//      C+2    win_valid. Weights for oc_tile 0 requested; the input stalls
//      C+3    window LATCHED; oc_tile 0 ENTERS the array
//      C+4-6  oc_tiles 1..3 enter it
//      C+9-12 the array's four results emerge (ST_LAT = 6 stages, L-1)
//      C+11-14 the four q_valid results arrive and are assembled
//      C+15   one full 32-channel entry written
//
//  The sweep is still n_oct cycles - the array accepts one oc_tile per cycle, so
//  pipelining it did not slow the stall down, only moved the results further
//  away. Weights still lead by ONE cycle, because they have to arrive at the
//  array's INPUT with the window, which is unchanged by anything behind it.
//
//  Latching the window matters: line_buffer's registers move on every
//  in_valid, and exactly one more pixel is in flight when the stall begins, so
//  by C+3 the live window has already changed. That extra pixel is legitimate
//  raster order and cannot itself produce a window - if (y,x) had both
//  coordinates odd then (y,x+1) does not - so nothing is missed.
//
//  Cost: 4 stall cycles per window rather than the theoretical 3, because the
//  sweep starts from the latch instead of racing the live window. 50,625 input
//  cycles + 4*12,544 = 100,801, i.e. 0.40 ms against 0.35 for the racing
//  version and 1.76 for one output element per cycle. The extra 0.05 ms buys a
//  stall that is trivially correct.
//
//  ---- one full entry per window ---------------------------------------
//
//  TS=8 channels arrive four times per window, in lanes 8t..8t+7 of the 32-lane
//  out_stage - the same lane-placement trick the depthwise and residual paths
//  use, one quarter instead of one half. Rather than teach act_buffer a
//  quarter write, the four results are ASSEMBLED into a 32-byte register and
//  stored as one full entry. That matches the natural granularity: one output
//  pixel is exactly one pool entry (OC=32), and it keeps act_buffer's write
//  port at the two sizes it already has.
//
//  ---- no multiplier in the address path -------------------------------
//
//  The image address is y*img_w + x, but the walk is raster, so a counter that
//  increments on every REAL pixel is that address. The output address is one
//  entry per window, also a counter.
//
//  Run:  bash scripts/run_sim.sh stem_feeder img_buffer line_buffer stem_array \
//          conv3x3_std wgt_buffer out_stage param_buffer rq_bank bias_add requantize
//============================================================================
module stem_feeder #(
    parameter DATA_W  = 8,
    parameter TS      = 8,      // output channels in parallel (DD-016)
    parameter CIN     = 3,      // image channels
    parameter K       = 3,
    parameter ACC_W   = 26,     // 27 taps: a bound, not a precondition
    parameter POOL_TM = 32,     // channels per pool entry
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter XW      = 9,      // coordinate width: 0..224 inclusive
    parameter MAX_W   = 224,
    parameter OCTW    = 4,      // oc_tile counter width
    parameter IA_W    = 16,     // image address width
    parameter AA_W    = 16,     // pool address width
    parameter WA_W    = 4,      // stem weight buffer address width
    parameter PA_W    = 6,
    parameter BANK_W  = 3,      // clog2(TS), the weight banks
    parameter PBANK_W = 5,      // clog2(POOL_TM), the shared param banks
    parameter WDEPTH  = 8,
    parameter PDEPTH  = 64,

    // Latency of the shared out_stage, which lives in accel_top: acc_valid to
    // q_valid. A PARAMETER because this module's oc_tile tag and drain are both
    // sized from it and out_stage is not instantiated here.
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
    input  wire [XW-1:0]             img_w,     // 224
    input  wire [XW-1:0]             img_h,
    input  wire [OCTW-1:0]           n_oct,     // ceil(OC/TS) = 4
    input  wire [AA_W-1:0]           base_out,

    // ---- weight load: TS banks of CIN*K*K bytes, address = oc_tile ------
    input  wire                      wl_en,
    input  wire [BANK_W-1:0]         wl_bank,
    input  wire [WA_W-1:0]           wl_addr,
    input  wire [CIN*K*K*DATA_W-1:0] wl_data,

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

    // ---- the image region ----------------------------------------------
    output wire                      im_rd_en,
    output wire [IA_W-1:0]           im_addr,
    input  wire [CIN*DATA_W-1:0]     im_data,   // one cycle after im_addr

    // ---- pool write (full entries) --------------------------------------
    output wire                      aw_en,
    output wire                      aw_full,
    output wire [AA_W-1:0]           aw_addr,
    output wire [POOL_TM*DATA_W-1:0] aw_data,

    output wire                      busy,
    output reg                       layer_done
);

    localparam NT       = CIN*K*K;          // 27 taps

    // ---- every depth in this module, derived and in one place ----------
    //  ST_LAT is stem_array's, restated from the same inputs it derives it from:
    //  one registered product stage plus clog2(NT) adder-tree levels, and no
    //  accumulate stage. The simulation check at the bottom MEASURES the real
    //  distance from the sweep to the array's valid_out and names every constant
    //  below if it disagrees - which is what makes restating it safe.
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    // ---- C-7 : the oc_tile index, constrained to its ACTUAL range -------
    //  `oct` is OCTW = 4 bits but only ever reaches 3, and it is used as a
    //  VARIABLE index into acc_wide and asm - so the tool built a 16-position
    //  decoder for each, four times wider than anything that can happen. C-7
    //  measured the cost: stem_feeder was the largest feeder at 8,968 LUTs
    //  against pw_feeder's 724, for a path carrying no DSPs at all against one
    //  carrying 512.
    //
    //  The bound is STRUCTURAL, not a shape field. The assembly of `asm` needs
    //  the TS-channel quarters to tile a POOL_TM-channel entry exactly - that is
    //  C-12's equality, n_oct*TS == POOL_TM - so the number of oc_tiles the stem
    //  can ever sweep is POOL_TM/TS, full stop. Indexing with that many bits is
    //  not an optimisation, it is saying what the counter actually is.
    localparam N_OCT_MAX = POOL_TM / TS;            // 4
    localparam OCT_IDX_W = clog2(N_OCT_MAX);        // 2

    localparam ST_LAT    = 1 + clog2(NT);           // 6
    localparam OCT_ARR   = ST_LAT;                  // oct -> array output
    localparam OCT_WR    = ST_LAT + OS_LAT;         // oct -> q_valid
    //  Drain: `busy` already covers the sweep itself via `sweeping`, and `adv`
    //  can only fire inside a sweep on its LAST cycle (see `adv` above), so
    //  layer_done can coincide with the end of a sweep but never its middle.
    //  After `sweeping` drops, the longest anything is still in flight is the
    //  array, the requantize stage, and the one cycle wr_go adds.
    localparam DRAIN_CYC = ST_LAT + OS_LAT + 1;     // 12 at OS_LAT=5
    localparam DRAIN_W   = clog2(DRAIN_CYC + 1);    // 4

    // ================= stage 0 : the raster walk ========================
    reg [XW-1:0]  cy, cx;
    reg [IA_W-1:0] img_off;                 // y*img_w + x, by accumulation
    reg            run;

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
    reg [XW-1:0]   img_w_q, img_h_q;
    reg [OCTW-1:0] n_oct_q;
    reg [AA_W-1:0] base_out_q;

    always @(posedge clock) begin
        if (!rst_n) begin
            img_w_q <= {XW{1'b0}};  img_h_q <= {XW{1'b0}};
            n_oct_q <= {OCTW{1'b0}};  base_out_q <= {AA_W{1'b0}};
        end else if (start) begin
            img_w_q <= img_w;  img_h_q <= img_h;
            n_oct_q <= n_oct;  base_out_q <= base_out;
        end
    end

    wire is_real = (cy < img_h_q) && (cx < img_w_q);
    wire last_x  = (cx == img_w_q);
    wire last_y  = last_x && (cy == img_h_q);

    // the stall: no advance while a window is being swept
    reg              sweeping;
    reg [OCTW-1:0]   oct;
    wire             last_sweep = sweeping && (oct == n_oct_q - 1'b1);
    wire             win_valid;
    //  ---- C-1 : there is NO back-pressure path, and that is load-bearing --
    //
    //  A `win_valid` arriving while `sweeping` is high hits the `!sweeping`
    //  guard below and is DISCARDED - no latch, no stall back into line_buffer,
    //  no error. Nothing anywhere in this module can push back on the window
    //  generator.
    //
    //  That is correct today for one reason only: the stem is always stride 2,
    //  so line_buffer emits a window every OTHER column and the sweep of
    //  n_oct = 4 tiles always finishes inside that gap. The dependency is on
    //  `stride2` being tied to 1'b1 three lines from here, in a different
    //  module, with nothing connecting the two facts.
    //
    //  If the stem ever becomes stride 1, windows arrive every cycle, the sweep
    //  cannot keep up, and windows are dropped silently - a decimated feature
    //  map, not an error. The check below is what says so. A REAL fix needs a
    //  stall output back into line_buffer, which is an architecture change and
    //  is not in scope here; what is in scope is that the assumption stops being
    //  invisible.
    wire             adv = run && ((!sweeping && !win_valid) || last_sweep);

    always @(posedge clock) begin
        if (!rst_n) begin
            cy <= {XW{1'b0}}; cx <= {XW{1'b0}}; img_off <= {IA_W{1'b0}};
            run <= 1'b0; layer_done <= 1'b0;
        end else if (start) begin
            cy <= {XW{1'b0}}; cx <= {XW{1'b0}}; img_off <= {IA_W{1'b0}};
            //  C-8: n_oct is guarded too now. addr_gen, res_feeder and
            //  gap_feeder refuse a zero-sized layer; this module checked img_w
            //  and img_h but not n_oct, so n_oct = 0 made `last_sweep` compare
            //  against -1, the sweep never ended, and the feeder wrote garbage
            //  into the pool with `busy` asserted - no hang, no error, a
            //  plausible feature map. The upper bound is C-7's structural one.
            run <= (img_w != {XW{1'b0}}) && (img_h != {XW{1'b0}}) &&
                   (n_oct != {OCTW{1'b0}}) && (n_oct <= N_OCT_MAX[OCTW-1:0]);
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            if (adv) begin
                // C-12: ONE assignment to img_off per path. This used to be two
                // - `if (is_real) img_off <= img_off + 1` here, and a reset to
                // zero inside the `last_y` branch below - which both fire on the
                // last real pixel of a layer and resolve by last-assignment-wins.
                // The result was correct and the mechanism was invisible: nothing
                // in the code said the ordering mattered, so any reordering of
                // those two statements would have silently changed behaviour.
                if (last_y)       img_off <= {IA_W{1'b0}};
                else if (is_real) img_off <= img_off + 1'b1;

                if (last_y) begin
                    run <= 1'b0;
                    layer_done <= 1'b1;
                    cy <= {XW{1'b0}}; cx <= {XW{1'b0}};
                end else if (last_x) begin
                    cy <= cy + 1'b1;  cx <= {XW{1'b0}};
                end else begin
                    cx <= cx + 1'b1;
                end
            end
        end
    end

    assign im_rd_en = adv && is_real;
    assign im_addr  = img_off;

    // ================= stage 1 : feed the window generator ==============
    reg            v_d1, real_d1;
    reg [XW-1:0]   y_d1, x_d1;

    always @(posedge clock) begin
        if (!rst_n)     begin v_d1 <= 1'b0; real_d1 <= 1'b0;
                              y_d1 <= {XW{1'b0}}; x_d1 <= {XW{1'b0}}; end
        else if (start) begin v_d1 <= 1'b0; real_d1 <= 1'b0; end
        else begin
            v_d1    <= adv;
            real_d1 <= is_real;
            y_d1    <= cy;
            x_d1    <= cx;
        end
    end

    wire [CIN*DATA_W-1:0] lb_in = real_d1 ? im_data : {CIN*DATA_W{1'b0}};

    wire [K*K*CIN*DATA_W-1:0] win;
    wire [XW-1:0]             out_x, out_y;

    line_buffer #(
        .DATA_W(DATA_W), .TC(CIN), .K(K), .MAX_W(MAX_W), .XW(XW)
    ) u_lb (
        .clock(clock), .rst_n(rst_n),
        .in_valid(v_d1), .in_data(lb_in), .in_x(x_d1), .in_y(y_d1),
        .stride2(1'b1),                      // the stem is always stride 2
        .win(win), .win_valid(win_valid), .out_x(out_x), .out_y(out_y)
    );

    // ================= the oc_tile sweep =================================
    // The window is LATCHED, because line_buffer's registers move on the one
    // in-flight pixel that arrives after the stall begins.
    reg [K*K*CIN*DATA_W-1:0] win_q;

    // ---- win_q has a SYNCHRONOUS reset, on purpose (DD-020) --------------
    //
    //  Split out of the state machine below, which keeps its asynchronous reset.
    //  This one register drives all 216 A inputs of the stem's conv3x3_std DSPs,
    //  and it was 6,480 of the design's 10,940 DPIR-2 violations - 59% - all
    //  saying the same thing:
    //
    //      DSP ... input pin ... is connected to registers with an asynchronous
    //      reset. This is preventing the possibility of merging these registers
    //      in to the DSP Block since the DSP block registers only possess
    //      synchronous reset capability.
    //
    //  `rst_n` arriving here is already the two-flop synchronised reset that
    //  accel_top produces (T-5), so using it synchronously is not a weakening -
    //  it is the same reset, sampled the way the DSP can accept.
    //
    //  This is the measured half of DD-020, and it sits on the design's critical
    //  path: win_q -> acc_q is the worst path in every run so far.
    always @(posedge clock) begin
        if (!rst_n)                       win_q <= {K*K*CIN*DATA_W{1'b0}};
        else if (win_valid && !sweeping)  win_q <= win;
    end

    always @(posedge clock) begin
        if (!rst_n) begin
            sweeping <= 1'b0; oct <= {OCTW{1'b0}};
        end else if (start) begin
            sweeping <= 1'b0; oct <= {OCTW{1'b0}};
        end else if (win_valid && !sweeping) begin
            sweeping <= 1'b1;
            oct      <= {OCTW{1'b0}};
        end else if (sweeping) begin
            if (oct == n_oct_q - 1'b1) sweeping <= 1'b0;
            else                     oct      <= oct + 1'b1;
        end
    end

    // Weights lead the compute by one cycle: the read issued alongside
    // win_valid returns oc_tile 0's weights exactly when the sweep starts.
    wire [WA_W-1:0] wa_oct = win_valid && !sweeping ? {WA_W{1'b0}}
                                                    : (oct + 1'b1);
    wire [TS*NT*DATA_W-1:0] wk;

    wgt_buffer #(
        .DATA_W(DATA_W), .TM(TS), .TN(NT),
        .DEPTH(WDEPTH), .ADDR_W(WA_W), .BANK_W(BANK_W)
    ) u_wgt (
        .clock(clock),
        .wr_en(wl_en), .wr_bank(wl_bank), .wr_addr(wl_addr), .wr_data(wl_data),
        .rd_en((win_valid && !sweeping) || sweeping),
        .rd_addr(wa_oct),
        .rd_data(wk)
    );

    wire [TS*ACC_W-1:0] acc;
    wire                arr_valid;

    stem_array #(.DATA_W(DATA_W), .TS(TS), .CIN(CIN), .K(K), .ACC_W(ACC_W)) u_arr (
        .clock(clock), .rst_n(rst_n),
        .valid(sweeping),
        .win(win_q), .wk(wk),
        .acc(acc), .valid_out(arr_valid)
    );

    // ---- the oc_tile tag, now that the array has latency ----------------
    //  `oct` used to serve three places directly or one cycle apart, because the
    //  array was combinational: the lane placement below, and the `asm` fold two
    //  cycles later. With ST_LAT stages in between they are OCT_ARR and OCT_WR
    //  apart, so there is one shift register and two taps off it.
    //
    //  Pushed every cycle rather than only while sweeping: the array free-runs,
    //  so the tag has to travel at the same rate as the data inside it, exactly
    //  as in pw_feeder.
    reg [OCTW-1:0] oct_sr [0:OCT_WR-1];

    integer os;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (os = 0; os < OCT_WR; os = os + 1) oct_sr[os] <= {OCTW{1'b0}};
        end else begin
            oct_sr[0] <= oct;
            for (os = 1; os < OCT_WR; os = os + 1) oct_sr[os] <= oct_sr[os-1];
        end
    end

    wire [OCTW-1:0] oct_arr = oct_sr[OCT_ARR-1];   // aligned with arr_valid
    wire [OCTW-1:0] oct_wr  = oct_sr[OCT_WR-1];    // aligned with q_valid

    // place the TS accumulators in lanes oct*TS .. +TS-1, using the tag that
    // travelled with them through the array
    reg [POOL_TM*ACC_W-1:0] acc_wide;
    integer L;
    always @* begin
        acc_wide = {POOL_TM*ACC_W{1'b0}};
        for (L = 0; L < TS; L = L + 1)
            acc_wide[(oct_arr[OCT_IDX_W-1:0]*TS + L)*ACC_W +: ACC_W] = acc[L*ACC_W +: ACC_W];
    end

    // OC <= POOL_TM for the stem, so every oc_tile shares parameter entry 0
    wire [PA_W-1:0] param_addr = {PA_W{1'b0}};

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    // was `= sweeping`, i.e. the array had no latency. A WIRE from the array's
    // own valid output now, so the latency cannot be asserted wrongly.
    assign os_acc_valid  = arr_valid;
    assign os_param_addr = param_addr;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

`ifndef SYNTHESIS
    // ---- C-1: a dropped window, reported by name -------------------------
    //  Fires when line_buffer presents a window the sweep cannot accept. Fatal:
    //  there is no correct continuation - the window is gone and the output map
    //  is short a pixel, so continuing would produce a shifted tensor that looks
    //  like activations. Compare C-12's asm check, which is also fatal, against
    //  L-13's residual report, which is not.
    //
    //  Unreachable while the stem is stride 2. That is the point: this is the
    //  witness for an assumption held three lines away in another module.
    always @(posedge clock) begin
        if (rst_n && win_valid && sweeping) begin
            $display("ERROR: %m C-1 line_buffer presented a window at time %0t while the oc_tile sweep was still running (oct=%0d of n_oct=%0d). There is no back-pressure path, so this window is DISCARDED and the output feature map loses a pixel. This is unreachable at stride 2; if the stem is now stride 1 the sweep needs a real stall back into line_buffer.",
                     $time, oct, n_oct_q);
            $finish;
        end
    end
`endif

    // ================= assemble four quarters into one entry ============
    // Every quarter folds into the same register; the write is delayed one
    // cycle so the last fold has landed before the entry is stored.
    reg [POOL_TM*DATA_W-1:0] asm;
    integer B;
    always @(posedge clock) begin
        if (!rst_n) asm <= {POOL_TM*DATA_W{1'b0}};
        else if (q_valid)
            for (B = 0; B < TS; B = B + 1)
                asm[(oct_wr[OCT_IDX_W-1:0]*TS + B)*DATA_W +: DATA_W] <=
                    q[(oct_wr[OCT_IDX_W-1:0]*TS + B)*DATA_W +: DATA_W];
    end

    wire entry_done = q_valid && (oct_wr == n_oct_q - 1'b1);

`ifndef SYNTHESIS
    //  C-12: `asm` is never cleared between entries - each quarter overwrites its
    //  own TS bytes and the register is stored whole. That is safe if and only if
    //  the quarters between them cover ALL of it, i.e. n_oct*TS == POOL_TM. Today
    //  they do exactly (4*8 = 32), so no byte of a stored entry is ever left over
    //  from the previous pixel.
    //
    //  n_oct is a RUNTIME input, so this cannot be an elaboration guard. If a
    //  future layer shape ever makes n_oct*TS smaller than POOL_TM, the top
    //  channels of every stem output would silently be the previous pixel's -
    //  which looks like a plausible feature map, not like a bug. Checked once per
    //  entry, where it is cheap and where the value being stored is the evidence.
    always @(posedge clock) begin
        if (rst_n && entry_done && ((n_oct_q * TS) != POOL_TM)) begin
            $display("ERROR: %m C-12 n_oct*TS = %0d but POOL_TM = %0d at time %0t. `asm` is only ever partially written and is stored whole, so %0d bytes of this entry are left over from the previous pixel. Either clear asm on the first quarter or fix the shape.",
                     n_oct_q * TS, POOL_TM, $time, POOL_TM - (n_oct_q * TS));
            $finish;
        end
    end
`endif

    reg            wr_go;
    reg [AA_W-1:0] out_cnt;

    always @(posedge clock) begin
        if (!rst_n) begin
            wr_go <= 1'b0; out_cnt <= {AA_W{1'b0}};
        end else if (start) begin
            wr_go <= 1'b0; out_cnt <= {AA_W{1'b0}};
        end else begin
            wr_go <= entry_done;
            if (wr_go) out_cnt <= out_cnt + 1'b1;
        end
    end

    assign aw_en   = wr_go;
    assign aw_full = 1'b1;                  // one output pixel = one entry
    assign aw_addr = base_out_q + out_cnt;
    assign aw_data = asm;

    // ---- C-2: the witness that was being thrown away ---------------------
    //
    //  Same finding as in dw_feeder, and the same fix. line_buffer emits
    //  out_x / out_y in OUTPUT coordinates with every window; they are declared,
    //  connected and never read, while `out_cnt` - a free-running count of
    //  entry_done pulses - is what actually forms the write address. One
    //  spurious or missing win_valid shifts the whole 112x112 feature map by a
    //  pixel and every value in it stays a plausible activation.
    //
    //  The alignment here is longer than the depthwise one because the sweep
    //  sits in the middle: out_x/out_y are valid with win_valid, the window is
    //  latched one cycle later, the sweep runs n_oct cycles, out_stage adds
    //  OS_LAT, and the write is one cycle after entry_done.
    //
    //  ---- and why the shape of this check had to change in Phase 2c ----
    //
    //  Phase 1 held the coordinates in `ox_h` from the win_q latch and copied
    //  them at entry_done, which worked while the array was combinational: the
    //  distance from the latch to entry_done was n_oct + OS_LAT = 6 cycles, and
    //  the next window could not be latched before then.
    //
    //  With ST_LAT = 6 stages in the array that distance is
    //  n_oct + ST_LAT + OS_LAT = 12, while the next window can be latched as
    //  soon as 3 cycles after the sweep ends. So `ox_h` is overwritten LONG
    //  before entry_done and the hold is simply wrong now.
    //
    //  The fix is to stop holding and start travelling: the coordinates ride the
    //  SAME shift register as the oc_tile tag, so whatever `oct_wr` belongs to,
    //  these belong to as well - by construction, at any array latency. `ox_live`
    //  is what gets pushed, and it is correct for every cycle of a sweep because
    //  the next latch cannot happen until the sweep has ended.
    //
    //  Inside `ifndef SYNTHESIS`, so the datapath is untouched.
`ifndef SYNTHESIS
    reg [XW-1:0] ox_live, oy_live;
    always @(posedge clock) begin
        if (!rst_n) begin
            ox_live <= {XW{1'b0}}; oy_live <= {XW{1'b0}};
        end else if (win_valid && !sweeping) begin
            ox_live <= out_x; oy_live <= out_y;    // captured with win_q
        end
    end

    reg [XW-1:0] ox_sr [0:OCT_WR-1];
    reg [XW-1:0] oy_sr [0:OCT_WR-1];

    integer xs;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (xs = 0; xs < OCT_WR; xs = xs + 1) begin
                ox_sr[xs] <= {XW{1'b0}};
                oy_sr[xs] <= {XW{1'b0}};
            end
        end else begin
            ox_sr[0] <= ox_live;
            oy_sr[0] <= oy_live;
            for (xs = 1; xs < OCT_WR; xs = xs + 1) begin
                ox_sr[xs] <= ox_sr[xs-1];
                oy_sr[xs] <= oy_sr[xs-1];
            end
        end
    end

    // aligned with q_valid, exactly like oct_wr; entry_done IS a q_valid, so
    // capturing there gives the coordinates of the entry about to be written
    reg [XW-1:0] ox_e, oy_e;
    always @(posedge clock) begin
        if (!rst_n) begin
            ox_e <= {XW{1'b0}}; oy_e <= {XW{1'b0}};
        end else if (entry_done) begin
            ox_e <= ox_sr[OCT_WR-1];
            oy_e <= oy_sr[OCT_WR-1];
        end
    end

    // ---- ST_LAT is restated here, so MEASURE it (L-1, L-2) --------------
    //  The oc_tile tag, the witness depth above and the drain are all sized from
    //  ST_LAT, and a wrong value has no width mismatch and no elaboration error.
    //  Time the real distance from a sweep cycle to the array's valid_out. One
    //  measurement per layer, then stop.
    reg [7:0] lat_cnt;
    reg       lat_arm, lat_seen;
    always @(posedge clock) begin
        if (!rst_n || start) begin
            lat_arm  <= 1'b0;
            lat_seen <= 1'b0;
            lat_cnt  <= 8'd0;
        end else if (!lat_seen) begin
            if (!lat_arm) begin
                if (sweeping) begin
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
        if (rst_n && lat_arm && !lat_seen && arr_valid && (lat_cnt != ST_LAT[7:0])) begin
            $display("ERROR: %m L-1 stem_array answered %0d cycles after the window entered it, but this module's ST_LAT says %0d at time %0t. The oc_tile tag (arr %0d, wr %0d) and the drain (%0d) are all sized from ST_LAT, so they are wrong too.",
                     lat_cnt, ST_LAT, $time, OCT_ARR, OCT_WR, DRAIN_CYC);
            $finish;
        end
    end

    wire [XW-1:0] out_w_e = (img_w_q + 1'b1) >> 1;  // the stem is always stride 2
    wire [31:0]   wit_cnt = (oy_e * out_w_e) + ox_e;

    //  Qualified by `busy` for the reason dw_feeder's copy documents: os_q_valid
    //  is broadcast to every feeder (T-9), so an idle feeder's output pipeline
    //  moves on another op's results.
    always @(posedge clock) begin
        if (rst_n && busy && wr_go) begin
            if ({16'd0, out_cnt} != wit_cnt) begin
                $display("ERROR: %m C-2 writeback address disagrees with line_buffer's own coordinates at time %0t: the entry counter says output pixel %0d, the window says (y=%0d, x=%0d) = pixel %0d with out_w=%0d. The whole feature map is shifted from here on.",
                         $time, out_cnt, oy_e, ox_e, wit_cnt, out_w_e);
                $finish;
            end
        end
        // C-1's counterpart: a window arriving while the sweep is busy is
        // dropped by the !sweeping guard, with no latch, no stall and no error.
        // Correct today only because stride2 is tied to 1 three lines away, so
        // the one in-flight pixel cannot produce a window. Reported here so a
        // future stride-1 stem is loud rather than silently lossy.
        if (rst_n && busy && win_valid && sweeping) begin
            $display("ERROR: %m C-1 a window arrived while the oc_tile sweep was busy at time %0t and has been DISCARDED. There is no back-pressure path into line_buffer. This is only unreachable while the stem is stride 2.",
                     $time);
            $finish;
        end
    end
`endif

    // ================= busy, including the drain ========================
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
    assign busy = run || layer_done || sweeping || (drain != {DRAIN_W{1'b0}});

endmodule

`default_nettype wire
