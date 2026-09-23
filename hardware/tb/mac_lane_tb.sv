`timescale 1ns / 1ps
//============================================================================
//  mac_lane_tb.sv  -  self-checking testbench for rtl/kernels/mac_lane.v
//
//  Cross-checks the Tn-wide lane against TWO oracles at once:
//    1. an independent reference sum computed here, and
//    2. the already-proven single-MAC conv1x1 engine.
//
//  The SAME dot product is fed to both DUTs -- streamed 1/cycle into conv1x1,
//  and Tn/cycle (tiled) into mac_lane -- and we assert
//        acc_lane === reference === acc_conv.
//  Dot-product lengths are multiples of TN; values are full int8 range and
//  ACC_W=32 so random sums never overflow.
//
//  Run:  bash scripts/run_sim.sh mac_lane conv1x1
//============================================================================
module mac_lane_tb;

    localparam DATA_W   = 8;
    localparam TN       = 16;
    localparam ACC_W    = 32;
    localparam MAXTILES = 80;
    localparam MAXL     = MAXTILES*TN;   // 1280

    // L-1 pipelined mac_lane: one registered product stage, clog2(TN) tree
    // levels, one accumulate stage. Derived here the same way the DUT derives
    // it, and then MEASURED below rather than assumed - the whole point of the
    // latency block is that this number is a contract six other constants in
    // the design are defined against (docs/latency_map.md).
    localparam LEVELS  = $clog2(TN);          // 4 at TN=16
    localparam MAC_LAT = 1 + LEVELS + 1;      // 6

    logic clock, rst_n;

    // conv1x1 (oracle) I/O
    logic                     c_valid, c_first, c_last;
    logic signed [DATA_W-1:0] c_a, c_w;
    logic signed [ACC_W-1:0]  c_acc;
    logic                     c_done;

    // mac_lane (DUT) I/O
    logic                     l_valid, l_first, l_last;
    logic [TN*DATA_W-1:0]     l_a, l_w;
    logic signed [ACC_W-1:0]  l_acc;
    logic                     l_done;

    conv1x1 #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_ref (
        .clock(clock), .rst_n(rst_n),
        .valid(c_valid), .first(c_first), .last(c_last),
        .a(c_a), .w(c_w), .acc(c_acc), .done(c_done)
    );

    mac_lane #(.DATA_W(DATA_W), .TN(TN), .ACC_W(ACC_W)) u_lane (
        .clock(clock), .rst_n(rst_n),
        .valid(l_valid), .first(l_first), .last(l_last),
        .a(l_a), .w(l_w), .acc(l_acc), .done(l_done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    logic signed [DATA_W-1:0] av [0:MAXL-1];
    logic signed [DATA_W-1:0] wv [0:MAXL-1];

    // stream L pairs (1/cycle) into conv1x1
    task automatic drive_conv(input integer L);
        integer i;
        begin
            @(negedge clock);
            for (i = 0; i < L; i++) begin
                c_a = av[i]; c_w = wv[i];
                c_valid = 1'b1; c_first = (i==0); c_last = (i==L-1);
                @(posedge clock); @(negedge clock);
            end
            c_valid = 0; c_first = 0; c_last = 0;
        end
    endtask

    // stream `tiles` tiles (TN pairs/cycle) into mac_lane
    task automatic drive_lane(input integer tiles);
        integer t, j;
        begin
            @(negedge clock);
            for (t = 0; t < tiles; t++) begin
                for (j = 0; j < TN; j++) begin
                    l_a[j*DATA_W +: DATA_W] = av[t*TN + j];
                    l_w[j*DATA_W +: DATA_W] = wv[t*TN + j];
                end
                l_valid = 1'b1; l_first = (t==0); l_last = (t==tiles-1);
                @(posedge clock); @(negedge clock);
            end
            l_valid = 0; l_first = 0; l_last = 0;
        end
    endtask

    task automatic run_case(input integer tiles, input string tag);
        integer i, L;
        longint expected;
        logic signed [ACC_W-1:0] lane_acc;
        logic                    lane_done;
        integer                  lat;
        begin
            L = tiles*TN;
            expected = 0;
            for (i = 0; i < L; i++) expected += longint'(av[i]) * longint'(wv[i]);

            // The lane is PIPELINED now, so wait for `done` instead of reading
            // the accumulator the instant the last tile goes in - and count the
            // cycles while waiting, so a latency change shows up here as a
            // number rather than downstream as a bit-exactness failure.
            //  lat counts in docs/latency_map.md's convention: how many cycles
            //  after the one carrying `valid` the result is OBSERVABLE. A
            //  registered output is therefore 1, which is what this lane was
            //  before it was pipelined. drive_lane already returns one cycle
            //  past the last tile, so the count starts at 1.
            drive_lane(tiles);
            lat = 1;
            while (l_done !== 1'b1 && lat < 64) begin
                @(posedge clock); @(negedge clock);
                lat++;
            end
            lane_acc  = l_acc;
            lane_done = l_done;
            drive_conv(L);

            total++;
            if (lane_done !== 1'b1) begin
                fails++; $display("  [ERR] %-14s tiles=%0d : lane done not asserted", tag, tiles);
            end else if (lat !== MAC_LAT) begin
                fails++;
                $display("  [ERR] %-14s tiles=%0d : done came %0d cycles after the last tile, MAC_LAT says %0d",
                         tag, tiles, lat, MAC_LAT);
            end else if (lane_acc !== ACC_W'(expected)) begin
                fails++; $display("  [ERR] %-14s tiles=%0d : lane acc=%0d expected=%0d", tag, tiles, lane_acc, expected);
            end else if (lane_acc !== c_acc) begin
                fails++; $display("  [ERR] %-14s tiles=%0d : lane=%0d != conv1x1=%0d", tag, tiles, lane_acc, c_acc);
            end else begin
                $display("  [ok ] %-14s tiles=%0d L=%0d : acc=%0d (lane==conv1x1==ref)", tag, tiles, L, lane_acc);
            end
        end
    endtask

    integer k, n, r;
    initial begin
        c_valid=0; c_first=0; c_last=0; c_a=0; c_w=0;
        l_valid=0; l_first=0; l_last=0; l_a=0; l_w=0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("directed cases (TN=%0d):", TN);
        for (k=0;k<TN;k++)   begin av[k]=8'sd7; wv[k]=-8'sd9; end
        run_case(1, "single tile");
        for (k=0;k<MAXL;k++) begin av[k]=0; wv[k]=0; end
        run_case(4, "all zero");
        for (k=0;k<MAXL;k++) begin av[k]=8'sd127; wv[k]=8'sd127; end
        run_case(80, "all +127");      // 80*16*16129
        for (k=0;k<MAXL;k++) begin av[k]=-8'sd128; wv[k]=8'sd127; end
        run_case(80, "all -128*127");

        $display("randomized cases:");
        for (n=0;n<20;n++) begin
            r = ($random % MAXTILES); if (r<0) r=-r; r=r+1;   // 1..MAXTILES
            for (k=0;k<r*TN;k++) begin av[k]=$random; wv[k]=$random; end
            run_case(r, $sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
