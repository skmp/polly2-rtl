//
// span_buffer_v2 - the THIN per-pixel handoff from the span expander to the TSP shade
// reader.
//
// spanner_v2 emits coalesced sparse spans; a small span_expander walks each span's `rep`
// covered pixels and writes ONE entry per pixel here: {shade, id, invw, at}. The shade
// reader then walks pixels 0..1023 densely (the proven tsp_st pattern), reads this entry,
// looks up triangle_setups[id] for the planes, and presents tsp_shade_pp.
//
// This keeps the READER a dense per-pixel walk (no data-dependent run stepping); the
// sparse->per-pixel expansion lives on the non-timing-critical write side. Planes are NOT
// duplicated here (only the 10-bit id) - they live once per triangle in triangle_setups.
//
// Single write port (expander) + single read port (reader), registered read (M10K, 1-cyc).
// One instance is a ping-pong HALF; peel_core instantiates two.
//
module span_buffer_v2 #(
    parameter integer DEPTH = 1024
) (
    input                 clk,
    // ---- WRITE (span_expander, one entry per covered pixel) ----
    input                 we,
    input      [9:0]      waddr,            // pixel index 0..1023
    input                 w_shade,          // this pixel is shaded this pass
    input      [9:0]      w_id,             // setup id (-> triangle_setups)
    input      [31:0]     w_invw,           // per-pixel invW
    input                 w_at,             // PT alpha-test enable
    // ---- READ (reader) : present raddr, data valid next cycle ----
    input      [9:0]      raddr,
    output                r_shade,
    output     [9:0]      r_id,
    output     [31:0]     r_invw,
    output                r_at
);
    localparam integer F_SHADE = 0;         // 1
    localparam integer F_ID    = 1;         // 10
    localparam integer F_INVW  = 11;        // 32
    localparam integer F_AT    = 43;        // 1
    localparam integer PW      = 44;

    (* ramstyle = "M10K, no_rw_check" *) reg [PW-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] rdw;

    wire [PW-1:0] wrw;
    assign wrw[F_SHADE]      = w_shade;
    assign wrw[F_ID   +: 10] = w_id;
    assign wrw[F_INVW +: 32] = w_invw;
    assign wrw[F_AT]         = w_at;

    always @(posedge clk) begin
        if (we) mem[waddr] <= wrw;
        rdw <= mem[raddr];
    end

    assign r_shade = rdw[F_SHADE];
    assign r_id    = rdw[F_ID   +: 10];
    assign r_invw  = rdw[F_INVW +: 32];
    assign r_at    = rdw[F_AT];
endmodule
