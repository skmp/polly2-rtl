// p2_isp_pix: the ISP's fragment rules, 32 lanes, one tile row a clock (PLAN M6; ARCHITECTURE 3.4.6, 3.4.7 "modifier
// volume summary"; isp 10.2, 10.3, 11.1, 11.2; refcore refsw_tile.cpp PixelFlush_isp, SummarizeStencilOr / And,
// refsw_lists.cpp RenderTriangle at refsw3 4f3efe15). M6 has the OPAQUE / TR_PRESORT rule and the MODIFIER rule with
// its folded summary; the punch-through and autosort rules (KeyAbove) are M7's.
//
// Per lane with in_mask[i] (the raster's row: zk[i] the stored depth key, p2_zkey_t; depthA, tagA, stencil, valid from
// p2_isp_buf):
//   OPAQUE, TR_PRESORT  DepthMode (ISP word 31:29) compares zk against depthA as signed 64-bit keys (StoredDepth's
//                       order): 0 never, 1 zk < depthA, 2 ==, 3 <=, 4 >, 5 !=, 6 >=, 7 always; on a pass depthA = zk
//                       unless ZWriteDis, tagA = tag, valid = 1 [dreamcast-tests pvr-tests/depth, ztile, zsign]
//   MODIFIER            mode 4 whatever the word says (it holds VolumeMode): zk > depthA flips stencil bit 1 (the parity)
//                       and sets bit 2 [pvr-tests/modvol, volrun]
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
// order through one pipeline keep the per-pixel fragment order (isp 1 item 1).
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
  // p2_isp_buf: F read (issued in R0, data in R1), N read (R1), the write port (R2)
  output logic                              f_re,
  output logic [P2_TILE_LOG2-1:0]           f_row,
  input  p2_zkey_t [P2_TILE-1:0]            f_depth,
  input  logic [P2_TILE-1:0][31:0]          f_tag,
  output logic [P2_TILE_LOG2-1:0]           n_row,
  input  logic [P2_TILE-1:0][2:0]           n_stencil,
  input  logic [P2_TILE-1:0]                n_valid,
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
  // nothing here stalls
  assign out_rdy = 1'b1;
  assign f_re    = row_v;
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
      r1_v <= row_v;
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

  logic [P2_TILE-1:0]       n_dwe, n_twe, n_vwe, hit;
  logic [P2_TILE-1:0][2:0]  n_st;
  logic                     n_swe;
  always_comb begin
    n_dwe = '0;
    n_twe = '0;
    n_vwe = '0;
    hit   = '0;
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

  assign idle = !row_v && !r1_v && !r2_v;
endmodule
