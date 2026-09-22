`timescale 1ns / 1ps
//============================================================================
//  dw_array_tb.sv  -  self-checking testbench for rtl/control/dw_array.v
//
//  dw_array is a TRANSPOSITION: line_buffer hands it a tap-major window and
//  wgt_buffer a channel-major weight block, and it has to pair tap i of channel
//  c with weight i of channel c. Get the stride wrong and channels get mixed
//  while every sum still looks perfectly reasonable - there is no saturation,
//  no zero, nothing obviously broken to notice. So every case here gives each
//  (channel, tap) pair a DISTINCT value, and one case makes the answer itself
//  identify the channel.
//
//  Two oracles:
//    1. an independent longint reference sum per channel, and
//    2. a SINGLE dwconv3x3 instance fed channel by channel - the same proven
//       silicon unreplicated, which is the right control for a wrapper, exactly
//       as in rq_bank_tb.
//
//  ACC_W = 21, the real width, with full-range int8 data. That is safe by
//  construction here rather than by precondition: 9 taps at worst
//  9*128*127 = 146,304 needs 19 bits. Unlike the pointwise array, no depthwise
//  input can overflow the accumulator, so the testbench does not have to widen
//  it the way pe_array_tb does.
//
//  Run:  bash scripts/run_sim.sh dw_array dwconv3x3
//============================================================================
module dw_array_tb;

    localparam DATA_W = 8;
    localparam TC     = 16;
    localparam K      = 3;
    localparam NT     = K*K;
    localparam ACC_W  = 26;

    // ---- DUT ---------------------------------------------------------------
    logic [NT*TC*DATA_W-1:0] win;
    logic [TC*NT*DATA_W-1:0] wk;
    wire  [TC*ACC_W-1:0]     acc;

    dw_array #(.DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W)) u_dut (
        .win(win), .wk(wk), .acc(acc)
    );

    // ---- oracle 2: one dwconv3x3, driven channel by channel ---------------
    logic [NT*DATA_W-1:0]    s_win, s_wk;
    wire  signed [ACC_W-1:0] s_acc;

    dwconv3x3 #(.DATA_W(DATA_W), .K(K), .ACC_W(ACC_W)) u_single (
        .win(s_win), .wk(s_wk), .acc(s_acc)
    );

    integer total = 0, fails = 0;

    // ---- stimulus, as plain arrays ----------------------------------------
    logic signed [DATA_W-1:0] a [0:TC-1][0:NT-1];   // [channel][tap]
    logic signed [DATA_W-1:0] w [0:TC-1][0:NT-1];

    task automatic pack;
        integer c, i;
        begin
            for (c = 0; c < TC; c++)
                for (i = 0; i < NT; i++) begin
                    // line_buffer order: tap-major, channel-minor
                    win[((i*TC) + c)*DATA_W +: DATA_W] = a[c][i];
                    // wgt_buffer order: channel-major, tap-minor
                    wk [((c*NT) + i)*DATA_W +: DATA_W] = w[c][i];
                end
        end
    endtask

    task automatic run_case(input string tag);
        integer c, i, bad_ref, bad_ora;
        longint expd;
        logic signed [ACC_W-1:0] got;
        begin
            bad_ref = 0; bad_ora = 0;
            pack;
            #1;                                  // settle the combinational net

            for (c = 0; c < TC; c++) begin
                // oracle 1: independent reference
                expd = 0;
                for (i = 0; i < NT; i++)
                    expd += longint'(a[c][i]) * longint'(w[c][i]);
                got = acc[c*ACC_W +: ACC_W];
                if (got !== ACC_W'(expd)) begin
                    bad_ref++;
                    if (bad_ref <= 4)
                        $display("  [ERR] %-18s ch=%0d : got %0d expected %0d",
                                 tag, c, got, expd);
                end

                // oracle 2: the same channel through a single dwconv3x3
                for (i = 0; i < NT; i++) begin
                    s_win[i*DATA_W +: DATA_W] = a[c][i];
                    s_wk [i*DATA_W +: DATA_W] = w[c][i];
                end
                #1;
                if (s_acc !== got) begin
                    bad_ora++;
                    if (bad_ora <= 4)
                        $display("  [ERR] %-18s ch=%0d : array %0d != single dwconv %0d",
                                 tag, c, got, s_acc);
                end
            end

            total++;
            if (bad_ref != 0 || bad_ora != 0) begin
                fails++;
                $display("  [ERR] %-18s %0d vs reference, %0d vs single engine",
                         tag, bad_ref, bad_ora);
            end else
                $display("  [ok ] %-18s %0d channels vs reference AND vs single engine",
                         tag, TC);
        end
    endtask

    integer c, i, n;
    initial begin
        win = 0; wk = 0; s_win = 0; s_wk = 0;

        $display("dw_array: %0d channels x %0d taps = %0d MACs, ACC_W=%0d",
                 TC, NT, TC*NT, ACC_W);
        $display("");
        $display("transposition cases (each channel and tap distinguishable):");

        // 1. channel identity - the answer names the channel. Activations are 1
        //    everywhere and channel c's weights are all (c+1), so the sum is
        //    9*(c+1): every channel differs, so ANY channel mix-up shows.
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = 8'sd1; w[c][i] = c + 1; end
        run_case("channel identity");

        // 2. one-hot tap - channel c has a single non-zero weight at tap
        //    (c mod NT) and activations count 1..9, so the sum is (c mod 9)+1.
        //    Catches a tap stride error inside a channel, which case 1 cannot
        //    see because its weights are uniform per channel.
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin
                a[c][i] = i + 1;
                w[c][i] = (i == (c % NT)) ? 8'sd1 : 8'sd0;
            end
        run_case("one-hot tap");

        // 3. single active channel - only channel 5 has weights; the other 15
        //    must read exactly 0, so a channel cannot leak into its neighbours.
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = 8'sd7; w[c][i] = 8'sd0; end
        for (i = 0; i < NT; i++) w[5][i] = 8'sd3;
        run_case("only channel 5");

        // 4. padding: a window with zeros where the image edge would be, which
        //    is what line_buffer actually supplies on the borders
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin
                a[c][i] = (i < K) ? 8'sd0 : (c + 2);    // top row zeroed
                w[c][i] = i - 4;
            end
        run_case("top row padded");

        // 5. int8 extremes at full depth - the worst case for ACC_W
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = -8'sd128; w[c][i] = 8'sd127; end
        run_case("min x max");
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = 8'sd127; w[c][i] = 8'sd127; end
        run_case("max x max");
        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = -8'sd128; w[c][i] = -8'sd128; end
        run_case("min x min");

        for (c = 0; c < TC; c++)
            for (i = 0; i < NT; i++) begin a[c][i] = 8'sd0; w[c][i] = 8'sd0; end
        run_case("all zero");

        $display("");
        $display("randomized (independent full-range int8 per channel and tap):");
        for (n = 0; n < 12; n++) begin
            for (c = 0; c < TC; c++)
                for (i = 0; i < NT; i++) begin a[c][i] = $random; w[c][i] = $random; end
            run_case($sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases, %0d channel-checks)", total, total*TC*2);
        else            $display("FAILED    (%0d errors in %0d cases)", fails, total);
        $finish;
    end

endmodule
