`timescale 1ns / 1ps
//============================================================================
//  pe_array_tb.sv  -  self-checking testbench for rtl/kernels/pe_array.v
//
//  pe_array is pure wiring, so the bugs it can have are WIRING bugs: a lane
//  reading another lane's weight slice, an accumulator landing in the wrong
//  slot of the output bus, taps swapped inside a lane, a broadcast that is
//  not actually shared, or a `done` that does not line up with the final acc.
//  Random data alone hides some of those - a symmetric mistake still adds up
//  to the right number - so the directed cases below make every lane, and
//  every tap, carry a DISTINGUISHABLE value.
//
//  Two oracles, the same pattern that proved mac_lane:
//    1. an independent reference dot product computed here in longint, for
//       ALL Tm lanes, on every case; and
//    2. the already-proven single-MAC conv1x1, streamed 1 term/cycle, over a
//       spread of lanes - proven logic rather than testbench arithmetic.
//
//  ACC_W = 32 here, not the datapath's 21, so full-range random int8 data
//  cannot overflow - the same choice mac_lane_tb makes, for the same reason.
//  The real ACC_W=21 configuration is exercised by the integration test
//  against the golden vectors (build plan #4).
//
//  Run:  bash scripts/run_sim.sh pe_array mac_lane conv1x1
//============================================================================
module pe_array_tb;

    localparam DATA_W   = 8;
    localparam TM       = 32;
    localparam TN       = 16;
    localparam ACC_W    = 32;
    localparam MAXTILES = 40;
    localparam MAXL     = MAXTILES*TN;      // 640

    logic clock, rst_n;

    // ---- pe_array (DUT) ----------------------------------------------------
    logic                     p_valid, p_first, p_last;
    logic [TN*DATA_W-1:0]     p_a;
    logic [TM*TN*DATA_W-1:0]  p_w;
    wire  [TM*ACC_W-1:0]      p_acc;
    wire                      p_done;

    // ---- conv1x1 (oracle 2) ------------------------------------------------
    logic                     c_valid, c_first, c_last;
    logic signed [DATA_W-1:0] c_a, c_w;
    wire  signed [ACC_W-1:0]  c_acc;
    wire                      c_done;

    pe_array #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W)) u_array (
        .clock(clock), .rst_n(rst_n),
        .valid(p_valid), .first(p_first), .last(p_last),
        .a(p_a), .w(p_w), .acc(p_acc), .done(p_done)
    );

    conv1x1 #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_ref (
        .clock(clock), .rst_n(rst_n),
        .valid(c_valid), .first(c_first), .last(c_last),
        .a(c_a), .w(c_w), .acc(c_acc), .done(c_done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ---- stimulus + expectations ------------------------------------------
    logic signed [DATA_W-1:0] av [0:MAXL-1];            // shared activations
    logic signed [DATA_W-1:0] wv [0:TM-1][0:MAXL-1];    // per-lane weights
    longint                   expected [0:TM-1];
    logic signed [ACC_W-1:0]  arr_acc  [0:TM-1];
    logic                     arr_done;

    // ---- drivers -----------------------------------------------------------
    // stream `tiles` tiles into the array: TN activations broadcast, TM*TN weights
    task automatic drive_array(input integer tiles);
        integer t, j, m;
        begin
            @(negedge clock);
            for (t = 0; t < tiles; t++) begin
                for (j = 0; j < TN; j++)
                    p_a[j*DATA_W +: DATA_W] = av[t*TN + j];
                for (m = 0; m < TM; m++)
                    for (j = 0; j < TN; j++)
                        p_w[(m*TN + j)*DATA_W +: DATA_W] = wv[m][t*TN + j];
                p_valid = 1'b1; p_first = (t == 0); p_last = (t == tiles-1);
                @(posedge clock); @(negedge clock);
            end
            p_valid = 0; p_first = 0; p_last = 0;
        end
    endtask

    // stream lane m's dot product, 1 term/cycle, through the single-MAC conv1x1
    task automatic drive_conv(input integer m, input integer L);
        integer i;
        begin
            @(negedge clock);
            for (i = 0; i < L; i++) begin
                c_a = av[i]; c_w = wv[m][i];
                c_valid = 1'b1; c_first = (i == 0); c_last = (i == L-1);
                @(posedge clock); @(negedge clock);
            end
            c_valid = 0; c_first = 0; c_last = 0;
        end
    endtask

    // ---- the check ---------------------------------------------------------
    // xlanes selects how many lanes ALSO go through the conv1x1 oracle
    // (0 = none, TM = all). The reference oracle always covers every lane.
    task automatic run_case(input integer tiles, input string tag,
                            input integer xlanes);
        integer i, m, L, step, fails0;
        begin
            fails0 = fails;
            L = tiles*TN;
            for (m = 0; m < TM; m++) begin
                expected[m] = 0;
                for (i = 0; i < L; i++)
                    expected[m] += longint'(av[i]) * longint'(wv[m][i]);
            end

            drive_array(tiles);
            arr_done = p_done;
            for (m = 0; m < TM; m++) arr_acc[m] = p_acc[m*ACC_W +: ACC_W];

            total++;
            if (arr_done !== 1'b1) begin
                fails++;
                $display("  [ERR] %-16s tiles=%0d : done not asserted", tag, tiles);
            end

            // oracle 1: independent reference, every lane
            for (m = 0; m < TM; m++) begin
                if (arr_acc[m] !== ACC_W'(expected[m])) begin
                    fails++;
                    if (fails - fails0 <= 8)
                        $display("  [ERR] %-16s tiles=%0d lane=%0d : acc=%0d expected=%0d",
                                 tag, tiles, m, arr_acc[m], expected[m]);
                end
            end

            // oracle 2: the proven conv1x1, on a spread of lanes
            if (xlanes > 0) begin
                step = (xlanes >= TM) ? 1 : (TM / xlanes);
                for (m = 0; m < TM; m = m + step) begin
                    drive_conv(m, L);
                    if (c_acc !== arr_acc[m]) begin
                        fails++;
                        $display("  [ERR] %-16s tiles=%0d lane=%0d : array=%0d != conv1x1=%0d",
                                 tag, tiles, m, arr_acc[m], c_acc);
                    end
                end
            end

            if (fails == fails0)
                $display("  [ok ] %-16s tiles=%0d L=%0d : %0d lanes vs ref, %0d vs conv1x1",
                         tag, tiles, L, TM, (xlanes >= TM) ? TM : xlanes);
        end
    endtask

    // ---- stimulus helper ---------------------------------------------------
    task automatic fill_const(input integer aval, input integer wval);
        integer k, m;
        begin
            for (k = 0; k < MAXL; k++) begin
                av[k] = aval;
                for (m = 0; m < TM; m++) wv[m][k] = wval;
            end
        end
    endtask

    integer k, m, n, r;
    initial begin
        p_valid=0; p_first=0; p_last=0; p_a=0; p_w=0;
        c_valid=0; c_first=0; c_last=0; c_a=0; c_w=0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("pe_array: TM=%0d lanes x TN=%0d taps = %0d MAC/cycle, ACC_W=%0d",
                 TM, TN, TM*TN, ACC_W);
        $display("");
        $display("wiring cases (every lane and tap carries a distinguishable value):");

        // 1. lane identity - a=1 everywhere, lane m weighted (m+1), so
        //    expected[m] = tiles*TN*(m+1). All 32 lanes differ, so ANY lane
        //    swap or weight-slice misalignment shows up immediately.
        for (k = 0; k < MAXL; k++) begin
            av[k] = 8'sd1;
            for (m = 0; m < TM; m++) wv[m][k] = m + 1;
        end
        run_case(2, "lane identity", TM);

        // 2. one-hot tap - lane m has weight 1 only at tap (m mod TN) and
        //    a[j] = j+1, so expected[m] = (m mod TN)+1. Catches tap ordering
        //    inside a lane, which case 1 cannot see.
        for (k = 0; k < TN; k++) av[k] = k + 1;
        for (m = 0; m < TM; m++)
            for (k = 0; k < TN; k++) wv[m][k] = (k == (m % TN)) ? 8'sd1 : 8'sd0;
        run_case(1, "one-hot tap", TM);

        // 3. single lane active - only lane 7 carries weights, every other
        //    lane must read exactly 0. Catches a lane leaking into neighbours.
        fill_const(8'sd5, 8'sd0);
        for (k = 0; k < MAXL; k++) wv[7][k] = 8'sd3;
        run_case(4, "only lane 7", 8);

        // 4. shared broadcast - identical weights in every lane, so all 32
        //    accumulators must come out EQUAL. If the activation bus were not
        //    truly shared, lanes would see different data and diverge.
        fill_const(8'sd6, -8'sd7);
        run_case(5, "shared bcast", 4);
        for (m = 1; m < TM; m++)
            if (arr_acc[m] !== arr_acc[0]) begin
                fails++;
                $display("  [ERR] broadcast not shared: lane%0d=%0d != lane0=%0d",
                         m, arr_acc[m], arr_acc[0]);
            end

        // 5. int8 extremes, at full depth
        fill_const(8'sd0,    8'sd0);    run_case(4,        "all zero", 4);
        fill_const(8'sd127,  8'sd127);  run_case(MAXTILES, "all +127", 4);
        fill_const(-8'sd128, 8'sd127);  run_case(MAXTILES, "min x max", 4);

        $display("");
        $display("randomized cases (independent random weights per lane):");
        for (n = 0; n < 12; n++) begin
            r = ($random % MAXTILES); if (r < 0) r = -r; r = r + 1;   // 1..MAXTILES
            for (k = 0; k < r*TN; k++) begin
                av[k] = $random;
                for (m = 0; m < TM; m++) wv[m][k] = $random;
            end
            run_case(r, $sformatf("rand[%0d]", n), 4);
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases, %0d lane-checks)", total, total*TM);
        else            $display("FAILED    (%0d errors across %0d cases)", fails, total);
        $finish;
    end

endmodule
