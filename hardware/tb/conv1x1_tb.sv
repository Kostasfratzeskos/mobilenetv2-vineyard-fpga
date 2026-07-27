`timescale 1ns / 1ps
//============================================================================
//  conv1x1_tb.sv  -  self-checking testbench for rtl/kernels/conv1x1.v
//
//  The DUT computes ONE streamed dot product. This TB checks the arithmetic
//  directly: it builds int8 activation/weight vectors, streams them through
//  the engine (first/last handshake), and compares the accumulator against an
//  independent reference sum computed here.
//
//  Coverage:
//    - directed edge cases (len 1, all zero, all max, mixed signs)
//    - randomized dot products of varied length
//  Lengths and value ranges are kept so the true sum fits ACC_W (no overflow),
//  matching how the real HW accumulator is sized never to overflow.
//
//  Run:  bash scripts/run_sim.sh conv1x1
//============================================================================
module conv1x1_tb;

    localparam DATA_W = 8;
    localparam ACC_W  = 32;      // wide here so random sums never overflow
    localparam MAXLEN = 300;

    logic                     clock;
    logic                     rst_n;
    logic                     valid;
    logic                     first;
    logic                     last;
    logic signed [DATA_W-1:0] a;
    logic signed [DATA_W-1:0] w;
    logic signed [ACC_W-1:0]  acc;
    logic                     done;

    integer total = 0;
    integer fails = 0;

    conv1x1 #(.DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .clock (clock),
        .rst_n (rst_n),
        .valid (valid),
        .first (first),
        .last  (last),
        .a     (a),
        .w     (w),
        .acc   (acc),
        .done  (done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    // storage for one test vector
    logic signed [DATA_W-1:0] av [0:MAXLEN-1];
    logic signed [DATA_W-1:0] wv [0:MAXLEN-1];

    // stream av/wv[0..len-1] through the engine and check the result
    task automatic run_dot(input integer len, input string tag);
        integer i;
        longint expected;   // independent reference sum
        begin
            expected = 0;
            for (i = 0; i < len; i++) expected += longint'(av[i]) * longint'(wv[i]);

            @(negedge clock);
            for (i = 0; i < len; i++) begin
                a     = av[i];
                w     = wv[i];
                valid = 1'b1;
                first = (i == 0);
                last  = (i == len - 1);
                @(posedge clock);      // element i accumulates here
                @(negedge clock);
            end
            valid = 1'b0; first = 1'b0; last = 1'b0;

            // after the last accumulate, done is high and acc is final
            total++;
            if (done !== 1'b1) begin
                fails++;
                $display("  [ERR] %-18s len=%0d : done not asserted", tag, len);
            end else if (acc !== ACC_W'(expected)) begin
                fails++;
                $display("  [ERR] %-18s len=%0d : acc=%0d expected=%0d", tag, len, acc, expected);
            end else begin
                $display("  [ok ] %-18s len=%0d : acc=%0d", tag, len, acc);
            end
        end
    endtask

    integer k, n, r;
    initial begin
        valid = 0; first = 0; last = 0; a = 0; w = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("directed cases:");

        // len 1
        av[0] = 8'sd7; wv[0] = -8'sd9;
        run_dot(1, "single -63");

        // all zero
        for (k = 0; k < 16; k++) begin av[k] = 0; wv[k] = 0; end
        run_dot(16, "all zero");

        // all max positive: 64 * (127*127)
        for (k = 0; k < 64; k++) begin av[k] = 8'sd127; wv[k] = 8'sd127; end
        run_dot(64, "all +127");

        // all max magnitude negative*positive: 64 * (-128*127)
        for (k = 0; k < 64; k++) begin av[k] = -8'sd128; wv[k] = 8'sd127; end
        run_dot(64, "all -128*127");

        // alternating signs cancel toward zero
        for (k = 0; k < 10; k++) begin
            av[k] = 8'sd100;
            wv[k] = (k % 2 == 0) ? 8'sd5 : -8'sd5;
        end
        run_dot(10, "alternating");

        $display("randomized cases:");
        for (n = 0; n < 20; n++) begin
            r = ($random % (MAXLEN-1)); if (r < 0) r = -r; r = r + 1;   // 1..MAXLEN-1
            for (k = 0; k < r; k++) begin
                av[k] = $random;   // truncates to signed 8-bit -> full int8 range
                wv[k] = $random;
            end
            run_dot(r, $sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
