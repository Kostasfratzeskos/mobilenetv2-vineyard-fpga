`timescale 1ns / 1ps
//============================================================================
//  stem_datapath_tb.sv  -  INTEGRATION: the stem vs the golden
//
//  The last opcode, and the hardest one. Layer features.0.0:
//     224x224x3 -> 112x112x32, 3x3 stride 2 pad 1, ACT_RELU6 qmax=127
//     input  = golden 000_input           (the quantized image, NCHW)
//     output = golden 001_features_0_0     (32x112x112, NCHW)
//
//  The same layer stem_layer_tb verified in July one output element at a time,
//  reading 27 activations for each. Here each input pixel is read ONCE, the
//  windows come from line_buffer, and 8 output channels are computed per cycle.
//
//  Four things happen here that nowhere else does:
//    - the image lives in its OWN region, not the activation pool, because 3
//      channels in a 32-channel entry would waste 91% of 1.53 MB;
//    - the input stream STALLS while each window is swept, because windows
//      arrive every 2 cycles inside an odd row but need 4 cycles of compute;
//    - four quarters of 8 channels are assembled into one 32-channel entry, so
//      act_buffer never needs a quarter write; and
//    - stride 2 with SAME padding on a 224x224 grid, which is the only place
//      the line buffer's virtual row and column meet a real image border.
//
//  Run:  bash scripts/run_sim.sh stem_datapath stem_feeder img_buffer \
//          line_buffer stem_array conv3x3_std wgt_buffer out_stage \
//          param_buffer rq_bank bias_add requantize act_buffer
//============================================================================
module stem_datapath_tb;

    // ---- layer ------------------------------------------------------------
    localparam CIN  = 3;
    localparam OC   = 32;
    localparam K    = 3;
    localparam NT   = CIN*K*K;              // 27
    localparam IH   = 224, IW = 224;
    localparam OH   = 112, OW = 112;
    localparam NIN  = CIN*IH*IW;            // 150528
    localparam NOUT = OC*OH*OW;             // 401408
    localparam QMAX = 8'sd127;

    // ---- datapath ---------------------------------------------------------
    localparam DATA_W  = 8;
    localparam TS      = 8;
    localparam ACC_W   = 21;
    localparam POOL_TM = 32;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam XW      = 9;
    localparam MAX_W   = 224;
    localparam OCTW    = 4;
    localparam IA_W    = 16;
    localparam AA_W    = 16;
    localparam WA_W    = 4;
    localparam PA_W    = 6;
    localparam BANK_W  = 3;
    localparam PBANK_W = 5;
    localparam WDEPTH  = 8;
    localparam PDEPTH  = 64;
    localparam SEL_W   = 1;
    localparam TN      = 16;
    localparam ADEPTH  = 16384;

    localparam N_OCT   = (OC + TS - 1) / TS;   // 4
    localparam BASE_O  = 0;

    // ---- golden ----------------------------------------------------------
    reg [7:0]  img_mem  [0:NIN-1];      // golden 000, NCHW (3,224,224)
    reg [7:0]  gold_mem [0:NOUT-1];     // golden 001, NCHW (32,112,112)
    reg [7:0]  wq_mem   [0:OC*NT-1];    // (OC, CIN, K, K) row-major
    reg [31:0] b_mem    [0:OC-1];
    reg [31:0] m0_mem   [0:OC-1];
    reg [7:0]  sh_mem   [0:OC-1];

    logic clock, rst_n;

    logic                    start;
    logic [XW-1:0]           img_w, img_h;
    logic [OCTW-1:0]         n_oct;
    logic [AA_W-1:0]         base_out;
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

    wire                     im_rd_en;
    wire [IA_W-1:0]          im_addr;
    wire [CIN*DATA_W-1:0]    im_data;

    wire                     st_aw_en, st_aw_full;
    wire [AA_W-1:0]          st_aw_addr;
    wire [POOL_TM*DATA_W-1:0] st_aw_data;
    wire                     busy, layer_done;

    stem_feeder #(.DATA_W(DATA_W), .TS(TS), .CIN(CIN), .K(K), .ACC_W(ACC_W),
                  .POOL_TM(POOL_TM), .BIAS_W(BIAS_W), .M0_W(M0_W),
                  .SHIFT_W(SHIFT_W), .XW(XW), .MAX_W(MAX_W), .OCTW(OCTW),
                  .IA_W(IA_W), .AA_W(AA_W), .WA_W(WA_W), .PA_W(PA_W),
                  .BANK_W(BANK_W), .PBANK_W(PBANK_W),
                  .WDEPTH(WDEPTH), .PDEPTH(PDEPTH)) u_stem (
        .clock(clock), .rst_n(rst_n),
        .start(start), .img_w(img_w), .img_h(img_h), .n_oct(n_oct),
        .base_out(base_out), .relu6_qmax(qmax),
        .wl_en(wl_en), .wl_bank(wl_bank), .wl_addr(wl_addr), .wl_data(wl_data),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .im_rd_en(im_rd_en), .im_addr(im_addr), .im_data(im_data),
        .aw_en(st_aw_en), .aw_full(st_aw_full),
        .aw_addr(st_aw_addr), .aw_data(st_aw_data),
        .busy(busy), .layer_done(layer_done)
    );

    // ---- the image region -------------------------------------------------
    logic                  iw_en;
    logic [IA_W-1:0]       iw_addr;
    logic [CIN*DATA_W-1:0] iw_data;

    img_buffer #(.DATA_W(DATA_W), .CIN(CIN), .DEPTH(IH*IW), .ADDR_W(IA_W)) u_img (
        .clock(clock),
        .wr_en(iw_en), .wr_addr(iw_addr), .wr_data(iw_data),
        .rd_en(im_rd_en), .rd_addr(im_addr), .rd_data(im_data)
    );

    // ---- the activation pool, written by the stem -------------------------
    logic             tb_rd;
    logic             tb_rd_en;
    logic [AA_W-1:0]  tb_rd_addr;
    logic [SEL_W-1:0] tb_rd_sel;
    wire  [TN*DATA_W-1:0] pool_word;

    act_buffer #(.DATA_W(DATA_W), .TM(POOL_TM), .TN(TN), .SEL_W(SEL_W),
                 .DEPTH(ADEPTH), .ADDR_W(AA_W)) u_act (
        .clock(clock),
        .wr_en(st_aw_en), .wr_full(st_aw_full), .wr_sel({SEL_W{1'b0}}),
        .wr_addr(st_aw_addr), .wr_data(st_aw_data),
        .rd_en(tb_rd_en), .rd_addr(tb_rd_addr), .rd_sel(tb_rd_sel),
        .rd_data(pool_word)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0, checked = 0, writes = 0, mon_on;

    // ---- monitor: every write is one output pixel, all 32 channels --------
    task automatic check_write;
        integer p, y, x, m;
        logic signed [7:0] got, expd;
        begin
            p = st_aw_addr - BASE_O;
            if (p < 0 || p >= OH*OW) begin
                fails++;
                if (fails <= 5)
                    $display("  [ERR] write outside the output tensor: addr=%0d", st_aw_addr);
            end else begin
                y = p / OW;
                x = p % OW;
                for (m = 0; m < OC; m++) begin
                    got  = st_aw_data[m*DATA_W +: DATA_W];
                    expd = gold_mem[(m*OH + y)*OW + x];
                    checked++;
                    if (got !== expd) begin
                        fails++;
                        if (fails <= 10)
                            $display("  [ERR] pix(%0d,%0d) ch=%0d : got %0d, golden %0d",
                                     y, x, m, got, $signed(expd));
                    end
                end
            end
            writes++;
            if (writes % 2048 == 0)
                $display("  ... %0d/%0d output pixels (%0d fails)", writes, OH*OW, fails);
        end
    endtask

    always @(negedge clock)
        if (mon_on && st_aw_en) check_write;

    // ---- load the image, NCHW -> one entry of 3 bytes per pixel -----------
    task automatic load_image;
        integer y, x, c;
        begin
            for (y = 0; y < IH; y++) begin
                for (x = 0; x < IW; x++) begin
                    @(negedge clock);
                    for (c = 0; c < CIN; c++)
                        iw_data[c*DATA_W +: DATA_W] = img_mem[(c*IH + y)*IW + x];
                    iw_addr = y*IW + x;
                    iw_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    iw_en = 1'b0;
                end
                if ((y + 1) % 64 == 0) $display("  ... %0d/%0d image rows loaded", y+1, IH);
            end
        end
    endtask

    // ---- weights: bank = lane within the tile, address = oc_tile ---------
    task automatic load_weights;
        integer ot, m, i, ocx;
        begin
            for (ot = 0; ot < N_OCT; ot++)
                for (m = 0; m < TS; m++) begin
                    @(negedge clock);
                    ocx = ot*TS + m;
                    for (i = 0; i < NT; i++)
                        wl_data[i*DATA_W +: DATA_W] =
                            (ocx < OC) ? wq_mem[ocx*NT + i] : 8'h00;
                    wl_bank = m[BANK_W-1:0];
                    wl_addr = ot[WA_W-1:0];
                    wl_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    wl_en = 1'b0;
                end
        end
    endtask

    // ---- the 32 channels' parameters, all in entry 0 ---------------------
    task automatic load_params;
        integer c;
        begin
            for (c = 0; c < POOL_TM; c++) begin
                @(negedge clock);
                pl_bank  = c[PBANK_W-1:0];
                pl_addr  = {PA_W{1'b0}};
                pl_bias  = (c < OC) ? b_mem[c]  : 32'sd0;
                pl_m0    = (c < OC) ? m0_mem[c] : 32'sd0;
                pl_shift = (c < OC) ? sh_mem[c][SHIFT_W-1:0] : {SHIFT_W{1'b0}};
                pl_en    = 1'b1;
                @(posedge clock);
                @(negedge clock);
                pl_en = 1'b0;
            end
        end
    endtask

    // ---- independent check that ACC_W=21 holds ---------------------------
    task automatic measure_accumulator;
        integer p, oy, ox, oc, c, ky, kx, iy, ix, stride, n;
        longint accv, biased, mx, lim;
        begin
            stride = 64;
            mx = 0; n = 0;
            for (p = 0; p < OH*OW; p = p + stride) begin
                oy = p / OW;
                ox = p % OW;
                for (oc = 0; oc < OC; oc++) begin
                    accv = 0;
                    for (c = 0; c < CIN; c++)
                        for (ky = 0; ky < K; ky++)
                            for (kx = 0; kx < K; kx++) begin
                                iy = oy*2 - 1 + ky;
                                ix = ox*2 - 1 + kx;
                                if (iy >= 0 && iy < IH && ix >= 0 && ix < IW)
                                    accv += longint'($signed(img_mem[(c*IH + iy)*IW + ix])) *
                                            longint'($signed(wq_mem[oc*NT + (c*K + ky)*K + kx]));
                            end
                    biased = accv + longint'($signed(b_mem[oc]));
                    if (biased < 0) biased = -biased;
                    if (biased > mx) mx = biased;
                    n++;
                end
            end
            lim = (longint'(1) << (ACC_W-1)) - 1;
            $display("");
            $display("accumulator range over %0d sampled elements:", n);
            $display("  max |acc + bias| = %0d   (27-tap bound is %0d)", mx, NT*128*127);
            $display("  ACC_W=%0d holds    +-%0d", ACC_W, lim+1);
            if (mx > lim) begin
                fails++;
                $display("  [ERR] the 21-bit accumulator would OVERFLOW");
            end else
                $display("  [ok ] fits, with %0d bits to spare", ACC_W - 1 - $clog2(mx + 1));
        end
    endtask

    integer p, y, x, m, bad;
    logic signed [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/000_input.hex",         img_mem);
        $readmemh("../../software/golden/image_1/001_features_0_0.hex",  gold_mem);
        $readmemh("../../software/export/features_0_0_w.hex",            wq_mem);
        $readmemh("../../software/export/features_0_0_b.hex",            b_mem);
        $readmemh("../../software/export/features_0_0_m0.hex",           m0_mem);
        $readmemh("../../software/export/features_0_0_shift.hex",        sh_mem);

        start = 0; mon_on = 0; tb_rd = 0;
        wl_en = 0; wl_bank = 0; wl_addr = 0; wl_data = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        iw_en = 0; iw_addr = 0; iw_data = 0;
        tb_rd_en = 0; tb_rd_addr = 0; tb_rd_sel = 0;
        img_w = 0; img_h = 0; n_oct = 0; base_out = 0; qmax = QMAX;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: features.0.0 - the stem");
        $display("  %0dx%0dx%0d -> %0dx%0dx%0d, stride 2 pad 1, ACT_RELU6 qmax=%0d",
                 IH, IW, CIN, OH, OW, OC, QMAX);
        $display("  each input pixel read ONCE; %0d output channels per cycle", TS);
        $display("  %0d oc_tiles per window, assembled into one 32-channel entry",
                 N_OCT);

        measure_accumulator;

        $display("");
        $display("loading:");
        load_weights;
        load_params;
        $display("  weights and parameters in");
        load_image;
        $display("  image in");

        @(negedge clock);
        img_w    = IW[XW-1:0];
        img_h    = IH[XW-1:0];
        n_oct    = N_OCT[OCTW-1:0];
        base_out = BASE_O[AA_W-1:0];
        mon_on   = 1;
        start    = 1'b1;
        @(negedge clock);
        start = 1'b0;

        $display("");
        $display("running (%0d input cycles + %0d windows x %0d sweep):",
                 (IH+1)*(IW+1), OH*OW, N_OCT);

        wait (!busy);
        repeat (16) @(negedge clock);
        mon_on = 0;

        // ---- read the pool back ------------------------------------------
        $display("");
        $display("reading the pool back:");
        bad = 0;
        for (p = 0; p < OH*OW; p = p + 97) begin
            y = p / OW;
            x = p % OW;
            for (m = 0; m < 2; m++) begin
                @(negedge clock);
                tb_rd_addr = BASE_O + p;
                tb_rd_sel  = m[SEL_W-1:0];
                tb_rd_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                tb_rd_en = 1'b0;
                for (int k = 0; k < TN; k++) begin
                    got  = pool_word[k*DATA_W +: DATA_W];
                    expd = gold_mem[((m*TN + k)*OH + y)*OW + x];
                    checked++;
                    if (got !== expd) begin
                        bad++;
                        if (bad <= 6)
                            $display("  [ERR] stored pix(%0d,%0d) ch=%0d : got %0d, golden %0d",
                                     y, x, m*TN + k, got, $signed(expd));
                    end
                end
            end
        end
        if (bad != 0) begin
            fails++;
            $display("  [ERR] %0d stored bytes wrong", bad);
        end else
            $display("  [ok ] sampled entries read back correctly");

        $display("");
        if (writes !== OH*OW) begin
            fails++;
            $display("  [ERR] %0d output pixels written, expected %0d", writes, OH*OW);
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model)", checked);
        else
            $display("FAILED    (%0d errors, %0d elements checked)", fails, checked);
        $finish;
    end

endmodule
