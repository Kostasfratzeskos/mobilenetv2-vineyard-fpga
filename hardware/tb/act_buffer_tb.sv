`timescale 1ns / 1ps
//============================================================================
//  act_buffer_tb.sv  -  self-checking testbench for rtl/control/act_buffer.v
//
//  The contract under test is the WIDTH CONVERSION: entries are written TM=32
//  channels at a time (one oc_tile result from the array) and read back TN=16
//  channels at a time (one ic_tile for the next layer). Getting the halves
//  the wrong way round, or failing to pipeline rd_sel with the data, would
//  silently feed every layer the wrong 16 channels.
//
//  The central case therefore replays a real layer end to end: write a feature
//  map the way the array would, then read it the way the next layer's addr_gen
//  will, using addr = pix*ceil(C/TM) + (ict>>1) and sel = ict[0], and check
//  every channel of every tile. Three channel counts are used because they
//  stress different corners of that mapping:
//      C=96  clean, 3 entries per pixel, 6 tiles
//      C=24  one entry, the upper half is 8 real channels + 8 of padding
//      C=48  two entries, 3 tiles - the last tile is the LOWER half of entry 1
//
//  DEPTH is small here; the behaviour does not depend on it and a 65,536-entry
//  memory would only slow the run down.
//
//  Run:  bash scripts/run_sim.sh act_buffer
//============================================================================
module act_buffer_tb;

    localparam DATA_W = 8;
    localparam TM     = 32;
    localparam TN     = 16;
    localparam SEL_W  = 1;
    localparam DEPTH  = 2048;
    localparam ADDR_W = 16;

    localparam ENT_BITS  = TM*DATA_W;     // 256
    localparam WORD_BITS = TN*DATA_W;     // 128

    logic clock;
    logic                  wr_en, rd_en;
    logic [ADDR_W-1:0]     wr_addr, rd_addr;
    logic [ENT_BITS-1:0]   wr_data;
    logic [SEL_W-1:0]      rd_sel;
    wire  [WORD_BITS-1:0]  rd_data;

    act_buffer #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .SEL_W(SEL_W),
                 .DEPTH(DEPTH), .ADDR_W(ADDR_W)) u_dut (
        .clock(clock),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_sel(rd_sel), .rd_data(rd_data)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // value of channel c at pixel p -- distinct for every (p,c)
    function automatic [7:0] chan(input integer p, input integer c);
        chan = 8'((p*13 + c*7 + 1) & 8'hFF);
    endfunction

    task automatic wr_entry(input integer a, input integer p, input integer c_base,
                            input integer c_total);
        integer k, c;
        begin
            @(negedge clock);
            for (k = 0; k < TM; k++) begin
                c = c_base + k;
                // beyond the real channel count the array writes whatever its
                // padded lanes produced -- model that as a recognisable value
                wr_data[k*DATA_W +: DATA_W] = (c < c_total) ? chan(p, c) : 8'hEE;
            end
            wr_addr = a[ADDR_W-1:0];
            wr_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            wr_en = 1'b0;
        end
    endtask

    task automatic rd_word(input integer a, input integer s,
                           output logic [WORD_BITS-1:0] d);
        begin
            @(negedge clock);
            rd_addr = a[ADDR_W-1:0];
            rd_sel  = s[SEL_W-1:0];
            rd_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            rd_en = 1'b0;
            d     = rd_data;
        end
    endtask

    // ------------------------------------------------------------------
    //  Replay one layer: write it as the array would, read it as the next
    //  layer's addr_gen will, and check every channel of every tile.
    // ------------------------------------------------------------------
    task automatic replay_layer(input integer npix, input integer nchan, input string tag);
        integer ents, tiles, p, e, t, j, c, bad;
        logic [WORD_BITS-1:0] d;
        logic [7:0] got, exp;
        begin
            ents  = (nchan + TM - 1) / TM;      // entries per pixel
            tiles = (nchan + TN - 1) / TN;      // ic_tiles per pixel
            bad   = 0;

            for (p = 0; p < npix; p++)
                for (e = 0; e < ents; e++)
                    wr_entry(p*ents + e, p, e*TM, nchan);

            for (p = 0; p < npix; p++)
                for (t = 0; t < tiles; t++) begin
                    rd_word(p*ents + (t >> 1), t & 1, d);
                    for (j = 0; j < TN; j++) begin
                        c   = t*TN + j;
                        got = d[j*DATA_W +: DATA_W];
                        exp = (c < nchan) ? chan(p, c) : 8'hEE;
                        if (got !== exp) begin
                            bad++;
                            if (bad <= 5)
                                $display("  [ERR] %-12s pix=%0d tile=%0d ch=%0d : got %02h expected %02h",
                                         tag, p, t, c, got, exp);
                        end
                    end
                end

            total++;
            if (bad != 0) begin
                fails++;
                $display("  [ERR] %-12s %0d bytes wrong", tag, bad);
            end else
                $display("  [ok ] %-12s %0d px x %0d ch : %0d entries -> %0d tiles, all %0d channels",
                         tag, npix, nchan, ents, tiles, npix*tiles*TN);
        end
    endtask

    logic [WORD_BITS-1:0] d0, d1;
    integer j, bad;
    initial begin
        wr_en = 0; rd_en = 0; wr_addr = 0; rd_addr = 0; wr_data = 0; rd_sel = 0;
        repeat (2) @(negedge clock);

        $display("act_buffer: entry = %0d ch (%0d bit), read word = %0d ch (%0d bit)",
                 TM, ENT_BITS, TN, WORD_BITS);
        $display("");

        // ---- 1. the two halves of one entry ------------------------------
        $display("half selection:");
        wr_entry(7, 0, 0, TM);              // channels 0..31 of pixel 0
        rd_word(7, 0, d0);
        rd_word(7, 1, d1);
        bad = 0;
        for (j = 0; j < TN; j++) begin
            if (d0[j*DATA_W +: DATA_W] !== chan(0, j))      bad++;
            if (d1[j*DATA_W +: DATA_W] !== chan(0, TN + j)) bad++;
        end
        total++;
        if (bad != 0) begin
            fails++;
            $display("  [ERR] half selection wrong in %0d of %0d bytes", bad, 2*TN);
        end else
            $display("  [ok ] sel=0 gives channels 0-%0d, sel=1 gives %0d-%0d",
                     TN-1, TN, TM-1);

        // ---- 2. rd_sel must be pipelined WITH the address ----------------
        // Present address and sel together, then change sel immediately after.
        // If sel were used combinationally at the output the data would follow
        // the new value instead of the one that accompanied the address.
        $display("");
        $display("rd_sel pipelining:");
        @(negedge clock);
        rd_addr = 16'd7; rd_sel = 1'b1; rd_en = 1'b1;
        @(posedge clock);
        @(negedge clock);
        rd_en = 1'b0; rd_sel = 1'b0;        // change sel AFTER the capture
        #1;
        total++;
        if (rd_data[0 +: DATA_W] !== chan(0, TN)) begin
            fails++;
            $display("  [ERR] output followed the late rd_sel: got %02h expected %02h",
                     rd_data[0 +: DATA_W], chan(0, TN));
        end else
            $display("  [ok ] sel travels with the data, not with the output mux");

        // ---- 3. address isolation ----------------------------------------
        $display("");
        $display("address isolation:");
        wr_entry(8, 1, 0, TM);
        rd_word(7, 0, d0);
        total++;
        if (d0[0 +: DATA_W] !== chan(0, 0)) begin
            fails++;
            $display("  [ERR] entry 7 disturbed by a write to entry 8");
        end else
            $display("  [ok ] writing entry 8 left entry 7 intact");

        // ---- 4. real layer shapes ----------------------------------------
        $display("");
        $display("layer replay (write as the array does, read as addr_gen will):");
        replay_layer(16, 96, "C=96");     // clean: 3 entries, 6 tiles
        replay_layer(16, 24, "C=24");     // 1 entry, upper half half-padded
        replay_layer(16, 48, "C=48");     // 2 entries, 3 tiles - odd split
        replay_layer(8,  16, "C=16");     // 1 entry, only the lower half used
        replay_layer(4,  320, "C=320");   // 10 entries, 20 tiles

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d checks)", total);
        else            $display("FAILED    (%0d / %0d checks)", fails, total);
        $finish;
    end

endmodule
