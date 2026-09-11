`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  wgt_buffer.v  -  banked on-chip weight store for the pointwise array
//
//  Build plan #3. This is the module that answers the hard number of
//  docs/controller_design.md section 5: pe_array consumes Tm*Tn = 512 int8
//  weights EVERY cycle, i.e. 4096 bit/cycle. No single memory delivers that,
//  so the store is split into Tm independent banks of Tn*8 = 128 bit, all
//  read with the SAME address. Bank m feeds lane m.
//
//      read : one address -> TM banks in parallel -> 4096 bit  (1 cycle)
//      write: ONE bank per cycle, 128 bit         -> matches a 128-bit AXI-HP
//                                                    beat from the DDR DMA
//
//  The asymmetry is the point: reads must be enormously wide because all Tm
//  lanes fire together, but writes only need to keep up with the DMA, which
//  is 128 bit/beat. Filling a layer therefore costs TM*entries cycles and is
//  meant to be overlapped with the previous layer's compute (double buffer).
//
//  Address layout (matches addr_gen directly):
//      rd_addr = oct * n_ic + ict
//  so walking ict fastest inside oct is a linear sweep - the feeder keeps a
//  plain counter instead of a multiplier.
//
//  Within an entry, bank m holds lane m's Tn weights for that (oct, ict):
//      rd_data[(m*TN + j)*DATA_W +: DATA_W]  =  w[(oct*TM + m)*IC + ict*TN + j]
//  which is exactly the bus layout pe_array expects, so the two wire together
//  with no reshuffling.
//
//  TAIL CONTRACT: the loader always writes the FULL n_oc*n_ic rectangle across
//  all TM banks, writing ZERO wherever there is no real weight (oc >= OC or
//  ic >= IC). A padded lane or tap then multiplies by zero and contributes
//  nothing, which is bit-exact and needs no masking logic anywhere in the
//  datapath. The memories are also zero-initialised below so a short load
//  cannot leak stale weights from the previous layer.
//
//  Sizing (measured from manifest.json): the largest pointwise layer is
//  features.18.0, 320->1280 at 7x7, needing 40*20 = 800 entries = 400 KB.
//  DEPTH 1024 leaves headroom and costs ~15 URAM.
//
//  Read latency is ONE cycle (registered output, so the memory infers as
//  BRAM/URAM rather than LUTRAM). The feeder must delay valid/first/last by
//  the same cycle or the accumulator clears on the wrong tile.
//
//  Run:  bash scripts/run_sim.sh wgt_buffer
//============================================================================
module wgt_buffer #(
    parameter DATA_W = 8,      // int8 weights
    parameter TM     = 32,     // banks = lanes
    parameter TN     = 16,     // weights per bank per read
    parameter DEPTH  = 1024,   // entries (max needed: 800)
    parameter ADDR_W = 10,     // clog2(DEPTH)
    parameter BANK_W = 5       // clog2(TM)   -- explicit, Verilog-2001
)(
    input  wire                     clock,

    // ---- write port: one 128-bit bank word per cycle (DMA fill) --------
    input  wire                     wr_en,
    input  wire [BANK_W-1:0]        wr_bank,
    input  wire [ADDR_W-1:0]        wr_addr,
    input  wire [TN*DATA_W-1:0]     wr_data,

    // ---- read port: all TM banks at one address -> 4096 bit ------------
    input  wire                     rd_en,
    input  wire [ADDR_W-1:0]        rd_addr,
    output wire [TM*TN*DATA_W-1:0]  rd_data
);

    localparam BANK_BITS = TN*DATA_W;    // 128

    genvar b;
    generate
        for (b = 0; b < TM; b = b + 1) begin : bank
            // One bank = one simple dual-port memory. Separate read and write
            // addresses, registered read data -> infers BRAM/URAM.
            reg [BANK_BITS-1:0] mem [0:DEPTH-1];
            reg [BANK_BITS-1:0] dout;

            // Zero the bank at power-up. On Xilinx this becomes the memory's
            // INIT and costs nothing; it also makes the tail contract above
            // hold even before the first load, and keeps simulation free of X.
            integer i;
            initial begin
                for (i = 0; i < DEPTH; i = i + 1) mem[i] = {BANK_BITS{1'b0}};
                dout = {BANK_BITS{1'b0}};
            end

            always @(posedge clock) begin
                if (wr_en && (wr_bank == b[BANK_W-1:0]))
                    mem[wr_addr] <= wr_data;
                if (rd_en)
                    dout <= mem[rd_addr];
            end

            assign rd_data[b*BANK_BITS +: BANK_BITS] = dout;
        end
    endgenerate

endmodule

`default_nettype wire
