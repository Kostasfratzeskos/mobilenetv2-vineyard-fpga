`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  addr_gen.v  -  pixel / oc_tile / ic_tile sequencer for the pointwise array
//
//  Build plan #3 of docs/controller_design.md. This is the spine of the
//  pointwise sub-controller: the three nested counters that walk the
//  output-stationary loop of section 5,
//
//      for pix in 0 .. n_pix-1            // H*W output pixels
//        for oct in 0 .. n_oct-1          // ceil(OC/Tm) output-channel tiles
//          for ict in 0 .. n_ict-1        // ceil(IC/Tn) input-channel tiles
//            emit (pix, oct, ict), first = (ict==0), last = (ict==n_ict-1)
//
//  which is exactly what pointwise_layer_tb does today with for-loops. What
//  the testbench does in simulation time, this does in hardware with counters.
//
//  Everything is RUNTIME configurable (n_pix, n_oc, n_ic are inputs, not
//  parameters) because one instance has to serve all 34 pointwise layers -
//  their shapes arrive from the instruction word of the top sequencer.
//
//  No tail logic here, deliberately. OC and IC that are not multiples of Tm/Tn
//  are handled where the weights are LOADED: the weight buffer starts zeroed
//  and only real weights are written, so a padded lane or tap multiplies by 0
//  and contributes nothing. Bit-exact, and it keeps the address path clean.
//  (Only 5 of the 34 pointwise layers have a tail at all - DD-013.)
//
//  Counter widths: the network needs 14 / 6 / 7 bits (n_pix max 12544 at
//  112x112, n_oc max 40, n_ic max 80 for the 1280-channel classifier). The
//  defaults below carry headroom.
//
//  Stalling: `en` low freezes the whole sequence and drops `valid`, so the
//  feeder can hold the array while a weight DMA catches up. `first`/`last`
//  are combinational functions of `ict` and are only meaningful while `valid`
//  is high - mac_lane qualifies both with valid internally.
//
//  NOTE for the feeder: a registered buffer read costs a cycle, so whoever
//  wires this to pe_array must delay valid/first/last by the SAME number of
//  cycles as the data path, or the accumulator will clear on the wrong tile.
//  That alignment is the feeder's job, not this module's.
//
//  Run:  bash scripts/run_sim.sh addr_gen
//============================================================================
module addr_gen #(
    parameter PIX_W = 16,     // pixel counter width   (needs 14)
    parameter OCT_W = 8,      // oc_tile counter width (needs 6)
    parameter ICT_W = 8       // ic_tile counter width (needs 7)
)(
    input  wire              clock,
    input  wire              rst_n,       // async active-low reset
    input  wire              start,       // pulse: (re)start a layer
    input  wire              en,          // advance; low = stall

    // layer shape, sampled at `start` (counts, not last-indices)
    input  wire [PIX_W-1:0]  n_pix,       // H*W
    input  wire [OCT_W-1:0]  n_oc,        // ceil(OC/Tm)
    input  wire [ICT_W-1:0]  n_ic,        // ceil(IC/Tn)

    output reg  [PIX_W-1:0]  pix,         // current output pixel
    output reg  [OCT_W-1:0]  oct,         // current output-channel tile
    output reg  [ICT_W-1:0]  ict,         // current input-channel tile
    output wire              valid,       // pix/oct/ict address a real tile
    output wire              first,       // first tile of this dot product
    output wire              last,        // final tile of this dot product
    output wire              busy,        // a layer is in flight
    output reg               layer_done   // pulses once, after the final tile
);

    // ---- shape latched at start ----------------------------------------
    // Held for the whole layer so the caller may change the inputs freely
    // once the layer is running (the next instruction can be prefetched).
    reg [PIX_W-1:0] pix_n;
    reg [OCT_W-1:0] oc_n;
    reg [ICT_W-1:0] ic_n;

    reg run;

    // ---- carry chain ----------------------------------------------------
    wire ict_wrap = (ict == ic_n  - 1'b1);
    wire oct_wrap = (oct == oc_n  - 1'b1) & ict_wrap;
    wire pix_wrap = (pix == pix_n - 1'b1) & oct_wrap;

    wire step = run & en;

    assign valid = step;
    assign first = (ict == {ICT_W{1'b0}});
    assign last  = ict_wrap;
    assign busy  = run;

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            pix <= {PIX_W{1'b0}};  oct <= {OCT_W{1'b0}};  ict <= {ICT_W{1'b0}};
            pix_n <= {PIX_W{1'b0}}; oc_n <= {OCT_W{1'b0}}; ic_n <= {ICT_W{1'b0}};
            run <= 1'b0;
            layer_done <= 1'b0;
        end else if (start) begin
            // restart wins over everything, including a layer in flight
            pix <= {PIX_W{1'b0}};  oct <= {OCT_W{1'b0}};  ict <= {ICT_W{1'b0}};
            pix_n <= n_pix;  oc_n <= n_oc;  ic_n <= n_ic;
            // a zero-sized layer would never terminate: refuse to start
            run <= (n_pix != {PIX_W{1'b0}}) &
                   (n_oc  != {OCT_W{1'b0}}) &
                   (n_ic  != {ICT_W{1'b0}});
            layer_done <= 1'b0;
        end else begin
            layer_done <= 1'b0;             // one-cycle pulse by default
            if (step) begin
                if (pix_wrap) begin
                    // final tile of the layer was just consumed
                    pix <= {PIX_W{1'b0}}; oct <= {OCT_W{1'b0}}; ict <= {ICT_W{1'b0}};
                    run <= 1'b0;
                    layer_done <= 1'b1;
                end else if (oct_wrap) begin
                    ict <= {ICT_W{1'b0}};  oct <= {OCT_W{1'b0}};  pix <= pix + 1'b1;
                end else if (ict_wrap) begin
                    ict <= {ICT_W{1'b0}};  oct <= oct + 1'b1;
                end else begin
                    ict <= ict + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
