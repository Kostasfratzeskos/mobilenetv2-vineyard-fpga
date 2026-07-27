`timescale 1ns / 1ps
//============================================================================
//  residual_add_tb.sv  -  self-checking testbench for rtl/kernels/residual_add.v
//
//  Pure combinational: drive target/saved/m0/shift, wait a delta, compare
//  against an independent reference:
//     rescaled = clamp_i8( (saved*m0 + (1<<(shift-1))) >>> shift )
//     out      = clamp_i8( rescaled + target )
//
//  Includes cases where rescaled+target overflows int8, so the final clamp
//  (vs the C's truncation) is actually exercised.
//
//  Run:  bash scripts/run_sim.sh residual_add
//============================================================================
module residual_add_tb;

    localparam DATA_W  = 8;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;

    localparam longint M0_HALF = 32'sd1073741824;   // 1<<30, with shift 31 => 0.5

    logic signed [DATA_W-1:0]  target, saved;
    logic signed [M0_W-1:0]    m0;
    logic        [SHIFT_W-1:0] shift;
    wire  signed [DATA_W-1:0]  out;

    residual_add #(.DATA_W(DATA_W), .M0_W(M0_W), .SHIFT_W(SHIFT_W)) dut (
        .target(target), .saved(saved), .m0(m0), .shift(shift), .out(out)
    );

    integer total = 0;
    integer fails = 0;

    function automatic longint clamp8(input longint v);
        if (v < -128) return -128;
        else if (v > 127) return 127;
        else return v;
    endfunction

    task automatic run_case(input longint t_target, input longint t_saved,
                            input longint t_m0, input integer t_shift, input string tag);
        longint prod, rounded, shifted, rescaled, expected;
        begin
            target = DATA_W'(t_target);
            saved  = DATA_W'(t_saved);
            m0     = M0_W'(t_m0);
            shift  = SHIFT_W'(t_shift);
            #1;

            prod     = t_saved * t_m0;
            rounded  = prod + (longint'(1) << (t_shift-1));
            shifted  = rounded >>> t_shift;
            rescaled = clamp8(shifted);
            expected = clamp8(rescaled + t_target);

            total++;
            if (out !== DATA_W'(expected)) begin
                fails++;
                $display("  [ERR] %-16s target=%0d saved=%0d : got %0d expect %0d",
                         tag, t_target, t_saved, out, expected);
            end else begin
                $display("  [ok ] %-16s target=%0d saved=%0d -> %0d", tag, t_target, t_saved, out);
            end
        end
    endtask

    integer n;
    longint rt, rs;
    initial begin
        $display("directed cases (M=0.5, shift 31):");
        run_case(  0,   0, M0_HALF, 31, "both zero");     // 0
        run_case( 50,   0, M0_HALF, 31, "saved 0");       // -> target 50
        run_case(  0, 100, M0_HALF, 31, "target 0");      // rescale 100->50
        run_case( 40,  80, M0_HALF, 31, "no sat");        // 40 + 40 = 80
        run_case(127, 100, M0_HALF, 31, "pos saturate");  // 127+50=177 -> 127
        run_case(-128,-100,M0_HALF, 31, "neg saturate");  // -128+-50=-178 -> -128
        run_case(100, 120, M0_HALF, 31, "pos sat 2");     // 100+60=160 -> 127

        $display("randomized cases:");
        for (n = 0; n < 24; n++) begin
            rt = $random % 128;          // target in ~[-127,127]
            rs = $random % 128;          // saved
            run_case(rt, rs, M0_HALF, 31, $sformatf("rand[%0d]", n));
        end

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d cases)", total);
        else            $display("FAILED    (%0d / %0d cases)", fails, total);
        $finish;
    end

endmodule
