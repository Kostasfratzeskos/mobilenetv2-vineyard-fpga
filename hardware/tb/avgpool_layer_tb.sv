`timescale 1ns / 1ps
//============================================================================
//  avgpool_layer_tb.sv  -  INTEGRATION test: avgpool -> requantize vs golden
//
//  Layer: avgpool (kind=gap), global average pool 7x7x1280 -> 1x1x1280.
//     input  = golden 062_features_18_0  (NCHW int8, 7x7x1280)
//     output = golden 063_avgpool        (int8, 1280)
//     requantize: ACT_NONE, m0 = 1990030058, shift = 36 (per-tensor scalar);
//     the /(H*W)=1/49 averaging is folded into m0.
//
//  For each channel: stream its 49 spatial samples through the accumulator,
//  then requantize the sum. (Sum order is irrelevant, so NCHW gather is fine.)
//
//  Run:  bash scripts/run_sim.sh avgpool_layer avgpool requantize
//============================================================================
module avgpool_layer_tb;

    localparam C  = 1280;
    localparam H  = 7, W = 7, HW = 49;
    localparam M0    = 32'd1990030058;
    localparam SHIFT = 6'd36;
    localparam ACT_NONE = 1'b0;

    reg [7:0] in_mem   [0:C*HW-1];
    reg [7:0] gold_mem [0:C-1];

    logic                clock, rst_n;
    logic                ap_valid, ap_first, ap_last;
    logic signed [7:0]   a_r;
    wire  signed [20:0]  acc_w;
    wire                 ap_done;
    logic                rq_en, act_r;
    logic signed [31:0]  m0_r;
    logic        [7:0]   sh_r;
    logic signed [7:0]   qmax_r;
    wire  signed [7:0]   q_w;

    avgpool #(.DATA_W(8), .ACC_W(21)) u_ap (
        .clock(clock), .rst_n(rst_n),
        .valid(ap_valid), .first(ap_first), .last(ap_last),
        .a(a_r), .acc(acc_w), .done(ap_done)
    );

    requantize #(.ACC_W(21), .M0_W(32), .SHIFT_W(6)) u_rq (
        .clock(clock), .rst_n(rst_n), .en(rq_en),
        .act(act_r), .in_data(acc_w), .M0(m0_r),
        .shift(sh_r[5:0]), .relu6_qmax(qmax_r), .quantized(q_w)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // pool one channel: stream its 49 samples, then requantize the sum
    task automatic do_channel(input integer c, output logic [7:0] got);
        integer y, x, s;
        begin
            @(negedge clock);
            for (y = 0; y < H; y++) begin
                for (x = 0; x < W; x++) begin
                    s = y*W + x;
                    a_r      = in_mem[(c*H + y)*W + x];   // NCHW, channel c
                    ap_valid = 1'b1;
                    ap_first = (s == 0);
                    ap_last  = (s == HW-1);
                    @(posedge clock);
                    @(negedge clock);
                end
            end
            ap_valid = 1'b0; ap_first = 1'b0; ap_last = 1'b0;

            m0_r = M0; sh_r = SHIFT; act_r = ACT_NONE; qmax_r = 0;
            rq_en = 1'b1;
            @(posedge clock);
            @(negedge clock);
            rq_en = 1'b0;
            got = q_w;
        end
    endtask

    integer c;
    logic [7:0] got, expd;
    initial begin
        $readmemh("../../software/golden/image_1/062_features_18_0.hex", in_mem);
        $readmemh("../../software/golden/image_1/063_avgpool.hex",       gold_mem);

        ap_valid=0; ap_first=0; ap_last=0; a_r=0; rq_en=0; act_r=0;
        m0_r=0; sh_r=0; qmax_r=0;
        rst_n = 0;
        repeat (2) @(negedge clock);
        rst_n = 1;

        $display("integration: avgpool gap (C=%0d, window=%0d)", C, HW);

        for (c = 0; c < C; c++) begin
            do_channel(c, got);
            expd = gold_mem[c];
            total++;
            if (got !== expd) begin
                fails++;
                if (fails <= 20)
                    $display("  [ERR] c=%0d : got %0d, expect %0d", c, $signed(got), $signed(expd));
            end
            if (c % 256 == 255) $display("  ... %0d/%0d channels (%0d fails)", c+1, C, fails);
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d channels)", total);
        else            $display("FAILED    (%0d / %0d channels)", fails, total);
        $finish;
    end

endmodule
