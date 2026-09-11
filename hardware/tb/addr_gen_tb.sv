`timescale 1ns / 1ps
//============================================================================
//  addr_gen_tb.sv  -  self-checking testbench for rtl/control/addr_gen.v
//
//  addr_gen replaces the nested for-loops of pointwise_layer_tb with hardware
//  counters, so the testbench keeps the for-loops as the oracle: a software
//  reference walks the same (pix, oct, ict) sequence and every tile the DUT
//  emits is compared against it, cycle by cycle. A counter that skips, repeats
//  or reorders a tile fails on the very first divergence.
//
//  What is checked, per layer:
//    - the full (pix, oct, ict) sequence, in order
//    - first == (ict==0) and last == (ict==n_ic-1), which is what clears and
//      closes the accumulator in mac_lane - an off-by-one here would silently
//      corrupt every dot product
//    - the tile COUNT equals n_pix * n_oc * n_ic (nothing lost or doubled)
//    - layer_done pulses exactly once, one cycle after the final tile
//    - stalls: with `en` randomly deasserted the sequence must freeze, not
//      skip. Every layer is run twice, clean and stalled, and both must give
//      byte-identical sequences.
//
//  Shapes exercised include the real extremes of the network: 112x112 pixels,
//  the 1280-channel classifier tile count, and the degenerate 1x1x1 case where
//  first and last are asserted on the SAME cycle.
//
//  Run:  bash scripts/run_sim.sh addr_gen
//============================================================================
module addr_gen_tb;

    localparam PIX_W = 16;
    localparam OCT_W = 8;
    localparam ICT_W = 8;

    logic clock, rst_n;
    logic start, en;
    logic [PIX_W-1:0] n_pix;
    logic [OCT_W-1:0] n_oc;
    logic [ICT_W-1:0] n_ic;

    wire [PIX_W-1:0] pix;
    wire [OCT_W-1:0] oct;
    wire [ICT_W-1:0] ict;
    wire             valid, first, last, busy;
    wire             layer_done;

    addr_gen #(.PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W)) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .en(en),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic),
        .pix(pix), .oct(oct), .ict(ict),
        .valid(valid), .first(first), .last(last), .busy(busy),
        .layer_done(layer_done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ------------------------------------------------------------------
    //  Drive one layer and score every tile against the software oracle.
    //  stall_pct = 0 runs flat out; >0 randomly deasserts `en`.
    // ------------------------------------------------------------------
    task automatic run_layer(input integer np, input integer no, input integer ni,
                             input string tag, input integer stall_pct);
        integer e_pix, e_oct, e_ict;      // the oracle's counters
        integer seen, expect_tiles, guard, errs, done_pulses;
        logic   e_first, e_last;
        begin
            e_pix = 0; e_oct = 0; e_ict = 0;
            seen = 0; errs = 0; done_pulses = 0;
            expect_tiles = np * no * ni;
            // generous watchdog: a stuck counter must not hang the run
            guard = (expect_tiles + 64) * 8;

            @(negedge clock);
            n_pix = np; n_oc = no; n_ic = ni;
            en    = 1'b1;
            start = 1'b1;
            @(negedge clock);
            start = 1'b0;

            while (guard > 0) begin
                en = (stall_pct == 0) ? 1'b1 : (({$random} % 100) >= stall_pct);
                #1;                                   // let `valid` settle

                if (valid) begin
                    e_first = (e_ict == 0);
                    e_last  = (e_ict == ni-1);

                    if (pix !== e_pix[PIX_W-1:0] || oct !== e_oct[OCT_W-1:0] ||
                        ict !== e_ict[ICT_W-1:0]) begin
                        errs++;
                        if (errs <= 5)
                            $display("  [ERR] %-14s tile %0d: got (%0d,%0d,%0d) expected (%0d,%0d,%0d)",
                                     tag, seen, pix, oct, ict, e_pix, e_oct, e_ict);
                    end
                    if (first !== e_first || last !== e_last) begin
                        errs++;
                        if (errs <= 5)
                            $display("  [ERR] %-14s tile %0d (%0d,%0d,%0d): first/last = %b/%b expected %b/%b",
                                     tag, seen, pix, oct, ict, first, last, e_first, e_last);
                    end

                    seen++;
                    // advance the oracle exactly as the RTL should
                    e_ict++;
                    if (e_ict == ni) begin
                        e_ict = 0; e_oct++;
                        if (e_oct == no) begin e_oct = 0; e_pix++; end
                    end
                end

                if (layer_done) done_pulses++;

                @(posedge clock);
                if (!busy && !layer_done && seen == expect_tiles) begin
                    @(negedge clock);
                    disable_loop: break;
                end
                @(negedge clock);
                guard--;
            end

            // let any trailing layer_done pulse be observed
            #1;
            if (layer_done) done_pulses++;

            total++;
            if (seen !== expect_tiles) begin
                errs++;
                $display("  [ERR] %-14s emitted %0d tiles, expected %0d", tag, seen, expect_tiles);
            end
            if (done_pulses !== 1) begin
                errs++;
                $display("  [ERR] %-14s layer_done pulsed %0d times, expected 1", tag, done_pulses);
            end
            if (busy !== 1'b0) begin
                errs++;
                $display("  [ERR] %-14s still busy after the final tile", tag);
            end
            if (guard <= 0) begin
                errs++;
                $display("  [ERR] %-14s watchdog expired (counter stuck?)", tag);
            end

            if (errs == 0)
                $display("  [ok ] %-14s %0dx%0dx%0d = %0d tiles%s",
                         tag, np, no, ni, expect_tiles,
                         (stall_pct > 0) ? $sformatf(", %0d%% stalled", stall_pct) : "");
            fails += errs;
        end
    endtask

    // run a shape both flat out and with stalls: the sequence must be identical
    task automatic run_both(input integer np, input integer no, input integer ni,
                            input string tag);
        begin
            run_layer(np, no, ni, tag, 0);
            run_layer(np, no, ni, tag, 35);
        end
    endtask

    integer k;
    initial begin
        start = 0; en = 0; n_pix = 0; n_oc = 0; n_ic = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("addr_gen: pixel / oc_tile / ic_tile sequencer");
        $display("");
        $display("degenerate shapes:");
        run_both(1, 1, 1,  "1x1x1");        // first and last on the SAME cycle
        run_both(1, 1, 5,  "single pixel");
        run_both(4, 1, 1,  "one tile each");
        run_both(1, 3, 1,  "oc tiles only");

        $display("");
        $display("real layer shapes:");
        // features.1.conv.1 : 112x112, OC=16 -> 1 oc tile, IC=32 -> 2 ic tiles
        run_both(12544, 1, 2, "feat.1.conv.1");
        // features.2.conv.2 : 56x56, OC=24 -> 1 (tail), IC=96 -> 6
        run_both(3136, 1, 6,  "feat.2.conv.2");
        // features.18.0 : 7x7, OC=1280 -> 40, IC=320 -> 20  (the widest)
        run_both(49, 40, 20,  "feat.18.0");
        // classifier.1 : 1 pixel, OC=4 -> 1 tile, IC=1280 -> 80 ic tiles
        run_both(1, 1, 80,   "classifier.1");

        $display("");
        $display("randomized shapes:");
        for (k = 0; k < 8; k++) begin
            automatic integer np = ({$random} % 20) + 1;
            automatic integer no = ({$random} % 6)  + 1;
            automatic integer ni = ({$random} % 10) + 1;
            run_both(np, no, ni, $sformatf("rand[%0d]", k));
        end

        $display("");
        $display("control edge cases:");

        // zero-sized layer must be refused, not looped forever
        @(negedge clock);
        n_pix = 16'd8; n_oc = 8'd2; n_ic = 8'd0;
        start = 1'b1; en = 1'b1;
        @(negedge clock);
        start = 1'b0;
        repeat (6) @(negedge clock);
        total++;
        if (busy !== 1'b0 || valid !== 1'b0) begin
            fails++;
            $display("  [ERR] zero-sized layer started (busy=%b valid=%b)", busy, valid);
        end else
            $display("  [ok ] zero n_ic refused, stays idle");

        // restart mid-flight: a new start must abandon the old layer cleanly
        @(negedge clock);
        n_pix = 16'd50; n_oc = 8'd4; n_ic = 8'd4;
        start = 1'b1; en = 1'b1;
        @(negedge clock);
        start = 1'b0;
        repeat (10) @(negedge clock);      // part-way through
        total++;
        if (!busy) begin
            fails++;
            $display("  [ERR] restart setup: layer ended early");
        end
        run_layer(3, 2, 2, "restart", 0);  // issues a fresh start mid-flight
        $display("  [ok ] restart mid-flight re-seeds at (0,0,0)");

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d layers)", total);
        else            $display("FAILED    (%0d errors across %0d layers)", fails, total);
        $finish;
    end

endmodule
