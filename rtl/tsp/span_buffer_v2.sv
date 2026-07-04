//
// span_buffer - the THIN span handoff from spanner_v2 (SPANGEN) to the TSP shade reader.
//
// spanner_v2 coalesces the leading same-tag run of each aligned 4-group into ONE span and
// writes it at the run-start pixel index: {id, rep, invw[0:3], shmask, at}. The setup id
// references triangle_setups[id] (the resolved planes, held separately). The shade reader
// walks run-starts (x += rep), looks up triangle_setups[id], and presents `rep` pixels.
//
// Replaces the old FAT per-pixel record (which stored resolved planes for every pixel);
// planes now live once per triangle in triangle_setups, keyed by id.
//
// Single write port (spanner) + single read port (reader), registered read (M10K, 1-cyc).
// One instance is a ping-pong HALF; peel_core instantiates two.
//
module span_buffer_v2 #(
    parameter integer DEPTH = 1024
) (
    input                 clk,
    // ---- WRITE (spanner_v2 sp_* port) ----
    input                 we,
    input      [9:0]      waddr,            // run-start pixel index (sp_idx)
    input      [9:0]      w_id,             // setup id (-> triangle_setups)
    input      [2:0]      w_rep,            // run length 1..4
    input      [31:0]     w_invw [0:3],     // per-covered-pixel invW (lanes 0..rep-1)
    input      [3:0]      w_shmask,         // per-covered-lane shade-valid
    input                 w_at,             // PT alpha-test enable (run-start lane)
    // ---- READ (reader) : present raddr, data valid next cycle ----
    input      [9:0]      raddr,
    output     [9:0]      r_id,
    output     [2:0]      r_rep,
    output     [31:0]     r_invw [0:3],
    output     [3:0]      r_shmask,
    output                r_at
);
    localparam integer F_ID     = 0;        // 10
    localparam integer F_REP    = 10;       // 3
    localparam integer F_INVW   = 13;       // 4*32 = 128
    localparam integer F_SHMASK = 141;      // 4
    localparam integer F_AT     = 145;      // 1
    localparam integer PW       = 146;

    (* ramstyle = "M10K, no_rw_check" *) reg [PW-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] rdw;                        // registered read word

    wire [PW-1:0] wrw;
    genvar gi;
    generate
      for (gi = 0; gi < 4; gi = gi + 1) begin : gpack
        assign wrw[F_INVW + 32*gi +: 32] = w_invw[gi];
      end
    endgenerate
    assign wrw[F_ID     +: 10] = w_id;
    assign wrw[F_REP    +: 3]  = w_rep;
    assign wrw[F_SHMASK +: 4]  = w_shmask;
    assign wrw[F_AT]           = w_at;

    always @(posedge clk) begin
        if (we) mem[waddr] <= wrw;
        rdw <= mem[raddr];                   // registered read
    end

    generate
      for (gi = 0; gi < 4; gi = gi + 1) begin : gunpack
        assign r_invw[gi] = rdw[F_INVW + 32*gi +: 32];
      end
    endgenerate
    assign r_id     = rdw[F_ID     +: 10];
    assign r_rep    = rdw[F_REP    +: 3];
    assign r_shmask = rdw[F_SHMASK +: 4];
    assign r_at     = rdw[F_AT];
endmodule
