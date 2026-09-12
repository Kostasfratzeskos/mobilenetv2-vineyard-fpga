`timescale 1ns / 1ps
//============================================================================
//  res_datapath_tb.sv  -  INTEGRATION: the residual add vs the golden
//
//  Layer: features.3.add   56x56x24, m0 = 1471079665, shift = 31
//     target = features.3.conv.2 output  (golden 009, the main path)
//     saved  = features.2.conv.2 output  (golden 006, the block input)
//     out    = golden 010
//
//  The same layer residual_layer_tb verified in July one element at a time.
//  Here 16 channels go through per slice, the rescale runs on the SHARED
//  out_stage rather than residual_add.v's own multiplier, and the result is
//  written back into the activation pool as a half entry.
//
//  What this exercises beyond the engine test:
//    - two operands from ONE read port, issued back to back, with `target`
//      carried in a delay line to meet its own rescaled `saved`;
//    - the pool read/write half addressing shared with the depthwise path;
//    - C=24, so slice 1 covers channels 16-31 of which only 16-23 are real -
//      the padded lanes compute on whatever the producing layer left there and
//      must not disturb the channels that matter;
//    - a read-back pass, because a write-bus check alone would miss a storage
//      bug (that is how the aw_full mutation slipped through in dw_datapath_tb).
//
//  ACC_W = 21, the real width. The rescale input is a sign-extended int8, so
//  the accumulator cannot overflow here by construction.
//
//  Run:  bash scripts/run_sim.sh res_datapath res_feeder out_stage \
//          param_buffer rq_bank bias_add requantize act_buffer
//============================================================================
module res_datapath_tb;

    // ---- layer ------------------------------------------------------------
    localparam C    = 24;
    localparam H    = 56;
    localparam W    = 56;
    localparam NPIX = H*W;                  // 3136
    localparam NELEM = C*H*W;               // 75264

    localparam M0    = 32'sd1471079665;
    localparam SHIFT = 6'd31;

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
    localparam ADEPTH  = 16384;

    localparam N_SL  = (C + TN - 1) / TN;            // 2
    localparam N_ENT = (C + POOL_TM - 1) / POOL_TM;  // 1
    localparam BASE_T = 0;                           // target
    localparam BASE_S = NPIX*N_ENT;                  // saved
    localparam BASE_O = 2*NPIX*N_ENT;                // out

    // ---- golden ----------------------------------------------------------
    reg [7:0] tgt_mem  [0:NELEM-1];     // golden 009, NCHW
    reg [7:0] sav_mem  [0:NELEM-1];     // golden 006, NCHW
    reg [7:0] gold_mem [0:NELEM-1];     // golden 010, NCHW

    logic clock, rst_n;

    logic                    start;
    logic [PIX_W-1:0]        n_pix;
    logic [SLW-1:0]          n_sl;
    logic [AA_W-1:0]         n_ent, base_in, base_saved, base_out;

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

    wire                     rs_aw_en, rs_aw_full;
    wire [SEL_W-1:0]         rs_aw_sel;
    wire [AA_W-1:0]          rs_aw_addr;
    wire [POOL_TM*DATA_W-1:0] rs_aw_data;

    wire                     busy, layer_done;

    res_feeder #(.DATA_W(DATA_W), .POOL_TM(POOL_TM), .TN(TN), .ACC_W(ACC_W),
                 .BIAS_W(BIAS_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
                 .PA_W(PA_W), .BANK_W(BANK_W), .PDEPTH(PDEPTH), .AA_W(AA_W),
                 .PIX_W(PIX_W), .SLW(SLW)) u_res (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_pix(n_pix), .n_sl(n_sl), .n_ent(n_ent),
        .base_in(base_in), .base_saved(base_saved), .base_out(base_out),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .a_rd_en(a_rd_en), .a_addr(a_addr), .a_sel(a_sel), .a_word(a_word),
        .aw_en(rs_aw_en), .aw_full(rs_aw_full), .aw_sel(rs_aw_sel),
        .aw_addr(rs_aw_addr), .aw_data(rs_aw_data),
        .busy(busy), .layer_done(layer_done)
    );

    // ---- the pool: loaded by the testbench, then written by the feeder ----
    logic                     load_mode, tb_rd;
    logic                     tb_aw_en;
    logic [AA_W-1:0]          tb_aw_addr;
    logic [POOL_TM*DATA_W-1:0] tb_aw_data;
    logic                     tb_rd_en;
    logic [AA_W-1:0]          tb_rd_addr;
    logic [SEL_W-1:0]         tb_rd_sel;

    wire                      aw_en   = load_mode ? tb_aw_en      : rs_aw_en;
    wire                      aw_full = load_mode ? 1'b1          : rs_aw_full;
    wire [SEL_W-1:0]          aw_sel  = load_mode ? {SEL_W{1'b0}} : rs_aw_sel;
    wire [AA_W-1:0]           aw_addr = load_mode ? tb_aw_addr    : rs_aw_addr;
    wire [POOL_TM*DATA_W-1:0] aw_data = load_mode ? tb_aw_data    : rs_aw_data;

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

    // ---- monitor ----------------------------------------------------------
    task automatic check_write;
        integer e, p, y, x, m, c;
        logic signed [7:0] got, expd;
        begin
            e = rs_aw_addr - BASE_O;
            p = e / N_ENT;
            if (p < 0 || p >= NPIX) begin
                fails++;
                if (fails <= 5)
                    $display("  [ERR] write outside the output tensor: addr=%0d", rs_aw_addr);
            end else begin
                y = p / W;
                x = p % W;
                for (m = 0; m < TN; m++) begin
                    c = rs_aw_sel*TN + m;
                    if (c < C) begin              // the rest is tail padding
                        got  = rs_aw_data[c*DATA_W +: DATA_W];
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
            end
            writes++;
            if (writes % 2048 == 0)
                $display("  ... %0d/%0d half-entry writes (%0d fails)",
                         writes, NPIX*N_SL, fails);
        end
    endtask

    always @(negedge clock)
        if (mon_on && rs_aw_en) check_write;

    // ---- load one tensor into the pool, NCHW -> 32-channel entries --------
    task automatic load_tensor(input integer base, input integer which);
        integer p, y, x, k;
        begin
            load_mode = 1'b1;
            for (p = 0; p < NPIX; p++) begin
                y = p / W;
                x = p % W;
                @(negedge clock);
                for (k = 0; k < POOL_TM; k++) begin
                    if (k < C)
                        tb_aw_data[k*DATA_W +: DATA_W] =
                            (which == 0) ? tgt_mem[(k*H + y)*W + x]
                                         : sav_mem[(k*H + y)*W + x];
                    else
                        // padded channels: the producing layer left garbage
                        // here, NOT zero, and it must not matter
                        tb_aw_data[k*DATA_W +: DATA_W] = 8'h5A + k[3:0];
                end
                tb_aw_addr = base + p*N_ENT;
                tb_aw_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                tb_aw_en = 1'b0;
            end
            load_mode = 1'b0;
        end
    endtask

    // ---- the scalar (m0, shift) goes into every parameter bank ------------
    task automatic load_params;
        integer b;
        begin
            for (b = 0; b < POOL_TM; b++) begin
                @(negedge clock);
                pl_bank  = b[BANK_W-1:0];
                pl_addr  = {PA_W{1'b0}};
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

    // ---- does the saturation ever fire on real data? ---------------------
    //  DD-009 records that the C reference TRUNCATES this sum while its comment
    //  says clamp, and claims they agree because real data fits int8. Mutation
    //  testing confirmed the claim the hard way: removing the saturation here
    //  passes the whole layer. So measure it rather than assume - count how many
    //  sums would actually need clamping.
    task automatic measure_saturation;
        integer pp, yy, xx, cc, n, nsat;
        longint prod, rounded, r, sum;
        begin
            n = 0; nsat = 0;
            for (pp = 0; pp < NPIX; pp = pp + 7) begin
                yy = pp / W;
                xx = pp % W;
                for (cc = 0; cc < C; cc++) begin
                    // requantize(saved, m0, shift, ACT_NONE)
                    prod    = longint'($signed(sav_mem[(cc*H + yy)*W + xx])) * longint'(M0);
                    rounded = prod + (longint'(1) << (SHIFT - 1));
                    r       = rounded >>> SHIFT;
                    if (r < -128)     r = -128;
                    else if (r > 127) r = 127;
                    sum = r + longint'($signed(tgt_mem[(cc*H + yy)*W + xx]));
                    n++;
                    if (sum > 127 || sum < -128) nsat++;
                end
            end
            $display("");
            $display("saturation check over %0d sampled elements:", n);
            if (nsat == 0)
                $display("  [ok ] NONE would clamp - DD-009's claim holds on this layer,");
            else
                $display("  [ok ] %0d of %0d would clamp (%0.2f%%)", nsat, n, 100.0*nsat/n);
            if (nsat == 0)
                $display("         so the saturation path is exercised only by residual_add_tb");
        end
    endtask

    integer p, y, x, m, c, bad;
    logic signed [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/009_features_3_conv_2.hex", tgt_mem);
        $readmemh("../../software/golden/image_1/006_features_2_conv_2.hex", sav_mem);
        $readmemh("../../software/golden/image_1/010_features_3_add.hex",    gold_mem);

        start = 0; load_mode = 0; tb_rd = 0; mon_on = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        tb_aw_en = 0; tb_aw_addr = 0; tb_aw_data = 0;
        tb_rd_en = 0; tb_rd_addr = 0; tb_rd_sel = 0;
        n_pix = 0; n_sl = 0; n_ent = 0;
        base_in = 0; base_saved = 0; base_out = 0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: features.3.add through res_feeder");
        $display("  %0dx%0dx%0d = %0d elements, m0=%0d shift=%0d", H, W, C, NELEM, M0, SHIFT);
        $display("  %0d slices of %0d channels, 2 cycles each", NPIX*N_SL, TN);
        $display("  C=%0d so slice 1 holds %0d real channels and %0d of padding",
                 C, C-TN, POOL_TM-C);
        measure_saturation;

        $display("");
        $display("loading:");
        load_params;
        load_tensor(BASE_T, 0);
        load_tensor(BASE_S, 1);
        $display("  target, saved and the scalar rescale in");

        @(negedge clock);
        n_pix      = NPIX[PIX_W-1:0];
        n_sl       = N_SL[SLW-1:0];
        n_ent      = N_ENT[AA_W-1:0];
        base_in    = BASE_T[AA_W-1:0];
        base_saved = BASE_S[AA_W-1:0];
        base_out   = BASE_O[AA_W-1:0];
        mon_on     = 1;
        start      = 1'b1;
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
        for (p = 0; p < NPIX; p = p + 61) begin
            y = p / W;
            x = p % W;
            for (m = 0; m < N_SL; m++) begin
                @(negedge clock);
                tb_rd_addr = BASE_O + p*N_ENT;
                tb_rd_sel  = m[SEL_W-1:0];
                tb_rd_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                tb_rd_en = 1'b0;
                for (c = 0; c < TN; c++)
                    if (m*TN + c < C) begin
                        got  = a_word[c*DATA_W +: DATA_W];
                        expd = gold_mem[((m*TN + c)*H + y)*W + x];
                        checked++;
                        if (got !== expd) begin
                            bad++;
                            if (bad <= 6)
                                $display("  [ERR] stored pix(%0d,%0d) ch=%0d : got %0d, golden %0d",
                                         y, x, m*TN + c, got, $signed(expd));
                        end
                    end
            end
        end
        tb_rd = 1'b0;
        if (bad != 0) begin
            fails++;
            $display("  [ERR] %0d stored bytes wrong", bad);
        end else
            $display("  [ok ] sampled entries read back correctly");

        $display("");
        if (writes !== NPIX*N_SL) begin
            fails++;
            $display("  [ERR] %0d half-entry writes, expected %0d", writes, NPIX*N_SL);
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model)", checked);
        else
            $display("FAILED    (%0d errors, %0d elements checked)", fails, checked);
        $finish;
    end

endmodule
