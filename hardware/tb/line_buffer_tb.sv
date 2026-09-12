`timescale 1ns / 1ps
//============================================================================
//  line_buffer_tb.sv  -  self-checking testbench for rtl/control/line_buffer.v
//
//  The claim under test is that reading each input pixel ONCE produces exactly
//  the same 3x3 windows the old testbenches built by reading nine. So the
//  oracle here is that nine-read version: for every emitted window the
//  testbench independently gathers the nine taps straight out of the image,
//  substituting zero wherever the tap falls outside it, and demands a match on
//  all TC channels.
//
//  What that actually exercises, and what would break silently without it:
//    - the two row delays being in the right ORDER (lb1 older than lb0);
//    - the top mask, which stops the stale contents of lb0/lb1 at the start of
//      a pass from reaching the window, so no memory clearing is needed;
//    - the left-column clear at in_x == 0, without which the window at cx = 0
//      would see the PREVIOUS row's last two columns instead of padding - a
//      wrap-around bug that produces plausible numbers;
//    - the virtual row and column, which are what let the last real row and
//      column be centred at all;
//    - stride 2 emitting only even centres while still consuming every pixel.
//
//  Pixel values are 1..255 and never 0, so padding is always distinguishable
//  from data. Every shape is run twice, flat out and with in_valid randomly
//  deasserted, and both must produce identical windows in identical order.
//
//  Run:  bash scripts/run_sim.sh line_buffer
//============================================================================
module line_buffer_tb;

    localparam DATA_W = 8;
    localparam TC     = 16;
    localparam K      = 3;
    localparam MAX_W  = 112;
    localparam XW     = 8;
    localparam GW     = TC*DATA_W;

    localparam MAXH = 112;
    localparam MAXPX = MAXH*MAX_W;

    logic clock, rst_n;
    logic                     in_valid, stride2;
    logic [GW-1:0]            in_data;
    logic [XW-1:0]            in_x, in_y;
    wire  [K*K*GW-1:0]        win;
    wire                      win_valid;
    wire  [XW-1:0]            out_x, out_y;

    line_buffer #(.DATA_W(DATA_W), .TC(TC), .K(K), .MAX_W(MAX_W), .XW(XW)) u_dut (
        .clock(clock), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data), .in_x(in_x), .in_y(in_y),
        .stride2(stride2),
        .win(win), .win_valid(win_valid), .out_x(out_x), .out_y(out_y)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ---- the image under test ---------------------------------------------
    integer cur_w, cur_h, cur_s;      // input width/height, stride
    integer cur_ow, cur_oh;           // the output grid they imply
    integer exp_cy, exp_cx, seen, errs, mon_on;

    // never 0, so padding is always distinguishable from real data
    function automatic [7:0] pix(input integer y, input integer x, input integer c);
        pix = 8'(((y*31 + x*7 + c*3) % 255) + 1);
    endfunction

    // ---- monitor: score every window against a nine-read gather -----------
    task automatic check_window;
        integer ky, kx, c, iy, ix, icy, icx, bad;
        logic [7:0] got, expd;
        begin
            bad = 0;
            if (out_y !== exp_cy[XW-1:0] || out_x !== exp_cx[XW-1:0]) begin
                bad++;
                if (errs < 4)
                    $display("  [ERR] window %0d: coords (%0d,%0d) expected (%0d,%0d)",
                             seen, out_y, out_x, exp_cy, exp_cx);
            end

            icy = exp_cy * cur_s;        // centre in INPUT coordinates
            icx = exp_cx * cur_s;
            for (ky = 0; ky < K; ky++)
                for (kx = 0; kx < K; kx++) begin
                    iy = icy - 1 + ky;
                    ix = icx - 1 + kx;
                    for (c = 0; c < TC; c++) begin
                        got  = win[((ky*K + kx)*TC + c)*DATA_W +: DATA_W];
                        expd = (iy >= 0 && iy < cur_h && ix >= 0 && ix < cur_w)
                               ? pix(iy, ix, c) : 8'h00;
                        if (got !== expd) begin
                            bad++;
                            if (errs + bad <= 6)
                                $display("  [ERR] centre(%0d,%0d) tap(%0d,%0d) ch=%0d : got %02h expected %02h",
                                         icy, icx, ky, kx, c, got, expd);
                        end
                    end
                end

            errs += bad;
            seen++;
            // advance to the next expected centre, in output coordinates
            exp_cx++;
            if (exp_cx == cur_ow) begin
                exp_cx = 0;
                exp_cy++;
            end
        end
    endtask

    always @(negedge clock)
        if (mon_on && win_valid) check_window;

    // ---- drive one pass over the extended grid ----------------------------
    task automatic run_pass(input integer iw, input integer ih, input integer s,
                            input string tag, input integer stall_pct);
        integer y, x, c, ow, oh, expect_n;
        begin
            cur_w = iw; cur_h = ih; cur_s = s;
            ow = (iw + 2 - K)/s + 1;
            oh = (ih + 2 - K)/s + 1;
            cur_ow = ow; cur_oh = oh;
            expect_n = ow*oh;
            exp_cy = 0; exp_cx = 0; seen = 0; errs = 0;

            // a fresh pass: the module must not depend on the line buffers
            // being cleared, so they are deliberately left dirty from the
            // previous pass.
            @(negedge clock);
            stride2 = (s == 2);
            mon_on  = 1;

            for (y = 0; y <= ih; y++) begin
                for (x = 0; x <= iw; x++) begin
                    // optional stall: hold everything, advance nothing
                    while (stall_pct != 0 && (({$random} % 100) < stall_pct)) begin
                        @(negedge clock);
                        in_valid = 1'b0;
                        @(posedge clock);
                    end
                    @(negedge clock);
                    for (c = 0; c < TC; c++)
                        in_data[c*DATA_W +: DATA_W] =
                            (y < ih && x < iw) ? pix(y, x, c) : 8'h00;
                    in_x     = x[XW-1:0];
                    in_y     = y[XW-1:0];
                    in_valid = 1'b1;
                    @(posedge clock);
                end
            end
            @(negedge clock);
            in_valid = 1'b0;
            repeat (3) @(negedge clock);
            mon_on = 0;

            total++;
            if (seen !== expect_n) begin
                errs++;
                $display("  [ERR] %-16s emitted %0d windows, expected %0d (%0dx%0d)",
                         tag, seen, expect_n, oh, ow);
            end

            if (errs == 0)
                $display("  [ok ] %-16s %0dx%0d s=%0d -> %0dx%0d : %0d windows x %0d taps x %0d ch%s",
                         tag, ih, iw, s, oh, ow, seen, K*K, TC,
                         (stall_pct > 0) ? ", stalled" : "");
            else
                fails++;
        end
    endtask

    task automatic run_both(input integer iw, input integer ih, input integer s,
                            input string tag);
        begin
            run_pass(iw, ih, s, tag, 0);
            run_pass(iw, ih, s, tag, 25);
        end
    endtask

    initial begin
        in_valid = 0; in_data = 0; in_x = 0; in_y = 0; stride2 = 0;
        cur_w = 1; cur_h = 1; cur_s = 1; cur_ow = 1; cur_oh = 1;
        exp_cy = 0; exp_cx = 0; seen = 0; errs = 0; mon_on = 0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("line_buffer: %0dx%0d window over %0d channels, MAX_W=%0d",
                 K, K, TC, MAX_W);
        $display("");
        $display("small shapes (easy to reason about by hand):");
        run_both(3,  3,  1, "3x3 s1");
        run_both(4,  4,  1, "4x4 s1");
        run_both(7,  7,  1, "7x7 s1");
        run_both(5,  3,  1, "5x3 s1 (wide)");
        run_both(3,  5,  1, "3x5 s1 (tall)");

        $display("");
        $display("stride 2 (every pixel consumed, every other centre emitted):");
        run_both(4,  4,  2, "4x4 s2");
        run_both(7,  7,  2, "7x7 s2");
        run_both(8,  8,  2, "8x8 s2");

        $display("");
        $display("real depthwise shapes:");
        run_both(14, 14, 1, "14x14 s1");
        run_both(28, 28, 2, "28x28 s2");
        run_pass(56, 56, 1, "56x56 s1", 0);
        run_pass(112, 112, 1, "112x112 s1", 0);    // the biggest, unstalled
        run_pass(112, 112, 2, "112x112 s2", 0);

        $display("");
        if (fails == 0) $display("ALL PASS  (%0d passes)", total);
        else            $display("FAILED    (%0d / %0d passes)", fails, total);
        $finish;
    end

endmodule
