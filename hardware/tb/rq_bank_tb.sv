`timescale 1ns / 1ps
//============================================================================
//  rq_bank_tb.sv  -  self-checking testbench for rtl/control/rq_bank.v
//
//  rq_bank invents no arithmetic: it wraps 32 copies of the already-proven
//  bias_add + requantize pair. So what can be wrong is the WRAPPING - a lane
//  reading another lane's bias, m0 or shift, a result landing in the wrong
//  byte of the 256-bit word, or a per-layer scalar not reaching every lane.
//  Every case below therefore gives each of the 32 lanes a DIFFERENT
//  accumulator AND different (bias, m0, shift), so any crossed bus shows up.
//
//  Two oracles, as everywhere in this project:
//    1. an independent reference of the requantize math computed here in
//       longint - including the two's-complement truncation that bias_add
//       performs when acc+bias exceeds ACC_W, so the check is exact rather
//       than relying on a precondition; and
//    2. a SINGLE bias_add + requantize chain, driven one lane at a time.
//       This is the same silicon as inside the bank, just not replicated,
//       which is exactly the right control for a wrapper: it cannot be fooled
//       by an arithmetic mistake, only by a wiring one.
//
//  Unlike pe_array_tb and pw_feeder_tb this runs at the REAL ACC_W = 21. This
//  module does not accumulate, so there is no overflow headroom to buy and no
//  reason to test a width the hardware will not have.
//
//  Run:  bash scripts/run_sim.sh rq_bank bias_add requantize
//============================================================================
module rq_bank_tb;

    localparam TM      = 32;
    localparam ACC_W   = 26;        // the real datapath width
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam DATA_W  = 8;

    localparam ACT_NONE  = 1'b0;
    localparam ACT_RELU6 = 1'b1;

    logic clock, rst_n;

    // ---- DUT ---------------------------------------------------------------
    logic                    en, act;
    logic signed [7:0]       qmax;
    logic [TM*ACC_W-1:0]     acc_bus;
    logic [TM*BIAS_W-1:0]    bias_bus;
    logic [TM*M0_W-1:0]      m0_bus;
    logic [TM*SHIFT_W-1:0]   sh_bus;
    wire  [TM*DATA_W-1:0]    q_bus;
    wire                     q_valid;

    rq_bank #(.TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
              .SHIFT_W(SHIFT_W), .DATA_W(DATA_W)) u_dut (
        .clock(clock), .rst_n(rst_n), .en(en),
        .act(act), .relu6_qmax(qmax),
        .acc(acc_bus), .bias(bias_bus), .m0(m0_bus), .shift(sh_bus),
        .q(q_bus), .q_valid(q_valid)
    );

    // ---- oracle 2: one bias_add + requantize chain -------------------------
    logic                     s_en;
    logic signed [ACC_W-1:0]  s_acc;
    logic signed [BIAS_W-1:0] s_bias;
    logic signed [M0_W-1:0]   s_m0;
    logic [SHIFT_W-1:0]       s_sh;
    wire  signed [ACC_W-1:0]  s_biased;
    wire  signed [7:0]        s_q;

    bias_add #(.ACC_W(ACC_W), .BIAS_W(BIAS_W)) u_sb (
        .acc_in(s_acc), .bias(s_bias), .acc_out(s_biased)
    );
    requantize #(.ACC_W(ACC_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W)) u_sr (
        .clock(clock), .rst_n(rst_n), .en(s_en),
        .act(act), .in_data(s_biased), .M0(s_m0), .shift(s_sh),
        .relu6_qmax(qmax), .quantized(s_q)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ---- stimulus ----------------------------------------------------------
    longint accv  [0:TM-1];
    longint biasv [0:TM-1];
    longint m0v   [0:TM-1];
    integer shv   [0:TM-1];

    // ---- oracle 1: the requantize math, independently ----------------------
    //  product = biased * M0 ; rounded = product + (1 << (shift-1))
    //  r = rounded >>> shift ; then clamp per activation
    //  `biased` wraps to ACC_W two's complement, exactly as bias_add does.
    function automatic logic signed [7:0] ref_q(input integer lane);
        longint biased, prod, rounded, r, lim;
        begin
            biased = accv[lane] + biasv[lane];
            lim    = longint'(1) << ACC_W;
            biased = biased % lim;
            if (biased < 0) biased += lim;
            if (biased >= (lim >> 1)) biased -= lim;

            prod    = biased * m0v[lane];
            rounded = prod + (longint'(1) << (shv[lane] - 1));
            r       = rounded >>> shv[lane];

            if (act == ACT_RELU6) begin
                if (r < 0)                 r = 0;
                else if (r > longint'(qmax)) r = longint'(qmax);
            end else begin
                if (r < -128)     r = -128;
                else if (r > 127) r = 127;
            end
            ref_q = r[7:0];
        end
    endfunction

    task automatic pack_buses;
        integer m;
        begin
            for (m = 0; m < TM; m++) begin
                acc_bus [m*ACC_W   +: ACC_W]   = accv[m][ACC_W-1:0];
                bias_bus[m*BIAS_W  +: BIAS_W]  = biasv[m][BIAS_W-1:0];
                m0_bus  [m*M0_W    +: M0_W]    = m0v[m][M0_W-1:0];
                sh_bus  [m*SHIFT_W +: SHIFT_W] = shv[m][SHIFT_W-1:0];
            end
        end
    endtask

    // drive the 32-wide bank once, then replay every lane through the
    // single chain, and score both against the reference
    task automatic run_case(input string tag);
        integer m, bad_ref, bad_ora;
        logic signed [7:0] got, expd;
        begin
            bad_ref = 0; bad_ora = 0;
            pack_buses;

            @(negedge clock);
            en = 1'b1;
            @(posedge clock);
            @(negedge clock);
            en = 1'b0;

            if (q_valid !== 1'b1) begin
                fails++;
                $display("  [ERR] %-18s q_valid not asserted", tag);
            end

            // oracle 1 - every lane against the independent reference
            for (m = 0; m < TM; m++) begin
                got  = q_bus[m*DATA_W +: DATA_W];
                expd = ref_q(m);
                if (got !== expd) begin
                    bad_ref++;
                    if (bad_ref <= 4)
                        $display("  [ERR] %-18s lane=%0d : got %0d expected %0d  (acc=%0d bias=%0d m0=%0d sh=%0d)",
                                 tag, m, got, expd, accv[m], biasv[m], m0v[m], shv[m]);
                end
            end

            // oracle 2 - every lane through the single proven chain
            for (m = 0; m < TM; m++) begin
                @(negedge clock);
                s_acc  = accv[m][ACC_W-1:0];
                s_bias = biasv[m][BIAS_W-1:0];
                s_m0   = m0v[m][M0_W-1:0];
                s_sh   = shv[m][SHIFT_W-1:0];
                s_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                s_en = 1'b0;
                if (s_q !== q_bus[m*DATA_W +: DATA_W]) begin
                    bad_ora++;
                    if (bad_ora <= 4)
                        $display("  [ERR] %-18s lane=%0d : bank %0d != single chain %0d",
                                 tag, m, $signed(q_bus[m*DATA_W +: DATA_W]), s_q);
                end
            end

            total++;
            if (bad_ref != 0 || bad_ora != 0) begin
                fails++;
                $display("  [ERR] %-18s %0d vs reference, %0d vs single chain",
                         tag, bad_ref, bad_ora);
            end else
                $display("  [ok ] %-18s %0d lanes vs reference AND vs single chain",
                         tag, TM);
        end
    endtask

    // realistic (m0, shift) pairs: m0 near 2^30, shift ~37 -> scale ~ 1/128
    task automatic fill_realistic(input integer acc_span);
        integer m, r;
        begin
            for (m = 0; m < TM; m++) begin
                r        = $random;
                accv[m]  = (r % acc_span);
                biasv[m] = ($random % 4096);
                // every lane a DIFFERENT multiplier and shift
                m0v[m]   = longint'(32'h4000_0000) + (m * 1234567);
                shv[m]   = 30 + (m % 8);
            end
        end
    endtask

    integer m, n;
    initial begin
        en = 0; s_en = 0; act = ACT_NONE; qmax = 8'sd0;
        acc_bus = 0; bias_bus = 0; m0_bus = 0; sh_bus = 0;
        s_acc = 0; s_bias = 0; s_m0 = 0; s_sh = 0;
        for (m = 0; m < TM; m++) begin accv[m]=0; biasv[m]=0; m0v[m]=1; shv[m]=1; end
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("rq_bank: %0d lanes, ACC_W=%0d (the real datapath width)", TM, ACC_W);
        $display("");
        $display("ACT_NONE, distinct bias/m0/shift per lane:");
        act = ACT_NONE; qmax = 8'sd0;

        for (m = 0; m < TM; m++) begin accv[m]=0; biasv[m]=0; m0v[m]=32'h4000_0000; shv[m]=31; end
        run_case("all zero");

        fill_realistic(200000);
        run_case("realistic mid");

        // clamp high: push every lane past +127
        for (m = 0; m < TM; m++) begin
            accv[m]  = 1000000 + m*100;
            biasv[m] = 0;
            m0v[m]   = 32'h7FFF_FFFF;
            shv[m]   = 20 + (m % 4);
        end
        run_case("clamp +127");

        // clamp low: push every lane past -128
        for (m = 0; m < TM; m++) begin
            accv[m]  = -1000000 - m*100;
            biasv[m] = 0;
            m0v[m]   = 32'h7FFF_FFFF;
            shv[m]   = 20 + (m % 4);
        end
        run_case("clamp -128");

        // bias alone decides the sign, accumulators are zero
        for (m = 0; m < TM; m++) begin
            accv[m]  = 0;
            biasv[m] = (m % 2) ? -100000 : 100000;
            m0v[m]   = 32'h4000_0000;
            shv[m]   = 32;
        end
        run_case("bias only");

        $display("");
        $display("ACT_RELU6 (clamped to [0, relu6_qmax]):");
        act = ACT_RELU6; qmax = 8'sd127;
        fill_realistic(200000);
        run_case("relu6 qmax=127");

        qmax = 8'sd40;                     // a tighter ceiling
        fill_realistic(400000);
        run_case("relu6 qmax=40");

        // negatives must floor at 0, not wrap
        for (m = 0; m < TM; m++) begin
            accv[m]  = -50000 - m*777;
            biasv[m] = 0;
            m0v[m]   = 32'h4000_0000;
            shv[m]   = 30;
        end
        run_case("relu6 negatives");

        $display("");
        $display("randomized:");
        act = ACT_NONE; qmax = 8'sd0;
        for (n = 0; n < 6; n++) begin
            for (m = 0; m < TM; m++) begin
                accv[m]  = $random % 1048576;
                biasv[m] = $random % 100000;
                m0v[m]   = longint'(32'h2000_0000) + ($random % 1000000000);
                if (m0v[m] < 1) m0v[m] = 1;
                shv[m]   = 24 + (m % 16);
            end
            run_case($sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases, %0d lane-checks)", total, total*TM*2);
        else            $display("FAILED    (%0d errors in %0d cases)", fails, total);
        $finish;
    end

endmodule
