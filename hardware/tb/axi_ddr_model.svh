//============================================================================
//  axi_ddr_model.svh  -  a behavioural AXI4 read-only slave standing in for
//                        PS-DDR4, backed by the real export blobs
//
//  `include-d at FILE scope (outside the testbench module) by both
//  wgt_dma_tb.sv and accel_dma_tb.sv. It is an include rather than a separate
//  .sv passed to run_sim.sh because run_sim.sh resolves its extra sources
//  BEFORE it cd's into the work directory, so a relative path to a second
//  testbench file would break; the -i include path it passes to xvlog is
//  absolute. program_ops.svh is the same pattern for the same reason.
//
//  ---- five regions, not one flat array ----------------------------------
//
//  The DMA reads five DDR regions at five independent base addresses - four for
//  the weights and parameters (DD-030) and one for the image (DD-032).
//  Modelling that as one byte array would mean allocating everything between
//  the bases, so each region is its own array and the address decode picks one.
//  An address in NO region answers DECERR - which is a real test, not a
//  convenience: a DMA that walks off the end of a blob gets caught by the bus
//  instead of quietly reading zeros.
//
//  ---- the byte order is the thing being pinned down ---------------------
//
//  params_b.hex and params_m0.hex are one 32-bit word per line; the DMA reads
//  them as BYTES and reassembles. This model writes them little-endian - entry
//  i occupies bytes 4i..4i+3 with the least significant byte at 4i - which is
//  what an ordinary PS-side memcpy of a uint32 array produces, and therefore
//  what firmware/ will have to do. The testbench holds the same data as 32-bit
//  words read straight from the file, so if the DMA's field extraction and this
//  convention disagree, the scoreboard says so rather than both being wrong in
//  the same direction.
//
//  ---- and the image is TRANSPOSED here, on purpose ----------------------
//
//  software/golden/*/000_input.hex is channel-planar (CHW): byte c*IH*IW +
//  y*IW + x. The DMA reads the image interleaved (HWC): byte (y*IW + x)*CIN + c.
//  DD-032 records why the DDR layout is HWC - it makes the image one sequential
//  stream for the DMA and it is what a JPEG decoder hands the PS anyway - and
//  `load_img` below does the transpose so no new generated artifact is needed.
//
//  Doing it here rather than in the testbench is deliberate: this model IS the
//  PS-side contract, so the transpose belongs next to the little-endian
//  parameter packing it sits beside. The testbench keeps the golden in CHW and
//  computes its expectation from that, so a transpose error shows up as a
//  mismatch rather than cancelling out.
//
//  ---- what it checks about the master -----------------------------------
//
//  A slave model that only serves data lets a master violate the protocol
//  silently. This one refuses to:
//
//      * a burst that crosses a 4 KB boundary          (AXI4, always illegal)
//      * ARLEN over 255, i.e. more than 256 beats      (AXI4 INCR ceiling)
//      * ARSIZE that is not the data-bus width
//      * ARBURST that is not INCR
//      * a start address that is not beat-aligned      (this master's promise)
//
//  Each prints ERROR: and stops, because there is no useful way to serve a
//  request that is not legal and the run should end where the evidence is.
//
//  ---- back-to-back beats are the point ----------------------------------
//
//  RDATA / RRESP / RLAST are COMBINATIONAL on the beat index, and only RVALID
//  is registered. Presenting the data from a register instead would leave one
//  idle cycle between every beat, which would cap the DMA at half rate and hide
//  exactly the behaviour the throughput requirement is about - the worst load
//  has to sustain one bank write per cycle, and a slave that cannot deliver one
//  beat per cycle makes that untestable.
//
//  ---- err_on -------------------------------------------------------------
//
//  Raises SLVERR on every beat while high, with RLAST still delivered so the
//  transaction completes properly. That is how wgt_dma_tb tests that a bus
//  failure becomes a sticky dma_error and NOT a ld_done pulse.
//
//  ---- AR_LAT and GAP_MASK -----------------------------------------------
//
//  AR_LAT delays the first beat of every burst; GAP_MASK inserts pseudo-random
//  single-cycle holes in the R stream when `gaps_on` is high (GAP_MASK 0
//  disables it entirely). Both exist to stop the DMA being verified only
//  against a slave that is always ready - the R FIFO and the two-beat window
//  are exactly the logic a perfectly behaved slave would never exercise.
//
//  `gaps_on` is an input rather than only a parameter because the same load has
//  to be run both ways: with holes to prove correctness under stalls, and
//  without to measure the sustained rate. A throughput number taken from a
//  stalling slave measures the slave.
//============================================================================
module axi_ddr_model #(
    parameter ADDR_W  = 32,
    parameter DATA_W  = 128,
    parameter ID_W    = 4,

    // region bases and sizes, in bytes
    parameter [ADDR_W-1:0] WGT_BASE = 32'h1000_0000,
    parameter              WGT_N    = 2194880,
    parameter [ADDR_W-1:0] PB_BASE  = 32'h2000_0000,
    parameter [ADDR_W-1:0] PM_BASE  = 32'h2400_0000,
    parameter [ADDR_W-1:0] PS_BASE  = 32'h2800_0000,
    parameter              PN       = 19264,      // parameter entries
    parameter [ADDR_W-1:0] IMG_BASE = 32'h3000_0000,
    parameter              IMG_N    = 150528,     // CIN*IH*IW bytes, HWC

    parameter AR_LAT   = 4,        // cycles from AR accepted to the first beat
    parameter GAP_MASK = 0,        // 0 = no holes; 7 = a hole ~1 cycle in 8
    parameter QD       = 8         // AR queue depth
)(
    input  logic               clock,
    input  logic               rst_n,
    input  logic               err_on,
    input  logic               gaps_on,

    input  logic [ID_W-1:0]    arid,
    input  logic [ADDR_W-1:0]  araddr,
    input  logic [7:0]         arlen,
    input  logic [2:0]         arsize,
    input  logic [1:0]         arburst,
    input  logic               arvalid,
    output logic               arready,

    output logic [ID_W-1:0]    rid,
    output logic [DATA_W-1:0]  rdata,
    output logic [1:0]         rresp,
    output logic               rlast,
    output logic               rvalid,
    input  logic               rready
);

    localparam BEAT_BYTES = DATA_W / 8;
    localparam BSIZE      = $clog2(BEAT_BYTES);
    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10, RESP_DECERR = 2'b11;

    // ---- the four regions -------------------------------------------------
    reg [7:0] wmem  [0:WGT_N-1];      // weights.hex, one byte per line
    reg [7:0] pbmem [0:PN*4-1];       // params_b.hex,     little-endian
    reg [7:0] pmmem [0:PN*4-1];       // params_m0.hex,    little-endian
    reg [7:0] psmem [0:PN-1];         // params_shift.hex, one byte per line
    reg [7:0] imem  [0:IMG_N-1];      // the image, HWC (transposed on load)

    // Staging for the two word-per-line files, so the little-endian split
    // happens here and not in whoever calls load().
    reg [31:0] wordbuf [0:PN-1];

    integer li, lb;

    task automatic load(input string wgt_file, input string b_file,
                        input string m_file,   input string s_file);
        begin
            for (li = 0; li < WGT_N; li = li + 1) wmem[li]  = 8'h00;
            for (li = 0; li < PN*4;  li = li + 1) pbmem[li] = 8'h00;
            for (li = 0; li < PN*4;  li = li + 1) pmmem[li] = 8'h00;
            for (li = 0; li < PN;    li = li + 1) psmem[li] = 8'h00;

            $readmemh(wgt_file, wmem);

            $readmemh(b_file, wordbuf);
            for (li = 0; li < PN; li = li + 1)
                for (lb = 0; lb < 4; lb = lb + 1)
                    pbmem[li*4 + lb] = wordbuf[li][lb*8 +: 8];

            $readmemh(m_file, wordbuf);
            for (li = 0; li < PN; li = li + 1)
                for (lb = 0; lb < 4; lb = lb + 1)
                    pmmem[li*4 + lb] = wordbuf[li][lb*8 +: 8];

            $readmemh(s_file, psmem);
        end
    endtask

    // ---- the image: read CHW, store HWC ----------------------------------
    //  chw_file is the golden 000_input.hex, one byte per line, channel-planar.
    //  ih/iw/cin describe it. See the note in the header for why the transpose
    //  is here and not in the testbench.
    reg [7:0] chwbuf [0:IMG_N-1];

    task automatic load_img(input string chw_file, input integer ih,
                            input integer iw,      input integer cin);
        integer y, x, c;
        begin
            for (li = 0; li < IMG_N; li = li + 1) begin
                imem[li]   = 8'h00;
                chwbuf[li] = 8'h00;
            end
            $readmemh(chw_file, chwbuf);
            for (y = 0; y < ih; y = y + 1)
                for (x = 0; x < iw; x = x + 1)
                    for (c = 0; c < cin; c = c + 1)
                        imem[(y*iw + x)*cin + c] = chwbuf[(c*ih + y)*iw + x];
        end
    endtask

    // ---- the address decode ----------------------------------------------
    //  {mapped, byte}. No output arguments, so it is safe to call from a
    //  combinational block in any tool.
    function automatic logic [8:0] byte_at(input logic [ADDR_W-1:0] a);
        begin
            if ((a >= WGT_BASE) && (a < (WGT_BASE + WGT_N)))
                return {1'b1, wmem[a - WGT_BASE]};
            if ((a >= PB_BASE) && (a < (PB_BASE + PN*4)))
                return {1'b1, pbmem[a - PB_BASE]};
            if ((a >= PM_BASE) && (a < (PM_BASE + PN*4)))
                return {1'b1, pmmem[a - PM_BASE]};
            if ((a >= PS_BASE) && (a < (PS_BASE + PN)))
                return {1'b1, psmem[a - PS_BASE]};
            if ((a >= IMG_BASE) && (a < (IMG_BASE + IMG_N)))
                return {1'b1, imem[a - IMG_BASE]};
            return 9'd0;
        end
    endfunction

    // ---- the AR queue -----------------------------------------------------
    logic [ADDR_W-1:0] q_addr [0:QD-1];
    logic [7:0]        q_len  [0:QD-1];
    logic [ID_W-1:0]   q_id   [0:QD-1];
    integer            qcnt, qwp, qrp;

    assign arready = (qcnt < QD);

    // ---- burst state ------------------------------------------------------
    localparam R_IDLE = 0, R_LAT = 1, R_BEAT = 2;
    integer            rstate;
    integer            lat_c, beat_i;
    logic [ADDR_W-1:0] cur_addr;
    logic [7:0]        cur_len;
    logic [ID_W-1:0]   cur_id;
    logic [15:0]       lfsr;
    logic              rv_r;

    // pseudo-random single-cycle holes in the R stream
    wire hole = gaps_on && (GAP_MASK != 0) && ((lfsr & GAP_MASK[15:0]) == 16'd0);

    assign rvalid = rv_r && !hole;
    assign rlast  = (beat_i == cur_len);
    assign rid    = cur_id;

    // ---- the beat, combinational on the beat index -----------------------
    logic [DATA_W-1:0] rdata_c;
    logic [1:0]        rresp_c;
    logic [8:0]        got;
    integer            k;

    // Explicit sensitivity rather than @(*): the block calls a function that
    // reads the region arrays, and an inferred list is one place a tool is
    // allowed to surprise you. The arrays never change after load().
    always @(beat_i or cur_addr or err_on) begin
        rresp_c = err_on ? RESP_SLVERR : RESP_OKAY;
        rdata_c = '0;
        for (k = 0; k < BEAT_BYTES; k = k + 1) begin
            got = byte_at(cur_addr + beat_i*BEAT_BYTES + k);
            if (!got[8]) rresp_c = RESP_DECERR;
            rdata_c[k*8 +: 8] = got[7:0];
        end
    end

    assign rdata = rdata_c;
    assign rresp = rresp_c;

    initial begin
        qcnt = 0; qwp = 0; qrp = 0;
        rstate = R_IDLE; lat_c = 0; beat_i = 0;
        rv_r = 1'b0;
        cur_addr = '0; cur_len = '0; cur_id = '0;
        lfsr = 16'hACE1;
    end

    always @(posedge clock) begin
        if (!rst_n) begin
            qcnt <= 0; qwp <= 0; qrp <= 0;
            rstate <= R_IDLE;
            rv_r <= 1'b0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};

            // ---- accept an AR, and refuse an illegal one ------------------
            if (arvalid && arready) begin
                if (arburst !== 2'b01) begin
                    $display("ERROR: %m AR at 0x%08x has ARBURST=%0d; this master issues INCR (1) only, at time %0t",
                             araddr, arburst, $time);
                    $finish;
                end
                if (arsize !== BSIZE[2:0]) begin
                    $display("ERROR: %m AR at 0x%08x has ARSIZE=%0d, expected %0d for a %0d-bit bus, at time %0t",
                             araddr, arsize, BSIZE, DATA_W, $time);
                    $finish;
                end
                if ((araddr & (BEAT_BYTES-1)) != 0) begin
                    $display("ERROR: %m AR at 0x%08x is not %0d-byte aligned at time %0t",
                             araddr, BEAT_BYTES, $time);
                    $finish;
                end
                // The 4 KB rule: (arlen+1) beats of BEAT_BYTES from araddr must
                // stay inside one 4096-byte page.
                if (((araddr & 32'h0000_0FFF) + (arlen + 1) * BEAT_BYTES) > 4096) begin
                    $display("ERROR: %m AR at 0x%08x with ARLEN=%0d (%0d beats, %0d bytes) crosses a 4 KB boundary at time %0t",
                             araddr, arlen, arlen+1, (arlen+1)*BEAT_BYTES, $time);
                    $finish;
                end
                q_addr[qwp] <= araddr;
                q_len[qwp]  <= arlen;
                q_id[qwp]   <= arid;
                qwp  <= (qwp + 1) % QD;
                qcnt <= qcnt + 1;
            end

            // ---- serve ---------------------------------------------------
            case (rstate)
            R_IDLE: if (qcnt > 0) begin
                cur_addr <= q_addr[qrp];
                cur_len  <= q_len[qrp];
                cur_id   <= q_id[qrp];
                qrp      <= (qrp + 1) % QD;
                qcnt     <= qcnt - 1;
                beat_i   <= 0;
                lat_c    <= AR_LAT;
                rstate   <= (AR_LAT == 0) ? R_BEAT : R_LAT;
            end

            R_LAT: begin
                if (lat_c > 1) lat_c <= lat_c - 1;
                else           rstate <= R_BEAT;
            end

            R_BEAT: begin
                rv_r <= 1'b1;
                if (rvalid && rready) begin
                    if (beat_i == cur_len) begin
                        rv_r   <= 1'b0;
                        rstate <= R_IDLE;
                    end else begin
                        beat_i <= beat_i + 1;
                    end
                end
            end
            default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule
