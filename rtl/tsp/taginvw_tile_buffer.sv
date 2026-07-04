//
// taginvw_tile_buffer - the ISP->TSP handoff buffer: the TSP-facing SLICE of the
// peel depth/tag buffer, split out so it can be PING-PONGED independently of the
// ISP-private u_peel scratch (depth/depth2/tag2 + compare + PeelBuffers RMW).
//
// It holds only the three fields TSP shade actually reads - {valid, tag, invW} -
// and is WRITTEN as a DUPLICATE of peel_tile_buffer's stage-B accept (same write
// data, same enable) plus the CLEAR walk. It has NO depth compare, no depth2/tag2,
// and no PeelBuffers walk: those stay ISP-private in u_peel. Because ISP already
// decided which lanes pass (peel_tile_buffer computes b_pass_lp / ras_pass_op),
// this module is told directly which lanes to write and what to write - it is a
// pure banked store, not a compare.
//
// Storage: ONE simple-dual-port tile_ram, WIDTH = 65 bits/lane {valid, tag[31:0],
// invW[31:0]}, NBANKS = LANES. Same banking as peel_tile_buffer: bank = x[BW-1:0],
// addr = {y[4:0], x[4:BW]}. One read port (shade single-pixel) + one write port
// (raster stage-B duplicate | CLEAR).
//
// Read clients  (at most one/cycle): shade single-pixel read.
// Write clients (at most one/cycle): raster stage-B duplicate | CLEAR.
// The peel_core credit handshake serializes producers/consumers per ping-pong
// half, so at most one read and one write client is asserted per cycle; the module
// asserts this (sim).
//
module taginvw_tile_buffer import tsp_pkg::*; #(
    parameter integer LANES = 8
) (
    input                       clk,
    input                       reset,

    // ---- RASTER stage-B duplicate: write {valid,tag,invW} for the passing lanes ----
    // wr_we[l] is peel_tile_buffer's per-lane accept for lane l (already masked by
    // inside/pass), wr_y/wr_x the chunk (LANES-aligned), wr_invw the per-lane invW.
    input                       wr_valid,       // any lane may write this cycle
    input      [LANES-1:0]      wr_we,          // per-lane write-enable (accept)
    input      [4:0]            wr_y,
    input      [4:0]            wr_x,           // chunk base (LANES-aligned)
    input      [31:0]           wr_tag,         // fragment CoreTag (same for all lanes)
    input      [32*LANES-1:0]   wr_invw,        // per-lane invW (flat)
    input                       wr_pt,          // PT-list won (b_which==0): the blend's
                                                // PT alpha-test enable, captured HERE at
                                                // raster stage-B (dt_pt is stale by the
                                                // time the decoupled reader blends).

    // ---- CLEAR: write {valid=1, tag=bg, invW=bg_depth} to all banks at clr_addr ----
    // (refsw ClearBuffers sets tagStatus.valid=true so the OP shade fills col_buf
    //  with the background color.)
    input                       clr_valid,
    input      [10-$clog2(LANES)-1:0] clr_addr,
    input      [31:0]           clr_depth,      // background invW/depth
    input      [31:0]           clr_tag,        // background CoreTag

    // ---- PEELBUFFERS valid-clear walk: mirror u_peel's per-pass reset of the staged
    // bit. u_peel's PeelBuffers RMW sets valid<-0 across the whole tile between peel
    // passes; since shade now reads THIS buffer, it must be cleared the same way (else
    // pass P+1 re-shades pass P's staged pixels). We only clear valid (tag/invW are
    // overwritten by the next pass's raster accepts before they're read). ----
    input                       pbc_valid,
    input      [10-$clog2(LANES)-1:0] pbc_addr,

    // ---- SHADE: single-pixel read (id = {y[4:0], x[4:0]}) ----
    input                       sh_rd_valid,
    input      [9:0]            sh_rd_id,
    output reg                  sh_valid,       // staged-this-pass bit  (1-cyc latency)
    output reg [31:0]           sh_tag,         // pending tag           (1-cyc latency)
    output reg [31:0]           sh_depth,       // depthBufferA (invW)   (1-cyc latency)
    output reg                  sh_pt,          // PT-list-won bit       (1-cyc latency)

    // ---- SPANNER: 4-wide ALIGNED read (group = x & ~3). REQUIRES LANES==4: the 4 aligned
    // pixels {g..g+3} then map exactly to banks 0..3, so one read of all banks at
    // addr {g[9:5], g[4:2]} returns the whole group. Lane l = pixel (g|l). 1-cyc latency.
    input                       rd4_valid,
    input      [9:0]            rd4_group,
    output     [3:0]            g4_valid,
    output     [31:0]           g4_tag  [0:3],
    output     [31:0]           g4_invw [0:3],
    output     [3:0]            g4_pt
);
    localparam integer NB        = LANES;
    localparam integer BANK_BITS = $clog2(LANES);   // 3 for 8, 2 for 4
    localparam integer AW        = 10 - BANK_BITS;   // per-bank addr width (7 / 8)
    localparam integer TW_INVW   = 0;    // [31:0] depthBufferA (invW)
    localparam integer TW_TAG    = 32;   // [31:0] tagBufferA
    localparam integer TW_VALID  = 64;   // [0]    tagStatus.valid
    localparam integer TW_PT     = 65;   // [0]    PT-list-won (blend alpha-test enable)
    localparam integer TI_W      = 66;

    reg  [NB-1:0]        we;
    reg  [AW*NB-1:0]     waddr;
    reg  [AW*NB-1:0]     raddr;
    reg  [TI_W*NB-1:0]   wdata;
    wire [TI_W*NB-1:0]   rdata;
    tile_ram #(.WIDTH(TI_W), .NBANKS(NB)) u_ram (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata)
    );

    // pack an AW-bit bank address {y[4:0], x[4:BANK_BITS]} onto all NB banks
    function automatic [AW*NB-1:0] pack_addr(input [4:0] y, input [4:0] xchunk);
        integer b;
        begin
            pack_addr = '0;
            for (b = 0; b < NB; b = b + 1)
                pack_addr[AW*b +: AW] = {y, xchunk[4:BANK_BITS]};
        end
    endfunction

    // -------------------- READ port (single-pixel OR 4-wide aligned group) --------------
    always @(*) begin
        raddr = '0;
        if (rd4_valid)        raddr = {NB{ {rd4_group[9:5], rd4_group[4:BANK_BITS]} }};
        else if (sh_rd_valid) raddr = {NB{ {sh_rd_id[9:5],  sh_rd_id[4:BANK_BITS]}  }};
    end

    // 4-wide group outputs: with LANES==4, banks 0..3 ARE lanes 0..3 of the aligned group
    // (combinational off the registered read rdata, 1-cyc after rd4_group presented).
    genvar gl;
    generate
      for (gl = 0; gl < 4; gl = gl + 1) begin : g4lane
        assign g4_valid[gl] = rdata[TI_W*gl + TW_VALID];
        assign g4_pt   [gl] = rdata[TI_W*gl + TW_PT];
        assign g4_tag  [gl] = rdata[TI_W*gl + TW_TAG  +: 32];
        assign g4_invw [gl] = rdata[TI_W*gl + TW_INVW +: 32];
      end
    endgenerate

    // -------------------- WRITE port mux --------------------
    integer cw;
    always @(*) begin
        we    = '0;
        waddr = '0;
        wdata = '0;

        if (clr_valid) begin                       // CLEAR: {valid=0,tag,invW} all banks
            we    = {NB{1'b1}};
            waddr = {NB{clr_addr}};
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[TI_W*cw + TW_INVW +: 32] = clr_depth;
                wdata[TI_W*cw + TW_TAG  +: 32] = clr_tag;
                // valid<-0, MATCHING the old u_peel CLEAR (it left PW_VALID at the
                // wdata='0 default). OP shade ignores valid (shades every pixel); the
                // PEEL passes gate on valid, so a CLEAR-set valid=1 would make peel
                // passes shade background pixels the reference skips (extra shading +
                // plane-cache misses). Keep it 0.
                wdata[TI_W*cw + TW_VALID]      = 1'b0;
            end
        end else if (pbc_valid) begin              // PeelBuffers valid-clear walk
            // Blind-write valid=0 (tag/invW become 0 but are never read while valid=0;
            // the next peel pass's raster accept overwrites all three before any read).
            we    = {NB{1'b1}};
            waddr = {NB{pbc_addr}};
            // wdata already all-zero from the reset above -> valid=0, tag=0, invW=0.
        end else if (wr_valid) begin               // stage-B accept duplicate
            waddr = pack_addr(wr_y, wr_x);
            for (cw = 0; cw < NB; cw = cw + 1) begin
                we[cw] = wr_we[cw];
                wdata[TI_W*cw + TW_INVW +: 32] = wr_invw[32*cw +: 32];
                wdata[TI_W*cw + TW_TAG  +: 32] = wr_tag;
                wdata[TI_W*cw + TW_VALID]      = 1'b1;
                wdata[TI_W*cw + TW_PT]         = wr_pt;   // PT-list-won (same for all lanes)
            end
        end
    end

    // -------------------- SHADE single-pixel read output --------------------
    // 1-cycle latency: sh_rd_valid presented this cycle -> fields next cycle.
    reg [BANK_BITS-1:0] sh_lane_r;
    always @(posedge clk) begin
        if (reset) sh_lane_r <= '0;
        else if (sh_rd_valid) sh_lane_r <= sh_rd_id[BANK_BITS-1:0];
    end
    always @(*) begin
        sh_valid = rdata[TI_W*sh_lane_r + TW_VALID];
        sh_tag   = rdata[TI_W*sh_lane_r + TW_TAG  +: 32];
        sh_depth = rdata[TI_W*sh_lane_r + TW_INVW +: 32];
        sh_pt    = rdata[TI_W*sh_lane_r + TW_PT];
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
        if ((clr_valid + wr_valid + pbc_valid) > 1)
            $error("taginvw_tile_buffer: multiple WRITE clients (%b%b%b)",
                   clr_valid, wr_valid, pbc_valid);
    end
`endif
endmodule
