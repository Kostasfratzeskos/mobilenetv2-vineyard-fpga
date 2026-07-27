`timescale 1ns / 1ps
//============================================================================
//  residual_layer_tb.sv  -  INTEGRATION test: residual_add vs golden
//
//  Layer: features.3.add  (res_add), 56x56x24 = 75264 elements.
//     target = features.3.conv.2 output (main path)     -> golden 009
//     saved  = features.2.conv.2 output (block input)   -> golden 006
//     out    = golden 010_features_3_add
//     rescale of `saved`: m0 = 1471079665, shift = 31 (per-tensor scalar)
//
//  residual_add is combinational and element-wise (target[i] and saved[i] are
//  the same NCHW position), so no gather: just iterate all elements.
//
//  This also decides the clamp-vs-truncate question empirically: if the RTL
//  clamp matches all 75264 golden elements, the Python golden clamps (or never
//  overflows), and our choice is correct.
//
//  Run:  bash scripts/run_sim.sh residual_layer residual_add
//============================================================================
module residual_layer_tb;

    localparam N     = 75264;
    localparam M0    = 32'd1471079665;
    localparam SHIFT = 6'd31;

    reg [7:0] saved_mem  [0:N-1];
    reg [7:0] target_mem [0:N-1];
    reg [7:0] gold_mem   [0:N-1];

    logic signed [7:0]  target, saved;
    logic signed [31:0] m0;
    logic        [5:0]  shift;
    wire  signed [7:0]  out;

    residual_add #(.DATA_W(8), .M0_W(32), .SHIFT_W(6)) dut (
        .target(target), .saved(saved), .m0(m0), .shift(shift), .out(out)
    );

    integer i, total = 0, fails = 0;
    logic [7:0] expd;
    initial begin
        $readmemh("../../software/golden/image_1/006_features_2_conv_2.hex", saved_mem);
        $readmemh("../../software/golden/image_1/009_features_3_conv_2.hex", target_mem);
        $readmemh("../../software/golden/image_1/010_features_3_add.hex",    gold_mem);

        m0 = M0; shift = SHIFT;
        $display("integration: features.3.add residual (N=%0d)", N);

        for (i = 0; i < N; i++) begin
            target = target_mem[i];
            saved  = saved_mem[i];
            #1;
            expd = gold_mem[i];
            total++;
            if (out !== expd) begin
                fails++;
                if (fails <= 20)
                    $display("  [ERR] i=%0d target=%0d saved=%0d : got %0d expect %0d",
                             i, $signed(target), $signed(saved), $signed(out), $signed(expd));
            end
            if (i % 15000 == 14999) $display("  ... %0d/%0d checked (%0d fails)", i+1, N, fails);
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d elements)", total);
        else            $display("FAILED    (%0d / %0d elements)", fails, total);
        $finish;
    end

endmodule
