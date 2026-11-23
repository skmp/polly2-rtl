// p2_tsp_rstart: run start (PLAN M10; ARCHITECTURE 3.7.5; tsp 5.1-5.4 at refsw3 4f3efe15: pvr_tsp_plane.h PlaneT::Value up to
// the integer k, refsw_tile.h PlaneStepper3::Val; num H4 seen, H7b, H11 FloorUnits). For each run at the SRQ's head
// (p2_tsp_store) and each plane of each entry the run's pixels use, the plane's evaluator words for the run:
//
//   A', B', C' = seen(A, B, C)              no zero, no infinity: a zero is 2^-127, an infinity 2^-128, with its sign
//                                           [uvmeas wexp, whuge: 4875 of 4875 readings] (p2_fp_in_seen)
//   ex = BL(tileLeft + 16), ey likewise     the tile's far half (tile + 16 .. tile + 32: one exponent)
//   e  = max(top C', top A' + ex - 1, top B' + ey - 1),  unit = e - 22 (PlaneHW::gridBits)
//                                           [uvspan: "the grid is 22 bits under E, the exponent a product CAN have in
//                                           this tile"; takes every uvmeas, wmeas and cmeas set to 100 %]
//   x0h = 2 (tileLeft + x) + half, yh = 2 (tileTop + y) + half         half = HALF_OFFSET[1] [halfofs, halfofs2]
//   base  = F(C') + F(A' x0h / 2) + F(B' yh / 2)    each term floored to the grid on its own, the products exact (16 x 13)
//                                           [tspprobe macOrder on 29 uvmeas sets, 23,640,053 readings: this 0 wrong;
//                                           F(C + B y) + F(A x) 3,445; one rounding 512,221]; screen coordinates
//                                           [tileLocal: 15,801 .. 1,277,606 wrong]
//   step  = F(A');  step2 = F(A' / 2);  hyd = F(cut62(C' + B'/2)) - F(C')    (SupSample, tsp 5.4: half steps, the line
//                                           half a pixel down added to C before the floor: num H7b, ARTIFACT A1) [ssrare:
//                                           the 24 of 140,545 pixels where the fractions carry; sshalf 728 of 728]
//   F(v) = floor(v / 2^unit), F(-0) = -1    (FloorUnits; p2_fp_floor ZNEG) [uvmeas point 5; wmeas 60 % of flat triangles]
//
// The mechanism [M tim 3.8: 3.9 / 4.2 / 6.3 clk a run within one triangle (untextured / textured / offset), ~4.7 / 6 / 8
// across triangles; "2 products a plane on the shared ALU, plus a coefficient reload on a store-index change" I]:
//   - the coefficient cache: per volume the last entry read, keyed by (tag, volume, tile): its header, K and per plane
//     A', B' and the run-independent words (unit, F(C'), step, step2, hyd). A run whose key differs reloads it through
//     the store's row read (p2_tsp_store rw_*: four planes a clock from the four banks, the header and K with row 0;
//     rows 0, 1, and 2 when the class has the offset planes), four lanes of seen / grid / floors / half line, one a
//     bank. The setup is a pure function of the key, the parameters and the registers, so a key in the cache needs no
//     read; `flush` (a render's start) empties it.
//   - the products: two planes a clock on the shared ALU's P2_TSP_NM = 4 multipliers (A' x0h, B' yh each; p2_tsp_alu's
//     run-start port, the setup's step held: `hold`), the results P2_TSP_L_MUL later floored and summed into base. The
//     planes are those the entry's class sets up (untextured 5: W and the colours; textured 7: + U, V; with the offset
//     planes 11; tsp 2.3, PixelFlush_tsp); a run with mixed vmask needs both volumes' [G T19: double cost].
//   - the run's descriptor (p2_tsp_rdesc_t) waits in an output register for p2_pxq; the next run is taken in the clock
//     it leaves. Pitch: the product clocks + 1 (5 / 7 / 11 planes: 4 / 5 / 7), a reload ~3 more [GAP T7: MT5's].
// Entries' tiles come from their records (er_*: p2_entq's in p2_core, M12): one is taken before an entry's first item,
// and dropped after its eoe item. Null items pass with their flags.
module p2_tsp_rstart
  import p2_hw_pkg::*;
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_fp_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              flush,      // a render's start: the cache is empty
  input  logic                              half,       // HALF_OFFSET[1] tsp_pixel_half_offset
  // the entries' records (the tile)
  input  logic                              er_v,
  output logic                              er_rdy,
  input  logic [5:0]                        er_tilex,
  input  logic [5:0]                        er_tiley,
  // the SRQ's head (p2_tsp_store out_*)
  input  logic                              in_v,
  output logic                              in_rdy,
  input  p2_rs_t                            in_item,
  input  logic [1:0]                        in_need,
  input  logic [1:0][P2_TSP_SIDX_BITS-1:0]  in_idx,
  // the store's row read
  output logic                              rw_v,
  output logic [P2_TSP_SIDX_BITS-1:0]       rw_idx,
  output logic [1:0]                        rw_row,
  input  p2_tsp_hdr_t                       rw_hdr,
  input  p2_tsp_k_t                         rw_k,
  input  p2_tsp_plane_t [3:0]               rw_plane,
  // the shared ALU (p2_tsp_setup / p2_tsp_alu): run start first
  output logic                              hold,
  output p2_fp16_t [P2_TSP_NM-1:0]          rs_a,
  output logic [P2_TSP_NM-1:0][12:0]        rs_b,
  input  p2_tsp_rsp_t [P2_TSP_NM-1:0]       rs_p,
  // the descriptor, to p2_pxq
  output logic                              o_v,
  input  logic                              o_rdy,
  output p2_tsp_rdesc_t                     o_d,
  // statistics (reported, not gated: T7)
  output logic                              t_busy,
  output logic                              t_reload,   // a row read this clock
  output logic                              t_mul       // run start's products this clock
);
  localparam int NPL = P2_TSP_NPL;
  localparam int GB  = P2_TSP_PLANE_GRID_BITS;

  // ---------------------------------------------------------------------------------------------- the planes of a class
  // (gen_tsp_prog.cpp kCls; p2_tsp_prog_pkg P2_TSP_CLS_*): UNTEX W, CB, CG, CR, CA; TEX* + U, V; TEX_O*, TEX_D* + the four
  // offset planes
  function automatic logic [3:0] n_planes(input logic [3:0] cls);
    if (cls == P2_TSP_CLS_UNTEX) return 4'd5;
    if (cls == P2_TSP_CLS_TEX || cls == P2_TSP_CLS_TEX_M0 || cls == P2_TSP_CLS_TEX_M1) return 4'd7;
    return 4'd11;
  endfunction
  function automatic logic [3:0] plane_at(input logic [3:0] cls, input logic [3:0] i);
    if (cls == P2_TSP_CLS_UNTEX) return (i == 4'd0) ? P2_TSP_PL_W : i + 4'd2;
    return i;
  endfunction

  // ---------------------------------------------------------------------------------------------- state
  typedef enum logic [1:0] { S_IDLE, S_RD, S_MUL, S_OUT } st_t;
  st_t st;

  logic       tile_have;
  logic [5:0] tile_x, tile_y;

  // the coefficient cache, per volume
  logic [1:0]                                   c_v;
  logic [1:0][31:0]                             c_tag;
  logic [1:0][5:0]                              c_tx, c_ty;
  p2_tsp_hdr_t [1:0]                            c_hdr;
  p2_tsp_k_t   [1:0]                            c_k;
  p2_fp16_t    [1:0][NPL-1:0]                   c_a, c_b;       // A', B' (seen)
  logic signed [1:0][NPL-1:0][P2_FP_EW-1:0]     c_unit;
  logic signed [1:0][NPL-1:0][P2_TSP_KBITS-1:0] c_fc;           // F(C')
  logic signed [1:0][NPL-1:0][P2_TSP_STEPBITS-1:0] c_step, c_step2;
  logic signed [1:0][NPL-1:0][P2_TSP_HYDBITS-1:0]  c_hyd;

  // the run in hand
  p2_rs_t                             r_item;
  logic [1:0]                         r_need, r_miss;
  logic [1:0][P2_TSP_SIDX_BITS-1:0]   r_idx;
  logic [5:0]                         r_tx, r_ty;
  logic [12:0]                        r_x0h, r_yh;
  logic signed [1:0][NPL-1:0][P2_TSP_KBITS-1:0] b_base;

  // the reload's and the products' pipeline registers (declared before their first use)
  logic       rd_vol;             // the volume being read
  logic [1:0] rd_row;
  logic       rd_issue, rd_more;
  logic       pd_v, pd_vol;       // the row whose data arrives this clock
  logic [1:0] pd_row;
  logic       mu_vol;             // the products: the volume, the index in its list
  logic [3:0] mu_i;
  logic       rp_v, rp_vol;       // the products whose results arrive this clock
  logic [1:0] rp_ok;
  logic [1:0][3:0] rp_pl;

  // ---------------------------------------------------------------------------------------------- taking an item
  logic       take, can_take;
  logic [1:0] miss_in;
  logic       out_free;
  assign out_free = !o_v || o_rdy;
  always_comb
    for (int v = 0; v < 2; v++)
      miss_in[v] = in_need[v] && !(c_v[v] && c_tag[v] == in_item.tag && c_tx[v] == tile_x && c_ty[v] == tile_y);
  // the descriptor leaves this clock (S_OUT) or none is in hand (S_IDLE): the next head can come in
  logic leaving;
  assign leaving  = st == S_OUT && out_free;       // with this clock's results merged (b_base_n)
  assign can_take = tile_have && !flush && (st == S_IDLE || leaving);
  assign in_rdy   = can_take;
  assign take     = in_v && can_take;
  assign er_rdy   = !tile_have && !flush;

  // ---------------------------------------------------------------------------------------------- the reload: row reads
  // rows a volume needs: 2, or 3 with the offset planes; its class from row 0's header, which arrives in the clock row 1
  // is read
  p2_tsp_hdr_t hdr_now;
  logic [3:0]  rd_rows;
  assign hdr_now  = (pd_v && pd_row == 2'd0 && pd_vol == rd_vol) ? rw_hdr : c_hdr[rd_vol];
  assign rd_rows  = (n_planes(hdr_now.cls) > 4'd8) ? 4'd3 : 4'd2;
  assign rd_issue = st == S_RD && rd_more;
  assign rw_v     = rd_issue;
  assign rw_idx   = r_idx[rd_vol];
  assign rw_row   = rd_row;
  assign t_reload = rd_issue;

  // the four lanes of a row's data: seen, the grid, the floors, the half line
  // the run's tile (r_tx, r_ty: the entry record may already be the next entry's while the eoe run reloads)
  logic signed [P2_FP_XW-1:0] ex, ey;                   // BL(tileLeft + 16), BL(tileTop + 16)
  logic [10:0] xl16, yt16;
  assign xl16 = 11'({r_tx, 5'd0}) + 11'd16;
  assign yt16 = 11'({r_ty, 5'd0}) + 11'd16;
  always_comb begin
    ex = '0;
    ey = '0;
    for (int i = 0; i < 11; i++) begin
      if (xl16[i]) ex = P2_FP_XW'(i + 1);
      if (yt16[i]) ey = P2_FP_XW'(i + 1);
    end
  end
  p2_fp16_t   [3:0]                       ln_a, ln_b, ln_c;
  logic signed [3:0][P2_FP_EW-1:0]        ln_unit;
  logic signed [3:0][P2_TSP_KBITS-1:0]    ln_fc, ln_hyd27;
  logic signed [3:0][P2_TSP_STEPBITS-1:0] ln_step, ln_step2;
  genvar g;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_lane
      p2_tsp_plane_t pl;
      logic          sa_bad, sb_bad, sc_bad;
      logic [4:0]    bla, blb, blc;
      logic signed [P2_FP_XW-1:0] ta, tb, tc, e;
      logic signed [P2_FP_EW-1:0] a2_exp;
      assign pl = rw_plane[g];
      p2_fp_in_seen #(.MW(16)) u_sa (.i_neg(pl.a.neg), .i_bad(pl.a.bad), .i_exp(pl.a.exp), .i_mant(pl.a.mant),
        .o_neg(ln_a[g].neg), .o_bad(sa_bad), .o_exp(ln_a[g].exp), .o_mant(ln_a[g].mant));
      p2_fp_in_seen #(.MW(16)) u_sb (.i_neg(pl.b.neg), .i_bad(pl.b.bad), .i_exp(pl.b.exp), .i_mant(pl.b.mant),
        .o_neg(ln_b[g].neg), .o_bad(sb_bad), .o_exp(ln_b[g].exp), .o_mant(ln_b[g].mant));
      p2_fp_in_seen #(.MW(16)) u_sc (.i_neg(pl.c.neg), .i_bad(pl.c.bad), .i_exp(pl.c.exp), .i_mant(pl.c.mant),
        .o_neg(ln_c[g].neg), .o_bad(sc_bad), .o_exp(ln_c[g].exp), .o_mant(ln_c[g].mant));
      assign ln_a[g].bad = 1'b0;
      assign ln_b[g].bad = 1'b0;
      assign ln_c[g].bad = 1'b0;
      p2_fp_lzc #(.W(16), .NW(5)) u_la (.v(ln_a[g].mant), .n(bla));
      p2_fp_lzc #(.W(16), .NW(5)) u_lb (.v(ln_b[g].mant), .n(blb));
      p2_fp_lzc #(.W(16), .NW(5)) u_lc (.v(ln_c[g].mant), .n(blc));
      // top(v) = exp + BL(mant): seen values are never zero
      assign ta = p2_fp_xw(ln_a[g].exp) + P2_FP_XW'(bla);
      assign tb = p2_fp_xw(ln_b[g].exp) + P2_FP_XW'(blb);
      assign tc = p2_fp_xw(ln_c[g].exp) + P2_FP_XW'(blc);
      always_comb begin
        e = tc;
        if (ta + ex - P2_FP_XW'(1) > e) e = ta + ex - P2_FP_XW'(1);
        if (tb + ey - P2_FP_XW'(1) > e) e = tb + ey - P2_FP_XW'(1);
      end
      assign ln_unit[g] = P2_FP_EW'(e - P2_FP_XW'(GB));
      p2_fp_floor #(.MW(16), .OW(P2_TSP_KBITS), .ZNEG(1'b1), .CLAMP(0)) u_fc (
        .i_neg(ln_c[g].neg), .i_exp(ln_c[g].exp), .i_mant(ln_c[g].mant), .u(ln_unit[g]), .o_int(ln_fc[g]), .o_frac());
      p2_fp_floor #(.MW(16), .OW(P2_TSP_STEPBITS), .ZNEG(1'b1), .CLAMP(0)) u_fa (
        .i_neg(ln_a[g].neg), .i_exp(ln_a[g].exp), .i_mant(ln_a[g].mant), .u(ln_unit[g]), .o_int(ln_step[g]), .o_frac());
      // A' / 2: Mul(a_, FromHalves(1), 62), the mantissa as it is, the exponent one less
      assign a2_exp = ln_a[g].exp - P2_FP_EW'(1);
      p2_fp_floor #(.MW(16), .OW(P2_TSP_STEPBITS), .ZNEG(1'b1), .CLAMP(0)) u_fa2 (
        .i_neg(ln_a[g].neg), .i_exp(a2_exp), .i_mant(ln_a[g].mant), .u(ln_unit[g]), .o_int(ln_step2[g]), .o_frac());
      p2_fp_half_line #(.MW(16), .KW(P2_TSP_KBITS)) u_hl (
        .c_neg(ln_c[g].neg), .c_exp(ln_c[g].exp), .c_mant(ln_c[g].mant),
        .b_neg(ln_b[g].neg), .b_exp(ln_b[g].exp), .b_mant(ln_b[g].mant), .unit(ln_unit[g]), .dk(ln_hyd27[g]));
    end
  endgenerate

  // ---------------------------------------------------------------------------------------------- the products
  // the run's list: volume 0's planes, then volume 1's, two planes (four products) a clock, not across volumes
  logic [3:0] mu_n;               // the volume's planes
  logic       mu_issue, mu_two;
  logic [3:0] mu_p0, mu_p1;
  assign mu_n     = n_planes(c_hdr[mu_vol].cls);
  assign mu_issue = st == S_MUL;
  assign mu_two   = mu_i + 4'd1 < mu_n;
  assign mu_p0    = plane_at(c_hdr[mu_vol].cls, mu_i);
  assign mu_p1    = plane_at(c_hdr[mu_vol].cls, mu_i + 4'd1);
  assign hold     = mu_issue;
  assign t_mul    = mu_issue;
  always_comb begin
    rs_a[0] = c_a[mu_vol][mu_p0];
    rs_b[0] = r_x0h;
    rs_a[1] = c_b[mu_vol][mu_p0];
    rs_b[1] = r_yh;
    rs_a[2] = c_a[mu_vol][mu_p1];
    rs_b[2] = r_x0h;
    rs_a[3] = c_b[mu_vol][mu_p1];
    rs_b[3] = r_yh;
  end
  // the results, P2_TSP_L_MUL (1) clock later: floored to the plane's grid (the halves' 2^-1 here), summed into base
  logic signed [3:0][P2_TSP_KBITS-1:0] rp_f;
  generate
    for (g = 0; g < 4; g = g + 1) begin : g_fl
      logic signed [P2_FP_EW-1:0] pe;
      assign pe = rs_p[g].exp - P2_FP_EW'(1);
      p2_fp_floor #(.MW(29), .OW(P2_TSP_KBITS), .ZNEG(1'b1), .CLAMP(0)) u_fp (
        .i_neg(rs_p[g].neg), .i_exp(pe), .i_mant(rs_p[g].mant), .u(c_unit[rp_vol][rp_pl[g / 2]]), .o_int(rp_f[g]), .o_frac());
    end
  endgenerate
  // base with this clock's results in (the descriptor is loaded from it in the clock the last results come)
  logic signed [1:0][NPL-1:0][P2_TSP_KBITS-1:0] b_base_n;
  always_comb begin
    b_base_n = b_base;
    if (rp_v)
      for (int h = 0; h < 2; h++)
        if (rp_ok[h])
          b_base_n[rp_vol][rp_pl[h]] = c_fc[rp_vol][rp_pl[h]] + rp_f[2 * h] + rp_f[2 * h + 1];
  end

  // ---------------------------------------------------------------------------------------------- the descriptor
  p2_tsp_rdesc_t d_new;
  always_comb begin
    d_new       = '0;
    d_new.item  = r_item;
    d_new.need  = r_need;
    d_new.sidx  = r_idx;
    d_new.tilex = r_tx;
    d_new.tiley = r_ty;
    for (int v = 0; v < 2; v++) begin
      d_new.vol[v].hdr = c_hdr[v];
      d_new.vol[v].k   = c_k[v];
      for (int p = 0; p < NPL; p++) begin
        d_new.vol[v].pl[p].base  = b_base_n[v][p];
        d_new.vol[v].pl[p].step  = c_step[v][p];
        d_new.vol[v].pl[p].step2 = c_step2[v][p];
        d_new.vol[v].pl[p].hyd   = c_hyd[v][p];
        d_new.vol[v].pl[p].unit  = c_unit[v][p];
      end
    end
  end

  assign t_busy = st != S_IDLE;

  always_ff @(posedge clk) begin
    if (rst) begin
      st        <= S_IDLE;
      tile_have <= 1'b0;
      c_v       <= '0;
      o_v       <= 1'b0;
      pd_v      <= 1'b0;
      rp_v      <= 1'b0;
    end else begin
      if (o_v && o_rdy) o_v <= 1'b0;
      if (er_v && er_rdy) begin
        tile_have <= 1'b1;
        tile_x    <= er_tilex;
        tile_y    <= er_tiley;
      end
      // ---- the reload's data: this clock's row into the cache (row 0 with the header, K and the key)
      pd_v <= rd_issue;
      if (rd_issue) begin
        pd_vol <= rd_vol;
        pd_row <= rd_row;
      end
      if (pd_v) begin
        if (pd_row == 2'd0) begin
          c_hdr[pd_vol] <= rw_hdr;
          c_k[pd_vol]   <= rw_k;
          c_tag[pd_vol] <= r_item.tag;
          c_tx[pd_vol]  <= r_tx;
          c_ty[pd_vol]  <= r_ty;
          c_v[pd_vol]   <= 1'b1;
        end
        for (int b = 0; b < 4; b++) begin
          logic [3:0] p;
          p = {pd_row, 2'(b)};
          if (p < 4'(NPL)) begin
            c_a[pd_vol][p]     <= ln_a[b];
            c_b[pd_vol][p]     <= ln_b[b];
            c_unit[pd_vol][p]  <= ln_unit[b];
            c_fc[pd_vol][p]    <= ln_fc[b];
            c_step[pd_vol][p]  <= ln_step[b];
            c_step2[pd_vol][p] <= ln_step2[b];
            c_hyd[pd_vol][p]   <= P2_TSP_HYDBITS'(ln_hyd27[b]);
          end
        end
      end
      // ---- the products' results
      rp_v <= mu_issue;
      if (mu_issue) begin
        rp_vol   <= mu_vol;
        rp_pl[0] <= mu_p0;
        rp_pl[1] <= mu_p1;
        rp_ok    <= {mu_two, 1'b1};
      end
      b_base <= b_base_n;

      case (st)
        S_IDLE: ;
        S_RD: begin
          if (rd_issue) begin
            if (4'(rd_row) + 4'd1 < rd_rows) begin
              rd_row <= rd_row + 2'd1;
            end else if (!rd_vol && r_miss[1]) begin
              rd_vol <= 1'b1;
              rd_row <= 2'd0;
            end else begin
              rd_more <= 1'b0;
            end
          end else if (!pd_v) begin
            // every row is in: the products
            st     <= S_MUL;
            mu_vol <= !r_need[0];
            mu_i   <= 4'd0;
          end
        end
        S_MUL: begin
          if (mu_i + 4'd2 < mu_n) begin
            mu_i <= mu_i + 4'd2;
          end else if (!mu_vol && r_need[1]) begin
            mu_vol <= 1'b1;
            mu_i   <= 4'd0;
          end else begin
            st <= S_OUT;
          end
        end
        S_OUT: begin
          if (leaving) begin
            o_v <= 1'b1;
            o_d <= d_new;
            st  <= S_IDLE;
          end
        end
        default: st <= S_IDLE;
      endcase

      // ---- an item comes in (in S_IDLE, or as the descriptor leaves)
      if (take) begin
        r_item <= in_item;
        r_need <= in_need;
        r_idx  <= in_idx;
        r_tx   <= tile_x;
        r_ty   <= tile_y;
        r_x0h  <= {(11'({tile_x, 5'd0}) + 11'(in_item.x)), 1'b0} + 13'(half);     // 2 (tileLeft + x) + half
        r_yh   <= {(11'({tile_y, 5'd0}) + 11'(in_item.y)), 1'b0} + 13'(half);
        r_miss <= miss_in;
        if (in_item.eoe) tile_have <= 1'b0;
        if (in_item.null_ || in_need == 2'b00) begin
          st <= S_OUT;
        end else if (miss_in != 2'b00) begin
          st      <= S_RD;
          rd_vol  <= !miss_in[0];
          rd_row  <= 2'd0;
          rd_more <= 1'b1;
          for (int v = 0; v < 2; v++)
            if (miss_in[v]) c_v[v] <= 1'b0;
        end else begin
          st     <= S_MUL;
          mu_vol <= !in_need[0];
          mu_i   <= 4'd0;
        end
      end
      if (flush)
        c_v <= '0;
    end
  end
endmodule
