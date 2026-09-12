`timescale 1ns / 1ps
//============================================================================
//  dw_datapath_tb.sv  -  INTEGRATION: the whole depthwise path vs the golden
//
//  Build plan #5's goal. The depthwise chain runs as one machine on real data,
//  at the real datapath width, against the software model:
//
//      counters -> act_buffer -> line_buffer -> dw_array
//               -> wgt_buffer + param_buffer -> rq_bank -> act_buffer
//
//  Layer: features.1.conv.0.0  (the depthwise of the first inverted residual)
//     C = 32, 112x112, stride 1, pad 1, activation = RELU6, qmax = 127
//     n_grp = ceil(32/16) = 2   channel groups
//     n_ent = ceil(32/32) = 1   pool entry per pixel
//
//  Deliberately the SAME layer dwconv_layer_tb verified in July by reading nine
//  activations per output element. Here each input pixel is read ONCE and the
//  windows come out of line_buffer, so the two are directly comparable: same
//  input, same golden, 16 channels per cycle instead of one element.
//
//  What this exercises that no unit test could:
//    - the two channel groups landing in the two HALVES of the same pool
//      entries (grp 0 -> channels 0-15, grp 1 -> 16-31, identical addresses,
//      different wr_sel), which is what act_buffer's half write exists for;
//    - real SAME padding on all four borders, from real data;
//    - the group-boundary hazard: weights and parameters are read every cycle
//      by pipelined group index, so the last windows of group 0 must still be
//      requantized with group 0's scales while group 1 is already streaming;
//    - ReLU6 clamping, which the pointwise integration did not cover (that
//      layer is ACT_NONE).
//
//  ACC_W = 21. For depthwise that is provably sufficient for the 9-tap sum
//  (9*128*127 = 146,304, 19 bits), but the int32 BIAS is added on top, so the
//  testbench still measures |acc + bias| independently and fails if it would
//  not fit.
//
//  Run:  bash scripts/run_sim.sh dw_datapath dw_feeder line_buffer dw_array \
//          dwconv3x3 wgt_buffer out_stage param_buffer rq_bank bias_add \
//          requantize act_buffer
//============================================================================
module dw_datapath_tb;

    // ---- layer geometry ----------------------------------------------------
    localparam C    = 32;
    localparam H    = 112;
    localparam W    = 112;
    localparam NPIX = H*W;                  // 12544
    localparam NELEM = C*H*W;               // 401408

    // ---- datapath parameters ----------------------------------------------
    localparam DATA_W  = 8;
    localparam TC      = 16;
    localparam K       = 3;
    localparam NT      = K*K;
    localparam ACC_W   = 21;
    localparam POOL_TM = 32;
    localparam SEL_W   = 1;
    localparam XW      = 8;
    localparam MAX_W   = 112;
    localparam GRPW    = 6;
    localparam AA_W    = 16;
    localparam WA_W    = 6;
    localparam PA_W    = 6;
    localparam BANK_W  = 4;       // weight banks  = clog2(TC)
    localparam PBANK_W = 5;       // shared param banks = clog2(POOL_TM)
    localparam WDEPTH  = 64;
    localparam PDEPTH  = 64;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam ADEPTH  = 32768;

    localparam ACT_RELU6 = 1'b1;
    localparam QMAX      = 8'sd127;

    localparam N_GRP   = (C + TC - 1) / TC;          // 2
    localparam N_ENT   = (C + POOL_TM - 1) / POOL_TM; // 1
    localparam BASE_IN  = 0;
    localparam BASE_OUT = NPIX;

    // ---- data from the software model -------------------------------------
    reg  [7:0]  in_mem   [0:NELEM-1];       // golden 001, NCHW
    reg  [7:0]  gold_mem [0:NELEM-1];       // golden 002, NCHW
    reg  [7:0]  wq_mem   [0:C*NT-1];        // (C,1,K,K) row-major
    reg  [31:0] b_mem    [0:C-1];
    reg  [31:0] m0_mem   [0:C-1];
    reg  [7:0]  sh_mem   [0:C-1];

    logic clock, rst_n;

    // ---- dw_feeder ---------------------------------------------------------
    logic                    start;
    logic [XW-1:0]           img_w, img_h;
    logic                    stride2;
    logic [GRPW-1:0]         n_grp;
    logic [AA_W-1:0]         n_ent, base_in, base_out;
    logic                    act;
    logic signed [7:0]       qmax;

    logic                    wl_en;
    logic [BANK_W-1:0]       wl_bank;
    logic [WA_W-1:0]         wl_addr;
    logic [NT*DATA_W-1:0]    wl_data;

    logic                    pl_en;
    logic [PBANK_W-1:0]      pl_bank;
    logic [PA_W-1:0]         pl_addr;
    logic signed [BIAS_W-1:0] pl_bias;
    logic signed [M0_W-1:0]  pl_m0;
    logic [SHIFT_W-1:0]      pl_shift;

    wire                     a_rd_en;
    wire [AA_W-1:0]          a_addr;
    wire [SEL_W-1:0]         a_sel;
    wire [TC*DATA_W-1:0]     a_word;

    wire                     dw_aw_en, dw_aw_full;
    wire [SEL_W-1:0]         dw_aw_sel;
    wire [AA_W-1:0]          dw_aw_addr;
    wire [POOL_TM*DATA_W-1:0] dw_aw_data;

    wire                     busy, layer_done;

    // ---- the activation pool: loaded by the testbench, then written by the
    //      accelerator, exactly as in the pointwise integration ------------
    logic                     load_mode;
    logic                     tb_aw_en;
    logic [AA_W-1:0]          tb_aw_addr;
    logic [POOL_TM*DATA_W-1:0] tb_aw_data;

    wire                      aw_en    = load_mode ? tb_aw_en    : dw_aw_en;
    wire                      aw_full  = load_mode ? 1'b1        : dw_aw_full;
    wire [SEL_W-1:0]          aw_sel   = load_mode ? {SEL_W{1'b0}} : dw_aw_sel;
    wire [AA_W-1:0]           aw_addr  = load_mode ? tb_aw_addr  : dw_aw_addr;
    wire [POOL_TM*DATA_W-1:0] aw_data  = load_mode ? tb_aw_data  : dw_aw_data;

    dw_feeder #(.DATA_W(DATA_W), .TC(TC), .K(K), .ACC_W(ACC_W),
                .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W),
                .POOL_TM(POOL_TM), .SEL_W(SEL_W), .XW(XW), .MAX_W(MAX_W),
                .GRPW(GRPW), .AA_W(AA_W), .WA_W(WA_W), .PA_W(PA_W),
                .BANK_W(BANK_W), .POOL_BANK_W(PBANK_W),
                .WDEPTH(WDEPTH), .PDEPTH(PDEPTH)) u_dw (
        .clock(clock), .rst_n(rst_n),
        .start(start), .img_w(img_w), .img_h(img_h), .stride2(stride2),
        .n_grp(n_grp), .n_ent(n_ent), .base_in(base_in), .base_out(base_out),
        .act(act), .relu6_qmax(qmax),
        .wl_en(wl_en), .wl_bank(wl_bank), .wl_addr(wl_addr), .wl_data(wl_data),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .a_rd_en(a_rd_en), .a_addr(a_addr), .a_sel(a_sel), .a_word(a_word),
        .aw_en(dw_aw_en), .aw_full(dw_aw_full), .aw_sel(dw_aw_sel),
        .aw_addr(dw_aw_addr), .aw_data(dw_aw_data),
        .busy(busy), .layer_done(layer_done)
    );

    // The read port is muxed too, so that after the run the testbench can read
    // the pool BACK. Checking the write bus alone would miss a storage bug:
    // wr_full only affects what lands in memory, and a full write would clobber
    // the neighbouring group's half without ever showing on the bus.
    logic              tb_rd;
    logic              tb_rd_en;
    logic [AA_W-1:0]   tb_rd_addr;
    logic [SEL_W-1:0]  tb_rd_sel;

    wire               rd_en_mux   = tb_rd ? tb_rd_en   : a_rd_en;
    wire [AA_W-1:0]    rd_addr_mux = tb_rd ? tb_rd_addr : a_addr;
    wire [SEL_W-1:0]   rd_sel_mux  = tb_rd ? tb_rd_sel  : a_sel;

    act_buffer #(.DATA_W(DATA_W), .TM(POOL_TM), .TN(TC), .SEL_W(SEL_W),
                 .DEPTH(ADEPTH), .ADDR_W(AA_W)) u_act (
        .clock(clock),
        .wr_en(aw_en), .wr_full(aw_full), .wr_sel(aw_sel),
        .wr_addr(aw_addr), .wr_data(aw_data),
        .rd_en(rd_en_mux), .rd_addr(rd_addr_mux), .rd_sel(rd_sel_mux),
        .rd_data(a_word)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0, checked = 0, writes = 0;
    integer mon_on;

    // ---- monitor: every write is 16 channels of one output pixel -----------
    task automatic check_write;
        integer p, y, x, m, c;
        logic signed [7:0] got, expd;
        begin
            p = dw_aw_addr - BASE_OUT;
            if (p < 0 || p >= NPIX) begin
                fails++;
                if (fails <= 5)
                    $display("  [ERR] write outside the output tensor: addr=%0d", dw_aw_addr);
            end else begin
                y = p / W;
                x = p % W;
                for (m = 0; m < TC; m++) begin
                    c    = dw_aw_sel*TC + m;
                    // the results now sit in the half of the word that wr_sel
                    // stores, not replicated across it, so index by channel
                    got  = dw_aw_data[c*DATA_W +: DATA_W];
                    expd = gold_mem[(c*H + y)*W + x];
                    checked++;
                    if (got !== expd) begin
                        fails++;
                        if (fails <= 10)
                            $display("  [ERR] pix(%0d,%0d) ch=%0d : got %0d, golden %0d",
                                     y, x, c, got, $signed(expd));
                    end
                end
            end
            writes++;
            if (writes % 4096 == 0)
                $display("  ... %0d/%0d half-entry writes (%0d fails)",
                         writes, N_GRP*NPIX, fails);
        end
    endtask

    always @(negedge clock)
        if (mon_on && dw_aw_en) check_write;

    // ---- load the activation pool, NCHW -> 32-channel entries --------------
    task automatic load_activations;
        integer p, y, x, k;
        begin
            load_mode = 1'b1;
            for (p = 0; p < NPIX; p++) begin
                y = p / W;
                x = p % W;
                @(negedge clock);
                for (k = 0; k < POOL_TM; k++)
                    tb_aw_data[k*DATA_W +: DATA_W] =
                        (k < C) ? in_mem[(k*H + y)*W + x] : 8'h00;
                tb_aw_addr = BASE_IN + p*N_ENT;
                tb_aw_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                tb_aw_en = 1'b0;
                if ((p + 1) % 4096 == 0)
                    $display("  ... %0d/%0d input pixels loaded", p+1, NPIX);
            end
            load_mode = 1'b0;
        end
    endtask

    // ---- load the depthwise weights: bank = channel within group ----------
    task automatic load_weights;
        integer g, m, i, ch;
        begin
            for (g = 0; g < N_GRP; g++)
                for (m = 0; m < TC; m++) begin
                    @(negedge clock);
                    ch = g*TC + m;
                    for (i = 0; i < NT; i++)
                        wl_data[i*DATA_W +: DATA_W] =
                            (ch < C) ? wq_mem[ch*NT + i] : 8'h00;
                    wl_bank = m[BANK_W-1:0];
                    wl_addr = g[WA_W-1:0];
                    wl_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    wl_en = 1'b0;
                end
        end
    endtask

    task automatic load_params;
        integer g, m, ch;
        begin
            for (g = 0; g < N_GRP; g++)
                for (m = 0; m < TC; m++) begin
                    @(negedge clock);
                    // the shared parameter buffer has POOL_TM banks and one
                    // entry per 32 channels, so channel ch lives in bank
                    // ch%POOL_TM at address ch/POOL_TM
                    ch       = g*TC + m;
                    pl_bank  = (ch % POOL_TM);
                    pl_addr  = (ch / POOL_TM);
                    pl_bias  = (ch < C) ? b_mem[ch]  : 32'sd0;
                    pl_m0    = (ch < C) ? m0_mem[ch] : 32'sd0;
                    pl_shift = (ch < C) ? sh_mem[ch][SHIFT_W-1:0] : {SHIFT_W{1'b0}};
                    pl_en    = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    pl_en = 1'b0;
                end
        end
    endtask

    // ---- independent check that ACC_W=21 holds once bias is added ---------
    task automatic measure_accumulator_range;
        integer p, y, x, ch, ky, kx, iy, ix, stride, n;
        longint accv, biased, max_acc, max_biased, lim;
        begin
            stride = 16;
            max_acc = 0; max_biased = 0; n = 0;
            for (p = 0; p < NPIX; p += stride) begin
                y = p / W;
                x = p % W;
                for (ch = 0; ch < C; ch++) begin
                    accv = 0;
                    for (ky = 0; ky < K; ky++)
                        for (kx = 0; kx < K; kx++) begin
                            iy = y - 1 + ky;
                            ix = x - 1 + kx;
                            if (iy >= 0 && iy < H && ix >= 0 && ix < W)
                                accv += longint'($signed(in_mem[(ch*H + iy)*W + ix])) *
                                        longint'($signed(wq_mem[ch*NT + ky*K + kx]));
                        end
                    biased = accv + longint'($signed(b_mem[ch]));
                    if (accv   < 0) begin if (-accv   > max_acc)    max_acc    = -accv;   end
                    else            begin if ( accv   > max_acc)    max_acc    =  accv;   end
                    if (biased < 0) begin if (-biased > max_biased) max_biased = -biased; end
                    else            begin if ( biased > max_biased) max_biased =  biased; end
                    n++;
                end
            end
            lim = (longint'(1) << (ACC_W-1)) - 1;
            $display("");
            $display("accumulator range over %0d sampled elements:", n);
            $display("  max |acc|        = %0d   (9-tap bound is 146,304)", max_acc);
            $display("  max |acc + bias| = %0d", max_biased);
            $display("  ACC_W=%0d holds    +-%0d", ACC_W, lim+1);
            if (max_biased > lim) begin
                fails++;
                $display("  [ERR] the 21-bit accumulator would OVERFLOW on this layer");
            end else
                $display("  [ok ] fits, with %0d bits of headroom to spare",
                         ACC_W - 1 - $clog2(max_biased + 1));
        end
    endtask

    initial begin
        $readmemh("../../software/golden/image_1/001_features_0_0.hex",         in_mem);
        $readmemh("../../software/golden/image_1/002_features_1_conv_0_0.hex",  gold_mem);
        $readmemh("../../software/export/features_1_conv_0_0_w.hex",            wq_mem);
        $readmemh("../../software/export/features_1_conv_0_0_b.hex",            b_mem);
        $readmemh("../../software/export/features_1_conv_0_0_m0.hex",           m0_mem);
        $readmemh("../../software/export/features_1_conv_0_0_shift.hex",        sh_mem);

        start = 0; load_mode = 0; mon_on = 0;
        tb_rd = 0; tb_rd_en = 0; tb_rd_addr = 0; tb_rd_sel = 0;
        wl_en = 0; wl_bank = 0; wl_addr = 0; wl_data = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        tb_aw_en = 0; tb_aw_addr = 0; tb_aw_data = 0;
        img_w = 0; img_h = 0; stride2 = 0; n_grp = 0; n_ent = 0;
        base_in = 0; base_out = 0; act = ACT_RELU6; qmax = QMAX;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: features.1.conv.0.0 through the depthwise datapath");
        $display("  C=%0d  %0dx%0d stride 1 pad 1  ACT_RELU6 qmax=%0d", C, H, W, QMAX);
        $display("  n_grp=%0d channel groups of %0d, n_ent=%0d pool entry per pixel",
                 N_GRP, TC, N_ENT);
        $display("  each pixel read ONCE; windows from line_buffer");

        measure_accumulator_range;

        $display("");
        $display("loading:");
        load_weights;
        load_params;
        $display("  weights and parameters in");
        load_activations;
        $display("  activations in");

        @(negedge clock);
        img_w    = W[XW-1:0];
        img_h    = H[XW-1:0];
        stride2  = 1'b0;
        n_grp    = N_GRP[GRPW-1:0];
        n_ent    = N_ENT[AA_W-1:0];
        base_in  = BASE_IN[AA_W-1:0];
        base_out = BASE_OUT[AA_W-1:0];
        mon_on   = 1;
        start    = 1'b1;
        @(negedge clock);
        start = 1'b0;

        $display("");
        $display("running %0d groups x %0dx%0d extended grid = %0d cycles:",
                 N_GRP, H+1, W+1, N_GRP*(H+1)*(W+1));

        wait (!busy);
        repeat (8) @(negedge clock);
        mon_on = 0;

        // ---- read the pool back: what was STORED, not just what was sent ---
        //  Both halves of the same entry must survive, because the two channel
        //  groups write the same addresses with different wr_sel. A full write
        //  would pass every check above and still destroy half the tensor.
        $display("");
        $display("reading the pool back (both halves of sampled entries):");
        tb_rd = 1'b1;
        begin : readback
            integer p, y, x, g, m, c, bad;
            logic signed [7:0] got, expd;
            bad = 0;
            for (p = 0; p < NPIX; p = p + 97) begin
                y = p / W;
                x = p % W;
                for (g = 0; g < N_GRP; g++) begin
                    @(negedge clock);
                    tb_rd_addr = BASE_OUT + p*N_ENT;
                    tb_rd_sel  = g[SEL_W-1:0];
                    tb_rd_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    tb_rd_en = 1'b0;
                    for (m = 0; m < TC; m++) begin
                        c    = g*TC + m;
                        got  = a_word[m*DATA_W +: DATA_W];
                        expd = gold_mem[(c*H + y)*W + x];
                        checked++;
                        if (got !== expd) begin
                            bad++;
                            if (bad <= 6)
                                $display("  [ERR] stored pix(%0d,%0d) ch=%0d : got %0d, golden %0d",
                                         y, x, c, got, $signed(expd));
                        end
                    end
                end
            end
            if (bad != 0) begin
                fails++;
                $display("  [ERR] %0d stored bytes wrong", bad);
            end else
                $display("  [ok ] every sampled entry holds BOTH groups intact");
        end
        tb_rd = 1'b0;

        $display("");
        if (writes !== N_GRP*NPIX) begin
            fails++;
            $display("  [ERR] %0d half-entry writes, expected %0d",
                     writes, N_GRP*NPIX);
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model)", checked);
        else
            $display("FAILED    (%0d errors, %0d elements checked)", fails, checked);
        $finish;
    end

endmodule
