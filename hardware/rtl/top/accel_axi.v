`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  accel_axi.v  -  accel_sys + axi_lite_csr: the accelerator a processor drives
//
//  Third and last of the layered tops, and the first one with no control pins
//  at all. The layering is deliberate and each level is separately measurable:
//
//      accel_top   the datapath and the sequencer.       846 port bits
//      accel_sys   + wgt_dma, so weights come from DDR.  499 port bits
//      accel_axi   + axi_lite_csr, so a PS drives it.    354 port bits
//
//  Nothing below this file changed to make it exist. accel_sys and accel_top are
//  byte-identical to what they were, which is why all 35 testbenches still pass
//  and why a failure here can only be in this wiring or in the CSR.
//
//  ---- what those 354 bits ARE, which is the whole point -----------------
//
//      AXI4 master       196    weights and parameters from PS-DDR
//      AXI-Lite slave    114    every control and status register
//      image load         41    im_wr_*, the one exception
//      clock, rst_n, irq   3
//
//  Compare accel_top, where 672 of 846 bits were the load side and existed as
//  pins only because nothing drove them. There is now nothing on this module
//  that is not an AXI interface, a clock, a reset, an interrupt - or the image.
//
//  ---- what is left, and it is one thing ---------------------------------
//
//      im_wr_*   41 bits   the image load. 224x224x3 = 147 KB from the PS.
//
//  That is the ONLY remaining port group that is not an AXI interface, a clock,
//  a reset or the interrupt. It was deliberately not folded in here: the right
//  answer is a second AXI4 read channel sharing wgt_dma's burst logic, and
//  routing 50,176 single AXI-Lite writes through the CSR instead would have
//  been a stopgap that then had to be removed. It is the next item of work, and
//  when it lands this file becomes the board top with no other change.
//
//  ---- so what CAN be done now that could not before ---------------------
//
//  A PS can run an inference. Concretely, and this is the whole sequence:
//
//      write ID           read it back, confirm the aperture is alive
//      write the program   512 words into the 0x1000 aperture
//      write WGT/PB/PM/PS_BASE  where the blobs are in DDR
//      write N_INSTR       64
//      write CTRL bit 0    START
//      poll STATUS bit 1   (or take the interrupt)
//      read RESULT_LO/HI, ARGMAX
//
//  accel_axi_tb does exactly that and nothing else, over two AXI interfaces,
//  and gets all 64 golden tensors bit-exact. Before this file, the same run
//  needed a testbench driving seven separate port groups.
//
//  ---- why the CSR is a sibling of accel_sys and not inside it ------------
//
//  Same reason wgt_dma is a sibling of accel_top rather than inside it. Folding
//  the CSR into accel_sys would have meant rewriting accel_dma_tb to drive
//  AXI-Lite, which would have made accel_dma_tb test two new things at once -
//  and the value of that testbench is precisely that it changes ONE thing
//  against accel_tb. Three tops cost three XDCs and three synthesis runs; they
//  buy the ability to say which layer a number belongs to.
//
//  Run:  bash scripts/run_sim.sh accel_axi accel_sys axi_lite_csr wgt_dma \
//          accel_top top_seq pw_feeder pw_out dw_feeder res_feeder \
//          gap_feeder stem_feeder logit_out out_stage pe_array mac_lane \
//          conv1x1 dwconv3x3 conv3x3_std dw_array stem_array line_buffer \
//          avgpool addr_gen wgt_buffer act_buffer img_buffer param_buffer \
//          rq_bank bias_add requantize
//============================================================================
module accel_axi #(
    // ---- datapath geometry, passed straight down --------------------------
    parameter DATA_W  = 8,
    parameter TM      = 32,  parameter TM_LOG = 5,
    parameter TN      = 16,  parameter TN_LOG = 4,
    parameter TC      = 16,  parameter TC_LOG = 4,
    parameter TS      = 8,   parameter TS_LOG = 3,
    parameter CIN     = 3,
    parameter K       = 3,
    parameter ACC_W   = 26,
    parameter BIAS_W  = 32,
    parameter M0_W    = 32,
    parameter SHIFT_W = 6,

    parameter ADEPTH  = 50176,
    parameter AA_W    = 16,
    parameter IDEPTH  = 50176,
    parameter IA_W    = 16,
    parameter PW_WDEPTH = 1024, parameter PW_WA_W = 10,
    parameter DW_WDEPTH = 64,   parameter DW_WA_W = 6,
    parameter ST_WDEPTH = 8,    parameter ST_WA_W = 4,
    parameter PDEPTH  = 64,     parameter PA_W   = 6,

    parameter PIX_W   = 16,
    parameter OCT_W   = 8,
    parameter ICT_W   = 8,
    parameter SLW     = 8,
    parameter GRPW    = 6,
    parameter OCTW    = 4,
    parameter XW_DW   = 8,
    parameter XW_ST   = 9,

    parameter PW_W    = 32,
    parameter PGA_W   = 9,
    parameter PROG_DEPTH = 512,
    parameter NI_W    = 8,
    parameter OS_LAT  = 5,
    parameter GAP_CYC = OS_LAT,
    parameter WDOG_W  = 20,

    parameter NLOG    = 4,
    parameter IDX_W   = 2,
    parameter LOG_W   = 16,

    parameter OFF_W   = 24,
    parameter BYT_W   = 20,
    parameter PCH_W   = 16,

    // ---- AXI4 read master (weights and parameters from DDR) --------------
    parameter AXI_ADDR_W  = 32,
    parameter AXI_DATA_W  = 128,
    parameter AXI_ID_W    = 4,
    parameter AXI_ID      = 0,
    parameter MAX_BURST   = 256,
    parameter MAX_OUTST   = 4,
    parameter RFIFO_DEPTH = 32,
    parameter RFIFO_AW    = 5,

    // ---- AXI4-Lite slave (control) ---------------------------------------
    //  8 KB: 0x0000 registers, 0x1000 the 2 KB program aperture.
    parameter CSR_ADDR_W  = 13,
    parameter CSR_DATA_W  = 32,
    parameter [31:0] ID_MAGIC = 32'h56_49_4E_45
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- AXI4-Lite slave: everything the PS configures and reads ---------
    input  wire [CSR_ADDR_W-1:0]     s_axi_awaddr,
    input  wire [2:0]                s_axi_awprot,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,
    input  wire [CSR_DATA_W-1:0]     s_axi_wdata,
    input  wire [CSR_DATA_W/8-1:0]   s_axi_wstrb,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,
    output wire [1:0]                s_axi_bresp,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,
    input  wire [CSR_ADDR_W-1:0]     s_axi_araddr,
    input  wire [2:0]                s_axi_arprot,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,
    output wire [CSR_DATA_W-1:0]     s_axi_rdata,
    output wire [1:0]                s_axi_rresp,
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready,

    // ---- image load: the one remaining non-AXI port group ----------------
    input  wire                      im_wr_en,
    input  wire [IA_W-1:0]           im_wr_addr,
    input  wire [CIN*DATA_W-1:0]     im_wr_data,

    // ---- AXI4 read-only master to PS-DDR ---------------------------------
    output wire [AXI_ID_W-1:0]       m_axi_arid,
    output wire [AXI_ADDR_W-1:0]     m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arlock,
    output wire [3:0]                m_axi_arcache,
    output wire [2:0]                m_axi_arprot,
    output wire                      m_axi_arvalid,
    input  wire                      m_axi_arready,

    input  wire [AXI_ID_W-1:0]       m_axi_rid,
    input  wire [AXI_DATA_W-1:0]     m_axi_rdata,
    input  wire [1:0]                m_axi_rresp,
    input  wire                      m_axi_rlast,
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready,

    // ---- to the PS's interrupt controller --------------------------------
    output wire                      irq
);

    // ---- everything that used to be a pin --------------------------------
    wire                    start;
    wire [NI_W-1:0]         n_instr;
    wire [AXI_ADDR_W-1:0]   wgt_base, pb_base, pm_base, ps_base;
    wire                    pg_en;
    wire [PGA_W-1:0]        pg_addr;
    wire [PW_W-1:0]         pg_data;

    wire [NLOG*LOG_W-1:0]   logits;
    wire                    logits_valid;
    wire [IDX_W-1:0]        argmax;
    wire                    argmax_valid;
    wire [NI_W-1:0]         pc;
    wire                    running, done, tag_error, fault, dma_error;

    // ======================================================================
    axi_lite_csr #(
        .AXI_ADDR_W(AXI_ADDR_W), .ADDR_W(CSR_ADDR_W), .DATA_W(CSR_DATA_W),
        .NI_W(NI_W), .PGA_W(PGA_W), .PW_W(PW_W),
        .NLOG(NLOG), .LOG_W(LOG_W), .IDX_W(IDX_W), .ID_MAGIC(ID_MAGIC)
    ) u_csr (
        .clock(clock), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .start(start), .n_instr(n_instr),
        .wgt_base(wgt_base), .pb_base(pb_base),
        .pm_base(pm_base), .ps_base(ps_base),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .running(running), .done(done), .fault(fault),
        .dma_error(dma_error), .tag_error(tag_error), .pc(pc),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid),
        .irq(irq)
    );

    accel_sys #(
        .DATA_W(DATA_W),
        .TM(TM), .TM_LOG(TM_LOG), .TN(TN), .TN_LOG(TN_LOG),
        .TC(TC), .TC_LOG(TC_LOG), .TS(TS), .TS_LOG(TS_LOG),
        .CIN(CIN), .K(K), .ACC_W(ACC_W), .BIAS_W(BIAS_W), .M0_W(M0_W),
        .SHIFT_W(SHIFT_W),
        .ADEPTH(ADEPTH), .AA_W(AA_W), .IDEPTH(IDEPTH), .IA_W(IA_W),
        .PW_WDEPTH(PW_WDEPTH), .PW_WA_W(PW_WA_W),
        .DW_WDEPTH(DW_WDEPTH), .DW_WA_W(DW_WA_W),
        .ST_WDEPTH(ST_WDEPTH), .ST_WA_W(ST_WA_W),
        .PDEPTH(PDEPTH), .PA_W(PA_W),
        .PIX_W(PIX_W), .OCT_W(OCT_W), .ICT_W(ICT_W), .SLW(SLW),
        .GRPW(GRPW), .OCTW(OCTW), .XW_DW(XW_DW), .XW_ST(XW_ST),
        .PW_W(PW_W), .PGA_W(PGA_W), .PROG_DEPTH(PROG_DEPTH), .NI_W(NI_W),
        .OS_LAT(OS_LAT), .GAP_CYC(GAP_CYC), .WDOG_W(WDOG_W),
        .NLOG(NLOG), .IDX_W(IDX_W), .LOG_W(LOG_W),
        .OFF_W(OFF_W), .BYT_W(BYT_W), .PCH_W(PCH_W),
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
        .AXI_ID_W(AXI_ID_W), .AXI_ID(AXI_ID),
        .MAX_BURST(MAX_BURST), .MAX_OUTST(MAX_OUTST),
        .RFIFO_DEPTH(RFIFO_DEPTH), .RFIFO_AW(RFIFO_AW)
    ) u_sys (
        .clock(clock), .rst_n(rst_n),
        .start(start), .n_instr(n_instr),
        .wgt_base(wgt_base), .pb_base(pb_base),
        .pm_base(pm_base),   .ps_base(ps_base),
        .pg_en(pg_en), .pg_addr(pg_addr), .pg_data(pg_data),
        .im_wr_en(im_wr_en), .im_wr_addr(im_wr_addr), .im_wr_data(im_wr_data),
        .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready),
        .logits(logits), .logits_valid(logits_valid),
        .argmax(argmax), .argmax_valid(argmax_valid),
        .pc(pc), .running(running), .done(done), .tag_error(tag_error),
        .fault(fault), .dma_error(dma_error)
    );

endmodule

`default_nettype wire
