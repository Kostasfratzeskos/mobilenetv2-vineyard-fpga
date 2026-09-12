`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  line_buffer.v  -  KxK sliding-window generator for the depthwise engine
//
//  Build plan #5. This is the module that finally replaces the hand-built
//  windows in dwconv_layer_tb and stem_layer_tb. Those testbenches read nine
//  activations per output element; this reads each input pixel EXACTLY ONCE
//  and lets the window fall out of two row delays plus a KxK shift register.
//
//  A "pixel" here is a group of TC channels (TC*8 bit), because the depthwise
//  engine works on TC channels in parallel (DD-014, Tc=16). Depthwise has no
//  cross-channel accumulation, so the TC channels ride through the window
//  machinery side by side and never interact.
//
//  ---- how the window appears ------------------------------------------
//
//  Pixels stream in raster order. Two line delays mean that while row r is
//  arriving, lb0 still holds row r-1 and lb1 holds row r-2. The KxK register
//  shifts one column per pixel, so after consuming (r, x) it holds
//
//        rows r-2, r-1, r   x   columns x-2, x-1, x
//
//  which is the window CENTRED AT (r-1, x-1). The window therefore trails the
//  input by one row and one column - that is not latency to be removed, it is
//  what a 3x3 window means.
//
//  ---- padding without clearing memory ---------------------------------
//
//  SAME padding needs a zero row above row 0, a zero column left of column 0,
//  and likewise past the far edges. Three mechanisms cover all of it:
//
//    top    : the new column is masked to zero while in_y < 1 (row -1) and
//             in_y < 2 (row -2), so the stale contents of lb0/lb1 at the start
//             of a pass never reach the window. No memory clearing needed,
//             which would otherwise cost img_w cycles per pass.
//    left   : at in_x == 0 the two left columns of the register are cleared
//             rather than shifted, so the window at cx = 0 sees zero on its
//             left. NOTE, measured: this clear is REDUNDANT as long as the
//             feeder walks the virtual column. That column injects a zero into
//             the right-hand column of the register at (r-1, img_w); two
//             shifts later - at (r, 1), which is where the first window of the
//             row is emitted - the zero has arrived in the leftmost column on
//             its own. Mutation testing found this: removing the clear passes
//             the whole testbench. It is kept deliberately, because deleting it
//             would make left-edge padding depend on the virtual-column
//             invariant as well as right-edge padding, so a later "optimisation"
//             that skipped the virtual column would break two things instead of
//             one. The cost is a 2:1 mux on 6 x 128 bit, about 0.3% of the LUTs.
//    right
//    bottom : the FEEDER walks one extra column and one extra row - in_x up to
//             img_w and in_y up to img_h - driving in_data = 0 there. That
//             virtual edge is what lets the last real row and column be
//             centred. It costs (H+W+1) extra cycles per pass, 1.8% at
//             112x112.
//
//  ---- who owns the counters -------------------------------------------
//
//  Not this module. The feeder owns in_x / in_y because it has to compute
//  activation-buffer addresses a cycle ahead of the data, and it is the one
//  that knows which coordinates are virtual. This module is a pure dataflow
//  element: give it a pixel and its coordinates, get a window. Same division
//  as everywhere else here - addressing is the controller's job.
//
//  ---- stride ----------------------------------------------------------
//
//  Every input pixel must still be consumed at stride 2 (the window has to
//  slide past it), but only windows whose centre is even in both axes are
//  emitted. That is why the depthwise cycle count follows the INPUT grid, not
//  the output grid - the correction noted in DD-014.
//
//  Window packing, matching dwconv3x3's tap order i = ky*K + kx:
//      win[((ky*K + kx)*TC + c)*DATA_W +: DATA_W]
//  so channel c's nine taps are strided by TC bytes through the bus.
//
//  Written for K=3; the parameter documents the shape rather than generalising
//  it, exactly as in dwconv3x3.
//
//  Run:  bash scripts/run_sim.sh line_buffer
//============================================================================
module line_buffer #(
    parameter DATA_W = 8,      // int8 activations
    parameter TC     = 16,     // channels carried in parallel
    parameter K      = 3,      // KxK window
    parameter MAX_W  = 112,    // widest input row in the network
    parameter XW     = 8       // coordinate width, covers MAX_W inclusive
)(
    input  wire                      clock,
    input  wire                      rst_n,

    // ---- input stream: one pixel-group per cycle, raster order ---------
    input  wire                      in_valid,
    input  wire [TC*DATA_W-1:0]      in_data,   // 0 on the virtual edge
    input  wire [XW-1:0]             in_x,      // 0 .. img_w  (img_w = virtual)
    input  wire [XW-1:0]             in_y,      // 0 .. img_h  (img_h = virtual)
    input  wire                      stride2,   // 1 = emit every other centre

    // ---- output: the window centred at (in_y-1, in_x-1) ---------------
    output wire [K*K*TC*DATA_W-1:0]  win,
    output reg                       win_valid,
    output reg  [XW-1:0]             out_x,     // in OUTPUT coordinates
    output reg  [XW-1:0]             out_y
);

    localparam GW = TC*DATA_W;        // bits per pixel-group (128)

    // ---- two row delays -------------------------------------------------
    // lb0 holds the previous row, lb1 the one before it. Combinational reads
    // (distributed RAM at this size) so no extra pipeline stage is needed; the
    // non-blocking writes below mean a read returns the OLD value, which is
    // exactly the cascade lb1 <= lb0 <= in_data.
    reg [GW-1:0] lb0 [0:MAX_W];
    reg [GW-1:0] lb1 [0:MAX_W];

    wire [GW-1:0] lb0_out = lb0[in_x];
    wire [GW-1:0] lb1_out = lb1[in_x];

    always @(posedge clock) begin
        if (in_valid) begin
            lb1[in_x] <= lb0_out;
            lb0[in_x] <= in_data;
        end
    end

    // ---- the KxK shift register -----------------------------------------
    // wr[ky*K + kx], ky = 0 is the topmost row, kx = 0 the leftmost column.
    reg [GW-1:0] wr [0:K*K-1];

    // the new right-hand column, with the top rows masked while they would
    // read rows -1 and -2
    wire [GW-1:0] col_top = (in_y >= 2) ? lb1_out : {GW{1'b0}};
    wire [GW-1:0] col_mid = (in_y >= 1) ? lb0_out : {GW{1'b0}};

    integer ky;
    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            for (ky = 0; ky < K*K; ky = ky + 1) wr[ky] <= {GW{1'b0}};
        end else if (in_valid) begin
            if (in_x == {XW{1'b0}}) begin
                // start of a row: the two columns to the left are outside the
                // image, so clear them instead of shifting the previous row in
                for (ky = 0; ky < K; ky = ky + 1) begin
                    wr[ky*K + 0] <= {GW{1'b0}};
                    wr[ky*K + 1] <= {GW{1'b0}};
                end
            end else begin
                for (ky = 0; ky < K; ky = ky + 1) begin
                    wr[ky*K + 0] <= wr[ky*K + 1];
                    wr[ky*K + 1] <= wr[ky*K + 2];
                end
            end
            wr[0*K + 2] <= col_top;
            wr[1*K + 2] <= col_mid;
            wr[2*K + 2] <= in_data;
        end
    end

    genvar g;
    generate
        for (g = 0; g < K*K; g = g + 1) begin : pack
            assign win[g*GW +: GW] = wr[g];
        end
    endgenerate

    // ---- which centres are emitted --------------------------------------
    // The centre is (in_y-1, in_x-1); it exists once both are at least 1, and
    // at stride 2 only when both are even.
    wire [XW-1:0] cy = in_y - 1'b1;
    wire [XW-1:0] cx = in_x - 1'b1;
    wire          in_range = (in_y >= 1) && (in_x >= 1);
    wire          aligned  = !stride2 || (!cy[0] && !cx[0]);

    always @(posedge clock or negedge rst_n) begin
        if (!rst_n) begin
            win_valid <= 1'b0;
            out_x     <= {XW{1'b0}};
            out_y     <= {XW{1'b0}};
        end else if (in_valid) begin
            win_valid <= in_range && aligned;
            out_y     <= stride2 ? (cy >> 1) : cy;
            out_x     <= stride2 ? (cx >> 1) : cx;
        end else begin
            win_valid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
