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
    parameter ACC_W  = 21,
    parameter SEL_W  = 1,         // clog2(TM/TN)
    parameter BANK_W = 5,         // clog2(TM)
    parameter PIX_W  = 16,
    parameter OCT_W  = 8,
    parameter ICT_W  = 8,
    parameter WA_W   = 10,        // weight buffer address width
    parameter AA_W   = 16,        // activation buffer address width
    parameter WDEPTH = 1024
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

    // ================= stage 0 : sequence and addresses =================
    wire [PIX_W-1:0] pix;
    wire [OCT_W-1:0] oct;
    wire [ICT_W-1:0] ict;
    wire             ag_valid, ag_first, ag_last;

    addr_gen #(.PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W)) u_addr (
        .clock(clock), .rst_n(rst_n),
        .start(start), .en(~stall),
        .n_pix(n_pix), .n_oc(n_oc), .n_ic(n_ic),
        .pix(pix), .oct(oct), .ict(ict),
        .valid(ag_valid), .first(ag_first), .last(ag_last),
        .busy(busy), .layer_done(layer_done)
    );

    // end of one dot product, and end of all the dot products of this pixel
    wire tile_last = ag_valid & ag_last;
    wire pix_last  = tile_last & (oct == n_oc - 1'b1);

    reg [WA_W-1:0] w_addr;      // walks 0 .. n_oc*n_ic-1, restarts per pixel
    reg [AA_W-1:0] pix_base;    // base_in + pix*n_ent, kept by accumulation

    always @(posedge clock or negedge rst_n) begin
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

    assign a_addr  = pix_base + (ict >> 1);
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
    always @(posedge clock or negedge rst_n) begin
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
    reg [PIX_W-1:0] pix_d1;
    reg [OCT_W-1:0] oct_d1;
    always @(posedge clock) begin
        if (ag_valid) begin pix_d1  <= pix;    oct_d1  <= oct;    end
        if (v_d)      begin acc_pix <= pix_d1; acc_oct <= oct_d1; end
    end

endmodule

`default_nettype wire
