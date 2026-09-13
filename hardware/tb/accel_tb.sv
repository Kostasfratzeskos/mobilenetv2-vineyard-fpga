`timescale 1ns / 1ps
//============================================================================
//  accel_tb.sv  -  INTEGRATION: the whole network, all 64 instructions
//
//  Runs the REAL compiled program end to end - one image in, four logits and a
//  predicted class out - and compares EVERY intermediate tensor against the
//  software golden, layer by layer. 6,895,780 elements across 64 ops.
//
//  The individual datapath testbenches already proved each feeder in isolation.
//  What this file exists to test is everything between them:
//
//    1. the opcode mux. Six feeders take turns through ONE out_stage, one
//       act_buffer and one parameter bank. A wrong selection, or an idle
//       feeder's write reaching the pool, shows up as a wrong tensor.
//    2. the allocator. Nothing tells an op where its input is except
//       gen_program.py's static allocation, through base_in / base_out /
//       base_saved. The residual adds are the sharp case: base_saved points at
//       a tensor produced up to three ops earlier that the allocator had to
//       keep alive across everything in between.
//    3. the drain between ops. top_seq waits for busy to fall, idles GAP_CYC
//       cycles, and flushes out_stage on the next op_start. Too short a window
//       destroys the TAIL of each layer, so every element is compared rather
//       than a sample.
//    4. the load handshake feeding real hardware. This testbench plays the DMA
//       exactly as the instruction describes it - see below.
//
//  ---- the testbench as DMA, driven only by the instruction ---------------
//
//  top_seq hands out (wgt_off, wgt_bytes, pchan) and waits for ld_done. That
//  turns out to be enough to load anything, with no per-layer table at all:
//
//      taps per output channel = wgt_bytes / pchan
//
//  which is 27 for the stem (3 channels x 3 x 3), 9 for a depthwise, and for a
//  pointwise it is IC itself. So the same three numbers that tell the DMA WHERE
//  to read also tell it HOW to deal the bytes into banks. The only thing the
//  testbench knows that the hardware does not is which golden file to compare
//  against, and even that is generated - see program_ops.svh.
//
//  Weights come from weights.hex by offset; parameters come from params_*.hex
//  sequentially, because ops execute in program order and the blob is already
//  padded to whole TM-channel tiles. Both are written by
//
//      python scripts/gen_program.py --emit
//
//  which must be run before this testbench (weights.hex is gitignored: it is a
//  byte-for-byte concatenation of the per-layer files already in the tree).
//
//  ---- the two ops that are not a tensor ---------------------------------
//
//  GAP writes 1x1x1280, which the same pool check handles with npix = 1.
//  LINEAR writes no tensor at all - its result is four int16 logits out of
//  logit_out, not int8 activations - so it is checked against
//  065_classifier_1_logits_int16.hex and the argmax against the class the
//  software model predicted.
//
//  Run:  bash scripts/run_sim.sh accel accel_top top_seq \
//          pw_feeder pw_out dw_feeder res_feeder gap_feeder stem_feeder \
//          logit_out out_stage pe_array mac_lane conv1x1 dwconv3x3 \
//          conv3x3_std dw_array stem_array line_buffer avgpool addr_gen \
//          wgt_buffer act_buffer img_buffer param_buffer rq_bank \
//          bias_add requantize
//============================================================================
module accel_tb;

    // ---- geometry, matching accel_top's defaults --------------------------
    localparam DATA_W  = 8;
    localparam TM      = 32;
    localparam TN      = 16;
    localparam TC      = 16;
    localparam TS      = 8;
    localparam CIN     = 3;
    localparam K       = 3;
    localparam ACC_W   = 21;
    localparam BIAS_W  = 32;
    localparam M0_W    = 32;
    localparam SHIFT_W = 6;
    localparam SEL_W   = 1;
    localparam AA_W    = 16;
    localparam IA_W    = 16;
    localparam PA_W    = 6;
    localparam BANK_W  = 5;
    localparam DW_BANK_W = 4;
    localparam ST_BANK_W = 3;
    localparam PW_WA_W = 10;
    localparam DW_WA_W = 6;
    localparam ST_WA_W = 4;
    localparam NI_W    = 8;
    localparam PGA_W   = 9;
    localparam PGW     = 32;
    localparam NLOG    = 4;
    localparam IDX_W   = 2;
    localparam LOG_W   = 16;

    localparam IH = 224, IW = 224;
    localparam NIN    = CIN*IH*IW;   // 150,528
    localparam MAXOUT = 1204224;     // largest single output tensor (96x112x112)
    localparam WBLOB  = 2194880;     // weights.hex
    localparam PBLOB  = 19264;       // params_*.hex, padded to whole tiles

    localparam [3:0] OP_STEM = 4'd1, OP_PW = 4'd2, OP_DW = 4'd3,
                     OP_RES  = 4'd4, OP_GAP = 4'd5, OP_LINEAR = 4'd6;

    // ---- DUT interface ----------------------------------------------------
    logic                      clock, rst_n;
    logic                      start;
    logic [NI_W-1:0]           n_instr;

    logic                      pg_en;
    logic [PGA_W-1:0]          pg_addr;
    logic [PGW-1:0]            pg_data;

    logic                      im_wr_en;
    logic [IA_W-1:0]           im_wr_addr;
    logic [CIN*DATA_W-1:0]     im_wr_data;

    wire                       ld_req;
    wire [23:0]                ld_off;
    wire [19:0]                ld_bytes;
    wire [15:0]                ld_pchan;
    logic                      ld_done;

    logic                      pw_wl_en;
    logic [BANK_W-1:0]         pw_wl_bank;
    logic [PW_WA_W-1:0]        pw_wl_addr;
    logic [TN*DATA_W-1:0]      pw_wl_data;

    logic                      dw_wl_en;
    logic [DW_BANK_W-1:0]      dw_wl_bank;
    logic [DW_WA_W-1:0]        dw_wl_addr;
    logic [K*K*DATA_W-1:0]     dw_wl_data;

    logic                      st_wl_en;
    logic [ST_BANK_W-1:0]      st_wl_bank;
    logic [ST_WA_W-1:0]        st_wl_addr;
    logic [CIN*K*K*DATA_W-1:0] st_wl_data;

    logic                      pl_en;
    logic [BANK_W-1:0]         pl_bank;
    logic [PA_W-1:0]           pl_addr;
    logic signed [BIAS_W-1:0]  pl_bias;
    logic signed [M0_W-1:0]    pl_m0;
    logic [SHIFT_W-1:0]        pl_shift;

    logic                      lg_pl_en;
    logic [IDX_W-1:0]          lg_pl_idx;
    logic signed [BIAS_W-1:0]  lg_pl_bias;
    logic signed [M0_W-1:0]    lg_pl_m0;
    logic [SHIFT_W-1:0]        lg_pl_shift;

    wire [NLOG*LOG_W-1:0]      logits;
    wire                       logits_valid;
    wire [IDX_W-1:0]           argmax;
    wire                       argmax_valid;
    wire [NI_W-1:0]            pc;
    wire                       running, done, tag_error;

    accel_top #(
        .DATA_W(DATA_W), .TM(TM), .TN(TN), .TC(TC), .TS(TS), .TSLOG(3),
        .CIN(CIN), .K(K), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W), .SEL_W(SEL_W),
        .AA_W(AA_W), .IA_W(IA_W), .PA_W(PA_W),
        .BANK_W(BANK_W), .DW_BANK_W(DW_BANK_W), .ST_BANK_W(ST_BANK_W),
        .PW_WA_W(PW_WA_W), .DW_WA_W(DW_WA_W), .ST_WA_W(ST_WA_W),
        .NI_W(NI_W), .PGA_W(PGA_W), .PW_W(PGW),
        .NLOG(NLOG), .IDX_W(IDX_W), .LOG_W(LOG_W)
    ) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_instr(n_instr),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .im_wr_en(im_wr_en), .im_wr_addr(im_wr_addr), .im_wr_data(im_wr_data),
        .ld_req(ld_req), .ld_off(ld_off), .ld_bytes(ld_bytes),
        .ld_pchan(ld_pchan), .ld_done(ld_done),
        .pw_wl_en(pw_wl_en), .pw_wl_bank(pw_wl_bank),
        .pw_wl_addr(pw_wl_addr), .pw_wl_data(pw_wl_data),
        .dw_wl_en(dw_wl_en), .dw_wl_bank(dw_wl_bank),
        .dw_wl_addr(dw_wl_addr), .dw_wl_data(dw_wl_data),
        .st_wl_en(st_wl_en), .st_wl_bank(st_wl_bank),
        .st_wl_addr(st_wl_addr), .st_wl_data(st_wl_data),
        .pl_en(pl_en), .pl_bank(pl_bank), .pl_addr(pl_addr),
        .pl_bias(pl_bias), .pl_m0(pl_m0), .pl_shift(pl_shift),
        .lg_pl_en(lg_pl_en), .lg_pl_idx(lg_pl_idx), .lg_pl_bias(lg_pl_bias),
        .lg_pl_m0(lg_pl_m0), .lg_pl_shift(lg_pl_shift),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid),
        .pc(pc), .running(running), .done(done), .tag_error(tag_error)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    // ---- memories ---------------------------------------------------------
    reg [31:0] prog     [0:511];
    reg [7:0]  img_mem  [0:NIN-1];
    reg [7:0]  gold_mem [0:MAXOUT-1];
    reg [15:0] gold_log [0:NLOG-1];
    reg [7:0]  wblob    [0:WBLOB-1];
    reg signed [31:0] pb_blob [0:PBLOB-1];
    reg signed [31:0] pm_blob [0:PBLOB-1];
    reg [7:0]         ps_blob [0:PBLOB-1];

    // The per-op geometry and golden-vector table, generated by the compiler
    // so it cannot drift from what was actually emitted. Declares N_PROG_OPS,
    // OP_OPCODE/OC/IC/OH/OW, load_op_table and load_golden (which fills
    // gold_mem, declared above).
    `include "program_ops.svh"

    localparam N_OPS = N_PROG_OPS;

    integer total = 0, fails = 0, checked = 0, ld_count = 0;
    integer pidx = 0;            // running index into the parameter blob

    // ======================================================================
    //  the testbench as DMA
    // ======================================================================

    // ---- stem: bank = lane within the tile, address = oc_tile -------------
    task automatic fill_stem_weights(input integer off, input integer nbytes,
                                     input integer pchan);
        integer ot, m, i, ocx, n_oct, nt;
        begin
            nt    = nbytes / pchan;          // 27
            n_oct = (pchan + TS - 1) / TS;
            for (ot = 0; ot < n_oct; ot++)
                for (m = 0; m < TS; m++) begin
                    @(negedge clock);
                    ocx = ot*TS + m;
                    for (i = 0; i < nt; i++)
                        st_wl_data[i*DATA_W +: DATA_W] =
                            (ocx < pchan) ? wblob[off + ocx*nt + i] : 8'h00;
                    st_wl_bank = m[ST_BANK_W-1:0];
                    st_wl_addr = ot[ST_WA_W-1:0];
                    st_wl_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    st_wl_en = 1'b0;
                end
        end
    endtask

    // ---- depthwise: bank = channel within group, address = group ----------
    task automatic fill_dw_weights(input integer off, input integer nbytes,
                                   input integer pchan);
        integer g, m, i, ch, n_grp, nt;
        begin
            nt    = nbytes / pchan;          // 9
            n_grp = (pchan + TC - 1) / TC;
            for (g = 0; g < n_grp; g++)
                for (m = 0; m < TC; m++) begin
                    @(negedge clock);
                    ch = g*TC + m;
                    for (i = 0; i < nt; i++)
                        dw_wl_data[i*DATA_W +: DATA_W] =
                            (ch < pchan) ? wblob[off + ch*nt + i] : 8'h00;
                    dw_wl_bank = m[DW_BANK_W-1:0];
                    dw_wl_addr = g[DW_WA_W-1:0];
                    dw_wl_en   = 1'b1;
                    @(posedge clock);
                    @(negedge clock);
                    dw_wl_en = 1'b0;
                end
        end
    endtask

    // ---- pointwise: bank = lane, address = oc_tile*n_ic + ic_tile ---------
    // The tail contract: zero wherever the channel does not exist, so padded
    // lanes contribute nothing and padded input channels multiply by zero.
    task automatic fill_pw_weights(input integer off, input integer nbytes,
                                   input integer pchan);
        integer ot, it, m, j, ocx, icx, n_oc, n_ic, ic;
        begin
            ic   = nbytes / pchan;
            n_oc = (pchan + TM - 1) / TM;
            n_ic = (ic + TN - 1) / TN;
            for (ot = 0; ot < n_oc; ot++)
                for (it = 0; it < n_ic; it++)
                    for (m = 0; m < TM; m++) begin
                        @(negedge clock);
                        ocx = ot*TM + m;
                        for (j = 0; j < TN; j++) begin
                            icx = it*TN + j;
                            pw_wl_data[j*DATA_W +: DATA_W] =
                                (ocx < pchan && icx < ic)
                                    ? wblob[off + ocx*ic + icx] : 8'h00;
                        end
                        pw_wl_bank = m[BANK_W-1:0];
                        pw_wl_addr = (ot*n_ic + it);
                        pw_wl_en   = 1'b1;
                        @(posedge clock);
                        @(negedge clock);
                        pw_wl_en = 1'b0;
                    end
        end
    endtask

    // ---- the shared parameter banks ---------------------------------------
    // The blob already carries the padding to a whole TM-channel tile, so this
    // is a straight copy: bank = ch % TM, address = ch / TM.
    task automatic fill_params(input integer pchan);
        integer ch, npad;
        begin
            npad = ((pchan + TM - 1) / TM) * TM;
            for (ch = 0; ch < npad; ch++) begin
                @(negedge clock);
                pl_bank  = ch % TM;
                pl_addr  = ch / TM;
                pl_bias  = pb_blob[pidx + ch];
                pl_m0    = pm_blob[pidx + ch];
                pl_shift = ps_blob[pidx + ch][SHIFT_W-1:0];
                pl_en    = 1'b1;
                @(posedge clock);
                @(negedge clock);
                pl_en = 1'b0;
            end
        end
    endtask

    // ---- the classifier's four classes go to logit_out instead ------------
    task automatic fill_logit_params(input integer pchan);
        integer i;
        begin
            for (i = 0; i < NLOG; i++) begin
                @(negedge clock);
                lg_pl_idx   = i[IDX_W-1:0];
                lg_pl_bias  = pb_blob[pidx + i];
                lg_pl_m0    = pm_blob[pidx + i];
                lg_pl_shift = ps_blob[pidx + i][SHIFT_W-1:0];
                lg_pl_en    = 1'b1;
                @(posedge clock);
                @(negedge clock);
                lg_pl_en = 1'b0;
            end
        end
    endtask

    task automatic serve_load;
        integer npad;
        begin
            case (u_dut.op_code)
                OP_STEM:   fill_stem_weights(ld_off, ld_bytes, ld_pchan);
                OP_DW:     fill_dw_weights  (ld_off, ld_bytes, ld_pchan);
                OP_PW,
                OP_LINEAR: fill_pw_weights  (ld_off, ld_bytes, ld_pchan);
                default:   ;      // RES_ADD and GAP carry no weights
            endcase

            if (u_dut.op_code == OP_LINEAR) fill_logit_params(ld_pchan);
            else                            fill_params(ld_pchan);

            // the blob is sequential: advance by a whole tile either way
            npad = ((ld_pchan + TM - 1) / TM) * TM;
            pidx = pidx + npad;
            ld_count++;
        end
    endtask

    initial begin : dma
        ld_done = 1'b0;
        forever begin
            @(posedge clock);
            if (ld_req === 1'b1 && ld_done === 1'b0) begin
                serve_load;
                @(negedge clock);
                ld_done = 1'b1;
                @(posedge clock);
                @(negedge clock);
                ld_done = 1'b0;
            end
        end
    end

    // ======================================================================
    //  checking
    // ======================================================================
    reg [NLOG*LOG_W-1:0] logits_q;
    reg [IDX_W-1:0]      argmax_q;
    reg                  got_logits, got_argmax;

    always @(posedge clock) begin
        if (!rst_n) begin
            got_logits <= 1'b0;
            got_argmax <= 1'b0;
        end else begin
            if (logits_valid) begin logits_q <= logits; got_logits <= 1'b1; end
            if (argmax_valid) begin argmax_q <= argmax; got_argmax <= 1'b1; end
        end
    end

    // Hierarchical reads of the pool take no simulation time, so a whole
    // tensor can be compared inside the gap between two ops.
    task automatic check_op(input integer k);
        integer p, c, oc, npix, n_ent, bad, base;
        reg [TM*DATA_W-1:0] ent;
        reg signed [7:0] got, expd;
        begin
            if (OP_OPCODE[k] == OP_LINEAR) begin
                checked++;
                $display("  [ok ] op %2d LINEAR   : checked after the run", k);
            end else begin
                load_golden(k);
                oc    = OP_OC[k];
                npix  = OP_OH[k]*OP_OW[k];
                n_ent = (oc + TM - 1) / TM;
                base  = u_dut.op_base_out;
                bad   = 0;

                for (p = 0; p < npix; p++)
                    for (c = 0; c < oc; c++) begin
                        ent  = u_dut.u_act.mem[base + p*n_ent + (c/TM)];
                        got  = ent[(c%TM)*DATA_W +: DATA_W];
                        expd = gold_mem[c*npix + p];
                        total++;
                        if (got !== expd) begin
                            bad++;
                            if (bad <= 3)
                                $display("  [ERR] op %0d pix %0d ch %0d : got %0d, golden %0d",
                                         k, p, c, got, expd);
                        end
                    end

                fails += bad;
                checked++;
                if (bad == 0)
                    $display("  [ok ] op %2d %-8s : %7d elements bit-exact  (base=%0d)",
                             k, opname(OP_OPCODE[k]), npix*oc, base);
                else
                    $display("  [ERR] op %2d %-8s : %0d of %0d elements wrong",
                             k, opname(OP_OPCODE[k]), bad, npix*oc);
            end
        end
    endtask

    function automatic string opname(input integer code);
        case (code)
            1: return "STEM";    2: return "PW";     3: return "DW";
            4: return "RES_ADD"; 5: return "GAP";    6: return "LINEAR";
            default: return "?";
        endcase
    endfunction

    // ---- op_busy must pulse exactly ONCE per op --------------------------
    // Not a style check. top_seq leaves S_RUN on the first !busy it sees, so a
    // feeder whose busy dips mid-op makes the sequencer start the next op's
    // weight load on top of a pipeline that is still draining. Four of the five
    // feeders used to do exactly that for one cycle, and pw_feeder exposed its
    // address generator's busy, which stops a full pipeline depth early. Both
    // are fixed (DD-017); this counts the edges so they stay fixed.
    integer busy_pulses = 0, started = 0, ended = 0;
    reg     was_busy;

    // ---- how long the hardware actually computes --------------------------
    // busy_cycles is the number the cycle model in docs/controller_design.md
    // predicts: time a feeder is working. run_cycles also counts the gaps, and
    // those are dominated by THIS TESTBENCH acting as the DMA two cycles per
    // bank word - a real DMA is wider and would overlap with compute - so
    // run_cycles is an upper bound on a system that does not exist yet, not a
    // measurement of the accelerator.
    integer busy_cycles = 0, run_cycles = 0;
    always @(posedge clock) begin
        if (rst_n && running) begin
            run_cycles++;
            if (u_dut.op_busy) busy_cycles++;
        end
    end

    always @(posedge clock) begin
        if (rst_n && u_dut.op_start) begin
            if (u_dut.op_busy) begin
                fails++;
                $display("  [ERR] op %0d started while the previous one was still busy",
                         started);
            end
            started++;
        end
    end

    always @(posedge clock) begin
        if (!rst_n) was_busy <= 1'b0;
        else begin
            was_busy <= u_dut.op_busy;
            if (!was_busy && u_dut.op_busy) busy_pulses++;
            if (was_busy && !u_dut.op_busy && running) begin
                check_op(ended);
                ended++;
            end
        end
    end

    // ======================================================================
    integer i, y, x, c0, bad_log;
    logic signed [15:0] got_l, exp_l;
    initial begin
        load_op_table;

        $readmemh("../../software/export/program.hex",           prog);
        $readmemh("../../software/golden/image_1/000_input.hex", img_mem);
        $readmemh("../../software/export/weights.hex",           wblob);
        $readmemh("../../software/export/params_b.hex",          pb_blob);
        $readmemh("../../software/export/params_m0.hex",         pm_blob);
        $readmemh("../../software/export/params_shift.hex",      ps_blob);
        $readmemh("../../software/golden/image_1/065_classifier_1_logits_int16.hex",
                  gold_log);

        start = 0; n_instr = 0;
        pg_en = 0; pg_addr = 0; pg_data = 0;
        im_wr_en = 0; im_wr_addr = 0; im_wr_data = 0;
        pw_wl_en = 0; pw_wl_bank = 0; pw_wl_addr = 0; pw_wl_data = 0;
        dw_wl_en = 0; dw_wl_bank = 0; dw_wl_addr = 0; dw_wl_data = 0;
        st_wl_en = 0; st_wl_bank = 0; st_wl_addr = 0; st_wl_data = 0;
        pl_en = 0; pl_bank = 0; pl_addr = 0; pl_bias = 0; pl_m0 = 0; pl_shift = 0;
        lg_pl_en = 0; lg_pl_idx = 0; lg_pl_bias = 0; lg_pl_m0 = 0; lg_pl_shift = 0;
        rst_n = 0;
        repeat (4) @(negedge clock);
        rst_n = 1;

        $display("INTEGRATION: accel_top running the whole network");
        $display("  %0d instructions, one image in, %0d logits out", N_OPS, NLOG);
        $display("  one out_stage, one act_buffer, one parameter bank, six feeders");
        $display("");

        // ---- the program ---------------------------------------------
        for (i = 0; i < 8*N_OPS; i++) begin
            @(negedge clock);
            pg_addr = i[PGA_W-1:0];
            pg_data = prog[i];
            pg_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            pg_en = 1'b0;
        end
        $display("loaded %0d program words", 8*N_OPS);

        // ---- the image -----------------------------------------------
        for (y = 0; y < IH; y++) begin
            for (x = 0; x < IW; x++) begin
                @(negedge clock);
                for (c0 = 0; c0 < CIN; c0++)
                    im_wr_data[c0*DATA_W +: DATA_W] = img_mem[(c0*IH + y)*IW + x];
                im_wr_addr = y*IW + x;
                im_wr_en   = 1'b1;
                @(posedge clock);
                @(negedge clock);
                im_wr_en = 1'b0;
            end
        end
        $display("loaded the %0dx%0d image", IH, IW);
        $display("");

        // ---- go -------------------------------------------------------
        n_instr = N_OPS[NI_W-1:0];
        @(negedge clock);
        start = 1'b1;
        @(negedge clock);
        start = 1'b0;

        $display("running:");
        wait (done === 1'b1);
        @(negedge clock);

        // ---- the classifier -------------------------------------------
        $display("");
        $display("the answer:");
        bad_log = 0;
        if (!got_logits) begin
            fails++;
            $display("  [ERR] logits_valid never pulsed");
        end else begin
            for (i = 0; i < NLOG; i++) begin
                got_l = logits_q[i*LOG_W +: LOG_W];
                exp_l = gold_log[i];
                total++;
                if (got_l !== exp_l) begin
                    bad_log++;
                    $display("  [ERR] logit %0d : got %0d, golden %0d", i, got_l, exp_l);
                end
            end
            fails += bad_log;
            if (bad_log == 0)
                $display("  [ok ] logits  %0d %0d %0d %0d  bit-exact",
                         $signed(logits_q[0*LOG_W +: LOG_W]),
                         $signed(logits_q[1*LOG_W +: LOG_W]),
                         $signed(logits_q[2*LOG_W +: LOG_W]),
                         $signed(logits_q[3*LOG_W +: LOG_W]));
        end

        if (!got_argmax) begin
            fails++;
            $display("  [ERR] argmax_valid never pulsed");
        end else if (argmax_q !== 2'd1) begin
            fails++;
            $display("  [ERR] predicted class %0d, golden 1 (esca)", argmax_q);
        end else
            $display("  [ok ] predicted class 1 = esca, as the software model");

        // ---- structure -------------------------------------------------
        $display("");
        if (tag_error) begin
            fails++;
            $display("  [ERR] pw_out's tag self-check tripped");
        end else
            $display("  [ok ] no tag error: the pointwise pipelines stayed in step");

        if (started !== N_OPS) begin
            fails++;
            $display("  [ERR] %0d ops started, expected %0d", started, N_OPS);
        end else
            $display("  [ok ] all %0d ops started, none overlapping", N_OPS);

        if (ld_count !== N_OPS) begin
            fails++;
            $display("  [ERR] the DMA was asked %0d times, expected %0d", ld_count, N_OPS);
        end else
            $display("  [ok ] every op waited for its weights (%0d loads)", ld_count);

        if (busy_pulses !== N_OPS) begin
            fails++;
            $display("  [ERR] op_busy pulsed %0d times for %0d ops - a feeder's busy dips mid-op",
                     busy_pulses, N_OPS);
        end else
            $display("  [ok ] op_busy pulsed exactly once per op (%0d)", busy_pulses);

        if (checked !== N_OPS) begin
            fails++;
            $display("  [ERR] only %0d of %0d ops were checked", checked, N_OPS);
        end

        $display("");
        $display("cycles:");
        $display("  feeders busy : %0d cycles = %0.3f ms at 250 MHz", busy_cycles,
                 busy_cycles / 250000.0);
        $display("  start to done: %0d cycles  (includes this testbench's DMA, which",
                 run_cycles);
        $display("                 is not the hardware - see the note in the source)");

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model, %0d ops, one whole inference)",
                     total, N_OPS);
        else
            $display("FAILED    (%0d mismatches out of %0d)", fails, total);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAILED    (timeout)");
        $finish;
    end

endmodule
