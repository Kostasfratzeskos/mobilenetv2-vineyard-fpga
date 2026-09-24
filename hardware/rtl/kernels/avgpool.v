`timescale 1ns / 1ps
`default_nettype none
//============================================================================
//  avgpool.v  -  global average pool accumulator (one channel, streamed)
//
//  Hardware twin of the inner sum of avgpool() in
//      software/cmodel/src/mobilenet.c
//
//  Global average pool HxWxC -> 1x1xC. For each channel, sum its H*W spatial
//  int8 samples into an accumulator; then requantize (ACT_NONE, scalar
//  m0/shift) turns that sum into the pooled int8 -- the /(H*W) averaging is
//  folded into (m0,shift) by the exporter, so there is NO divide here.
//
//  This engine is ONLY the per-channel accumulator: it streams the H*W samples
//  of one channel and produces the raw sum. The requantize engine (reused)
//  does the tail. Unlike conv1x1 this is a plain ADDER (no weights, no MAC), so
//  it costs an adder, not a DSP -- the resource-appropriate choice for pooling.
//
//  Handshake mirrors conv1x1:
//    valid - `a` is a valid sample this cycle -> accumulate
//    first - first sample of this channel (acc <- 0)
//    last  - final sample -> `done` pulses next cycle (acc is then complete)
//============================================================================
module avgpool #(
    parameter DATA_W = 8,     // int8 activations
    parameter ACC_W  = 26     // accumulator width (feeds requantize in_data)
)(
    input  wire                     clock,
    input  wire                     rst_n,     // async active-low reset
    input  wire                     valid,     // `a` valid this cycle
    input  wire                     first,     // first sample of the channel
    input  wire                     last,      // final sample of the channel
    input  wire signed [DATA_W-1:0] a,         // one spatial sample
    output reg  signed [ACC_W-1:0]  acc,       // running / final sum
    output reg                      done       // 1 the cycle acc becomes final
);

    // base = 0 on the first sample, else the running sum. Signed add
    // sign-extends the int8 sample up to ACC_W automatically.
    wire signed [ACC_W-1:0] base = first ? {ACC_W{1'b0}} : acc;

    always @(posedge clock) begin
        if (!rst_n)     acc <= {ACC_W{1'b0}};
        else if (valid) acc <= base + a;
    end

    // ---- done, with the armed bit (L-10) -------------------------------
    //  `done <= valid & last` was unconditional, so a `last` with no preceding
    //  `first` announced a stale partial sum as a finished channel. The same
    //  defect mac_lane had, and the same fix: a sticky bit recording that a
    //  `first` was actually seen. `armed | first` rather than `armed`, because a
    //  one-sample channel has first and last in the same cycle.
    reg armed;

    always @(posedge clock) begin
        if (!rst_n) begin
            armed <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= valid & last & (armed | first);

            if      (valid & first) armed <= 1'b1;
            else if (valid & last)  armed <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clock) begin
        if (rst_n && valid && last && !armed && !first) begin
            $display("ERROR: %m L-10 `last` with no preceding `first` at time %0t: the accumulator holds a stale partial sum and `done` is being suppressed.",
                     $time);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
