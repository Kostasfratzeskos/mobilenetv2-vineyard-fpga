`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  accel_top.v  -  the whole accelerator
//
//  One sequencer, six feeders, ONE requantize stage, ONE activation pool.
//  This is the module that makes the sharing real: out_stage was factored out
//  so that five feeders could share it, but until this file existed each one
//  still instantiated its own and the DSP saving was theoretical.
//
//  ---- why a mux and not six engines -----------------------------------
//
//  top_seq is strictly sequential: it starts one op, waits for busy to fall,
//  and only then decodes the next. So at most one feeder is live at any time,
//  and everything downstream of the accumulators can be a single instance
//  that the opcode points at:
//
//      op_code --+--> which feeder gets op_start
//                +--> whose os_acc drives the shared out_stage
//                +--> whose a_* drives the pool read port
//                +--> whose aw_* drives the pool write port
//
//  os_q goes back to every feeder unconditionally. An idle feeder will happily
//  requantize whatever is on the bus and assert its own aw_en, but its write
//  never reaches the pool because the write mux is selected by opcode - and
//  its address counter is reset by `start` before it next matters. Broadcasting
//  is cheaper than gating and the mux already provides the isolation.
//
//  ---- what the program now has to get right ---------------------------
//
//  `act` and `relu6_qmax` used to be hardwired inside three feeders: res_feeder
//  and gap_feeder forced ACT_NONE, stem_feeder forced ACT_RELU6. With one
//  shared stage they come from the instruction word instead, so those are no
//  longer properties of the RTL - they are obligations on gen_program.py:
//
//      STEM    act=1, qmax=127     (the stem is a ReLU6 layer)
//      PW      act per layer
//      DW      act per layer
//      RES_ADD act=0               (the residual add must not clamp to ReLU6)
//      GAP     act=0
//      LINEAR  act=0               (and it bypasses out_stage entirely)
//
//  The generator already emits exactly this - res/gap/linear are hardcoded
//  act=0 and the manifest marks the stem relu6 with qmax 127 - and
//  accel_tb checks it against the real program rather than trusting it.
//
//  ---- the two feeders that are not on the shared stage -----------------
//
//  LINEAR does not use out_stage. It runs on pw_feeder like any 1x1 conv
//  (n_pix=1, n_oc=1, n_ic=80) but its tail is logit_out, which requantizes
//  4 channels to int16 instead of 32 to int8 and picks the argmax. Its
//  acc_valid is gated by the opcode so that a PW op cannot disturb it.
//
//  The stem reads img_buffer, not the pool - it is the only op whose input is
//  the image - so the pool read mux simply never selects it.
//
//  ---- the load side ----------------------------------------------------
//
//  The DMA does not exist yet. top_seq raises ld_req with (offset, bytes,
//  pchan) and waits for ld_done; this module exposes that handshake and the
//  write ports of all four memories (three weight buffers of different shapes,
//  plus the shared parameter banks) so that whatever answers - a testbench
//  today, an AXI master later - can fill them. The three weight buffers cannot
//  be merged: their word widths are TN*8=128, K*K*8=72 and CIN*K*K*8=216 bits.
//
//  Run:  bash scripts/run_sim.sh accel accel_top top_seq \
//          pw_feeder pw_out dw_feeder res_feeder gap_feeder stem_feeder \
//          logit_out out_stage pe_array mac_lane conv1x1 dwconv3x3 \
//          conv3x3_std dw_array stem_array line_buffer avgpool addr_gen \
//          wgt_buffer act_buffer img_buffer param_buffer rq_bank \
//          bias_add requantize
//============================================================================
module accel_top #(
    // ---- datapath geometry ---------------------------------------------
    parameter DATA_W  = 8,
    parameter TM      = 32,     // pointwise lanes / channels per pool entry
    parameter TN      = 16,     // channels per pool read word
    parameter TC      = 16,     // depthwise channels in parallel (DD-014)
    parameter TS      = 8,      // stem channels in parallel (DD-016)
    parameter TSLOG   = 3,      // clog2(TS) -- keep in step with TS
    parameter CIN     = 3,
    parameter K       = 3,
    parameter ACC_W   = 21,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,
    parameter SEL_W   = 1,      // clog2(TM/TN)

    // ---- memories -------------------------------------------------------
    parameter ADEPTH  = 50176,  // activation pool peak, from the allocator
    parameter AA_W    = 16,
    parameter IDEPTH  = 50176,  // 224*224 image pixels
    parameter IA_W    = 16,
    parameter PW_WDEPTH = 1024, parameter PW_WA_W = 10,
    parameter DW_WDEPTH = 64,   parameter DW_WA_W = 6,
    parameter ST_WDEPTH = 8,    parameter ST_WA_W = 4,
    parameter PDEPTH  = 64,     parameter PA_W   = 6,

    // ---- widths ---------------------------------------------------------
    parameter PIX_W   = 16,
    parameter OCT_W   = 8,
    parameter ICT_W   = 8,
    parameter SLW     = 8,
    parameter GRPW    = 6,
    parameter OCTW    = 4,
    parameter XW_DW   = 8,      // depthwise coordinates, MAX_W = 112
    parameter XW_ST   = 9,      // stem coordinates, 0..224 inclusive
    parameter BANK_W  = 5,      // clog2(TM), the pointwise + parameter banks
    parameter DW_BANK_W = 4,    // clog2(TC)
    parameter ST_BANK_W = 3,    // clog2(TS)

    // ---- program --------------------------------------------------------
    parameter PW_W    = 32,
    parameter PGA_W   = 9,
    parameter PROG_DEPTH = 512,
    parameter NI_W    = 8,
    parameter GAP_CYC = 4,

    // ---- classifier ------------------------------------------------------
    parameter NLOG    = 4,
    parameter IDX_W   = 2,
    parameter LOG_W   = 16
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- run control -----------------------------------------------------
    input  wire                      start,
    input  wire [NI_W-1:0]           n_instr,

    // ---- program load ----------------------------------------------------
    input  wire                      pg_en,
    input  wire [PGA_W-1:0]          pg_addr,
    input  wire [PW_W-1:0]           pg_data,

    // ---- image load ------------------------------------------------------
    input  wire                      im_wr_en,
    input  wire [IA_W-1:0]           im_wr_addr,
    input  wire [CIN*DATA_W-1:0]     im_wr_data,

    // ---- weight fetch handshake (the DMA answers) ------------------------
    output wire                      ld_req,
    output wire [23:0]               ld_off,
    output wire [19:0]               ld_bytes,
    output wire [15:0]               ld_pchan,
    input  wire                      ld_done,

    // ---- weight write ports, one per buffer shape ------------------------
    input  wire                      pw_wl_en,
    input  wire [BANK_W-1:0]         pw_wl_bank,
    input  wire [PW_WA_W-1:0]        pw_wl_addr,
    input  wire [TN*DATA_W-1:0]      pw_wl_data,

    input  wire                      dw_wl_en,
    input  wire [DW_BANK_W-1:0]      dw_wl_bank,
    input  wire [DW_WA_W-1:0]        dw_wl_addr,
    input  wire [K*K*DATA_W-1:0]     dw_wl_data,

    input  wire                      st_wl_en,
    input  wire [ST_BANK_W-1:0]      st_wl_bank,
    input  wire [ST_WA_W-1:0]        st_wl_addr,
    input  wire [CIN*K*K*DATA_W-1:0] st_wl_data,

    // ---- the shared parameter banks --------------------------------------
    input  wire                      pl_en,
    input  wire [BANK_W-1:0]         pl_bank,
    input  wire [PA_W-1:0]           pl_addr,
    input  wire signed [BIAS_W-1:0]  pl_bias,
    input  wire signed [M0_W-1:0]    pl_m0,
    input  wire [SHIFT_W-1:0]        pl_shift,

    // ---- the classifier's own four parameter sets ------------------------
    input  wire                      lg_pl_en,
    input  wire [IDX_W-1:0]          lg_pl_idx,
    input  wire signed [BIAS_W-1:0]  lg_pl_bias,
    input  wire signed [M0_W-1:0]    lg_pl_m0,
    input  wire [SHIFT_W-1:0]        lg_pl_shift,

    // ---- the answer -------------------------------------------------------
    output wire [NLOG*LOG_W-1:0]     logits,
    output wire                      logits_valid,
    output wire [IDX_W-1:0]          argmax,
    output wire                      argmax_valid,

    // ---- status -----------------------------------------------------------
    output wire [NI_W-1:0]           pc,
    output wire                      running,
    output wire                      done,
    output wire                      tag_error
);

    // ================= opcodes ==========================================
    localparam [3:0] OP_STEM   = 4'd1,
                     OP_PW     = 4'd2,
                     OP_DW     = 4'd3,
                     OP_RES    = 4'd4,
                     OP_GAP    = 4'd5,
                     OP_LINEAR = 4'd6;

    // ================= the decoded instruction ==========================
    wire                     op_start;
    wire [3:0]               op_code;
    wire [7:0]               op_img_w, op_img_h;
    wire                     op_stride2, op_act;
    wire signed [7:0]        op_qmax;
    wire [15:0]              op_n_pix;
    wire [7:0]               op_n_oc, op_n_ic, op_n_grp;
    wire [7:0]               op_n_ent_in, op_n_ent_out;
    wire [15:0]              op_base_in, op_base_out, op_base_saved;
    wire                     op_busy;

    top_seq #(
        .PW_W(PW_W), .PGA_W(PGA_W), .PROG_DEPTH(PROG_DEPTH),
        .NI_W(NI_W), .GAP_CYC(GAP_CYC)
    ) u_seq (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_instr(n_instr),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .ld_req(ld_req), .ld_off(ld_off), .ld_bytes(ld_bytes),
        .ld_pchan(ld_pchan), .ld_done(ld_done),
        .op_start(op_start), .op_code(op_code),
        .op_img_w(op_img_w), .op_img_h(op_img_h),
        .op_stride2(op_stride2), .op_act(op_act), .op_qmax(op_qmax),
        .op_n_pix(op_n_pix), .op_n_oc(op_n_oc), .op_n_ic(op_n_ic),
        .op_n_grp(op_n_grp),
        .op_n_ent_in(op_n_ent_in), .op_n_ent_out(op_n_ent_out),
        .op_base_in(op_base_in), .op_base_out(op_base_out),
        .op_base_saved(op_base_saved),
        .op_busy(op_busy),
        .pc(pc), .running(running), .done(done)
    );

    // ================= which feeder is this op's =========================
    wire sel_stem = (op_code == OP_STEM);
    wire sel_pw   = (op_code == OP_PW);
    wire sel_dw   = (op_code == OP_DW);
    wire sel_res  = (op_code == OP_RES);
    wire sel_gap  = (op_code == OP_GAP);
    wire sel_lin  = (op_code == OP_LINEAR);
    wire sel_pwf  = sel_pw | sel_lin;     // pw_feeder serves both

    wire st_start  = op_start & sel_stem;
    wire pwf_start = op_start & sel_pwf;
    wire dw_start  = op_start & sel_dw;
    wire rs_start  = op_start & sel_res;
    wire gp_start  = op_start & sel_gap;

    // ---- the fields, resized to each feeder's ports ----------------------
    wire [AA_W-1:0]  n_ent_w = {{(AA_W-8){1'b0}}, op_n_ent_in};
    wire [XW_ST-1:0] st_img_w = {{(XW_ST-8){1'b0}}, op_img_w};
    wire [XW_ST-1:0] st_img_h = {{(XW_ST-8){1'b0}}, op_img_h};

    // The stem's tile count is ceil(OC/TS), which is not a field: the program
    // carries n_oc = ceil(OC/TM) because that is what every other op means by
    // it. TS is a datapath choice (DD-016), so deriving it here from the
    // channel count keeps the compiled program independent of it.
    wire [15:0]      st_noct_full = (ld_pchan + (TS - 1)) >> TSLOG;
    wire [OCTW-1:0]  st_n_oct     = st_noct_full[OCTW-1:0];

    // ================= the ONE requantize stage ==========================
    wire [TM*ACC_W-1:0]  os_acc;
    wire                 os_acc_valid;
    wire [PA_W-1:0]      os_param_addr;
    wire [TM*DATA_W-1:0] os_q;
    wire                 os_q_valid;

    wire [TM*ACC_W-1:0]  st_os_acc,  pw_os_acc,  dw_os_acc,  rs_os_acc,  gp_os_acc;
    wire                 st_os_val,  pw_os_val,  dw_os_val,  rs_os_val,  gp_os_val;
    wire [PA_W-1:0]      st_os_pa,   pw_os_pa,   dw_os_pa,   rs_os_pa,   gp_os_pa;

    assign os_acc       = sel_stem ? st_os_acc :
                          sel_pw   ? pw_os_acc :
                          sel_dw   ? dw_os_acc :
                          sel_res  ? rs_os_acc :
                          sel_gap  ? gp_os_acc : {TM*ACC_W{1'b0}};

    assign os_acc_valid = sel_stem ? st_os_val :
                          sel_pw   ? pw_os_val :
                          sel_dw   ? dw_os_val :
                          sel_res  ? rs_os_val :
                          sel_gap  ? gp_os_val : 1'b0;

    assign os_param_addr= sel_stem ? st_os_pa :
                          sel_pw   ? pw_os_pa :
                          sel_dw   ? dw_os_pa :
                          sel_res  ? rs_os_pa :
                          sel_gap  ? gp_os_pa : {PA_W{1'b0}};

    out_stage #(
        .TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .DATA_W(DATA_W),
        .PDEPTH(PDEPTH), .PA_W(PA_W), .BANK_W(BANK_W)
    ) u_os (
        .clock(clock), .rst_n(rst_n),
        .flush(op_start),
        .act(op_act), .relu6_qmax(op_qmax),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .acc(os_acc), .acc_valid(os_acc_valid), .param_addr(os_param_addr),
        .q(os_q), .q_valid(os_q_valid)
    );

    // ================= the activation pool ==============================
    wire                 a_rd_en;
    wire [AA_W-1:0]      a_addr;
    wire [SEL_W-1:0]     a_sel;
    wire [TN*DATA_W-1:0] a_word;

    wire                 aw_en;
    wire                 aw_full;
    wire [SEL_W-1:0]     aw_sel;
    wire [AA_W-1:0]      aw_addr;
    wire [TM*DATA_W-1:0] aw_data;

    act_buffer #(
        .DATA_W(DATA_W), .TM(TM), .TN(TN), .SEL_W(SEL_W),
        .DEPTH(ADEPTH), .ADDR_W(AA_W)
    ) u_act (
        .clock(clock),
        .wr_en(aw_en), .wr_full(aw_full), .wr_sel(aw_sel),
        .wr_addr(aw_addr), .wr_data(aw_data),
        .rd_en(a_rd_en), .rd_addr(a_addr), .rd_sel(a_sel), .rd_data(a_word)
    );

    // ================= the image region =================================
    wire             im_rd_en;
    wire [IA_W-1:0]  im_addr;
    wire [CIN*DATA_W-1:0] im_data;

    img_buffer #(
        .DATA_W(DATA_W), .CIN(CIN), .DEPTH(IDEPTH), .ADDR_W(IA_W)
    ) u_img (
        .clock(clock),
        .wr_en(im_wr_en), .wr_addr(im_wr_addr), .wr_data(im_wr_data),
        .rd_en(im_rd_en), .rd_addr(im_addr), .rd_data(im_data)
    );

    // ================= STEM ==============================================
    wire                 st_aw_en, st_aw_full, st_busy, st_done;
    wire [AA_W-1:0]      st_aw_addr;
    wire [TM*DATA_W-1:0] st_aw_data;

    stem_feeder #(
        .DATA_W(DATA_W), .TS(TS), .CIN(CIN), .K(K), .ACC_W(ACC_W),
        .POOL_TM(TM), .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
        .XW(XW_ST), .MAX_W(224), .OCTW(OCTW), .IA_W(IA_W), .AA_W(AA_W),
        .WA_W(ST_WA_W), .PA_W(PA_W), .BANK_W(ST_BANK_W), .PBANK_W(BANK_W),
        .WDEPTH(ST_WDEPTH), .PDEPTH(PDEPTH)
    ) u_stem (
        .clock(clock), .rst_n(rst_n),
        .start(st_start), .img_w(st_img_w), .img_h(st_img_h),
        .n_oct(st_n_oct), .base_out(op_base_out),
        .wl_en(st_wl_en), .wl_bank(st_wl_bank),
        .wl_addr(st_wl_addr), .wl_data(st_wl_data),
        .os_acc(st_os_acc), .os_acc_valid(st_os_val),
        .os_param_addr(st_os_pa), .os_q(os_q), .os_q_valid(os_q_valid),
        .im_rd_en(im_rd_en), .im_addr(im_addr), .im_data(im_data),
        .aw_en(st_aw_en), .aw_full(st_aw_full),
        .aw_addr(st_aw_addr), .aw_data(st_aw_data),
        .busy(st_busy), .layer_done(st_done)
    );

    // ================= POINTWISE (and the classifier's front half) =======
    wire                 pwf_rd_en;
    wire [AA_W-1:0]      pwf_addr;
    wire [SEL_W-1:0]     pwf_sel;
    wire [TM*ACC_W-1:0]  pwf_acc;
    wire                 pwf_acc_valid;
    wire [PIX_W-1:0]     pwf_acc_pix;
    wire [OCT_W-1:0]     pwf_acc_oct;
    wire                 pwf_busy, pwf_done;

    pw_feeder #(
        .DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W), .SEL_W(SEL_W),
        .BANK_W(BANK_W), .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W),
        .WA_W(PW_WA_W), .AA_W(AA_W), .WDEPTH(PW_WDEPTH)
    ) u_pwf (
        .clock(clock), .rst_n(rst_n),
        .start(pwf_start), .stall(1'b0),
        .n_pix(op_n_pix), .n_oc(op_n_oc), .n_ic(op_n_ic),
        .n_ent(n_ent_w), .base_in(op_base_in),
        .wl_en(pw_wl_en), .wl_bank(pw_wl_bank),
        .wl_addr(pw_wl_addr), .wl_data(pw_wl_data),
        .a_rd_en(pwf_rd_en), .a_addr(pwf_addr), .a_sel(pwf_sel),
        .a_word(a_word),
        .acc(pwf_acc), .acc_valid(pwf_acc_valid),
        .acc_pix(pwf_acc_pix), .acc_oct(pwf_acc_oct),
        .busy(pwf_busy), .layer_done(pwf_done)
    );

    wire                 pw_aw_en;
    wire [AA_W-1:0]      pw_aw_addr;
    wire [TM*DATA_W-1:0] pw_aw_data;

    pw_out #(
        .TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .DATA_W(DATA_W), .PIX_W(PIX_W), .OCT_W(OCT_W),
        .PDEPTH(PDEPTH), .PA_W(PA_W), .BANK_W(BANK_W), .AA_W(AA_W)
    ) u_pwo (
        .clock(clock), .rst_n(rst_n),
        .start(pwf_start), .n_oc(op_n_oc), .base_out(op_base_out),
        .os_acc(pw_os_acc), .os_acc_valid(pw_os_val),
        .os_param_addr(pw_os_pa), .os_q(os_q), .os_q_valid(os_q_valid),
        .acc(pwf_acc), .acc_valid(pwf_acc_valid),
        .acc_pix(pwf_acc_pix), .acc_oct(pwf_acc_oct),
        .aw_en(pw_aw_en), .aw_addr(pw_aw_addr), .aw_data(pw_aw_data),
        .tag_error(tag_error)
    );

    // ---- the classifier tail: int16 logits, not int8 activations --------
    logit_out #(
        .TM(TM), .NLOG(NLOG), .IDX_W(IDX_W), .ACC_W(ACC_W),
        .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .LOG_W(LOG_W)
    ) u_log (
        .clock(clock), .rst_n(rst_n),
        .start(op_start & sel_lin),
        .pl_en(lg_pl_en), .pl_idx(lg_pl_idx), .pl_bias(lg_pl_bias),
        .pl_m0(lg_pl_m0), .pl_shift(lg_pl_shift),
        .acc(pwf_acc), .acc_valid(pwf_acc_valid & sel_lin),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid)
    );

    // ================= DEPTHWISE =========================================
    wire                 dw_rd_en;
    wire [AA_W-1:0]      dw_addr;
    wire [SEL_W-1:0]     dw_sel;
    wire                 dw_aw_en, dw_aw_full, dw_busy, dw_done;
    wire [SEL_W-1:0]     dw_aw_sel;
    wire [AA_W-1:0]      dw_aw_addr;
    wire [TM*DATA_W-1:0] dw_aw_data;

    dw_feeder #(
        .DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W), .BIAS_W(BIAS_W),
        .M0_W(M0_W), .SHIFT_W(SHIFT_W), .POOL_TM(TM), .SEL_W(SEL_W),
        .XW(XW_DW), .MAX_W(112), .GRPW(GRPW), .AA_W(AA_W), .WA_W(DW_WA_W),
        .PA_W(PA_W), .BANK_W(DW_BANK_W), .POOL_BANK_W(BANK_W),
        .WDEPTH(DW_WDEPTH), .PDEPTH(PDEPTH)
    ) u_dw (
        .clock(clock), .rst_n(rst_n),
        .start(dw_start), .img_w(op_img_w), .img_h(op_img_h),
        .stride2(op_stride2), .n_grp(op_n_grp[GRPW-1:0]), .n_ent(n_ent_w),
        .base_in(op_base_in), .base_out(op_base_out),
        .wl_en(dw_wl_en), .wl_bank(dw_wl_bank),
        .wl_addr(dw_wl_addr), .wl_data(dw_wl_data),
        .os_acc(dw_os_acc), .os_acc_valid(dw_os_val),
        .os_param_addr(dw_os_pa), .os_q(os_q), .os_q_valid(os_q_valid),
        .a_rd_en(dw_rd_en), .a_addr(dw_addr), .a_sel(dw_sel), .a_word(a_word),
        .aw_en(dw_aw_en), .aw_full(dw_aw_full), .aw_sel(dw_aw_sel),
        .aw_addr(dw_aw_addr), .aw_data(dw_aw_data),
        .busy(dw_busy), .layer_done(dw_done)
    );

    // ================= RESIDUAL ADD ======================================
    wire                 rs_rd_en;
    wire [AA_W-1:0]      rs_addr;
    wire [SEL_W-1:0]     rs_sel;
    wire                 rs_aw_en, rs_aw_full, rs_busy, rs_done;
    wire [SEL_W-1:0]     rs_aw_sel;
    wire [AA_W-1:0]      rs_aw_addr;
    wire [TM*DATA_W-1:0] rs_aw_data;

    res_feeder #(
        .DATA_W(DATA_W), .POOL_TM(TM), .TN(TN), .ACC_W(ACC_W),
        .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
        .PA_W(PA_W), .BANK_W(BANK_W), .PDEPTH(PDEPTH), .AA_W(AA_W),
        .PIX_W(PIX_W), .SLW(SLW)
    ) u_res (
        .clock(clock), .rst_n(rst_n),
        .start(rs_start), .n_pix(op_n_pix), .n_sl(op_n_ic), .n_ent(n_ent_w),
        .base_in(op_base_in), .base_saved(op_base_saved),
        .base_out(op_base_out),
        .os_acc(rs_os_acc), .os_acc_valid(rs_os_val),
        .os_param_addr(rs_os_pa), .os_q(os_q), .os_q_valid(os_q_valid),
        .a_rd_en(rs_rd_en), .a_addr(rs_addr), .a_sel(rs_sel), .a_word(a_word),
        .aw_en(rs_aw_en), .aw_full(rs_aw_full), .aw_sel(rs_aw_sel),
        .aw_addr(rs_aw_addr), .aw_data(rs_aw_data),
        .busy(rs_busy), .layer_done(rs_done)
    );

    // ================= GLOBAL AVERAGE POOL ===============================
    wire                 gp_rd_en;
    wire [AA_W-1:0]      gp_addr;
    wire [SEL_W-1:0]     gp_sel;
    wire                 gp_aw_en, gp_aw_full, gp_busy, gp_done;
    wire [SEL_W-1:0]     gp_aw_sel;
    wire [AA_W-1:0]      gp_aw_addr;
    wire [TM*DATA_W-1:0] gp_aw_data;

    gap_feeder #(
        .DATA_W(DATA_W), .POOL_TM(TM), .TN(TN), .ACC_W(ACC_W),
        .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
        .PA_W(PA_W), .BANK_W(BANK_W), .PDEPTH(PDEPTH), .AA_W(AA_W),
        .PIX_W(PIX_W), .SLW(SLW)
    ) u_gap (
        .clock(clock), .rst_n(rst_n),
        .start(gp_start), .n_pix(op_n_pix), .n_sl(op_n_ic), .n_ent(n_ent_w),
        .base_in(op_base_in), .base_out(op_base_out),
        .os_acc(gp_os_acc), .os_acc_valid(gp_os_val),
        .os_param_addr(gp_os_pa), .os_q(os_q), .os_q_valid(os_q_valid),
        .a_rd_en(gp_rd_en), .a_addr(gp_addr), .a_sel(gp_sel), .a_word(a_word),
        .aw_en(gp_aw_en), .aw_full(gp_aw_full), .aw_sel(gp_aw_sel),
        .aw_addr(gp_aw_addr), .aw_data(gp_aw_data),
        .busy(gp_busy), .layer_done(gp_done)
    );

    // ================= the two pool muxes ================================
    // Read: the stem is absent on purpose - it reads the image, not the pool.
    assign a_rd_en = sel_pwf ? pwf_rd_en :
                     sel_dw  ? dw_rd_en  :
                     sel_res ? rs_rd_en  :
                     sel_gap ? gp_rd_en  : 1'b0;

    assign a_addr  = sel_pwf ? pwf_addr :
                     sel_dw  ? dw_addr  :
                     sel_res ? rs_addr  :
                     sel_gap ? gp_addr  : {AA_W{1'b0}};

    assign a_sel   = sel_pwf ? pwf_sel :
                     sel_dw  ? dw_sel  :
                     sel_res ? rs_sel  :
                     sel_gap ? gp_sel  : {SEL_W{1'b0}};

    // Write: LINEAR is absent on purpose - its result is logits, not a tensor.
    assign aw_en   = sel_stem ? st_aw_en :
                     sel_pw   ? pw_aw_en :
                     sel_dw   ? dw_aw_en :
                     sel_res  ? rs_aw_en :
                     sel_gap  ? gp_aw_en : 1'b0;

    assign aw_full = sel_stem ? st_aw_full :
                     sel_pw   ? 1'b1       :   // pw_out always writes all TM
                     sel_dw   ? dw_aw_full :
                     sel_res  ? rs_aw_full :
                     sel_gap  ? gp_aw_full : 1'b1;

    assign aw_sel  = sel_dw  ? dw_aw_sel :
                     sel_res ? rs_aw_sel :
                     sel_gap ? gp_aw_sel : {SEL_W{1'b0}};

    assign aw_addr = sel_stem ? st_aw_addr :
                     sel_pw   ? pw_aw_addr :
                     sel_dw   ? dw_aw_addr :
                     sel_res  ? rs_aw_addr :
                     sel_gap  ? gp_aw_addr : {AA_W{1'b0}};

    assign aw_data = sel_stem ? st_aw_data :
                     sel_pw   ? pw_aw_data :
                     sel_dw   ? dw_aw_data :
                     sel_res  ? rs_aw_data :
                     sel_gap  ? gp_aw_data : {TM*DATA_W{1'b0}};

    // ================= back to the sequencer =============================
    // Only the started feeder can be busy: every other one is held in its idle
    // state because its `start` never pulsed.
    assign op_busy = st_busy | pwf_busy | dw_busy | rs_busy | gp_busy;

endmodule

`default_nettype wire
