`timescale 1ns / 1ps
//============================================================================
//  conv3x3_std_tb.sv  -  self-checking testbench for rtl/kernels/conv3x3_std.v
//
//  conv3x3_std is a pure combinational NT-tap MAC (NT = K*K*CIN). No clock:
//  fill the window+kernel, pack into the flat vectors, compare the accumulator
//  against an independent reference sum.
//
//  NT=27, 27 * 128*127 ~ 439k fits ACC_W=21, so the real HW width is tested.
//
//  Run:  bash scripts/run_sim.sh conv3x3_std
//============================================================================
module conv3x3_std_tb;

    localparam DATA_W = 8;
    localparam K      = 3;
    localparam CIN    = 3;
    localparam NT     = K*K*CIN;     // 27
    localparam ACC_W  = 21;

    logic [NT*DATA_W-1:0]     win_v, wk_v;
    wire  signed [ACC_W-1:0]  acc;

    conv3x3_std #(.DATA_W(DATA_W), .K(K), .CIN(CIN), .ACC_W(ACC_W)) dut (
        .win (win_v),
        .wk  (wk_v),
        .acc (acc)
    );

    integer total = 0;
    integer fails = 0;

    logic signed [DATA_W-1:0] a [0:NT-1];
    logic signed [DATA_W-1:0] g [0:NT-1];

    task automatic run_case(input string tag);
        integer i;
        longint expected;
        begin
            expected = 0;
            for (i = 0; i < NT; i++) begin
                win_v[i*DATA_W +: DATA_W] = a[i];
                wk_v [i*DATA_W +: DATA_W] = g[i];
                expected += longint'(a[i]) * longint'(g[i]);
            end
            #1;
            total++;
            if (acc !== ACC_W'(expected)) begin
                fails++;
                $display("  [ERR] %-14s acc=%0d expected=%0d", tag, acc, expected);
            end else begin
                $display("  [ok ] %-14s acc=%0d", tag, acc);
            end
        end
    endtask

    task automatic fill(input logic signed [DATA_W-1:0] va, input logic signed [DATA_W-1:0] vg);
        integer i; begin for (i=0;i<NT;i++) begin a[i]=va; g[i]=vg; end end
    endtask

    integer i, n;
    initial begin
        $display("directed cases:");
        fill(0, 0);                 run_case("all zero");
        fill(8'sd127, 8'sd127);     run_case("all +127");     // 27*16129 = 435483
        fill(-8'sd128, 8'sd127);    run_case("all -128*127"); // 27*-16256 = -438912

        // single active tap (rest zero -> heavy padding case)
        fill(0,0); a[13]=8'sd9; g[13]=8'sd7;   run_case("single tap");

        // half the taps padded to zero
        for (i=0;i<NT;i++) begin a[i]=(i<9)?8'sd0:(i-13); g[i]=3; end
        run_case("9 taps padded");

        $display("randomized cases:");
        for (n = 0; n < 20; n++) begin
            for (i=0;i<NT;i++) begin a[i]=$random; g[i]=$random; end
            run_case($sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
