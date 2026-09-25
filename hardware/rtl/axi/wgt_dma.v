`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  wgt_dma.v  -  the weight and parameter DMA: a read-only AXI4 master
//
//  This is the module that answers `ld_req`. top_seq has exposed that handshake
//  since build plan #6 and its header says, in as many words, that it "does NOT
//  contain the DMA"; accel_tb has played the DMA's part for the whole 64-op
//  network, bit-exact against the software golden, for every tensor. This file
//  replaces that testbench task with hardware.
//
//  What it is handed, per op, and nothing else:
//
//      ld_op     the opcode              (new - see DD-030 and the note below)
//      ld_off    byte offset into the weight blob
//      ld_bytes  how many bytes that blob holds for this op
//      ld_pchan  how many channels of requantize parameters to load
//
//  and what it must produce: the FULL rectangle of one of three differently
//  shaped weight buffers, plus ceil(pchan/TM)*TM parameter entries, then ONE
//  rising edge on `ld_done`.
//
//  ---- the one arithmetic fact the whole module rests on -----------------
//
//      taps per output channel = ld_bytes / ld_pchan
//
//  27 for the stem (CIN*K*K), 9 for a depthwise (K*K), and IC itself for a
//  pointwise. That is why there is no per-layer table here and no 64-entry ROM:
//  the same three numbers that say WHERE to read also say HOW to deal the bytes
//  out. It is computed once per load by the sequential divider below - 20
//  cycles, 64 times over the network, which is 1,280 cycles total and not worth
//  a second thought.
//
//  ---- why every load is ONE SEQUENTIAL BYTE STREAM ----------------------
//
//  This is the decision that makes this module small, and it is worth stating
//  because the obvious reading of the buffer contract leads somewhere much
//  worse.
//
//  wgt_buffer's address layout is  rd_addr = oct*n_ic + ict  with bank = lane,
//  so the natural way to describe a pointwise fill is "for each (oct, ict)
//  tile, write all TM banks" - the loop order (ot, it, m). Written that way the
//  DMA reads, for a fixed (ot, it), TN bytes from each of TM rows at stride IC:
//  a strided GATHER, which on a 128-bit AXI port means one burst per 16 bytes
//  and a read efficiency of 16/IC.
//
//  But the buffer takes an arbitrary (bank, addr) with every write. The ORDER
//  of the writes is therefore free; only the mapping is fixed. Reordering to
//  (ot, m, it) - output channel outer, input-channel tile inner - walks output
//  channels in exactly the order they are stored in the blob, and each
//  channel's IC bytes are contiguous AND immediately followed by the next
//  channel's. The same rectangle, the same addr = ot*n_ic + it, the same
//  bank = m; but now the address stream into DDR is one unbroken run from
//  ld_off to ld_off+ld_bytes.
//
//  And the same is true of the other two shapes: the stem walks ocx ascending
//  with 27 contiguous bytes each, the depthwise walks ch ascending with 9. So
//  all three collapse to the same three-part machine:
//
//      a SEQUENTIAL BYTE READER  - AR generator, burst splitter, R FIFO
//      a BYTE-GRANULAR REALIGNER - a two-beat window and a byte pointer
//      a DEALER                  - one nested counter, three output shapes
//
//  The alternative - honouring the (ot, it, m) order - would need either a
//  scatter/gather engine or ceil(IC/TN)*n_oc separate bursts per layer. On
//  features.18.0 (IC=320, OC=1280) that is 800 bursts of 16 bytes instead of
//  100 bursts of 256 beats.
//
//  ---- why the realigner is not optional ---------------------------------
//
//  In the compiled program every ld_off happens to be a multiple of 16, so a
//  beat-aligned reader would pass a base-alignment test. ROWS are what is not
//  aligned, and that is not a coincidence that can be relied on:
//
//      stem      27-byte rows   ocx*27 mod 16 cycles through 16 values
//      depthwise  9-byte rows
//      pointwise IC-byte rows - IC = 24 for features.3.conv.0.0 and
//                features.4.conv.0.0, so every odd output channel starts
//                8 bytes into a beat
//
//  Once the load is one sequential stream the row stride stops mattering by
//  itself - what remains is a single byte pointer into the stream, which is
//  what the window below is. It also makes an unaligned ld_off free, so a
//  future blob layout cannot break this silently. wgt_dma_tb drives a
//  deliberately odd offset for exactly that reason.
//
//  ---- the TAIL CONTRACT is honoured by writing, not by skipping ----------
//
//  wgt_buffer and param_buffer both state it: the loader writes the FULL
//  rectangle and puts ZERO wherever there is no real weight, so a padded lane
//  multiplies by zero and no masking logic is needed anywhere downstream. This
//  module therefore emits a write for every (bank, addr) in the rectangle,
//  including the channels past ld_pchan, and those writes carry zero. They
//  consume no bytes from the stream, which is why the stream length and the
//  write count are different numbers.
//
//  The per-lane byte mask below is the other half of the same contract: a
//  partial input-channel tile (IC=24 -> the second tile holds 8 real bytes)
//  has its remaining lanes zeroed rather than filled with the next channel's
//  weights, which is what a plain 16-byte copy would have done.
//
//  ---- the parameter blob: three regions (DD-030) -------------------------
//
//  There is no parameter offset in the instruction and there does not need to
//  be: ops execute in program order, so `pidx` below is a running index
//  advanced by ceil(pchan/TM)*TM after every load and reset on `start`. The
//  padding to a whole tile is already in the blob.
//
//  The three arrays are three DDR regions with three base registers, read as
//  three sequential streams per TM-channel tile into the staging memories
//  below. DD-030 records the decision, the rejected single-interleaved-record
//  alternative and the honest cost: an interleaved 16-byte record would have
//  made one beat one channel and removed both the staging and the stream
//  switching. The reason it was still rejected is that it would be a fourth
//  encoding of numbers export.py already writes and gen_program.py already
//  validates, and this project has twice paid for that class of drift.
//
//  Why staging is unavoidable here: param_buffer has ONE write port carrying
//  bias, m0 and shift together, a 128-bit beat of params_b.hex carries four
//  channels of bias and nothing else, and AXI4 (unlike AXI3) forbids read-data
//  interleaving - beats of one transaction are contiguous. So two of the three
//  arrays have to wait somewhere for the third, and one tile is the smallest
//  "somewhere" that keeps pl_bank = ch % TM / pl_addr = ch / TM trivial.
//
//  The staging memories are BEAT-shaped, not entry-shaped: 8 x 128 bit rather
//  than 32 x 32 bit. A beat carries four bias entries, so an entry-shaped array
//  would need four write ports and would synthesise to ~2,300 flip-flops; one
//  write port and a 4:1 read mux is the same 2,304 bits in LUTRAM.
//
//  LINEAR reads a whole tile and emits only NLOG=4 writes, so 15 of its 18
//  beats are discarded. That happens once per inference and buys uniformity:
//  one parameter phase, not two.
//
//  ---- why every output is REGISTERED ------------------------------------
//
//  The write data is a byte-granular shift of a two-beat window, which is a
//  16:1 mux per byte lane. Driving a memory write port through that
//  combinationally puts ~5 levels of logic between an AXI-side register and a
//  BRAM/LUTRAM write enable, on a design whose measured worst path is 8 levels
//  at 198.3 MHz. So the whole output group - three weight ports, the parameter
//  port and the classifier's - goes through one register stage. Throughput is
//  unchanged (it pipelines), latency grows by one cycle per load, and
//  accel_top's load ports become register-to-register paths, which is what
//  accel_top_ooc.xdc's "tighten these once the DMA is real" was waiting for.
//
//  ---- what happens when the bus says no ---------------------------------
//
//  RRESP != OKAY sets the sticky `dma_error` and the module STOPS: it drains
//  the outstanding transactions (the protocol requires accepting beats already
//  requested), then parks and never pulses `ld_done` again. top_seq's S_LOAD
//  watchdog then expires, sets its own sticky `fault` and abandons the run in
//  S_ERR, so the PS reads two bits and learns both that the run failed and that
//  the bus is why. A silent wrong-weights run is the one outcome that must not
//  be reachable, and pulsing ld_done on a failed read is the only way to get
//  there.
//
//  ---- an undecodable opcode is deliberately NOT this module's error -----
//
//  top_seq validates the opcode at S_GO, which is AFTER S_LOAD - so a program
//  carrying one of the ten encodings no feeder decodes reaches this module
//  first. Hanging here would replace T-2's precise message ("opcode N decodes
//  to no feeder at pc=M") with a 1M-cycle watchdog timeout that says nothing.
//  So an unknown opcode is treated as parameters-only: the weight phase is
//  skipped, ld_done pulses, and S_GO reports it properly one state later.
//
//  ---- one module, not two ----------------------------------------------
//
//  The reader and the dealer are separable and a split was considered: an
//  `axi_rd_stream.v` presenting (arm, addr, len) -> a byte stream, with this
//  file reduced to the dealer. Rejected because the split earns its keep only
//  with its own testbench, and the thing worth testing is the pair - a stream
//  reader that is right about beats and wrong about the first byte offset
//  passes any test written against it alone. The sections below are banner-
//  separated in the order the data flows, which is what the split would have
//  bought for reading.
//
//  Run:  bash scripts/run_sim.sh wgt_dma
//============================================================================
module wgt_dma #(
    // ---- datapath geometry: MUST match what accel_top is built with ------
    //  Not a second copy of the numbers - a second READER of them. accel_sys
    //  passes one set of parameters to both instances, so there is exactly one
    //  place where TM/TN/TC/TS are chosen. The *_LOG parameters follow the
    //  house style set by TSLOG / BANK_W / SEL_W: an explicit log with an
    //  elaboration check, rather than a clog2 function Verilog-2001 would let
    //  us write but that nothing else in this design uses.
    parameter DATA_W    = 8,
    parameter TM        = 32,   parameter TM_LOG = 5,
    parameter TN        = 16,   parameter TN_LOG = 4,
    parameter TC        = 16,   parameter TC_LOG = 4,
    parameter TS        = 8,    parameter TS_LOG = 3,
    parameter CIN       = 3,
    parameter K         = 3,
    parameter BIAS_W    = 32,
    parameter M0_W      = 32,
    parameter SHIFT_W   = 6,
    parameter PW_WA_W   = 10,
    parameter DW_WA_W   = 6,
    parameter ST_WA_W   = 4,
    parameter PA_W      = 6,
    parameter BANK_W    = 5,
    parameter DW_BANK_W = 4,
    parameter ST_BANK_W = 3,
    parameter NLOG      = 4,
    parameter IDX_W     = 2,

    // ---- the load handshake's field widths (top_seq's instruction) -------
    parameter OFF_W     = 24,   // ld_off
    parameter BYT_W     = 20,   // ld_bytes
    parameter PCH_W     = 16,   // ld_pchan

    // ---- AXI4 --------------------------------------------------------------
    parameter AXI_ADDR_W = 32,
    // 128 bit because that is BOTH the S_AXI_HP data width on the ZU+ AND the
    // pointwise bank word (TN*DATA_W). The elaboration check below ties them:
    // the whole single-cycle pointwise write depends on one beat being exactly
    // one bank word.
    parameter AXI_DATA_W = 128,
    parameter AXI_ID_W   = 4,
    parameter AXI_ID     = 0,
    // 256 is the AXI4 ceiling for INCR. Lower it to shorten the longest
    // uninterruptible read if the interconnect ever needs that.
    parameter MAX_BURST  = 256,
    // At least two, so the R channel does not go idle between bursts: the AR
    // for burst n+1 is issued while burst n is still streaming. This is the
    // parameter that decides whether features.18.0 sustains one bank write per
    // cycle, and wgt_dma_tb measures that rather than assuming it.
    parameter MAX_OUTST  = 4,
    parameter RFIFO_DEPTH = 32, parameter RFIFO_AW = 5
)(
    input  wire                        clock,
    input  wire                        rst_n,

    // `start` is top_seq's, and it means the same thing here: a new run begins
    // from a known state. It resets the parameter index, clears dma_error and
    // latches the configuration below.
    input  wire                        start,

    // ---- configuration, latched at `start` -------------------------------
    //  Plain input wires today. Shaped so an AXI-Lite CSR block can drive them
    //  later without touching this module: four write-only 32-bit registers,
    //  read once per run. AXI-Lite itself is a separate open item.
    input  wire [AXI_ADDR_W-1:0]       wgt_base,   // weights.hex     in DDR
    input  wire [AXI_ADDR_W-1:0]       pb_base,    // params_b.hex
    input  wire [AXI_ADDR_W-1:0]       pm_base,    // params_m0.hex
    input  wire [AXI_ADDR_W-1:0]       ps_base,    // params_shift.hex

    // ---- the handshake top_seq raises ------------------------------------
    input  wire                        ld_req,
    input  wire [3:0]                  ld_op,
    input  wire [OFF_W-1:0]            ld_off,
    input  wire [BYT_W-1:0]            ld_bytes,
    input  wire [PCH_W-1:0]            ld_pchan,
    // ONE cycle, and only after the last buffer write has been committed.
    // top_seq detects a RISING EDGE while ld_req is high (finding T-10): a
    // level left high from the previous load used to complete a load with no
    // data moved, so a pulse is not a style choice here.
    output reg                         ld_done,

    // ---- the four write ports of accel_top -------------------------------
    output reg                         pw_wl_en,
    output wire [BANK_W-1:0]           pw_wl_bank,
    output wire [PW_WA_W-1:0]          pw_wl_addr,
    output wire [TN*DATA_W-1:0]        pw_wl_data,

    output reg                         dw_wl_en,
    output wire [DW_BANK_W-1:0]        dw_wl_bank,
    output wire [DW_WA_W-1:0]          dw_wl_addr,
    output wire [K*K*DATA_W-1:0]       dw_wl_data,

    output reg                         st_wl_en,
    output wire [ST_BANK_W-1:0]        st_wl_bank,
    output wire [ST_WA_W-1:0]          st_wl_addr,
    output wire [CIN*K*K*DATA_W-1:0]   st_wl_data,

    output reg                         pl_en,
    output wire [BANK_W-1:0]           pl_bank,
    output wire [PA_W-1:0]             pl_addr,
    output wire signed [BIAS_W-1:0]    pl_bias,
    output wire signed [M0_W-1:0]      pl_m0,
    output wire [SHIFT_W-1:0]          pl_shift,

    output reg                         lg_pl_en,
    output wire [IDX_W-1:0]            lg_pl_idx,
    output wire signed [BIAS_W-1:0]    lg_pl_bias,
    output wire signed [M0_W-1:0]      lg_pl_m0,
    output wire [SHIFT_W-1:0]          lg_pl_shift,

    // ---- status ----------------------------------------------------------
    //  Sticky, cleared only by `start` or reset. Read it next to top_seq's
    //  `fault`: fault alone means the accelerator gave up, fault AND dma_error
    //  means the bus is why.
    output reg                         dma_error,

    // ---- AXI4 read-only master -------------------------------------------
    output wire [AXI_ID_W-1:0]         m_axi_arid,
    output reg  [AXI_ADDR_W-1:0]       m_axi_araddr,
    output reg  [7:0]                  m_axi_arlen,
    output wire [2:0]                  m_axi_arsize,
    output wire [1:0]                  m_axi_arburst,
    output wire                        m_axi_arlock,
    output wire [3:0]                  m_axi_arcache,
    output wire [2:0]                  m_axi_arprot,
    output reg                         m_axi_arvalid,
    input  wire                        m_axi_arready,

    input  wire [AXI_ID_W-1:0]         m_axi_rid,
    input  wire [AXI_DATA_W-1:0]       m_axi_rdata,
    input  wire [1:0]                  m_axi_rresp,
    input  wire                        m_axi_rlast,
    input  wire                        m_axi_rvalid,
    output wire                        m_axi_rready
);

    // ======================================================================
    //  derived constants
    // ======================================================================
    //  BYTE_W is 8 because a byte is 8 bits. It is deliberately NOT written as
    //  DATA_W even though DATA_W is also 8: DATA_W is the activation width, and
    //  the two being equal is a property of int8 quantization, not a rule. The
    //  blobs are byte arrays in DDR whatever the datapath happens to be.
    localparam BYTE_W     = 8;

    localparam BEAT_BYTES = AXI_DATA_W / BYTE_W;        // 16
    localparam BB_LOG     = TN_LOG;                     // 4, checked below
    localparam TAP_MAX    = CIN * K * K;                // 27, the stem's row
    localparam ST_BITS    = TAP_MAX * DATA_W;           // 216
    localparam ST_HI      = ST_BITS - AXI_DATA_W;       // 88
    localparam DW_BITS    = K * K * DATA_W;             // 72
    localparam PW_BITS    = TN * DATA_W;                // 128

    //  The AXI4 4 KB boundary rule. Not a tunable - a burst may not cross it.
    localparam AXI_PAGE   = 4096;
    localparam PAGE_BEATS = AXI_PAGE / BEAT_BYTES;      // 256
    localparam BURST_CAP  = (MAX_BURST < PAGE_BEATS) ? MAX_BURST : PAGE_BEATS;

    //  bytes per parameter entry, per array, and beats per TM-channel tile
    localparam B_BYTES    = BIAS_W / BYTE_W;            // 4
    localparam M_BYTES    = M0_W   / BYTE_W;            // 4
    localparam S_BYTES    = 1;                          // the shift is one byte
    localparam B_ROWS     = (TM * B_BYTES) / BEAT_BYTES;  // 8
    localparam S_ROWS     = (TM * S_BYTES) / BEAT_BYTES;  // 2
    localparam EPB_BM     = BEAT_BYTES / B_BYTES;         // 4 entries per beat
    localparam EPB_S      = BEAT_BYTES / S_BYTES;         // 16

    //  Counter widths. The largest single load is features.18.0 at 409,600
    //  bytes, so BYT_W covers every byte count and the beat count is narrower.
    localparam BEATS_W    = BYT_W;
    localparam PIDX_W     = 20;      // 19,264 entries in the parameter blob
    localparam CHK_W      = BB_LOG + 2;   // chunk / gathered-bytes counters

    localparam [1:0] RESP_OKAY = 2'b00, RESP_EXOKAY = 2'b01;

    // ---- opcodes, matching accel_top's ----------------------------------
    localparam [3:0] OP_STEM   = 4'd1,
                     OP_PW     = 4'd2,
                     OP_DW     = 4'd3,
                     OP_LINEAR = 4'd6;

    // ======================================================================
    //  elaboration checks
    // ======================================================================
    //  Same idiom as wgt_buffer.v:81-88 and top_seq.v:146-150: Verilog-2001 has
    //  no $fatal at elaboration, so the check instantiates a module that does
    //  not exist. Elaboration fails and the tool prints the module name, which
    //  IS the error message. Every one of these guards a number that, if wrong,
    //  produces WRONG WEIGHTS rather than a compile error.
    generate
        if ((1 << TM_LOG) != TM) begin : chk_tm
            ERROR_WGT_DMA_TM_LOG_DOES_NOT_MATCH_TM u_err();
        end
        if ((1 << TN_LOG) != TN) begin : chk_tn
            ERROR_WGT_DMA_TN_LOG_DOES_NOT_MATCH_TN u_err();
        end
        if ((1 << TC_LOG) != TC) begin : chk_tc
            ERROR_WGT_DMA_TC_LOG_DOES_NOT_MATCH_TC u_err();
        end
        if ((1 << TS_LOG) != TS) begin : chk_ts
            ERROR_WGT_DMA_TS_LOG_DOES_NOT_MATCH_TS u_err();
        end
        // One beat IS one pointwise bank word. The single-cycle pointwise write
        // depends on it, and so does BB_LOG being TN_LOG.
        if (AXI_DATA_W != TN * DATA_W) begin : chk_beat
            ERROR_WGT_DMA_AXI_DATA_W_MUST_EQUAL_TN_TIMES_DATA_W u_err();
        end
        if (DATA_W != BYTE_W) begin : chk_byte
            ERROR_WGT_DMA_BLOBS_ARE_BYTE_ARRAYS_DATA_W_MUST_BE_8 u_err();
        end
        // The stem's row must need MORE than one beat and AT MOST two: the word
        // assembly latches exactly one beat and has exactly two placements.
        if (TAP_MAX <= BEAT_BYTES) begin : chk_tap_lo
            ERROR_WGT_DMA_STEM_ROW_FITS_ONE_BEAT_SIMPLIFY_THE_ASSEMBLY u_err();
        end
        if (TAP_MAX > 2 * BEAT_BYTES) begin : chk_tap_hi
            ERROR_WGT_DMA_STEM_ROW_NEEDS_MORE_THAN_TWO_BEATS u_err();
        end
        // A beat must reach the 4 KB page in at most 256 beats, or ARLEN cannot
        // express a full-page burst.
        if (PAGE_BEATS > 256) begin : chk_page
            ERROR_WGT_DMA_BEAT_TOO_NARROW_FOR_A_256_BEAT_PAGE u_err();
        end
        if ((MAX_BURST < 1) || (MAX_BURST > 256)) begin : chk_burst
            ERROR_WGT_DMA_MAX_BURST_OUT_OF_AXI4_RANGE u_err();
        end
        // Two outstanding is the throughput requirement, not a preference.
        if (MAX_OUTST < 2) begin : chk_outst_lo
            ERROR_WGT_DMA_MAX_OUTST_MUST_BE_AT_LEAST_TWO u_err();
        end
        if (MAX_OUTST > 8) begin : chk_outst_hi
            ERROR_WGT_DMA_OUTST_COUNTER_IS_FOUR_BITS u_err();
        end
        if (RFIFO_DEPTH != (1 << RFIFO_AW)) begin : chk_fifo
            ERROR_WGT_DMA_RFIFO_DEPTH_MUST_BE_TWO_POW_RFIFO_AW u_err();
        end
        if (RFIFO_DEPTH < 4) begin : chk_fifo_min
            ERROR_WGT_DMA_RFIFO_TOO_SHALLOW_TO_COVER_AR_LATENCY u_err();
        end
        // A parameter tile must be a whole number of beats in all three arrays,
        // or the staging rows do not line up with the channels. And bias and m0
        // must be the same width, because one row/entry counter pair walks both.
        if (((TM * B_BYTES) % BEAT_BYTES) != 0) begin : chk_brow
            ERROR_WGT_DMA_BIAS_TILE_IS_NOT_A_WHOLE_NUMBER_OF_BEATS u_err();
        end
        if (((TM * S_BYTES) % BEAT_BYTES) != 0) begin : chk_srow
            ERROR_WGT_DMA_SHIFT_TILE_IS_NOT_A_WHOLE_NUMBER_OF_BEATS u_err();
        end
        if (BIAS_W != M0_W) begin : chk_bm
            ERROR_WGT_DMA_BIAS_AND_M0_MUST_BE_THE_SAME_WIDTH u_err();
        end
        if (NLOG > TM) begin : chk_nlog
            ERROR_WGT_DMA_CLASSIFIER_HAS_MORE_CLASSES_THAN_A_TILE u_err();
        end
        if (SHIFT_W > BYTE_W) begin : chk_shift
            ERROR_WGT_DMA_SHIFT_IS_ONE_BYTE_IN_THE_BLOB u_err();
        end
        // The shared bank register holds the widest of the three lane counts,
        // and the shared address register the widest of the three addresses.
        if (((1 << BANK_W) < TM) || ((1 << BANK_W) < TC)
            || ((1 << BANK_W) < TS) || ((1 << BANK_W) < EPB_S)) begin : chk_bank
            ERROR_WGT_DMA_BANK_W_TOO_NARROW_FOR_TM_TC_TS_OR_A_BEAT u_err();
        end
        if ((PW_WA_W < DW_WA_W) || (PW_WA_W < ST_WA_W)) begin : chk_addr
            ERROR_WGT_DMA_PW_WA_W_MUST_BE_THE_WIDEST_WEIGHT_ADDRESS u_err();
        end
    endgenerate

    // ======================================================================
    //  the latched request, and the shape it implies
    // ======================================================================
    reg [3:0]            q_op;
    reg [OFF_W-1:0]      q_off;
    reg [BYT_W-1:0]      q_bytes;
    reg [PCH_W-1:0]      q_pchan;
    reg [BYT_W-1:0]      q_taps;      // ld_bytes / ld_pchan
    reg [7:0]            q_ntile;     // ceil(pchan/TM) - parameter tiles, and
                                      // the pointwise oc-tile count: same value
    reg [AXI_ADDR_W-1:0] c_wgt, c_pb, c_pm, c_ps;
    reg [PIDX_W-1:0]     pidx;        // running index into the parameter blob

    wire is_stem = (q_op == OP_STEM);
    wire is_dw   = (q_op == OP_DW);
    wire is_pw   = (q_op == OP_PW) || (q_op == OP_LINEAR);
    wire is_lin  = (q_op == OP_LINEAR);
    // RES_ADD and GAP carry parameters only; so does any opcode this module
    // does not recognise - see the header. `has_wgt` is the single decision.
    wire has_wgt = (q_bytes != {BYT_W{1'b0}}) && (is_stem || is_dw || is_pw);

    // ======================================================================
    //  taps = ld_bytes / ld_pchan  -  a plain restoring divider
    // ======================================================================
    //  BYT_W iterations, once per load. A combinational divider would be the
    //  only multi-level arithmetic in the module and would sit on nothing's
    //  critical path but its own; a sequential one costs 20 cycles out of a
    //  load that is at minimum 50 and at most ~28,000.
    reg [BYT_W-1:0]   div_n;      // shrinking dividend
    reg [BYT_W:0]     div_r;      // remainder, one bit wider for the shift-in
    reg [BYT_W-1:0]   div_q;
    reg [5:0]         div_i;
    reg               div_run;

    wire [BYT_W:0] div_dv    = {{(BYT_W+1-PCH_W){1'b0}}, q_pchan};
    wire [BYT_W:0] div_r_sh  = {div_r[BYT_W-1:0], div_n[BYT_W-1]};
    wire           div_ge    = (div_r_sh >= div_dv);

    // ======================================================================
    //  the sequential byte reader
    // ======================================================================
    //  Armed with a byte address and a byte length. It reads the ALIGNED beats
    //  that cover [addr, addr+len) and presents them as a beat stream; the
    //  window below turns that into bytes starting at addr itself.
    reg                   rd_arm;       // one cycle: (re)start a stream
    reg [AXI_ADDR_W-1:0]  rd_addr;
    reg [BEATS_W-1:0]     rd_len;       // bytes

    wire [BB_LOG-1:0]     rd_q     = rd_addr[BB_LOG-1:0];
    wire [AXI_ADDR_W-1:0] rd_align = {rd_addr[AXI_ADDR_W-1:BB_LOG], {BB_LOG{1'b0}}};
    // ceil((q + len) / BEAT_BYTES)
    wire [BEATS_W:0]      rd_beats = ({{(BEATS_W+1-BB_LOG){1'b0}}, rd_q}
                                      + {1'b0, rd_len}
                                      + BEAT_BYTES[BEATS_W:0] - {{BEATS_W{1'b0}}, 1'b1})
                                     >> BB_LOG;

    // ---- AR generator -----------------------------------------------------
    reg  [AXI_ADDR_W-1:0] ar_addr;
    reg  [BEATS_W:0]      ar_left;      // beats still to request
    reg  [3:0]            outst;        // accepted transactions, RLAST pending

    //  Beats left in the current 4 KB page: a burst may not cross it.
    wire [8:0] pg_left = PAGE_BEATS[8:0] - {1'b0, ar_addr[11:BB_LOG]};
    wire [8:0] cap     = (pg_left > BURST_CAP[8:0]) ? BURST_CAP[8:0] : pg_left;
    wire [8:0] blen    = (ar_left > {{(BEATS_W-8){1'b0}}, cap}) ? cap : ar_left[8:0];

    wire ar_go = (ar_left != {(BEATS_W+1){1'b0}}) && (outst < MAX_OUTST[3:0])
                 && !m_axi_arvalid && !dma_error && !rd_arm;

    assign m_axi_arid    = AXI_ID[AXI_ID_W-1:0];
    assign m_axi_arsize  = BB_LOG[2:0];        // 2**size bytes per beat = 16
    assign m_axi_arburst = 2'b01;              // INCR
    assign m_axi_arlock  = 1'b0;
    // 4'b0011 = modifiable, bufferable: an ordinary non-cacheable read, which
    // is what the HP port wants for a DDR region the PS has already flushed.
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;             // data, secure, unprivileged

    // ---- R FIFO -----------------------------------------------------------
    reg [AXI_DATA_W-1:0] rf [0:RFIFO_DEPTH-1];
    reg [RFIFO_AW-1:0]   rf_wp, rf_rp;
    reg [RFIFO_AW:0]     rf_cnt;

    wire rf_full  = (rf_cnt == RFIFO_DEPTH[RFIFO_AW:0]);
    wire rf_empty = (rf_cnt == {(RFIFO_AW+1){1'b0}});
    wire rf_push  = m_axi_rvalid && m_axi_rready;
    wire [AXI_DATA_W-1:0] rf_out = rf[rf_rp];

    // Beats already requested must be accepted even while erroring out, or the
    // slave is left holding an incomplete transaction.
    assign m_axi_rready = !rf_full || dma_error;

    // ---- the two-beat window and the byte pointer -------------------------
    reg [AXI_DATA_W-1:0] w0, w1;     // w0 holds the older beat
    reg [1:0]            wcnt;       // valid beats in the window, 0..2
    reg [BB_LOG-1:0]     wp;         // byte pointer into w0

    wire [2*AXI_DATA_W-1:0] win = {w1, w0};
    // The realigner proper: BEAT_BYTES bytes starting at byte wp of the stream.
    wire [AXI_DATA_W-1:0]   ext = win >> {wp, 3'b000};

    wire [CHK_W:0] win_bytes = {{(CHK_W-1){1'b0}}, wcnt} << BB_LOG;  // 0/16/32
    wire [CHK_W:0] avail     = (win_bytes > {{(CHK_W+1-BB_LOG){1'b0}}, wp})
                               ? (win_bytes - {{(CHK_W+1-BB_LOG){1'b0}}, wp})
                               : {(CHK_W+1){1'b0}};

    // Driven by the dealer below: consume `tk` bytes this cycle.
    wire [CHK_W-1:0] tk;
    wire             take;

    wire [CHK_W:0] wp_sum = {{(CHK_W+1-BB_LOG){1'b0}}, wp} + {1'b0, tk};
    wire           retire = take && (wp_sum >= BEAT_BYTES[CHK_W:0]);

    wire [1:0] wcnt_ar  = wcnt - {1'b0, retire};        // after the retire
    wire       win_push = !rf_empty && (wcnt_ar < 2'd2) && !rd_arm;
    wire       rf_pop   = win_push;

    // One assignment per path, computed here rather than by two NBAs in the
    // clocked block: C-12 is on record for what last-assignment-wins cost in
    // stem_feeder.
    wire [AXI_DATA_W-1:0] w0_surv = retire ? w1 : w0;
    wire [AXI_DATA_W-1:0] w0_nxt  = (win_push && (wcnt_ar == 2'd0)) ? rf_out : w0_surv;
    wire [AXI_DATA_W-1:0] w1_nxt  = (win_push && (wcnt_ar == 2'd1)) ? rf_out
                                    : (retire ? {AXI_DATA_W{1'b0}} : w1);

    // ======================================================================
    //  the dealer's nested counter
    // ======================================================================
    //  One loop for all three shapes, lp_c innermost:
    //
    //      shape   lp_a          lp_b        lp_c      bank    addr
    //      STEM    oc tile       lane 0..TS  (1)       lp_b    lp_a
    //      DW      group         ch 0..TC    (1)       lp_b    lp_a
    //      PW      oc tile       lane 0..TM  ic tile   lp_b    a_base+lp_c
    //
    //  ocx advances when lp_c wraps, which for the stem and the depthwise is
    //  every word. The order is what the header's "one sequential byte stream"
    //  paragraph is about: lp_c innermost walks one output channel's taps in
    //  blob order, and lp_b then moves to the next output channel, which is the
    //  next bytes in the blob.
    reg [7:0]         lp_a, lp_c;
    reg [BANK_W-1:0]  lp_b;
    reg [7:0]         lim_a, lim_c;
    reg [BANK_W-1:0]  lim_b;
    reg [PCH_W-1:0]   ocx;
    reg [PW_WA_W-1:0] a_base;        // lp_a * lim_c, kept by accumulation
    reg [BYT_W-1:0]   ic_left;       // taps not yet dealt for this channel

    wire ch_real = (ocx < q_pchan);

    //  Bytes this bank word needs. Zero for a padded output channel, which
    //  still gets a write - the TAIL CONTRACT - but consumes no stream.
    wire [CHK_W-1:0] need = !ch_real ? {CHK_W{1'b0}}
                          : is_pw    ? ((ic_left > BEAT_BYTES[BYT_W-1:0])
                                          ? BEAT_BYTES[CHK_W-1:0]
                                          : ic_left[CHK_W-1:0])
                                     : q_taps[CHK_W-1:0];

    reg [CHK_W-1:0]      gh;         // bytes of this word already gathered
    reg [AXI_DATA_W-1:0] lo_q;       // the stem's first beat, latched

    wire [CHK_W-1:0] chunk_full = need - gh;
    wire [CHK_W-1:0] chunk      = (chunk_full > BEAT_BYTES[CHK_W-1:0])
                                  ? BEAT_BYTES[CHK_W-1:0] : chunk_full;
    wire             chunk_last = ((gh + chunk) == need);

    // ---- the per-lane byte mask: the other half of the tail contract ------
    wire [AXI_DATA_W-1:0] ext_m;
    genvar mi;
    generate
        for (mi = 0; mi < BEAT_BYTES; mi = mi + 1) begin : lane_mask
            assign ext_m[mi*BYTE_W +: BYTE_W] =
                (mi < chunk) ? ext[mi*BYTE_W +: BYTE_W] : {BYTE_W{1'b0}};
        end
    endgenerate

    // ======================================================================
    //  parameter staging: beat-shaped, one write port
    // ======================================================================
    reg [AXI_DATA_W-1:0] b_stg [0:B_ROWS-1];
    reg [AXI_DATA_W-1:0] m_stg [0:B_ROWS-1];
    reg [AXI_DATA_W-1:0] s_stg [0:S_ROWS-1];

    reg [7:0]         pf_i, pf_n;      // staging row being filled / rows total
    reg [7:0]         p_tile;          // tile index within this op
    reg [PIDX_W-1:0]  p_cur;           // pidx + p_tile*TM
    reg [BANK_W-1:0]  pe_j;            // channel within the tile, 0..TM-1
    reg [7:0]         pe_rb, pe_rs;    // staging row for bias/m0, and for shift
    reg [BANK_W-1:0]  pe_sb, pe_ss;    // entry within that row

    // The 4:1 (bias/m0) and 16:1 (shift) read muxes the beat-shaped staging
    // buys in exchange for one write port instead of four.
    wire [BIAS_W-1:0] stg_bias  = b_stg[pe_rb][pe_sb*BIAS_W +: BIAS_W];
    wire [M0_W-1:0]   stg_m0    = m_stg[pe_rb][pe_sb*M0_W   +: M0_W];
    wire [BYTE_W-1:0] stg_shift = s_stg[pe_rs][pe_ss*BYTE_W +: BYTE_W];

    // ======================================================================
    //  the registered output stage
    // ======================================================================
    //  One data register wide enough for the stem, sliced down for the other
    //  two ports; one bank register; one address register. The parameter port
    //  and the classifier's share a second set, because LINEAR sends the same
    //  three fields to lg_pl_* instead of pl_*.
    reg [ST_BITS-1:0]       wd_q;
    reg [BANK_W-1:0]        wb_q;
    reg [PW_WA_W-1:0]       wa_q;
    reg signed [BIAS_W-1:0] pd_bias;
    reg signed [M0_W-1:0]   pd_m0;
    reg [SHIFT_W-1:0]       pd_shift;
    reg [BANK_W-1:0]        pd_bank;
    reg [PA_W-1:0]          pd_addr;

    assign pw_wl_data = wd_q[PW_BITS-1:0];
    assign dw_wl_data = wd_q[DW_BITS-1:0];
    assign st_wl_data = wd_q;
    assign pw_wl_bank = wb_q;
    assign dw_wl_bank = wb_q[DW_BANK_W-1:0];
    assign st_wl_bank = wb_q[ST_BANK_W-1:0];
    assign pw_wl_addr = wa_q;
    assign dw_wl_addr = wa_q[DW_WA_W-1:0];
    assign st_wl_addr = wa_q[ST_WA_W-1:0];

    assign pl_bias     = pd_bias;
    assign pl_m0       = pd_m0;
    assign pl_shift    = pd_shift;
    assign pl_bank     = pd_bank;
    assign pl_addr     = pd_addr;
    assign lg_pl_bias  = pd_bias;
    assign lg_pl_m0    = pd_m0;
    assign lg_pl_shift = pd_shift;
    assign lg_pl_idx   = pd_bank[IDX_W-1:0];

    //  The word that would be written this cycle. For the stem the low beat
    //  comes from lo_q and the high ST_HI bits from the masked second chunk;
    //  for everything else gh is always zero and the upper bits are zero, which
    //  is exactly what a padded lane needs.
    wire [ST_BITS-1:0] word_now = (gh != {CHK_W{1'b0}})
                                  ? {ext_m[ST_HI-1:0], lo_q}
                                  : {{ST_HI{1'b0}}, ext_m};

    // ======================================================================
    //  the state machine
    // ======================================================================
    localparam S_IDLE  = 5'd0,   // waiting for ld_req
               S_DIV   = 5'd1,   // taps = bytes / pchan
               S_SHAPE = 5'd2,   // set the loop limits
               S_WARM  = 5'd3,   // arm the reader for the weight stream
               S_WDEAL = 5'd4,   // deal the weight rectangle
               S_PNEXT = 5'd5,   // next parameter tile, or done
               S_PBA   = 5'd6,   // arm the bias stream
               S_PB    = 5'd7,   // fill the bias staging
               S_PMA   = 5'd8,   // arm the m0 stream
               S_PM    = 5'd9,   // fill the m0 staging
               S_PSA   = 5'd10,  // arm the shift stream
               S_PS    = 5'd11,  // fill the shift staging
               S_PEMIT = 5'd12,  // write the tile to param_buffer
               S_FLUSH = 5'd13,  // let the last registered write commit
               S_DONE  = 5'd14,  // pulse ld_done
               S_ACK   = 5'd15,  // wait for top_seq to drop ld_req
               S_DRAIN = 5'd16,  // wait out the requested beats after an abort
               S_ERR   = 5'd17;  // parked: dma_error set, ld_done never again

    reg [4:0] st;

    //  The dealer consumes only in the states that read the stream, and never
    //  in the cycle a stream is being armed - the window still holds the
    //  previous stream's bytes until the end of that cycle.
    wire deal_ok  = (st == S_WDEAL) && !rd_arm
                    && (avail >= {1'b0, chunk});
    wire pfill_ok = ((st == S_PB) || (st == S_PM) || (st == S_PS)) && !rd_arm
                    && (avail >= BEAT_BYTES[CHK_W:0]);

    assign take = (deal_ok && (chunk != {CHK_W{1'b0}})) || pfill_ok;
    assign tk   = pfill_ok ? BEAT_BYTES[CHK_W-1:0] : chunk;

    //  Loop advance, computed once and used by both the counter update and the
    //  end-of-rectangle test.
    wire c_wrap = (lp_c == (lim_c - 8'd1));
    wire b_wrap = c_wrap && (lp_b == (lim_b - {{(BANK_W-1){1'b0}}, 1'b1}));
    wire a_wrap = b_wrap && (lp_a == (lim_a - 8'd1));
    wire w_emit = deal_ok && chunk_last;

    //  Parameter emit: LINEAR writes NLOG entries, everything else a whole tile.
    wire [BANK_W-1:0] pe_lim = is_lin ? NLOG[BANK_W-1:0] : TM[BANK_W-1:0];
    wire pe_last = (pe_j == (pe_lim - {{(BANK_W-1){1'b0}}, 1'b1}));

    integer ri;
    initial begin
        for (ri = 0; ri < RFIFO_DEPTH; ri = ri + 1) rf[ri]    = {AXI_DATA_W{1'b0}};
        for (ri = 0; ri < B_ROWS;      ri = ri + 1) b_stg[ri] = {AXI_DATA_W{1'b0}};
        for (ri = 0; ri < B_ROWS;      ri = ri + 1) m_stg[ri] = {AXI_DATA_W{1'b0}};
        for (ri = 0; ri < S_ROWS;      ri = ri + 1) s_stg[ri] = {AXI_DATA_W{1'b0}};
    end

    // ======================================================================
    //  AXI AR channel, the R FIFO and the window
    // ======================================================================
    always @(posedge clock) begin
        if (!rst_n) begin
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= {AXI_ADDR_W{1'b0}};
            m_axi_arlen   <= 8'd0;
            ar_addr <= {AXI_ADDR_W{1'b0}};
            ar_left <= {(BEATS_W+1){1'b0}};
            outst   <= 4'd0;
            rf_wp   <= {RFIFO_AW{1'b0}};
            rf_rp   <= {RFIFO_AW{1'b0}};
            rf_cnt  <= {(RFIFO_AW+1){1'b0}};
            w0      <= {AXI_DATA_W{1'b0}};
            w1      <= {AXI_DATA_W{1'b0}};
            wcnt    <= 2'd0;
            wp      <= {BB_LOG{1'b0}};
        end else begin
            // ---- AR ------------------------------------------------------
            if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arvalid <= 1'b0;
                outst         <= outst + 4'd1;
            end

            // A stream is only ever armed with outst == 0 and no AR in flight
            // (S_WARM / S_PBA / S_PMA / S_PSA all wait for it), so restarting
            // the address generator here cannot orphan a transaction.
            if (rd_arm) begin
                ar_addr <= rd_align;
                ar_left <= rd_beats;
                wcnt    <= 2'd0;
                wp      <= rd_q;
                rf_wp   <= {RFIFO_AW{1'b0}};
                rf_rp   <= {RFIFO_AW{1'b0}};
                rf_cnt  <= {(RFIFO_AW+1){1'b0}};
            end else begin
                if (ar_go) begin
                    m_axi_arvalid <= 1'b1;
                    m_axi_araddr  <= ar_addr;
                    m_axi_arlen   <= blen[7:0] - 8'd1;
                    ar_addr       <= ar_addr
                                     + ({{(AXI_ADDR_W-9){1'b0}}, blen} << BB_LOG);
                    ar_left       <= ar_left - {{(BEATS_W-8){1'b0}}, blen};
                end

                // ---- R ---------------------------------------------------
                if (rf_push) begin
                    rf[rf_wp] <= m_axi_rdata;
                    rf_wp     <= rf_wp + {{(RFIFO_AW-1){1'b0}}, 1'b1};
                    if (m_axi_rlast && (outst != 4'd0)) outst <= outst - 4'd1;
                end
                // rf_cnt tracks push and pop together, so both can happen in
                // one cycle and the count stays right.
                if (rf_push && !rf_pop)      rf_cnt <= rf_cnt + {{RFIFO_AW{1'b0}}, 1'b1};
                else if (!rf_push && rf_pop) rf_cnt <= rf_cnt - {{RFIFO_AW{1'b0}}, 1'b1};
                if (rf_pop) rf_rp <= rf_rp + {{(RFIFO_AW-1){1'b0}}, 1'b1};

                // ---- the window ------------------------------------------
                if (win_push || retire) begin
                    w0   <= w0_nxt;
                    w1   <= w1_nxt;
                    wcnt <= wcnt_ar + {1'b0, win_push};
                end
                if (take) begin
                    wp <= retire ? (wp_sum[BB_LOG-1:0] - BEAT_BYTES[BB_LOG-1:0])
                                 : wp_sum[BB_LOG-1:0];
                end
            end
        end
    end

    // ======================================================================
    //  the divider
    // ======================================================================
    always @(posedge clock) begin
        if (!rst_n) begin
            div_run <= 1'b0;
            div_n   <= {BYT_W{1'b0}};
            div_r   <= {(BYT_W+1){1'b0}};
            div_q   <= {BYT_W{1'b0}};
            div_i   <= 6'd0;
        end else if ((st == S_IDLE) && ld_req && !dma_error) begin
            div_n   <= ld_bytes;
            div_r   <= {(BYT_W+1){1'b0}};
            div_q   <= {BYT_W{1'b0}};
            div_i   <= BYT_W[5:0];
            // pchan == 0 cannot reach here behind ld_req (top_seq's `no_load`),
            // and bytes == 0 is RES_ADD / GAP: both leave the quotient at zero,
            // which is what a params-only load wants.
            div_run <= (ld_pchan != {PCH_W{1'b0}}) && (ld_bytes != {BYT_W{1'b0}});
        end else if (div_run) begin
            div_n <= {div_n[BYT_W-2:0], 1'b0};
            div_r <= div_ge ? (div_r_sh - div_dv) : div_r_sh;
            div_q <= {div_q[BYT_W-2:0], div_ge};
            div_i <= div_i - 6'd1;
            if (div_i == 6'd1) div_run <= 1'b0;
        end
    end

    // ======================================================================
    //  the sequencer, the dealer and the output registers
    // ======================================================================
    always @(posedge clock) begin
        if (!rst_n) begin
            st <= S_IDLE;
            ld_done   <= 1'b0;
            dma_error <= 1'b0;
            pidx      <= {PIDX_W{1'b0}};
            rd_arm    <= 1'b0;
            rd_addr   <= {AXI_ADDR_W{1'b0}};
            rd_len    <= {BEATS_W{1'b0}};
            q_op      <= 4'd0;
            q_off     <= {OFF_W{1'b0}};
            q_bytes   <= {BYT_W{1'b0}};
            q_pchan   <= {PCH_W{1'b0}};
            q_taps    <= {BYT_W{1'b0}};
            q_ntile   <= 8'd0;
            c_wgt <= {AXI_ADDR_W{1'b0}}; c_pb <= {AXI_ADDR_W{1'b0}};
            c_pm  <= {AXI_ADDR_W{1'b0}}; c_ps <= {AXI_ADDR_W{1'b0}};
            lp_a  <= 8'd0; lp_b  <= {BANK_W{1'b0}};                  lp_c  <= 8'd0;
            lim_a <= 8'd1; lim_b <= {{(BANK_W-1){1'b0}}, 1'b1};      lim_c <= 8'd1;
            ocx     <= {PCH_W{1'b0}};
            a_base  <= {PW_WA_W{1'b0}};
            ic_left <= {BYT_W{1'b0}};
            gh      <= {CHK_W{1'b0}};
            lo_q    <= {AXI_DATA_W{1'b0}};
            pf_i    <= 8'd0;
            pf_n    <= 8'd0;
            p_tile  <= 8'd0;
            p_cur   <= {PIDX_W{1'b0}};
            pe_j    <= {BANK_W{1'b0}};
            pe_rb   <= 8'd0; pe_rs <= 8'd0;
            pe_sb   <= {BANK_W{1'b0}}; pe_ss <= {BANK_W{1'b0}};
            pw_wl_en <= 1'b0; dw_wl_en <= 1'b0; st_wl_en <= 1'b0;
            pl_en    <= 1'b0; lg_pl_en <= 1'b0;
            wd_q <= {ST_BITS{1'b0}}; wb_q <= {BANK_W{1'b0}};
            wa_q <= {PW_WA_W{1'b0}};
            pd_bias  <= {BIAS_W{1'b0}};  pd_m0   <= {M0_W{1'b0}};
            pd_shift <= {SHIFT_W{1'b0}}; pd_bank <= {BANK_W{1'b0}};
            pd_addr  <= {PA_W{1'b0}};
        end else begin
            // Every write enable and ld_done is a single cycle, and rd_arm is a
            // single-cycle pulse. Defaults first; the state that means to
            // assert one overrides it below.
            pw_wl_en <= 1'b0;
            dw_wl_en <= 1'b0;
            st_wl_en <= 1'b0;
            pl_en    <= 1'b0;
            lg_pl_en <= 1'b0;
            ld_done  <= 1'b0;
            rd_arm   <= 1'b0;

            case (st)

            // ---- waiting ---------------------------------------------
            S_IDLE: if (ld_req) begin
                q_op    <= ld_op;
                q_off   <= ld_off;
                q_bytes <= ld_bytes;
                q_pchan <= ld_pchan;
                // ceil(pchan/TM): the parameter blob's own padding, and for a
                // pointwise also the oc-tile count. One expression, one value.
                q_ntile <= ((ld_pchan + TM[PCH_W-1:0]
                             - {{(PCH_W-1){1'b0}}, 1'b1}) >> TM_LOG);
                st      <= S_DIV;
            end

            // ---- taps -------------------------------------------------
            S_DIV: if (!div_run) begin
                q_taps <= div_q;
                st     <= S_SHAPE;
            end

            // ---- the loop limits --------------------------------------
            S_SHAPE: begin
                lp_a    <= 8'd0;
                lp_b    <= {BANK_W{1'b0}};
                lp_c    <= 8'd0;
                ocx     <= {PCH_W{1'b0}};
                a_base  <= {PW_WA_W{1'b0}};
                gh      <= {CHK_W{1'b0}};
                p_tile  <= 8'd0;
                p_cur   <= pidx;
                ic_left <= q_taps;

                if (is_stem) begin
                    // ceil(pchan/TS) oc tiles of TS lanes, one tap row each
                    lim_a <= ((q_pchan + TS[PCH_W-1:0]
                               - {{(PCH_W-1){1'b0}}, 1'b1}) >> TS_LOG);
                    lim_b <= TS[BANK_W-1:0];
                    lim_c <= 8'd1;
                end else if (is_dw) begin
                    lim_a <= ((q_pchan + TC[PCH_W-1:0]
                               - {{(PCH_W-1){1'b0}}, 1'b1}) >> TC_LOG);
                    lim_b <= TC[BANK_W-1:0];
                    lim_c <= 8'd1;
                end else begin
                    // PW and LINEAR: ceil(pchan/TM) x TM x ceil(ic/TN)
                    lim_a <= q_ntile;
                    lim_b <= TM[BANK_W-1:0];
                    lim_c <= ((q_taps + TN[BYT_W-1:0]
                               - {{(BYT_W-1){1'b0}}, 1'b1}) >> TN_LOG);
                end

                st <= has_wgt ? S_WARM : S_PNEXT;
            end

            // ---- arm the weight stream -------------------------------
            S_WARM: if ((outst == 4'd0) && !m_axi_arvalid) begin
                rd_arm  <= 1'b1;
                rd_addr <= c_wgt + {{(AXI_ADDR_W-OFF_W){1'b0}}, q_off};
                rd_len  <= q_bytes;
                st      <= S_WDEAL;
            end

            // ---- deal the rectangle ---------------------------------
            S_WDEAL: begin
                if (deal_ok && !chunk_last) begin
                    // the stem's first beat: latch it and come back
                    lo_q <= ext_m;
                    gh   <= gh + chunk;
                end else if (w_emit) begin
                    // one (bank, addr, data) into the right buffer
                    wd_q     <= word_now;
                    wb_q     <= lp_b;
                    wa_q     <= is_pw ? (a_base + {{(PW_WA_W-8){1'b0}}, lp_c})
                                      : {{(PW_WA_W-8){1'b0}}, lp_a};
                    st_wl_en <= is_stem;
                    dw_wl_en <= is_dw;
                    pw_wl_en <= is_pw;
                    gh       <= {CHK_W{1'b0}};

                    // ---- advance -------------------------------------
                    if (a_wrap) begin
                        st <= S_PNEXT;
                    end else if (b_wrap) begin
                        lp_a    <= lp_a + 8'd1;
                        lp_b    <= {BANK_W{1'b0}};
                        lp_c    <= 8'd0;
                        a_base  <= a_base + {{(PW_WA_W-8){1'b0}}, lim_c};
                        ocx     <= ocx + {{(PCH_W-1){1'b0}}, 1'b1};
                        ic_left <= q_taps;
                    end else if (c_wrap) begin
                        lp_b    <= lp_b + {{(BANK_W-1){1'b0}}, 1'b1};
                        lp_c    <= 8'd0;
                        ocx     <= ocx + {{(PCH_W-1){1'b0}}, 1'b1};
                        ic_left <= q_taps;
                    end else begin
                        lp_c    <= lp_c + 8'd1;
                        ic_left <= ic_left - BEAT_BYTES[BYT_W-1:0];
                    end
                end
            end

            // ---- one parameter tile, three streams ------------------
            S_PNEXT: begin
                pe_j  <= {BANK_W{1'b0}};
                pe_rb <= 8'd0; pe_sb <= {BANK_W{1'b0}};
                pe_rs <= 8'd0; pe_ss <= {BANK_W{1'b0}};
                pf_i  <= 8'd0;
                // q_ntile == 0 means pchan == 0, which top_seq's `no_load`
                // keeps behind ld_req; the comparison covers it anyway.
                st <= (p_tile >= q_ntile) ? S_FLUSH : S_PBA;
            end

            S_PBA: if ((outst == 4'd0) && !m_axi_arvalid) begin
                pf_n    <= B_ROWS[7:0];
                rd_arm  <= 1'b1;
                rd_addr <= c_pb + ({{(AXI_ADDR_W-PIDX_W){1'b0}}, p_cur} * B_BYTES);
                rd_len  <= (TM * B_BYTES);
                st      <= S_PB;
            end

            S_PB: if (pfill_ok) begin
                b_stg[pf_i[7:0]] <= ext;
                pf_i <= pf_i + 8'd1;
                if (pf_i == (pf_n - 8'd1)) begin
                    pf_i <= 8'd0;
                    st   <= S_PMA;
                end
            end

            S_PMA: if ((outst == 4'd0) && !m_axi_arvalid) begin
                pf_n    <= B_ROWS[7:0];
                rd_arm  <= 1'b1;
                rd_addr <= c_pm + ({{(AXI_ADDR_W-PIDX_W){1'b0}}, p_cur} * M_BYTES);
                rd_len  <= (TM * M_BYTES);
                st      <= S_PM;
            end

            S_PM: if (pfill_ok) begin
                m_stg[pf_i[7:0]] <= ext;
                pf_i <= pf_i + 8'd1;
                if (pf_i == (pf_n - 8'd1)) begin
                    pf_i <= 8'd0;
                    st   <= S_PSA;
                end
            end

            S_PSA: if ((outst == 4'd0) && !m_axi_arvalid) begin
                pf_n    <= S_ROWS[7:0];
                rd_arm  <= 1'b1;
                rd_addr <= c_ps + ({{(AXI_ADDR_W-PIDX_W){1'b0}}, p_cur} * S_BYTES);
                rd_len  <= (TM * S_BYTES);
                st      <= S_PS;
            end

            S_PS: if (pfill_ok) begin
                s_stg[pf_i[7:0]] <= ext;
                pf_i <= pf_i + 8'd1;
                if (pf_i == (pf_n - 8'd1)) begin
                    pf_i <= 8'd0;
                    st   <= S_PEMIT;
                end
            end

            // ---- write the tile ------------------------------------
            S_PEMIT: begin
                pd_bias  <= stg_bias;
                pd_m0    <= stg_m0;
                pd_shift <= stg_shift[SHIFT_W-1:0];
                pd_bank  <= pe_j;
                pd_addr  <= p_tile[PA_W-1:0];
                // LINEAR's four classes go to logit_out instead, and it still
                // advances the parameter pointer by a whole tile.
                pl_en    <= !is_lin;
                lg_pl_en <= is_lin;

                if (pe_last) begin
                    p_tile <= p_tile + 8'd1;
                    p_cur  <= p_cur + TM[PIDX_W-1:0];
                    st     <= S_PNEXT;
                end else begin
                    pe_j <= pe_j + {{(BANK_W-1){1'b0}}, 1'b1};
                    if (pe_sb == (EPB_BM[BANK_W-1:0] - {{(BANK_W-1){1'b0}}, 1'b1})) begin
                        pe_sb <= {BANK_W{1'b0}};
                        pe_rb <= pe_rb + 8'd1;
                    end else begin
                        pe_sb <= pe_sb + {{(BANK_W-1){1'b0}}, 1'b1};
                    end
                    if (pe_ss == (EPB_S[BANK_W-1:0] - {{(BANK_W-1){1'b0}}, 1'b1})) begin
                        pe_ss <= {BANK_W{1'b0}};
                        pe_rs <= pe_rs + 8'd1;
                    end else begin
                        pe_ss <= pe_ss + {{(BANK_W-1){1'b0}}, 1'b1};
                    end
                end
            end

            // ---- let the last registered write commit --------------
            S_FLUSH: begin
                pidx <= pidx + ({{(PIDX_W-8){1'b0}}, q_ntile} << TM_LOG);
                st   <= S_DONE;
            end

            // ---- one cycle of ld_done -----------------------------
            S_DONE: begin
                ld_done <= 1'b1;
                st      <= S_ACK;
            end

            // ---- the other half of the handshake ------------------
            //  top_seq holds `ld_req` until it sees `ld_done` RISE and drops it
            //  on that same clock edge - so ld_req is STILL HIGH for one cycle
            //  after the pulse. Returning straight to S_IDLE would re-latch the
            //  request and run the whole load a second time, which is
            //  bit-identical and therefore invisible except as doubled fill
            //  cycles. Waiting for ld_req to fall is the complete handshake.
            S_ACK: if (!ld_req) st <= S_IDLE;

            // ---- wait for the bus to go quiet ---------------------
            S_DRAIN: if ((outst == 4'd0) && !m_axi_arvalid)
                st <= dma_error ? S_ERR : S_ACK;

            // ---- parked ------------------------------------------
            S_ERR: ;

            //  Eighteen of the thirty-two encodings of `st` are named, so
            //  this is reachable only by corruption. It parks rather than
            //  recovering, for the same
            //  reason top_seq's default goes to S_ERR: a state register that
            //  reached an impossible value should be loud.
            default: begin
                dma_error <= 1'b1;
                st        <= S_ERR;
            end
            endcase

            // ---- the bus said no ------------------------------------
            //  After the case, so it overrides whatever transition that made.
            //  EXOKAY cannot occur on a normal read but is not an error if it
            //  does. The module stops here and `ld_done` is never pulsed again,
            //  which is what turns a bus failure into top_seq's watchdog and
            //  `fault` rather than into wrong weights.
            if (m_axi_rvalid && m_axi_rready
                && (m_axi_rresp != RESP_OKAY) && (m_axi_rresp != RESP_EXOKAY)) begin
                dma_error <= 1'b1;
                rd_arm    <= 1'b0;
                pw_wl_en  <= 1'b0;
                dw_wl_en  <= 1'b0;
                st_wl_en  <= 1'b0;
                pl_en     <= 1'b0;
                lg_pl_en  <= 1'b0;
                ld_done   <= 1'b0;
                st        <= S_DRAIN;
            end

            // ---- `start` restarts everything -----------------------
            //  Outermost, so it wins over both. It clears dma_error for the
            //  same reason top_seq's `start` clears `fault`: a run is launched
            //  from a known state rather than inheriting one. The configuration
            //  is latched HERE and nowhere else, so it cannot change under a
            //  load already in flight.
            if (start) begin
                c_wgt     <= wgt_base;
                c_pb      <= pb_base;
                c_pm      <= pm_base;
                c_ps      <= ps_base;
                pidx      <= {PIDX_W{1'b0}};
                dma_error <= 1'b0;
                rd_arm    <= 1'b0;
                pw_wl_en  <= 1'b0;
                dw_wl_en  <= 1'b0;
                st_wl_en  <= 1'b0;
                pl_en     <= 1'b0;
                lg_pl_en  <= 1'b0;
                ld_done   <= 1'b0;
                st        <= S_DRAIN;
            end
        end
    end

    // ======================================================================
    //  simulation-only checks
    // ======================================================================
    //  The distinction top_seq's header draws applies here too. A condition the
    //  hardware is DESIGNED to handle reports and continues ([FAULT]); a
    //  condition that must NEVER happen prints ERROR: and stops, because there
    //  is no correct way to carry on and the run should end where the evidence
    //  is. All of these are the second kind except the protocol one.
`ifndef SYNTHESIS
    reg ld_req_q, cfg_valid;
    always @(posedge clock) begin
        if (!rst_n) begin
            ld_req_q  <= 1'b0;
            cfg_valid <= 1'b0;
        end else begin
            ld_req_q <= ld_req;
            if (start) cfg_valid <= 1'b1;
        end
    end

    always @(posedge clock) begin
        if (rst_n) begin
            // The shape contract, checked against the structural constants the
            // datapath is built from. taps comes from a division of two program
            // fields, so a mis-encoded instruction lands here rather than as a
            // silently wrong rectangle.
            if ((st == S_SHAPE) && is_stem && (q_taps != TAP_MAX)) begin
                $display("ERROR: %m a STEM load says taps=%0d (ld_bytes=%0d / ld_pchan=%0d) but the stem array holds CIN*K*K=%0d at time %0t. The program and the datapath disagree about the stem's kernel.",
                         q_taps, q_bytes, q_pchan, TAP_MAX, $time);
                $finish;
            end
            if ((st == S_SHAPE) && is_dw && (q_taps != (K*K))) begin
                $display("ERROR: %m a DW load says taps=%0d (ld_bytes=%0d / ld_pchan=%0d) but a depthwise kernel is K*K=%0d at time %0t.",
                         q_taps, q_bytes, q_pchan, K*K, $time);
                $finish;
            end
            if ((st == S_SHAPE) && is_pw && (q_taps == {BYT_W{1'b0}})
                && (q_bytes != {BYT_W{1'b0}})) begin
                $display("ERROR: %m a pointwise load carries %0d bytes but taps divided to zero (ld_pchan=%0d) at time %0t.",
                         q_bytes, q_pchan, $time);
                $finish;
            end
            // The rectangle must fit the buffer it is being written into.
            if (pw_wl_en && (wa_q > ((1 << PW_WA_W) - 1))) begin
                $display("ERROR: %m pointwise weight address %0d exceeds PW_WA_W=%0d at time %0t.",
                         wa_q, PW_WA_W, $time);
                $finish;
            end
            if (st_wl_en && (wa_q > ((1 << ST_WA_W) - 1))) begin
                $display("ERROR: %m stem weight address %0d exceeds ST_WA_W=%0d at time %0t.",
                         wa_q, ST_WA_W, $time);
                $finish;
            end
            if (dw_wl_en && (wa_q > ((1 << DW_WA_W) - 1))) begin
                $display("ERROR: %m depthwise weight address %0d exceeds DW_WA_W=%0d at time %0t.",
                         wa_q, DW_WA_W, $time);
                $finish;
            end
            if (pl_en && (pd_addr > ((1 << PA_W) - 1))) begin
                $display("ERROR: %m parameter address %0d exceeds PA_W=%0d at time %0t.",
                         pd_addr, PA_W, $time);
                $finish;
            end
            // A load before `start` reads from whatever the base registers were
            // reset to, which is zero - so the symptom would be a DECERR from
            // the interconnect, or on a system that happens to map address zero,
            // a run with garbage weights. Saying so by name is worth one bit of
            // simulation state.
            if ((st == S_WARM) && !cfg_valid) begin
                $display("ERROR: %m a load was requested before `start` ever pulsed, so the four DDR base addresses were never latched, at time %0t.",
                         $time);
                $finish;
            end
            // The other side of top_seq's T-10 protocol check: ld_done must
            // never be asserted with no request outstanding. The hardware copes
            // (top_seq ignores it), so this reports and continues.
            //
            // Qualified by ld_req's PREVIOUS value as well as its current one.
            // ld_done is high for the one cycle after S_DONE and top_seq drops
            // ld_req on that same edge, so a requester that releases ld_req
            // part-way through the cycle - which a testbench driving it from a
            // negedge does - would otherwise trip this on every single load.
            if (ld_done && !ld_req && !ld_req_q)
                $display("  [FAULT] %m ld_done asserted with no ld_req outstanding at time %0t. The load handshake is being driven wrongly from THIS side.",
                         $time);
            // A single ARID is what makes in-order attribution of R beats safe.
            if (m_axi_rvalid && m_axi_rready && (m_axi_rid != AXI_ID[AXI_ID_W-1:0])) begin
                $display("ERROR: %m an R beat came back with RID=%0d, expected %0d, at time %0t. This master issues one ID and attributes beats in AR order; a foreign ID means the beats belong to somebody else.",
                         m_axi_rid, AXI_ID, $time);
                $finish;
            end
        end
    end

    // ---- the realigner's invariant ---------------------------------------
    //  A window that reported bytes it does not hold would produce weights from
    //  whatever w1 was left holding. Mid-stream, an empty window must mean a
    //  zero byte pointer, and the arithmetic says so: with wcnt == 1 the
    //  available count is BEAT_BYTES - wp and a consume can never exceed it, so
    //  the only retire that empties the window is the one where wp + tk is
    //  exactly BEAT_BYTES, which leaves wp at zero.
    //
    //  The exception is the cycle a stream is ARMED. An unaligned ld_off sets
    //  wp to off % BEAT_BYTES before any beat has arrived, so wcnt == 0 with
    //  wp != 0 is the correct state until the first beat lands - which is
    //  precisely what case 6 of wgt_dma_tb (an odd ld_off) produces, and what
    //  an earlier version of this check wrongly called an error.
    reg win_fresh;
    always @(posedge clock) begin
        if (!rst_n)        win_fresh <= 1'b1;
        else if (rd_arm)   win_fresh <= 1'b1;
        else if (win_push) win_fresh <= 1'b0;
    end

    always @(posedge clock) begin
        if (rst_n && !win_fresh && !rd_arm
            && (wcnt == 2'd0) && (wp != {BB_LOG{1'b0}})) begin
            $display("ERROR: %m the realigner window is empty mid-stream with a non-zero byte pointer (wp=%0d) at time %0t.",
                     wp, $time);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
