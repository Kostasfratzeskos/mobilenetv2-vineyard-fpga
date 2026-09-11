`timescale 1ns / 1ps
//============================================================================
//  pw_feeder_tb.sv  -  self-checking testbench for rtl/control/pw_feeder.v
//
//  This is the first test where the whole pointwise front end runs as one
//  machine: counters drive addresses, addresses drive two buffers, the buffer
//  data meets delayed control at the array, and finished accumulators come
//  back out tagged. So the testbench does what the real system will do -
//  fill the buffers the way the DMA and the previous layer would, press
//  start, and check every result against a plain software dot product.
//
//  Three things can go wrong here that no unit test could see:
//
//    1. PIPELINE ALIGNMENT. The buffers answer a cycle late, so valid/first/
//       last must reach pe_array a cycle late too. If `first` arrived early
//       the accumulator would clear on the wrong tile and every dot product
//       would be short by one term - a bug that still produces plausible
//       numbers. Layers with n_ic > 1 are what expose it.
//    2. TAG ALIGNMENT. `done` lands two cycles after the tile that caused it,
//       so (pix, oct) is pipelined alongside. The testbench checks the tag of
//       every result, in order, not just the values - a tag that slips would
//       write correct numbers to the wrong address.
//    3. ADDRESS GENERATION. The weight counter restarts each pixel and the
//       activation base accumulates; either drifting would feed the right
//       shape of data from the wrong place.
//
//  Stalls are the sharp edge for all three, so every shape runs twice: flat
//  out, and with `stall` randomly asserted. Both must give identical results,
//  in identical order.
//
//  ACC_W = 32 here, as in pe_array_tb, so full-range random int8 cannot
//  overflow. Tail shapes (OC=24, IC=24) are included because padded lanes and
//  taps must read as zero through the buffers' tail contracts.
//
//  Run:  bash scripts/run_sim.sh pw_feeder addr_gen wgt_buffer act_buffer pe_array mac_lane
//============================================================================
module pw_feeder_tb;

    localparam DATA_W = 8;
    localparam TM     = 32;
    localparam TN     = 16;
    localparam ACC_W  = 32;
    localparam SEL_W  = 1;
    localparam BANK_W = 5;
    localparam PIX_W  = 16;
    localparam OCT_W  = 8;
    localparam ICT_W  = 8;
    localparam WA_W   = 10;
    localparam AA_W   = 16;
    localparam WDEPTH = 1024;
    localparam ADEPTH = 2048;

    localparam MAXP = 16;      // pixels used by the testbench
    localparam MAXC = 128;     // channels used by the testbench

    logic clock, rst_n;
    logic start, stall;
    logic [PIX_W-1:0] n_pix;
    logic [OCT_W-1:0] n_oc;
    logic [ICT_W-1:0] n_ic;
    logic [AA_W-1:0]  n_ent, base_in;

    logic                  wl_en;
    logic [BANK_W-1:0]     wl_bank;
    logic [WA_W-1:0]       wl_addr;
    logic [TN*DATA_W-1:0]  wl_data;

    logic                  aw_en;
    logic [AA_W-1:0]       aw_addr;
    logic [TM*DATA_W-1:0]  aw_data;

    wire [TM*ACC_W-1:0]    acc;
    wire                   acc_valid;
    wire [PIX_W-1:0]       acc_pix;
    wire [OCT_W-1:0]       acc_oct;
    wire                   busy, layer_done;

    pw_feeder #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W), .SEL_W(SEL_W),
                .BANK_W(BANK_W), .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W),
                .WA_W(WA_W), .AA_W(AA_W), .WDEPTH(WDEPTH), .ADEPTH(ADEPTH)) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .stall(stall),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic), .n_ent(n_ent), .base_in(base_in),
        .wl_en(wl_en), .wl_bank(wl_bank), .wl_addr(wl_addr), .wl_data(wl_data),
        .aw_en(aw_en), .aw_addr(aw_addr), .aw_data(aw_data),
        .acc(acc), .acc_valid(acc_valid), .acc_pix(acc_pix), .acc_oct(acc_oct),
        .busy(busy), .layer_done(layer_done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    integer total = 0, fails = 0;

    // ---- the layer under test, visible to the monitor ------------------
    integer cur_p, cur_ic, cur_oc, cur_nic, cur_noc;
    logic signed [DATA_W-1:0] av [0:MAXP-1][0:MAXC-1];    // activations
    logic signed [DATA_W-1:0] wv [0:MAXC-1][0:MAXC-1];    // weights [oc][ic]

    // ---- monitor: score every result the feeder emits ------------------
    integer mon_on, seen, exp_p, exp_o, errs;
    // drain latency: how long results keep arriving after layer_done, which
    // is the minimum gap the sequencer must leave before the next `start`
    integer done_seen, drain_cyc, drain_max;

    task automatic score_result;
        integer m, k, ocx;
        longint expd;
        logic signed [ACC_W-1:0] got;
        begin
            // the tag must follow pixel-major, oc_tile-minor order
            if (acc_pix !== exp_p[PIX_W-1:0] || acc_oct !== exp_o[OCT_W-1:0]) begin
                errs++;
                if (errs <= 5)
                    $display("  [ERR] result %0d: tag (pix=%0d,oct=%0d) expected (%0d,%0d)",
                             seen, acc_pix, acc_oct, exp_p, exp_o);
            end

            for (m = 0; m < TM; m++) begin
                ocx  = exp_o*TM + m;
                expd = 0;
                if (ocx < cur_oc)
                    for (k = 0; k < cur_ic; k++)
                        expd += longint'(av[exp_p][k]) * longint'(wv[ocx][k]);
                got = acc[m*ACC_W +: ACC_W];
                if (got !== ACC_W'(expd)) begin
                    errs++;
                    if (errs <= 5)
                        $display("  [ERR] pix=%0d oct=%0d lane=%0d (oc=%0d): got %0d expected %0d",
                                 exp_p, exp_o, m, ocx, got, expd);
                end
            end

            seen++;
            exp_o++;
            if (exp_o == cur_noc) begin exp_o = 0; exp_p++; end
        end
    endtask

    always @(negedge clock) begin
        if (mon_on) begin
            if (layer_done) begin done_seen = 1; drain_cyc = 0; end
            else if (done_seen) drain_cyc++;
            if (acc_valid) begin
                score_result;
                if (done_seen && drain_cyc > drain_max) drain_max = drain_cyc;
            end
        end
    end

    // ---- fill the buffers the way the real system would ----------------
    task automatic load_acts(input integer npix, input integer ic, input integer base);
        integer p, e, k, c, nent;
        begin
            nent = (ic + TM - 1) / TM;
            for (p = 0; p < npix; p++)
                for (e = 0; e < nent; e++) begin
                    @(negedge clock);
                    for (k = 0; k < TM; k++) begin
                        c = e*TM + k;
                        // beyond IC the stored value is whatever the previous
                        // layer's padded lanes produced: deliberately NOT zero,
                        // to prove the zero weights are what makes it harmless
                        aw_data[k*DATA_W +: DATA_W] = (c < ic) ? av[p][c] : 8'h5A;
                    end
                    aw_addr = base[AA_W-1:0] + (p*nent + e);
                    aw_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    aw_en = 1'b0;
                end
        end
    endtask

    task automatic load_wgts(input integer ic, input integer oc);
        integer ot, it, m, j, ocx, icx, nic, noc;
        begin
            nic = (ic + TN - 1) / TN;
            noc = (oc + TM - 1) / TM;
            // the full n_oc*n_ic rectangle across every bank, zero in the pad
            for (ot = 0; ot < noc; ot++)
                for (it = 0; it < nic; it++)
                    for (m = 0; m < TM; m++) begin
                        @(negedge clock);
                        ocx = ot*TM + m;
                        for (j = 0; j < TN; j++) begin
                            icx = it*TN + j;
                            wl_data[j*DATA_W +: DATA_W] =
                                (ocx < oc && icx < ic) ? wv[ocx][icx] : 8'h00;
                        end
                        wl_bank = m[BANK_W-1:0];
                        wl_addr = (ot*nic + it);
                        wl_en   = 1'b1;
                        @(posedge clock);
                        @(negedge clock);
                        wl_en = 1'b0;
                    end
        end
    endtask

    // ---- run one layer end to end --------------------------------------
    task automatic run_layer(input integer npix, input integer ic, input integer oc,
                             input integer base, input string tag, input integer stall_pct);
        integer expect_n, guard;
        begin
            cur_p = npix; cur_ic = ic; cur_oc = oc;
            cur_nic = (ic + TN - 1) / TN;
            cur_noc = (oc + TM - 1) / TM;
            expect_n = npix * cur_noc;

            load_acts(npix, ic, base);
            load_wgts(ic, oc);

            seen = 0; exp_p = 0; exp_o = 0; errs = 0;
            done_seen = 0; drain_cyc = 0;

            @(negedge clock);
            n_pix   = npix[PIX_W-1:0];
            n_oc    = cur_noc[OCT_W-1:0];
            n_ic    = cur_nic[ICT_W-1:0];
            n_ent   = ((ic + TM - 1) / TM);
            base_in = base[AA_W-1:0];
            stall   = 1'b0;
            start   = 1'b1;
            mon_on  = 1;
            @(negedge clock);
            start = 1'b0;

            guard = (npix * cur_noc * cur_nic + 64) * 8;
            while (busy && guard > 0) begin
                stall = (stall_pct == 0) ? 1'b0 : (({$random} % 100) < stall_pct);
                @(negedge clock);
                guard--;
            end
            stall = 1'b0;
            repeat (6) @(negedge clock);      // drain the last results
            mon_on = 0;

            total++;
            if (seen !== expect_n) begin
                errs++;
                $display("  [ERR] %-14s produced %0d results, expected %0d", tag, seen, expect_n);
            end
            if (guard <= 0) begin
                errs++;
                $display("  [ERR] %-14s watchdog expired", tag);
            end

            if (errs == 0)
                $display("  [ok ] %-14s %0dpx IC=%0d OC=%0d : %0d results x %0d lanes%s",
                         tag, npix, ic, oc, seen, TM,
                         (stall_pct > 0) ? $sformatf(", %0d%% stalled", stall_pct) : "");
            else
                fails++;
        end
    endtask

    task automatic randomize_data(input integer ic, input integer oc);
        integer p, c, o;
        begin
            for (p = 0; p < MAXP; p++)
                for (c = 0; c < MAXC; c++) av[p][c] = $random;
            for (o = 0; o < MAXC; o++)
                for (c = 0; c < MAXC; c++) wv[o][c] = $random;
        end
    endtask

    // run a shape clean and stalled; both must agree with the reference
    task automatic run_both(input integer npix, input integer ic, input integer oc,
                            input integer base, input string tag);
        begin
            randomize_data(ic, oc);
            run_layer(npix, ic, oc, base, tag, 0);
            run_layer(npix, ic, oc, base, tag, 30);
        end
    endtask

    initial begin
        start = 0; stall = 0; wl_en = 0; aw_en = 0;
        wl_bank = 0; wl_addr = 0; wl_data = 0;
        aw_addr = 0; aw_data = 0;
        n_pix = 0; n_oc = 0; n_ic = 0; n_ent = 0; base_in = 0;
        mon_on = 0; seen = 0; exp_p = 0; exp_o = 0; errs = 0;
        done_seen = 0; drain_cyc = 0; drain_max = 0;
        cur_p = 0; cur_ic = 0; cur_oc = 0; cur_nic = 1; cur_noc = 1;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("pw_feeder: addr_gen + wgt_buffer + act_buffer + pe_array");
        $display("");
        $display("clean shapes:");
        run_both(4,  32, 64,  0, "IC32 OC64");     // n_ic=2, n_oc=2, n_ent=1
        run_both(4,  96, 32,  0, "IC96 OC32");     // n_ic=6, n_oc=1, n_ent=3
        run_both(6,  64, 96,  0, "IC64 OC96");     // n_ic=4, n_oc=3, n_ent=2

        $display("");
        $display("tail shapes (padded lanes and taps must contribute zero):");
        run_both(4,  24, 24,  0, "IC24 OC24");     // both dimensions padded
        run_both(4,  96, 24,  0, "IC96 OC24");     // OC tail only
        run_both(4,  40, 64,  0, "IC40 OC64");     // IC tail only, odd n_ic=3

        $display("");
        $display("single ic_tile (the writeback-bound case):");
        run_both(8,  16, 96,  0, "IC16 OC96");     // n_ic=1 - first and last together

        $display("");
        $display("non-zero input base:");
        run_both(4,  32, 32, 500, "base=500");

        $display("");
        $display("drain latency: results kept arriving up to %0d cycles after layer_done", drain_max);
        $display("  -> the sequencer must leave at least that gap before the next start");
        total++;
        if (drain_max > 4) begin
            fails++;
            $display("  [ERR] drain latency %0d exceeds the documented 2-cycle pipeline", drain_max);
        end
        $display("");
        if (fails == 0) $display("ALL PASS  (%0d layers)", total);
        else            $display("FAILED    (%0d / %0d layers)", fails, total);
        $finish;
    end

endmodule
