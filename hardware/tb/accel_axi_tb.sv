`timescale 1ns / 1ps
//============================================================================
//  accel_axi_tb.sv  -  INTEGRATION: the whole network, driven only over AXI
//
//  The third and last of the integration testbenches, and the one that runs the
//  accelerator the way a processor will. Everything the PS does, this file does,
//  in the same order, over the same two interfaces and nothing else:
//
//      read ID                      confirm the aperture is alive
//      write 512 program words       into the 0x1000 aperture
//      write WGT/PB/PM/PS/IMG_BASE   where the five blobs are in DDR
//      write N_INSTR                 64
//      write CTRL bit 1              LOAD_IMAGE
//      poll STATUS bit 7             until the image is in
//      write CTRL bit 0              START
//      poll STATUS bit 1             until done  (the interrupt is checked too)
//      read RESULT_LO/HI, ARGMAX     the answer
//
//  ---- the three integration testbenches, and what each one adds ----------
//
//      accel_tb       a testbench task answers ld_req.        the fast path
//      accel_dma_tb   + the real wgt_dma over AXI4.           the weights are real
//      accel_axi_tb   + the real CSR over AXI-Lite.           the CONTROL is real
//
//  All three run the same program against the same 64 goldens and share
//  accel_check.svh, so the pass criterion is bit-identical by construction. Each
//  step changes exactly ONE thing, which is what makes a failure attributable.
//
//  ---- what only this one can catch --------------------------------------
//
//    * the PS-visible answer. accel_check.svh compares the internal `logits`
//      bus in its valid cycle; this file additionally reads RESULT_LO/HI and
//      ARGMAX back over AXI-Lite AFTER the run and compares those to the golden.
//      Those are different values on a design where the CSR forgot to latch -
//      and getting that wrong is the failure logit_out.v's own header describes
//      as "last frame's confident prediction of a healthy leaf".
//    * `done` as a polled bit rather than an observed pulse. Every other
//      testbench waits on the `done` wire, which a processor cannot do.
//    * the program arriving through a 2 KB aperture rather than a port, 512
//      writes with byte strobes, and the accelerator executing it.
//    * the interrupt actually asserting on a real run.
//
//  ---- and now there is no port left at all ------------------------------
//
//  Since DD-032 the image comes from DDR over the same AXI master as the
//  weights, so accel_axi has nothing on it but two AXI interfaces, a clock, a
//  reset and an interrupt. THIS testbench drives every one of the DUT's inputs
//  through those two interfaces - there is no back door, no hierarchical write
//  and no port poked directly. That is the strongest statement this level of
//  testbench can make, and it is what makes accel_axi droppable into a block
//  design: whatever the PS will do, this file has already done.
//
//  Run:  bash scripts/run_sim.sh accel_axi accel_sys axi_lite_csr wgt_dma \
//          accel_top top_seq pw_feeder pw_out dw_feeder res_feeder \
//          gap_feeder stem_feeder logit_out out_stage pe_array mac_lane \
//          conv1x1 dwconv3x3 conv3x3_std dw_array stem_array line_buffer \
//          avgpool addr_gen wgt_buffer act_buffer img_buffer param_buffer \
//          rq_bank bias_add requantize
//============================================================================
`include "axi_ddr_model.svh"

