//
// span_buffer - one 1024-entry buffer of FULLY-RESOLVED per-pixel TSP shade inputs,
// the handoff from the "spanner" stage to the TSP shade pipeline.
//
// The spanner resolves every pixel's planes (via the plane/setup cache + prefetch)
// and WRITES the complete tsp_shade_pp input record here, one entry per tile pixel
// (index 0..1023). The TSP pipeline then READS it back at a guaranteed 1 pixel/clock
// and never stalls on a plane-cache miss - all miss latency was absorbed upstream in
// the spanner (which runs concurrently on the PREVIOUS pass's buffer via ping-pong).
//
// Payload per pixel (PW bits): the exact tsp_shade_pp inputs -
//   {shade_valid, invw, pofs, ptex, tcw, tsp, c[0..9], ddy[0..9], ddx[0..9]}
// shade_valid = this pixel is shaded this pass (PEEL skips !valid; OP sets all).
//
// Single write port (spanner) + single read port (TSP), registered read (M10K, 1-cyc
// latency). One instance is a ping-pong HALF; peel_core instantiates two.
//
module span_buffer #(
    parameter integer DEPTH = 1024
) (
    input                 clk,
    // ---- WRITE (spanner) ----
    input                 we,
    input      [9:0]      waddr,
    input                 w_shade,          // shade_valid
    input      [31:0]     w_invw,
    input                 w_ptex,
    input                 w_pofs,
    input                 w_at,             // PT alpha-test enable (cb_at_en)
    input      [31:0]     w_tsp,
    input      [31:0]     w_tcw,
    input      [31:0]     w_ddx [0:9],
    input      [31:0]     w_ddy [0:9],
    input      [31:0]     w_c   [0:9],
    // ---- READ (TSP) : present raddr, data valid next cycle ----
    input      [9:0]      raddr,
    output                r_shade,
    output     [31:0]     r_invw,
    output                r_ptex,
    output                r_pofs,
    output                r_at,             // PT alpha-test enable
    output     [31:0]     r_tsp,
    output     [31:0]     r_tcw,
    output     [31:0]     r_ddx [0:9],
    output     [31:0]     r_ddy [0:9],
    output     [31:0]     r_c   [0:9]
);
    // field offsets in the packed word
    localparam integer F_DDX   = 0;         // 10*32
    localparam integer F_DDY   = 320;       // 10*32
    localparam integer F_C     = 640;       // 10*32
    localparam integer F_TSP   = 960;       // 32
    localparam integer F_TCW   = 992;       // 32
    localparam integer F_PTEX  = 1024;      // 1
    localparam integer F_POFS  = 1025;      // 1
    localparam integer F_INVW  = 1026;      // 32
    localparam integer F_SHADE = 1058;      // 1
    localparam integer F_AT    = 1059;      // 1  (PT alpha-test enable)
    localparam integer PW      = 1060;

    (* ramstyle = "M10K, no_rw_check" *) reg [PW-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] rdw;                        // registered read word

    // pack the write word
    wire [PW-1:0] wrw;
    genvar gi;
    generate
      for (gi = 0; gi < 10; gi = gi + 1) begin : gpack
        assign wrw[F_DDX + 32*gi +: 32] = w_ddx[gi];
        assign wrw[F_DDY + 32*gi +: 32] = w_ddy[gi];
        assign wrw[F_C   + 32*gi +: 32] = w_c  [gi];
      end
    endgenerate
    assign wrw[F_TSP   +: 32] = w_tsp;
    assign wrw[F_TCW   +: 32] = w_tcw;
    assign wrw[F_PTEX]        = w_ptex;
    assign wrw[F_POFS]        = w_pofs;
    assign wrw[F_INVW  +: 32] = w_invw;
    assign wrw[F_SHADE]       = w_shade;
    assign wrw[F_AT]          = w_at;

    always @(posedge clk) begin
        if (we) mem[waddr] <= wrw;
        rdw <= mem[raddr];                   // registered read
    end

    // unpack the read word
    generate
      for (gi = 0; gi < 10; gi = gi + 1) begin : gunpack
        assign r_ddx[gi] = rdw[F_DDX + 32*gi +: 32];
        assign r_ddy[gi] = rdw[F_DDY + 32*gi +: 32];
        assign r_c  [gi] = rdw[F_C   + 32*gi +: 32];
      end
    endgenerate
    assign r_tsp   = rdw[F_TSP  +: 32];
    assign r_tcw   = rdw[F_TCW  +: 32];
    assign r_ptex  = rdw[F_PTEX];
    assign r_pofs  = rdw[F_POFS];
    assign r_invw  = rdw[F_INVW +: 32];
    assign r_shade = rdw[F_SHADE];
    assign r_at    = rdw[F_AT];
endmodule
