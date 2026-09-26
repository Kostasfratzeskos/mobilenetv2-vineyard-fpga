`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  accel_sys.v  -  accel_top + wgt_dma, presenting an AXI4 read master
//
//  The accelerator and the thing that feeds it weights, wired together. That is
//  all this file is: there is no logic here beyond the parameter arithmetic
//  below, and that is deliberate - accel_top is UNCHANGED by the DMA existing,
//  apart from one added output (`ld_op`, which DD-030 explains), so all 31
//  existing testbenches keep passing and accel_tb stays the fast path.
//
//  ---- what it fixes: the 841-port problem -------------------------------
//
//  scripts/impl.tcl:22 and scripts/make_project.tcl:50 both record why every
//  timing and area number in this project so far has been out-of-context:
//
//      accel_top has 841 port bits. The XCZU7EV package has roughly 300 PL
//      user I/O, so a normal flow fails I/O placement before it ever reaches
//      timing.
//
//  Most of those bits are the LOAD SIDE - three weight-buffer write ports of
//  128, 72 and 216 bits, the parameter port, the classifier's parameter port
//  and the ld_* handshake - which exist as pins only because the DMA did not.
//  Measured on the current source: 846 port bits today (the comment predates
//  `ld_op`), of which 672 across 29 ports are the load side. Wiring the DMA in
//  here absorbs all 672 and adds back the AXI4 read channel (196 bits) and four
//  32-bit base-address registers:
//
//      accel_top   846 port bits
//      accel_sys   493 port bits   (41 bits of image out, 35 of control in)
//
//  ---- so this is still NOT the board top --------------------------------
//
//  One group remains as a port, and it is the next item of work rather than an
//  oversight:
//
//      pg_*      42 bits   the program load. 512 words of instruction memory
//                          that the PS writes once per boot. accel_axi absorbs
//                          it into the AXI-Lite aperture; at THIS level it is
//                          still a port.
//
//  The image is no longer among them. wgt_dma reads it from DDR over the same
//  AXI master as the weights (DD-032), so `im_wr_*` is an internal connection
//  here instead of 41 bits of pin. Everything else is the AXI master, the
//  configuration registers, the answer and status.
//
//  ---- why the base addresses are plain input wires -----------------------
//
//  wgt_base, pb_base, pm_base and ps_base are latched inside wgt_dma on
//  `start`, and they are shaped exactly as an AXI-Lite CSR block would drive
//  them: four write-only 32-bit registers, read once per run, never changing
//  under a load in flight. AXI-Lite control registers are a separate open item;
//  when they land, they connect here and nothing inside changes.
//
//  ---- what is deliberately NOT here (C-11) ------------------------------
//
//  No weight double-buffering. C-11 is the largest available throughput
//  improvement in the design - features.18.0 spends 25,600 fill cycles against
//  39,200 compute - and DD-029 records why it is not being built yet. What this
//  file does for it is stay out of the way: every weight write is still a plain
//  (en, bank, addr, data) port on accel_top, so a second bank would be a
//  select on that port and not a change to the DMA or to this wiring. That is
//  the whole extent of the preparation, on purpose.
//
//  ---- the load ports are now internal, which the XDC was waiting for -----
//
//  hardware/constraints/accel_top_ooc.xdc gives pg_*, im_wr_*, pw_wl_*,
//  dw_wl_*, st_wl_*, pl_*, lg_pl_* and ld_done a 0.5 ns input delay with the
//  comment "Tighten these once the DMA is real", because a port fed by a DMA
//  that did not exist had no launch clock on the other side. For accel_sys all
//  of those except pg_* and im_wr_* are register-to-register paths inside the
//  module, timed like any other logic - and wgt_dma registers every one of its
//  outputs specifically so they arrive that way. See accel_sys_ooc.xdc.
//
//  Run:  bash scripts/run_sim.sh accel_dma accel_sys wgt_dma accel_top top_seq \
//          pw_feeder pw_out dw_feeder res_feeder gap_feeder stem_feeder \
//          logit_out out_stage pe_array mac_lane conv1x1 dwconv3x3 \
//          conv3x3_std dw_array stem_array line_buffer avgpool addr_gen \
//          wgt_buffer act_buffer img_buffer param_buffer rq_bank \
//          bias_add requantize
//============================================================================
module accel_sys #(
    // ---- datapath geometry ----------------------------------------------
    //  The *_LOG parameters are chosen HERE and the byte/bank widths are
    //  derived from them, rather than both being passed down independently.
    //  accel_top's own parameter list still names BANK_W, DW_BANK_W, ST_BANK_W,
    //  TSLOG and SEL_W separately - it predates this file and its 31
    //  testbenches pass them explicitly - but from this level up there is one
    //  place where TM, TN, TC, TS and their logs are decided, so a transposed
    //  width cannot reach only one of the two instances.
    parameter DATA_W  = 8,
    parameter TM      = 32,  parameter TM_LOG = 5,
    parameter TN      = 16,  parameter TN_LOG = 4,
    parameter TC      = 16,  parameter TC_LOG = 4,
    parameter TS      = 8,   parameter TS_LOG = 3,
    parameter CIN     = 3,
    parameter K       = 3,
    parameter ACC_W   = 26,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,

    // ---- memories -------------------------------------------------------
    parameter ADEPTH  = 50176,
    parameter AA_W    = 16,
    parameter IDEPTH  = 50176,
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
    parameter XW_DW   = 8,
    parameter XW_ST   = 9,

    // ---- program --------------------------------------------------------
    parameter PW_W    = 32,
    parameter PGA_W   = 9,
    parameter PROG_DEPTH = 512,
    parameter NI_W    = 8,
    parameter OS_LAT  = 5,
    parameter GAP_CYC = OS_LAT,
    parameter WDOG_W  = 20,

    // ---- classifier -----------------------------------------------------
    parameter NLOG    = 4,
    parameter IDX_W   = 2,
    parameter LOG_W   = 16,

    // ---- the load handshake's field widths -------------------------------
    parameter OFF_W   = 24,
    parameter BYT_W   = 20,
    parameter PCH_W   = 16,

    // ---- AXI4 -----------------------------------------------------------
    parameter AXI_ADDR_W  = 32,
    parameter AXI_DATA_W  = 128,
    parameter AXI_ID_W    = 4,
    parameter AXI_ID      = 0,
    parameter MAX_BURST   = 256,
    parameter MAX_OUTST   = 4,
    parameter RFIFO_DEPTH = 32,
    parameter RFIFO_AW    = 5
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- run control -----------------------------------------------------
    input  wire                      start,
    input  wire [NI_W-1:0]           n_instr,

    // ---- where the four blobs live in PS-DDR (latched at `start`) --------
    input  wire [AXI_ADDR_W-1:0]     wgt_base,
    input  wire [AXI_ADDR_W-1:0]     pb_base,
    input  wire [AXI_ADDR_W-1:0]     pm_base,
    input  wire [AXI_ADDR_W-1:0]     ps_base,

    // ---- program load: still a port, see the header ----------------------
    input  wire                      pg_en,
    input  wire [PGA_W-1:0]          pg_addr,
    input  wire [PW_W-1:0]           pg_data,

    // ---- the image, read from DDR by wgt_dma (DD-032) --------------------
    //  `img_base` is not latched at `start` like the other four: the image is
    //  loaded BEFORE a run, so it is sampled when the load is requested.
    //  `img_busy` is the level to poll; `img_done` pulses only on success, so a
    //  bus error cannot be read as a loaded image.
    input  wire [AXI_ADDR_W-1:0]     img_base,
    input  wire                      img_start,
    output wire                      img_busy,
    output wire                      img_done,

    // ---- AXI4 read-only master -------------------------------------------
    output wire [AXI_ID_W-1:0]       m_axi_arid,
    output wire [AXI_ADDR_W-1:0]     m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arlock,
    output wire [3:0]                m_axi_arcache,
    output wire [2:0]                m_axi_arprot,
    output wire                      m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [AXI_ID_W-1:0]       m_axi_rid,
    input  wire [AXI_DATA_W-1:0]     m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready,

    // ---- the answer -------------------------------------------------------
    output wire [NLOG*LOG_W-1:0]     logits,
    output wire                      logits_valid,
    output wire [IDX_W-1:0]          argmax,
    output wire                      argmax_valid,

    // ---- status -----------------------------------------------------------
    //  Read `fault` and `dma_error` together: fault alone means the
    //  accelerator gave up (watchdog, bad opcode, n_instr out of range),
    //  fault AND dma_error means the bus is why.
    output wire [NI_W-1:0]           pc,
    output wire                      running,
    output wire                      done,
    output wire                      tag_error,
    output wire                      fault,
    output wire                      dma_error
);

    // ---- the widths accel_top names separately, derived from the logs -----
    localparam BANK_W    = TM_LOG;          // clog2(TM)     = 5
    localparam DW_BANK_W = TC_LOG;          // clog2(TC)     = 4
    localparam ST_BANK_W = TS_LOG;          // clog2(TS)     = 3
    localparam SEL_W     = TM_LOG - TN_LOG; // clog2(TM/TN)  = 1

    generate
        if ((1 << TM_LOG) != TM) begin : chk_tm
            ERROR_ACCEL_SYS_TM_LOG_DOES_NOT_MATCH_TM u_err();
        end
        if ((1 << TN_LOG) != TN) begin : chk_tn
            ERROR_ACCEL_SYS_TN_LOG_DOES_NOT_MATCH_TN u_err();
        end
        if ((1 << TC_LOG) != TC) begin : chk_tc
            ERROR_ACCEL_SYS_TC_LOG_DOES_NOT_MATCH_TC u_err();
        end
        if ((1 << TS_LOG) != TS) begin : chk_ts
            ERROR_ACCEL_SYS_TS_LOG_DOES_NOT_MATCH_TS u_err();
        end
        if (TM_LOG < TN_LOG) begin : chk_sel
            ERROR_ACCEL_SYS_TM_MUST_BE_AT_LEAST_TN u_err();
        end
    endgenerate

    // ---- the handshake and the four write ports, now internal ------------
    wire                      ld_req, ld_done;
    wire [3:0]                ld_op;
    wire [OFF_W-1:0]          ld_off;
    wire [BYT_W-1:0]          ld_bytes;
    wire [PCH_W-1:0]          ld_pchan;

    wire                      pw_wl_en;
    wire [BANK_W-1:0]         pw_wl_bank;
    wire [PW_WA_W-1:0]        pw_wl_addr;
    wire [TN*DATA_W-1:0]      pw_wl_data;

    wire                      dw_wl_en;
    wire [DW_BANK_W-1:0]      dw_wl_bank;
    wire [DW_WA_W-1:0]        dw_wl_addr;
    wire [K*K*DATA_W-1:0]     dw_wl_data;

    wire                      st_wl_en;
    wire [ST_BANK_W-1:0]      st_wl_bank;
    wire [ST_WA_W-1:0]        st_wl_addr;
    wire [CIN*K*K*DATA_W-1:0] st_wl_data;

    wire                      im_wr_en;
    wire [IA_W-1:0]           im_wr_addr;
    wire [CIN*DATA_W-1:0]     im_wr_data;

    wire                      pl_en;
    wire [BANK_W-1:0]         pl_bank;
    wire [PA_W-1:0]           pl_addr;
    wire signed [BIAS_W-1:0]  pl_bias;
    wire signed [M0_W-1:0]    pl_m0;
    wire [SHIFT_W-1:0]        pl_shift;

    wire                      lg_pl_en;
    wire [IDX_W-1:0]          lg_pl_idx;
    wire signed [BIAS_W-1:0]  lg_pl_bias;
    wire signed [M0_W-1:0]    lg_pl_m0;
    wire [SHIFT_W-1:0]        lg_pl_shift;

    // ======================================================================
    accel_top #(
        .DATA_W(DATA_W), .TM(TM), .TN(TN), .TC(TC), .TS(TS), .TSLOG(TS_LOG),
        .CIN(CIN), .K(K), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
        .ADEPTH(ADEPTH), .AA_W(AA_W), .IDEPTH(IDEPTH), .IA_W(IA_W),
        .PW_WDEPTH(PW_WDEPTH), .PW_WA_W(PW_WA_W),
        .DW_WDEPTH(DW_WDEPTH), .DW_WA_W(DW_WA_W),
        .ST_WDEPTH(ST_WDEPTH), .ST_WA_W(ST_WA_W),
        .PDEPTH(PDEPTH), .PA_W(PA_W),
        .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W), .SLW(SLW),
        .GRPW(GRPW), .OCTW(OCTW), .XW_DW(XW_DW), .XW_ST(XW_ST),
        .BANK_W(BANK_W), .DW_BANK_W(DW_BANK_W), .ST_BANK_W(ST_BANK_W),
        .PW_W(PW_W), .PGA_W(PGA_W), .PROG_DEPTH(PROG_DEPTH), .NI_W(NI_W),
        .OS_LAT(OS_LAT), .GAP_CYC(GAP_CYC), .WDOG_W(WDOG_W),
        .NLOG(NLOG), .IDX_W(IDX_W), .LOG_W(LOG_W)
    ) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_instr(n_instr),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .im_wr_en(im_wr_en), .im_wr_addr(im_wr_addr), .im_wr_data(im_wr_data),
        .ld_req(ld_req), .ld_op(ld_op), .ld_off(ld_off),
        .ld_bytes(ld_bytes), .ld_pchan(ld_pchan), .ld_done(ld_done),
        .pw_wl_en(pw_wl_en), .pw_wl_bank(pw_wl_bank),
        .pw_wl_addr(pw_wl_addr), .pw_wl_data(pw_wl_data),
        .dw_wl_en(dw_wl_en), .dw_wl_bank(dw_wl_bank),
        .dw_wl_addr(dw_wl_addr), .dw_wl_data(dw_wl_data),
        .st_wl_en(st_wl_en), .st_wl_bank(st_wl_bank),
        .st_wl_addr(st_wl_addr), .st_wl_data(st_wl_data),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .lg_pl_en(lg_pl_en), .lg_pl_idx(lg_pl_idx), .lg_pl_bias(lg_pl_bias),
        .lg_pl_m0(lg_pl_m0), .lg_pl_shift(lg_pl_shift),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid),
        .pc(pc), .running(running), .done(done), .tag_error(tag_error),
        .fault(fault)
    );

    wgt_dma #(
        .DATA_W(DATA_W),
        .TM(TM), .TM_LOG(TM_LOG), .TN(TN), .TN_LOG(TN_LOG),
        .TC(TC), .TC_LOG(TC_LOG), .TS(TS), .TS_LOG(TS_LOG),
        .CIN(CIN), .K(K),
        .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
        .PW_WA_W(PW_WA_W), .DW_WA_W(DW_WA_W), .ST_WA_W(ST_WA_W), .PA_W(PA_W),
        .BANK_W(BANK_W), .DW_BANK_W(DW_BANK_W), .ST_BANK_W(ST_BANK_W),
        .NLOG(NLOG), .IDX_W(IDX_W),
        .IDEPTH(IDEPTH), .IA_W(IA_W),
        .OFF_W(OFF_W), .BYT_W(BYT_W), .PCH_W(PCH_W),
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
        .AXI_ID_W(AXI_ID_W), .AXI_ID(AXI_ID),
        .MAX_BURST(MAX_BURST), .MAX_OUTST(MAX_OUTST),
        .RFIFO_DEPTH(RFIFO_DEPTH), .RFIFO_AW(RFIFO_AW)
    ) u_dma (
        // The DMA takes the RAW rst_n, not accel_top's synchronised copy:
        // rst_n_i is internal to accel_top by design (DD-020), and the DMA has
        // its own synchronous reset off the same signal. Both see async
        // assertion and, through accel_top's two-flop synchroniser, a
        // deassertion that is at most one cycle apart - which cannot matter,
        // because the DMA does nothing until `ld_req`, and top_seq cannot raise
        // ld_req until it has left reset and been given `start`.
        .clock(clock), .rst_n(rst_n), .start(start),
        .wgt_base(wgt_base), .pb_base(pb_base),
        .pm_base(pm_base),   .ps_base(ps_base), .img_base(img_base),
        .img_start(img_start), .img_busy(img_busy), .img_done(img_done),
        .im_wr_en(im_wr_en), .im_wr_addr(im_wr_addr), .im_wr_data(im_wr_data),
        .ld_req(ld_req), .ld_op(ld_op), .ld_off(ld_off),
        .ld_bytes(ld_bytes), .ld_pchan(ld_pchan), .ld_done(ld_done),
        .pw_wl_en(pw_wl_en), .pw_wl_bank(pw_wl_bank),
        .pw_wl_addr(pw_wl_addr), .pw_wl_data(pw_wl_data),
        .dw_wl_en(dw_wl_en), .dw_wl_bank(dw_wl_bank),
        .dw_wl_addr(dw_wl_addr), .dw_wl_data(dw_wl_data),
        .st_wl_en(st_wl_en), .st_wl_bank(st_wl_bank),
        .st_wl_addr(st_wl_addr), .st_wl_data(st_wl_data),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .lg_pl_en(lg_pl_en), .lg_pl_idx(lg_pl_idx), .lg_pl_bias(lg_pl_bias),
        .lg_pl_m0(lg_pl_m0), .lg_pl_shift(lg_pl_shift),
        .dma_error(dma_error),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

endmodule

`default_nettype wire
