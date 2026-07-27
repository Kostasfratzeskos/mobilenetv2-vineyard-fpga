`timescale 1ns / 1ps
//============================================================================
//  requantize_tb.sv  -  self-checking testbench for rtl/kernels/requantize.v
//
//  SystemVerilog testbench, Verilog-2001 DUT (keep RTL synthesizable & plain).
//
//  Golden oracle: the SAME directed vectors as
//      software/cmodel/test/test_requantize.c
//  so a pass here means the RTL matches the C reference bit-for-bit on every
//  case the C reference itself is validated against.
//
//  Mapping note: the C test's check_core() exercises requant_mul_shift (the
//  int32 core, no clamp). This module only emits the clamped int8, so those
//  core cases are replayed with act=ACT_NONE and results that already fit in
//  int8 -> clamp_i8 is the identity, so the int8 output equals the core value.
//  The out-of-range and ReLU6 cases come straight from check_elem().
//
//  Run (Vivado xsim):
//     xvlog -sv requantize_tb.sv ../rtl/kernels/requantize.v
//     xelab requantize_tb -s rq -timescale 1ns/1ps
//     xsim rq -runall
//============================================================================
module requantize_tb;

    // ---- op-kind encoding (must match the DUT) ------------------------
    localparam ACT_NONE  = 1'b0;
    localparam ACT_RELU6 = 1'b1;

    // handy multiplier: 1<<30 with shift 31 => M = 0.5 (as in the C test)
    localparam signed [31:0] M0_HALF = 32'sd1073741824;

    // ---- DUT I/O ------------------------------------------------------
    logic                      clock;
    logic                      rst_n;
    logic                      en;
    logic                      act;
    logic signed [20:0]        in_data;      // ACC_W = 21
    logic signed [31:0]        M0;           // M0_W  = 32
    logic        [5:0]         shift;        // SHIFT_W = 6
    logic signed [7:0]         relu6_qmax;
    logic signed [7:0]         quantized;

    integer total = 0;
    integer fails = 0;

    // ---- DUT ----------------------------------------------------------
    requantize #(
        .ACC_W   (21),
        .M0_W    (32),
        .SHIFT_W (6)
    ) dut (
        .clock      (clock),
        .rst_n      (rst_n),
        .en         (en),
        .act        (act),
        .in_data    (in_data),
        .M0         (M0),
        .shift      (shift),
        .relu6_qmax (relu6_qmax),
        .quantized  (quantized)
    );

    // ---- clock: 10 ns period ------------------------------------------
    initial clock = 1'b0;
    always #5 clock = ~clock;

    // ---- one vector: drive, pulse en for a cycle, check registered out -
    task automatic run_case(
        input logic               t_act,
        input logic signed [20:0] t_acc,
        input logic signed [31:0] t_m0,
        input logic        [5:0]  t_shift,
        input logic signed [7:0]  t_q6,
        input logic signed [7:0]  t_expect,
        input string              tag
    );
        @(negedge clock);
        in_data    = t_acc;
        M0         = t_m0;
        shift      = t_shift;
        act        = t_act;
        relu6_qmax = t_q6;
        en         = 1'b1;
        @(posedge clock);          // result register loads here
        @(negedge clock);          // let the registered value settle
        en = 1'b0;

        total++;
        if (quantized === t_expect)
            $display("  [ok ] %-22s acc=%0d -> %0d", tag, t_acc, quantized);
        else begin
            fails++;
            $display("  [ERR] %-22s acc=%0d -> got %0d, expect %0d",
                     tag, t_acc, quantized, t_expect);
        end
    endtask

    // ---- stimulus -----------------------------------------------------
    initial begin
        // init + reset
        en = 0; act = ACT_NONE; in_data = 0; M0 = 0; shift = 6'd1; relu6_qmax = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("core, M = 0.5  (round-half-up toward +inf), via ACT_NONE:");
        run_case(ACT_NONE,    3, M0_HALF, 31, 8'sd0,   8'sd2,  "M=0.5 +3");
        run_case(ACT_NONE,   -3, M0_HALF, 31, 8'sd0,  -8'sd1,  "M=0.5 -3 tie->-1");
        run_case(ACT_NONE,    5, M0_HALF, 31, 8'sd0,   8'sd3,  "M=0.5 +5");
        run_case(ACT_NONE,   -5, M0_HALF, 31, 8'sd0,  -8'sd2,  "M=0.5 -5 tie->-2");
        run_case(ACT_NONE,    7, M0_HALF, 31, 8'sd0,   8'sd4,  "M=0.5 +7");
        run_case(ACT_NONE,   -7, M0_HALF, 31, 8'sd0,  -8'sd3,  "M=0.5 -7");
        run_case(ACT_NONE,  100, M0_HALF, 31, 8'sd0,   8'sd50, "M=0.5 +100");
        run_case(ACT_NONE, -100, M0_HALF, 31, 8'sd0,  -8'sd50, "M=0.5 -100");
        run_case(ACT_NONE,  101, M0_HALF, 31, 8'sd0,   8'sd51, "M=0.5 +101");
        run_case(ACT_NONE, -101, M0_HALF, 31, 8'sd0,  -8'sd50, "M=0.5 -101 tie->-50");

        $display("core, M = 0.25  (shift 32), via ACT_NONE:");
        run_case(ACT_NONE,   10, M0_HALF, 32, 8'sd0,   8'sd3,  "M=0.25 +10");
        run_case(ACT_NONE,  -10, M0_HALF, 32, 8'sd0,  -8'sd2,  "M=0.25 -10");
        run_case(ACT_NONE,    1, M0_HALF, 32, 8'sd0,   8'sd0,  "M=0.25 +1");
        run_case(ACT_NONE,   -1, M0_HALF, 32, 8'sd0,   8'sd0,  "M=0.25 -1");

        $display("big magnitude + clamp (catches product-overflow bug):");
        run_case(ACT_NONE,  1000000, 32'sd2000000000, 31, 8'sd6,  8'sd127, "big + -> sat127");
        run_case(ACT_NONE, -1000000, 32'sd2000000000, 31, 8'sd6, -8'sd128, "big - -> sat-128");

        $display("ReLU6 tail (clamp to [0, q6]):");
        run_case(ACT_RELU6,   -5, M0_HALF, 31, 8'sd6, 8'sd0, "relu6 -2 -> 0");
        run_case(ACT_RELU6,  101, M0_HALF, 31, 8'sd6, 8'sd6, "relu6 51 -> cap 6");
        run_case(ACT_RELU6,    7, M0_HALF, 31, 8'sd6, 8'sd4, "relu6 4 in [0,6]");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d cases)", total);
        else
            $display("FAILED    (%0d / %0d cases)", fails, total);

        $finish;
    end

endmodule
