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
//  Run:  bash scripts/run_sim.sh top_seq
//============================================================================
module top_seq #(
    parameter PW_W      = 32,     // program word width
    parameter PGA_W     = 9,      // program memory address width (512 words)
    parameter PROG_DEPTH= 512,
    parameter NI_W      = 8,      // instruction-count width
    parameter GAP_CYC   = 4       // idle cycles after each op
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
    output reg                 ld_req,
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

    output reg  [NI_W-1:0]     pc,          // instruction index, for debug
    output reg                 running,
    output reg                 done         // pulses when the program ends
);

    // ---- program memory --------------------------------------------------
    reg [PW_W-1:0] prog [0:PROG_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < PROG_DEPTH; i = i + 1) prog[i] = {PW_W{1'b0}};
    end

    always @(posedge clock)
        if (pg_en) prog[pg_addr] <= pg_data;

    // ---- the instruction register ----------------------------------------
    reg [PW_W-1:0] w [0:7];
    reg [2:0]      fw;                       // fetch word counter

    // Combinational read: 512 x 32 bit is 16 Kbit, small enough for distributed
    // RAM, and a registered read would put the fetch a cycle out of step with
    // the word counter for no benefit at 8 cycles per instruction.
    wire [PGA_W-1:0] fetch_addr = {pc[PGA_W-4:0], fw};
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

    // ---- the sequence ----------------------------------------------------
    localparam S_IDLE  = 3'd0,
               S_FETCH = 3'd1,
               S_LOAD  = 3'd2,
               S_GO    = 3'd3,
               S_WAIT  = 3'd4,   // wait for the feeder to TAKE the job
               S_RUN   = 3'd5,   // then wait for it to finish
               S_GAP   = 3'd6;

    reg [2:0] st;
    reg [3:0] gap;

    // nothing to fetch when the op carries neither weights nor parameters
    wire no_load = (ld_bytes == 20'd0) && (ld_pchan == 16'd0);

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; pc <= {NI_W{1'b0}}; fw <= 3'd0;
            ld_req <= 1'b0; op_start <= 1'b0; running <= 1'b0; done <= 1'b0;
            gap <= 4'd0;
        end else begin
            op_start <= 1'b0;
            done     <= 1'b0;

            case (st)
            S_IDLE: begin
                if (start && (n_instr != {NI_W{1'b0}})) begin
                    pc      <= {NI_W{1'b0}};
                    fw      <= 3'd0;
                    running <= 1'b1;
                    st      <= S_FETCH;
                end
            end

            // eight words, one per cycle
            S_FETCH: begin
                w[fw] <= fetch_word;
                fw    <= fw + 3'd1;
                if (fw == 3'd7) st <= S_LOAD;
            end

            S_LOAD: begin
                if (no_load) begin
                    st <= S_GO;
                end else if (!ld_req) begin
                    ld_req <= 1'b1;
                end else if (ld_done) begin
                    ld_req <= 1'b0;
                    st     <= S_GO;
                end
            end

            S_GO: begin
                op_start <= 1'b1;
                st       <= S_WAIT;
            end

            // Two states rather than one: wait for `busy` to RISE, then for it
            // to fall. A single "wait until not busy" would fall straight
            // through, because a feeder cannot assert busy until the cycle
            // after it sees op_start.
            S_WAIT: if (op_busy) st <= S_RUN;

            S_RUN: if (!op_busy) begin
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

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
