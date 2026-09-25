`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  top_seq.v  -  the program sequencer
//
//  Build plan #6, the last module. Idea 2 of controller_design.md section 1:
//  a top sequencer reads one instruction per op from program memory and hands
//  its fields to the right sub-controller. The `op_type` enum of the C model
//  became the opcode, so the manifest is most of the program already.
//
//  It executes the 64 instructions scripts/gen_program.py emits from
//  manifest.json - 74 manifest ops, of which the 10 `save` markers fold away
//  because they move no data (they are lifetime annotations for the allocator,
//  not work).
//
//  ---- what it does, and deliberately does not -------------------------
//
//  Does: fetch, decode, request the layer's weights and parameters, start the
//  feeder that owns the opcode, wait for it, leave the drain gap, advance.
//
//  Does NOT contain the DMA. Weight fetching is an AXI master against PS-DDR4,
//  which is a Phase-4 concern; here it is a handshake - `ld_req` with the blob
//  offset, byte count and channel count from the instruction, then wait for
//  `ld_done`. Whoever owns the bus answers it. That is the same boundary
//  act_buffer's fill port draws.
//
//  Does NOT mux the feeders. It presents the decoded fields plus a per-opcode
//  start strobe; the datapath top wires those to the six sub-controllers and
//  returns one `op_busy`. Keeping the mux out of here leaves this module a
//  pure control unit, testable against the real program with a stub feeder.
//
//  ---- the instruction ---------------------------------------------------
//
//  Eight 32-bit words, fetched one per cycle. Density is irrelevant at 64 ops
//  (2 KB either way) so the layout was chosen to be readable in a hex dump.
//  This extraction must track the table in controller_design.md section 9 and
//  the encoder in gen_program.py:
//
//    w0  [3:0] opcode  [11:4] img_w  [19:12] img_h  [20] stride2  [21] act
//        [31:24] relu6_qmax
//    w1  [15:0] n_pix  [23:16] n_oc  [31:24] n_ic
//    w2  [7:0]  n_grp  [15:8] n_ent_in  [23:16] n_ent_out
//    w3  [15:0] base_in   [31:16] base_out
//    w4  [15:0] base_saved
//    w5  [23:0] wgt_off       w6  [19:0] wgt_bytes      w7  [15:0] pchan
//
//  ---- the gap after each op --------------------------------------------
//
//  pw_feeder documents that `layer_done` fires while the last result is still
//  in the pipeline, so a `start` too early destroys it. Every feeder now folds
//  that drain into its own `busy`, but the sequencer still leaves GAP_CYC idle
//  cycles afterwards - it costs 64*4 cycles over the whole network, which is
//  nothing next to reloading the weight buffer between layers anyway.
//
//  ---- the two ways this module used to fail silently (T-1, T-2) ---------
//
//  T-1, the instruction ceiling. `fetch_addr` is {pc, fw}: three bits of word
//  index and the rest instruction index, so it is PGA_W that decides how many
//  instructions can exist - 2**(PGA_W-3) = 64 - while PROG_DEPTH decides how
//  many words the memory holds. This network has EXACTLY 64 instructions, and
//  `n_instr` is eight bits and accepted 255. Instruction 64 fetched instruction
//  0's words and executed it, so one added layer or debug op would have
//  corrupted execution rather than failed to build. Now: an elaboration check
//  ties PGA_W to PROG_DEPTH, a runtime check refuses an out-of-range n_instr,
//  and gen_program.py asserts the same ceiling at build time.
//
//  T-2, the hang. S_WAIT had no escape if `op_busy` never rose and S_LOAD none
//  if `ld_done` never arrived. Three reachable causes: an `op_code` that is one
//  of the ten of sixteen encodings no feeder decodes; a feeder's own zero-shape
//  guard correctly refusing the op, so the defensive behaviour causes the hang;
//  or a DMA that never answers. All three parked with running=1 and `done` never
//  pulsing, recoverable only by reset. `default: st <= S_IDLE` guarded an
//  illegal STATE, which is unreachable, not an illegal OPCODE, which is not.
//  Now: an opcode-validity check at S_GO, one watchdog shared across
//  S_LOAD/S_WAIT/S_RUN, an S_ERR state, and a sticky `fault` output.
//
//  Run:  bash scripts/run_sim.sh top_seq
//============================================================================
module top_seq #(
    parameter PW_W      = 32,     // program word width
    parameter PGA_W     = 9,      // program memory address width (512 words)
    parameter PROG_DEPTH= 512,
    parameter NI_W      = 8,      // instruction-count width
    parameter GAP_CYC   = 4,      // idle cycles after each op
    // Watchdog width. DERIVED, not chosen: the longest legitimate op is the
    // stem, 225*225 input positions plus 4 sweep cycles x 12,544 windows =
    // 100,801 cycles, and the worst weight fill is features.18.0 at
    // 32 banks x 800 entries = 25,600. 2**20 = 1,048,576 is 10.4x the longest
    // op, so it cannot fire on a healthy run; it still bounds a hang to 4.2 ms
    // at 250 MHz instead of forever. Recompute it if a layer ever gets longer.
    parameter WDOG_W    = 20
)(
    input  wire                clock,
    input  wire                rst_n,

    // ---- run control ---------------------------------------------------
    input  wire                start,       // execute the whole program
    input  wire [NI_W-1:0]     n_instr,     // 64 for this network

    // ---- program load ---------------------------------------------------
    input  wire                pg_en,
    input  wire [PGA_W-1:0]    pg_addr,
    input  wire [PW_W-1:0]     pg_data,

    // ---- weight / parameter fetch handshake (the DMA answers) -----------
    //  `ld_op` is the SAME BITS as `op_code` below, and that is deliberate. It
    //  carries no new information; what it adds is that the load handshake's
    //  contract is a GROUP - {ld_op, ld_off, ld_bytes, ld_pchan}, all valid
    //  while `ld_req` is high - instead of a reader having to know that
    //  `op_code` happens to be stable during S_LOAD because `w[]` is not
    //  rewritten until the next S_FETCH.
    //
    //  The DMA cannot do without it and cannot derive it (DD-030). accel_tb
    //  reads `u_dut.op_code` hierarchically; an AXI master at the pin boundary
    //  has no hierarchy to read. And the opcode is not recoverable from the
    //  load fields: taps = ld_bytes/ld_pchan is 1280 for the LINEAR op and
    //  there is no taps value that separates PW from LINEAR - yet those two
    //  send their parameters to DIFFERENT ports, pl_* and lg_pl_*. A DMA
    //  guessing from taps would load the classifier's parameters into the
    //  pointwise banks and produce four plausible wrong logits.
    //
    //  Against finding T-7 ("ld_pchan carries three meanings at once"): this is
    //  the honest way to make meaning (1), the DMA's parameter count, real
    //  without also making it imply the shape and the destination.
    output reg                 ld_req,
    output wire [3:0]          ld_op,       // the opcode, held with ld_req
    output wire [23:0]         ld_off,      // byte offset into the weight blob
    output wire [19:0]         ld_bytes,
    output wire [15:0]         ld_pchan,
    input  wire                ld_done,

    // ---- the decoded instruction, stable while the op runs --------------
    output reg                 op_start,    // one-cycle pulse
    output wire [3:0]          op_code,
    output wire [7:0]          op_img_w,
    output wire [7:0]          op_img_h,
    output wire                op_stride2,
    output wire                op_act,
    output wire signed [7:0]   op_qmax,
    output wire [15:0]         op_n_pix,
    output wire [7:0]          op_n_oc,
    output wire [7:0]          op_n_ic,
    output wire [7:0]          op_n_grp,
    output wire [7:0]          op_n_ent_in,
    output wire [7:0]          op_n_ent_out,
    output wire [15:0]         op_base_in,
    output wire [15:0]         op_base_out,
    output wire [15:0]         op_base_saved,

    // ---- from whichever feeder is running --------------------------------
    input  wire                op_busy,

    // A feeder's own self-check says its result is in the wrong place (T-3).
    // Today that is pw_out's (pix, oct) tag comparator, which is the only
    // witness of its kind in the design; its verdict used to reach a top-level
    // pin and nothing else, so a drift completed the run and produced a
    // confident wrong answer. Terminating is the only combination with
    // "detect" that is worth anything.
    input  wire                op_error,

    output reg  [NI_W-1:0]     pc,          // instruction index, for debug
    output reg                 running,
    output reg                 done,        // pulses when the program ends
    output reg                 fault        // sticky: the run was abandoned
);

    // ---- T-1: PGA_W and PROG_DEPTH must agree --------------------------
    // Verilog-2001 has no $fatal at elaboration, so the check is a generate
    // that instantiates a module which does not exist. Elaboration then fails
    // and the tool prints the module name, which IS the error message.
    generate
        if (PROG_DEPTH != (1 << PGA_W)) begin : chk_prog_depth
            ERROR_PROG_DEPTH_MUST_EQUAL_TWO_POW_PGA_W u_err();
        end
    endgenerate

    // Eight words per instruction, so the instruction index occupies the top
    // PGA_W-3 bits of the program address. MAX_INSTR is the real ceiling that
    // T-1 is about - not a comment about one, a localparam the RTL uses.
    localparam PGI_W     = PGA_W - 3;          // instruction-index bits (6)
    localparam MAX_INSTR = 1 << PGI_W;         // 64

    // ---- program memory --------------------------------------------------
    reg [PW_W-1:0] prog [0:PROG_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < PROG_DEPTH; i = i + 1) prog[i] = {PW_W{1'b0}};
    end

    //  T-10: the program is NOT writable while running. It used to be, which
    //  means a host write landing mid-inference could change an instruction this
    //  sequencer had already fetched, or one it was about to - and the symptom
    //  would be an output tensor, not an error. The guard costs one AND gate.
    //
    //  This is a real behavioural change, not just a check: a write attempted
    //  while running is now DROPPED rather than applied. That is the safe
    //  direction - silently ignoring a write the host should not have made beats
    //  silently honouring it - and the simulation check below says so by name so
    //  the drop is never invisible during bring-up.
    always @(posedge clock)
        if (pg_en && !running) prog[pg_addr] <= pg_data;

`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (rst_n && pg_en && running)
            $display("[FAULT] %m T-10 program write to address %0d attempted while running at time %0t. It was DROPPED. The program memory is read-only between `start` and `done`.",
                     pg_addr, $time);
    end
