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
//  Run:  bash scripts/run_sim.sh requantize
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
    logic                      flush;
    logic                      act;
    logic signed [25:0]        in_data;      // ACC_W = 26
    logic signed [31:0]        M0;           // M0_W  = 32
    logic        [5:0]         shift;        // SHIFT_W = 6
    logic signed [7:0]         relu6_qmax;
    logic signed [7:0]         quantized;
    logic                      q_valid;

    // L-3: four register stages - in_data (absorbing bias_add), product,
    // round+shift, clamp. Derived here so a change to the DUT shows up as a
    // latency mismatch rather than as a wrong value.
    localparam RQ_LAT = 4;

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
        .flush      (flush),
        .act        (act),
        .in_data    (in_data),
        .M0         (M0),
        .shift      (shift),
        .relu6_qmax (relu6_qmax),
        .quantized  (quantized),
        .q_valid    (q_valid)
    );

    // ---- a second DUT for the L-4 / L-5 guards -------------------------
    //  The instance above keeps the shipping configuration, where a contract
    //  violation stops the simulation. This one reports instead, so the guards
    //  can be driven into every corner - including the corners that must NOT
    //  fire, which is the half that is easy to forget.
    localparam G_ACC_W   = 21;
    localparam G_ROUND_W = G_ACC_W + 32 + 1;      // 54
    localparam G_SH_MAX  = G_ROUND_W - 1;         // 53

    logic        [5:0]  g_shift;
    logic signed [31:0] g_m0;
    logic signed [20:0] g_acc;
    logic signed [7:0]  g_q;

    requantize #(.ACC_W(G_ACC_W), .M0_W(32), .SHIFT_W(6),
                 .CHECKS_ARE_FATAL(0)) g_dut (
        .clock(clock), .rst_n(rst_n), .en(1'b1), .flush(1'b0), .act(ACT_NONE),
        .in_data(g_acc), .M0(g_m0), .shift(g_shift), .relu6_qmax(8'sd0),
        .quantized(g_q), .q_valid()
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
        integer lat;
        @(negedge clock);
        in_data    = t_acc;
        M0         = t_m0;
        shift      = t_shift;
        act        = t_act;
        relu6_qmax = t_q6;
        en         = 1'b1;
        @(posedge clock);          // stage 1 captures in_data and the params
        @(negedge clock);
        en = 1'b0;

        // L-3: the answer is RQ_LAT stages away now, and `q_valid` marks it.
        // Counted rather than assumed - docs/latency_map.md's convention, where
        // a single registered output is 1.
        lat = 1;
        while (q_valid !== 1'b1 && lat < 32) begin
            @(posedge clock); @(negedge clock);
            lat++;
        end
        if (q_valid !== 1'b1) begin
            fails++;
            $display("  [ERR] %-22s q_valid never came back", tag);
        end else if (lat !== RQ_LAT) begin
            fails++;
            $display("  [ERR] %-22s q_valid came %0d cycles after en, RQ_LAT says %0d",
                     tag, lat, RQ_LAT);
        end

        total++;
        if (quantized === t_expect)
            $display("  [ok ] %-22s acc=%0d -> %0d", tag, t_acc, quantized);
        else begin
            fails++;
            $display("  [ERR] %-22s acc=%0d -> got %0d, expect %0d",
                     tag, t_acc, quantized, t_expect);
        end
    endtask

    // Drive the guard DUT for one cycle and check the OUTPUT VALUE. The
    // tripwire lines are evidence in the log; what is ASSERTED here is that the
    // guard changed no reachable result.
    task automatic g_case(input logic signed [20:0] acc_in,
                          input logic signed [31:0] m0_in,
                          input logic [5:0] sh_in,
                          input logic signed [7:0] expect_q,
                          input string tag);
        begin
            @(negedge clock);
            g_acc = acc_in; g_m0 = m0_in; g_shift = sh_in;
            // the guard DUT has en tied high, so the pipeline free-runs: hold
            // the inputs for RQ_LAT edges and the answer emerges.
            repeat (RQ_LAT) @(posedge clock);
            @(negedge clock);
            total++;
            if (g_q === expect_q)
                $display("  [ok ] %-36s -> %0d", tag, g_q);
            else begin
                fails++;
                $display("  [ERR] %-36s -> got %0d, expect %0d", tag, g_q, expect_q);
            end
        end
    endtask

    // ---- stimulus -----------------------------------------------------
    initial begin
        // init + reset
        en = 0; flush = 0; act = ACT_NONE; in_data = 0; M0 = 0; shift = 6'd1; relu6_qmax = 0;
        g_acc = 0; g_m0 = 0; g_shift = 6'd1;
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

        // ---- L-4 / L-5: the shift guard -------------------------------
        //
        //  `half = 1 << (shift-1)` with an unsigned SHIFT_W-bit subtract, so
        //  shift=0 wrapped to 63 and the rounding term vanished, and shift=59
        //  (at ACC_W=26) put the rounding one ON THE SIGN BIT. At ACC_W=21 the
        //  boundary is 53. The guard makes both cases produce 0 explicitly.
        //
        //  The important half of this is the cases that must NOT change: the
        //  whole point of Phase 1 is that no reachable value moves.
        $display("");
        $display("L-4 / L-5, the shift guard (ACC_W=%0d, so SH_MAX=%0d):",
                 G_ACC_W, G_SH_MAX);

        // legitimate tail lane: shift=0 AND m0=0. Must be silent and give 0.
        g_case(21'sd100, 32'sd0, 6'd0, 8'sd0, "tail lane shift=0 m0=0 (silent)");

        // L-4: shift=0 with a REAL m0. The tripwire must fire. Note what the
        // result is: 100 * 2**30 >>> 0 saturates to 127, because a lost shift
        // means the value is never scaled down at all. That is the damage the
        // check is there to report - it is not a rounding error, it is a
        // channel pinned at saturation.
        g_case(21'sd100, M0_HALF, 6'd0, 8'sd127, "L-4 shift=0 m0!=0 (must fire)");

        // L-5: past SH_MAX the rounding term is suppressed instead of becoming
        // -2**(ROUND_W-1). With m0 small the result is 0 either way, but the
        // tripwire must say so.
        g_case(21'sd100, M0_HALF, G_SH_MAX[5:0] + 6'd1, 8'sd0,
               "L-5 shift=SH_MAX+1 (must fire)");
        g_case(21'sd100, M0_HALF, 6'd63, 8'sd0, "L-5 shift=63 (must fire)");

        // and the boundary that must stay silent and exact
        g_case(21'sd100, M0_HALF, G_SH_MAX[5:0], 8'sd0, "shift=SH_MAX (silent)");
        g_case(21'sd3,   M0_HALF, 6'd31,         8'sd2, "shift=31 unchanged by the guard");
        g_case(-21'sd3,  M0_HALF, 6'd31,        -8'sd1, "shift=31 negative tie unchanged");
        g_case(21'sd1,   M0_HALF, 6'd1,          8'sd127,
               "shift=1 (smallest legal) unchanged");

        // ---- C-10: a flush must kill a result already in flight ----------
        //
        //  This is the defect C-10 named: out_stage's flush cleared its own stage
        //  A and nothing behind it, so a result already latched still produced a
        //  q_valid RQ_LAT cycles later - into whichever feeder had since been
        //  selected. Now `flush` clears requantize's whole valid pipeline, and
        //  this is the test that says so. Without the fix, q_valid arrives and
        //  this reports a failure.
        $display("");
        $display("C-10, the flush:");
        begin
            integer k;
            logic   saw_qv;

            @(negedge clock);
            in_data = 21'sd100; M0 = M0_HALF; shift = 6'd31;
            act = ACT_NONE; relu6_qmax = 8'sd0;
            en = 1'b1;
            @(posedge clock);            // stage 1 loads
            @(negedge clock);
            en = 1'b0;
            // one more stage, so there is definitely something in flight
            @(posedge clock); @(negedge clock);

            flush = 1'b1;
            @(posedge clock); @(negedge clock);
            flush = 1'b0;

            // give it more than the whole pipeline to (not) come out
            saw_qv = 1'b0;
            for (k = 0; k < RQ_LAT + 4; k = k + 1) begin
                if (q_valid === 1'b1) saw_qv = 1'b1;
                @(posedge clock); @(negedge clock);
            end

            total++;
            if (saw_qv) begin
                fails++;
                $display("  [ERR] flush did NOT drop the in-flight result: q_valid still came");
            end else
                $display("  [ok ] flush dropped the in-flight result (no q_valid)");
        end

        // and the pipeline still works afterwards - a flush must not wedge it
        run_case(ACT_NONE, 3, M0_HALF, 31, 8'sd0, 8'sd2, "works after flush");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d cases)", total);
        else
            $display("FAILED    (%0d / %0d cases)", fails, total);

        $finish;
    end

endmodule
