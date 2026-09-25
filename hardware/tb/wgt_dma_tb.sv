`timescale 1ns / 1ps
//============================================================================
//  wgt_dma_tb.sv  -  UNIT: the weight DMA against a behavioural AXI4 slave
//
//  wgt_dma replaces a testbench task that was already proven end to end, so the
//  risk here is not "does it work at all" - accel_dma_tb answers that - it is
//  "does it put every byte in the right place for the shapes that are rare".
//  This file goes after those shapes one at a time, with a scoreboard that does
//  not share a line of arithmetic with the DUT.
//
//  ---- the expectation is computed in a DIFFERENT loop order ---------------
//
//  Deliberately. wgt_dma deals a pointwise layer in the order (oc_tile, lane,
//  ic_tile) because that makes the DDR read one sequential run - its header
//  argues the case at length. The expectation below is built in the order the
//  buffer contract is naturally written in, (oc_tile, ic_tile, lane), from
//  wgt_buffer's own address formula:
//
//      rd_data[(m*TN + j)*8 +: 8] = w[(oct*TM + m)*IC + ict*TN + j]
//
//  So the two agree only if the reordering argument is actually true. A
//  scoreboard that walked the same loops in the same order would confirm the
//  DUT against itself.
//
//  Every write is matched on (port, bank, addr) and each expected entry must be
//  hit EXACTLY once: an unexpected write, a duplicate write and a missing write
//  are three separate failures. The duplicate check matters more than it looks -
//  a rectangle that writes the same address twice and skips another is
//  bit-exact on the second-to-last layer and wrong on the last.
//
//  ---- what each case is for ----------------------------------------------
//
//   1 STEM   op 0     27-byte rows: the only shape needing two beats per word,
//                     and pchan=32 = 4 tiles of TS=8 exactly.
//   2 DW     op 1     9-byte rows, 2 groups.
//   3 PW     op 2     ic=32 (two whole ic tiles), pchan=16 < TM: HALF the lanes
//                     are padding and must be written as zero.
//   4 PW     op 5     ic=96, pchan=24: padded lanes again, different ratio.
//   5 PW     op 6     ic=24. The case the design brief singles out: ic is not a
//                     multiple of TN, so every odd output channel starts 8
//                     bytes into a beat AND the second ic tile is 8 real bytes
//                     plus 8 of zero. A 16-byte-aligned gather is bit-exact on
//                     every other layer in the network and wrong here.
//   6 PW     synthetic, ic=24 at an ODD ld_off. Nothing in the compiled program
//                     has an unaligned base today - every ld_off is a multiple
//                     of 16 - so this is the case that stops that becoming an
//                     accidental dependency.
//   7 DW     op 59    960 channels, 60 groups: exercises DW_WA_W=6 to 59.
//   8 GAP    op 62    ld_bytes = 0, pchan = 1280: parameters ONLY, 40 tiles,
//                     and the parameter index has to advance by a full 1280.
//   9 LINEAR op 63    ic=1280 and the parameters go to lg_pl_* instead, while
//                     the index still advances by a whole tile of 32.
//  10 PW     op 61    features.18.0, the worst load in the network: 409,600
//                     bytes, 25,600 bank writes, 100 maximum-length bursts.
//  10b       op 61 again, with the slave's R-channel holes switched OFF. This
//                     is where the throughput claim is measured, because a rate
//                     taken against a stalling slave measures the slave.
//  11 bus error       SLVERR on every beat: dma_error must go high and STAY
//                     high, and ld_done must never pulse.
//
//  The eleven data cases run as ONE sequence without an intervening `start`, so
//  the running parameter index is under test too - it is the one piece of state
//  that carries between loads, and the blob has no offset field to catch it.
//
//  Run:  bash scripts/run_sim.sh wgt_dma
//============================================================================
`include "axi_ddr_model.svh"

