`timescale 1ns / 1ps
//============================================================================
//  stem_layer_tb.sv  -  INTEGRATION test: conv3x3_std -> bias_add -> requantize
//
//  Reproduces the network STEM (the real first layer), bit-exact vs the golden.
//  First feeder to combine all three at once: stride-2 downsampling, a channel
//  gather (Cin=3), and border zero-padding.
//
//  Layer: features.0.0  (standard 3x3 conv)
//     Cin = 3, OC = 32, K = 3, stride 2, pad 1
//     input  224x224x3 (NCHW)  ->  output 112x112x32 (NCHW)
//     activation = RELU6, relu6_qmax = 127 ; m0/shift per output channel
//
//  Weights (OC,Cin,K,K) row-major: w[oc*NT + (ic*K+ky)*K + kx], NT = Cin*K*K = 27.
//  Window: iy = oy*S - P + ky, ix = ox*S - P + kx ; out-of-image taps -> 0.
//  Same tap ordering i = (ic*K+ky)*K+kx used for both win and wk.
//
//  Coverage: top two rows, an interior row, and the bottom two rows x all cols
//  x all OC -- exercises the stride-2 border padding, across every channel.
//
//  Run:  bash scripts/run_sim.sh stem_layer conv3x3_std bias_add requantize
//============================================================================
module stem_layer_tb;

    // ---- layer geometry ----------------------------------------------------
    localparam CIN = 3;
    localparam OC  = 32;
    localparam IH  = 224, IW = 224;      // input  H,W
    localparam OH  = 112, OW = 112;      // output H,W
    localparam K   = 3;
    localparam P   = 1;                  // padding
    localparam S   = 2;                  // stride
    localparam NT  = CIN*K*K;            // 27 taps

    localparam ACT_RELU6  = 1'b1;
    localparam RELU6_QMAX = 8'sd127;

    localparam IN_N   = CIN*IH*IW;       // 150528
    localparam GOLD_N = OC*OH*OW;        // 401408
    localparam W_N    = OC*NT;           // 864

    // ---- data memories -----------------------------------------------------
    reg  [7:0]  in_mem   [0:IN_N-1];
    reg  [7:0]  w_mem    [0:W_N-1];
    reg  [31:0] b_mem    [0:OC-1];
    reg  [31:0] m0_mem   [0:OC-1];
    reg  [7:0]  sh_mem   [0:OC-1];
    reg  [7:0]  gold_mem [0:GOLD_N-1];

    // ---- DUT I/O -----------------------------------------------------------
    logic                clock, rst_n;
    logic [NT*8-1:0]     win_v, wk_v;         // conv3x3_std (combinational)
    wire  signed [20:0]  acc_w;
    logic signed [31:0]  bias_r;              // bias_add (combinational)
    wire  signed [20:0]  biased_w;
    logic                rq_en, act_r;        // requantize (registered)
    logic signed [31:0]  m0_r;
    logic        [7:0]   sh_r;
    logic signed [7:0]   qmax_r;
    wire  signed [7:0]   q_w;

    conv3x3_std #(.DATA_W(8), .K(K), .CIN(CIN), .ACC_W(21)) u_conv (
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

    // one output element (oc, oy, ox): build the padded 27-tap window (window x
    // channels) with stride 2, run conv -> bias -> requantize, return int8.
    task automatic do_element(input integer oc, input integer oy, input integer ox,
                              output logic [7:0] got);
        integer ky, kx, ic, i, iy, ix;
        logic [7:0] sample;
        begin
            @(negedge clock);
            for (ic = 0; ic < CIN; ic++) begin
                for (ky = 0; ky < K; ky++) begin
                    for (kx = 0; kx < K; kx++) begin
                        i  = (ic*K + ky)*K + kx;
                        iy = oy*S - P + ky;
                        ix = ox*S - P + kx;
                        if (iy >= 0 && iy < IH && ix >= 0 && ix < IW)
                            sample = in_mem[(ic*IH + iy)*IW + ix];   // NCHW, channel ic
                        else
                            sample = 8'sd0;                          // zero padding
                        win_v[i*8 +: 8] = sample;
                        wk_v [i*8 +: 8] = w_mem[oc*NT + i];          // (OC,Cin,K,K)
                    end
                end
            end

            bias_r = b_mem[oc];
            m0_r   = m0_mem[oc];
            sh_r   = sh_mem[oc];
            act_r  = ACT_RELU6;
            qmax_r = RELU6_QMAX;
            rq_en  = 1'b1;
            @(posedge clock);
            @(negedge clock);
            rq_en  = 1'b0;
            got    = q_w;
        end
    endtask

    integer oy_tab [0:4];
    integer r, oy, ox, oc;
    logic [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/000_input.hex",           in_mem);
        $readmemh("../../software/export/features_0_0_w.hex",              w_mem);
        $readmemh("../../software/export/features_0_0_b.hex",              b_mem);
        $readmemh("../../software/export/features_0_0_m0.hex",             m0_mem);
        $readmemh("../../software/export/features_0_0_shift.hex",          sh_mem);
        $readmemh("../../software/golden/image_1/001_features_0_0.hex",    gold_mem);

        win_v = 0; wk_v = 0; bias_r = 0; rq_en = 0; act_r = 0;
        m0_r = 0; sh_r = 0; qmax_r = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        oy_tab[0] = 0;      oy_tab[1] = 1;       // top border (stride-2 padding)
        oy_tab[2] = OH/2;                         // interior
        oy_tab[3] = OH-2;   oy_tab[4] = OH-1;     // bottom rows

        $display("integration: features.0.0 stem (Cin=%0d OC=%0d, s=2), 5 rows x %0d cols", CIN, OC, OW);

        for (r = 0; r < 5; r++) begin
            oy = oy_tab[r];
            for (ox = 0; ox < OW; ox++) begin
                for (oc = 0; oc < OC; oc++) begin
                    do_element(oc, oy, ox, got);
                    expd = gold_mem[(oc*OH + oy)*OW + ox];
                    total++;
                    if (got !== expd) begin
                        fails++;
                        if (fails <= 20)
                            $display("  [ERR] oc=%0d pix(%0d,%0d) : got %0d, expect %0d",
                                     oc, oy, ox, $signed(got), $signed(expd));
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
