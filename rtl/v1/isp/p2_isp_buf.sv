// p2_isp_buf: the ISP's per-pixel state of one tile (PLAN M6; ARCHITECTURE 3.4.7; isp 10.1, 13, 4.2; refcore
// refsw_tile.cpp depthBuffer / tagBuffer / stencilBuffer / tagStatus, ClearBuffers, ClearParamStatusBuffer at refsw3
// 4f3efe15). 32 rows x 32 lanes, read and written a row at a time.
//
// M6 holds the fields the opaque and modifier volume phases use; the punch-through and translucent fields (depthB,
// tagB, depthC, refTagC, opTag, resTag, resDepth / savedDepth, rendered, rcur, rlp, everRendered) and their sweeps are
// M7's (ARCHITECTURE 3.4.7's table):
//   depthA   64 (p2_zkey_t)  RAM, one per lane (conventions 4.2: one array per write lane), 2 read copies: F (raster R1,
//                            sweeps) and C (the cutter, M7); both written together
//   tagA     32              RAM, as depthA. All 32 bits: ClearBuffers(ISP_BACKGND_T.full) keeps a background tag's
//                            bits 31:29 (dreamcast-tests pvr-tests/bgtie, scenegen BGTAG), and 0xFFFFFFFF IS
//                            TAG_BELOW (KeyAbove), not a flag
//   stencil  3               flip-flops: bit 0 the volume status, 1 the parity, 2 "touched by this volume" (refsw3's
//                            stencilBuffer bits; SummarizeStencilOr / And)
//   valid    1               flip-flops (tagStatus.valid)
//
// Ports:
//   F read    f_re / f_row: the row's depthA and tagA the next clock (a registered RAM read; the raster's R1)
//   N read    n_row: the row's stencil and valid, combinationally (flip-flops)
//   C read    c_re / c_row: the copy's row the next clock (M7's cutter; unused in M6)
//   write     one port: the raster's R2 (per-lane enables for depth, tag, valid; the stencil a whole row), or the sweep
//             engine. ctl issues raster work and sweeps one after the other, so they never write in one clock (checked)
//   sweeps    one row a clock over the 32 rows [G; GAP T13: "Z clear + background setup 142"]: CLEAR (depthA = key,
//             tagA = tag, stencil = 0, valid = 1: ClearBuffers sets tagStatus {true, false}), CLRSTATUS (valid = 0)
//   debug     sim only: a row of every field, combinationally (the tile testbench's compare), and a row write (its
//             resync after the phases M6 does not have)
module p2_isp_buf
  import p2_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // F read
  input  logic                              f_re,
  input  logic [P2_TILE_LOG2-1:0]           f_row,
  output p2_zkey_t [P2_TILE-1:0]            f_depth,
  output logic [P2_TILE-1:0][31:0]          f_tag,
  // N read
  input  logic [P2_TILE_LOG2-1:0]           n_row,
  output logic [P2_TILE-1:0][2:0]           n_stencil,
  output logic [P2_TILE-1:0]                n_valid,
  // C read (M7)
  input  logic                              c_re,
  input  logic [P2_TILE_LOG2-1:0]           c_row,
  output p2_zkey_t [P2_TILE-1:0]            c_depth,
  output logic [P2_TILE-1:0][31:0]          c_tag,
  // the write port (raster R2)
  input  logic                              w_v,
  input  logic [P2_TILE_LOG2-1:0]           w_row,
  input  logic [P2_TILE-1:0]                w_dwe,
  input  logic [P2_TILE-1:0]                w_twe,
  input  p2_zkey_t [P2_TILE-1:0]            w_depth,
  input  logic [P2_TILE-1:0][31:0]          w_tag,
  input  logic                              w_swe,
  input  logic [P2_TILE-1:0][2:0]           w_stencil,
  input  logic [P2_TILE-1:0]                w_vwe,
  input  logic [P2_TILE-1:0]                w_valid,
  // sweeps (p2_isp_ctl)
  input  logic                              sw_v,
  input  p2_sweep_t                         sw_op,
  input  p2_zkey_t                          sw_key,
  input  logic [31:0]                       sw_tag,
  output logic                              sw_busy,
  // debug (sim)
  input  logic [P2_TILE_LOG2-1:0]           dbg_row,
  output p2_zkey_t [P2_TILE-1:0]            dbg_depth,
  output logic [P2_TILE-1:0][31:0]          dbg_tag,
  output logic [P2_TILE-1:0][2:0]           dbg_stencil,
  output logic [P2_TILE-1:0]                dbg_valid,
  input  logic                              dbg_we,
  input  p2_zkey_t [P2_TILE-1:0]            dbg_wdepth,
  input  logic [P2_TILE-1:0][31:0]          dbg_wtag,
  input  logic [P2_TILE-1:0][2:0]           dbg_wstencil,
  input  logic [P2_TILE-1:0]                dbg_wvalid
);
  localparam int TAG_BITS = 32;     // ISP_BACKGND_T.full (refsw_tile.cpp ClearBuffers)

  // ---------------------------------------------------------------------------------------------- the sweep engine
  logic                    sw_act;
  p2_sweep_t               sw_q;
  logic [P2_TILE_LOG2-1:0] sw_row;
  p2_zkey_t                sw_k;
  logic [31:0]             sw_t;
  assign sw_busy = sw_act;
  always_ff @(posedge clk) begin
    if (rst) begin
      sw_act <= 1'b0;
    end else if (sw_act) begin
      sw_row <= sw_row + 1'b1;
      if (sw_row == '1)
        sw_act <= 1'b0;
    end else if (sw_v) begin
      sw_act <= 1'b1;
      sw_q   <= sw_op;
      sw_row <= '0;
      sw_k   <= sw_key;
      sw_t   <= sw_tag;
    end
  end

  // ---------------------------------------------------------------------------------------------- the write mux
  logic                              ww;
  logic [P2_TILE_LOG2-1:0]           wrow;
  logic [P2_TILE-1:0]                wdwe, wtwe, wvwe;
  logic                              wswe;
  p2_zkey_t [P2_TILE-1:0]            wd;
  logic [P2_TILE-1:0][31:0]          wt;
  logic [P2_TILE-1:0][2:0]           wst;
  logic [P2_TILE-1:0]                wvl;
  always_comb begin
    ww   = w_v;
    wrow = w_row;
    wdwe = w_dwe;
    wtwe = w_twe;
    wvwe = w_vwe;
    wswe = w_swe;
    wd   = w_depth;
    wt   = w_tag;
    wst  = w_stencil;
    wvl  = w_valid;
    if (sw_act) begin
      ww   = 1'b1;
      wrow = sw_row;
      wswe = 1'b0;
      wdwe = '0;
      wtwe = '0;
      wvwe = '1;
      wvl  = '0;
      if (sw_q == P2_SW_CLEAR) begin
        wdwe = '1;
        wtwe = '1;
        wswe = 1'b1;
        wst  = '0;
        wvl  = '1;
        for (int i = 0; i < P2_TILE; i++) begin
          wd[i] = sw_k;
          wt[i] = sw_t;
        end
      end
    end
`ifndef SYNTHESIS
    if (dbg_we) begin
      ww   = 1'b1;
      wrow = dbg_row;
      wdwe = '1;
      wtwe = '1;
      wvwe = '1;
      wswe = 1'b1;
      wd   = dbg_wdepth;
      wt   = dbg_wtag;
      wst  = dbg_wstencil;
      wvl  = dbg_wvalid;
    end
`endif
  end

  // ---------------------------------------------------------------------------------------------- depthA, tagA (RAMs)
  genvar g;
  generate
    for (g = 0; g < P2_TILE; g = g + 1) begin : g_lane
      p2_zkey_t            dmf [P2_TILE];     // the F copy
      p2_zkey_t            dmc [P2_TILE];     // the C copy
      logic [TAG_BITS-1:0] tmf [P2_TILE];
      logic [TAG_BITS-1:0] tmc [P2_TILE];
      always_ff @(posedge clk) begin
        if (ww && wdwe[g]) begin
          dmf[wrow] <= wd[g];
          dmc[wrow] <= wd[g];
        end
        if (ww && wtwe[g]) begin
          tmf[wrow] <= TAG_BITS'(wt[g]);
          tmc[wrow] <= TAG_BITS'(wt[g]);
        end
        if (f_re) begin
          f_depth[g] <= dmf[f_row];
          f_tag[g]   <= 32'(tmf[f_row]);
        end
        if (c_re) begin
          c_depth[g] <= dmc[c_row];
          c_tag[g]   <= 32'(tmc[c_row]);
        end
      end
`ifndef SYNTHESIS
      assign dbg_depth[g] = dmf[dbg_row];
      assign dbg_tag[g]   = 32'(tmf[dbg_row]);
`else
      assign dbg_depth[g] = '0;
      assign dbg_tag[g]   = '0;
`endif
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- stencil, valid (flops)
  logic [P2_TILE-1:0][P2_TILE-1:0][2:0] st;     // [row][lane]
  logic [P2_TILE-1:0][P2_TILE-1:0]      vl;
  always_ff @(posedge clk) begin
    if (ww) begin
      if (wswe)
        st[wrow] <= wst;
      for (int i = 0; i < P2_TILE; i++)
        if (wvwe[i])
          vl[wrow][i] <= wvl[i];
    end
  end
  assign n_stencil   = st[n_row];
  assign n_valid     = vl[n_row];
  assign dbg_stencil = st[dbg_row];
  assign dbg_valid   = vl[dbg_row];

`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && sw_act && w_v)
      $error("p2_isp_buf: a raster write during a sweep (ctl issues them one after the other)");
`endif
endmodule
