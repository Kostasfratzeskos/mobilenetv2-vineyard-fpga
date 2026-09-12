`timescale 1ns / 1ps
//============================================================================
//  gap_datapath_tb.sv  -  INTEGRATION: the global average pool vs the golden
//
//  Layer: avgpool (the `gap` op)   7x7x1280 -> 1x1x1280
//     m0 = 1990030058, shift = 36, window = 49
//     input  = golden 062_features_18_0   (7x7x1280, NCHW)
//     output = golden 063_avgpool         (1280 values)
//
//  The same layer avgpool_layer_tb verified in July one channel at a time.
//  Here 16 channels are accumulated in parallel and the tail runs on the
//  SHARED out_stage.
//
//  The point worth checking is DD-010: there is no divider anywhere. The
//  1/(H*W) is folded into the requantize multiplier, so the average has to come
//  out of the same multiply-shift the rescale needs. If the fold were wrong the
//  results would be off by a factor of 49, which is not subtle - but it would
//  also be off by a factor of 49 in the C model, so matching the golden is what
//  confirms the exporter and the hardware agree on it.
//
//  ACC_W = 21 is provably sufficient: 49 * 128 = 6,272 needs 14 bits, and the
//  input is a ReLU6 output so it is non-negative in practice. The testbench
//  measures the largest sum anyway.
//
//  Run:  bash scripts/run_sim.sh gap_datapath gap_feeder avgpool out_stage \
//          param_buffer rq_bank bias_add requantize act_buffer
//============================================================================
module gap_datapath_tb;

    // ---- layer ------------------------------------------------------------
    localparam C    = 1280;
    localparam H    = 7;
    localparam W    = 7;
    localparam NPIX = H*W;                  // 49
    localparam NELEM = C*H*W;               // 62720

    localparam M0    = 32'sd1990030058;
    localparam SHIFT = 6'd36;

    // ---- datapath ---------------------------------------------------------
    localparam DATA_W  = 8;
    localparam POOL_TM = 32;
    localparam TN      = 16;
    localparam ACC_W   = 21;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam SEL_W   = 1;
    localparam PA_W    = 6;
    localparam BANK_W  = 5;
    localparam PDEPTH  = 64;
    localparam AA_W    = 16;
    localparam PIX_W   = 16;
    localparam SLW     = 8;
    localparam ADEPTH  = 4096;

    localparam N_SL  = (C + TN - 1) / TN;            // 80
    localparam N_ENT = (C + POOL_TM - 1) / POOL_TM;  // 40
    localparam BASE_I = 0;
    localparam BASE_O = NPIX*N_ENT;                  // 1960

    // ---- golden ----------------------------------------------------------
    reg [7:0] in_mem   [0:NELEM-1];     // golden 062, NCHW
    reg [7:0] gold_mem [0:C-1];         // golden 063

    logic clock, rst_n;

    logic                    start;
    logic [PIX_W-1:0]        n_pix;
    logic [SLW-1:0]          n_sl;
    logic [AA_W-1:0]         n_ent, base_in, base_out;

    logic                    pl_en;
    logic [BANK_W-1:0]       pl_bank;
    logic [PA_W-1:0]         pl_addr;
    logic signed [BIAS_W-1:0] pl_bias;
    logic signed [M0_W-1:0]  pl_m0;
    logic [SHIFT_W-1:0]      pl_shift;

    wire                     a_rd_en;
    wire [AA_W-1:0]          a_addr;
    wire [SEL_W-1:0]         a_sel;
    wire [TN*DATA_W-1:0]     a_word;

    wire                     gp_aw_en, gp_aw_full;
    wire [SEL_W-1:0]         gp_aw_sel;
    wire [AA_W-1:0]          gp_aw_addr;
    wire [POOL_TM*DATA_W-1:0] gp_aw_data;

    wire                     busy, layer_done;

    gap_feeder #(.DATA_W(DATA_W), .POOL_TM(POOL_TM), .TN(TN), .ACC_W(ACC_W),
                 .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
                 .PA_W(PA_W), .BANK_W(BANK_W), .PDEPTH(PDEPTH), .AA_W(AA_W),
                 .PIX_W(PIX_W), .SLW(SLW)) u_gap (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_pix(n_pix), .n_sl(n_sl), .n_ent(n_ent),
        .base_in(base_in), .base_out(base_out),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .a_rd_en(a_rd_en), .a_addr(a_addr), .a_sel(a_sel), .a_word(a_word),
        .aw_en(gp_aw_en), .aw_full(gp_aw_full), .aw_sel(gp_aw_sel),
        .aw_addr(gp_aw_addr), .aw_data(gp_aw_data),
        .busy(busy), .layer_done(layer_done)
    );

    // ---- the pool ---------------------------------------------------------
    logic                     load_mode, tb_rd;
    logic                     tb_aw_en;
    logic [AA_W-1:0]          tb_aw_addr;
    logic [POOL_TM*DATA_W-1:0] tb_aw_data;
    logic                     tb_rd_en;
    logic [AA_W-1:0]          tb_rd_addr;
    logic [SEL_W-1:0]         tb_rd_sel;

    wire                      aw_en   = load_mode ? tb_aw_en      : gp_aw_en;
    wire                      aw_full = load_mode ? 1'b1          : gp_aw_full;
    wire [SEL_W-1:0]          aw_sel  = load_mode ? {SEL_W{1'b0}} : gp_aw_sel;
    wire [AA_W-1:0]           aw_addr = load_mode ? tb_aw_addr    : gp_aw_addr;
    wire [POOL_TM*DATA_W-1:0] aw_data = load_mode ? tb_aw_data    : gp_aw_data;

    wire                      rd_en_mux   = tb_rd ? tb_rd_en   : a_rd_en;
    wire [AA_W-1:0]           rd_addr_mux = tb_rd ? tb_rd_addr : a_addr;
    wire [SEL_W-1:0]          rd_sel_mux  = tb_rd ? tb_rd_sel  : a_sel;

    act_buffer #(.DATA_W(DATA_W), .TM(POOL_TM), .TN(TN), .SEL_W(SEL_W),
                 .DEPTH(ADEPTH), .ADDR_W(AA_W)) u_act (
        .clock(clock),
        .wr_en(aw_en), .wr_full(aw_full), .wr_sel(aw_sel),
        .wr_addr(aw_addr), .wr_data(aw_data),
        .rd_en(rd_en_mux), .rd_addr(rd_addr_mux), .rd_sel(rd_sel_mux),
        .rd_data(a_word)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0, checked = 0, writes = 0, mon_on;

    // ---- monitor: every write is 16 pooled channels -----------------------
    task automatic check_write;
        integer e, m, c;
        logic signed [7:0] got, expd;
        begin
            e = gp_aw_addr - BASE_O;
            if (e < 0 || e >= N_ENT) begin
                fails++;
                if (fails <= 5)
                    $display("  [ERR] write outside the output tensor: addr=%0d", gp_aw_addr);
            end else begin
                for (m = 0; m < TN; m++) begin
                    c = e*POOL_TM + gp_aw_sel*TN + m;
                    if (c < C) begin
                        got  = gp_aw_data[(gp_aw_sel*TN + m)*DATA_W +: DATA_W];
                        expd = gold_mem[c];
                        checked++;
                        if (got !== expd) begin
                            fails++;
                            if (fails <= 10)
                                $display("  [ERR] ch=%0d : got %0d, golden %0d",
                                         c, got, $signed(expd));
                        end
                    end
                end
            end
            writes++;
        end
    endtask

    always @(negedge clock)
        if (mon_on && gp_aw_en) check_write;

    // ---- load the input feature map --------------------------------------
    task automatic load_input;
        integer p, y, x, e, k, c;
        begin
            load_mode = 1'b1;
            for (p = 0; p < NPIX; p++) begin
                y = p / W;
                x = p % W;
                for (e = 0; e < N_ENT; e++) begin
                    @(negedge clock);
                    for (k = 0; k < POOL_TM; k++) begin
                        c = e*POOL_TM + k;
                        tb_aw_data[k*DATA_W +: DATA_W] =
                            (c < C) ? in_mem[(c*H + y)*W + x] : 8'h00;
                    end
                    tb_aw_addr = BASE_I + p*N_ENT + e;
                    tb_aw_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    tb_aw_en = 1'b0;
                end
            end
            load_mode = 1'b0;
        end
    endtask

    // ---- the scalar (m0, shift) into every bank of every used address ----
    task automatic load_params;
        integer b, a;
        begin
            for (a = 0; a < N_ENT; a++)
                for (b = 0; b < POOL_TM; b++) begin
                    @(negedge clock);
                    pl_bank  = b[BANK_W-1:0];
                    pl_addr  = a[PA_W-1:0];
                    pl_bias  = 32'sd0;
                    pl_m0    = M0;
                    pl_shift = SHIFT;
                    pl_en    = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    pl_en = 1'b0;
                end
        end
    endtask

    // ---- how big does the sum actually get? ------------------------------
    task automatic measure_sums;
        integer c, p, y, x;
        longint s, mx, lim;
        begin
            mx = 0;
            for (c = 0; c < C; c++) begin
                s = 0;
                for (p = 0; p < NPIX; p++) begin
                    y = p / W;
                    x = p % W;
                    s += longint'($signed(in_mem[(c*H + y)*W + x]));
                end
                if (s < 0) s = -s;
                if (s > mx) mx = s;
            end
            lim = (longint'(1) << (ACC_W-1)) - 1;
            $display("");
            $display("pooled sums over all %0d channels:", C);
            $display("  max |sum| = %0d   (bound for %0d taps is %0d)",
                     mx, NPIX, NPIX*128);
            $display("  ACC_W=%0d holds +-%0d", ACC_W, lim+1);
            if (mx > lim) begin
                fails++;
                $display("  [ERR] the accumulator would OVERFLOW");
            end else
                $display("  [ok ] fits, with %0d bits to spare",
                         ACC_W - 1 - $clog2(mx + 1));
        end
    endtask

    integer c, m, k, ch, bad;
    logic signed [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/062_features_18_0.hex", in_mem);
        $readmemh("../../software/golden/image_1/063_avgpool.hex",       gold_mem);

        start = 0; load_mode = 0; tb_rd = 0; mon_on = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        tb_aw_en = 0; tb_aw_addr = 0; tb_aw_data = 0;
        tb_rd_en = 0; tb_rd_addr = 0; tb_rd_sel = 0;
        n_pix = 0; n_sl = 0; n_ent = 0; base_in = 0; base_out = 0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: the global average pool through gap_feeder");
        $display("  %0dx%0dx%0d -> 1x1x%0d,  m0=%0d shift=%0d, window=%0d",
                 H, W, C, C, M0, SHIFT, NPIX);
        $display("  %0d channel slices of %0d, %0d reads each = %0d cycles",
                 N_SL, TN, NPIX, N_SL*NPIX);
        $display("  no divider anywhere: the 1/%0d is folded into m0 (DD-010)", NPIX);

        measure_sums;

        $display("");
        $display("loading:");
        load_params;
        load_input;
        $display("  input and the scalar rescale in");

        @(negedge clock);
        n_pix    = NPIX[PIX_W-1:0];
        n_sl     = N_SL[SLW-1:0];
        n_ent    = N_ENT[AA_W-1:0];
        base_in  = BASE_I[AA_W-1:0];
        base_out = BASE_O[AA_W-1:0];
        mon_on   = 1;
        start    = 1'b1;
        @(negedge clock);
        start = 1'b0;

        $display("");
        $display("running:");
        wait (!busy);
        repeat (8) @(negedge clock);
        mon_on = 0;

        // ---- read the pool back ------------------------------------------
        $display("");
        $display("reading the pool back:");
        tb_rd = 1'b1;
        bad = 0;
        for (c = 0; c < N_ENT; c++)
            for (m = 0; m < 2; m++) begin
                @(negedge clock);
                tb_rd_addr = BASE_O + c;
                tb_rd_sel  = m[SEL_W-1:0];
                tb_rd_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                tb_rd_en = 1'b0;
                for (k = 0; k < TN; k++) begin
                    ch = c*POOL_TM + m*TN + k;
                    if (ch < C) begin
                        got  = a_word[k*DATA_W +: DATA_W];
                        expd = gold_mem[ch];
                        checked++;
                        if (got !== expd) begin
                            bad++;
                            if (bad <= 8)
                                $display("  [ERR] stored ch=%0d : got %0d, golden %0d",
                                         ch, got, $signed(expd));
                        end
                    end
                end
            end
        tb_rd = 1'b0;
        if (bad != 0) begin
            fails++;
            $display("  [ERR] %0d stored channels wrong", bad);
        end else
            $display("  [ok ] all %0d pooled channels read back correctly", C);

        $display("");
        if (writes !== N_SL) begin
            fails++;
            $display("  [ERR] %0d half-entry writes, expected %0d", writes, N_SL);
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model)", checked);
        else
            $display("FAILED    (%0d errors, %0d elements checked)", fails, checked);
        $finish;
    end

endmodule
