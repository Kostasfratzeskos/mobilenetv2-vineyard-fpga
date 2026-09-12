`timescale 1ns / 1ps
//============================================================================
//  pw_out_tb.sv  -  self-checking testbench for rtl/control/pw_out.v
//
//  pw_out is the output half: accumulators in, int8 words out to act_buffer.
//  Three things have to be right at once, and they fail independently:
//
//    1. the DATA - all 32 lanes requantized with THEIR OWN channel's bias, m0
//       and shift, fetched from the parameter buffer by oc_tile;
//    2. the ADDRESS - one consecutive entry per result, starting at base_out,
//       which is the claim that makes a counter sufficient instead of a
//       multiplier; and
//    3. the ORDER - the tag self-check must stay quiet on correct input.
//
//  The testbench drives results the way pw_feeder does (pixel-major,
//  oc_tile-minor, back to back so the 2-cycle pipeline is actually full) and
//  scores every write against an independent longint reference of the
//  requantize math - the same reference rq_bank_tb uses, including bias_add's
//  two's-complement truncation.
//
//  It also tests the TRIPWIRE ITSELF: a deliberately wrong tag must raise
//  tag_error, and `start` must clear it. A self-check that cannot fire is
//  worse than none, because it reads as reassurance.
//
//  param_buffer and out_stage have no testbenches of their own: every write port
//  is driven here and every read field changes the results, so separate ones
//  would only duplicate this coverage. Runs at the real ACC_W = 21.
//
//  Run:  bash scripts/run_sim.sh pw_out out_stage param_buffer rq_bank bias_add requantize
//============================================================================
module pw_out_tb;

    localparam TM      = 32;
    localparam ACC_W   = 21;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam DATA_W  = 8;
    localparam PIX_W   = 16;
    localparam OCT_W   = 8;
    localparam PDEPTH  = 64;
    localparam PA_W    = 6;
    localparam BANK_W  = 5;
    localparam AA_W    = 16;

    localparam ACT_NONE  = 1'b0;
    localparam ACT_RELU6 = 1'b1;

    localparam MAXR = 96;      // results tracked in flight
    localparam MAXC = 512;     // channels the testbench models

    logic clock, rst_n;

    logic                    start;
    logic [OCT_W-1:0]        n_oc;
    logic [AA_W-1:0]         base_out;
    logic                    act;
    logic signed [7:0]       qmax;

    logic                    pl_en;
    logic [BANK_W-1:0]       pl_bank;
    logic [PA_W-1:0]         pl_addr;
    logic signed [BIAS_W-1:0] pl_bias;
    logic signed [M0_W-1:0]  pl_m0;
    logic [SHIFT_W-1:0]      pl_shift;

    logic [TM*ACC_W-1:0]     acc_bus;
    logic                    acc_valid;
    logic [PIX_W-1:0]        acc_pix;
    logic [OCT_W-1:0]        acc_oct;

    wire                     aw_en;
    wire [AA_W-1:0]          aw_addr;
    wire [TM*DATA_W-1:0]     aw_data;
    wire                     tag_error;

    pw_out #(.TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
             .SHIFT_W(SHIFT_W), .DATA_W(DATA_W), .PIX_W(PIX_W), .OCT_W(OCT_W),
             .PDEPTH(PDEPTH), .PA_W(PA_W), .BANK_W(BANK_W), .AA_W(AA_W)) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_oc(n_oc), .base_out(base_out),
        .act(act), .relu6_qmax(qmax),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .acc(acc_bus), .acc_valid(acc_valid), .acc_pix(acc_pix), .acc_oct(acc_oct),
        .aw_en(aw_en), .aw_addr(aw_addr), .aw_data(aw_data),
        .tag_error(tag_error)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ---- the parameters the testbench believes in, per channel -------------
    longint pbias [0:MAXC-1];
    longint pm0   [0:MAXC-1];
    integer pshv  [0:MAXC-1];

    // ---- results fed, awaiting their write --------------------------------
    longint hist_acc [0:MAXR-1][0:TM-1];
    integer hist_oct [0:MAXR-1];
    integer n_fed, n_written, bad;
    integer mon_on;

    // ---- oracle: the requantize math, independently -----------------------
    function automatic logic signed [7:0] ref_q(input longint accv,
                                                input longint biasv,
                                                input longint m0v,
                                                input integer shiftv);
        longint biased, prod, rounded, r, lim;
        begin
            biased = accv + biasv;
            lim    = longint'(1) << ACC_W;
            biased = biased % lim;
            if (biased < 0) biased += lim;
            if (biased >= (lim >> 1)) biased -= lim;

            prod    = biased * m0v;
            rounded = prod + (longint'(1) << (shiftv - 1));
            r       = rounded >>> shiftv;

            if (act == ACT_RELU6) begin
                if (r < 0)                   r = 0;
                else if (r > longint'(qmax)) r = longint'(qmax);
            end else begin
                if (r < -128)     r = -128;
                else if (r > 127) r = 127;
            end
            ref_q = r[7:0];
        end
    endfunction

    // ---- monitor: score every write ---------------------------------------
    task automatic check_write;
        integer m, ch;
        logic signed [7:0] got, expd;
        integer oct_i;
        begin
            if (n_written >= MAXR) begin
                bad++;
                $display("  [ERR] more writes than results fed");
            end else begin
                if (aw_addr !== (base_out + n_written[AA_W-1:0])) begin
                    bad++;
                    if (bad <= 5)
                        $display("  [ERR] write %0d: addr %0d expected %0d",
                                 n_written, aw_addr, base_out + n_written);
                end
                oct_i = hist_oct[n_written];
                for (m = 0; m < TM; m++) begin
                    ch   = oct_i*TM + m;
                    got  = aw_data[m*DATA_W +: DATA_W];
                    expd = ref_q(hist_acc[n_written][m], pbias[ch], pm0[ch], pshv[ch]);
                    if (got !== expd) begin
                        bad++;
                        if (bad <= 5)
                            $display("  [ERR] write %0d lane=%0d (ch=%0d): got %0d expected %0d",
                                     n_written, m, ch, got, expd);
                    end
                end
            end
            n_written++;
        end
    endtask

    always @(negedge clock)
        if (mon_on && aw_en) check_write;

    // ---- load the parameter buffer, one channel per cycle -----------------
    task automatic load_params(input integer nocs);
        integer ot, m, ch;
        begin
            for (ot = 0; ot < nocs; ot++)
                for (m = 0; m < TM; m++) begin
                    ch = ot*TM + m;
                    @(negedge clock);
                    pl_bank  = m[BANK_W-1:0];
                    pl_addr  = ot[PA_W-1:0];
                    pl_bias  = pbias[ch][BIAS_W-1:0];
                    pl_m0    = pm0[ch][M0_W-1:0];
                    pl_shift = pshv[ch][SHIFT_W-1:0];
                    pl_en    = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    pl_en = 1'b0;
                end
        end
    endtask

    // ---- feed one result, the way pw_feeder would --------------------------
    task automatic feed(input integer pix, input integer oct, input integer span);
        integer m;
        begin
            @(negedge clock);
            for (m = 0; m < TM; m++) begin
                hist_acc[n_fed][m] = ($random % span);
                acc_bus[m*ACC_W +: ACC_W] = hist_acc[n_fed][m][ACC_W-1:0];
            end
            hist_oct[n_fed] = oct;
            acc_pix   = pix[PIX_W-1:0];
            acc_oct   = oct[OCT_W-1:0];
            acc_valid = 1'b1;
            n_fed++;
            @(posedge clock);
            @(negedge clock);
            acc_valid = 1'b0;
            // pe_array reuses its accumulators the moment the next dot product
            // starts, so the bus must NOT still hold this result a cycle later.
            // Scribbling here is what makes pw_out's capture register load
            // bearing: without it the requantize stage would read this garbage.
            for (m = 0; m < TM; m++)
                acc_bus[m*ACC_W +: ACC_W] = ACC_W'(20'hDEAD0 + m);
        end
    endtask

    // ---- run a whole layer -------------------------------------------------
    task automatic run_layer(input integer npix, input integer nocs,
                             input integer base, input integer span,
                             input string tag);
        integer p, o;
        begin
            // fresh parameters for every channel of this layer
            for (o = 0; o < nocs*TM; o++) begin
                pbias[o] = ($random % 8192);
                // keep m0 a POSITIVE int32: pl_m0 is signed [31:0], so a
                // value past 2**31-1 would reach the DUT negative while the
                // longint reference kept it positive - a testbench bug, not a
                // DUT one, and exactly what bit the first run of this test.
                pm0[o]   = longint'(32'h2000_0000)
                           + ((o * 7654321) % longint'(32'h4000_0000));
                pshv[o]  = 28 + (o % 10);
            end
            load_params(nocs);

            @(negedge clock);
            n_oc     = nocs[OCT_W-1:0];
            base_out = base[AA_W-1:0];
            start    = 1'b1;
            n_fed = 0; n_written = 0; bad = 0; mon_on = 1;
            @(negedge clock);
            start = 1'b0;

            // back to back, so the 2-cycle pipeline is genuinely full
            for (p = 0; p < npix; p++)
                for (o = 0; o < nocs; o++)
                    feed(p, o, span);

            repeat (6) @(negedge clock);      // let the pipeline drain
            mon_on = 0;

            total++;
            if (n_written !== n_fed) begin
                bad++;
                $display("  [ERR] %-16s %0d writes for %0d results", tag, n_written, n_fed);
            end
            if (tag_error !== 1'b0) begin
                bad++;
                $display("  [ERR] %-16s tag_error raised on correct input", tag);
            end

            if (bad == 0)
                $display("  [ok ] %-16s %0dpx x %0d tiles : %0d writes from base %0d, all %0d channels",
                         tag, npix, nocs, n_written, base, n_written*TM);
            else
                fails++;
        end
    endtask

    integer m;
    initial begin
        start = 0; n_oc = 1; base_out = 0; act = ACT_NONE; qmax = 8'sd0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        acc_bus = 0; acc_valid = 0; acc_pix = 0; acc_oct = 0;
        n_fed = 0; n_written = 0; bad = 0; mon_on = 0;
        for (m = 0; m < MAXC; m++) begin pbias[m]=0; pm0[m]=1; pshv[m]=1; end
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("pw_out: param_buffer + rq_bank + write counter, ACC_W=%0d", ACC_W);
        $display("");
        $display("ACT_NONE:");
        act = ACT_NONE; qmax = 8'sd0;
        run_layer(4,  1,   0, 300000, "1 tile/px");
        run_layer(4,  3,   0, 300000, "3 tiles/px");
        run_layer(6,  2, 500, 300000, "base=500");
        run_layer(1, 10,   0, 300000, "10 tiles, 1px");

        $display("");
        $display("ACT_RELU6:");
        act = ACT_RELU6; qmax = 8'sd127;
        run_layer(4, 2, 0, 300000, "relu6 qmax=127");
        qmax = 8'sd40;
        run_layer(4, 2, 0, 900000, "relu6 qmax=40");

        $display("");
        $display("the tag self-check itself:");
        act = ACT_NONE; qmax = 8'sd0;

        // correct order first, tag_error must stay low
        run_layer(3, 2, 0, 300000, "clean order");

        // now feed a WRONG oct and require tag_error to fire
        @(negedge clock);
        n_oc = 8'd2; base_out = 16'd0; start = 1'b1;
        n_fed = 0; n_written = 0; bad = 0; mon_on = 0;
        @(negedge clock);
        start = 1'b0;
        feed(0, 0, 1000);        // correct
        feed(0, 1, 1000);        // correct
        feed(1, 1, 1000);        // WRONG - should be (1,0)
        repeat (4) @(negedge clock);
        total++;
        if (tag_error !== 1'b1) begin
            fails++;
            $display("  [ERR] tag_error did NOT fire on a wrong tag");
        end else
            $display("  [ok ] tag_error fires on a wrong (pix,oct)");

        // a tag wrong in PIX ONLY must also fire - the previous case had both
        // fields wrong, so it could not tell a full comparison from an
        // oct-only one.
        @(negedge clock);
        n_oc = 8'd2; base_out = 16'd0; start = 1'b1;
        n_fed = 0; n_written = 0; bad = 0; mon_on = 0;
        @(negedge clock);
        start = 1'b0;
        feed(0, 0, 1000);
        feed(0, 1, 1000);
        feed(1, 0, 1000);
        feed(1, 1, 1000);
        feed(3, 0, 1000);        // WRONG pix - should be 2 - but oct is right
        repeat (4) @(negedge clock);
        total++;
        if (tag_error !== 1'b1) begin
            fails++;
            $display("  [ERR] tag_error did NOT fire on a wrong pix alone");
        end else
            $display("  [ok ] tag_error fires on a wrong pix alone");

        // and `start` must clear it
        @(negedge clock);
        start = 1'b1;
        @(negedge clock);
        start = 1'b0;
        @(negedge clock);
        total++;
        if (tag_error !== 1'b0) begin
            fails++;
            $display("  [ERR] start did not clear tag_error");
        end else
            $display("  [ok ] start clears tag_error");

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