module accel_axi_tb;

    // ---- geometry, matching accel_axi's defaults --------------------------
    localparam DATA_W  = 8;
    localparam TM      = 32,  TM_LOG = 5;
    localparam TN      = 16,  TN_LOG = 4;
    localparam TC      = 16,  TC_LOG = 4;
    localparam TS      = 8,   TS_LOG = 3;
    localparam CIN     = 3;
    localparam K       = 3;
    localparam AA_W    = 16;
    localparam IA_W    = 16;
    localparam NI_W    = 8;
    localparam PGA_W   = 9;
    localparam PGW     = 32;
    localparam NLOG    = 4;
    localparam IDX_W   = 2;
    localparam LOG_W   = 16;

    localparam AXI_ADDR_W = 32;
    localparam AXI_DATA_W = 128;
    localparam AXI_ID_W   = 4;
    localparam CSR_ADDR_W = 13;
    localparam CSR_DATA_W = 32;
    localparam [31:0] ID_MAGIC = 32'h56_49_4E_45;

    localparam IH = 224, IW = 224;
    localparam NIN    = CIN*IH*IW;
    localparam MAXOUT = 1204224;
    localparam WBLOB  = 2194880;
    localparam PBLOB  = 19264;

    // the register map, mirrored rather than imported
    localparam int A_CTRL     = 'h00, A_N_INSTR   = 'h04, A_IRQ_EN    = 'h08,
                   A_STAT_CLR = 'h0C, A_STATUS    = 'h10, A_WGT_BASE  = 'h14,
                   A_PB_BASE  = 'h18, A_PM_BASE   = 'h1C, A_PS_BASE   = 'h20,
                   A_RESULT_LO= 'h24, A_RESULT_HI = 'h28, A_ARGMAX    = 'h2C,
                   A_ID       = 'h30, A_IMG_BASE  = 'h34,
                   A_PROG     = 'h1000;
    localparam int S_RUNNING = 0, S_DONE = 1, S_FAULT = 2, S_DMA = 3,
                   S_TAG = 4, S_RES = 5, S_IMG_BUSY = 6, S_IMG_DONE = 7;

    // the DDR map the PS will have to honour
    localparam [31:0] WGT_BASE = 32'h1000_0000;
    localparam [31:0] PB_BASE  = 32'h2000_0000;
    localparam [31:0] PM_BASE  = 32'h2400_0000;
    localparam [31:0] PS_BASE  = 32'h2800_0000;
    localparam [31:0] IMG_BASE = 32'h3000_0000;

    // ======================================================================
    logic clock, rst_n;

    // AXI-Lite, driven by the BFM include
    logic [CSR_ADDR_W-1:0]   al_awaddr;
    logic                    al_awvalid;
    wire                     al_awready;
    logic [CSR_DATA_W-1:0]   al_wdata;
    logic [CSR_DATA_W/8-1:0] al_wstrb;
    logic                    al_wvalid;
    wire                     al_wready;
    wire [1:0]               al_bresp;
    wire                     al_bvalid;
    logic                    al_bready;
    logic [CSR_ADDR_W-1:0]   al_araddr;
    logic                    al_arvalid;
    wire                     al_arready;
    wire [CSR_DATA_W-1:0]    al_rdata;
    wire [1:0]               al_rresp;
    wire                     al_rvalid;
    logic                    al_rready;

    // the AXI4 master to DDR
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

    wire                  irq;

    accel_axi #(
        .DATA_W(DATA_W),
        .TM(TM), .TM_LOG(TM_LOG), .TN(TN), .TN_LOG(TN_LOG),
        .TC(TC), .TC_LOG(TC_LOG), .TS(TS), .TS_LOG(TS_LOG),
        .CIN(CIN), .K(K),
        .AA_W(AA_W), .IA_W(IA_W),
        .NI_W(NI_W), .PGA_W(PGA_W), .PW_W(PGW),
        .NLOG(NLOG), .IDX_W(IDX_W), .LOG_W(LOG_W),
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
        .CSR_ADDR_W(CSR_ADDR_W), .CSR_DATA_W(CSR_DATA_W), .ID_MAGIC(ID_MAGIC)
    ) u_axi (
        .clock(clock), .rst_n(rst_n),
        .s_axi_awaddr(al_awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(al_awvalid), .s_axi_awready(al_awready),
        .s_axi_wdata(al_wdata), .s_axi_wstrb(al_wstrb),
        .s_axi_wvalid(al_wvalid), .s_axi_wready(al_wready),
        .s_axi_bresp(al_bresp), .s_axi_bvalid(al_bvalid),
        .s_axi_bready(al_bready),
        .s_axi_araddr(al_araddr), .s_axi_arprot(3'b000),
        .s_axi_arvalid(al_arvalid), .s_axi_arready(al_arready),
        .s_axi_rdata(al_rdata), .s_axi_rresp(al_rresp),
        .s_axi_rvalid(al_rvalid), .s_axi_rready(al_rready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arcache(arcache), .m_axi_arprot(arprot),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
        .irq(irq)
    );

    axi_ddr_model #(
        .ADDR_W(AXI_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W),
        .WGT_BASE(WGT_BASE), .WGT_N(WBLOB),
        .PB_BASE(PB_BASE), .PM_BASE(PM_BASE), .PS_BASE(PS_BASE), .PN(PBLOB),
        .IMG_BASE(IMG_BASE), .IMG_N(CIN*IH*IW),
        .AR_LAT(3), .GAP_MASK(0)
    ) u_ddr (
        .clock(clock), .rst_n(rst_n), .err_on(1'b0), .gaps_on(1'b0),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    // ---- memories this testbench needs ------------------------------------
    reg [31:0] prog     [0:511];
    reg [7:0]  img_mem  [0:NIN-1];
    reg [7:0]  gold_mem [0:MAXOUT-1];
    reg [15:0] gold_log [0:NLOG-1];

    `include "program_ops.svh"

    localparam N_OPS = N_PROG_OPS;

    // ---- what accel_check.svh expects, taken hierarchically ---------------
    //  These stopped being top-level ports when the CSR absorbed them, which is
    //  the whole point of this layer. A testbench may read hierarchy; a PS may
    //  not, and the AXI-Lite readback at the end is what proves the PS does not
    //  need to.
    wire [NLOG*LOG_W-1:0] logits       = u_axi.logits;
    wire                  logits_valid = u_axi.logits_valid;
    wire [IDX_W-1:0]      argmax       = u_axi.argmax;
    wire                  argmax_valid = u_axi.argmax_valid;
    wire                  running      = u_axi.running;
    wire                  done         = u_axi.done;
    wire                  tag_error    = u_axi.tag_error;
    wire                  fault        = u_axi.fault;
    wire                  dma_error    = u_axi.dma_error;

    string cname = "axi";

    `define ACCEL_DUT u_axi.u_sys.u_dut
    `include "accel_check.svh"
    `include "axi_lite_master.svh"

    // ---- did the interrupt ever fire? -------------------------------------
    reg irq_seen;
    always @(posedge clock) begin
        if (!rst_n) irq_seen <= 1'b0;
        else if (irq) irq_seen <= 1'b1;
    end

    // ======================================================================
    integer i;
    integer poll_reads;
    logic [31:0] d, st;
    logic signed [LOG_W-1:0] ax_got, ax_exp;
    integer bad_ax;

    initial begin
        load_op_table;
        $readmemh("../../software/export/program.hex", prog);
        load_input;
        load_gold_logits;
        u_ddr.load("../../software/export/weights.hex",
                   "../../software/export/params_b.hex",
                   "../../software/export/params_m0.hex",
                   "../../software/export/params_shift.hex");
        u_ddr.load_img("../../software/golden/healthy_hl6025/000_input.hex",
                       IH, IW, CIN);

        al_idle;
        rst_n = 0;
        repeat (4) @(negedge clock);
        rst_n = 1;
        repeat (2) @(negedge clock);

        $display("INTEGRATION: accel_axi, the whole network driven ONLY over AXI");
        $display("  AXI-Lite for control and the program, AXI4 for the weights");
        $display("  %0d instructions, one image in, %0d logits out", N_OPS, NLOG);
        $display("");

        // ---- 1: is anything there? ------------------------------------
        al_check(A_ID, ID_MAGIC, "ID");
        $display("  ID reads 0x%08x - the aperture is alive", ID_MAGIC);

        // ---- 2: the program, through the aperture ---------------------
        for (i = 0; i < 8*N_OPS; i++)
            al_wr(A_PROG + 4*i, prog[i], "program");
        $display("  wrote %0d program words through the 0x%04x aperture",
                 8*N_OPS, A_PROG);

        // ---- 3: where the blobs are -----------------------------------
        al_wr(A_WGT_BASE, WGT_BASE, "wgt_base");
        al_wr(A_PB_BASE,  PB_BASE,  "pb_base");
        al_wr(A_PM_BASE,  PM_BASE,  "pm_base");
        al_wr(A_PS_BASE,  PS_BASE,  "ps_base");
        al_wr(A_IMG_BASE, IMG_BASE, "img_base");
        al_wr(A_N_INSTR,  N_OPS,    "n_instr");
        al_wr(A_IRQ_EN,   32'h3,    "irq_en");
        $display("  configured: wgt 0x%08x  b 0x%08x  m0 0x%08x  shift 0x%08x  img 0x%08x",
                 WGT_BASE, PB_BASE, PM_BASE, PS_BASE, IMG_BASE);

        // ---- 4: the image, over AXI-Lite and AXI4 like everything else ---
        //  The last port group is gone (DD-032). Write LOAD_IMAGE, poll until
        //  STATUS says it is in. A PS does exactly this and nothing more.
        al_wr(A_CTRL, 32'h2, "LOAD_IMAGE");
        poll_reads = 0;
        forever begin
            al_rd(A_STATUS, st, "img poll");
            poll_reads++;
            if (st[S_IMG_DONE]) break;
            if (st[S_DMA]) begin
                fails++;
                $display("  [ERR] dma_error while loading the image (STATUS 0x%08x)", st);
                break;
            end
            repeat (200) @(negedge clock);
        end
        if (st[S_IMG_BUSY]) begin
            fails++;
            $display("  [ERR] STATUS says the image load is still busy after it reported done");
        end
        $display("  loaded the %0dx%0d image over AXI4 in %0d polls - no image port remains",
                 IH, IW, poll_reads);
        $display("");

        // ---- 5: go, and POLL for it, the way a processor must ----------
        al_wr(A_CTRL, 32'h1, "START");
        $display("running:");

        poll_reads = 0;
        forever begin
            al_rd(A_STATUS, st, "poll");
            poll_reads++;
            if (st[S_DONE]) break;
            if (st[S_FAULT]) begin
                fails++;
                $display("  [ERR] STATUS reports `fault` mid-run (0x%08x)", st);
                break;
            end
            // a poll every few hundred cycles, which is what a PS would do
            repeat (200) @(negedge clock);
        end
        $display("  STATUS bit %0d observed set after %0d polls", S_DONE, poll_reads);

        // ---- 6: the same golden check as the other two -----------------
        report_tail;

        // ---- 7: what only this testbench can check --------------------
        //  The answer as the PS sees it: read back over AXI-Lite, after the run,
        //  with no knowledge of when logits_valid pulsed.
        $display("");
        $display("the answer as the PS reads it:");
        bad_ax = 0;
        al_rd(A_RESULT_LO, d, "RESULT_LO");
        for (i = 0; i < 2; i++) begin
            ax_got = d[i*LOG_W +: LOG_W];
            ax_exp = gold_log[i];
            if (ax_got !== ax_exp) begin
                bad_ax++;
                $display("  [ERR] RESULT_LO logit %0d: got %0d, golden %0d",
                         i, ax_got, ax_exp);
            end
        end
        al_rd(A_RESULT_HI, d, "RESULT_HI");
        for (i = 0; i < 2; i++) begin
            ax_got = d[i*LOG_W +: LOG_W];
            ax_exp = gold_log[i+2];
            if (ax_got !== ax_exp) begin
                bad_ax++;
                $display("  [ERR] RESULT_HI logit %0d: got %0d, golden %0d",
                         i+2, ax_got, ax_exp);
            end
        end
        fails += bad_ax;
        if (bad_ax == 0)
            // $signed: gold_log is an unsigned reg, so a bare %0d prints
            // -4950 as 60586 and makes a correct line look wrong.
            $display("  [ok ] RESULT_LO/HI over AXI-Lite: %0d %0d %0d %0d, bit-exact",
                     $signed(gold_log[0]), $signed(gold_log[1]),
                     $signed(gold_log[2]), $signed(gold_log[3]));

        al_rd(A_ARGMAX, d, "ARGMAX");
        if (!d[2]) begin
            fails++;
            $display("  [ERR] ARGMAX says no result was captured");
        end else if (d[IDX_W-1:0] !== GOLDEN_ARGMAX[IDX_W-1:0]) begin
            fails++;
            $display("  [ERR] ARGMAX over AXI-Lite: got %0d, golden %0d (%s)",
                     d[IDX_W-1:0], GOLDEN_ARGMAX, GOLDEN_CLASS);
        end else
            $display("  [ok ] ARGMAX over AXI-Lite: class %0d = %s",
                     d[IDX_W-1:0], GOLDEN_CLASS);

        // ---- 8: the rest of the PS-visible contract -------------------
        $display("");
        al_rd(A_STATUS, st, "final STATUS");
        if (st[S_FAULT] || st[S_DMA] || st[S_TAG]) begin
            fails++;
            $display("  [ERR] STATUS still reports an error: 0x%08x", st);
        end else
            $display("  [ok ] STATUS clean: no fault, no dma_error, no tag_error");

        if (st[S_RUNNING]) begin
            fails++;
            $display("  [ERR] STATUS still says running after done");
        end

        if (!irq_seen) begin
            fails++;
            $display("  [ERR] irq never asserted with IRQ_EN = 3");
        end else
            $display("  [ok ] irq asserted on completion");

        // STATUS_CLR must clear `done` now that nothing drives it
        al_wr(A_STAT_CLR, 32'h3F, "STATUS_CLR");
        repeat (2) @(negedge clock);
        al_rd(A_STATUS, st, "STATUS after clear");
        if (st[S_DONE]) begin
            fails++;
            $display("  [ERR] STATUS_CLR did not clear `done`");
        end else
            $display("  [ok ] STATUS_CLR cleared the sticky bits, irq released");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model, %0d ops, driven entirely over AXI-Lite + AXI4)",
                     total, N_OPS);
        else
            $display("FAILED    (%0d mismatches out of %0d)", fails, total);
        $finish;
    end

    initial begin
        #600_000_000;
        $display("FAILED    (timeout)");
        $finish;
    end

endmodule
