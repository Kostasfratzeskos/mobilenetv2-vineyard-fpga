`timescale 1ns / 1ps
//============================================================================
//  top_seq_tb.sv  -  self-checking testbench for rtl/control/top_seq.v
//
//  Driven by the REAL program: software/export/program.hex, the 64 instructions
//  gen_program.py compiles from manifest.json. That matters more than synthetic
//  stimulus would, because the thing most likely to be wrong about a decoder is
//  that it disagrees with the encoder, and this is the encoder's actual output.
//
//  Two oracles, as everywhere:
//    1. the testbench decodes each instruction from its OWN copy of the program
//       with its own field extraction, and every output of the DUT is compared
//       against it at the moment the op is issued; and
//    2. the op sequence is checked against what the network is known to
//       contain - 64 instructions, 34 PW, 17 DW, 1 STEM, 10 RES_ADD, 1 GAP,
//       1 LINEAR - so a decoder that read plausible garbage would still fail.
//
//  The feeders and the DMA are stubs here, on purpose: this is a control unit
//  and its own logic is what is under test. The stub feeder takes a varying
//  number of cycles to finish, which is what exercises the two-state busy
//  handshake; the stub DMA answers ld_req after a varying delay.
//
//  Run:  bash scripts/run_sim.sh top_seq
//============================================================================
module top_seq_tb;

    localparam PW_W  = 32;
    localparam PGA_W = 9;
    localparam PROG  = 512;
    localparam NI_W  = 8;
    localparam GAP   = 4;

    localparam N_INSTR = 64;

    localparam OP_STEM = 4'h1, OP_PW = 4'h2, OP_DW = 4'h3,
               OP_RES  = 4'h4, OP_GAP = 4'h5, OP_LIN = 4'h6;

    logic clock, rst_n;
    logic             start;
    logic [NI_W-1:0]  n_instr;
    logic             pg_en;
    logic [PGA_W-1:0] pg_addr;
    logic [PW_W-1:0]  pg_data;

    wire              ld_req;
    wire [23:0]       ld_off;
    wire [19:0]       ld_bytes;
    wire [15:0]       ld_pchan;
    logic             ld_done;

    wire              op_start;
    wire [3:0]        op_code;
    wire [7:0]        op_img_w, op_img_h;
    wire              op_stride2, op_act;
    wire signed [7:0] op_qmax;
    wire [15:0]       op_n_pix;
    wire [7:0]        op_n_oc, op_n_ic, op_n_grp, op_n_ent_in, op_n_ent_out;
    wire [15:0]       op_base_in, op_base_out, op_base_saved;
    logic             op_busy;
    wire [NI_W-1:0]   pc;
    wire              running, done;

    top_seq #(.PW_W(PW_W), .PGA_W(PGA_W), .PROG_DEPTH(PROG),
              .NI_W(NI_W), .GAP_CYC(GAP)) u_dut (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_instr(n_instr),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .ld_req(ld_req), .ld_off(ld_off), .ld_bytes(ld_bytes),
        .ld_pchan(ld_pchan), .ld_done(ld_done),
        .op_start(op_start), .op_code(op_code),
        .op_img_w(op_img_w), .op_img_h(op_img_h),
        .op_stride2(op_stride2), .op_act(op_act), .op_qmax(op_qmax),
        .op_n_pix(op_n_pix), .op_n_oc(op_n_oc), .op_n_ic(op_n_ic),
        .op_n_grp(op_n_grp), .op_n_ent_in(op_n_ent_in), .op_n_ent_out(op_n_ent_out),
        .op_base_in(op_base_in), .op_base_out(op_base_out),
        .op_base_saved(op_base_saved),
        .op_busy(op_busy),
        .pc(pc), .running(running), .done(done)
    );

    initial clock = 1'b0;
    always #5 clock = ~clock;

    // ---- the testbench's own copy of the program -------------------------
    reg [31:0] prog [0:PROG-1];

    integer fails = 0, issued = 0;
    integer cnt_stem, cnt_pw, cnt_dw, cnt_res, cnt_gap, cnt_lin;

    // ---- protocol state: checking the ORDER, not just the fields ---------
    //  Two mutations passed a field-only check: starting an op without waiting
    //  for ld_done, and a busy handshake that falls straight through. Both are
    //  invisible unless the testbench tracks what happened BETWEEN op_starts.
    integer ld_seen, saw_busy;

    // ---- oracle 1: independent field extraction --------------------------
    task automatic check_issue(input integer k);
        logic [31:0] a, b, c, d, e, f, g, h;
        begin
            a = prog[k*8+0]; b = prog[k*8+1]; c = prog[k*8+2]; d = prog[k*8+3];
            e = prog[k*8+4]; f = prog[k*8+5]; g = prog[k*8+6]; h = prog[k*8+7];

            if (op_code      !== a[3:0])    begin fails++; $display("  [ERR] op %0d: opcode %0h != %0h", k, op_code, a[3:0]); end
            if (op_img_w     !== a[11:4])   begin fails++; $display("  [ERR] op %0d: img_w", k);   end
            if (op_img_h     !== a[19:12])  begin fails++; $display("  [ERR] op %0d: img_h", k);   end
            if (op_stride2   !== a[20])     begin fails++; $display("  [ERR] op %0d: stride2", k); end
            if (op_act       !== a[21])     begin fails++; $display("  [ERR] op %0d: act", k);     end
            if (op_qmax      !== a[31:24])  begin fails++; $display("  [ERR] op %0d: qmax", k);    end
            if (op_n_pix     !== b[15:0])   begin fails++; $display("  [ERR] op %0d: n_pix %0d != %0d", k, op_n_pix, b[15:0]); end
            if (op_n_oc      !== b[23:16])  begin fails++; $display("  [ERR] op %0d: n_oc", k);    end
            if (op_n_ic      !== b[31:24])  begin fails++; $display("  [ERR] op %0d: n_ic", k);    end
            if (op_n_grp     !== c[7:0])    begin fails++; $display("  [ERR] op %0d: n_grp", k);   end
            if (op_n_ent_in  !== c[15:8])   begin fails++; $display("  [ERR] op %0d: n_ent_in", k); end
            if (op_n_ent_out !== c[23:16])  begin fails++; $display("  [ERR] op %0d: n_ent_out", k); end
            if (op_base_in   !== d[15:0])   begin fails++; $display("  [ERR] op %0d: base_in %0d != %0d", k, op_base_in, d[15:0]); end
            if (op_base_out  !== d[31:16])  begin fails++; $display("  [ERR] op %0d: base_out %0d != %0d", k, op_base_out, d[31:16]); end
            if (op_base_saved!== e[15:0])   begin fails++; $display("  [ERR] op %0d: base_saved", k); end
            if (ld_off       !== f[23:0])   begin fails++; $display("  [ERR] op %0d: wgt_off", k);  end
            if (ld_bytes     !== g[19:0])   begin fails++; $display("  [ERR] op %0d: wgt_bytes", k); end
            if (ld_pchan     !== h[15:0])   begin fails++; $display("  [ERR] op %0d: pchan", k);    end

            if (pc !== k[NI_W-1:0]) begin
                fails++;
                $display("  [ERR] op %0d issued with pc=%0d", k, pc);
            end

            // the DMA must have answered before an op that needs weights or
            // parameters is allowed to start
            if ((g[19:0] != 20'd0 || h[15:0] != 16'd0) && ld_seen == 0) begin
                fails++;
                $display("  [ERR] op %0d started without waiting for ld_done", k);
            end
            // and the PREVIOUS op must actually have run to completion:
            // it must have gone busy at all, AND must no longer be busy now
            if (k > 0 && saw_busy == 0) begin
                fails++;
                $display("  [ERR] op %0d started but op %0d never went busy", k, k-1);
            end
            if (k > 0 && op_busy) begin
                fails++;
                $display("  [ERR] op %0d started while op %0d was still busy", k, k-1);
            end
            ld_seen  = 0;
            saw_busy = 0;

            case (op_code)
                OP_STEM: cnt_stem++;
                OP_PW:   cnt_pw++;
                OP_DW:   cnt_dw++;
                OP_RES:  cnt_res++;
                OP_GAP:  cnt_gap++;
                OP_LIN:  cnt_lin++;
                default: begin
                    fails++;
                    $display("  [ERR] op %0d: unknown opcode %0h", k, op_code);
                end
            endcase
            issued++;
        end
    endtask

    always @(negedge clock) begin
        if (ld_done) ld_seen  = 1;
        if (op_busy) saw_busy = 1;
        if (op_start) check_issue(issued);
    end

    // ---- stub feeder -----------------------------------------------------
    //  Two things vary, and both matter:
    //    the LATENCY before busy rises (1..3 cycles). Every feeder built so far
    //    raises it exactly one cycle after start, which makes the two-state
    //    busy handshake look redundant - S_RUN alone would catch a 1-cycle
    //    feeder. The contract top_seq documents is "any number of cycles", so
    //    the stub takes longer sometimes, and that is what makes S_WAIT load
    //    bearing rather than decorative;
    //    the DURATION (5..29 cycles), long enough that a sequencer which did
    //    not wait would issue the next op while this one was still busy.
    integer stub, arm;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            arm <= 0; stub <= 0;
        end else if (op_start) begin
            arm  <= 1 + (issued % 3);
            stub <= 0;
        end else if (arm != 0) begin
            if (arm == 1) stub <= 5 + (issued % 25);
            arm <= arm - 1;
        end else if (stub != 0) begin
            stub <= stub - 1;
        end
    end
    always @* op_busy = (stub != 0);

    // ---- stub DMA: answers ld_req after a varying delay ------------------
    integer dma;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin dma <= 0; ld_done <= 1'b0; end
        else begin
            ld_done <= 1'b0;
            if (ld_req && dma == 0 && !ld_done) dma <= 1 + (issued % 5);
            else if (dma > 1) dma <= dma - 1;
            else if (dma == 1) begin dma <= 0; ld_done <= 1'b1; end
        end
    end

    integer k, guard;
    initial begin
        $readmemh("../../software/export/program.hex", prog);
        for (k = 0; k < PROG; k++) if (prog[k] === 32'hx) prog[k] = 32'h0;

        start = 0; n_instr = 0; pg_en = 0; pg_addr = 0; pg_data = 0;
        ld_done = 0; op_busy = 0;
        ld_seen = 0; saw_busy = 0; arm = 0; stub = 0;
        cnt_stem = 0; cnt_pw = 0; cnt_dw = 0; cnt_res = 0; cnt_gap = 0; cnt_lin = 0;
        rst_n = 0;
        repeat (3) @(negedge clock);
        rst_n = 1;

        $display("top_seq: executing the real program from software/export/program.hex");
        $display("");

        // ---- load the program ------------------------------------------
        for (k = 0; k < N_INSTR*8; k++) begin
            @(negedge clock);
            pg_addr = k[PGA_W-1:0];
            pg_data = prog[k];
            pg_en   = 1'b1;
            @(posedge clock);
            @(negedge clock);
            pg_en = 1'b0;
        end
        $display("loaded %0d instructions (%0d words)", N_INSTR, N_INSTR*8);

        // ---- run ---------------------------------------------------------
        @(negedge clock);
        n_instr = N_INSTR[NI_W-1:0];
        start   = 1'b1;
        @(negedge clock);
        start = 1'b0;

        guard = 200000;
        while (!done && guard > 0) begin
            @(negedge clock);
            guard--;
        end

        $display("");
        if (guard <= 0) begin
            fails++;
            $display("  [ERR] the program never finished (stuck at pc=%0d)", pc);
        end

        // ---- oracle 2: the op mix the network is known to have ----------
        $display("issued %0d instructions:", issued);
        $display("    STEM %0d   PW %0d   DW %0d   RES_ADD %0d   GAP %0d   LINEAR %0d",
                 cnt_stem, cnt_pw, cnt_dw, cnt_res, cnt_gap, cnt_lin);
        if (issued !== N_INSTR) begin
            fails++;
            $display("  [ERR] issued %0d, expected %0d", issued, N_INSTR);
        end
        if (cnt_stem !== 1)  begin fails++; $display("  [ERR] STEM count"); end
        if (cnt_pw   !== 34) begin fails++; $display("  [ERR] PW count");   end
        if (cnt_dw   !== 17) begin fails++; $display("  [ERR] DW count");   end
        if (cnt_res  !== 10) begin fails++; $display("  [ERR] RES count");  end
        if (cnt_gap  !== 1)  begin fails++; $display("  [ERR] GAP count");  end
        if (cnt_lin  !== 1)  begin fails++; $display("  [ERR] LINEAR count"); end
        if (running !== 1'b0) begin fails++; $display("  [ERR] still running after done"); end
        if (saw_busy == 0) begin
            fails++;
            $display("  [ERR] the last op never went busy");
        end

        $display("");
        if (fails == 0)
            $display("ALL PASS  (%0d instructions, %0d fields each, decoded and sequenced)",
                     issued, 18);
        else
            $display("FAILED    (%0d errors)", fails);
        $finish;
    end

endmodule
