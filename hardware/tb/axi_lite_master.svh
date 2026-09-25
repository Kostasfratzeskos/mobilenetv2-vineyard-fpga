//============================================================================
//  axi_lite_master.svh  -  an AXI4-Lite master BFM, as tasks
//
//  `include-d INSIDE a testbench module by axi_lite_csr_tb and accel_axi_tb.
//  An include rather than a separate .sv for the same reason as
//  axi_ddr_model.svh: run_sim.sh resolves its extra sources before it cd's into
//  the work directory, so a relative path to a second file breaks, while the
//  -i include path it hands xvlog is absolute.
//
//  It expects these signals to exist in the including module, driven by nobody
//  else: clock, al_awaddr, al_awvalid, al_awready, al_wdata, al_wstrb,
//  al_wvalid, al_bresp, al_bvalid, al_bready, al_araddr, al_arvalid,
//  al_arready, al_rdata, al_rresp, al_rvalid, al_rready - plus an integer
//  `fails` it increments, and a string `cname` it names in messages.
//
//  ---- AW and W are retired INDEPENDENTLY --------------------------------
//
//  Not a detail. axi_lite_csr captures the two channels separately, precisely so
//  it works against a master that does not present them together, and a BFM that
//  drops both VALIDs on the first READY it happens to see would never exercise
//  that. So each channel's VALID is held until its own READY, and the two can
//  complete on different cycles.
//
//  Every VALID is deasserted on the NEGEDGE after the READY was sampled, never
//  at the clock edge itself, so nothing here races the DUT's own sampling.
//
//  ---- the response is always checked ------------------------------------
//
//  al_wr / al_rd expect OKAY and record a failure otherwise; al_wr_exp /
//  al_rd_exp take the response they expect. That split matters because
//  axi_lite_csr answers SLVERR on purpose in six different situations, and a
//  testbench that ignored BRESP would pass while every one of those guards was
//  broken.
//============================================================================

    localparam [1:0] AL_OKAY = 2'b00, AL_SLVERR = 2'b10;

    task automatic al_idle;
        begin
            al_awaddr  = '0;  al_awvalid = 1'b0;
            al_wdata   = '0;  al_wstrb   = '0;  al_wvalid = 1'b0;
            al_bready  = 1'b0;
            al_araddr  = '0;  al_arvalid = 1'b0;
            al_rready  = 1'b0;
        end
    endtask

    // ---- write, with explicit strobes and an expected response -----------
    task automatic al_wr_full(input int a, input logic [31:0] d,
                              input logic [3:0] strb, input logic [1:0] exp,
                              input string what);
        logic saw_aw, saw_w;
        logic [1:0] resp;
        begin
            @(negedge clock);
            al_awaddr  = a;
            al_awvalid = 1'b1;
            al_wdata   = d;
            al_wstrb   = strb;
            al_wvalid  = 1'b1;
            al_bready  = 1'b1;

            forever begin
                @(posedge clock);
                saw_aw = al_awvalid && al_awready;
                saw_w  = al_wvalid  && al_wready;
                @(negedge clock);
                if (saw_aw) al_awvalid = 1'b0;
                if (saw_w)  al_wvalid  = 1'b0;
                if (!al_awvalid && !al_wvalid) break;
            end

            forever begin
                @(posedge clock);
                if (al_bvalid) begin
                    resp = al_bresp;
                    break;
                end
            end
            @(negedge clock);
            al_bready = 1'b0;

            if (resp !== exp) begin
                fails++;
                $display("  [ERR] %s: write 0x%04x = 0x%08x answered BRESP %b, expected %b",
                         what, a, d, resp, exp);
            end
        end
    endtask

    task automatic al_wr(input int a, input logic [31:0] d, input string what);
        begin al_wr_full(a, d, 4'hF, AL_OKAY, what); end
    endtask

    task automatic al_wr_exp(input int a, input logic [31:0] d,
                             input logic [1:0] exp, input string what);
        begin al_wr_full(a, d, 4'hF, exp, what); end
    endtask

    // ---- read ------------------------------------------------------------
    task automatic al_rd_full(input int a, output logic [31:0] d,
                              input logic [1:0] exp, input string what);
        logic [1:0] resp;
        begin
            @(negedge clock);
            al_araddr  = a;
            al_arvalid = 1'b1;
            al_rready  = 1'b1;

            forever begin
                @(posedge clock);
                if (al_arready) break;
            end
            @(negedge clock);
            al_arvalid = 1'b0;

            forever begin
                @(posedge clock);
                if (al_rvalid) begin
                    d    = al_rdata;
                    resp = al_rresp;
                    break;
                end
            end
            @(negedge clock);
            al_rready = 1'b0;

            if (resp !== exp) begin
                fails++;
                $display("  [ERR] %s: read 0x%04x answered RRESP %b, expected %b",
                         what, a, resp, exp);
            end
        end
    endtask

    task automatic al_rd(input int a, output logic [31:0] d, input string what);
        begin al_rd_full(a, d, AL_OKAY, what); end
    endtask

    task automatic al_rd_exp(input int a, output logic [31:0] d,
                             input logic [1:0] exp, input string what);
        begin al_rd_full(a, d, exp, what); end
    endtask

    // ---- read and compare ------------------------------------------------
    task automatic al_check(input int a, input logic [31:0] expect_d,
                            input string what);
        logic [31:0] got;
        begin
            al_rd(a, got, what);
            if (got !== expect_d) begin
                fails++;
                $display("  [ERR] %s: 0x%04x reads 0x%08x, expected 0x%08x",
                         what, a, got, expect_d);
            end
        end
    endtask

    // ---- read and compare only the bits named by a mask ------------------
    task automatic al_check_mask(input int a, input logic [31:0] expect_d,
                                 input logic [31:0] mask, input string what);
        logic [31:0] got;
        begin
            al_rd(a, got, what);
            if ((got & mask) !== (expect_d & mask)) begin
                fails++;
                $display("  [ERR] %s: 0x%04x reads 0x%08x, expected 0x%08x under mask 0x%08x",
                         what, a, got, expect_d, mask);
            end
        end
    endtask
