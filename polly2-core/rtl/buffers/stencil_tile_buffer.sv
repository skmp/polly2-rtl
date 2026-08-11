//
// stencil_tile_buffer - the MODIFIER VOLUME stencil plane for one 32x32 tile.
//
// refsw2 keeps a 3-bit stencil per pixel (refsw_tile.cpp stencilBuffer) and this
// module is that byte, banked for the raster:
//
//   bit0 INV   "this pixel is inside the accumulated shadow volume". The only bit
//              TSP ever sees: refsw2 RenderParamTags computes
//                  InVolume = (stencil & 0b001) && tag.shadow
//              and, in CHEAP-SHADOW mode (FPU_SHAD_SCALE.intensity_shadow), scales
//              the interpolated base/offset colour by FPU_SHAD_SCALE.scale_factor.
//   bit1 FLIP  per-volume parity. A modifier-volume triangle that passes the depth
//              test TOGGLES it (refsw2 PixelFlush_isp RM_MODIFIER: `*stencil ^= 0b0010`).
//   bit2 SUM   "a modvol triangle touched this pixel in the current volume", set
//              alongside every flip (`*stencil |= 0b100`). It is what makes the
//              summarize a no-op on untouched pixels.
//
// VOLUME END (refsw2 RenderTriangle, after RM_MODIFIER rasterization): a triangle
// whose ISP word carries VolumeMode != 0 closes the volume and SUMMARIZES the whole
// tile - SummarizeStencilOr for VolumeMode 1 ("inside last"), SummarizeStencilAnd
// for 2 ("outside last"):
//
//   if (SUM) { INV = or ? (INV | FLIP) : (INV & FLIP); }   FLIP = 0; SUM = 0;
//
// FLIP can only be set together with SUM, so clearing both unconditionally is the
// same transform on untouched pixels (which keep their INV) with no extra mux.
// VolumeMode 0 is a plain non-last polygon: accumulate parity, no summarize.
//
// STORAGE: ONE simple-dual-port block RAM, 1024/LANES entries x 3*LANES bits - the
// whole LANES-pixel raster chunk in one word, so the write needs no per-lane byte
// enable and no banking. Every client (raster chunk, CLEAR/zero walk, summarize
// walk, the spanner's 4-wide aligned group) addresses a chunk, and the group the
// spanner asks for is a contiguous slice inside one. Chunk addr = {y[4:0], x[4:BB]}.
//
// The raster path is a READ-MODIFY-WRITE across the same stage A / stage B pair as
// peel_tile_buffer: stage A presents the chunk read, stage B (next cycle) XORs the
// passing lanes' FLIP and writes the chunk back - untouched lanes are carried from
// the read, exactly as peel_tile_buffer carries its unwritten fields. Consecutive
// raster chunks are always different addresses (the sweep steps x by LANES, then
// rows), and back-to-back triangles are separated by the POP+CORNER pair, so the
// read never collides with the previous cycle's write.
//
// Read clients  (at most one/cycle): spanner 4-wide | raster stage A | summarize walk.
// Write clients (at most one/cycle): raster stage B | CLEAR/zero walk | summarize walk.
// peel_core's barriers + the u_taginvw ping-pong credit keep the ISP-side clients
// (raster/clear/summarize, PRODUCER half) disjoint from the spanner read (CONSUMER
// half); the module asserts the exclusion in sim.
//
module stencil_tile_buffer #(
    parameter integer LANES = 8
) (
    input                       clk,
    input                       reset,

    // ---- RASTER stage A: present the chunk read (mirrors peel_tile_buffer) ----
    input                       ras_a_valid,
    input      [4:0]            ras_a_y,
    input      [4:0]            ras_a_x,      // chunk base (LANES-aligned)

    // ---- RASTER stage B: flip FLIP + set SUM on the lanes that passed ----
    // mv_we[l] = peel_tile_buffer's b_mv_we[l] (inside & the forced-GE depth test).
    input                       ras_b_valid,
    input      [LANES-1:0]      mv_we,
    input      [4:0]            b_y,
    input      [4:0]            b_x,

    // ---- CLEAR / ZERO walk: write {0,0,0} to the chunk at clr_addr ----
    // Used by the tile CLEAR (refsw ClearBuffers stencilValue=0) and by the
    // PT/TL peel walks (refsw PeelBuffers/PeelBuffersPTInitial also zero it, so a
    // translucent pass never inherits the opaque pass's shadow mask).
    input                       clr_valid,
    input      [10-$clog2(LANES)-1:0] clr_addr,

    // ---- SUMMARIZE RMW walk (read-ahead cursor / delayed write, like PeelBuffers) ----
    input                       sum_rd_valid,
    input      [10-$clog2(LANES)-1:0] sum_rd_addr,
    input                       sum_wr_valid,
    input      [10-$clog2(LANES)-1:0] sum_wr_addr,
    input                       sum_and,      // 0 = OR (VolumeMode 1), 1 = AND (VolumeMode 2)

    // ---- SPANNER: 4-wide ALIGNED read (group = x & ~3), 1-cyc latency ----
    input                       rd4_valid,
    input      [9:0]            rd4_group,
    output     [3:0]            g4_inv        // per-lane INV bit (lane l = pixel group|l)
);
    localparam integer BANK_BITS = $clog2(LANES);        // 3 for 8, 2 for 4
    localparam integer AW        = 10 - BANK_BITS;       // chunk-address width (7 / 8)
    localparam integer NCH       = 1 << AW;              // chunks per tile
    localparam integer SW        = 3;                    // {SUM, FLIP, INV} per lane
    localparam integer W         = SW * LANES;

    // per-lane field offsets inside the packed chunk word
    localparam integer F_INV  = 0;
    localparam integer F_FLIP = 1;
    localparam integer F_SUM  = 2;

    reg              we;
    reg  [AW-1:0]    waddr;
    reg  [W-1:0]     wdata;
    reg              re;
    reg  [AW-1:0]    raddr;
    wire [W-1:0]     q;
    bram_sdp #(.W(W), .D(NCH)) u_ram (
        .clk(clk), .we(we), .waddr(waddr), .din(wdata),
        .re(re), .raddr(raddr), .q(q));

    // -------------------- READ port mux --------------------
    // Priority mirrors taginvw_tile_buffer: the spanner (consumer half) first, then
    // the ISP-side clients (producer half). They are never simultaneous - see header.
    always @(*) begin
        re    = rd4_valid | ras_a_valid | sum_rd_valid;
        raddr = '0;
        if (rd4_valid)          raddr = {rd4_group[9:5], rd4_group[4:BANK_BITS]};
        else if (ras_a_valid)   raddr = {ras_a_y, ras_a_x[4:BANK_BITS]};
        else if (sum_rd_valid)  raddr = sum_rd_addr;
    end

    // -------------------- WRITE port mux --------------------
    integer cw;
    always @(*) begin
        we    = 1'b0;
        waddr = '0;
        wdata = '0;

        if (clr_valid) begin                       // CLEAR / zero walk
            we    = 1'b1;
            waddr = clr_addr;
            // wdata stays all-zero: INV/FLIP/SUM cleared for every lane.
        end else if (sum_wr_valid) begin           // SummarizeStencilOr / ...And
            we    = 1'b1;
            waddr = sum_wr_addr;
            for (cw = 0; cw < LANES; cw = cw + 1) begin
                wdata[SW*cw + F_INV] =
                    q[SW*cw + F_SUM] ? (sum_and ? (q[SW*cw + F_INV] & q[SW*cw + F_FLIP])
                                                : (q[SW*cw + F_INV] | q[SW*cw + F_FLIP]))
                                     :  q[SW*cw + F_INV];
                wdata[SW*cw + F_FLIP] = 1'b0;      // (FLIP set => SUM set, so this is
                wdata[SW*cw + F_SUM]  = 1'b0;      //  the `&= 0b001` of the reference)
            end
        end else if (ras_b_valid) begin            // modvol accept: flip parity
            we    = 1'b1;
            waddr = {b_y, b_x[4:BANK_BITS]};
            for (cw = 0; cw < LANES; cw = cw + 1) begin
                wdata[SW*cw + F_INV]  =  q[SW*cw + F_INV];        // untouched by a flip
                wdata[SW*cw + F_FLIP] =  q[SW*cw + F_FLIP] ^ mv_we[cw];
                wdata[SW*cw + F_SUM]  =  q[SW*cw + F_SUM]  | mv_we[cw];
            end
        end
    end

    // -------------------- SPANNER 4-wide group output --------------------
    // The aligned group {g..g+3} is a contiguous 4-lane slice of the chunk: the whole
    // chunk when LANES==4, the g[2]-selected half when LANES==8. Latch the half select
    // with the read so it tracks the registered q (same trick as taginvw_tile_buffer).
    localparam integer G4B = (BANK_BITS > 2) ? BANK_BITS - 2 : 1;
    reg [G4B-1:0] g4_half_r;
    always @(posedge clk) begin
        if (reset) g4_half_r <= '0;
        else if (rd4_valid) g4_half_r <= (BANK_BITS > 2) ? rd4_group[2 +: G4B] : '0;
    end
    genvar gl;
    generate
      for (gl = 0; gl < 4; gl = gl + 1) begin : g4lane
        assign g4_inv[gl] = q[SW*(4*g4_half_r + gl) + F_INV];
      end
    endgenerate

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
        if ((clr_valid + sum_wr_valid + ras_b_valid) > 1)
            $error("stencil_tile_buffer: multiple WRITE clients (%b%b%b)",
                   clr_valid, sum_wr_valid, ras_b_valid);
        if ((rd4_valid + ras_a_valid + sum_rd_valid) > 1)
            $error("stencil_tile_buffer: multiple READ clients (%b%b%b)",
                   rd4_valid, ras_a_valid, sum_rd_valid);
    end
`endif
endmodule
