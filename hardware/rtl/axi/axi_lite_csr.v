`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  axi_lite_csr.v  -  the control registers the PS drives the accelerator with
//
//  Until this file existed, accel_sys had `start`, `n_instr`, four DDR base
//  addresses and the whole program-load port as plain pins with nothing to
//  drive them. Nothing could RUN the design; accel_dma_tb drove those pins from
//  a testbench. This is what a processor drives instead.
//
//  firmware/README.md states the contract from the other side: the PS "reads an
//  image from the SD card, preprocesses and quantizes it to int8, writes it to
//  DDR, configures the PL accelerator over AXI-Lite, runs inference, reads the
//  result". This module is the "configures ... over AXI-Lite, reads the result"
//  half of that sentence.
//
//  ---- THE reason this module exists, and it is not "convenience" ---------
//
//  Two of the accelerator's outputs are single-cycle events, and a processor
//  polling a register cannot see a single cycle. Converting events into state
//  is this module's real job:
//
//    `done`         is a ONE-CYCLE PULSE from top_seq. A PS reading a register
//                   will essentially never be looking during that cycle.
//
//    `logits`       is worse, and logit_out.v:212-217 says so in its own words:
//                   "requantize's output register free-runs, so `logits` only
//                   ever means anything in a `logits_valid` cycle... it
//                   deliberately does not turn `logits` into a latched output,
//                   because that would move `logits_valid` by a cycle."
//
//  That decision is right for logit_out - moving `logits_valid` would have been
//  worse - but it means the latch has to happen SOMEWHERE, and this is where.
//  logit_out's header already describes the failure mode it was half-guarding
//  against (finding T-10): "the PS reads these over AXI, and a poll that
//  arrives between `start` and the first `logits_valid` gets a complete,
//  plausible, four-class answer belonging to the previous image. That is the
//  worst shape a stale value can take: not an x, not a zero, but last frame's
//  confident prediction of a healthy leaf." T-10's `stale` gate closed the
//  window from `start` to the first result by zeroing it. This closes the rest
//  of it, by latching the result when it is valid and holding it until the next
//  `start`. Between them there is no window in which RESULT_LO/HI can be read
//  as anything but zeros or this image's answer.
//
//  ---- the register map ---------------------------------------------------
//
//    off    name         acc   contents
//    0x00   CTRL         W1P   [0] START. Writing 1 pulses start for exactly
//                              one cycle and clears the sticky status bits.
//                              [1] LOAD_IMAGE. Pulses the DMA's image request.
//                              Reads as 0 - these are actions, not state.
//    0x04   N_INSTR      RW    [7:0] instruction count. RESETS TO ZERO, on
//                              purpose: top_seq's T-1 check refuses n_instr==0
//                              and raises `fault`, so a PS that forgets to
//                              write it gets a loud refusal instead of an
//                              assumed 64 that happens to be right today.
//    0x08   IRQ_EN       RW    [0] interrupt on done, [1] on any error
//    0x0C   STATUS_CLR   W1C   write 1 to a bit to clear that sticky STATUS bit
//    0x10   STATUS       RO    [0] running (live, not sticky)
//                              [1] done  [2] fault  [3] dma_error
//                              [4] tag_error        (all four sticky)
//                              [5] result captured
//                              [6] image load busy  (live, not sticky)
//                              [7] image loaded     (sticky)
//                              [15:8] pc, for diagnosing a hang
//    0x14   WGT_BASE     RW    weights.hex       in DDR
//    0x18   PB_BASE      RW    params_b.hex
//    0x1C   PM_BASE      RW    params_m0.hex
//    0x20   PS_BASE      RW    params_shift.hex
//    0x24   RESULT_LO    RO    [15:0] logit 0, [31:16] logit 1   (latched)
//    0x28   RESULT_HI    RO    [15:0] logit 2, [31:16] logit 3   (latched)
//    0x2C   ARGMAX       RO    [1:0] predicted class (latched), [2] valid
//    0x30   ID           RO    a fixed magic word
//    0x34   IMG_BASE     RW    the image in DDR, HWC interleaved (DD-032)
//
//    0x1000-0x17FF  PROG  WO   the 512 program words, as a 2 KB aperture
//
//  Why an aperture for the program and not an address/data register pair: the
//  program is 2 KB written once per boot, and an aperture makes the PS side a
//  plain loop over an array with no hidden pointer state to get out of step. A
//  pointer register that is one word behind produces a program that executes -
//  which is the failure mode T-1 and the checkpoint-hash guard both exist to
//  make impossible, so not introducing another one is worth 2 KB of address
//  space that costs nothing.
//
//  ---- loud, not silent ---------------------------------------------------
//
//  This module answers SLVERR rather than quietly accepting, in four cases.
//  The repository's convention is that a silent wrong answer is the one outcome
//  worth spending logic to avoid, and a bus error is the loudest thing a slave
//  can say to a processor:
//
//    1. an unmapped address, read or write. Catches a PS built against a stale
//       map, which is otherwise a write that vanishes.
//    2. a write to a read-only register.
//    3. a program or configuration write while `running`. top_seq's T-10 guard
//       already DROPS a program write during a run - "the safe direction", its
//       comment says, but silent. This turns the drop into a reported error.
//    4. a partial program word (WSTRB != 4'hF). A byte-wise program write is a
//       PS bug; honouring it would assemble an instruction from two writes and
//       execute whatever the first one left.
//
//  And one case that is refused for a reason worth stating on its own:
//
//    5. START while `running`. top_seq ignores `start` outside S_IDLE/S_ERR, so
//       this looks harmless - but wgt_dma's `start` is UNCONDITIONAL and resets
//       its running parameter index to zero. A mid-run START would therefore
//       leave the sequencer running while every subsequent parameter load read
//       from the wrong place in the blob, and the run would finish, with wrong
//       biases from some layer onward. So it is refused here, which is the only
//       place that can see both modules at once.
//
//    6. START while the IMAGE IS STILL LOADING, and LOAD_IMAGE while `running`.
//       Same shape, and the same consequence: the stem reads img_buffer from its
//       first cycle, so starting on a half-written image produces a complete
//       feature map built partly from the previous picture. Nothing downstream
//       could notice. `img_busy` is the live bit both guards test, and it is
//       high from the moment the request is latched so there is no window where
//       a PS can see "not busy" between writing LOAD_IMAGE and the load
//       beginning.
//
//  ---- AXI-Lite handshaking ----------------------------------------------
//
//  AW and W are captured INDEPENDENTLY rather than by asserting both readies
//  only when both VALIDs are present. The simpler form deadlocks against a
//  master that waits for AWREADY before driving WVALID; AXI4 forbids a master
//  from doing that, but "correct against every legal master" is worth fifteen
//  lines in the one module a processor talks to. Same clock domain as the rest
//  of the design: on the ZU+ the PS's M_AXI_HPM aclk is driven by the same PL
//  clock as S_AXI_HP, so there is no CDC here any more than there is in
//  wgt_dma.
//
//  Run:  bash scripts/run_sim.sh axi_lite_csr
//============================================================================
module axi_lite_csr #(
    parameter AXI_ADDR_W = 32,     // the DDR base addresses this hands out
    parameter ADDR_W     = 13,     // the AXI-Lite aperture: 8 KB
    parameter DATA_W     = 32,
    parameter NI_W       = 8,      // n_instr
    parameter PGA_W      = 9,      // program memory address width (512 words)
    parameter PW_W       = 32,     // program word
    parameter NLOG       = 4,
    parameter LOG_W      = 16,
    parameter IDX_W      = 2,
    parameter [31:0] ID_MAGIC = 32'h56_49_4E_45     // "VINE"
)(
    input  wire                     clock,
    input  wire                     rst_n,

    // ---- AXI4-Lite slave ------------------------------------------------
    input  wire [ADDR_W-1:0]        s_axi_awaddr,
    input  wire [2:0]               s_axi_awprot,
    input  wire                     s_axi_awvalid,
    output wire                     s_axi_awready,
    input  wire [DATA_W-1:0]        s_axi_wdata,
    input  wire [DATA_W/8-1:0]      s_axi_wstrb,
    input  wire                     s_axi_wvalid,
    output wire                     s_axi_wready,
    output reg  [1:0]               s_axi_bresp,
    output reg                      s_axi_bvalid,
    input  wire                     s_axi_bready,
    input  wire [ADDR_W-1:0]        s_axi_araddr,
    input  wire [2:0]               s_axi_arprot,
    input  wire                     s_axi_arvalid,
    output wire                     s_axi_arready,
    output reg  [DATA_W-1:0]        s_axi_rdata,
    output reg  [1:0]               s_axi_rresp,
    output reg                      s_axi_rvalid,
    input  wire                     s_axi_rready,

    // ---- what it drives -------------------------------------------------
    output reg                      start,        // one cycle
    output reg  [NI_W-1:0]          n_instr,
    output reg  [AXI_ADDR_W-1:0]    wgt_base,
    output reg  [AXI_ADDR_W-1:0]    pb_base,
    output reg  [AXI_ADDR_W-1:0]    pm_base,
    output reg  [AXI_ADDR_W-1:0]    ps_base,

    output reg                      pg_en,
    output reg  [PGA_W-1:0]         pg_addr,
    output reg  [PW_W-1:0]          pg_data,

    // ---- the image load ---------------------------------------------------
    output reg                      img_start,    // one cycle
    output reg  [AXI_ADDR_W-1:0]    img_base,
    input  wire                     img_busy,
    input  wire                     img_done,     // a one-cycle pulse

    // ---- what it observes -----------------------------------------------
    input  wire                     running,
    input  wire                     done,          // a ONE-CYCLE pulse
    input  wire                     fault,
    input  wire                     dma_error,
    input  wire                     tag_error,
    input  wire [NI_W-1:0]          pc,
    input  wire [NLOG*LOG_W-1:0]    logits,        // valid only while logits_valid
    input  wire                     logits_valid,
    input  wire [IDX_W-1:0]         argmax,
    input  wire                     argmax_valid,

    // ---- to the PS's interrupt controller -------------------------------
    output wire                     irq
);

    // ======================================================================
    //  the map, as localparams rather than literals
    // ======================================================================
    localparam BYTES    = DATA_W / 8;
    localparam LSB      = 2;                  // byte offset bits, 32-bit regs
    localparam PROG_SEL = ADDR_W - 1;         // 1 = the program aperture

    localparam R_CTRL       = 4'd0,
               R_N_INSTR    = 4'd1,
               R_IRQ_EN     = 4'd2,
               R_STATUS_CLR = 4'd3,
               R_STATUS     = 4'd4,
               R_WGT_BASE   = 4'd5,
               R_PB_BASE    = 4'd6,
               R_PM_BASE    = 4'd7,
               R_PS_BASE    = 4'd8,
               R_RESULT_LO  = 4'd9,
               R_RESULT_HI  = 4'd10,
               R_ARGMAX     = 4'd11,
               R_ID         = 4'd12,
               R_IMG_BASE   = 4'd13,
               N_REGS       = 4'd14;

    localparam [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

    // ======================================================================
    //  elaboration checks
    // ======================================================================
    //  Same idiom as wgt_buffer.v:81-88: Verilog-2001 has no elaboration
    //  $fatal, so instantiate a module that does not exist and let the tool
    //  print its name, which IS the error message.
    generate
        // The program aperture's word index must fit strictly below the bit
        // that selects the aperture, or a program write aliases onto a register.
        if (ADDR_W < (PGA_W + LSB + 1)) begin : chk_aperture
            ERROR_CSR_ADDR_W_TOO_NARROW_FOR_THE_PROGRAM_APERTURE u_err();
        end
        // ...and the registers must fit strictly below it too.
        if ((1 << (PROG_SEL - LSB)) < N_REGS) begin : chk_regs
            ERROR_CSR_ADDR_W_TOO_NARROW_FOR_THE_REGISTER_BLOCK u_err();
        end
        if (DATA_W != 32) begin : chk_data
            ERROR_CSR_AXI_LITE_DATA_WIDTH_MUST_BE_32 u_err();
        end
        if (PW_W != DATA_W) begin : chk_pw
            ERROR_CSR_PROGRAM_WORD_MUST_BE_ONE_AXI_LITE_BEAT u_err();
        end
        if ((NLOG * LOG_W) > (2 * DATA_W)) begin : chk_logits
            ERROR_CSR_LOGITS_DO_NOT_FIT_IN_RESULT_LO_AND_HI u_err();
        end
        if (NI_W > 8) begin : chk_ni
            ERROR_CSR_N_INSTR_DOES_NOT_FIT_THE_STATUS_PC_FIELD u_err();
        end
        // The four DDR bases are written as single registers, so a base wider
        // than one beat would be silently truncated by the byte-strobe merge.
        if (AXI_ADDR_W != DATA_W) begin : chk_base
            ERROR_CSR_DDR_BASE_MUST_BE_ONE_AXI_LITE_BEAT u_err();
        end
    endgenerate

    // ======================================================================
    //  event -> state: the whole point of the module
    // ======================================================================
    reg                    st_done, st_fault, st_dma, st_tag, st_res, st_img;
    reg [NLOG*LOG_W-1:0]   logits_q;
    reg [IDX_W-1:0]        argmax_q;
    reg [1:0]              irq_en;

    // Set by the event, cleared by START or by STATUS_CLR. `fault`, `dma_error`
    // and `tag_error` are already sticky at their sources, so clearing the copy
    // while the source is still asserted re-sets it on the next cycle - which
    // is honest rather than annoying: STATUS is then telling the truth, and the
    // only way out of a fault really is a new run. Said again in the map above.
    //
    // The clear is keyed on the REGISTERED `start` output, not on the
    // combinational write decision one cycle earlier, so that "the run begins"
    // is one instant for the status bits and for the accelerator rather than two.
    reg  [7:0]             stat_clr;            // one cycle, from STATUS_CLR

    always @(posedge clock) begin
        if (!rst_n) begin
            st_done  <= 1'b0; st_fault <= 1'b0; st_dma <= 1'b0;
            st_tag   <= 1'b0; st_res   <= 1'b0; st_img <= 1'b0;
            logits_q <= {NLOG*LOG_W{1'b0}};
            argmax_q <= {IDX_W{1'b0}};
        end else begin
            // clear first, set second: an event in the same cycle as a clear
            // must survive it, or a run that faults immediately looks clean.
            if (start || stat_clr[1]) st_done  <= 1'b0;
            if (start || stat_clr[2]) st_fault <= 1'b0;
            if (start || stat_clr[3]) st_dma   <= 1'b0;
            if (start || stat_clr[4]) st_tag   <= 1'b0;
            if (start || stat_clr[5]) st_res   <= 1'b0;
            if (start || stat_clr[7]) st_img   <= 1'b0;

            if (done)      st_done  <= 1'b1;
            if (fault)     st_fault <= 1'b1;
            if (dma_error) st_dma   <= 1'b1;
            if (tag_error) st_tag   <= 1'b1;
            //  From the DMA's one-cycle pulse, which fires only on a successful
            //  image load. Deliberately NOT derived from img_busy's falling
            //  edge: img_busy also falls when a bus error abandons the load, and
            //  the two must not read the same.
            if (img_done)  st_img   <= 1'b1;

            // The latch this module exists for. logits are only meaningful in a
            // logits_valid cycle (logit_out.v:212-217); argmax likewise.
            if (start) begin
                logits_q <= {NLOG*LOG_W{1'b0}};
                argmax_q <= {IDX_W{1'b0}};
            end
            if (logits_valid) logits_q <= logits;
            if (argmax_valid) begin
                argmax_q <= argmax;
                st_res   <= 1'b1;
            end
        end
    end

    // IRQ_EN[0] = done, IRQ_EN[1] = any error. Level, not a pulse: a PS
    // interrupt controller wants a level it can see whenever it looks.
    assign irq = (irq_en[0] & st_done)
               | (irq_en[1] & (st_fault | st_dma | st_tag));

    wire [DATA_W-1:0] status_word =
        { {(DATA_W-16){1'b0}},
          pc,                                        // [15:8]
          st_img, img_busy,                          // [7], [6]
          st_res, st_tag, st_dma, st_fault, st_done, running };

    // ======================================================================
    //  the write channel
    // ======================================================================
    reg              aw_seen, w_seen;
    reg [ADDR_W-1:0] aw_addr;
    reg [DATA_W-1:0] w_data;
    reg [BYTES-1:0]  w_strb;

    // Captured independently; see the header on why not the both-valid form.
    assign s_axi_awready = !aw_seen && !s_axi_bvalid;
    assign s_axi_wready  = !w_seen  && !s_axi_bvalid;

    wire do_write = aw_seen && w_seen && !s_axi_bvalid;

    wire              wr_is_prog = aw_addr[PROG_SEL];
    wire [3:0]        wr_reg     = aw_addr[LSB+3:LSB];
    wire              wr_reg_hi  = |aw_addr[PROG_SEL-1:LSB+4];   // above the map
    wire              wr_prog_hi = |aw_addr[PROG_SEL-1:PGA_W+LSB];

    // WSTRB applied per byte, so a byte write to a config register cannot
    // corrupt the other three. A control register is not normally written
    // byte-wise, but "not normally" is not a reason to get it wrong.
    function [DATA_W-1:0] wstrb_merge;
        input [DATA_W-1:0] old_v;
        input [DATA_W-1:0] new_v;
        input [BYTES-1:0]  strb;
        integer b;
        begin
            wstrb_merge = old_v;
            for (b = 0; b < BYTES; b = b + 1)
                if (strb[b]) wstrb_merge[b*8 +: 8] = new_v[b*8 +: 8];
        end
    endfunction

    //  One merged value per writable register. Verilog-2001 does not allow a
    //  bit-select of a function CALL, so these cannot be sliced inline at the
    //  point of use - which is why they are named wires rather than expressions
    //  inside the case below.
    wire [DATA_W-1:0] mg_ni  = wstrb_merge({{(DATA_W-NI_W){1'b0}}, n_instr},
                                           w_data, w_strb);
    wire [DATA_W-1:0] mg_ie  = wstrb_merge({{(DATA_W-2){1'b0}}, irq_en},
                                           w_data, w_strb);
    wire [DATA_W-1:0] mg_wgt = wstrb_merge(wgt_base, w_data, w_strb);
    wire [DATA_W-1:0] mg_pb  = wstrb_merge(pb_base,  w_data, w_strb);
    wire [DATA_W-1:0] mg_pm  = wstrb_merge(pm_base,  w_data, w_strb);
    wire [DATA_W-1:0] mg_ps  = wstrb_merge(ps_base,  w_data, w_strb);
    wire [DATA_W-1:0] mg_img = wstrb_merge(img_base, w_data, w_strb);

    // ---- is this write allowed? -----------------------------------------
    wire wr_ro     = (wr_reg == R_STATUS) || (wr_reg == R_RESULT_LO)
                  || (wr_reg == R_RESULT_HI) || (wr_reg == R_ARGMAX)
                  || (wr_reg == R_ID);
    wire wr_cfg    = (wr_reg == R_N_INSTR) || (wr_reg == R_WGT_BASE)
                  || (wr_reg == R_PB_BASE) || (wr_reg == R_PM_BASE)
                  || (wr_reg == R_PS_BASE) || (wr_reg == R_IMG_BASE);
    wire wr_start  = (wr_reg == R_CTRL) && w_data[0] && w_strb[0];
    wire wr_img    = (wr_reg == R_CTRL) && w_data[1] && w_strb[0];

    wire wr_bad_addr = wr_is_prog ? wr_prog_hi
                                  : (wr_reg_hi || (wr_reg >= N_REGS));
    // (3) and (5) of the header: nothing that changes how a run behaves may be
    // written while one is in progress. (6): nor while the image is loading -
    // starting on a half-written image is the same class of silent wrong answer,
    // and IMG_BASE moving mid-load would be worse still.
    wire wr_bad_run  = (running  && (wr_is_prog || wr_cfg || wr_start || wr_img))
                    || (img_busy && (wr_start || wr_img
                                     || (wr_reg == R_IMG_BASE)));
    // (4): a partial program word would assemble an instruction from two writes
    wire wr_bad_strb = wr_is_prog && (w_strb != {BYTES{1'b1}});

    wire wr_err = wr_bad_addr || wr_bad_strb || wr_bad_run
                  || (!wr_is_prog && wr_ro);
    wire wr_ok  = do_write && !wr_err;

    always @(posedge clock) begin
        if (!rst_n) begin
            aw_seen <= 1'b0; w_seen <= 1'b0;
            aw_addr <= {ADDR_W{1'b0}};
            w_data  <= {DATA_W{1'b0}};
            w_strb  <= {BYTES{1'b0}};
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= RESP_OKAY;
            start     <= 1'b0;
            img_start <= 1'b0;
            img_base  <= {AXI_ADDR_W{1'b0}};
            n_instr  <= {NI_W{1'b0}};       // zero on purpose; see the map
            wgt_base <= {AXI_ADDR_W{1'b0}};
            pb_base  <= {AXI_ADDR_W{1'b0}};
            pm_base  <= {AXI_ADDR_W{1'b0}};
            ps_base  <= {AXI_ADDR_W{1'b0}};
            pg_en    <= 1'b0;
            pg_addr  <= {PGA_W{1'b0}};
            pg_data  <= {PW_W{1'b0}};
            irq_en   <= 2'b00;
            stat_clr <= 8'd0;
        end else begin
            // one-cycle outputs
            start     <= 1'b0;
            img_start <= 1'b0;
            pg_en     <= 1'b0;
            stat_clr  <= 8'd0;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_addr <= s_axi_awaddr;
                aw_seen <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                w_data <= s_axi_wdata;
                w_strb <= s_axi_wstrb;
                w_seen <= 1'b1;
            end

            if (do_write) begin
                aw_seen      <= 1'b0;
                w_seen       <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= wr_err ? RESP_SLVERR : RESP_OKAY;
            end

            if (wr_ok) begin
                if (wr_is_prog) begin
                    pg_en   <= 1'b1;
                    pg_addr <= aw_addr[PGA_W+LSB-1:LSB];
                    pg_data <= w_data;
                end else begin
                    case (wr_reg)
                    R_CTRL:       begin
                                      start     <= w_data[0] & w_strb[0];
                                      img_start <= w_data[1] & w_strb[0];
                                  end
                    R_N_INSTR:    n_instr  <= mg_ni[NI_W-1:0];
                    R_IRQ_EN:     irq_en   <= mg_ie[1:0];
                    R_STATUS_CLR: stat_clr <= w_data[7:0] & {8{w_strb[0]}};
                    R_WGT_BASE:   wgt_base <= mg_wgt;
                    R_PB_BASE:    pb_base  <= mg_pb;
                    R_PM_BASE:    pm_base  <= mg_pm;
                    R_PS_BASE:    ps_base  <= mg_ps;
                    R_IMG_BASE:   img_base <= mg_img;
                    default:      ;     // unreachable: wr_err covered the rest
                    endcase
                end
            end

            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ======================================================================
    //  the read channel
    // ======================================================================
    reg [ADDR_W-1:0] ar_addr;
    reg              ar_busy;

    assign s_axi_arready = !s_axi_rvalid && !ar_busy;

    wire       rd_is_prog = ar_addr[PROG_SEL];
    wire [3:0] rd_reg     = ar_addr[LSB+3:LSB];
    wire       rd_reg_hi  = |ar_addr[PROG_SEL-1:LSB+4];
    // The program memory has no read port out of top_seq, so the aperture is
    // write-only and says so rather than returning a plausible zero.
    wire       rd_err     = rd_is_prog || rd_reg_hi || (rd_reg >= N_REGS);

    always @(posedge clock) begin
        if (!rst_n) begin
            ar_busy     <= 1'b0;
            ar_addr     <= {ADDR_W{1'b0}};
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= RESP_OKAY;
            s_axi_rdata  <= {DATA_W{1'b0}};
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                ar_addr <= s_axi_araddr;
                ar_busy <= 1'b1;
            end else if (ar_busy && !s_axi_rvalid) begin
                // one cycle after capture, so rd_* see the registered address
                ar_busy      <= 1'b0;
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= rd_err ? RESP_SLVERR : RESP_OKAY;
                if (rd_err) s_axi_rdata <= {DATA_W{1'b0}};
                else case (rd_reg)
                    R_N_INSTR:   s_axi_rdata <= {{(DATA_W-NI_W){1'b0}}, n_instr};
                    R_IRQ_EN:    s_axi_rdata <= {{(DATA_W-2){1'b0}}, irq_en};
                    R_STATUS:    s_axi_rdata <= status_word;
                    R_WGT_BASE:  s_axi_rdata <= wgt_base;
                    R_PB_BASE:   s_axi_rdata <= pb_base;
                    R_PM_BASE:   s_axi_rdata <= pm_base;
                    R_PS_BASE:   s_axi_rdata <= ps_base;
                    R_IMG_BASE:  s_axi_rdata <= img_base;
                    R_RESULT_LO: s_axi_rdata <= logits_q[0 +: 2*LOG_W];
                    R_RESULT_HI: s_axi_rdata <= logits_q[2*LOG_W +: 2*LOG_W];
                    R_ARGMAX:    s_axi_rdata <= {{(DATA_W-3){1'b0}},
                                                 st_res, argmax_q};
                    R_ID:        s_axi_rdata <= ID_MAGIC;
                    // CTRL and STATUS_CLR are actions, not state: they read as
                    // zero rather than erroring, because a PS dumping the whole
                    // block for a bug report should not take a bus error for it.
                    default:     s_axi_rdata <= {DATA_W{1'b0}};
                endcase
            end

            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
        end
    end

    // ======================================================================
    //  simulation-only checks
    // ======================================================================
`ifndef SYNTHESIS
    //  These report and continue. Every one of them is a condition the HARDWARE
    //  handles correctly by answering SLVERR - the point of saying it again here
    //  is that a SLVERR reaching the PS as a data abort is a long way from the
    //  line of driver code that caused it, and this names the cause. They print
    //  [FAULT] rather than ERROR: for the reason top_seq's header gives: these
    //  are handled conditions, and axi_lite_csr_tb drives every one of them on
    //  purpose to watch the guard fire.
    always @(posedge clock) begin
        if (rst_n && do_write) begin
            if (wr_bad_addr)
                $display("  [FAULT] %m AXI-Lite write to unmapped address 0x%h, answered SLVERR, at time %0t",
                         aw_addr, $time);
            if (!wr_is_prog && wr_ro)
                $display("  [FAULT] %m AXI-Lite write to read-only register %0d (0x%h), answered SLVERR, at time %0t",
                         wr_reg, aw_addr, $time);
            if (wr_bad_strb)
                $display("  [FAULT] %m AXI-Lite partial program write, WSTRB=0x%h at 0x%h. A program word must be written whole; answered SLVERR, at time %0t",
                         w_strb, aw_addr, $time);
            if (wr_bad_run && wr_start)
                $display("  [FAULT] %m START written while running. REFUSED: top_seq would ignore it, but wgt_dma's start is unconditional and would reset its parameter index mid-run, so the run would finish with wrong biases. Answered SLVERR, at time %0t",
                         $time);
            if (wr_bad_run && wr_img)
                $display("  [FAULT] %m LOAD_IMAGE written while %0s. REFUSED: the stem reads img_buffer from its first cycle, so overwriting the image under a run - or restarting a load already in flight - produces a feature map built partly from another picture. Answered SLVERR, at time %0t",
                         running ? "running" : "an image load is in flight", $time);
            if (wr_bad_run && img_busy && wr_start)
                $display("  [FAULT] %m START written while the image is still loading. REFUSED: the run would begin on a half-written image. Answered SLVERR, at time %0t",
                         $time);
            if (wr_bad_run && !wr_start && !wr_img)
                $display("  [FAULT] %m AXI-Lite %0s write at 0x%h while %0s, answered SLVERR, at time %0t",
                         wr_is_prog ? "program" : "config", aw_addr,
                         running ? "running" : "an image load is in flight", $time);
        end
        //  Qualified on the cycle the RESPONSE is formed, not on the capture
        //  cycle. An earlier version tested `rd_is_prog` when AR was accepted -
        //  but rd_is_prog is decoded from the REGISTERED address, which at that
        //  moment still holds the PREVIOUS transaction's. So it reported the
        //  wrong address, one read late, and blamed a perfectly good register
        //  read for the aperture read before it. The response path was always
        //  right; only the message was wrong, which is the more dangerous of
        //  the two to leave in place.
        if (rst_n && ar_busy && !s_axi_rvalid && rd_err) begin
            if (rd_is_prog)
                $display("  [FAULT] %m AXI-Lite read from the write-only program aperture at 0x%h, answered SLVERR, at time %0t",
                         ar_addr, $time);
            else
                $display("  [FAULT] %m AXI-Lite read from unmapped address 0x%h, answered SLVERR, at time %0t",
                         ar_addr, $time);
        end
    end

    //  `start` must be exactly one cycle wide, or top_seq's S_IDLE admits the
    //  run twice and wgt_dma resets its parameter index on the second. The same
    //  applies to img_start, which wgt_dma latches.
    reg start_q, img_start_q;
    always @(posedge clock) begin
        if (!rst_n) begin
            start_q     <= 1'b0;
            img_start_q <= 1'b0;
        end else begin
            if (start && start_q) begin
                $display("ERROR: %m `start` was asserted for more than one cycle at time %0t. top_seq and wgt_dma both take it as a pulse.",
                         $time);
                $finish;
            end
            if (img_start && img_start_q) begin
                $display("ERROR: %m `img_start` was asserted for more than one cycle at time %0t. wgt_dma takes it as a pulse.",
                         $time);
                $finish;
            end
            start_q     <= start;
            img_start_q <= img_start;
        end
    end
`endif

endmodule

`default_nettype wire
