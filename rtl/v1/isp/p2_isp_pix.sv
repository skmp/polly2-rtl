// p2_isp_pix: the ISP's fragment rules, 32 lanes, one tile row a clock (PLAN M6, M7; ARCHITECTURE 3.4.6, 3.4.7
// "modifier volume summary"; isp 10.2, 10.3, 11.1, 11.2, 11.4, 11.5, 11.6; refcore refsw_tile.cpp PixelFlush_isp,
// KeyAbove, SummarizeStencilOr / And, refsw_lists.cpp RenderTriangle at refsw3 4f3efe15).
//
// Per lane with in_mask[i] (the raster's row: zk[i] the stored depth key, p2_zkey_t; depthA, tagA, stencil, valid from
// p2_isp_buf):
//   OPAQUE, TR_PRESORT  DepthMode (ISP word 31:29) compares zk against depthA as signed 64-bit keys (StoredDepth's
//                       order): 0 never, 1 zk < depthA, 2 ==, 3 <=, 4 >, 5 !=, 6 >=, 7 always; on a pass depthA = zk
//                       unless ZWriteDis, tagA = tag, valid = 1 [dreamcast-tests pvr-tests/depth, ztile, zsign]
//   MODIFIER            mode 4 whatever the word says (it holds VolumeMode): zk > depthA flips stencil bit 1 (the parity)
//                       and sets bit 2 [pvr-tests/modvol, volrun]
//   PT_PASS0 / N        no DepthMode (mode 7): rendered && !rlp (resolved before the pass before) rejects;
//                       !KeyAbove(zk, tag, depthC, refTagC) rejects (in front of the opaque layer, or what an earlier chunk
//                       resolved: pvr-tests/trtie); tagB != TAG_BELOW && !KeyAbove(depthB, tagB, zk, tag) rejects (below
//                       the boundary); valid && !KeyAbove(zk, tag, depthA, tagA) rejects (the nearest such); else
//                       more = 1, depthA = zk (ZWriteDis or not), tagA = tag, valid = 1 [ptlayers, ptruns, dumprules]
//   TR_AUTOSORT         no DepthMode: valid && KeyAbove(zk, tag, depthA, tagA) gives more and rejects (a nearer one
//                       waits); !KeyAbove(zk, tag, depthB, tagB) rejects (not above the layer drawn last); valid gives more
//                       (a best displaced); then depthA = zk, tagA = tag, valid = 1 [sort, trtie, trsort_*]
// KeyAbove(aK, aT, bK, bT): aK != bK ? aK > bK (signed keys) : bT == TAG_BELOW ? aT != TAG_BELOW : aT != TAG_BELOW &&
// aT[23:0] > bT[23:0] (PARAMETER_TAG_SORT_MASK). `more` (refsw3's MoreToDraw) is the OR over the lanes and rows of a walk,
// to p2_isp_ctl; ctl clears it (more_clr) before the walk.
// The summary (a closing triangle's VolumeMode 1 = OR, "inside last"; 2 = AND, "outside last"; 3 .. 7 none, isp 15 #16):
// refsw3 summarizes the whole tile after the closing triangle, rasterized or culled; here the closer's descriptor steps
// all 32 rows (a culled or bad one as a `kill` descriptor with no pixel inside, p2_isp_setup) and in each row's write,
// after the row's own parity updates, every pixel of the row with stencil bit 2 gets {2'b00, s0 | s1} (OR) or
// {2'b00, s0 & s1} (AND). The closer's row j write is the volume's last write to row j and the summary acts on each pixel
// alone, so this is SummarizeStencil* after the triangle [I; a rasterized closer pays no clock for it: 65 = 2 x 32 + 1].
//
// Pipeline [I, ARCHITECTURE 3.4.6]: R0 the raster's row register (this unit issues the buffer's F read with its row);
// R1 the read data, the lane decisions and the rules; R2 the row write. Two rows of different primitives may be the same
// row one clock apart (a primitive's last row, the next one's first: scenegen ROWS), so R1's read is bypassed per lane:
// from R2's write data (written at the end of this clock) and from R3, the write of the clock before (the F read was
// sampled at the edge that wrote it). The flip-flop fields are read in R1, so the write of the clock before is in them;
// only a row one clock apart would need a bypass from R2. valid has it (M7's punch-through rows write and read it);
// the stencil has none: only MODIFIER rows write it, and a MODIFIER triangle (a kill descriptor too) steps all 32 rows
// (p2_isp_rowclip), so two of its rows of one row number are at least 32 clocks apart, never one (tb/isp_tile asserts it on
// every input: "MODIFIER row one clock after one of the same row"). With the bypass nothing stalls [M "depth processing never shows in the time"]; rows of one primitive in order and primitives in list
// order through one pipeline keep the per-pixel fragment order (isp 1 item 1). The fields the punch-through and sort rules
// read besides (depthB, tagB, depthC, refTagC: RAMs read with the F read; rendered, rlp: flip-flops) are not written by
// the raster, so they need no bypass.
//
// The row barrier (ARCHITECTURE 3.4.7): a row enters R0's read only when bar_ok says the cutter has passed it (the
// SHADE before this walk read it); otherwise the raster holds it (out_rdy = 0).
module p2_isp_pix
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  // the raster's rows (R0)
  input  logic                              row_v,
  output logic                              out_rdy,
  input  logic [P2_TILE_LOG2-1:0]           row_j,
  input  logic [P2_TILE-1:0]                in_mask,
  input  p2_zkey_t [P2_TILE-1:0]            zk,
  input  p2_tag_t                           row_tag,
  input  p2_rm_t                            row_rm,
  input  logic [2:0]                        row_depth_mode,
  input  logic                              row_zwdis,
  input  p2_sum_op_t                        row_sum_op,
  // the row barrier
  input  logic [P2_TILE-1:0]                bar_ok,
  // MoreToDraw
  input  logic                              more_clr,
  output logic                              more,
  // p2_isp_buf: F read (issued in R0, data in R1), N read (R1), the write port (R2)
  output logic                              f_re,
  output logic [P2_TILE_LOG2-1:0]           f_row,
  input  p2_zkey_t [P2_TILE-1:0]            f_depth,
  input  logic [P2_TILE-1:0][31:0]          f_tag,
  input  p2_zkey_t [P2_TILE-1:0]            f_depth_b,
  input  logic [P2_TILE-1:0][31:0]          f_tag_b,
  input  p2_zkey_t [P2_TILE-1:0]            f_depth_c,
  input  logic [P2_TILE-1:0][31:0]          f_reftag_c,
  output logic [P2_TILE_LOG2-1:0]           n_row,
  input  logic [P2_TILE-1:0][2:0]           n_stencil,
  input  logic [P2_TILE-1:0]                n_valid,
  input  logic [P2_TILE-1:0]                n_rendered,
  input  logic [P2_TILE-1:0]                n_rlp,
  output logic                              w_v,
  output logic [P2_TILE_LOG2-1:0]           w_row,
  output logic [P2_TILE-1:0]                w_dwe,
  output logic [P2_TILE-1:0]                w_twe,
  output p2_zkey_t [P2_TILE-1:0]            w_depth,
  output logic [P2_TILE-1:0][31:0]          w_tag,
  output logic                              w_swe,
  output logic [P2_TILE-1:0][2:0]           w_stencil,
  output logic [P2_TILE-1:0]                w_vwe,
  output logic [P2_TILE-1:0]                w_valid,
  output logic                              idle
);
  // nothing here stalls; a row waits for the barrier only
  assign out_rdy = bar_ok[row_j];
  assign f_re    = row_v && out_rdy;
  assign f_row   = row_j;

  // ---------------------------------------------------------------------------------------------- R1
  logic                    r1_v;
  logic [P2_TILE_LOG2-1:0] r1_j;
  logic [P2_TILE-1:0]      r1_m;
  p2_zkey_t [P2_TILE-1:0]  r1_zk;
  logic [31:0]             r1_tag;
  p2_rm_t                  r1_rm;
  logic [2:0]              r1_dm;
  logic                    r1_zw;
  p2_sum_op_t              r1_sum;
  always_ff @(posedge clk) begin
    if (rst)
      r1_v <= 1'b0;
    else
      r1_v <= row_v && out_rdy;
    r1_j   <= row_j;
    r1_m   <= in_mask;
    r1_zk  <= zk;
    r1_tag <= row_tag;
    r1_rm  <= row_rm;
    r1_dm  <= row_depth_mode;
    r1_zw  <= row_zwdis;
    r1_sum <= row_sum_op;
  end
  assign n_row = r1_j;

  // R2 (the write this clock) and R3 (the write of the clock before), for the bypass
  logic                    r2_v, r3_v;
  logic [P2_TILE_LOG2-1:0] r2_j, r3_j;
  logic [P2_TILE-1:0]      r2_dwe, r2_twe, r2_vwe, r3_dwe, r3_twe;
  logic                    r2_swe;
  p2_zkey_t [P2_TILE-1:0]  r2_d, r3_d;
  logic [P2_TILE-1:0][31:0] r2_t, r3_t;
  logic [P2_TILE-1:0][2:0] r2_s;
  logic [P2_TILE-1:0]      r2_vl;

  // the row's state as R1 sees it: the buffer's, with the writes not yet visible in it
  p2_zkey_t [P2_TILE-1:0]   dA;
  logic [P2_TILE-1:0][31:0] tA;
  logic [P2_TILE-1:0][2:0]  st;
  logic [P2_TILE-1:0]       vl;
  p2_zkey_t [P2_TILE-1:0]   dB, dC;
  logic [P2_TILE-1:0][31:0] tB, rtC;
  logic [P2_TILE-1:0]       rendered1, rlp1;
  assign dB        = f_depth_b;
  assign tB        = f_tag_b;
  assign dC        = f_depth_c;
  assign rtC       = f_reftag_c;
  assign rendered1 = n_rendered;
  assign rlp1      = n_rlp;
  logic                     by2, by3;
  assign by2 = r2_v && r2_j == r1_j;
  assign by3 = r3_v && r3_j == r1_j;
  always_comb begin
    for (int i = 0; i < P2_TILE; i++) begin
      dA[i] = f_depth[i];
      tA[i] = f_tag[i];
      if (by3 && r3_dwe[i]) dA[i] = r3_d[i];
      if (by3 && r3_twe[i]) tA[i] = r3_t[i];
      if (by2 && r2_dwe[i]) dA[i] = r2_d[i];
      if (by2 && r2_twe[i]) tA[i] = r2_t[i];
      st[i] = n_stencil[i];
      vl[i] = (by2 && r2_vwe[i]) ? r2_vl[i] : n_valid[i];
    end
  end

  // ---------------------------------------------------------------------------------------------- the rules
  localparam logic [31:0] BELOW = P2_TAG_BELOW;
  // refsw_tile.cpp KeyAbove: a larger key is nearer, or as near and later in the list
  function automatic logic key_above(input p2_zkey_t ak, input logic [31:0] at, input p2_zkey_t bk,
                                     input logic [31:0] bt);
    if (ak != bk)
      return $signed(ak) > $signed(bk);
    if (bt == BELOW)
      return at != BELOW;
    return at != BELOW && at[23:0] > bt[23:0];
  endfunction

  // a MODIFIER fragment's parity flip (PixelFlush_isp RM_MODIFIER: *stencil ^= 0b010; *stencil |= 0b100)
  function automatic logic [2:0] f_parity(input logic [2:0] s, input logic hit);
    return hit ? {1'b1, !s[1], s[0]} : s;
  endfunction
  // the summary of a pixel touched by the volume (SummarizeStencilOr / And: stencil & 0b100 -> the status bit only)
  function automatic logic [2:0] f_sum(input logic [2:0] s, input p2_sum_op_t op);
    if (op == P2_SUM_NONE || !s[2])
      return s;
    return {2'b00, (op == P2_SUM_OR) ? (s[0] | s[1]) : (s[0] & s[1])};
  endfunction

  logic [P2_TILE-1:0]       n_dwe, n_twe, n_vwe, hit, n_more, pt_rej;
  logic [P2_TILE-1:0][2:0]  n_st;
  logic                     n_swe;
  always_comb begin
    n_dwe  = '0;
    n_twe  = '0;
    n_vwe  = '0;
    hit    = '0;
    n_more = '0;
    for (int i = 0; i < P2_TILE; i++) begin
      logic pass;
      // PixelFlush_isp's DepthMode compare: StoredDepth keys, signed
      unique case (r1_dm)
        3'd0:    pass = 1'b0;
        3'd1:    pass = $signed(r1_zk[i]) <  $signed(dA[i]);
        3'd2:    pass = r1_zk[i] == dA[i];
        3'd3:    pass = $signed(r1_zk[i]) <= $signed(dA[i]);
        3'd4:    pass = $signed(r1_zk[i]) >  $signed(dA[i]);
        3'd5:    pass = r1_zk[i] != dA[i];
        3'd6:    pass = $signed(r1_zk[i]) >= $signed(dA[i]);
        default: pass = 1'b1;
      endcase
      if (r1_rm == P2_RM_OPAQUE || r1_rm == P2_RM_TRANSLUCENT_PRESORT) begin
        if (r1_m[i] && pass) begin
          n_dwe[i] = !r1_zw;
          n_twe[i] = 1'b1;
          n_vwe[i] = 1'b1;
        end
      end
      // the punch-through passes: the nearest key below the boundary, in front of the opaque layer
      pt_rej[i] = (rendered1[i] && !rlp1[i]) ||
                  !key_above(r1_zk[i], r1_tag, dC[i], rtC[i]) ||
                  (tB[i] != BELOW && !key_above(dB[i], tB[i], r1_zk[i], r1_tag)) ||
                  (vl[i] && !key_above(r1_zk[i], r1_tag, dA[i], tA[i]));
      if (r1_rm == P2_RM_PUNCHTHROUGH_PASS0 || r1_rm == P2_RM_PUNCHTHROUGH_PASSN) begin
        if (r1_m[i] && !pt_rej[i]) begin
          n_more[i] = 1'b1;
          n_dwe[i]  = 1'b1;
          n_twe[i]  = 1'b1;
          n_vwe[i]  = 1'b1;
        end
      end
      // the translucent sort: the farthest key above the layer drawn last
      if (r1_rm == P2_RM_TRANSLUCENT_AUTOSORT && r1_m[i]) begin
        if (vl[i] && key_above(r1_zk[i], r1_tag, dA[i], tA[i]))
          n_more[i] = 1'b1;
        else if (key_above(r1_zk[i], r1_tag, dB[i], tB[i])) begin
          n_more[i] = vl[i];
          n_dwe[i]  = 1'b1;
          n_twe[i]  = 1'b1;
          n_vwe[i]  = 1'b1;
        end
      end
      // MODIFIER: mode 4, strictly greater, whatever the ISP word's top bits (VolumeMode)
      hit[i] = r1_rm == P2_RM_MODIFIER && r1_m[i] && $signed(r1_zk[i]) > $signed(dA[i]);
    end
    // the row's parity updates, then the summary (a closer's row: after its own fragments)
    n_swe = r1_rm == P2_RM_MODIFIER;
    for (int i = 0; i < P2_TILE; i++)
      n_st[i] = f_sum(f_parity(st[i], hit[i]), r1_sum);
  end

  // ---------------------------------------------------------------------------------------------- R2, R3
  always_ff @(posedge clk) begin
    if (rst) begin
      r2_v <= 1'b0;
      r3_v <= 1'b0;
    end else begin
      r2_v <= r1_v;
      r3_v <= r2_v;
    end
    r2_j   <= r1_j;
    r2_dwe <= r1_v ? n_dwe : '0;
    r2_twe <= r1_v ? n_twe : '0;
    r2_vwe <= r1_v ? n_vwe : '0;
    r2_swe <= r1_v && n_swe;
    for (int i = 0; i < P2_TILE; i++) begin
      r2_d[i]  <= r1_zk[i];
      r2_t[i]  <= r1_tag;
    end
    r2_s   <= n_st;
    r2_vl  <= '1;
    r3_j   <= r2_j;
    r3_dwe <= r2_dwe;
    r3_twe <= r2_twe;
    r3_d   <= r2_d;
    r3_t   <= r2_t;
  end

  assign w_v       = r2_v;
  assign w_row     = r2_j;
  assign w_dwe     = r2_dwe;
  assign w_twe     = r2_twe;
  assign w_depth   = r2_d;
  assign w_tag     = r2_t;
  assign w_swe     = r2_swe;
  assign w_stencil = r2_s;
  assign w_vwe     = r2_vwe;
  assign w_valid   = r2_vl;

  // MoreToDraw: set by any lane of any row of the walk
  always_ff @(posedge clk) begin
    if (rst || more_clr)
      more <= 1'b0;
    else if (r1_v && n_more != '0)
      more <= 1'b1;
  end

  assign idle = !row_v && !r1_v && !r2_v;
endmodule
