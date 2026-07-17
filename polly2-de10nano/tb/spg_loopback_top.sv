// Loopback wrapper: simplex_pvr_top's FB write master and spg's display read
// side by side, for the write-layout vs scanout-layout cross-check
// (spg_loopback_tb.cpp). The C++ testbench models the DDR between them as a
// single byte array: the write port fills it, spg's Avalon reads are served
// from it, and every displayed pixel is compared against the streamed one.
module spg_loopback_top import tsp_pkg::*; (
    input  wire        clk,
    input  wire        reset,       // core (write-side) reset
    input  wire        spg_reset,   // video-side reset

    // peel_core_stub control (see peel_core_stub.sv)
    input  wire        wr_en,
    input  wire [12:0] wr_addr,
    input  wire [31:0] wr_data,

    // ---- FB write channel (to the C++ DDR model) ----
    input  wire        DDRAM2_BUSY,
    output wire [7:0]  DDRAM2_BURSTCNT,
    output wire [28:0] DDRAM2_ADDR,
    output wire [63:0] DDRAM2_DIN,
    output wire [7:0]  DDRAM2_BE,
    output wire        DDRAM2_WE,

    // ---- spg config ----
    input  wire [31:0] fb_base,
    input  wire [13:0] fb_stride,
    input  wire        fb_line_dbl,
    input  wire        fb_split,
    input  wire        fb_disp_half,

    // ---- spg display read channel (from the C++ DDR model) ----
    output wire         avl_read,
    output wire [27:0]  avl_address,
    output wire [7:0]   avl_burstcount,
    input  wire         avl_waitrequest,
    input  wire [127:0] avl_readdata,
    input  wire         avl_readdatavalid,

    // ---- spg video out ----
    output wire [7:0]  red,
    output wire [7:0]  green,
    output wire [7:0]  blue,
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire        vblank,
    output wire        border,
    output wire        underrun
);

    // write side: only the DDRAM2 channel is used; the render-read channel is
    // tied off (the stub only issues reads when commanded, which this TB
    // never does)
    simplex_pvr_top u_pvr (
        .clk    (clk),
        .reset  (reset),
        .wr_en  (wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .go     (1'b0),
        .done   (),
        .tex_en (1'b1),
        .FB_R_SOF1(), .FB_R_SOF2(), .FB_W_SOF1(), .FB_W_SOF2(), .TEST_SELECT(),

        .DDRAM_CLK       (),
        .DDRAM_BUSY      (1'b0),
        .DDRAM_BURSTCNT  (),
        .DDRAM_ADDR      (),
        .DDRAM_DOUT      (64'd0),
        .DDRAM_DOUT_READY(1'b0),
        .DDRAM_RD        (),

        .DDRAM2_CLK      (),
        .DDRAM2_BUSY     (DDRAM2_BUSY),
        .DDRAM2_BURSTCNT (DDRAM2_BURSTCNT),
        .DDRAM2_ADDR     (DDRAM2_ADDR),
        .DDRAM2_DIN      (DDRAM2_DIN),
        .DDRAM2_BE       (DDRAM2_BE),
        .DDRAM2_WE       (DDRAM2_WE)
    );

    // read side: same clock for video and avalon domains (the CDC toggles
    // inside spg are same-clock safe)
    spg u_spg (
        .clk         (clk),
        .reset       (spg_reset),

        .fb_base     (fb_base),
        .fb_stride   (fb_stride),
        .fb_line_dbl (fb_line_dbl),
        .fb_split    (fb_split),
        .fb_disp_half(fb_disp_half),

        .avl_clk          (clk),
        .avl_read         (avl_read),
        .avl_address      (avl_address),
        .avl_burstcount   (avl_burstcount),
        .avl_waitrequest  (avl_waitrequest),
        .avl_readdata     (avl_readdata),
        .avl_readdatavalid(avl_readdatavalid),

        .red   (red),
        .green (green),
        .blue  (blue),
        .hsync (hsync),
        .vsync (vsync),
        .de    (de),
        .vblank(vblank),
        .border(border),

        .src_line  (),
        .vblank_in (),
        .vblank_out(),
        .underrun  (underrun)
    );

endmodule