`endif

    // ---- T-10: ld_done is EDGE detected ---------------------------------
    //  `ld_done` is a handshake from a DMA that does not exist yet, so this
    //  module's contract for it will be written AFTER the code that depends on
    //  it - which is exactly the situation where a level-sensitive read is a
    //  trap. Read as a level, a `ld_done` left asserted from the previous load
    //  completes the next one two cycles after S_LOAD is entered, with no data
    //  moved and nothing to say so; the weights for that layer are then whatever
    //  the previous layer left in the buffer, and the output is a plausible
    //  feature map.
    //
    //  Requiring a RISING edge while `ld_req` is asserted means a stuck-high
    //  `ld_done` produces a HANG instead, which T-2's watchdog already catches
    //  and reports as a fault. Turning a silent wrong answer into a loud stop is
    //  the whole trade.
    reg ld_done_q;

    always @(posedge clock) begin
        if (!rst_n) ld_done_q <= 1'b0;
        else        ld_done_q <= ld_done;
    end

    wire ld_done_edge = ld_done & ~ld_done_q;

`ifndef SYNTHESIS
    //  The other half: a `ld_done` that is high when nobody asked is a protocol
    //  violation by whoever owns the bus. The hardware copes (it is ignored, and
    //  the edge never comes while ld_req is low), so this reports and continues.
    always @(posedge clock) begin
        if (rst_n && ld_done && !ld_req)
            $display("[FAULT] %m T-10 ld_done is asserted with no ld_req outstanding at time %0t. Ignored - but the load handshake is being driven wrongly, and a level-sensitive reader would have completed a load here with no data moved.",
                     $time);
    end
