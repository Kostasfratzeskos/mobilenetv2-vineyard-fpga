`timescale 1ns / 1ps
//============================================================================
//  pw_datapath_tb.sv  -  INTEGRATION: the whole pointwise path vs the golden
//
//  Build plan #4's actual goal. Everything built in the last two sessions runs
//  as one machine, on real data, at the real datapath width, and the output is
//  compared bit-for-bit against the software model:
//
//      addr_gen -> wgt_buffer + act_buffer -> pe_array(32 lanes)
//               -> param_buffer -> rq_bank -> act_buffer
//
//  Layer: features.1.conv.1  (the project 1x1, linear bottleneck)
//     IC = 32, OC = 16, H = W = 112, activation = NONE
//     n_ic = ceil(32/16) = 2     ic_tiles per dot product
//     n_oc = ceil(16/32) = 1     oc_tiles per pixel
//
//  This is deliberately the SAME layer pointwise_layer_tb verified in July at
//  1 MAC/cycle, so the two results are directly comparable: same input, same
//  golden, same arithmetic, 512 MACs per cycle instead of one.
//
//  Why this layer is a good first integration: OC=16 means only HALF the 32
//  lanes carry real channels, so the tail contract is exercised by real data
//  rather than by a synthetic case. Lanes 16-31 get zero weights and must
//  contribute nothing.
//
//  ACC_W = 21 - the real width, not the 32 the unit tests use. Two things
//  follow from that, and both are checked:
//    1. every output element must match the golden bit-exactly, and
//    2. the testbench independently computes the true int64 accumulator over a
//       sample of the layer and reports the largest magnitude seen, so the
//       21-bit precondition stops being an assumption and becomes a measured
//       margin. It FAILS if anything would not fit.
//
//  Layout conversions the testbench performs (the DMA's job in the real
//  system): golden activations are NCHW, so channel c of pixel (y,x) sits at
//  (c*H + y)*W + x, and must be gathered into act_buffer entries of 32
//  contiguous channels per pixel. Weights are (OC,IC) row-major and must be
//  scattered into bank m = lane, address = ic_tile.
//
//  Run:  bash scripts/run_sim.sh pw_datapath pw_feeder pw_out addr_gen \
//          wgt_buffer act_buffer pe_array mac_lane param_buffer rq_bank \
//          bias_add requantize
//============================================================================
module pw_datapath_tb;

    // ---- layer geometry ----------------------------------------------------
    localparam IC   = 32;
    localparam OC   = 16;
    localparam H    = 112;
    localparam W    = 112;
    localparam NPIX = H*W;                  // 12544 - the WHOLE layer

    localparam IN_N   = IC*H*W;             // 401408
    localparam GOLD_N = OC*H*W;             // 200704

    // ---- datapath parameters ----------------------------------------------
    localparam DATA_W  = 8;
    localparam TM      = 32;
    localparam TN      = 16;
    localparam ACC_W   = 21;                // THE REAL WIDTH
    localparam SEL_W   = 1;
    localparam BANK_W  = 5;
    localparam PIX_W   = 16;
    localparam OCT_W   = 8;
    localparam ICT_W   = 8;
    localparam WA_W    = 10;
    localparam AA_W    = 16;
    localparam WDEPTH  = 64;                // this layer needs 2
    localparam ADEPTH  = 32768;             // input 12544 + output 12544
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam PDEPTH  = 64;
    localparam PA_W    = 6;

    localparam ACT_NONE = 1'b0;

    localparam N_IC   = (IC + TN - 1) / TN;     // 2
    localparam N_OC   = (OC + TM - 1) / TM;     // 1
    localparam N_ENT  = (IC + TM - 1) / TM;     // 1 input entry per pixel
    localparam BASE_IN  = 0;
    localparam BASE_OUT = NPIX;                 // right after the input

    // ---- data from the software model -------------------------------------
    reg  [7:0]  in_mem   [0:IN_N-1];        // golden 002, NCHW
    reg  [7:0]  wq_mem   [0:OC*IC-1];       // weights (OC,IC)
    reg  [31:0] b_mem    [0:OC-1];
    reg  [31:0] m0_mem   [0:OC-1];
    reg  [7:0]  sh_mem   [0:OC-1];
    reg  [7:0]  gold_mem [0:GOLD_N-1];      // golden 003, NCHW

    logic clock, rst_n;

    // ---- feeder ------------------------------------------------------------
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

    // ---- activation write port: the testbench loads, then pw_out drives ----
    logic                  load_mode;
    logic                  tb_aw_en;
    logic [AA_W-1:0]       tb_aw_addr;
    logic [TM*DATA_W-1:0]  tb_aw_data;

    wire                   out_aw_en;
    wire [AA_W-1:0]        out_aw_addr;
    wire [TM*DATA_W-1:0]   out_aw_data;

    wire                   aw_en   = load_mode ? tb_aw_en   : out_aw_en;
    wire [AA_W-1:0]        aw_addr = load_mode ? tb_aw_addr : out_aw_addr;
    wire [TM*DATA_W-1:0]   aw_data = load_mode ? tb_aw_data : out_aw_data;

    pw_feeder #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W), .SEL_W(SEL_W),
                .BANK_W(BANK_W), .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W),
                .WA_W(WA_W), .AA_W(AA_W), .WDEPTH(WDEPTH), .ADEPTH(ADEPTH)) u_feed (
        .clock(clock), .rst_n(rst_n),
        .start(start), .stall(stall),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic), .n_ent(n_ent), .base_in(base_in),
        .wl_en(wl_en), .wl_bank(wl_bank), .wl_addr(wl_addr), .wl_data(wl_data),
        .aw_en(aw_en), .aw_addr(aw_addr), .aw_data(aw_data),
        .acc(acc), .acc_valid(acc_valid), .acc_pix(acc_pix), .acc_oct(acc_oct),
        .busy(busy), .layer_done(layer_done)
    );

    // ---- output half -------------------------------------------------------
    logic [AA_W-1:0]         base_out;
    logic                    act;
    logic signed [7:0]       qmax;
    logic                    pl_en;
    logic [BANK_W-1:0]       pl_bank;
    logic [PA_W-1:0]         pl_addr;
    logic signed [BIAS_W-1:0] pl_bias;
    logic signed [M0_W-1:0]  pl_m0;
    logic [SHIFT_W-1:0]      pl_shift;
    wire                     tag_error;

    pw_out #(.TM(TM), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
             .SHIFT_W(SHIFT_W), .DATA_W(DATA_W), .PIX_W(PIX_W), .OCT_W(OCT_W),
             .PDEPTH(PDEPTH), .PA_W(PA_W), .BANK_W(BANK_W), .AA_W(AA_W)) u_out (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_oc(n_oc), .base_out(base_out),
        .act(act), .relu6_qmax(qmax),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .acc(acc), .acc_valid(acc_valid), .acc_pix(acc_pix), .acc_oct(acc_oct),
        .aw_en(out_aw_en), .aw_addr(out_aw_addr), .aw_data(out_aw_data),
        .tag_error(tag_error)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer fails = 0, checked = 0, writes = 0;
    integer mon_on;

    // ---- monitor: every write is one output pixel --------------------------
    task automatic check_write;
        integer p, y, x, m;
        logic signed [7:0] got, expd;
        begin
            p = out_aw_addr - BASE_OUT;
            if (p < 0 || p >= NPIX) begin
                fails++;
                if (fails <= 5)
                    $display("  [ERR] write outside the output tensor: addr=%0d", out_aw_addr);
            end else begin
                y = p / W;
                x = p % W;
                // only the real channels exist in the golden; 16-31 are padding
                for (m = 0; m < OC; m++) begin
                    got  = out_aw_data[m*DATA_W +: DATA_W];
                    expd = gold_mem[(m*H + y)*W + x];
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
                $display("  ... %0d/%0d output pixels written (%0d fails)", writes, NPIX, fails);
        end
    endtask

    always @(negedge clock)
        if (mon_on && out_aw_en) check_write;

    // ---- load the activation pool, NCHW -> 32-channel entries --------------
    task automatic load_activations;
        integer p, y, x, e, k, c;
        begin
            load_mode = 1'b1;
            for (p = 0; p < NPIX; p++) begin
                y = p / W;
                x = p % W;
                for (e = 0; e < N_ENT; e++) begin
                    @(negedge clock);
                    for (k = 0; k < TM; k++) begin
                        c = e*TM + k;
                        tb_aw_data[k*DATA_W +: DATA_W] =
                            (c < IC) ? in_mem[(c*H + y)*W + x] : 8'h00;
                    end
                    tb_aw_addr = BASE_IN + (p*N_ENT + e);
                    tb_aw_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    tb_aw_en = 1'b0;
                end
                if ((p + 1) % 4096 == 0)
                    $display("  ... %0d/%0d input pixels loaded", p+1, NPIX);
            end
            load_mode = 1'b0;
        end
    endtask

    // ---- load the weights, (OC,IC) -> bank = lane, addr = ic_tile ----------
    task automatic load_weights;
        integer ot, it, m, j, ocx, icx;
        begin
            for (ot = 0; ot < N_OC; ot++)
                for (it = 0; it < N_IC; it++)
                    for (m = 0; m < TM; m++) begin
                        @(negedge clock);
                        ocx = ot*TM + m;
                        for (j = 0; j < TN; j++) begin
                            icx = it*TN + j;
                            // the tail contract: zero wherever the channel
                            // does not exist, so padded lanes contribute 0
                            wl_data[j*DATA_W +: DATA_W] =
                                (ocx < OC && icx < IC) ? wq_mem[ocx*IC + icx] : 8'h00;
                        end
                        wl_bank = m[BANK_W-1:0];
                        wl_addr = (ot*N_IC + it);
                        wl_en   = 1'b1;
                        @(posedge clock);
                        @(negedge clock);
                        wl_en = 1'b0;
                    end
        end
    endtask

    // ---- load the per-channel requantize parameters ------------------------
    task automatic load_params;
        integer ot, m, ocx;
        begin
            for (ot = 0; ot < N_OC; ot++)
                for (m = 0; m < TM; m++) begin
                    @(negedge clock);
                    ocx      = ot*TM + m;
                    pl_bank  = m[BANK_W-1:0];
                    pl_addr  = ot[PA_W-1:0];
                    pl_bias  = (ocx < OC) ? b_mem[ocx]  : 32'sd0;
                    pl_m0    = (ocx < OC) ? m0_mem[ocx] : 32'sd0;
                    pl_shift = (ocx < OC) ? sh_mem[ocx][SHIFT_W-1:0] : {SHIFT_W{1'b0}};
                    pl_en    = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    pl_en = 1'b0;
                end
        end
    endtask

    // ---- independent check that ACC_W=21 is actually enough ---------------
    //  Computes the true int64 dot product over a sample of the layer and
    //  reports the largest magnitude, before and after bias. This turns the
    //  21-bit precondition into a measured margin instead of a hope.
    task automatic measure_accumulator_range;
        integer p, y, x, oc, ic, stride, n;
        longint accv, biased, max_acc, max_biased, lim;
        begin
            stride     = 16;                 // every 16th pixel
            max_acc    = 0;
            max_biased = 0;
            n          = 0;
            for (p = 0; p < NPIX; p += stride) begin
                y = p / W;
                x = p % W;
                for (oc = 0; oc < OC; oc++) begin
                    accv = 0;
                    for (ic = 0; ic < IC; ic++)
                        accv += longint'($signed(in_mem[(ic*H + y)*W + x])) *
                                longint'($signed(wq_mem[oc*IC + ic]));
                    biased = accv + longint'($signed(b_mem[oc]));
                    if (accv   < 0) begin if (-accv   > max_acc)    max_acc    = -accv;   end
                    else            begin if ( accv   > max_acc)    max_acc    =  accv;   end
                    if (biased < 0) begin if (-biased > max_biased) max_biased = -biased; end
                    else            begin if ( biased > max_biased) max_biased =  biased; end
                    n++;
                end
            end
            lim = (longint'(1) << (ACC_W-1)) - 1;      // +1048575
            $display("");
            $display("accumulator range over %0d sampled elements (every %0dth pixel):",
                     n, stride);
            $display("  max |acc|        = %0d", max_acc);
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
        $readmemh("../../software/golden/image_1/002_features_1_conv_0_0.hex", in_mem);
        $readmemh("../../software/export/features_1_conv_1_w.hex",             wq_mem);
        $readmemh("../../software/export/features_1_conv_1_b.hex",             b_mem);
        $readmemh("../../software/export/features_1_conv_1_m0.hex",            m0_mem);
        $readmemh("../../software/export/features_1_conv_1_shift.hex",         sh_mem);
        $readmemh("../../software/golden/image_1/003_features_1_conv_1.hex",   gold_mem);

        start = 0; stall = 0; load_mode = 0; mon_on = 0;
        wl_en = 0; wl_bank = 0; wl_addr = 0; wl_data = 0;
        tb_aw_en = 0; tb_aw_addr = 0; tb_aw_data = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        n_pix = 0; n_oc = 0; n_ic = 0; n_ent = 0; base_in = 0; base_out = 0;
        act = ACT_NONE; qmax = 8'sd0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: features.1.conv.1 through the 512-MAC pointwise datapath");
        $display("  IC=%0d OC=%0d  %0dx%0d = %0d pixels  (the whole layer)", IC, OC, H, W, NPIX);
        $display("  n_ic=%0d n_oc=%0d  ACC_W=%0d (the real width)", N_IC, N_OC, ACC_W);
        $display("  OC=%0d of %0d lanes are real -> lanes %0d-%0d are tail padding",
                 OC, TM, OC, TM-1);
        $display("");

        measure_accumulator_range;

        $display("");
        $display("loading:");
        load_weights;
        load_params;
        $display("  weights and parameters in");
        load_activations;
        $display("  activations in");

        // ---- run ----------------------------------------------------------
        @(negedge clock);
        n_pix    = NPIX[PIX_W-1:0];
        n_oc     = N_OC[OCT_W-1:0];
        n_ic     = N_IC[ICT_W-1:0];
        n_ent    = N_ENT[AA_W-1:0];
        base_in  = BASE_IN[AA_W-1:0];
        base_out = BASE_OUT[AA_W-1:0];
        mon_on   = 1;
        start    = 1'b1;
        @(negedge clock);
        start = 1'b0;

        $display("");
        $display("running %0d pixels x %0d oc_tile x %0d ic_tile = %0d array cycles:",
                 NPIX, N_OC, N_IC, NPIX*N_OC*N_IC);

        wait (!busy);
        repeat (8) @(negedge clock);        // drain the output pipeline
        mon_on = 0;

        // ---- verdict ------------------------------------------------------
        $display("");
        if (writes !== NPIX) begin
            fails++;
            $display("  [ERR] %0d output pixels written, expected %0d", writes, NPIX);
        end
        if (tag_error !== 1'b0) begin
            fails++;
            $display("  [ERR] tag_error raised - the two pipelines drifted");
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model)", checked);
        else
            $display("FAILED    (%0d errors, %0d elements checked)", fails, checked);
        $finish;
    end

endmodule
