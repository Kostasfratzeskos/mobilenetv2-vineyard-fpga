`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  pw_feeder.v  -  the pointwise sub-controller: counters + buffers + array
//
//  Build plan #3, final piece. Wires addr_gen, wgt_buffer, act_buffer and
//  pe_array into the input half of the pointwise datapath, and hands out
//  finished Tm-wide accumulators tagged with the output element they belong
//  to. The output half (capture, bias, requantize, writeback) sits outside.
//
//  ---- the pipeline, and why the tags exist ---------------------------
//
//   cycle C   addr_gen emits (pix, oct, ict) + valid/first/last
//             -> addresses computed, buffer reads issued
//   cycle C+1 buffer data arrives; valid/first/last, delayed by one, reach
//             pe_array together with it
//   cycle C+2 pe_array's acc is final and `done` is high
//
//  So `done` lands TWO cycles after the tile that produced it, by which time
//  addr_gen has long moved on. The (pix, oct) tag is therefore pipelined
//  alongside and presented with the result, so the writeback knows where the
//  32 values belong. Each tag stage advances on ITS OWN valid, never on the
//  bare clock, or a stall would slide the tags past the data.
//
//  Getting that delay wrong is the classic bug here: if valid/first/last
//  reached pe_array a cycle early, `first` would clear the accumulator on the
//  wrong tile and every dot product in the network would be silently short.
//
//  ---- addressing without multipliers ---------------------------------
//
//  The naive addresses are wgt = oct*n_ic + ict and act = pix*n_ent + ict>>1,
//  but neither multiply is needed, because the sweep order makes both linear:
//
//    weights: the tile order IS the address order, 0 .. n_oc*n_ic-1, and it
//             restarts on every pixel (a 1x1 conv reuses the same weight
//             matrix at every pixel - that is the whole point of it). So one
//             counter that increments per tile and clears at the end of a
//             pixel.
//    acts   : only `pix` scales, so a base register that adds n_ent when the
//             pixel advances, plus ict>>1 as the offset within the pixel.
//
//  ---- what the caller must provide ------------------------------------
//
//  Shapes are runtime inputs, latched at `start`:
//    n_pix   = H*W                     n_oc  = ceil(OC/TM)
//    n_ic    = ceil(IC/TN)             n_ent = ceil(IC/TM)   entries per pixel
//    base_in = where this layer's input lives in the activation pool
//
//  The weight load port passes straight through to wgt_buffer, so the DMA
//  drives it directly. The weight buffer must already hold the layer's full
//  n_oc*n_ic rectangle, zero-padded per its tail contract, before `start`.
//
//  ---- the activation pool is NOT owned here ---------------------------
//
//  act_buffer lives at the top level, not inside this module. It is a SHARED
//  resource: the depthwise path reads and writes the same feature maps, and a
//  second instance would double 1.5 MB of on-chip memory for no reason. So this
//  module drives a read address and consumes the word that comes back a cycle
//  later (a_rd_en / a_addr / a_sel out, a_word in), and whoever assembles the
//  system points those at the pool. The weight buffer stays inside because it
//  genuinely belongs to the pointwise path - the depthwise weights have a
//  different shape entirely (16 banks of 9 taps, not 32 of 16).
//
//  `stall` freezes the whole front end, addr_gen included, for as long as it
//  is held - that is how the drain stage will apply back-pressure.
//
//  ---- CONSTRAINT: leave the pipeline time to drain ---------------------
//
//  `layer_done` fires when addr_gen CONSUMES the last tile, but that tile's
//  result is still two stages behind it. Measured in pw_feeder_tb: results
//  keep arriving for 1 more cycle after layer_done. A `start` asserted before
//  that clears v_d/f_d/l_d and those in-flight results are LOST, not merely
//  mis-tagged. The sequencer must therefore leave at least two idle cycles
//  after layer_done before starting the next layer - which costs nothing,
//  since it also has to reload the weight buffer between layers.
//
//  (This is also the only case where the `ag_valid` / `v_d` guards on the tag
//  pipeline below do any work. Within a layer they are redundant, because
//  addr_gen freezes its outputs whenever valid is low, so capturing the tag
//  unconditionally would latch the same value - removing the guards passes
//  the whole testbench. They are kept because they make the intent explicit
//  and stay correct if addr_gen's behaviour ever changes.)
//
//  Run:  bash scripts/run_sim.sh pw_feeder addr_gen wgt_buffer pe_array mac_lane
//============================================================================
module pw_feeder #(
    parameter DATA_W = 8,
    parameter TM     = 32,        // lanes / output channels in parallel
    parameter TN     = 16,        // input channels per cycle
    parameter ACC_W  = 26,
    parameter SEL_W  = 1,         // clog2(TM/TN)
    parameter BANK_W = 5,         // clog2(TM)
    parameter PIX_W  = 16,
    parameter OCT_W  = 8,
    parameter ICT_W  = 8,
    parameter WA_W   = 10,        // weight buffer address width
    parameter AA_W   = 16,        // activation buffer address width
    parameter WDEPTH = 1024,

    // Latency of the shared out_stage, which lives in accel_top: acc_valid to
    // q_valid. A PARAMETER rather than a literal because this module's drain
    // counter is defined against it and out_stage is not instantiated here, so
    // there is nothing else that would make the two move together. See
    // docs/latency_map.md.
    // Default is the REAL value, not a placeholder. It was 2 while requantize
    // was one register; L-3 made it 5, and the standalone testbenches
    // instantiate this module directly and take the default - so a stale
    // default is not a cosmetic issue, it silently desynchronises this feeder
    // from the out_stage sitting next to it. dw_datapath_tb caught exactly that
    // via the C-2 witness: a 3-cycle gap showed up as a 3-pixel shift.
    parameter OS_LAT = 5
)(
    input  wire                   clock,
    input  wire                   rst_n,

    // ---- layer control -------------------------------------------------
    input  wire                   start,
    input  wire                   stall,
    input  wire [PIX_W-1:0]       n_pix,     // H*W
    input  wire [OCT_W-1:0]       n_oc,      // ceil(OC/TM)
    input  wire [ICT_W-1:0]       n_ic,      // ceil(IC/TN)
    input  wire [AA_W-1:0]        n_ent,     // ceil(IC/TM), entries per pixel
    input  wire [AA_W-1:0]        base_in,   // input tensor base address

    // ---- weight load port (straight through to wgt_buffer) -------------
    input  wire                   wl_en,
    input  wire [BANK_W-1:0]      wl_bank,
    input  wire [WA_W-1:0]        wl_addr,
    input  wire [TN*DATA_W-1:0]   wl_data,

    // ---- activation pool read interface (the pool is at the top level) --
    output wire                   a_rd_en,
    output wire [AA_W-1:0]        a_addr,
    output wire [SEL_W-1:0]       a_sel,
    input  wire [TN*DATA_W-1:0]   a_word,    // arrives one cycle after a_addr

    // ---- results -------------------------------------------------------
    output wire [TM*ACC_W-1:0]    acc,        // Tm finished accumulators
    output wire                   acc_valid,  // they are final this cycle
    output reg  [PIX_W-1:0]       acc_pix,    // which pixel they belong to
    output reg  [OCT_W-1:0]       acc_oct,    // which output-channel tile
    output wire                   busy,
    output wire                   layer_done
);

    // ---- the latencies this module is defined against -------------------
    //  MAC_LAT is mac_lane's, restated here from the same inputs rather than
    //  copied as a number: one registered product stage, clog2(TN) adder-tree
    //  levels, one accumulate stage. mac_lane.v is where it is defined; this is
    //  the same arithmetic, not a second opinion. The simulation check at the
    //  bottom of this file MEASURES the real latency and fails if the two ever
    //  disagree, which is the only thing that makes restating it safe.
    //
    //  ARR_LAT is what this module actually cares about, and the distinction is
    //  new with A-1: pe_array registers `a`, `w` and the controls at its input
    //  before the lanes see them (DD-022 option B), so the ARRAY answers one
    //  cycle later than the LANE does. Everything downstream - the tag pipeline,
    //  the drain, the measurement check - is sized from ARR_LAT. MAC_LAT is kept
    //  as the intermediate it is derived from rather than folded away, because
    //  the two numbers now have different owners and will move separately.
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1) v = v >> 1;
        end
    endfunction

    localparam MAC_LAT = 1 + clog2(TN) + 1;             // 6 at TN=16
    localparam ARR_LAT = 1 + MAC_LAT;                   // 7, incl. A-1's input reg

    // ================= stage 0 : sequence and addresses =================
    wire [PIX_W-1:0] pix;
    wire [OCT_W-1:0] oct;
    wire [ICT_W-1:0] ict;
    wire             ag_valid, ag_first, ag_last;
    wire             ag_busy;

    addr_gen #(.PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W)) u_addr (
        .clock(clock), .rst_n(rst_n),
        .start(start), .en(~stall),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic),
        .pix(pix), .oct(oct), .ict(ict),
        .valid(ag_valid), .first(ag_first), .last(ag_last),
        .busy(ag_busy), .layer_done(layer_done)
    );

    // ---- busy has to outlive addr_gen ----------------------------------
    // addr_gen's own `busy` drops the moment it CONSUMES the last tile, but
    // that tile's result is still in pe_array, and OS_LAT more cycles behind
    // that in the shared out_stage. Exposing addr_gen's busy directly made
    // `busy` mean "I have stopped reading", when every caller reads it as "my
    // writes have landed" - and at the top level that cost the last two pixels
    // of every pointwise layer, which accel_tb caught. The other four feeders
    // already carried this counter; this one was the odd case out because its
    // address generator happened to expose a busy of its own.
    //
    // ---- the drain is DERIVED now (L-1) --------------------------------
    //  It used to be the literal 3'd7, chosen with slack when mac_lane
    //  answered in one cycle. mac_lane is pipelined now, so the number has to
    //  come from the structure or it is a bit-exactness failure waiting for a
    //  retrain. Counting from the cycle `layer_done` is high:
    //
    //      +1              ... the last tile reaches pe_array (v_d)
    //      +ARR_LAT        ... pe_array's acc_valid for it
    //      +OS_LAT         ... out_stage's q_valid, i.e. the write
    //
    //  layer_done is itself one cycle after the tile was consumed, so the
    //  distance from the layer_done cycle to the last write is exactly
    //  ARR_LAT + OS_LAT. `busy` is high during the layer_done cycle and for
    //  `drain` cycles after it, so DRAIN_CYC = ARR_LAT + OS_LAT covers it with
    //  nothing to spare and nothing wasted. It was MAC_LAT + OS_LAT until A-1
    //  put a register in front of the lanes.
    localparam DRAIN_CYC = ARR_LAT + OS_LAT;            // 12 at OS_LAT=5
    localparam DRAIN_W   = clog2(DRAIN_CYC + 1);        // 4

    reg [DRAIN_W-1:0] drain;
    always @(posedge clock) begin
        if (!rst_n)                   drain <= {DRAIN_W{1'b0}};
        else if (start)               drain <= {DRAIN_W{1'b0}};
        else if (layer_done)          drain <= DRAIN_CYC[DRAIN_W-1:0];
        else if (drain != {DRAIN_W{1'b0}}) drain <= drain - 1'b1;
    end

    assign busy = ag_busy || layer_done || (drain != {DRAIN_W{1'b0}});

    // end of one dot product, and end of all the dot products of this pixel
    wire tile_last = ag_valid & ag_last;
    wire pix_last  = tile_last & (oct == n_oc - 1'b1);

    reg [WA_W-1:0] w_addr;      // walks 0 .. n_oc*n_ic-1, restarts per pixel
    reg [AA_W-1:0] pix_base;    // base_in + pix*n_ent, kept by accumulation

    always @(posedge clock) begin
        if (!rst_n) begin
            w_addr   <= {WA_W{1'b0}};
            pix_base <= {AA_W{1'b0}};
        end else if (start) begin
            w_addr   <= {WA_W{1'b0}};
            pix_base <= base_in;
        end else if (ag_valid) begin
            w_addr <= pix_last ? {WA_W{1'b0}} : (w_addr + 1'b1);
            if (pix_last) pix_base <= pix_base + n_ent;
        end
    end

    // ---- C-5: SEL_W is the ONE encoding of the entry/word ratio ---------
    //  Every one of these used to pair a SEL_W-derived half-select with a
    //  literal divide-by-two - `x[W-1:1]` or `x >> 1` - and the two agreed only
    //  because POOL_TM/TN happens to be 2, so SEL_W happens to be 1. At ratio 4
    //  the `*_sel` port would widen correctly and every address would still
    //  divide by 2, so three quarters of the reads would land on the wrong entry
    //  with no width mismatch and nothing to say so. The shift is `>> SEL_W`
    //  now, which is the same value today and the right one at any ratio.
    //
    //  Done through a 32-bit intermediate and then resized to exactly the port
    //  width: a bare shift keeps the operand's own width, so the result would be
    //  silently truncated or zero-extended at the assignment depending on which
    //  side was wider.
    wire [31:0]     ict_wide = {{(32-ICT_W){1'b0}}, ict} >> SEL_W;
    wire [AA_W-1:0] ict_ent  = ict_wide[AA_W-1:0];

    assign a_addr  = pix_base + ict_ent;
    assign a_sel   = ict[SEL_W-1:0];
    assign a_rd_en = ag_valid;

    // ================= the two buffers ==================================
    wire [TM*TN*DATA_W-1:0] w_word;

    wgt_buffer #(.DATA_W(DATA_W), .TM(TM), .TN(TN),
                 .DEPTH(WDEPTH), .ADDR_W(WA_W), .BANK_W(BANK_W)) u_wgt (
        .clock(clock),
        .wr_en(wl_en), .wr_bank(wl_bank), .wr_addr(wl_addr), .wr_data(wl_data),
        .rd_en(ag_valid), .rd_addr(w_addr), .rd_data(w_word)
    );

    // ================= stage 1 : control delayed to meet the data =======
    reg v_d, f_d, l_d;
    always @(posedge clock) begin
        if (!rst_n)     begin v_d <= 1'b0; f_d <= 1'b0; l_d <= 1'b0; end
        else if (start) begin v_d <= 1'b0; f_d <= 1'b0; l_d <= 1'b0; end
        else            begin v_d <= ag_valid; f_d <= ag_first; l_d <= ag_last; end
    end

    // ================= stage 2 : the array ==============================
    pe_array #(.DATA_W(DATA_W), .TM(TM), .TN(TN), .ACC_W(ACC_W)) u_array (
        .clock(clock), .rst_n(rst_n),
        .valid(v_d), .first(f_d), .last(l_d),
        .a(a_word), .w(w_word),
        .acc(acc), .done(acc_valid)
    );

    // ---- tag pipeline --------------------------------------------------
    //
    //  TAG_LAT = 1 + ARR_LAT, because the tag has to travel from the cycle
    //  addr_gen emitted it to the cycle pe_array's `done` presents the result:
    //  one cycle for the buffer read, then the whole ARRAY pipeline - A-1's
    //  input register plus mac_lane. It was two stages when mac_lane answered in
    //  one cycle, seven before A-1 added its register.
    //
    //  ---- why only the FIRST stage is gated ---------------------------
    //
    //  The old header said "each tag stage advances on ITS OWN valid, never on
    //  the bare clock, or a stall would slide the tags past the data". That was
    //  right for a combinational array and is now exactly backwards for the
    //  stages inside it.
    //
    //  Stage 1 is the buffer-read stage, and act_buffer and wgt_buffer only
    //  update their outputs when their read enable is high - so their data is
    //  HELD during a stall, and the tag beside it must be held too. It keeps
    //  its `ag_valid` gate.
    //
    //  Stages 2..TAG_LAT shadow mac_lane's product register and adder tree,
    //  which FREE-RUN (they are not clock-enabled - see mac_lane's header). A
    //  held buffer output simply propagates through them, so the data advances
    //  every cycle whether or not `valid` is high, and a tag gated on valid
    //  would fall behind it. They free-run for the same reason the tree does,
    //  and mac_lane's own valid shift register free-runs beside them.
    //  acc_pix / acc_oct ARE the last stage, so the shift register in front of
    //  them holds TAG_LAT-1. Counting it out, for a tag emitted in cycle C:
    //      pix_sr[0]           valid in C+1   (the buffer-read stage)
    //      pix_sr[k]           valid in C+1+k
    //      pix_sr[TAG_LAT-2]   valid in C+TAG_LAT-1
    //      acc_pix             valid in C+TAG_LAT  = C+8, with acc_valid
    localparam TAG_LAT = 1 + ARR_LAT;                 // 8

    reg [PIX_W-1:0] pix_sr [0:TAG_LAT-2];
    reg [OCT_W-1:0] oct_sr [0:TAG_LAT-2];

    integer ts;
    always @(posedge clock) begin
        if (!rst_n) begin
            for (ts = 0; ts <= TAG_LAT-2; ts = ts + 1) begin
                pix_sr[ts] <= {PIX_W{1'b0}};
                oct_sr[ts] <= {OCT_W{1'b0}};
            end
            acc_pix <= {PIX_W{1'b0}};
            acc_oct <= {OCT_W{1'b0}};
        end else begin
            // stage 1: gated, because the buffers it shadows are gated
            if (ag_valid) begin
                pix_sr[0] <= pix;
                oct_sr[0] <= oct;
            end
            // stages 2..TAG_LAT-1: free-running, because mac_lane is
            for (ts = 1; ts <= TAG_LAT-2; ts = ts + 1) begin
                pix_sr[ts] <= pix_sr[ts-1];
                oct_sr[ts] <= oct_sr[ts-1];
            end
            // the last stage, aligned with pe_array's acc_valid
            acc_pix <= pix_sr[TAG_LAT-2];
            acc_oct <= oct_sr[TAG_LAT-2];
        end
    end

    // ---- C-6: the weight rectangle must fit the weight buffer ------------
    //
    //  `w_addr` is WA_W bits and walks 0 .. n_oc*n_ic-1, so a layer needing
    //  more than WDEPTH entries wraps SILENTLY and re-reads the start of the
    //  rectangle. No live overflow today: the worst layer is features.18.0 at
    //  40*20 = 800 of 1024 (78%), and the classifier needs only 80 because this
    //  model has 4 classes. A stock 1000-class head would need 32*80 = 2560 and
    //  would read the wrong weights for two thirds of the layer, producing a
    //  plausible wrong answer.
    //
    //  Checked at `start`, when the shape arrives, rather than per tile. The
    //  build-time assert in gen_program.py is the one that matters most - it
    //  fires before a simulation is spent - and wgt_buffer's elaboration guard
    //  covers a mis-parameterised instance. This one covers the runtime shape,
    //  which neither of those sees.
`ifndef SYNTHESIS
    // ---- ARR_LAT is restated here, so MEASURE it (L-1, L-2, A-1) --------
    //  This module computes MAC_LAT from TN with the same arithmetic mac_lane
    //  uses, adds pe_array's own input register to get ARR_LAT, and sizes its
    //  tag depth and drain counter against the result. If either pipeline ever
    //  changes and this does not, the symptom is a shifted output tensor that
    //  still looks like activations. So: time the real thing. Time from the LAST
    //  tile of a dot product entering pe_array (`v_d && l_d`) to `acc_valid`
    //  coming back, because `done` only fires on a last tile - timing from the
    //  FIRST tile instead measures the latency plus the dot product's own
    //  length, which is what the first version of this check did and why it
    //  reported 7 for a two-tile shape.
    //
    //  This check is ALSO the witness for A-1. pe_array's register is invisible
    //  from here except as one extra cycle, so if the register were added and
    //  ARR_LAT were not, or the reverse, nothing about the wiring would look
    //  wrong - the tags would just be off by one for every pixel in the network.
    //  One measurement per layer, then stop: `lat_arm` left permanently set
    //  re-checked on every later acc_valid against a counter that had kept
    //  running, which reported 7 for a latency that was 6.
    reg [7:0] lat_cnt;
    reg       lat_arm, lat_seen;
    always @(posedge clock) begin
        if (!rst_n || start) begin
            lat_arm  <= 1'b0;
            lat_seen <= 1'b0;
            lat_cnt  <= 8'd0;
        end else if (!lat_seen) begin
            if (!lat_arm) begin
                // the LAST tile of a dot product: `done` only fires on one
                if (v_d && l_d) begin
                    lat_arm <= 1'b1;
                    lat_cnt <= 8'd1;
                end
            end else if (acc_valid) begin
                lat_seen <= 1'b1;
            end else begin
                lat_cnt <= lat_cnt + 8'd1;
            end
        end
    end

    always @(posedge clock) begin
        if (rst_n && lat_arm && !lat_seen && acc_valid && (lat_cnt != ARR_LAT[7:0])) begin
            $display("ERROR: %m L-1/A-1 pe_array answered %0d cycles after the tile entered it, but this module's ARR_LAT says %0d at time %0t (MAC_LAT %0d + pe_array's A-1 input register). The tag pipeline (%0d deep) and the drain (%0d) are both sized from ARR_LAT, so they are now wrong too.",
                     lat_cnt, ARR_LAT, $time, MAC_LAT, TAG_LAT, DRAIN_CYC);
            $finish;
        end
    end

    // n_oc and n_ic are OCT_W/ICT_W wide; multiply in a wide integer so the
    // product itself cannot be the thing that overflows.
    always @(posedge clock) begin
        if (rst_n && start) begin
            if ((n_oc * n_ic) > WDEPTH) begin
                $display("ERROR: %m C-6 layer needs n_oc*n_ic = %0d weight entries, the buffer holds WDEPTH = %0d (WA_W = %0d) at time %0t. w_addr would wrap and re-read the start of the rectangle.",
                         n_oc * n_ic, WDEPTH, WA_W, $time);
                $finish;
            end
        end
    end
`endif

endmodule

`default_nettype wire
