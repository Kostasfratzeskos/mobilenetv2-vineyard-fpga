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
//      C     counters; image read issued
//      C+1   pixel arrives; line_buffer fed
//      C+2   win_valid. Weights for oc_tile 0 requested; the input stalls
//      C+3   window LATCHED; oc_tile 0 computed -> out_stage
//      C+4-6 oc_tiles 1..3
//      C+5-8 the four q_valid results arrive and are assembled
//      C+8   one full 32-channel entry written
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
    parameter ACC_W   = 21,     // 27 taps: a bound, not a precondition
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
    parameter PDEPTH  = 64
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

    // ================= stage 0 : the raster walk ========================
    reg [XW-1:0]  cy, cx;
    reg [IA_W-1:0] img_off;                 // y*img_w + x, by accumulation
    reg            run;

    wire is_real = (cy < img_h) && (cx < img_w);
    wire last_x  = (cx == img_w);
    wire last_y  = last_x && (cy == img_h);

    // the stall: no advance while a window is being swept
    reg              sweeping;
    reg [OCTW-1:0]   oct;
    wire             last_sweep = sweeping && (oct == n_oct - 1'b1);
    wire             win_valid;
    wire             adv = run && ((!sweeping && !win_valid) || last_sweep);

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            cy <= {XW{1'b0}}; cx <= {XW{1'b0}}; img_off <= {IA_W{1'b0}};
            run <= 1'b0; layer_done <= 1'b0;
        end else if (start) begin
            cy <= {XW{1'b0}}; cx <= {XW{1'b0}}; img_off <= {IA_W{1'b0}};
            run <= (img_w != {XW{1'b0}}) && (img_h != {XW{1'b0}});
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;
            if (adv) begin
                if (is_real) img_off <= img_off + 1'b1;
                if (last_y) begin
                    run <= 1'b0;
                    layer_done <= 1'b1;
                    cy <= {XW{1'b0}}; cx <= {XW{1'b0}}; img_off <= {IA_W{1'b0}};
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

    always @(posedge clock or negedge rst_n) begin
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

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            sweeping <= 1'b0; oct <= {OCTW{1'b0}}; win_q <= {K*K*CIN*DATA_W{1'b0}};
        end else if (start) begin
            sweeping <= 1'b0; oct <= {OCTW{1'b0}};
        end else if (win_valid && !sweeping) begin
            win_q    <= win;
            sweeping <= 1'b1;
            oct      <= {OCTW{1'b0}};
        end else if (sweeping) begin
            if (oct == n_oct - 1'b1) sweeping <= 1'b0;
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

    stem_array #(.DATA_W(DATA_W), .TS(TS), .CIN(CIN), .K(K), .ACC_W(ACC_W)) u_arr (
        .win(win_q), .wk(wk), .acc(acc)
    );

    // place the TS accumulators in lanes oct*TS .. +TS-1
    reg [POOL_TM*ACC_W-1:0] acc_wide;
    integer L;
    always @* begin
        acc_wide = {POOL_TM*ACC_W{1'b0}};
        for (L = 0; L < TS; L = L + 1)
            acc_wide[(oct*TS + L)*ACC_W +: ACC_W] = acc[L*ACC_W +: ACC_W];
    end

    // OC <= POOL_TM for the stem, so every oc_tile shares parameter entry 0
    wire [PA_W-1:0] param_addr = {PA_W{1'b0}};

    // The requantize stage itself is in accel_top; this drives it.
    assign os_acc        = acc_wide;
    assign os_acc_valid  = sweeping;
    assign os_param_addr = param_addr;

    wire [POOL_TM*DATA_W-1:0] q       = os_q;
    wire                      q_valid = os_q_valid;

    // ================= assemble four quarters into one entry ============
    reg [OCTW-1:0] oct_d1, oct_d2;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin oct_d1 <= {OCTW{1'b0}}; oct_d2 <= {OCTW{1'b0}}; end
        else        begin oct_d1 <= oct;          oct_d2 <= oct_d1;       end
    end

    // Every quarter folds into the same register; the write is delayed one
    // cycle so the last fold has landed before the entry is stored.
    reg [POOL_TM*DATA_W-1:0] asm;
    integer B;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) asm <= {POOL_TM*DATA_W{1'b0}};
        else if (q_valid)
            for (B = 0; B < TS; B = B + 1)
                asm[(oct_d2*TS + B)*DATA_W +: DATA_W] <=
                    q[(oct_d2*TS + B)*DATA_W +: DATA_W];
    end

    wire entry_done = q_valid && (oct_d2 == n_oct - 1'b1);

    reg            wr_go;
    reg [AA_W-1:0] out_cnt;

    always @(posedge clock or negedge rst_n) begin
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
    assign aw_addr = base_out + out_cnt;
    assign aw_data = asm;

    // ================= busy, including the drain ========================
    reg [3:0] drain;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n)             drain <= 4'd0;
        else if (start)         drain <= 4'd0;
        else if (layer_done)    drain <= 4'd15;
        else if (drain != 4'd0) drain <= drain - 4'd1;
    end

    // `layer_done` is in here for a reason that only shows up at the top level.
    // It pulses in the SAME cycle `run` drops, but `drain` is not loaded until
    // the edge at the END of that cycle - so without it there is exactly one
    // cycle where run=0 and drain=0 and `busy` reads low. top_seq leaves S_RUN
    // on the first !busy it sees, so that one-cycle hole made it start the next
    // op's weight load while this one still had its whole drain to go. Found by
    // accel_tb; invisible to a standalone testbench, which waits on layer_done
    // rather than on busy falling.
    assign busy = run || layer_done || sweeping || (drain != 4'd0);

endmodule

`default_nettype wire
