`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  act_buffer.v  -  on-chip activation store for the pointwise array
//
//  Build plan #3. Holds the feature maps that never leave the chip (DD-007,
//  controller_design.md section 4). One entry = TM channels of one pixel.
//
//  WHY 256 BIT AND NOT 128. The array is asymmetric: it WRITES Tm=32 output
//  channels at a time (one oc_tile result) but READS Tn=16 input channels at
//  a time. With a 128-bit memory each writeback would cost two cycles, and in
//  features.2.conv.0.0 (IC=16, so only ONE ic_tile per dot product) the
//  writeback would take 75,264 cycles against 37,632 of compute - the store
//  would become the bottleneck and cost ~6.6% of the whole pointwise runtime.
//  Storing TM channels per entry and muxing down on the read side removes it:
//  one write per oc_tile, one read per ic_tile, both single-cycle.
//
//  Addressing (the feeder supplies flat addresses; see below for why):
//      write : addr = base_out + pix*ceil(OC/TM) + oct
//      read  : addr = base_in  + pix*ceil(IC/TM) + (ict >> 1),  sel = ict[0]
//  so two consecutive ic_tiles share one entry - the lower and upper half.
//  This works for every layer shape, including IC=24 (one entry, 8 channels
//  of padding in the upper half) and IC=48 (two entries, tiles 0,1 from the
//  first and tile 2 from the lower half of the second).
//
//  NO PING-PONG HARDWARE, deliberately. Two fixed halves would need 2x the
//  largest feature map (2.3 MB), but what is actually required is the largest
//  INPUT + OUTPUT pair that must be resident together, which is 1.53 MB. So
//  this is one flat pool and the ping-pong is a controller policy: two base
//  address registers that swap between layers. Dumb hardware, policy in the
//  sequencer - the same split as everywhere else in this design.
//
//  PADDING IS SAFE. When OC is not a multiple of TM the array still produces
//  TM results, and the padded lanes carry garbage rather than zero (their
//  accumulator is 0, but bias_add and requantize then act on it). That
//  garbage is stored, and it is harmless: the NEXT layer multiplies those
//  channels by weights that the wgt_buffer tail contract guarantees are zero.
//  The two tail contracts depend on each other - do not relax either alone.
//
//  DEPTH: the largest resident pair needs 50,176 entries (features.1.conv.1's
//  output at 112x112x16 plus features.2.conv.0.0's at 112x112x96). The
//  default 65,536 rounds that up to a clean 16-bit address = 2 MB.
//  The raw 224x224x3 input is NOT stored here - it is the stem's input and
//  would waste 91% of an entry on padding; the stem has its own feeder.
//
//  ---- half writes, and why -------------------------------------------
//
//  The pointwise array produces TM=32 channels per result and fills a whole
//  entry. The depthwise array produces TC=16 (DD-014) and fills HALF of one,
//  because a depthwise pass covers 16 channels of every pixel before moving to
//  the next 16. So `wr_full` low writes only the slice named by `wr_sel`,
//  leaving the other half of the entry as the previous pass left it. On
//  BRAM/URAM this is a native byte-enable, not a read-modify-write.
//
//  Convention for a half write: the caller REPLICATES its payload across the
//  whole wr_data word and lets wr_sel choose which copy lands. That keeps this
//  module generic over TM/TN rather than hard-coding which half is which.
//
//  Read latency is ONE cycle, like wgt_buffer. rd_sel is pipelined with the
//  data so the caller presents it with the address, not a cycle later.
//
//  Run:  bash scripts/run_sim.sh act_buffer
//============================================================================
module act_buffer #(
    parameter DATA_W = 8,       // int8 activations
    parameter TM     = 32,      // channels per stored entry (write width)
    parameter TN     = 16,      // channels per read word
    parameter SEL_W  = 1,       // clog2(TM/TN) -- which slice of an entry
    parameter DEPTH  = 65536,   // entries (50,176 needed)
    parameter ADDR_W = 16
)(
    input  wire                   clock,

    // ---- write port: a whole entry, or one TN-channel slice of it -----
    input  wire                   wr_en,
    input  wire                   wr_full,   // 1 = all TM channels
    input  wire [SEL_W-1:0]       wr_sel,    // which slice when wr_full = 0
    input  wire [ADDR_W-1:0]      wr_addr,
    input  wire [TM*DATA_W-1:0]   wr_data,

    // ---- read port: one ic_tile, TN channels --------------------------
    input  wire                   rd_en,
    input  wire [ADDR_W-1:0]      rd_addr,
    input  wire [SEL_W-1:0]       rd_sel,     // slice within the entry
    output wire [TN*DATA_W-1:0]   rd_data
);

    localparam ENT_BITS  = TM*DATA_W;     // 256
    localparam WORD_BITS = TN*DATA_W;     // 128

    // URAM, not BRAM, and not left to the tool to decide. 50,176 entries of
    // 256 bit is 12.85 Mbit, which is more than every BRAM on the XCZU7EV put
    // together (11.0 Mbit) - so mapping it to BRAM cannot fit, and the first
    // synthesis run proved it does exactly that if asked nicely: Block RAM
    // 560 tiles of 312 available, 179%, with all 96 URAMs sitting unused.
    // URAM holds 27.0 Mbit, and this needs 52 of the 96.
    (* ram_style = "ultra" *)
    reg [ENT_BITS-1:0]  mem [0:DEPTH-1];
    reg [ENT_BITS-1:0]  dout;
    reg [SEL_W-1:0]     sel_q;            // travels with the data

    // Deterministic power-up. On Xilinx this becomes the memory INIT and
    // costs nothing; it also keeps simulation free of X before the first
    // layer has written anything.
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) mem[i] = {ENT_BITS{1'b0}};
        dout  = {ENT_BITS{1'b0}};
        sel_q = {SEL_W{1'b0}};
    end

    localparam NSEL = TM / TN;            // slices per entry (2)

    integer h;
    always @(posedge clock) begin
        if (wr_en) begin
            // one enable per slice: a full write asserts them all, a half write
            // only the one wr_sel names. Infers the memory's byte enables.
            for (h = 0; h < NSEL; h = h + 1)
                if (wr_full || (wr_sel == h[SEL_W-1:0]))
                    mem[wr_addr][h*WORD_BITS +: WORD_BITS] <=
                        wr_data[h*WORD_BITS +: WORD_BITS];
        end
        if (rd_en) begin
            dout  <= mem[rd_addr];
            sel_q <= rd_sel;
        end
    end

    // slice the stored entry down to the TN channels the array wants
    assign rd_data = dout[sel_q*WORD_BITS +: WORD_BITS];

endmodule

`default_nettype wire
