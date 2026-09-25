`timescale 1ns / 1ps
//============================================================================
//  axi_lite_csr_tb.sv  -  UNIT: the control registers, register by register
//
//  accel_axi_tb proves the CSR works well enough to run an inference. What it
//  cannot show is the behaviour on the paths a working PS never takes, and those
//  are most of this module: six SLVERR guards, a sticky-bit clear, and a result
//  latch whose whole purpose is to be right in a window that a successful run
//  never looks at. So they are driven here on purpose, one at a time.
//
//  ---- the test that matters most ---------------------------------------
//
//  Case 7. logit_out does NOT hold `logits` - its header says so
//  (logit_out.v:212-217): "requantize's output register free-runs, so `logits`
//  only ever means anything in a `logits_valid` cycle". So this testbench pulses
//  logits_valid with one value, then CHANGES `logits` to something else while
//  valid is low, and reads RESULT_LO/HI back. If the CSR forwarded instead of
//  latching, the read returns the second value - and on real hardware that
//  second value is whatever requantize's free-running register happens to hold,
//  which logit_out's own header describes as "last frame's confident prediction
//  of a healthy leaf". A test that only ever drove logits once would pass
//  against a plain wire.
//
//  ---- and the guard that is not obvious --------------------------------
//
//  Case 12. START while `running` must be REFUSED, not ignored. top_seq ignores
//  `start` outside S_IDLE/S_ERR, so a mid-run START looks harmless - but
//  wgt_dma's `start` is unconditional and resets its running parameter index, so
//  the sequencer would keep going while every later parameter load read from the
//  wrong place in the blob. The run would finish. With wrong biases.
//
//  Run:  bash scripts/run_sim.sh axi_lite_csr
//============================================================================
module axi_lite_csr_tb;

    localparam AXI_ADDR_W = 32;
    localparam ADDR_W     = 13;
    localparam DATA_W     = 32;
    localparam NI_W       = 8;
    localparam PGA_W      = 9;
    localparam PW_W       = 32;
    localparam NLOG       = 4;
    localparam LOG_W      = 16;
    localparam IDX_W      = 2;
    localparam [31:0] ID_MAGIC = 32'h56_49_4E_45;

    // the map, mirrored here rather than imported: a second copy is the point,
    // because a typo in the RTL's decode and a typo here will not agree.
    localparam int A_CTRL       = 'h00,
                   A_N_INSTR    = 'h04,
                   A_IRQ_EN     = 'h08,
                   A_STATUS_CLR = 'h0C,
                   A_STATUS     = 'h10,
                   A_WGT_BASE   = 'h14,
                   A_PB_BASE    = 'h18,
                   A_PM_BASE    = 'h1C,
                   A_PS_BASE    = 'h20,
                   A_RESULT_LO  = 'h24,
                   A_RESULT_HI  = 'h28,
                   A_ARGMAX     = 'h2C,
                   A_ID         = 'h30,
                   A_PROG       = 'h1000;

    // STATUS bit positions
    localparam int S_RUNNING = 0, S_DONE = 1, S_FAULT = 2, S_DMA = 3,
                   S_TAG = 4, S_RES = 5;

    logic clock, rst_n;

    logic [ADDR_W-1:0]   al_awaddr;
    logic                al_awvalid;
    wire                 al_awready;
    logic [DATA_W-1:0]   al_wdata;
    logic [DATA_W/8-1:0] al_wstrb;
    logic                al_wvalid;
    wire                 al_wready;
    wire [1:0]           al_bresp;
    wire                 al_bvalid;
    logic                al_bready;
    logic [ADDR_W-1:0]   al_araddr;
    logic                al_arvalid;
    wire                 al_arready;
    wire [DATA_W-1:0]    al_rdata;
    wire [1:0]           al_rresp;
    wire                 al_rvalid;
    logic                al_rready;

    wire                    start;
    wire [NI_W-1:0]         n_instr;
    wire [AXI_ADDR_W-1:0]   wgt_base, pb_base, pm_base, ps_base;
    wire                    pg_en;
    wire [PGA_W-1:0]        pg_addr;
    wire [PW_W-1:0]         pg_data;

    logic                   running, done, fault, dma_error, tag_error;
    logic [NI_W-1:0]        pc;
    logic [NLOG*LOG_W-1:0]  logits;
    logic                   logits_valid;
    logic [IDX_W-1:0]       argmax;
    logic                   argmax_valid;
    wire                    irq;

    axi_lite_csr #(
        .AXI_ADDR_W(AXI_ADDR_W), .ADDR_W(ADDR_W), .DATA_W(DATA_W),
        .NI_W(NI_W), .PGA_W(PGA_W), .PW_W(PW_W),
        .NLOG(NLOG), .LOG_W(LOG_W), .IDX_W(IDX_W), .ID_MAGIC(ID_MAGIC)
    ) u_csr (
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
        .start(start), .n_instr(n_instr),
        .wgt_base(wgt_base), .pb_base(pb_base),
        .pm_base(pm_base), .ps_base(ps_base),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .running(running), .done(done), .fault(fault),
        .dma_error(dma_error), .tag_error(tag_error), .pc(pc),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid),
        .irq(irq)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0;
    string  cname = "init";

    `include "axi_lite_master.svh"

    // ---- watch the one-cycle outputs -------------------------------------
    integer start_pulses = 0, pg_writes = 0;
    integer start_width = 0, worst_width = 0;
    reg [PGA_W-1:0] last_pg_addr;
    reg [PW_W-1:0]  last_pg_data;

    always @(posedge clock) if (rst_n) begin
        if (start) begin
            start_width++;
            if (start_width > worst_width) worst_width = start_width;
        end else begin
            if (start_width > 0) start_pulses++;
            start_width = 0;
        end
        if (pg_en) begin
            pg_writes++;
            last_pg_addr = pg_addr;
            last_pg_data = pg_data;
        end
    end

    task automatic banner(input string s);
        begin
            cname = s;
        end
    endtask

    task automatic ok(input string s);
        begin
            $display("  [ok ] %s", s);
        end
    endtask

    logic [31:0] d;
    integer      i, f0;
    logic signed [LOG_W-1:0] lg [0:NLOG-1];

    initial begin
        al_idle;
        running = 0; done = 0; fault = 0; dma_error = 0; tag_error = 0;
        pc = 0; logits = '0; logits_valid = 0; argmax = 0; argmax_valid = 0;
        rst_n = 0;

        $display("UNIT: axi_lite_csr, the registers the PS drives the accelerator with");
        $display("");

        repeat (4) @(negedge clock);
        rst_n = 1;
        repeat (2) @(negedge clock);

        // ---- 1: the aperture is alive ---------------------------------
        banner("1 ID");
        al_check(A_ID, ID_MAGIC, cname);
        ok("1  ID reads the magic word - the aperture is alive");

        // ---- 2: reset defaults ----------------------------------------
        banner("2 reset defaults");
        f0 = fails;
        al_check(A_N_INSTR,  32'h0, cname);   // ZERO on purpose: top_seq's T-1
        al_check(A_WGT_BASE, 32'h0, cname);
        al_check(A_PB_BASE,  32'h0, cname);
        al_check(A_PM_BASE,  32'h0, cname);
        al_check(A_PS_BASE,  32'h0, cname);
        al_check(A_IRQ_EN,   32'h0, cname);
        al_check(A_RESULT_LO, 32'h0, cname);
        al_check(A_RESULT_HI, 32'h0, cname);
        if (fails == f0)
            ok("2  every register resets to zero, n_instr included (T-1 refuses 0)");

        // ---- 3: config write / read-back ------------------------------
        banner("3 config");
        f0 = fails;
        al_wr(A_N_INSTR,  32'd64, cname);
        al_wr(A_WGT_BASE, 32'h1000_0000, cname);
        al_wr(A_PB_BASE,  32'h2000_0000, cname);
        al_wr(A_PM_BASE,  32'h2400_0000, cname);
        al_wr(A_PS_BASE,  32'h2800_0000, cname);
        al_check(A_N_INSTR,  32'd64, cname);
        al_check(A_WGT_BASE, 32'h1000_0000, cname);
        al_check(A_PB_BASE,  32'h2000_0000, cname);
        al_check(A_PM_BASE,  32'h2400_0000, cname);
        al_check(A_PS_BASE,  32'h2800_0000, cname);
        if (n_instr !== 8'd64) begin
            fails++;
            $display("  [ERR] 3: n_instr output is %0d, expected 64", n_instr);
        end
        if (wgt_base !== 32'h1000_0000) begin
            fails++;
            $display("  [ERR] 3: wgt_base output is 0x%08x", wgt_base);
        end
        if (fails == f0) ok("3  config writes read back and reach the output pins");

        // ---- 4: byte strobes ------------------------------------------
        //  A control register is not normally written byte-wise, but honouring
        //  WSTRB is the difference between a byte write and a corrupted word.
        banner("4 byte strobes");
        f0 = fails;
        al_wr_full(A_PB_BASE, 32'hDEAD_BEEF, 4'b0010, AL_OKAY, cname);
        al_check(A_PB_BASE, 32'h2000_BE00, cname);   // only byte 1 changed
        al_wr(A_PB_BASE, 32'h2000_0000, cname);      // put it back
        if (fails == f0) ok("4  WSTRB honoured per byte, the other three untouched");

        // ---- 5: START is a one-cycle pulse ----------------------------
        banner("5 START");
        f0 = fails;
        al_wr(A_CTRL, 32'h1, cname);
        repeat (4) @(negedge clock);
        if (start_pulses !== 1) begin
            fails++;
            $display("  [ERR] 5: start pulsed %0d times, expected 1", start_pulses);
        end
        if (worst_width !== 1) begin
            fails++;
            $display("  [ERR] 5: start was %0d cycles wide, expected 1 - top_seq and wgt_dma both take it as a pulse",
                     worst_width);
        end
        al_check(A_CTRL, 32'h0, cname);     // an action, not a state
        if (fails == f0)
            ok("5  START pulses `start` for exactly one cycle and reads back 0");

        // ---- 6: STATUS reflects the live and the sticky ----------------
        banner("6 STATUS");
        f0 = fails;
        running = 1; pc = 8'd37;
        @(negedge clock);
        al_check_mask(A_STATUS, (1 << S_RUNNING) | (37 << 8),
                      32'h0000_FF01, cname);
        running = 0;
        @(negedge clock);
        // a one-cycle `done` pulse must become a sticky bit - a PS polling a
        // register will essentially never be looking during that one cycle
        done = 1; @(negedge clock); done = 0;
        @(negedge clock);
        al_check_mask(A_STATUS, (1 << S_DONE), (1 << S_DONE) | 1, cname);
        if (fails == f0)
            ok("6  STATUS: running is live, pc is readable, a one-cycle done goes sticky");

        // ---- 7: the result is LATCHED, not forwarded -------------------
        banner("7 result latch");
        f0 = fails;
        //  Packed BY INDEX rather than as one concatenation. Writing it as
        //  {4444, 3333, -2222, 1111} puts logit 0 in the LOW bits and reads
        //  left-to-right as most-significant-first, which is the opposite order
        //  to the register map - and an expectation written from the visual
        //  order of that concatenation is wrong while looking right. It was, the
        //  first time. The map is: RESULT_LO = {logit 1, logit 0},
        //  RESULT_HI = {logit 3, logit 2}.
        lg[0] =  16'sd1111;
        lg[1] = -16'sd2222;
        lg[2] =  16'sd3333;
        lg[3] =  16'sd4444;
        for (i = 0; i < NLOG; i++) logits[i*LOG_W +: LOG_W] = lg[i];
        argmax = 2'd2;
        @(negedge clock);
        logits_valid = 1; argmax_valid = 1;
        @(negedge clock);
        logits_valid = 0; argmax_valid = 0;
        // Now change `logits` with valid LOW. On hardware this is requantize's
        // free-running output register moving on; the CSR must not follow it.
        logits = {16'hDEAD, 16'hBEEF, 16'hCAFE, 16'hF00D};
        argmax = 2'd0;
        repeat (3) @(negedge clock);
        al_check(A_RESULT_LO, {lg[1], lg[0]}, cname);
        al_check(A_RESULT_HI, {lg[3], lg[2]}, cname);
        al_check_mask(A_ARGMAX, (1 << 2) | 2'd2, 32'h7, cname);
        al_check_mask(A_STATUS, (1 << S_RES), (1 << S_RES), cname);
        if (fails == f0)
            ok("7  logits and argmax LATCHED on valid, not forwarded (logit_out does not hold them)");

        // ---- 8: the error bits --------------------------------------
        banner("8 error bits");
        f0 = fails;
        fault = 1; dma_error = 1; tag_error = 1;
        @(negedge clock);
        al_check_mask(A_STATUS,
                      (1 << S_FAULT) | (1 << S_DMA) | (1 << S_TAG),
                      (1 << S_FAULT) | (1 << S_DMA) | (1 << S_TAG), cname);
        if (fails == f0) ok("8  fault, dma_error and tag_error all reach STATUS");

        // ---- 9: irq ---------------------------------------------------
        banner("9 irq");
        f0 = fails;
        if (irq !== 1'b0) begin
            fails++;
            $display("  [ERR] 9: irq is high with IRQ_EN = 0");
        end
        al_wr(A_IRQ_EN, 32'h2, cname);      // on any error
        @(negedge clock);
        if (irq !== 1'b1) begin
            fails++;
            $display("  [ERR] 9: irq did not assert with an error pending and IRQ_EN[1] set");
        end
        // the sources are still asserted, so clearing the copies cannot help -
        // STATUS is telling the truth and the way out of a fault is a new run
        al_wr(A_STATUS_CLR, 32'h3F, cname);
        @(negedge clock);
        if (irq !== 1'b1) begin
            fails++;
            $display("  [ERR] 9: irq cleared while its source was still asserted - STATUS would be lying");
        end
        fault = 0; dma_error = 0; tag_error = 0;
        @(negedge clock);
        al_wr(A_STATUS_CLR, 32'h3F, cname);
        repeat (2) @(negedge clock);
        if (irq !== 1'b0) begin
            fails++;
            $display("  [ERR] 9: irq still high after the sources dropped and STATUS_CLR");
        end
        al_wr(A_IRQ_EN, 32'h0, cname);
        if (fails == f0)
            ok("9  irq follows the sticky bits, and STATUS_CLR cannot lie about a live source");

        // ---- 10: START clears the sticky bits and the result ----------
        banner("10 START clears");
        f0 = fails;
        done = 1; @(negedge clock); done = 0;
        @(negedge clock);
        al_wr(A_CTRL, 32'h1, cname);
        repeat (3) @(negedge clock);
        al_check_mask(A_STATUS, 32'h0, 32'h3E, cname);     // all sticky bits clear
        al_check(A_RESULT_LO, 32'h0, cname);
        al_check(A_RESULT_HI, 32'h0, cname);
        if (fails == f0)
            ok("10 START clears the sticky bits and zeroes the stale result");

        // ---- 11: the program aperture ---------------------------------
        banner("11 program aperture");
        f0 = fails;
        al_wr(A_PROG + 4*7, 32'hA5A5_1234, cname);
        repeat (2) @(negedge clock);
        if (pg_writes !== 1) begin
            fails++;
            $display("  [ERR] 11: pg_en pulsed %0d times, expected 1", pg_writes);
        end
        if (last_pg_addr !== 9'd7) begin
            fails++;
            $display("  [ERR] 11: pg_addr was %0d, expected 7", last_pg_addr);
        end
        if (last_pg_data !== 32'hA5A5_1234) begin
            fails++;
            $display("  [ERR] 11: pg_data was 0x%08x", last_pg_data);
        end
        // the last word of the 512, to prove the aperture reaches the top
        al_wr(A_PROG + 4*511, 32'h0000_00FF, cname);
        repeat (2) @(negedge clock);
        if (last_pg_addr !== 9'd511) begin
            fails++;
            $display("  [ERR] 11: pg_addr was %0d for the last word, expected 511",
                     last_pg_addr);
        end
        if (fails == f0)
            ok("11 the program aperture drives pg_en/addr/data, word 0 to 511");

        // ---- 12: the guards, one at a time ---------------------------
        //  Each of these must answer SLVERR. The [FAULT] lines the DUT prints
        //  alongside are deliberate and are what a bring-up engineer reads.
        $display("");
        $display("  the SLVERR guards (the [FAULT] lines below are the point):");
        banner("12 guards");
        f0 = fails;

        al_wr_exp('h40, 32'h1, AL_SLVERR, cname);            // unmapped
        al_wr_exp('h34, 32'h1, AL_SLVERR, cname);            // just past the map
        al_rd_exp('h40, d, AL_SLVERR, cname);                // unmapped read
        al_wr_exp(A_STATUS, 32'h1, AL_SLVERR, cname);        // read-only
        al_wr_exp(A_ID, 32'h1, AL_SLVERR, cname);            // read-only
        al_rd_exp(A_PROG, d, AL_SLVERR, cname);              // write-only
        al_wr_exp(A_PROG + 4*600, 32'h1, AL_SLVERR, cname);  // past the aperture
        al_wr_full(A_PROG, 32'h1, 4'b0011, AL_SLVERR, cname);// partial prog word

        running = 1;
        @(negedge clock);
        al_wr_exp(A_N_INSTR, 32'd32, AL_SLVERR, cname);      // config while running
        al_wr_exp(A_WGT_BASE, 32'h0, AL_SLVERR, cname);
        al_wr_exp(A_PROG, 32'h1, AL_SLVERR, cname);          // program while running
        al_wr_exp(A_CTRL, 32'h1, AL_SLVERR, cname);          // START while running
        // ...and none of them had any effect
        al_check(A_N_INSTR, 32'd64, cname);
        al_check(A_WGT_BASE, 32'h1000_0000, cname);
        running = 0;
        @(negedge clock);

        // STATUS_CLR and IRQ_EN are NOT config: they are safe during a run, and
        // refusing them would leave a PS unable to acknowledge an interrupt.
        running = 1;
        @(negedge clock);
        al_wr(A_STATUS_CLR, 32'h3F, cname);
        al_wr(A_IRQ_EN, 32'h0, cname);
        running = 0;
        @(negedge clock);

        if (fails == f0)
            ok("12 six guards answer SLVERR, nothing they refused took effect");

        // one more: the refused START really did not pulse
        if (start_pulses !== 2) begin
            fails++;
            $display("  [ERR] 12: start pulsed %0d times over the whole run, expected 2 - a refused START still pulsed",
                     start_pulses);
        end else
            ok("12 the refused START did not pulse `start` (2 pulses over the run)");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (13 registers, a 512-word aperture and six SLVERR guards)");
        else
            $display("FAILED    (%0d problems)", fails);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAILED    (timeout)");
        $finish;
    end

endmodule
