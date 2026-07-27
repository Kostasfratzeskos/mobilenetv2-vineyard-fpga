`timescale 1ns / 1ps
//============================================================================
//  pointwise_layer_tb.sv  -  INTEGRATION test: conv1x1 -> bias_add -> requantize
//
//  Reproduces one real pointwise layer of the network and compares against the
//  cmodel golden vector, bit-exact.
//
//  Layer: features.1.conv.1  (project 1x1, linear bottleneck)
//     IC = 32, OC = 16, H = W = 112, stride 1, pad 0
//     activation = NONE (relu6 = False)
//     m0 / shift : per output channel
//
//  Data (all $readmemh, paths relative to the sim work dir = ROOT/sim/xsim_*):
//     input  : golden 002_features_1_conv_0_0.hex   (NCHW int8)
//     weights: features_1_conv_1_w.hex              (OC,IC int8)
//     bias   : features_1_conv_1_b.hex              (int32)
//     m0     : features_1_conv_1_m0.hex             (int32)
//     shift  : features_1_conv_1_shift.hex          (small int)
//     golden : golden 003_features_1_conv_1.hex     (NCHW int8)
//
//  Layout note: activations are stored NCHW, so channel `c` of pixel (y,x) is
//  at index (c*H + y)*W + x. Weights are (OC,IC) row-major: w[oc*IC + ic].
//
//  To keep the sim quick, only the first NPIX pixels are checked -- conv1x1 is
//  spatially independent, so every IC/OC/weight combination is still exercised.
//
//  Run:  bash scripts/run_sim.sh pointwise_layer conv1x1 bias_add requantize
//============================================================================
module pointwise_layer_tb;

    // ---- layer geometry ----------------------------------------------------
    localparam IC   = 32;
    localparam OC   = 16;
    localparam H    = 112;
    localparam W    = 112;
    localparam NPIX = 256;              // first-N pixels to check

    localparam IN_N   = IC*H*W;         // 401408
    localparam GOLD_N = OC*H*W;         // 200704
    localparam W_N    = OC*IC;          // 512

    localparam ACT_NONE = 1'b0;

    // ---- data memories -----------------------------------------------------
    reg  [7:0]  in_mem   [0:IN_N-1];
    reg  [7:0]  wq_mem   [0:W_N-1];
    reg  [31:0] b_mem    [0:OC-1];
    reg  [31:0] m0_mem   [0:OC-1];
    reg  [7:0]  sh_mem   [0:OC-1];
    reg  [7:0]  gold_mem [0:GOLD_N-1];

    // ---- DUT I/O -----------------------------------------------------------
    logic                clock;
    logic                rst_n;
    // conv1x1
    logic                cv_valid, cv_first, cv_last;
    logic signed [7:0]   a_r, w_r;
    wire  signed [20:0]  acc_w;
    wire                 cv_done;
    // bias_add
    logic signed [31:0]  bias_r;
    wire  signed [20:0]  biased_w;
    // requantize
    logic                rq_en, act_r;
    logic signed [31:0]  m0_r;
    logic        [7:0]   sh_r;
    logic signed [7:0]   qmax_r;
    wire  signed [7:0]   q_w;

    conv1x1 #(.DATA_W(8), .ACC_W(21)) u_conv (
        .clock(clock), .rst_n(rst_n),
        .valid(cv_valid), .first(cv_first), .last(cv_last),
        .a(a_r), .w(w_r), .acc(acc_w), .done(cv_done)
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

    // compute one output element (pixel y,x ; output channel oc) through the chain
    task automatic do_element(input integer y, input integer x, input integer oc,
                              output logic [7:0] got);
        integer ic;
        begin
            @(negedge clock);
            for (ic = 0; ic < IC; ic++) begin
                a_r      = in_mem[(ic*H + y)*W + x];
                w_r      = wq_mem[oc*IC + ic];
                cv_valid = 1'b1;
                cv_first = (ic == 0);
                cv_last  = (ic == IC-1);
                @(posedge clock);
                @(negedge clock);
            end
            cv_valid = 1'b0; cv_first = 1'b0; cv_last = 1'b0;

            // acc_w is final; bias_add is combinational; drive requantize params
            bias_r = b_mem[oc];
            m0_r   = m0_mem[oc];
            sh_r   = sh_mem[oc];
            act_r  = ACT_NONE;
            qmax_r = 8'sd0;
            rq_en  = 1'b1;
            @(posedge clock);          // requantize captures the result
            @(negedge clock);
            rq_en  = 1'b0;
            got    = q_w;
        end
    endtask

    integer p, y, x, oc;
    logic [7:0] got, expd;
    initial begin
        // load everything (relative to ROOT/sim/xsim_pointwise_layer/)
        $readmemh("../../software/golden/image_1/002_features_1_conv_0_0.hex", in_mem);
        $readmemh("../../software/export/features_1_conv_1_w.hex",            wq_mem);
        $readmemh("../../software/export/features_1_conv_1_b.hex",            b_mem);
        $readmemh("../../software/export/features_1_conv_1_m0.hex",           m0_mem);
        $readmemh("../../software/export/features_1_conv_1_shift.hex",        sh_mem);
        $readmemh("../../software/golden/image_1/003_features_1_conv_1.hex",  gold_mem);

        cv_valid = 0; cv_first = 0; cv_last = 0; a_r = 0; w_r = 0;
        rq_en = 0; act_r = 0; m0_r = 0; sh_r = 0; qmax_r = 0; bias_r = 0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("integration: features.1.conv.1  (IC=%0d OC=%0d), first %0d pixels", IC, OC, NPIX);

        for (p = 0; p < NPIX; p++) begin
            y = p / W;
            x = p % W;
            for (oc = 0; oc < OC; oc++) begin
                do_element(y, x, oc, got);
                expd = gold_mem[(oc*H + y)*W + x];
                total++;
                if (got !== expd) begin
                    fails++;
                    if (fails <= 20)
                        $display("  [ERR] pix(%0d,%0d) oc=%0d : got %0d, expect %0d",
                                 y, x, oc, $signed(got), $signed(expd));
                end
            end
            if (p % 64 == 63) $display("  ... %0d/%0d pixels checked (%0d fails)", p+1, NPIX, fails);
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d elements)", total);
        else            $display("FAILED    (%0d / %0d elements)", fails, total);
        $finish;
    end

endmodule
