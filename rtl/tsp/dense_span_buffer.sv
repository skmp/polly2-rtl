//
// dense_span_buffer - the DENSE spanner_v2 -> TSP handoff. spanner_v2 emits shaded spans
// into a shared RING; this stores one span per slot:
//   { start (run-start pixel y:x), rep (1..4), id (triangle_setups slot), invw[0:3], at }
// The TSP reader walks a pass's ring range (base..base+cnt-1, wrapping), reads a span, and
// EXPANDS its `rep` pixels into the shade pipeline (pixel k = start+k, invw[k]). No per-pixel
// dense walk, no shade mask - every stored span is shaded. ONE shared RING instance (the ring
// pointers live in spanner_v2 / peel_core); DEPTH = ring size (2048 = two worst-case tiles).
//
// Registered read (M10K, 1-cyc): present raddr, span fields valid next cycle.
//
module dense_span_buffer #(
    parameter integer DEPTH = 2048,
    parameter integer AW    = $clog2(DEPTH)   // slot-address width (derived from DEPTH)
) (
    input                 clk,
    // ---- WRITE (spanner_v2 sp_* dense port): one span at the ring head slot ----
    input                 we,
    input      [AW-1:0]   waddr,            // ring slot (sp_slot = span_head)
    input      [9:0]      w_start,          // run-start pixel index (y:x)
    input      [9:0]      w_id,             // setup id (-> triangle_setups)
    input      [2:0]      w_rep,            // run length 1..4
    input      [31:0]     w_invw [0:3],     // per-covered-pixel invW
    input                 w_at,             // PT alpha-test enable
    // ---- READ (reader): present raddr, span valid next cycle ----
    input      [AW-1:0]   raddr,
    output     [9:0]      r_start,
    output     [9:0]      r_id,
    output     [2:0]      r_rep,
    output     [31:0]     r_invw [0:3],
    output                r_at
);
    localparam integer F_START = 0;         // 10
    localparam integer F_ID    = 10;        // 10
    localparam integer F_REP   = 20;        // 3
    localparam integer F_INVW  = 23;        // 128 (4 x 32)
    localparam integer F_AT    = 151;       // 1
    localparam integer PW      = 152;

    (* ramstyle = "M10K, no_rw_check" *) reg [PW-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] rdw;

    wire [PW-1:0] wrw;
    assign wrw[F_START +: 10] = w_start;
    assign wrw[F_ID    +: 10] = w_id;
    assign wrw[F_REP   +: 3]  = w_rep;
    assign wrw[F_AT]          = w_at;
    genvar gi;
    generate
      for (gi = 0; gi < 4; gi = gi + 1)
        assign wrw[F_INVW + 32*gi +: 32] = w_invw[gi];
    endgenerate

    always @(posedge clk) begin
        if (we) mem[waddr] <= wrw;
        rdw <= mem[raddr];
    end

    assign r_start = rdw[F_START +: 10];
    assign r_id    = rdw[F_ID    +: 10];
    assign r_rep   = rdw[F_REP   +: 3];
    assign r_at    = rdw[F_AT];
    genvar gr;
    generate
      for (gr = 0; gr < 4; gr = gr + 1)
        assign r_invw[gr] = rdw[F_INVW + 32*gr +: 32];
    endgenerate
endmodule
