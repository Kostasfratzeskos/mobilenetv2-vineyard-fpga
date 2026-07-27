`timescale 1ns / 1ps
//============================================================================
//  avgpool_tb.sv  -  self-checking testbench for rtl/kernels/avgpool.v
//
//  The DUT streams the H*W int8 samples of one channel and accumulates their
//  sum. This TB drives varied-length streams (first/last handshake) and checks
//  the accumulator against an independent reference sum.
//
//  ACC_W=32 here so random long streams never overflow; the real HW default
//  (ACC_W=21) easily holds a 7x7=49 sample sum.
//
//  Run:  bash scripts/run_sim.sh avgpool
//============================================================================
module avgpool_tb;

    localparam DATA_W = 8;
    localparam ACC_W  = 32;
    localparam MAXLEN = 400;

    logic                     clock, rst_n;
    logic                     valid, first, last;
    logic signed [DATA_W-1:0] a;
    logic signed [ACC_W-1:0]  acc;
    logic                     done;

    integer total = 0;
    integer fails = 0;

    avgpool #(.DATA_W(DATA_W), .ACC_W(ACC_W)) dut (
        .clock(clock), .rst_n(rst_n),
        .valid(valid), .first(first), .last(last),
        .a(a), .acc(acc), .done(done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    logic signed [DATA_W-1:0] sv [0:MAXLEN-1];

    // stream sv[0..len-1] through the accumulator and check the running sum
    task automatic run_pool(input integer len, input string tag);
        integer i;
        longint expected;
        begin
            expected = 0;
            for (i = 0; i < len; i++) expected += longint'(sv[i]);

            @(negedge clock);
            for (i = 0; i < len; i++) begin
                a     = sv[i];
                valid = 1'b1;
                first = (i == 0);
                last  = (i == len-1);
                @(posedge clock);
                @(negedge clock);
            end
            valid = 1'b0; first = 1'b0; last = 1'b0;

            total++;
            if (done !== 1'b1) begin
                fails++;
                $display("  [ERR] %-16s len=%0d : done not asserted", tag, len);
            end else if (acc !== ACC_W'(expected)) begin
                fails++;
                $display("  [ERR] %-16s len=%0d : acc=%0d expected=%0d", tag, len, acc, expected);
            end else begin
                $display("  [ok ] %-16s len=%0d : acc=%0d", tag, len, acc);
            end
        end
    endtask

    integer k, n, r;
    initial begin
        valid = 0; first = 0; last = 0; a = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("directed cases:");
        sv[0] = 8'sd42;                                     run_pool(1,  "single");
        for (k=0;k<49;k++) sv[k]=0;                         run_pool(49, "all zero");
        for (k=0;k<49;k++) sv[k]=8'sd127;                   run_pool(49, "all +127");  // 6223
        for (k=0;k<49;k++) sv[k]=-8'sd128;                  run_pool(49, "all -128");  // -6272
        for (k=0;k<50;k++) sv[k]=(k%2)? -8'sd10 : 8'sd10;   run_pool(50, "alternating");// 0

        $display("randomized cases:");
        for (n=0;n<20;n++) begin
            r = ($random % (MAXLEN-1)); if (r<0) r=-r; r=r+1;
            for (k=0;k<r;k++) sv[k] = $random;
            run_pool(r, $sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
