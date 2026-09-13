`timescale 1ns / 1ps
//============================================================================
//  accel_tb.sv  -  INTEGRATION: the whole accelerator, three real ops
//
//  Runs the first three instructions of the REAL compiled program end to end
//  and checks each op's output against the software golden:
//
//      op 0  STEM  features.0.0        224x224x3  -> 112x112x32   golden 001
//      op 1  DW    features.1.conv.0.0 112x112x32 -> 112x112x32   golden 002
//      op 2  PW    features.1.conv.1   112x112x32 -> 112x112x16   golden 003
//
//  The individual datapath testbenches already proved each feeder in isolation.
//  What is new here, and what this file exists to test, is everything BETWEEN
//  them - which is exactly what accel_top adds:
//
//    1. the opcode mux. Three different feeders run back to back through ONE
//       out_stage, one act_buffer and one parameter bank. If the mux selected
//       the wrong source, or an idle feeder's writes reached the pool, the
//       golden check fails.
//    2. the base-address handoff. Nothing tells op 1 where op 0 put its output
//       except gen_program.py's static allocator, through base_in / base_out in
//       the instruction word. The three ops form a chain, so a wrong address is
//       not a silent offset - op 1 reads garbage.
//    3. the drain between ops. top_seq waits for busy to fall and then idles
//       GAP_CYC cycles before the next op_start, which also flushes out_stage.
//       If that window is too short the tail of each op is destroyed - and the
//       tail is the LAST pixels, which a spot check would miss, so every
//       element is compared.
//    4. the load handshake actually feeding hardware. top_seq raises ld_req and
//       this testbench plays the DMA: it fills whichever weight buffer the
//       opcode names, pads the parameter banks to a multiple of TM with zeros
//       (the tail contract - see below), and answers ld_done.
//
//  ---- the parameter tail contract -------------------------------------
//
//  ld_pchan is the real channel count, 16 for op 2. The parameter banks are
//  read a full TM-lane tile at a time, so lanes 16..31 would read banks that
//  were never written - X, not garbage - and X survives being multiplied by
//  the next layer's zero weights. So the DMA rounds up to a multiple of TM and
//  writes zeros past pchan. That is a rule it can apply from ld_pchan alone,
//  which is why the instruction does not need to carry it.
//
//  ---- what this does NOT cover yet ------------------------------------
//
//  Only three of the 64 instructions run. RES_ADD and GAP are not reachable
//  here for a concrete reason rather than convenience: gen_program emits them
//  with wbytes=0 and pchan=0, so top_seq takes its `no_load` path and never
//  asks for their (m0, shift) - which they do need, one value broadcast to
//  every channel. Fixing that is a generator change, not an accel_top change.
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

    localparam N_OPS   = 3;          // STEM -> DW -> PW
    localparam IH = 224, IW = 224;   // the image
    localparam NIN = CIN*IH*IW;      // 150,528
    localparam MAXOUT = 401408;      // 32 x 112 x 112, the biggest golden here
    localparam MAXW   = 1024;        // the biggest weight blob here (864 B)

    // ---- the three ops, in program order ----------------------------------
    // Read straight off gen_program.py's listing. OC and IC are needed because
    // the tail contract is about REAL channels, which the instruction word only
    // carries as tile counts.
    //   k  opcode  OC  IC   OH   OW
    //   0  STEM    32   3   112  112
    //   1  DW      32  32   112  112
    //   2  PW      16  32   112  112
    integer OP_OC [0:N_OPS-1];
    integer OP_IC [0:N_OPS-1];
    integer OP_OH [0:N_OPS-1];
    integer OP_OW [0:N_OPS-1];

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
    reg [7:0]  wq_mem   [0:MAXW-1];
    reg signed [31:0] b_mem  [0:TM-1];
    reg signed [31:0] m0_mem [0:TM-1];
    reg [31:0]        sh_mem [0:TM-1];

    integer total = 0, fails = 0, checked = 0;

    // ======================================================================
    //  the testbench as DMA
    // ======================================================================
    task automatic load_files(input integer k);
        begin
            case (k)
            0: begin
                $readmemh("../../software/export/features_0_0_w.hex",     wq_mem);
                $readmemh("../../software/export/features_0_0_b.hex",     b_mem);
                $readmemh("../../software/export/features_0_0_m0.hex",    m0_mem);
                $readmemh("../../software/export/features_0_0_shift.hex", sh_mem);
            end
            1: begin
                $readmemh("../../software/export/features_1_conv_0_0_w.hex",     wq_mem);
                $readmemh("../../software/export/features_1_conv_0_0_b.hex",     b_mem);
                $readmemh("../../software/export/features_1_conv_0_0_m0.hex",    m0_mem);
                $readmemh("../../software/export/features_1_conv_0_0_shift.hex", sh_mem);
            end
            2: begin
                $readmemh("../../software/export/features_1_conv_1_w.hex",     wq_mem);
                $readmemh("../../software/export/features_1_conv_1_b.hex",     b_mem);
                $readmemh("../../software/export/features_1_conv_1_m0.hex",    m0_mem);
                $readmemh("../../software/export/features_1_conv_1_shift.hex", sh_mem);
            end
            endcase
        end
    endtask

    // ---- stem: bank = lane within the tile, address = oc_tile -------------
    task automatic fill_stem_weights(input integer oc);
        integer ot, m, i, ocx, n_oct, nt;
        begin
            nt    = CIN*K*K;                 // 27 bytes per output channel
            n_oct = (oc + TS - 1) / TS;
            for (ot = 0; ot < n_oct; ot++)
                for (m = 0; m < TS; m++) begin
                    @(negedge clock);
                    ocx = ot*TS + m;
                    for (i = 0; i < nt; i++)
                        st_wl_data[i*DATA_W +: DATA_W] =
                            (ocx < oc) ? wq_mem[ocx*nt + i] : 8'h00;
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
    task automatic fill_dw_weights(input integer c);
        integer g, m, i, ch, n_grp, nt;
        begin
            nt    = K*K;
            n_grp = (c + TC - 1) / TC;
            for (g = 0; g < n_grp; g++)
                for (m = 0; m < TC; m++) begin
                    @(negedge clock);
                    ch = g*TC + m;
                    for (i = 0; i < nt; i++)
                        dw_wl_data[i*DATA_W +: DATA_W] =
                            (ch < c) ? wq_mem[ch*nt + i] : 8'h00;
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
    task automatic fill_pw_weights(input integer oc, input integer ic);
        integer ot, it, m, j, ocx, icx, n_oc, n_ic;
        begin
            n_oc = (oc + TM - 1) / TM;
            n_ic = (ic + TN - 1) / TN;
            for (ot = 0; ot < n_oc; ot++)
                for (it = 0; it < n_ic; it++)
                    for (m = 0; m < TM; m++) begin
                        @(negedge clock);
                        ocx = ot*TM + m;
                        for (j = 0; j < TN; j++) begin
                            icx = it*TN + j;
                            pw_wl_data[j*DATA_W +: DATA_W] =
                                (ocx < oc && icx < ic) ? wq_mem[ocx*ic + icx] : 8'h00;
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

    // ---- the shared parameter banks, padded to a multiple of TM -----------
    task automatic fill_params(input integer pchan);
        integer ch, npad;
        begin
            npad = ((pchan + TM - 1) / TM) * TM;
            for (ch = 0; ch < npad; ch++) begin
                @(negedge clock);
                pl_bank  = ch % TM;
                pl_addr  = ch / TM;
                pl_bias  = (ch < pchan) ? b_mem[ch]  : 32'sd0;
                pl_m0    = (ch < pchan) ? m0_mem[ch] : 32'sd0;
                pl_shift = (ch < pchan) ? sh_mem[ch][SHIFT_W-1:0] : {SHIFT_W{1'b0}};
                pl_en    = 1'b1;
                @(posedge clock);
                @(negedge clock);
                pl_en = 1'b0;
            end
        end
    endtask

    // ---- one whole load, driven by what the sequencer is asking for -------
    localparam [3:0] OP_STEM = 4'd1, OP_PW = 4'd2, OP_DW = 4'd3,
                     OP_RES  = 4'd4, OP_GAP = 4'd5, OP_LINEAR = 4'd6;

    integer ld_count = 0;

    task automatic serve_load;
        integer k;
        begin
            k = pc;
            load_files(k);
            case (u_dut.op_code)
                OP_STEM: fill_stem_weights(OP_OC[k]);
                OP_DW:   fill_dw_weights(OP_OC[k]);
                OP_PW:   fill_pw_weights(OP_OC[k], OP_IC[k]);
                default: ;
            endcase
            fill_params(ld_pchan);
            ld_count++;
            $display("  [dma] op %0d opcode=%0d : %0d weight bytes, %0d channels",
                     k, u_dut.op_code, ld_bytes, ld_pchan);
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
    //  checking: after each op, compare its whole output against the golden
    //  Hierarchical reads of the pool take no simulation time, so the check
    //  fits inside the GAP window between two ops.
    // ======================================================================
    task automatic load_golden(input integer k);
        begin
            case (k)
            0: $readmemh("../../software/golden/image_1/001_features_0_0.hex",        gold_mem);
            1: $readmemh("../../software/golden/image_1/002_features_1_conv_0_0.hex", gold_mem);
            2: $readmemh("../../software/golden/image_1/003_features_1_conv_1.hex",   gold_mem);
            endcase
        end
    endtask

    task automatic check_op(input integer k);
        integer p, c, oc, npix, n_ent, bad;
        integer base;
        reg [TM*DATA_W-1:0] ent;
        reg signed [7:0] got, expd;
        begin
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
                        if (bad <= 5)
                            $display("  [ERR] op %0d pix %0d ch %0d : got %0d, golden %0d",
                                     k, p, c, got, expd);
                    end
                end

            fails += bad;
            checked++;
            if (bad == 0)
                $display("  [ok ] op %0d : %0d elements bit-exact  (base=%0d, %0d entries/pixel)",
                         k, npix*oc, base, n_ent);
            else
                $display("  [ERR] op %0d : %0d of %0d elements wrong",
                         k, bad, npix*oc);
        end
    endtask

    // ---- ops must not overlap, and the right feeder must run --------------
    integer started = 0, ended = 0;
    reg     was_busy;

    always @(posedge clock) begin
        if (rst_n && u_dut.op_start) begin
            if (u_dut.op_busy)
                begin
                    fails++;
                    $display("  [ERR] op %0d started while the previous one was still busy",
                             started);
                end
            started++;
        end
    end

    // ---- op_busy must pulse exactly ONCE per op --------------------------
    // Not a style check. top_seq leaves S_RUN on the first !busy it sees, so a
    // feeder whose busy dips mid-op makes the sequencer start the next op's
    // weight load on top of a pipeline that is still draining. Four of the five
    // feeders used to do exactly that for one cycle - `drain` is loaded by
    // layer_done, which pulses in the same cycle `run` drops, so busy read low
    // in between - and pw_feeder exposed its address generator's busy, which
    // stops a full pipeline-depth early. Both are fixed; this counts the edges
    // so they stay fixed.
    // The falling edge is also where each op is checked: hierarchical reads of
    // the pool take no simulation time, so the whole comparison fits between
    // this op finishing and the next one starting.
    integer busy_pulses = 0;

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
    integer i, y, x, c0;
    initial begin
        OP_OC[0] = 32; OP_IC[0] =  3; OP_OH[0] = 112; OP_OW[0] = 112;
        OP_OC[1] = 32; OP_IC[1] = 32; OP_OH[1] = 112; OP_OW[1] = 112;
        OP_OC[2] = 16; OP_IC[2] = 32; OP_OH[2] = 112; OP_OW[2] = 112;

        $readmemh("../../software/export/program.hex",           prog);
        $readmemh("../../software/golden/image_1/000_input.hex", img_mem);

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

        $display("INTEGRATION: accel_top running the first %0d instructions of the real program", N_OPS);
        $display("  STEM features.0.0 -> DW features.1.conv.0.0 -> PW features.1.conv.1");
        $display("  one out_stage, one act_buffer, one parameter bank, three feeders");
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
            if ((y + 1) % 64 == 0)
                $display("  ... %0d/%0d image rows loaded", y+1, IH);
        end
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
        if (fails == 0)
            $display("ALL PASS  (%0d elements bit-exact vs the software model, %0d ops chained)",
                     total, N_OPS);
        else
            $display("FAILED    (%0d mismatches out of %0d)", fails, total);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("FAILED    (timeout)");
        $finish;
    end

endmodule
