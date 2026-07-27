`timescale 1ns / 1ps
//============================================================================
//  bias_add_tb.sv  -  self-checking testbench for rtl/kernels/bias_add.v
//
//  bias_add is pure combinational (acc_out = acc_in + bias), so no clock: the
//  TB drives inputs, waits a delta, and compares against an independent sum.
//
//  Values are kept within ACC_W (21-bit signed) so the result never overflows
//  -- the same precondition the real datapath guarantees.
//
//  Run:  bash scripts/run_sim.sh bias_add
//============================================================================
module bias_add_tb;

    localparam ACC_W  = 21;
    localparam BIAS_W = 32;

    localparam longint ACC_MAX =  (longint'(1) << (ACC_W-1)) - 1;   //  1048575
    localparam longint ACC_MIN = -(longint'(1) << (ACC_W-1));       // -1048576

    logic signed [ACC_W-1:0]  acc_in;
    logic signed [BIAS_W-1:0] bias;
    logic signed [ACC_W-1:0]  acc_out;

    integer total = 0;
    integer fails = 0;

    bias_add #(.ACC_W(ACC_W), .BIAS_W(BIAS_W)) dut (
        .acc_in  (acc_in),
        .bias    (bias),
        .acc_out (acc_out)
    );

    task automatic run_case(input longint t_acc, input longint t_bias, input string tag);
        longint expected;
        begin
            acc_in = ACC_W'(t_acc);
            bias   = BIAS_W'(t_bias);
            #1;                                   // let combinational logic settle
            expected = t_acc + t_bias;

            total++;
            if (acc_out !== ACC_W'(expected)) begin
                fails++;
                $display("  [ERR] %-16s %0d + %0d : got %0d, expect %0d",
                         tag, t_acc, t_bias, acc_out, expected);
            end else begin
                $display("  [ok ] %-16s %0d + %0d = %0d", tag, t_acc, t_bias, acc_out);
            end
        end
    endtask

    integer n;
    longint ra, rb;
    initial begin
        $display("directed cases:");
        run_case(0,        0,        "zero");
        run_case(100,     -30,       "pos+neg");
        run_case(-1000,    1000,     "cancel");
        run_case(ACC_MAX,  0,        "acc max");
        run_case(ACC_MIN,  0,        "acc min");
        run_case(500000,   500000,   "near +max");
        run_case(-500000, -500000,   "near -max");

        $display("randomized cases (kept in-range):");
        for (n = 0; n < 20; n++) begin
            ra = $random % 500000;    // -499999 .. 499999
            rb = $random % 500000;
            run_case(ra, rb, $sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
