`timescale 1ns / 1ps
//============================================================================
//  lin_datapath_tb.sv  -  INTEGRATION: the classifier tail vs the golden
//
//  The last op of the network, and the first test whose output is an ANSWER
//  rather than a feature map.
//
//  Layer: classifier.1   1x1x1280 -> 4 int16 logits -> one class
//     input  = golden 063_avgpool                (1280 int8, the GAP output)
//     acc    = golden 064_classifier_1_acc_int32 (post-bias, 4 values)
//     logits = golden 065_classifier_1_logits_int16
//
//  No new feeder: the classifier IS a 1x1 convolution with n_pix=1, n_oc=1,
//  n_ic=80, so pw_feeder runs it unchanged and only the tail is different -
//  logit_out instead of pw_out. That substitution is the whole point of this
//  test.
//
//  Three things are checked, in increasing order of how much they mean:
//    1. the 21-bit accumulators against golden 064, which is the post-bias
//       int32 the C model dumped - this is the network's LONGEST dot product
//       (IC=1280) and so the tightest point for ACC_W;
//    2. the int16 logits against golden 065, which exercises the clamp_i16
//       path that requantize.v's new OUT_W parameter opens up (DD-011); and
//    3. the predicted class, which is what the whole accelerator exists to
//       produce.
//
//  Run:  bash scripts/run_sim.sh lin_datapath pw_feeder logit_out addr_gen \
//          wgt_buffer act_buffer pe_array mac_lane bias_add requantize
//============================================================================
module lin_datapath_tb;

    // ---- layer ------------------------------------------------------------
    localparam IC    = 1280;
    localparam OC    = 4;
    localparam NPIX  = 1;

    // ---- datapath ---------------------------------------------------------
    localparam DATA_W  = 8;
    localparam TM      = 32;
    localparam TN      = 16;
    localparam ACC_W   = 21;
    localparam SEL_W   = 1;
    localparam BANK_W  = 5;
    localparam PIX_W   = 16;
    localparam OCT_W   = 8;
    localparam ICT_W   = 8;
    localparam WA_W    = 10;
    localparam AA_W    = 16;
    localparam WDEPTH  = 128;
    localparam ADEPTH  = 128;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam LOG_W   = 16;
    localparam IDX_W   = 2;

    localparam N_IC  = (IC + TN - 1) / TN;          // 80
    localparam N_OC  = (OC + TM - 1) / TM;          // 1
    localparam N_ENT = (IC + TM - 1) / TM;          // 40
    localparam BASE_I = 0;

    // ---- golden ----------------------------------------------------------
    reg [7:0]  in_mem  [0:IC-1];        // golden 063: the pooled vector
    reg [7:0]  wq_mem  [0:OC*IC-1];     // (OC, IC) row-major
    reg [31:0] b_mem   [0:OC-1];
    reg [31:0] m0_mem  [0:OC-1];
    reg [7:0]  sh_mem  [0:OC-1];
    reg [31:0] gacc    [0:OC-1];        // golden 064, post-bias int32
    reg [15:0] glogit  [0:OC-1];        // golden 065

    logic clock, rst_n;

    logic                  start, stall;
    logic [PIX_W-1:0]      n_pix;
    logic [OCT_W-1:0]      n_oc;
    logic [ICT_W-1:0]      n_ic;
    logic [AA_W-1:0]       n_ent, base_in;

    logic                  wl_en;
    logic [BANK_W-1:0]     wl_bank;
    logic [WA_W-1:0]       wl_addr;
    logic [TN*DATA_W-1:0]  wl_data;

    wire [TM*ACC_W-1:0]    acc;
    wire                   acc_valid;
    wire [PIX_W-1:0]       acc_pix;
    wire [OCT_W-1:0]       acc_oct;
    wire                   busy, layer_done;

    wire                   a_rd_en;
    wire [AA_W-1:0]        a_addr;
    wire [SEL_W-1:0]       a_sel;
    wire [TN*DATA_W-1:0]   a_word;

    logic                  tb_aw_en;
    logic [AA_W-1:0]       tb_aw_addr;
    logic [TM*DATA_W-1:0]  tb_aw_data;

    pw_feeder #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W), .SEL_W(SEL_W),
                .BANK_W(BANK_W), .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W),
                .WA_W(WA_W), .AA_W(AA_W), .WDEPTH(WDEPTH)) u_feed (
        .clock(clock), .rst_n(rst_n),
        .start(start), .stall(stall),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic), .n_ent(n_ent), .base_in(base_in),
        .wl_en(wl_en), .wl_bank(wl_bank), .wl_addr(wl_addr), .wl_data(wl_data),
        .a_rd_en(a_rd_en), .a_addr(a_addr), .a_sel(a_sel), .a_word(a_word),
        .acc(acc), .acc_valid(acc_valid), .acc_pix(acc_pix), .acc_oct(acc_oct),
        .busy(busy), .layer_done(layer_done)
    );

    act_buffer #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .SEL_W(SEL_W),
                 .DEPTH(ADEPTH), .ADDR_W(AA_W)) u_act (
        .clock(clock),
        .wr_en(tb_aw_en), .wr_full(1'b1), .wr_sel({SEL_W{1'b0}}),
        .wr_addr(tb_aw_addr), .wr_data(tb_aw_data),
        .rd_en(a_rd_en), .rd_addr(a_addr), .rd_sel(a_sel), .rd_data(a_word)
    );

    // ---- the tail: logit_out replaces pw_out for this op ------------------
    logic                    pl_en;
    logic [IDX_W-1:0]        pl_idx;
    logic signed [BIAS_W-1:0] pl_bias;
    logic signed [M0_W-1:0]  pl_m0;
    logic [SHIFT_W-1:0]      pl_shift;

    wire [OC*LOG_W-1:0]      logits;
    wire                     logits_valid;
    wire [IDX_W-1:0]         argmax;
    wire                     argmax_valid;

    logit_out #(.TM(TM), .NLOG(OC), .IDX_W(IDX_W), .ACC_W(ACC_W),
                .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
                .LOG_W(LOG_W)) u_log (
        .clock(clock), .rst_n(rst_n), .start(start),
        .pl_en(pl_en), .pl_idx(pl_idx),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .acc(acc), .acc_valid(acc_valid),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0;

    // ---- capture: every `valid` here is a ONE-CYCLE pulse, so the testbench
    //      has to latch it the way the PS-side register will --------------
    logic signed [ACC_W-1:0]  acc_cap [0:OC-1];
    logic signed [LOG_W-1:0]  log_cap [0:OC-1];
    logic [IDX_W-1:0]         arg_cap;
    integer acc_seen, log_seen, arg_seen;

    always @(negedge clock) begin
        if (acc_valid) begin
            integer c;
            for (c = 0; c < OC; c++) acc_cap[c] = $signed(acc[c*ACC_W +: ACC_W]);
            acc_seen++;
        end
        if (logits_valid) begin
            integer c;
            for (c = 0; c < OC; c++) log_cap[c] = $signed(logits[c*LOG_W +: LOG_W]);
            log_seen++;
        end
        if (argmax_valid) begin
            arg_cap = argmax;
            arg_seen++;
        end
    end

    integer c, k, it, ocx, icx, best;
    logic signed [15:0] got16, exp16;
    initial begin
        $readmemh("../../software/golden/image_1/063_avgpool.hex",                  in_mem);
        $readmemh("../../software/export/classifier_1_w.hex",                       wq_mem);
        $readmemh("../../software/export/classifier_1_b.hex",                       b_mem);
        $readmemh("../../software/export/classifier_1_m0.hex",                      m0_mem);
        $readmemh("../../software/export/classifier_1_shift.hex",                   sh_mem);
        $readmemh("../../software/golden/image_1/064_classifier_1_acc_int32.hex",   gacc);
        $readmemh("../../software/golden/image_1/065_classifier_1_logits_int16.hex", glogit);

        start = 0; stall = 0; acc_seen = 0; log_seen = 0; arg_seen = 0;
        wl_en = 0; wl_bank = 0; wl_addr = 0; wl_data = 0;
        tb_aw_en = 0; tb_aw_addr = 0; tb_aw_data = 0;
        pl_en = 0; pl_idx = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        n_pix = 0; n_oc = 0; n_ic = 0; n_ent = 0; base_in = 0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: classifier.1 - the accelerator's answer");
        $display("  1x1x%0d -> %0d int16 logits -> one class", IC, OC);
        $display("  pw_feeder runs it as a 1x1 conv: n_pix=1, n_oc=%0d, n_ic=%0d",
                 N_OC, N_IC);
        $display("  logit_out replaces pw_out: clamp_i16 instead of clamp_i8");
        $display("");

        // ---- load the pooled vector as 40 entries of 32 channels ---------
        for (k = 0; k < N_ENT; k++) begin
            @(negedge clock);
            for (c = 0; c < TM; c++)
                tb_aw_data[c*DATA_W +: DATA_W] =
                    ((k*TM + c) < IC) ? in_mem[k*TM + c] : 8'h00;
            tb_aw_addr = BASE_I + k;
            tb_aw_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            tb_aw_en = 1'b0;
        end

        // ---- weights: bank = lane, address = ic_tile; zero past OC -------
        for (it = 0; it < N_IC; it++)
            for (k = 0; k < TM; k++) begin
                @(negedge clock);
                ocx = k;
                for (c = 0; c < TN; c++) begin
                    icx = it*TN + c;
                    wl_data[c*DATA_W +: DATA_W] =
                        (ocx < OC && icx < IC) ? wq_mem[ocx*IC + icx] : 8'h00;
                end
                wl_bank = k[BANK_W-1:0];
                wl_addr = it[WA_W-1:0];
                wl_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                wl_en = 1'b0;
            end

        // ---- the four classes' parameters --------------------------------
        for (c = 0; c < OC; c++) begin
            @(negedge clock);
            pl_idx   = c[IDX_W-1:0];
            pl_bias  = b_mem[c];
            pl_m0    = m0_mem[c];
            pl_shift = sh_mem[c][SHIFT_W-1:0];
            pl_en    = 1'b1;
            @(posedge clock);
            @(negedge clock);
            pl_en = 1'b0;
        end
        $display("loaded: 1280-channel input, %0d weights, %0d class parameters",
                 OC*IC, OC);

        // ---- run ---------------------------------------------------------
        @(negedge clock);
        n_pix   = NPIX[PIX_W-1:0];
        n_oc    = N_OC[OCT_W-1:0];
        n_ic    = N_IC[ICT_W-1:0];
        n_ent   = N_ENT[AA_W-1:0];
        base_in = BASE_I[AA_W-1:0];
        start   = 1'b1;
        @(negedge clock);
        start = 1'b0;

        wait (!busy);
        repeat (8) @(negedge clock);

        // ---- 1. the accumulators, against the post-bias int32 golden ------
        $display("");
        $display("accumulators (the network's longest dot product, IC=%0d):", IC);
        for (c = 0; c < OC; c++) begin
            // the golden is POST bias; the array produces the raw dot product
            automatic longint want = $signed(gacc[c]);
            automatic longint have = acc_cap[c] + $signed(b_mem[c]);
            if (have !== want) begin
                fails++;
                $display("  [ERR] class %0d: acc+bias = %0d, golden %0d", c, have, want);
            end else
                $display("  [ok ] class %0d: acc+bias = %0d", c, have);
        end
        begin
            automatic longint mx = 0;
            for (c = 0; c < OC; c++) begin
                automatic longint v = acc_cap[c] + $signed(b_mem[c]);
                if (v < 0) v = -v;
                if (v > mx) mx = v;
            end
            $display("  max |acc+bias| = %0d against the %0d-bit limit %0d  (%0d%% of range)",
                     mx, ACC_W, (1 << (ACC_W-1)) - 1, (100*mx)/((1 << (ACC_W-1)) - 1));
            $display("        this is the TIGHTEST accumulator in the network");
        end

        // ---- 2. the int16 logits -----------------------------------------
        $display("");
        $display("logits (clamp_i16, the new OUT_W path):");
        if (log_seen !== 1) begin
            fails++;
            $display("  [ERR] logits_valid pulsed %0d times, expected 1", log_seen);
        end
        for (c = 0; c < OC; c++) begin
            got16 = log_cap[c];
            exp16 = $signed(glogit[c]);
            if (got16 !== exp16) begin
                fails++;
                $display("  [ERR] class %0d: logit = %0d, golden %0d", c, got16, exp16);
            end else
                $display("  [ok ] class %0d: logit = %0d", c, got16);
        end

        // ---- 3. the answer -----------------------------------------------
        best = 0;
        for (c = 1; c < OC; c++)
            if ($signed(glogit[c]) > $signed(glogit[best])) best = c;
        $display("");
        $display("prediction:");
        if (arg_seen !== 1) begin
            fails++;
            $display("  [ERR] argmax_valid pulsed %0d times, expected 1", arg_seen);
        end else if (arg_cap !== best[IDX_W-1:0]) begin
            fails++;
            $display("  [ERR] argmax = %0d, expected %0d", arg_cap, best);
        end else
            $display("  [ok ] class %0d of {black_rot, esca, healthy, leaf_blight}", arg_cap);

        $display("");
        if (fails == 0) $display("ALL PASS  (accumulators, logits and the class all bit-exact)");
        else            $display("FAILED    (%0d errors)", fails);
        $finish;
    end

endmodule
