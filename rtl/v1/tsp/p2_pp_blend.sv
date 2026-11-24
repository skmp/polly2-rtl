// p2_pp_blend: the pixel pipe's P10 blend and P11 feedback (PLAN M11; ARCHITECTURE 3.7.7 P10, P11, 3.9; tsp 19 at refsw3
// 4f3efe15: refsw_tile.cpp PixelFlush_tsp's last lines (tspAlphaStuck), BlendingUnit, BlendCoefs, BlendMul, the
// PixelFlush_tsp wrapper's tspAlphaStuck rule, ClearFpuCache; RenderParamTags' keepRes and punch-through branches).
//
// The P9 register holds the point (p2_pp_ss's pixel); its tile-buffer words are read as it enters (p2_tbuf's read ports,
// one clock): buffer 1 at idx, and buffer 2 at idx when the TSP word selects it (SrcSelect or DstSelect: the secondary
// port, shared with the write-out, ARCHITECTURE 3.9). In P10:
//   stuck alpha  the tile's tspAlphaStuck register: alpha 0 unless 255 [blendsel, blendsel2: settings 193, 196]; set after
//                a pixel (run-only too) of a volume with SrcSelect && DstSelect, DstInstr 0 (ZERO) and SrcInstr 1 (ONE) or
//                4 (SRC_A); cleared after an entry's eoe point (refsw3 ClearFpuCache at the next entry)
//   alpha test   (the point's atest: the punch-through passes, PT_MV's rendered pixels) alpha < PT_ALPHA_REF (the whole
//                register): alpha 0, failed; else alpha 255 [alphatest, dumprules cell 22]
//   blend        src = SrcSelect ? buffer 2 : the colour; dst = DstSelect ? buffer 2 : buffer 1; coefficients 0, the other
//                colour, src alpha, dst alpha, each inverted by the instruction's bit 0; each product (c x m) >> 8 with
//                255 counting as 256 and an inverse as 256 - that, then added and saturated [blend: 3072 of 3072]
//   write        to DstSelect ? buffer 2 : buffer 1, except a run-only pixel (keepRes: both words kept) and SrcSelect &&
//                DstSelect (writes nothing, every pair of instructions) [blend, blendsel]
//   the P10 forward  the next point's words were read in the clock this point writes: a read of the same word of the
//                same buffer takes the written value [I: no stall is measured; TR_PRESORT's back-to-back primitives]
//   P11 feedback the punch-through passes: a PIXEL message {idx, fail, ro} a pixel, PASS_DONE after the eop point (fail =
//                the pass's OR of fail on pixels not run-only) to the ISP (p2_isp_fb), through a 2-entry queue; a point
//                that cannot put its messages in it holds the pipe (fb_block)
// The point leaving P10 ends the pass drain (drain_done, on eop) and releases its run's store entries (rel, on the run's
// last point: the pins' extent, ARCHITECTURE 3.7.1).
// M12, the tile buffers' controller (p2_tbuf_ctl; ARCHITECTURE 3.9):
//   hold9      the P9 register takes no point (a bubble; the stages before it hold): p2_tsp_pp raises it while an eoe
//              point is in P10 (p10_eoe) and while the controller's action on that entry is pending, so that the next
//              entry's first point reads the buffers after the swap [M tim 3.10: "they swap when the TSP starts the next
//              tile"]
//   dlock      the buffer-2 interlock: a point with DstSelect waits in P10 while the write-out is busy (wo_busy) [M accbuf:
//              SEC WRITE +1025 a tile; the bands being written out are never damaged]; SrcSelect && DstSelect too (it
//              writes nothing; whether it waits is GAP: [G] the interlock decodes the DstSelect bit). Into the global stall.
module p2_pp_blend
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       stall,
  input  logic [31:0]                pt_alpha_ref,     // PT_ALPHA_REF
  input  logic                       hold9,
  input  logic                       wo_busy,
  output logic                       p10_eoe,
  output logic                       dlock,
  input  logic                       i_v,
  input  p2_pp_pt_t                  i_pt,
  input  logic [31:0]                i_col,
  // p2_tbuf: the reads (issued as a point enters P9's register, the data the clock after) and the write
  output logic                       rd_en,
  output logic [P2_PIX_BITS-1:0]     rd_idx,
  output logic                       rd_b2,
  input  logic [31:0]                rd_b1_data,
  input  logic [31:0]                rd_b2_data,
  output logic                       wr_en,
  output logic                       wr_b2,
  output logic [P2_PIX_BITS-1:0]     wr_idx,
  output logic [31:0]                wr_data,
  // P11: the feedback to the ISP
  output logic                       fb_v,
  input  logic                       fb_rdy,
  output p2_fb_t                     fb,
  output logic                       fb_block,
  // the point leaving P10
  output logic                       drain_done,
  output logic                       rel_v,
  output logic [1:0]                 rel_need,
  output logic [1:0][P2_TSP_SIDX_BITS-1:0] rel_idx,
  // taps
  output logic                       t_out,            // a point leaves P10
  output p2_pp_ctl_t                 t_ctl,
  output logic                       t_stuck,          // tspAlphaStuck after this point (before an eoe clears it)
  output logic                       t_at
);
  // ---------------------------------------------------------------------------------------------- the P9 register
  logic        s_v;
  p2_pp_pt_t   s_pt;
  logic [31:0] s_col;
  logic        fw1, fw2;
  logic [31:0] fwd;
  p2_pp_ctl_t  c;
  assign c = s_pt.ctl;

  assign rd_en  = i_v && !stall && !hold9;
  assign rd_idx = {i_pt.ctl.y, i_pt.ctl.x};
  assign rd_b2  = i_pt.ctl.hdr.tsp[25] || i_pt.ctl.hdr.tsp[24];

  // ---------------------------------------------------------------------------------------------- P10
  logic        stuck, anyfail;
  logic        srcsel, dstsel, setter, ptpass, adv;
  logic [2:0]  srci, dsti;
  assign srci   = c.hdr.tsp[31:29];
  assign dsti   = c.hdr.tsp[28:26];
  assign srcsel = c.hdr.tsp[25];
  assign dstsel = c.hdr.tsp[24];
  assign setter = srcsel && dstsel && dsti == 3'd0 && (srci == 3'd1 || srci == 3'd4);
  assign ptpass = c.rm == P2_RM_PUNCHTHROUGH_PASS0 || c.rm == P2_RM_PUNCHTHROUGH_PASSN;
  assign adv    = s_v && !stall;
  assign p10_eoe = s_v && c.eoe;
  assign dlock   = s_v && !c.null_ && dstsel && wo_busy;

  function automatic logic [8:0] bmul(input logic [7:0] x, input logic inv);   // BlendMul
    logic [8:0] k;
    k = {1'b0, x} + ((x == 8'hFF) ? 9'd1 : 9'd0);
    return inv ? (9'd256 - k) : k;
  endfunction
  function automatic logic [31:0] coefs(input logic [1:0] which, input logic [31:0] other, input logic [31:0] src,
                                        input logic [31:0] dst);           // BlendCoefs(inst >> 1)
    case (which)
      2'd0:    return '0;
      2'd1:    return other;
      2'd2:    return {4{src[31:24]}};
      default: return {4{dst[31:24]}};
    endcase
  endfunction

  logic [31:0] b1, b2, col, src, dst, sb, db, rv;
  logic        at;
  always_comb begin
    b1  = fw1 ? fwd : rd_b1_data;
    b2  = fw2 ? fwd : rd_b2_data;
    col = s_col;
    if (stuck) col[31:24] = (col[31:24] == 8'hFF) ? 8'hFF : 8'h00;
    at = 1'b1;
    if (c.atest) begin
      at = !(32'(col[31:24]) < pt_alpha_ref);
      col[31:24] = at ? 8'hFF : 8'h00;
    end
    src = srcsel ? b2 : col;
    dst = dstsel ? b2 : b1;
    sb  = coefs(srci[2:1], dst, src, dst);
    db  = coefs(dsti[2:1], src, src, dst);
    for (int j = 0; j < 4; j++) begin
      logic [16:0] ps, pd;
      logic [8:0]  sum;
      ps  = 17'(src[8 * j +: 8]) * 17'(bmul(sb[8 * j +: 8], srci[0]));
      pd  = 17'(dst[8 * j +: 8]) * 17'(bmul(db[8 * j +: 8], dsti[0]));
      sum = {1'b0, ps[15:8]} + {1'b0, pd[15:8]};
      rv[8 * j +: 8] = sum[8] ? 8'hFF : sum[7:0];
    end
  end

  assign wr_en   = adv && !c.null_ && !c.ro && !(srcsel && dstsel);
  assign wr_b2   = dstsel;
  assign wr_idx  = {c.y, c.x};
  assign wr_data = rv;

  // ---------------------------------------------------------------------------------------------- P11: the feedback
  logic [1:0]   q_n;
  p2_fb_t [1:0] q;
  logic [1:0]   npush;
  p2_fb_t       m_pix, m_done;
  logic         pfail;
  assign pfail = !c.null_ && !at && !c.ro;
  always_comb begin
    m_pix      = '0;
    m_pix.kind = P2_FB_PIXEL;
    m_pix.idx  = {c.y, c.x};
    m_pix.fail = !at;
    m_pix.ro   = c.ro;
    m_done      = '0;
    m_done.kind = P2_FB_PASS_DONE;
    m_done.fail = anyfail || pfail;
    npush = '0;
    if (s_v && ptpass) npush = 2'(!c.null_) + 2'(c.eop);
  end
  assign fb_block = npush > (2'd2 - q_n);
  assign fb_v     = q_n != 2'd0;
  assign fb       = q[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      q_n     <= '0;
      anyfail <= 1'b0;
    end else begin
      logic [1:0]   n;
      p2_fb_t [1:0] qq;
      n  = q_n;
      qq = q;
      if (fb_v && fb_rdy) begin
        qq[0] = qq[1];
        n     = n - 2'd1;
      end
      if (adv && ptpass) begin
        if (!c.null_) begin
          qq[n[0]] = m_pix;
          n        = n + 2'd1;
        end
        if (c.eop) begin
          qq[n[0]] = m_done;
          n        = n + 2'd1;
        end
        anyfail <= c.eop ? 1'b0 : (anyfail || pfail);
      end
      q_n <= n;
      q   <= qq;
    end
  end

  // ---------------------------------------------------------------------------------------------- the registers
  always_ff @(posedge clk) begin
    if (rst) begin
      s_v   <= 1'b0;
      stuck <= 1'b0;
    end else begin
      if (!stall) s_v <= i_v && !hold9;
      if (adv) begin
        if (c.eoe) stuck <= 1'b0;
        else if (!c.null_ && setter) stuck <= 1'b1;
      end
    end
    if (i_v && !stall && !hold9) begin
      s_pt  <= i_pt;
      s_col <= i_col;
      // the P10 forward: this point's write, read by the point entering now
      fw1 <= wr_en && !wr_b2 && wr_idx == rd_idx;
      fw2 <= wr_en && wr_b2 && wr_idx == rd_idx;
      fwd <= rv;
    end
  end

  assign drain_done = adv && c.eop && c.rm != P2_RM_TRANSLUCENT_PRESORT;   // the drained eops (p2_pp_issue)
  assign rel_v      = adv && c.last && !c.null_ && c.need != 2'b00;
  assign rel_need   = c.need;
  assign rel_idx    = c.sidx;
  assign t_out      = adv;
  assign t_ctl      = c;
  assign t_stuck    = stuck || (!c.null_ && setter);
  assign t_at       = at;
endmodule