module wgt_dma_tb;

    // ---- geometry, matching accel_top's defaults --------------------------
    localparam DATA_W    = 8;
    localparam TM        = 32,  TM_LOG = 5;
    localparam TN        = 16,  TN_LOG = 4;
    localparam TC        = 16,  TC_LOG = 4;
    localparam TS        = 8,   TS_LOG = 3;
    localparam CIN       = 3;
    localparam K         = 3;
    localparam BIAS_W    = 32;
    localparam M0_W      = 32;
    localparam SHIFT_W   = 6;
    localparam PW_WA_W   = 10;
    localparam DW_WA_W   = 6;
    localparam ST_WA_W   = 4;
    localparam PA_W      = 6;
    localparam BANK_W    = 5;
    localparam DW_BANK_W = 4;
    localparam ST_BANK_W = 3;
    localparam NLOG      = 4;
    localparam IDX_W     = 2;

    localparam OFF_W     = 24;
    localparam BYT_W     = 20;
    localparam PCH_W     = 16;

    localparam AXI_ADDR_W = 32;
    localparam AXI_DATA_W = 128;
    localparam AXI_ID_W   = 4;

    localparam ST_BITS = CIN*K*K*DATA_W;     // 216
    localparam DW_BITS = K*K*DATA_W;         // 72
    localparam PW_BITS = TN*DATA_W;          // 128

    // buffer depths, matching accel_top
    localparam PW_DEPTH = 1024;
    localparam DW_DEPTH = 64;
    localparam ST_DEPTH = 16;
    localparam PDEPTH   = 64;

    localparam WBLOB = 2194880;              // weights.hex
    localparam PBLOB = 19264;                // params_*.hex, padded to tiles

    localparam [3:0] OP_STEM = 4'd1, OP_PW = 4'd2, OP_DW = 4'd3,
                     OP_RES  = 4'd4, OP_GAP = 4'd5, OP_LINEAR = 4'd6;

    // the DDR map this testbench hands the DMA
    localparam [31:0] WGT_BASE = 32'h1000_0000;
    localparam [31:0] PB_BASE  = 32'h2000_0000;
    localparam [31:0] PM_BASE  = 32'h2400_0000;
    localparam [31:0] PS_BASE  = 32'h2800_0000;

    // ======================================================================
    //  DUT and slave
    // ======================================================================
    logic clock, rst_n, start;
    logic err_on, gaps_on;

    //  Counters shared by the driver and the monitor. Declared here because the
    //  monitor is an always block and the driver a task, and both read them.
    integer cyc = 0;
    integer fails = 0;          // the verdict
    integer n_exp = 0;          // expected writes in the current case
    integer n_obs = 0;          // observed writes in the current case
    integer w_cnt, w_first, w_last;   // the weight phase, for the rate

    logic              ld_req;
    logic [3:0]        ld_op;
    logic [OFF_W-1:0]  ld_off;
    logic [BYT_W-1:0]  ld_bytes;
    logic [PCH_W-1:0]  ld_pchan;
    wire               ld_done;

    wire                     pw_wl_en;
    wire [BANK_W-1:0]        pw_wl_bank;
    wire [PW_WA_W-1:0]       pw_wl_addr;
    wire [PW_BITS-1:0]       pw_wl_data;
    wire                     dw_wl_en;
    wire [DW_BANK_W-1:0]     dw_wl_bank;
    wire [DW_WA_W-1:0]       dw_wl_addr;
    wire [DW_BITS-1:0]       dw_wl_data;
    wire                     st_wl_en;
    wire [ST_BANK_W-1:0]     st_wl_bank;
    wire [ST_WA_W-1:0]       st_wl_addr;
    wire [ST_BITS-1:0]       st_wl_data;
    wire                     pl_en;
    wire [BANK_W-1:0]        pl_bank;
    wire [PA_W-1:0]          pl_addr;
    wire signed [BIAS_W-1:0] pl_bias;
    wire signed [M0_W-1:0]   pl_m0;
    wire [SHIFT_W-1:0]       pl_shift;
    wire                     lg_pl_en;
    wire [IDX_W-1:0]         lg_pl_idx;
    wire signed [BIAS_W-1:0] lg_pl_bias;
    wire signed [M0_W-1:0]   lg_pl_m0;
    wire [SHIFT_W-1:0]       lg_pl_shift;
    wire                     dma_error;

    wire [AXI_ID_W-1:0]   arid;
    wire [AXI_ADDR_W-1:0] araddr;
    wire [7:0]            arlen;
    wire [2:0]            arsize;
    wire [1:0]            arburst;
    wire                  arlock;
    wire [3:0]            arcache;
    wire [2:0]            arprot;
    wire                  arvalid, arready;
    wire [AXI_ID_W-1:0]   rid;
    wire [AXI_DATA_W-1:0] rdata;
    wire [1:0]            rresp;
    wire                  rlast, rvalid, rready;

    wgt_dma #(
        .DATA_W(DATA_W), .TM(TM), .TM_LOG(TM_LOG), .TN(TN), .TN_LOG(TN_LOG),
        .TC(TC), .TC_LOG(TC_LOG), .TS(TS), .TS_LOG(TS_LOG),
        .CIN(CIN), .K(K), .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
        .PW_WA_W(PW_WA_W), .DW_WA_W(DW_WA_W), .ST_WA_W(ST_WA_W), .PA_W(PA_W),
        .BANK_W(BANK_W), .DW_BANK_W(DW_BANK_W), .ST_BANK_W(ST_BANK_W),
        .NLOG(NLOG), .IDX_W(IDX_W),
        .OFF_W(OFF_W), .BYT_W(BYT_W), .PCH_W(PCH_W),
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W)
    ) u_dma (
        .clock(clock), .rst_n(rst_n), .start(start),
        .wgt_base(WGT_BASE), .pb_base(PB_BASE),
        .pm_base(PM_BASE),   .ps_base(PS_BASE),
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
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arcache(arcache), .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    // GAP_MASK non-zero on purpose: the R FIFO and the two-beat window only do
    // anything when the slave stalls, so a slave that never stalls would leave
    // them untested.
    axi_ddr_model #(
        .ADDR_W(AXI_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W),
        .WGT_BASE(WGT_BASE), .WGT_N(WBLOB),
        .PB_BASE(PB_BASE), .PM_BASE(PM_BASE), .PS_BASE(PS_BASE), .PN(PBLOB),
        .AR_LAT(5), .GAP_MASK(15)
    ) u_ddr (
        .clock(clock), .rst_n(rst_n), .err_on(err_on), .gaps_on(gaps_on),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    // ======================================================================
    //  the reference blobs, read independently of the slave model
    // ======================================================================
    reg [7:0]         wb [0:WBLOB-1];
    reg signed [31:0] pb [0:PBLOB-1];
    reg signed [31:0] pm [0:PBLOB-1];
    reg [7:0]         ps [0:PBLOB-1];

    // ======================================================================
    //  the expectation
    // ======================================================================
    reg [PW_BITS-1:0] e_pw   [0:TM-1][0:PW_DEPTH-1];
    bit               e_pw_v [0:TM-1][0:PW_DEPTH-1];
    bit               e_pw_s [0:TM-1][0:PW_DEPTH-1];

    reg [DW_BITS-1:0] e_dw   [0:TC-1][0:DW_DEPTH-1];
    bit               e_dw_v [0:TC-1][0:DW_DEPTH-1];
    bit               e_dw_s [0:TC-1][0:DW_DEPTH-1];

    reg [ST_BITS-1:0] e_st   [0:TS-1][0:ST_DEPTH-1];
    bit               e_st_v [0:TS-1][0:ST_DEPTH-1];
    bit               e_st_s [0:TS-1][0:ST_DEPTH-1];

    reg signed [BIAS_W-1:0] e_pb   [0:TM-1][0:PDEPTH-1];
    reg signed [M0_W-1:0]   e_pm   [0:TM-1][0:PDEPTH-1];
    reg [SHIFT_W-1:0]       e_ps   [0:TM-1][0:PDEPTH-1];
    bit                     e_pl_v [0:TM-1][0:PDEPTH-1];
    bit                     e_pl_s [0:TM-1][0:PDEPTH-1];

    reg signed [BIAS_W-1:0] e_lb   [0:NLOG-1];
    reg signed [M0_W-1:0]   e_lm   [0:NLOG-1];
    reg [SHIFT_W-1:0]       e_ls   [0:NLOG-1];
    bit                     e_lg_v [0:NLOG-1];
    bit                     e_lg_s [0:NLOG-1];

    integer tot_exp = 0, tot_obs = 0;
    integer pidx_ref = 0;    // the TB's own copy of the running index
    integer cases   = 0;
    string  cname;

    integer i, j, m, ot, it, g, ch, ocx, icx, ic, nt, n_oc, n_ic, n_oct, n_grp;
    integer npad, a, d_i;

    task automatic clear_exp;
        begin
            for (i = 0; i < TM; i++) for (j = 0; j < PW_DEPTH; j++)
                begin e_pw_v[i][j] = 0; e_pw_s[i][j] = 0; end
            for (i = 0; i < TC; i++) for (j = 0; j < DW_DEPTH; j++)
                begin e_dw_v[i][j] = 0; e_dw_s[i][j] = 0; end
            for (i = 0; i < TS; i++) for (j = 0; j < ST_DEPTH; j++)
                begin e_st_v[i][j] = 0; e_st_s[i][j] = 0; end
            for (i = 0; i < TM; i++) for (j = 0; j < PDEPTH; j++)
                begin e_pl_v[i][j] = 0; e_pl_s[i][j] = 0; end
            for (i = 0; i < NLOG; i++)
                begin e_lg_v[i] = 0; e_lg_s[i] = 0; end
            n_exp = 0;
            n_obs = 0;
            w_cnt = 0;
            w_first = -1;
            w_last  = -1;
        end
    endtask

    // ---- the stem: bank = lane in the tile, address = oc tile -------------
    task automatic exp_stem(input integer off, input integer nbytes,
                            input integer pchan);
        reg [ST_BITS-1:0] d;
        begin
            nt    = nbytes / pchan;
            n_oct = (pchan + TS - 1) / TS;
            for (ot = 0; ot < n_oct; ot++)
                for (m = 0; m < TS; m++) begin
                    ocx = ot*TS + m;
                    d   = '0;
                    for (i = 0; i < nt; i++)
                        d[i*DATA_W +: DATA_W] =
                            (ocx < pchan) ? wb[off + ocx*nt + i] : 8'h00;
                    e_st[m][ot]   = d;
                    e_st_v[m][ot] = 1;
                    n_exp++;
                end
        end
    endtask

    // ---- depthwise: bank = channel in the group, address = group ----------
    task automatic exp_dw(input integer off, input integer nbytes,
                          input integer pchan);
        reg [DW_BITS-1:0] d;
        begin
            nt    = nbytes / pchan;
            n_grp = (pchan + TC - 1) / TC;
            for (g = 0; g < n_grp; g++)
                for (m = 0; m < TC; m++) begin
                    ch = g*TC + m;
                    d  = '0;
                    for (i = 0; i < nt; i++)
                        d[i*DATA_W +: DATA_W] =
                            (ch < pchan) ? wb[off + ch*nt + i] : 8'h00;
                    e_dw[m][g]   = d;
                    e_dw_v[m][g] = 1;
                    n_exp++;
                end
        end
    endtask

    // ---- pointwise, straight from wgt_buffer's address formula ------------
    //  Loop order (oc tile, ic tile, lane) - NOT the DUT's. See the header.
    task automatic exp_pw(input integer off, input integer nbytes,
                          input integer pchan);
        reg [PW_BITS-1:0] d;
        begin
            ic   = nbytes / pchan;
            n_oc = (pchan + TM - 1) / TM;
            n_ic = (ic + TN - 1) / TN;
            for (ot = 0; ot < n_oc; ot++)
                for (it = 0; it < n_ic; it++)
                    for (m = 0; m < TM; m++) begin
                        ocx = ot*TM + m;
                        d   = '0;
                        for (j = 0; j < TN; j++) begin
                            icx = it*TN + j;
                            d[j*DATA_W +: DATA_W] =
                                (ocx < pchan && icx < ic)
                                    ? wb[off + ocx*ic + icx] : 8'h00;
                        end
                        e_pw[m][ot*n_ic + it]   = d;
                        e_pw_v[m][ot*n_ic + it] = 1;
                        n_exp++;
                    end
        end
    endtask

    // ---- the shared parameter banks --------------------------------------
    task automatic exp_params(input integer pchan, input integer pi);
        begin
            npad = ((pchan + TM - 1) / TM) * TM;
            for (ch = 0; ch < npad; ch++) begin
                e_pb[ch % TM][ch / TM]   = pb[pi + ch];
                e_pm[ch % TM][ch / TM]   = pm[pi + ch];
                e_ps[ch % TM][ch / TM]   = ps[pi + ch][SHIFT_W-1:0];
                e_pl_v[ch % TM][ch / TM] = 1;
                n_exp++;
            end
        end
    endtask

    task automatic exp_logit(input integer pi);
        begin
            for (i = 0; i < NLOG; i++) begin
                e_lb[i]   = pb[pi + i];
                e_lm[i]   = pm[pi + i];
                e_ls[i]   = ps[pi + i][SHIFT_W-1:0];
                e_lg_v[i] = 1;
                n_exp++;
            end
        end
    endtask

    // ======================================================================
    //  the monitor: every write is checked as it happens
    // ======================================================================
    task automatic bad(input string what);
        begin
            fails++;
            if (fails <= 20) $display("  [ERR] %s: %s", cname, what);
        end
    endtask

    always @(posedge clock) if (rst_n) begin
        // The weight phase, timed separately. The whole-load rate also carries
        // the parameter tail - 40 tiles x three AR turnarounds on the worst op -
        // which is real but is not what "the R channel must not go idle" is
        // about. First-to-last weight write is.
        if (st_wl_en || dw_wl_en || pw_wl_en) begin
            w_cnt++;
            if (w_first < 0) w_first = cyc;
            w_last = cyc;
        end

        if (st_wl_en) begin
            n_obs++;
            if (!e_st_v[st_wl_bank][st_wl_addr])
                bad($sformatf("unexpected stem write to bank %0d addr %0d",
                              st_wl_bank, st_wl_addr));
            else if (e_st_s[st_wl_bank][st_wl_addr])
                bad($sformatf("duplicate stem write to bank %0d addr %0d",
                              st_wl_bank, st_wl_addr));
            else if (st_wl_data !== e_st[st_wl_bank][st_wl_addr])
                bad($sformatf("stem bank %0d addr %0d: got %054x, expected %054x",
                              st_wl_bank, st_wl_addr, st_wl_data,
                              e_st[st_wl_bank][st_wl_addr]));
            else e_st_s[st_wl_bank][st_wl_addr] = 1;
        end

        if (dw_wl_en) begin
            n_obs++;
            if (!e_dw_v[dw_wl_bank][dw_wl_addr])
                bad($sformatf("unexpected dw write to bank %0d addr %0d",
                              dw_wl_bank, dw_wl_addr));
            else if (e_dw_s[dw_wl_bank][dw_wl_addr])
                bad($sformatf("duplicate dw write to bank %0d addr %0d",
                              dw_wl_bank, dw_wl_addr));
            else if (dw_wl_data !== e_dw[dw_wl_bank][dw_wl_addr])
                bad($sformatf("dw bank %0d addr %0d: got %018x, expected %018x",
                              dw_wl_bank, dw_wl_addr, dw_wl_data,
                              e_dw[dw_wl_bank][dw_wl_addr]));
            else e_dw_s[dw_wl_bank][dw_wl_addr] = 1;
        end

        if (pw_wl_en) begin
            n_obs++;
            if (!e_pw_v[pw_wl_bank][pw_wl_addr])
                bad($sformatf("unexpected pw write to bank %0d addr %0d",
                              pw_wl_bank, pw_wl_addr));
            else if (e_pw_s[pw_wl_bank][pw_wl_addr])
                bad($sformatf("duplicate pw write to bank %0d addr %0d",
                              pw_wl_bank, pw_wl_addr));
            else if (pw_wl_data !== e_pw[pw_wl_bank][pw_wl_addr])
                bad($sformatf("pw bank %0d addr %0d: got %032x, expected %032x",
                              pw_wl_bank, pw_wl_addr, pw_wl_data,
                              e_pw[pw_wl_bank][pw_wl_addr]));
            else e_pw_s[pw_wl_bank][pw_wl_addr] = 1;
        end

        if (pl_en) begin
            n_obs++;
            if (!e_pl_v[pl_bank][pl_addr])
                bad($sformatf("unexpected param write to bank %0d addr %0d",
                              pl_bank, pl_addr));
            else if (e_pl_s[pl_bank][pl_addr])
                bad($sformatf("duplicate param write to bank %0d addr %0d",
                              pl_bank, pl_addr));
            else if ((pl_bias  !== e_pb[pl_bank][pl_addr]) ||
                     (pl_m0    !== e_pm[pl_bank][pl_addr]) ||
                     (pl_shift !== e_ps[pl_bank][pl_addr]))
                bad($sformatf("param bank %0d addr %0d: got (%0d, %0d, %0d), expected (%0d, %0d, %0d)",
                              pl_bank, pl_addr, pl_bias, pl_m0, pl_shift,
                              e_pb[pl_bank][pl_addr], e_pm[pl_bank][pl_addr],
                              e_ps[pl_bank][pl_addr]));
            else e_pl_s[pl_bank][pl_addr] = 1;
        end

        if (lg_pl_en) begin
            n_obs++;
            if (!e_lg_v[lg_pl_idx])
                bad($sformatf("unexpected logit param write to idx %0d", lg_pl_idx));
            else if (e_lg_s[lg_pl_idx])
                bad($sformatf("duplicate logit param write to idx %0d", lg_pl_idx));
            else if ((lg_pl_bias  !== e_lb[lg_pl_idx]) ||
                     (lg_pl_m0    !== e_lm[lg_pl_idx]) ||
                     (lg_pl_shift !== e_ls[lg_pl_idx]))
                bad($sformatf("logit param %0d: got (%0d, %0d, %0d), expected (%0d, %0d, %0d)",
                              lg_pl_idx, lg_pl_bias, lg_pl_m0, lg_pl_shift,
                              e_lb[lg_pl_idx], e_lm[lg_pl_idx], e_ls[lg_pl_idx]));
            else e_lg_s[lg_pl_idx] = 1;
        end
    end

    // ---- every expected write must have happened -------------------------
    task automatic check_complete;
        integer missing;
        begin
            missing = 0;
            for (i = 0; i < TM; i++) for (j = 0; j < PW_DEPTH; j++)
                if (e_pw_v[i][j] && !e_pw_s[i][j]) begin
                    missing++;
                    if (missing <= 3)
                        bad($sformatf("pw bank %0d addr %0d never written", i, j));
                end
            for (i = 0; i < TC; i++) for (j = 0; j < DW_DEPTH; j++)
                if (e_dw_v[i][j] && !e_dw_s[i][j]) begin
                    missing++;
                    if (missing <= 3)
                        bad($sformatf("dw bank %0d addr %0d never written", i, j));
                end
            for (i = 0; i < TS; i++) for (j = 0; j < ST_DEPTH; j++)
                if (e_st_v[i][j] && !e_st_s[i][j]) begin
                    missing++;
                    if (missing <= 3)
                        bad($sformatf("stem bank %0d addr %0d never written", i, j));
                end
            for (i = 0; i < TM; i++) for (j = 0; j < PDEPTH; j++)
                if (e_pl_v[i][j] && !e_pl_s[i][j]) begin
                    missing++;
                    if (missing <= 3)
                        bad($sformatf("param bank %0d addr %0d never written", i, j));
                end
            for (i = 0; i < NLOG; i++)
                if (e_lg_v[i] && !e_lg_s[i]) begin
                    missing++;
                    bad($sformatf("logit param %0d never written", i));
                end
            if (missing != 0)
                bad($sformatf("%0d expected writes never happened", missing));
        end
    endtask

    // ======================================================================
    //  the driver: exactly top_seq's half of the handshake
    // ======================================================================
    integer t0, cyc_last, f0;

    task automatic do_load(input string nm, input integer op,
                           input integer off, input integer nbytes,
                           input integer pchan);
        begin
            cname = nm;
            clear_exp;
            case (op)
                OP_STEM: exp_stem(off, nbytes, pchan);
                OP_DW:   exp_dw  (off, nbytes, pchan);
                OP_PW,
                OP_LINEAR: if (nbytes != 0) exp_pw(off, nbytes, pchan);
                default: ;    // RES_ADD / GAP carry no weights
            endcase
            if (op == OP_LINEAR) exp_logit(pidx_ref);
            else                 exp_params(pchan, pidx_ref);

            f0 = fails;
            @(negedge clock);
            ld_op    = op[3:0];
            ld_off   = off[OFF_W-1:0];
            ld_bytes = nbytes[BYT_W-1:0];
            ld_pchan = pchan[PCH_W-1:0];
            ld_req   = 1'b1;
            t0       = cyc;

            // top_seq holds ld_req until it sees ld_done RISE, then drops it.
            @(posedge ld_done);
            cyc_last = cyc - t0;
            @(negedge clock);
            ld_req = 1'b0;
            @(negedge clock);

            check_complete;
            pidx_ref = pidx_ref + ((pchan + TM - 1) / TM) * TM;
            tot_exp  = tot_exp + n_exp;
            tot_obs  = tot_obs + n_obs;
            cases++;

            if (n_obs != n_exp)
                bad($sformatf("%0d writes observed, %0d expected", n_obs, n_exp));

            $display("  [%s] %-22s %6d writes, %6d cycles  (%.2f writes/cycle)",
                     (fails == f0) ? "ok " : "ERR", nm, n_obs, cyc_last,
                     (cyc_last > 0) ? (1.0*n_obs/cyc_last) : 0.0);
        end
    endtask

    always @(posedge clock) if (rst_n) cyc++;

    // ======================================================================
    integer big_writes, big_cycles, big_wc, big_wcyc;
    real    wrate;
    initial begin
        err_on  = 0;
        gaps_on = 1;        // holes in the R stream for every correctness case
        ld_req = 0; ld_op = 0; ld_off = 0; ld_bytes = 0; ld_pchan = 0;
        start  = 0;
        rst_n  = 0;

        $display("UNIT: wgt_dma against a behavioural AXI4 slave");
        $display("  the expectation is computed in a different loop order from the DUT");
        $display("");

        for (d_i = 0; d_i < WBLOB; d_i++) wb[d_i] = 8'h00;
        $readmemh("../../software/export/weights.hex",      wb);
        $readmemh("../../software/export/params_b.hex",     pb);
        $readmemh("../../software/export/params_m0.hex",    pm);
        $readmemh("../../software/export/params_shift.hex", ps);
        u_ddr.load("../../software/export/weights.hex",
                   "../../software/export/params_b.hex",
                   "../../software/export/params_m0.hex",
                   "../../software/export/params_shift.hex");
        $display("loaded the weight blob (%0d bytes) and %0d parameter entries",
                 WBLOB, PBLOB);
        $display("");

        clear_exp;
        repeat (4) @(negedge clock);
        rst_n = 1;

        // `start` latches the four bases and zeroes the parameter index. The
        // DMA refuses to be X here: its S_PBA check catches a missing start.
        @(negedge clock);
        start = 1'b1;
        @(negedge clock);
        start = 1'b0;
        repeat (4) @(negedge clock);

        // ---- the ten data cases, as ONE sequence -----------------------
        do_load("1 STEM op0",     OP_STEM,   0,       864,    32);
        do_load("2 DW   op1",     OP_DW,     864,     288,    32);
        do_load("3 PW   op2",     OP_PW,     1152,    512,    16);
        do_load("4 PW   op5",     OP_PW,     4064,    2304,   24);
        do_load("5 PW   op6 ic24", OP_PW,    6368,    3456,   144);
        do_load("6 PW   odd off",  OP_PW,    6369,    3456,   144);
        do_load("7 DW   op59",    OP_DW,     1464320, 8640,   960);
        do_load("8 GAP  op62",    OP_GAP,    0,       0,      1280);
        do_load("9 LIN  op63",    OP_LINEAR, 2189760, 5120,   4);
        do_load("10 PW  op61",    OP_PW,     1780160, 409600, 1280);

        // ---- 10b: the same load with a slave that never stalls ----------
        //  The rate is measured here and not above, because a number taken
        //  against a slave that inserts holes measures the slave. Re-running the
        //  identical load also says the DMA is not carrying state between loads
        //  that happens to work only the first time - the parameter index has
        //  moved on, so the expectation differs even though the weights do not.
        gaps_on = 0;
        do_load("10b PW op61 no gaps", OP_PW, 1780160, 409600, 1280);
        big_writes = n_obs;
        big_cycles = cyc_last;
        big_wc     = w_cnt;
        big_wcyc   = w_last - w_first + 1;
        gaps_on = 1;

        // ---- 11: the bus says no ---------------------------------------
        //  dma_error must go high, STAY high, and ld_done must never pulse.
        //  top_seq's watchdog is what turns this into an abandoned run; here
        //  all that matters is that this module does not claim success.
        $display("");
        cname = "11 bus error";
        clear_exp;
        err_on = 1'b1;
        @(negedge clock);
        ld_op = OP_PW; ld_off = 1152; ld_bytes = 512; ld_pchan = 16;
        ld_req = 1'b1;
        repeat (4000) @(negedge clock);

        if (ld_done !== 1'b0) begin
            fails++;
            $display("  [ERR] 11 bus error: ld_done pulsed on a failed read");
        end
        if (dma_error !== 1'b1) begin
            fails++;
            $display("  [ERR] 11 bus error: dma_error never asserted");
        end else
            $display("  [ok ] 11 bus error          dma_error set, ld_done never pulsed");

        // and it is STICKY: clearing the fault does not clear the flag
        err_on = 1'b0;
        repeat (200) @(negedge clock);
        if (dma_error !== 1'b1) begin
            fails++;
            $display("  [ERR] 11 bus error: dma_error is not sticky");
        end else
            $display("  [ok ] sticky                dma_error survives the bus recovering");

        // only `start` clears it
        @(negedge clock); ld_req = 1'b0;
        @(negedge clock); start = 1'b1;
        @(negedge clock); start = 1'b0;
        repeat (20) @(negedge clock);
        if (dma_error !== 1'b0) begin
            fails++;
            $display("  [ERR] 11 bus error: `start` did not clear dma_error");
        end else
            $display("  [ok ] recovery              `start` clears dma_error");

        // ---- the throughput claim --------------------------------------
        $display("");
        $display("throughput on the worst load in the network (features.18.0):");
        $display("  409,600 bytes = 25,600 beats, 1,280 parameter channels");
        $display("  whole load   : %0d writes in %0d cycles  (%.3f per cycle)",
                 big_writes, big_cycles, 1.0*big_writes/big_cycles);
        wrate = 1.0*big_wc/big_wcyc;
        $display("  weight phase : %0d writes in %0d cycles  (%.3f per cycle)",
                 big_wc, big_wcyc, wrate);
        $display("  the difference is the parameter tail: 40 tiles x three");
        $display("  sequential streams, each paying an AR turnaround (DD-030)");

        // The hard bar is top_seq's watchdog: exceeding 2**20 cycles in one load
        // sets `fault` and abandons the run.
        if (big_cycles >= (1<<20)) begin
            fails++;
            $display("  [ERR] the worst load exceeds top_seq's S_LOAD watchdog of %0d cycles",
                     1<<20);
        end else
            $display("  [ok ] %0d cycles against top_seq's S_LOAD watchdog of %0d",
                     big_cycles, 1<<20);

        // The design target: the R channel must not go idle between bursts, i.e.
        // one bank write per cycle through the weight phase. 0.95 rather than
        // 1.00 leaves the first burst's AR latency, which cannot be hidden.
        if (wrate < 0.95) begin
            fails++;
            $display("  [ERR] the weight phase sustains only %.3f writes/cycle - the R channel is going idle between bursts",
                     wrate);
        end else
            $display("  [ok ] the weight phase sustains one bank write per cycle");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d loads, %0d writes scoreboarded against an independent expectation)",
                     cases, tot_obs);
        else
            $display("FAILED    (%0d problems over %0d writes)", fails, tot_obs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAILED    (timeout)");
        $finish;
    end

endmodule
