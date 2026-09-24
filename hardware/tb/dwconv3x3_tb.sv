`timescale 1ns / 1ps
//============================================================================
//  dwconv3x3_tb.sv  -  self-checking testbench for rtl/kernels/dwconv3x3.v
//
//  dwconv3x3 is a PIPELINED 9-tap MAC since L-1: one registered product stage
//  plus clog2(9) = 4 adder-tree levels, so DW_LAT = 5 and it has a clock. Build a
//  3x3 window + 3x3 kernel, pack them into the flat port vectors, hold them for
//  the pipeline to fill, and compare the accumulator against an independent
//  reference sum.
//
//  The window is HELD while the pipeline drains, which is what the real feeder
//  does too: line_buffer only updates its output when it is fed, so a held
//  window propagating through a free-running tree is the normal case, not a
//  special one.
//
//  Coverage:
//    - directed: zero, all max +/-, single tap, known small
//    - zero-padding: border/corner windows with some taps forced to 0
//    - randomized full-range int8 windows
//  9 taps * 128*127 ~ 146k fits ACC_W=21, so the real HW width is tested here.
//
//  Run:  bash scripts/run_sim.sh dwconv3x3
//============================================================================
module dwconv3x3_tb;

    localparam DATA_W = 8;
    localparam K      = 3;
    localparam NT     = K*K;      // 9 taps
    localparam ACC_W  = 26;

    // L-1: one registered product stage + clog2(NT) tree levels. Derived here
    // the same way the DUT derives it, so a change to one shows up as a
    // mismatch rather than as a wrong number.
    localparam LEVELS = $clog2(NT);          // 4
    localparam DW_LAT = 1 + LEVELS;          // 5

    logic                     clock, rst_n;
    logic [NT*DATA_W-1:0]     win_v, wk_v;
    wire  signed [ACC_W-1:0]  acc;

    dwconv3x3 #(.DATA_W(DATA_W), .K(K), .ACC_W(ACC_W)) dut (
        .clock (clock),
        .rst_n (rst_n),
        .win   (win_v),
        .wk    (wk_v),
        .acc   (acc)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0;
    integer fails = 0;

    // one window / kernel, tap-major (i = ky*K + kx)
    logic signed [DATA_W-1:0] a [0:NT-1];
    logic signed [DATA_W-1:0] g [0:NT-1];

    // pack a[]/g[] into the flat vectors, drive, and check
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
            // hold the window while the pipeline fills: DW_LAT edges, then read
            repeat (DW_LAT) @(posedge clock);
            @(negedge clock);
            total++;
            if (acc !== ACC_W'(expected)) begin
                fails++;
                $display("  [ERR] %-16s acc=%0d expected=%0d", tag, acc, expected);
            end else begin
                $display("  [ok ] %-16s acc=%0d", tag, acc);
            end
        end
    endtask

    // helpers to fill the whole window / kernel with one value
    task automatic fill_win(input logic signed [DATA_W-1:0] v);
        integer i; begin for (i=0;i<NT;i++) a[i]=v; end
    endtask
    task automatic fill_ker(input logic signed [DATA_W-1:0] v);
        integer i; begin for (i=0;i<NT;i++) g[i]=v; end
    endtask

    integer i, n;
    initial begin
        win_v = '0; wk_v = '0;
        rst_n = 1'b0;
        repeat (2) @(negedge clock);
        rst_n = 1'b1;
        @(negedge clock);

        $display("directed cases:");

        fill_win(0);  fill_ker(0);              run_case("all zero");
        fill_win(8'sd127); fill_ker(8'sd127);   run_case("all +127");   // 9*16129
        fill_win(-8'sd128); fill_ker(8'sd127);  run_case("all -128*127");// 9*-16256

        // single active tap (center), rest zero
        fill_win(0); fill_ker(0);
        a[4] = 8'sd10; g[4] = 8'sd5;            run_case("center only");

        // known small mixed window
        for (i=0;i<NT;i++) begin a[i]=i-4; g[i]=1; end   // sum of -4..4 = 0
        run_case("sum -4..4");

        $display("zero-padding cases (taps forced 0):");

        // top-row padded (taps 0,1,2 = 0), rest random-ish
        for (i=0;i<NT;i++) begin a[i]=(i<3)?8'sd0:(20+i); g[i]=2; end
        run_case("top row pad");

        // top-left corner: only taps 4,5,7,8 in-bounds, others 0
        fill_win(0); fill_ker(8'sd3);
        a[4]=8'sd11; a[5]=8'sd12; a[7]=8'sd13; a[8]=8'sd14;
        run_case("corner pad");

        $display("randomized cases:");
        for (n = 0; n < 20; n++) begin
            for (i=0;i<NT;i++) begin
                a[i] = $random;    // full int8 range
                g[i] = $random;
            end
            run_case($sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
