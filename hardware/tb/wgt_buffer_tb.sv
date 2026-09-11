`timescale 1ns / 1ps
//============================================================================
//  wgt_buffer_tb.sv  -  self-checking testbench for rtl/control/wgt_buffer.v
//
//  The thing that actually matters about this module is a CONTRACT, not a
//  computation: the byte written as (bank m, entry addr, tap j) must come back
//  at bit position (m*TN + j)*DATA_W of the 4096-bit read word, because that
//  word is wired straight into pe_array's `w` port with no reshuffling. If the
//  bank ordering or the tap ordering is off, every dot product in the network
//  is quietly wrong. So the testbench fills every (bank, addr, tap) with a
//  DISTINCT value and checks all 512 bytes of every entry - the same idea that
//  caught the wiring mutations in pe_array_tb.
//
//  Also checked:
//    - bank isolation: writing one bank must not disturb the other 31
//    - the TAIL CONTRACT: entries never written read back as zero, which is
//      what makes zero-padded lanes and taps contribute nothing
//    - read latency is exactly one cycle, not zero and not two
//    - a realistic layer load, tail included, read back in address order
//
//  Run:  bash scripts/run_sim.sh wgt_buffer
//============================================================================
module wgt_buffer_tb;

    localparam DATA_W = 8;
    localparam TM     = 32;
    localparam TN     = 16;
    localparam DEPTH  = 1024;
    localparam ADDR_W = 10;
    localparam BANK_W = 5;
    localparam BANK_BITS = TN*DATA_W;      // 128

    logic clock;
    logic                    wr_en, rd_en;
    logic [BANK_W-1:0]       wr_bank;
    logic [ADDR_W-1:0]       wr_addr, rd_addr;
    logic [BANK_BITS-1:0]    wr_data;
    wire  [TM*BANK_BITS-1:0] rd_data;

    wgt_buffer #(.DATA_W(DATA_W), .TM(TM), .TN(TN),
                 .DEPTH(DEPTH), .ADDR_W(ADDR_W), .BANK_W(BANK_W)) u_dut (
        .clock(clock),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // a distinct byte for every (bank, addr, tap) triple
    function automatic [7:0] pat(input integer b, input integer a, input integer j);
        pat = 8'((b*37 + a*11 + j*3 + 1) & 8'hFF);
    endfunction

    // write one 128-bit bank word
    task automatic wr_word(input integer b, input integer a, input integer base_tap_src);
        integer j;
        begin
            @(negedge clock);
            for (j = 0; j < TN; j++)
                wr_data[j*DATA_W +: DATA_W] = (base_tap_src < 0) ? 8'h00 : pat(b, a, j);
            wr_bank = b[BANK_W-1:0];
            wr_addr = a[ADDR_W-1:0];
            wr_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            wr_en = 1'b0;
        end
    endtask

    // issue a read and return the 4096-bit word (1-cycle latency)
    task automatic rd_word(input integer a, output logic [TM*BANK_BITS-1:0] d);
        begin
            @(negedge clock);
            rd_addr = a[ADDR_W-1:0];
            rd_en   = 1'b1;
            @(posedge clock);          // memory captures -> dout updates
            @(negedge clock);
            rd_en   = 1'b0;
            d       = rd_data;
        end
    endtask

    // check a whole entry against the pattern (or against zero)
    task automatic check_entry(input integer a, input bit expect_zero, input string tag);
        logic [TM*BANK_BITS-1:0] d;
        logic [7:0] got, exp;
        integer b, j, bad;
        begin
            rd_word(a, d);
            bad = 0;
            for (b = 0; b < TM; b++)
                for (j = 0; j < TN; j++) begin
                    got = d[(b*TN + j)*DATA_W +: DATA_W];
                    exp = expect_zero ? 8'h00 : pat(b, a, j);
                    if (got !== exp) begin
                        bad++;
                        if (bad <= 4)
                            $display("  [ERR] %-16s addr=%0d bank=%0d tap=%0d : got %02h expected %02h",
                                     tag, a, b, j, got, exp);
                    end
                end
            total++;
            if (bad != 0) fails++;
        end
    endtask

    logic [TM*BANK_BITS-1:0] d0, d1;
    integer a, b, j, k, bad;
    initial begin
        wr_en = 0; rd_en = 0; wr_bank = 0; wr_addr = 0; rd_addr = 0; wr_data = 0;
        repeat (2) @(negedge clock);

        $display("wgt_buffer: %0d banks x %0d bit = %0d bit/read, depth %0d",
                 TM, BANK_BITS, TM*BANK_BITS, DEPTH);
        $display("");

        // ---- 1. tail contract: nothing written yet, everything reads zero ----
        $display("tail contract (unwritten entries must read as zero):");
        check_entry(0,   1'b1, "virgin addr 0");
        check_entry(517, 1'b1, "virgin addr 517");
        if (fails == 0) $display("  [ok ] unwritten entries read 0 - padded lanes contribute nothing");

        // ---- 2. bit-position contract, full sweep of a few entries ----------
        $display("");
        $display("bit-position contract (bank m, tap j -> bit (m*TN+j)*8):");
        for (k = 0; k < 3; k++) begin
            a = (k == 0) ? 0 : ((k == 1) ? 1 : 799);   // 799 = last real entry
            for (b = 0; b < TM; b++) wr_word(b, a, 0);
            check_entry(a, 1'b0, $sformatf("full entry a=%0d", a));
        end
        if (fails == 0)
            $display("  [ok ] all %0d bytes land where pe_array expects them", 3*TM*TN);

        // ---- 3. bank isolation ----------------------------------------------
        $display("");
        $display("bank isolation:");
        // entry 42 : write ONLY bank 9, everything else must stay zero
        wr_word(9, 42, 0);
        rd_word(42, d0);
        bad = 0;
        for (b = 0; b < TM; b++)
            for (j = 0; j < TN; j++) begin
                logic [7:0] got = d0[(b*TN + j)*DATA_W +: DATA_W];
                logic [7:0] exp = (b == 9) ? pat(9, 42, j) : 8'h00;
                if (got !== exp) begin
                    bad++;
                    if (bad <= 4)
                        $display("  [ERR] isolation addr=42 bank=%0d tap=%0d : got %02h expected %02h",
                                 b, j, got, exp);
                end
            end
        total++;
        if (bad != 0) fails++;
        else $display("  [ok ] writing bank 9 left the other %0d banks untouched", TM-1);

        // entry 0 must be unchanged by the write to entry 42
        check_entry(0, 1'b0, "addr 0 after wr 42");

        // ---- 4. read latency is exactly one cycle ---------------------------
        $display("");
        $display("read timing:");
        // Park the output on a DIFFERENT entry first (42: only bank 9 set),
        // then read entry 0. Before the clock edge the output must still show
        // entry 42; after it, entry 0. Reading the same address twice could
        // not tell a registered read from a combinational one.
        rd_word(42, d0);                      // dout now holds entry 42
        @(negedge clock);
        rd_addr = 10'd0; rd_en = 1'b1;
        #1;
        d0 = rd_data;                 // still entry 42 -> bank 0 reads zero
        @(posedge clock);
        @(negedge clock);
        rd_en = 1'b0;
        d1 = rd_data;                 // now entry 0 -> bank 0 holds pat(0,0,j)
        total++;
        if (d0[(0*TN + 0)*DATA_W +: DATA_W] !== 8'h00) begin
            fails++;
            $display("  [ERR] read is combinational: new data appeared before the clock edge");
        end else if (d1[(0*TN + 0)*DATA_W +: DATA_W] !== pat(0, 0, 0)) begin
            fails++;
            $display("  [ERR] data not available one cycle after rd_en (got %02h, expected %02h)",
                     d1[(0*TN + 0)*DATA_W +: DATA_W], pat(0, 0, 0));
        end else
            $display("  [ok ] data valid exactly one cycle after rd_en");

        // ---- 5. a realistic layer load, tail included -----------------------
        // features.2.conv.2 shape: OC=24 -> 1 oc tile with 8 padded lanes,
        // IC=96 -> 6 ic tiles. Loader writes the full rectangle, zeros in the pad.
        $display("");
        $display("realistic load (OC=24 of %0d lanes, IC=96 -> 6 entries):", TM);
        for (a = 0; a < 6; a++)
            for (b = 0; b < TM; b++)
                wr_word(b, 900 + a, (b < 24) ? 0 : -1);   // -1 = write zeros
        bad = 0;
        for (a = 0; a < 6; a++) begin
            rd_word(900 + a, d0);
            for (b = 0; b < TM; b++)
                for (j = 0; j < TN; j++) begin
                    logic [7:0] got = d0[(b*TN + j)*DATA_W +: DATA_W];
                    logic [7:0] exp = (b < 24) ? pat(b, 900 + a, j) : 8'h00;
                    if (got !== exp) bad++;
                end
        end
        total++;
        if (bad != 0) begin
            fails++;
            $display("  [ERR] realistic load: %0d bytes wrong", bad);
        end else
            $display("  [ok ] 24 real lanes correct, 8 padded lanes read 0");

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d checks)", total);
        else            $display("FAILED    (%0d / %0d checks)", fails, total);
        $finish;
    end

endmodule
