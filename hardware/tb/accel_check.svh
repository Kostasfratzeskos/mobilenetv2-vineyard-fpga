//============================================================================
//  accel_check.svh  -  the golden checking shared by accel_tb and accel_dma_tb
//
//  accel_tb and accel_dma_tb run the SAME program against the SAME goldens and
//  differ only in who answers `ld_req`: a testbench task in one, real hardware
//  behind an AXI4 slave model in the other. The pass criterion has to be
//  identical for the comparison to mean anything, so it lives in one file
//  rather than being copied - program_ops.svh is the precedent, and the reason
//  is the same one stated there: a hand-copied second source of truth silently
//  stops matching the first.
//
//  ---- how to include it -------------------------------------------------
//
//  Define `ACCEL_DUT to the hierarchical path of the accel_top instance, then
//  include this AFTER program_ops.svh (which declares the op table and
//  load_golden) and after N_OPS:
//
//      `define ACCEL_DUT u_dut            // accel_tb
//      `define ACCEL_DUT u_sys.u_dut      // accel_dma_tb
//
//  Define `ACCEL_TB_DMA if the testbench itself is playing the DMA, which only
//  changes what the cycle report says about the numbers it prints.
//
//  It expects these to exist in the including module: clock, rst_n, logits,
//  logits_valid, argmax, argmax_valid, tag_error, fault, gold_mem, gold_log,
//  and the localparams N_OPS, NLOG, LOG_W, IDX_W, TM, DATA_W.
//
//  ---- what it checks, and why each one is here ---------------------------
//
//   * every element of every intermediate tensor, hierarchically out of the
//     activation pool, against the software golden. Every element and not a
//     sample, because too short a drain window destroys the TAIL of a layer and
//     nothing else would notice.
//   * the four logits and the predicted class.
//   * op_busy pulses exactly ONCE per op. Not a style check: top_seq leaves
//     S_RUN on the first !busy it sees, so a feeder whose busy dips mid-op
//     makes the sequencer start the next op's weight load on top of a pipeline
//     that is still draining. Four of five feeders used to do that (DD-017).
//   * no op starts while the previous one is busy.
//   * `fault` and `tag_error` are clear. Both are meant to be silent on a
//     healthy run, and a check that is only ever silent is one nobody notices
//     has stopped working.
//   * the DMA was asked exactly N_OPS times. Counted from ld_done RISING while
//     ld_req is high - which is top_seq's own edge rule (T-10), so this counts
//     completed loads the way the sequencer does, whoever is answering.
//============================================================================

    // ---- the verdict -------------------------------------------------------
    integer total = 0, fails = 0, checked = 0, ld_count = 0;

    // ---- completed loads, counted the way top_seq counts them -------------
    reg ld_done_q;
    always @(posedge clock) begin
        if (!rst_n) ld_done_q <= 1'b0;
        else begin
            ld_done_q <= `ACCEL_DUT.ld_done;
            if (`ACCEL_DUT.ld_done && !ld_done_q && `ACCEL_DUT.ld_req)
                ld_count <= ld_count + 1;
        end
    end

    // ---- the answer, latched when it appears -------------------------------
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

    function automatic string opname(input integer code);
        case (code)
            1: return "STEM";    2: return "PW";     3: return "DW";
            4: return "RES_ADD"; 5: return "GAP";    6: return "LINEAR";
            default: return "?";
        endcase
    endfunction

    // Hierarchical reads of the pool take no simulation time, so a whole tensor
    // can be compared inside the gap between two ops.
    task automatic check_op(input integer k);
        integer p, c, oc, npix, n_ent, bad, base;
        reg [TM*DATA_W-1:0] ent;
        reg signed [7:0] got, expd;
        begin
            if (OP_OPCODE[k] == 6) begin          // LINEAR writes no tensor
                checked++;
                $display("  [ok ] op %2d LINEAR   : checked after the run", k);
            end else begin
                load_golden(k);
                oc    = OP_OC[k];
                npix  = OP_OH[k]*OP_OW[k];
                n_ent = (oc + TM - 1) / TM;
                base  = `ACCEL_DUT.op_base_out;
                bad   = 0;

                for (p = 0; p < npix; p++)
                    for (c = 0; c < oc; c++) begin
                        ent  = `ACCEL_DUT.u_act.mem[base + p*n_ent + (c/TM)];
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

    // ---- the structural monitors ------------------------------------------
    integer busy_pulses = 0, started = 0, ended = 0;
    reg     was_busy;

    integer busy_cycles = 0, run_cycles = 0;
    always @(posedge clock) begin
        if (rst_n && running) begin
            run_cycles++;
            if (`ACCEL_DUT.op_busy) busy_cycles++;
        end
    end

    always @(posedge clock) begin
        if (rst_n && `ACCEL_DUT.op_start) begin
            if (`ACCEL_DUT.op_busy) begin
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
            was_busy <= `ACCEL_DUT.op_busy;
            if (!was_busy && `ACCEL_DUT.op_busy) busy_pulses++;
            if (was_busy && !`ACCEL_DUT.op_busy && running) begin
                check_op(ended);
                ended++;
            end
        end
    end

    // ======================================================================
    //  the report, called once after `done`
    // ======================================================================
    task automatic report_tail;
        integer i, bad_log;
        logic signed [15:0] got_l, exp_l;
        begin
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
            end else if (argmax_q !== GOLDEN_ARGMAX[IDX_W-1:0]) begin
                fails++;
                $display("  [ERR] predicted class %0d, golden %0d (%s)",
                         argmax_q, GOLDEN_ARGMAX, GOLDEN_CLASS);
            end else
                $display("  [ok ] predicted class %0d = %s, as the software model",
                         argmax_q, GOLDEN_CLASS);

            // ---- structure -------------------------------------------------
            $display("");
            if (tag_error) begin
                fails++;
                $display("  [ERR] pw_out's tag self-check tripped");
            end else
                $display("  [ok ] no tag error: the pointwise pipelines stayed in step");

            if (fault) begin
                fails++;
                $display("  [ERR] top_seq raised `fault`: the run was abandoned (watchdog, bad opcode or n_instr)");
            end else
                $display("  [ok ] no fault: no hang, no undecodable opcode, n_instr in range");

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
`ifdef ACCEL_TB_DMA
            $display("  start to done: %0d cycles  (includes this testbench's DMA, which",
                     run_cycles);
            $display("                 is not the hardware - see the note in the source)");
`else
            $display("  start to done: %0d cycles  (includes the real weight DMA; the fill",
                     run_cycles);
            $display("                 is serial with compute, which is C-11 / DD-029)");
            $display("  load overhead: %0d cycles = %0.1f%% of the run",
                     run_cycles - busy_cycles,
                     100.0 * (run_cycles - busy_cycles) / run_cycles);
`endif
        end
    endtask