`endif

    // ---- the instruction register ----------------------------------------
    reg [PW_W-1:0] w [0:7];
    reg [2:0]      fw;                       // fetch word counter

    // Combinational read: 512 x 32 bit is 16 Kbit, small enough for distributed
    // RAM, and a registered read would put the fetch a cycle out of step with
    // the word counter for no benefit at 8 cycles per instruction.
    // Written as pc[PGI_W-1:0] rather than pc[PGA_W-4:0] so that the slice and
    // the ceiling the runtime check enforces are the same expression (T-1).
    wire [PGA_W-1:0] fetch_addr = {pc[PGI_W-1:0], fw};
    wire [PW_W-1:0]  fetch_word = prog[fetch_addr];

    assign op_code       = w[0][3:0];
    assign op_img_w      = w[0][11:4];
    assign op_img_h      = w[0][19:12];
    assign op_stride2    = w[0][20];
    assign op_act        = w[0][21];
    assign op_qmax       = w[0][31:24];
    assign op_n_pix      = w[1][15:0];
    assign op_n_oc       = w[1][23:16];
    assign op_n_ic       = w[1][31:24];
    assign op_n_grp      = w[2][7:0];
    assign op_n_ent_in   = w[2][15:8];
    assign op_n_ent_out  = w[2][23:16];
    assign op_base_in    = w[3][15:0];
    assign op_base_out   = w[3][31:16];
    assign op_base_saved = w[4][15:0];
    assign ld_off        = w[5][23:0];
    assign ld_bytes      = w[6][19:0];
    assign ld_pchan      = w[7][15:0];

    // Same slice as op_code, named for the load side. See the port comment.
    assign ld_op         = w[0][3:0];

    // ---- the sequence ----------------------------------------------------
    localparam S_IDLE  = 3'd0,
               S_FETCH = 3'd1,
               S_LOAD  = 3'd2,
               S_GO    = 3'd3,
               S_WAIT  = 3'd4,   // wait for the feeder to TAKE the job
               S_RUN   = 3'd5,   // then wait for it to finish
               S_GAP   = 3'd6,
               S_ERR   = 3'd7;   // abandoned: fault is sticky, running is low

    reg [2:0] st;
    reg [3:0] gap;

    // nothing to fetch when the op carries neither weights nor parameters
    wire no_load = (ld_bytes == 20'd0) && (ld_pchan == 16'd0);

    // ---- T-2: the opcode must be one a feeder actually decodes ----------
    // Six of the sixteen encodings reach a feeder. The other ten would let
    // op_start pulse into nothing, and op_busy would never rise.
    wire op_valid = (op_code >= 4'd1) && (op_code <= 4'd6);

    // ---- T-2: one watchdog across S_LOAD, S_WAIT and S_RUN --------------
    // S_GO sits between S_LOAD and S_WAIT and is not armed, so the load gets
    // its own budget and S_WAIT+S_RUN share one - which is the right split,
    // because "the DMA should have answered" and "the op should have finished"
    // are the two independent deadlines.
    localparam [WDOG_W-1:0] WDOG_LIM = {WDOG_W{1'b1}};

    reg [WDOG_W-1:0] wdog;
    wire wdog_arm  = (st == S_LOAD) || (st == S_WAIT) || (st == S_RUN);
    wire wdog_trip = wdog_arm && (wdog == WDOG_LIM);

    always @(posedge clock) begin
        if (!rst_n)          wdog <= {WDOG_W{1'b0}};
        else if (!wdog_arm)  wdog <= {WDOG_W{1'b0}};
        else if (!wdog_trip) wdog <= wdog + 1'b1;
    end

    always @(posedge clock) begin
        if (!rst_n) begin
            st <= S_IDLE; pc <= {NI_W{1'b0}}; fw <= 3'd0;
            ld_req <= 1'b0; op_start <= 1'b0; running <= 1'b0; done <= 1'b0;
            gap <= 4'd0; fault <= 1'b0;
        end else begin
            op_start <= 1'b0;
            done     <= 1'b0;

            case (st)
            // S_ERR admits `start` on exactly the same terms as S_IDLE, rather
            // than routing through it. Routing through cost a second `start`
            // pulse to recover - the first left S_ERR with `fault` still set -
            // and a two-pulse recovery protocol is the kind of thing that is
            // correct in the RTL and wrong in every caller. One pulse in, one
            // admission check, either running or faulted again.
            S_IDLE, S_ERR: begin
                // `start` clears a previous fault, so a run is always launched
                // from a known state rather than inheriting one.
                if (start) begin
                    if ((n_instr == {NI_W{1'b0}}) || (n_instr > MAX_INSTR)) begin
                        // T-1: n_instr is eight bits and the program memory
                        // holds MAX_INSTR instructions. Refusing is the whole
                        // point - executing instruction 64 would have fetched
                        // instruction 0's words and looked like a working run.
                        fault   <= 1'b1;
                        running <= 1'b0;
                        st      <= S_ERR;
                    end else begin
                        pc      <= {NI_W{1'b0}};
                        fw      <= 3'd0;
                        running <= 1'b1;
                        fault   <= 1'b0;
                        st      <= S_FETCH;
                    end
                end
            end

            // eight words, one per cycle
            S_FETCH: begin
                w[fw] <= fetch_word;
                fw    <= fw + 3'd1;
                if (fw == 3'd7) st <= S_LOAD;
            end

            S_LOAD: begin
                if (wdog_trip) begin
                    // the DMA never answered
                    ld_req  <= 1'b0;
                    fault   <= 1'b1;
                    running <= 1'b0;
                    st      <= S_ERR;
                end else if (no_load) begin
                    st <= S_GO;
                end else if (!ld_req) begin
                    ld_req <= 1'b1;
                end else if (ld_done_edge) begin
                    ld_req <= 1'b0;
                    st     <= S_GO;
                end
            end

            S_GO: begin
                if (!op_valid) begin
                    // T-2 cause (a): no feeder decodes this opcode, so op_busy
                    // would never rise and S_WAIT would park forever. Caught
                    // here rather than by the watchdog, because the opcode is
                    // knowable now and a 1M-cycle wait tells you nothing.
                    fault   <= 1'b1;
                    running <= 1'b0;
                    st      <= S_ERR;
                end else begin
                    op_start <= 1'b1;
                    st       <= S_WAIT;
                end
            end

            // Two states rather than one: wait for `busy` to RISE, then for it
            // to fall. A single "wait until not busy" would fall straight
            // through, because a feeder cannot assert busy until the cycle
            // after it sees op_start.
            S_WAIT: if (wdog_trip || op_error) begin
                // T-2 cause (b): the feeder's own zero-shape guard refused the
                // op, so the defensive behaviour is what causes the hang.
                // T-3: or a feeder's self-check reported a misplaced result.
                fault   <= 1'b1;
                running <= 1'b0;
                st      <= S_ERR;
            end else if (op_busy) st <= S_RUN;

            S_RUN: if (wdog_trip || op_error) begin
                fault   <= 1'b1;
                running <= 1'b0;
                st      <= S_ERR;
            end else if (!op_busy) begin
                gap <= GAP_CYC[3:0];
                st  <= S_GAP;
            end

            S_GAP: begin
                if (gap != 4'd0) begin
                    gap <= gap - 4'd1;
                end else if (pc == n_instr - 1'b1) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                    st      <= S_IDLE;
                end else begin
                    pc <= pc + 1'b1;
                    fw <= 3'd0;
                    st <= S_FETCH;
                end
            end

            // S_ERR is handled with S_IDLE above: abandoned, `fault` asserted
            // and `done` never pulsing, so a caller waiting on `done` learns by
            // reading one bit that it is waiting for nothing.

            // All eight encodings of `st` are now named, so this is
            // unreachable. It goes to S_ERR rather than S_IDLE because a state
            // register that reached an impossible value should be loud.
            default: begin
                fault   <= 1'b1;
                running <= 1'b0;
                st      <= S_ERR;
            end
            endcase
        end
    end

    // ---- why the run was abandoned, in simulation only ------------------
    //
    //  The RTL carries one `fault` bit, which is what the hardware needs. The
    //  REASON is worth more than a bit while debugging and costs nothing here.
    //
    //  These print `[FAULT]`, not `ERROR:`, and they do not call $finish -
    //  deliberately, and the distinction is worth stating because the rest of
    //  this review's simulation checks do the opposite:
    //
    //    * a condition the HARDWARE is designed to handle (these three) reports
    //      and lets the simulation continue. `fault` is the verdict, and a
    //      testbench asserts on it - accel_tb does, and top_seq_tb drives every
    //      one of these cases on purpose to watch the guard fire. A message that
    //      tripped scripts/run_sim.sh's failure grep would make a passing
    //      negative test unrunnable.
    //    * a condition that must NEVER happen (L-12's bias overflow, C-2's
    //      address witness, C-4's memory collision, T-3's tag drift) prints
    //      `ERROR:` and calls $finish, because there is no correct way to carry
    //      on and the run should stop where the evidence is.
`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (rst_n) begin
            if (((st == S_IDLE) || (st == S_ERR)) && start &&
                ((n_instr == {NI_W{1'b0}}) || (n_instr > MAX_INSTR)))
                $display("  [FAULT] %m T-1 n_instr=%0d out of range 1..%0d at time %0t",
                         n_instr, MAX_INSTR, $time);
            if ((st == S_GO) && !op_valid)
                $display("  [FAULT] %m T-2 pc=%0d opcode %0d decodes to no feeder at time %0t",
                         pc, op_code, $time);
            if (wdog_trip)
                $display("  [FAULT] %m T-2 watchdog expired in state %0d at pc=%0d (opcode %0d) at time %0t",
                         st, pc, op_code, $time);
            // pw_out's own ERROR:/$finish fires first and stops the run, so this
            // is for the case where that check is compiled out or the error
            // comes from a feeder that does not have one yet.
            if (op_error && ((st == S_WAIT) || (st == S_RUN)))
                $display("  [FAULT] %m T-3 a feeder reported a misplaced result at pc=%0d (opcode %0d) at time %0t",
                         pc, op_code, $time);
        end
    end
`endif

endmodule

`default_nettype wire
