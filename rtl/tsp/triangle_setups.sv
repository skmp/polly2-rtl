//
// triangle_setups - the per-triangle resolved-plane store, keyed by setup id.
//
// spanner_v2's SETUP engine writes one entry per DISTINCT triangle of a tile pass:
//   {isp, tsp, tcw, 10 x ddx, 10 x ddy, 10 x c}
// The shade reader looks it up by the span's id and presents the planes to tsp_shade_pp
// (deriving pp_texture/pp_offset from the isp word). This holds planes ONCE per triangle
// instead of the old span_buffer's copy-per-pixel.
//
// Write port takes the FLAT 320-bit plane vectors (spanner_v2 ts_ddx/ddy/c); read port
// unpacks to 10-lane arrays for tsp_shade_pp. Registered read (M10K, 1-cyc). One instance
// is a ping-pong HALF; peel_core instantiates two.
//
module triangle_setups import tsp_pkg::*; #(
    parameter integer DEPTH = 1024,
    parameter integer AW    = 10
) (
    input                 clk,
    // ---- WRITE (spanner_v2 ts_* port) ----
    input                 we,
    input      [AW-1:0]   waddr,            // setup id
    input      [31:0]     w_isp, w_tsp, w_tcw,
    input      [319:0]    w_ddx, w_ddy, w_c,  // 10 x 32, lane j at [32*j +: 32]
    // ---- READ (reader) : present raddr, data valid next cycle ----
    input      [AW-1:0]   raddr,
    output     [31:0]     r_tsp, r_tcw,
    output                r_ptex,           // isp[ISP_TEXTURE_BIT]
    output                r_pofs,           // isp[ISP_OFFSET_BIT]
    output     [31:0]     r_ddx [0:9],
    output     [31:0]     r_ddy [0:9],
    output     [31:0]     r_c   [0:9]
);
    localparam integer F_ISP = 0;           // 32
    localparam integer F_TSP = 32;          // 32
    localparam integer F_TCW = 64;          // 32
    localparam integer F_DDX = 96;          // 320
    localparam integer F_DDY = 416;         // 320
    localparam integer F_C   = 736;         // 320
    localparam integer PW    = 1056;

    (* ramstyle = "M10K, no_rw_check" *) reg [PW-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] rdw;

    wire [PW-1:0] wrw;
    assign wrw[F_ISP +: 32]  = w_isp;
    assign wrw[F_TSP +: 32]  = w_tsp;
    assign wrw[F_TCW +: 32]  = w_tcw;
    assign wrw[F_DDX +: 320] = w_ddx;
    assign wrw[F_DDY +: 320] = w_ddy;
    assign wrw[F_C   +: 320] = w_c;

    always @(posedge clk) begin
        if (we) mem[waddr] <= wrw;
        rdw <= mem[raddr];
    end

    wire [31:0] r_isp = rdw[F_ISP +: 32];
    assign r_tsp  = rdw[F_TSP +: 32];
    assign r_tcw  = rdw[F_TCW +: 32];
    assign r_ptex = r_isp[ISP_TEXTURE_BIT];
    assign r_pofs = r_isp[ISP_OFFSET_BIT];
    genvar gi;
    generate
      for (gi = 0; gi < 10; gi = gi + 1) begin : gunpack
        assign r_ddx[gi] = rdw[F_DDX + 32*gi +: 32];
        assign r_ddy[gi] = rdw[F_DDY + 32*gi +: 32];
        assign r_c  [gi] = rdw[F_C   + 32*gi +: 32];
      end
    endgenerate
endmodule
