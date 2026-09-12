`timescale 1ns / 1ps
//============================================================================
//  stem_array_tb.sv  -  self-checking testbench for rtl/control/stem_array.v
//
//  Like dw_array, this module's content is a TRANSPOSITION plus a broadcast,
//  so its possible faults are wiring faults: a tap landing in the wrong place
//  of the reordered window, a lane reading another lane's weights, or a result
//  in the wrong accumulator slot. All of those still produce plausible sums.
//
//  So every case gives each (channel, ky, kx) and each lane a DISTINCT value,
//  and one case makes the answer name its own lane. Two oracles, as always:
//  an independent longint reference, and a SINGLE conv3x3_std driven lane by
//  lane - the same proven silicon unreplicated, which is the right control for
//  a wrapper.
//
//  ACC_W = 21, the real width, with full-range int8: 27 taps bound the sum at
//  27*128*127 = 438,912, which needs 20 bits. Safe by construction here, as in
//  dw_array and unlike the pointwise path.
//
//  Run:  bash scripts/run_sim.sh stem_array conv3x3_std
//============================================================================
module stem_array_tb;

    localparam DATA_W = 8;
    localparam TS     = 8;
    localparam CIN    = 3;
    localparam K      = 3;
    localparam NT     = CIN*K*K;      // 27
    localparam ACC_W  = 21;

    logic [K*K*CIN*DATA_W-1:0]    win;
    logic [TS*NT*DATA_W-1:0]      wk;
    wire  [TS*ACC_W-1:0]          acc;

    stem_array #(.DATA_W(DATA_W), .TS(TS), .CIN(CIN), .K(K), .ACC_W(ACC_W)) u_dut (
        .win(win), .wk(wk), .acc(acc)
    );

    // ---- oracle 2: one conv3x3_std, driven lane by lane ------------------
    logic [NT*DATA_W-1:0]    s_win, s_wk;
    wire  signed [ACC_W-1:0] s_acc;

    conv3x3_std #(.DATA_W(DATA_W), .K(K), .CIN(CIN), .ACC_W(ACC_W)) u_single (
        .win(s_win), .wk(s_wk), .acc(s_acc)
    );

    integer total = 0, fails = 0;

    // ---- stimulus, in their natural orders -------------------------------
    logic signed [DATA_W-1:0] a  [0:CIN-1][0:K-1][0:K-1];   // [channel][ky][kx]
    logic signed [DATA_W-1:0] w  [0:TS-1][0:NT-1];          // [lane][conv tap]

    task automatic pack;
        integer c, ky, kx, m, i;
        begin
            for (c = 0; c < CIN; c++)
                for (ky = 0; ky < K; ky++)
                    for (kx = 0; kx < K; kx++)
                        // line_buffer order: tap-major, channel-minor
                        win[(((ky*K + kx)*CIN) + c)*DATA_W +: DATA_W] = a[c][ky][kx];
            for (m = 0; m < TS; m++)
                for (i = 0; i < NT; i++)
                    wk[(m*NT + i)*DATA_W +: DATA_W] = w[m][i];
        end
    endtask

    task automatic run_case(input string tag);
        integer m, c, ky, kx, i, bad_ref, bad_ora;
        longint expd;
        logic signed [ACC_W-1:0] got;
        begin
            bad_ref = 0; bad_ora = 0;
            pack;
            #1;

            for (m = 0; m < TS; m++) begin
                // oracle 1: the conv order is i = (c*K + ky)*K + kx
                expd = 0;
                for (c = 0; c < CIN; c++)
                    for (ky = 0; ky < K; ky++)
                        for (kx = 0; kx < K; kx++)
                            expd += longint'(a[c][ky][kx]) *
                                    longint'(w[m][(c*K + ky)*K + kx]);
                got = acc[m*ACC_W +: ACC_W];
                if (got !== ACC_W'(expd)) begin
                    bad_ref++;
                    if (bad_ref <= 4)
                        $display("  [ERR] %-18s lane=%0d : got %0d expected %0d",
                                 tag, m, got, expd);
                end

                // oracle 2: the same lane through a single conv3x3_std
                for (c = 0; c < CIN; c++)
                    for (ky = 0; ky < K; ky++)
                        for (kx = 0; kx < K; kx++)
                            s_win[((c*K + ky)*K + kx)*DATA_W +: DATA_W] = a[c][ky][kx];
                for (i = 0; i < NT; i++)
                    s_wk[i*DATA_W +: DATA_W] = w[m][i];
                #1;
                if (s_acc !== got) begin
                    bad_ora++;
                    if (bad_ora <= 4)
                        $display("  [ERR] %-18s lane=%0d : array %0d != single conv %0d",
                                 tag, m, got, s_acc);
                end
            end

            total++;
            if (bad_ref != 0 || bad_ora != 0) begin
                fails++;
                $display("  [ERR] %-18s %0d vs reference, %0d vs single engine",
                         tag, bad_ref, bad_ora);
            end else
                $display("  [ok ] %-18s %0d lanes vs reference AND vs single engine",
                         tag, TS);
        end
    endtask

    integer m, c, ky, kx, i, n;
    initial begin
        win = 0; wk = 0; s_win = 0; s_wk = 0;

        $display("stem_array: %0d lanes x %0d taps (%0d ch x %0dx%0d) = %0d MACs, ACC_W=%0d",
                 TS, NT, CIN, K, K, TS*NT, ACC_W);
        $display("");
        $display("wiring cases (each lane and tap distinguishable):");

        // 1. lane identity - all activations 1, lane m weighted (m+1), so the
        //    sum is 27*(m+1): every lane differs, so a lane or weight-slice
        //    swap shows immediately.
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++) a[c][ky][kx] = 8'sd1;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = m + 1;
        run_case("lane identity");

        // 2. one-hot tap - lane m has a single non-zero weight at tap (m mod
        //    NT), and every (c,ky,kx) carries a distinct activation, so the sum
        //    NAMES the tap. This is what catches a transposition error, which
        //    case 1 cannot see because its weights are uniform per lane.
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++)
                    a[c][ky][kx] = (c*K + ky)*K + kx + 1;     // 1..27, distinct
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = (i == (m % NT)) ? 8'sd1 : 8'sd0;
        run_case("one-hot tap");

        // 3. one-hot CHANNEL - only input channel 1 has data. A transposition
        //    that mixed the channel and tap axes would smear it across the
        //    window.
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++)
                    a[c][ky][kx] = (c == 1) ? (ky*K + kx + 1) : 8'sd0;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = i + 1;
        run_case("only channel 1");

        // 4. one-hot CORNER - only the top-left tap of every channel, which is
        //    the position the padding at an image corner leaves non-zero.
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++)
                    a[c][ky][kx] = (ky == 0 && kx == 0) ? (c + 3) : 8'sd0;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = i - 13;
        run_case("only tap (0,0)");

        // 5. only lane 5 has weights: the other seven must read exactly 0
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++) a[c][ky][kx] = 8'sd9;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = 8'sd0;
        for (i = 0; i < NT; i++) w[5][i] = 8'sd4;
        run_case("only lane 5");

        // 6. int8 extremes - the worst case for ACC_W
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++) a[c][ky][kx] = -8'sd128;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = 8'sd127;
        run_case("min x max");
        for (c = 0; c < CIN; c++)
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++) a[c][ky][kx] = -8'sd128;
        for (m = 0; m < TS; m++)
            for (i = 0; i < NT; i++) w[m][i] = -8'sd128;
        run_case("min x min");

        $display("");
        $display("randomized (independent full-range int8):");
        for (n = 0; n < 12; n++) begin
            for (c = 0; c < CIN; c++)
                for (ky = 0; ky < K; ky++)
                    for (kx = 0; kx < K; kx++) a[c][ky][kx] = $random;
            for (m = 0; m < TS; m++)
                for (i = 0; i < NT; i++) w[m][i] = $random;
            run_case($sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases, %0d lane-checks)", total, total*TS*2);
        else            $display("FAILED    (%0d errors in %0d cases)", fails, total);
        $finish;
    end

endmodule
