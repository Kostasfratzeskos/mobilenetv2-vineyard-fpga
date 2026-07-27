`timescale 1ns / 1ps
//============================================================================
//  dwconv_layer_tb.sv  -  INTEGRATION test: dwconv3x3 -> bias_add -> requantize
//
//  Reproduces one real depthwise layer of the network, bit-exact vs the golden.
//  This is the first TB that generates the sliding 3x3 window and the border
//  ZERO-PADDING itself (the feeder's job) -- a step toward the controller.
//
//  Layer: features.1.conv.0.0  (depthwise 3x3)
//     C = 32 (groups = 32), H = W = 112, K = 3, stride 1, pad 1 (SAME)
//     activation = RELU6, relu6_qmax = 127
//     m0 / shift : per channel
//
//  Weights (C,1,K,K) row-major: w[c*K*K + ky*K + kx].
//  Activations NCHW: channel c of pixel (y,x) at (c*H + y)*W + x.
//  Window: input coord for tap (ky,kx) is iy=oy-P+ky, ix=ox-P+kx; out-of-image
//  taps contribute 0 (zero padding), matching the C `continue`.
//
//  Coverage: top two rows, an interior row, and the bottom two rows -- so every
//  border and corner (where padding kicks in) is exercised, across all C.
//
//  Run:  bash scripts/run_sim.sh dwconv_layer dwconv3x3 bias_add requantize
//============================================================================
module dwconv_layer_tb;

    // ---- layer geometry ----------------------------------------------------
    localparam C  = 32;
    localparam H  = 112;
    localparam W  = 112;
    localparam K  = 3;
    localparam P  = 1;                 // padding
    localparam S  = 1;                 // stride
    localparam NT = K*K;               // 9 taps

    localparam ACT_RELU6 = 1'b1;
    localparam RELU6_QMAX = 8'sd127;

    localparam ACT_N  = C*H*W;         // 401408 (in and golden)
    localparam W_N    = C*K*K;         // 288

    // ---- data memories -----------------------------------------------------
    reg  [7:0]  in_mem   [0:ACT_N-1];
    reg  [7:0]  w_mem    [0:W_N-1];
    reg  [31:0] b_mem    [0:C-1];
    reg  [31:0] m0_mem   [0:C-1];
    reg  [7:0]  sh_mem   [0:C-1];
    reg  [7:0]  gold_mem [0:ACT_N-1];

    // ---- DUT I/O -----------------------------------------------------------
    logic                clock, rst_n;
    // dwconv3x3 (combinational)
    logic [NT*8-1:0]     win_v, wk_v;
    wire  signed [20:0]  acc_w;
    // bias_add (combinational)
    logic signed [31:0]  bias_r;
    wire  signed [20:0]  biased_w;
    // requantize (registered)
    logic                rq_en, act_r;
    logic signed [31:0]  m0_r;
    logic        [7:0]   sh_r;
    logic signed [7:0]   qmax_r;
    wire  signed [7:0]   q_w;

    dwconv3x3 #(.DATA_W(8), .K(K), .ACC_W(21)) u_dw (
        .win(win_v), .wk(wk_v), .acc(acc_w)
    );

    bias_add #(.ACC_W(21), .BIAS_W(32)) u_bias (
        .acc_in(acc_w), .bias(bias_r), .acc_out(biased_w)
    );

    requantize #(.ACC_W(21), .M0_W(32), .SHIFT_W(6)) u_rq (
        .clock(clock), .rst_n(rst_n), .en(rq_en),
        .act(act_r), .in_data(biased_w), .M0(m0_r),
        .shift(sh_r[5:0]), .relu6_qmax(qmax_r), .quantized(q_w)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0;
    integer fails = 0;

    // one output element: build the padded 3x3 window for channel c at (oy,ox),
    // run it through dwconv -> bias -> requantize, return the int8 result.
    task automatic do_element(input integer c, input integer oy, input integer ox,
                              output logic [7:0] got);
        integer ky, kx, tap, iy, ix;
        logic [7:0] sample;
        begin
            @(negedge clock);
            for (ky = 0; ky < K; ky++) begin
                for (kx = 0; kx < K; kx++) begin
                    tap = ky*K + kx;
                    iy  = oy*S - P + ky;
                    ix  = ox*S - P + kx;
                    if (iy >= 0 && iy < H && ix >= 0 && ix < W)
                        sample = in_mem[(c*H + iy)*W + ix];   // NCHW, channel c
                    else
                        sample = 8'sd0;                       // zero padding
                    win_v[tap*8 +: 8] = sample;
                    wk_v [tap*8 +: 8] = w_mem[c*NT + tap];    // (C,1,K,K)
                end
            end

            // dwconv/bias are combinational; drive per-channel requantize params
            bias_r = b_mem[c];
            m0_r   = m0_mem[c];
            sh_r   = sh_mem[c];
            act_r  = ACT_RELU6;
            qmax_r = RELU6_QMAX;
            rq_en  = 1'b1;
            @(posedge clock);
            @(negedge clock);
            rq_en  = 1'b0;
            got    = q_w;
        end
    endtask

    // rows chosen so all four borders + corners are covered (plus one interior)
    integer oy_tab [0:4];
    integer r, oy, ox, c;
    logic [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/001_features_0_0.hex",       in_mem);
        $readmemh("../../software/export/features_1_conv_0_0_w.hex",           w_mem);
        $readmemh("../../software/export/features_1_conv_0_0_b.hex",           b_mem);
        $readmemh("../../software/export/features_1_conv_0_0_m0.hex",          m0_mem);
        $readmemh("../../software/export/features_1_conv_0_0_shift.hex",       sh_mem);
        $readmemh("../../software/golden/image_1/002_features_1_conv_0_0.hex", gold_mem);

        win_v = 0; wk_v = 0; bias_r = 0; rq_en = 0; act_r = 0;
        m0_r = 0; sh_r = 0; qmax_r = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        oy_tab[0] = 0;      oy_tab[1] = 1;       // top border + top corners
        oy_tab[2] = H/2;                          // interior
        oy_tab[3] = H-2;    oy_tab[4] = H-1;      // bottom border + bottom corners

        $display("integration: features.1.conv.0.0 dwconv (C=%0d), 5 rows x %0d cols", C, W);

        for (r = 0; r < 5; r++) begin
            oy = oy_tab[r];
            for (ox = 0; ox < W; ox++) begin
                for (c = 0; c < C; c++) begin
                    do_element(c, oy, ox, got);
                    expd = gold_mem[(c*H + oy)*W + ox];
                    total++;
                    if (got !== expd) begin
                        fails++;
                        if (fails <= 20)
                            $display("  [ERR] c=%0d pix(%0d,%0d) : got %0d, expect %0d",
                                     c, oy, ox, $signed(got), $signed(expd));
                    end
                end
            end
            $display("  ... row oy=%0d done (%0d fails so far)", oy, fails);
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d elements)", total);
        else            $display("FAILED    (%0d / %0d elements)", fails, total);
        $finish;
    end

endmodule
