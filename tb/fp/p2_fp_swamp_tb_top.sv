// p2_fp_swamp_tb_top: make fp-swamp (tb/fp/fp_swamp_tb.cpp). H7a p2_fp_swamp three ways:
//   - alone: swamp (SAT 0) and sat (SAT 1) of the tuple i;
//   - in place in EdgeWinding (pvr_isp_edge.h L110-122): the swamped determinant of the corners (x[k], y[k]), built from
//     p2_fp_mul (24x24 -> 24), p2_fp_add (24/25; Sub flips the sign) and p2_fp_swamp in refsw3's order;
//   - in place in EdgeTile::Setup's start (L180-197): c, dx, dy (saturated), dxP, dyP (swamped), first and the start
//     (saturated), from the edge a -> b and the tile's first sample point (x0, y0: FromHalves tuples).
// Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_swamp_tb_top
  import p2_fp_pkg::*;
(
  input  logic                              clk,
  input  logic                              in_v,
  // alone
  input  logic                              i_neg,
  input  logic                              i_bad,
  input  logic signed [P2_FP_EW-1:0]        i_exp,
  input  logic [23:0]                       i_mant,
  // EdgeWinding's corners
  input  logic [2:0]                        x_neg,
  input  logic [2:0]                        x_bad,
  input  logic [2:0][P2_FP_EW-1:0]          x_exp,
  input  logic [2:0][23:0]                  x_mant,
  input  logic [2:0]                        y_neg,
  input  logic [2:0]                        y_bad,
  input  logic [2:0][P2_FP_EW-1:0]          y_exp,
  input  logic [2:0][23:0]                  y_mant,
  // the start: the edge a -> b ([0] = a, [1] = b) and the sample point
  input  logic [1:0]                        ex_neg,
  input  logic [1:0][P2_FP_EW-1:0]         ex_exp,
  input  logic [1:0][23:0]                  ex_mant,
  input  logic [1:0]                        ey_neg,
  input  logic [1:0][P2_FP_EW-1:0]          ey_exp,
  input  logic [1:0][23:0]                  ey_mant,
  input  logic                              x0_neg,
  input  logic                              x0_bad,
  input  logic signed [P2_FP_EW-1:0]        x0_exp,
  input  logic [23:0]                       x0_mant,
  input  logic                              y0_neg,
  input  logic                              y0_bad,
  input  logic signed [P2_FP_EW-1:0]        y0_exp,
  input  logic [23:0]                       y0_mant,
  output logic                              out_v,
  output logic                              sw_neg, sw_bad, sat_neg, sat_bad,
  output logic signed [P2_FP_EW-1:0]        sw_exp, sat_exp,
  output logic [23:0]                       sw_mant, sat_mant,
  output logic                              det_neg, det_bad,
  output logic signed [P2_FP_EW-1:0]        det_exp,
  output logic [23:0]                       det_mant,
  // the start's values: 0 c, 1 dx (sat), 2 dy (sat), 3 dxP, 4 dyP, 5 first, 6 start (sat)
  output logic [6:0]                        st_neg,
  output logic [6:0]                        st_bad,
  output logic [6:0][P2_FP_EW-1:0]          st_exp,
  output logic [6:0][23:0]                  st_mant
);
  p2_hw_check u_hw_check ();

  typedef logic signed [P2_FP_EW-1:0] ex_t;

  // ---- alone
  logic sn, sb, tn, tb;
  ex_t  se, te;
  logic [23:0] sm, tm;
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_sw (.i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant),
    .o_neg(sn), .o_bad(sb), .o_exp(se), .o_mant(sm));
  p2_fp_swamp #(.MW(24), .SAT(1'b1)) u_sat (.i_neg(i_neg), .i_bad(i_bad), .i_exp(i_exp), .i_mant(i_mant),
    .o_neg(tn), .o_bad(tb), .o_exp(te), .o_mant(tm));

  // ---- EdgeWinding: e(j, k) = swamp(Sub(swamp(Mul(x[j], y[k])), swamp(Mul(x[k], y[j])))), edges (1,2) (2,0) (0,1)
  logic [2:0][1:0]       pn, pb, qn, qb;     // the products, then swamped
  ex_t  [2:0][1:0]       pe, qe;
  logic [2:0][1:0][23:0] pm, qm;
  logic [2:0]            en, eb, fn, fb;     // each e before and after its swamp
  ex_t  [2:0]            ee, fe;
  logic [2:0][23:0]      em, fm;
  genvar g;
  generate
    for (g = 0; g < 3; g = g + 1) begin : g_edge
      localparam int J = (g + 1) % 3;
      localparam int K = (g + 2) % 3;
      p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_m0 (
        .a_neg(x_neg[J]), .a_bad(x_bad[J]), .a_exp(x_exp[J]), .a_mant(x_mant[J]),
        .b_neg(y_neg[K]), .b_bad(y_bad[K]), .b_exp(y_exp[K]), .b_mant(y_mant[K]),
        .o_neg(pn[g][0]), .o_bad(pb[g][0]), .o_exp(pe[g][0]), .o_mant(pm[g][0]));
      p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_m1 (
        .a_neg(x_neg[K]), .a_bad(x_bad[K]), .a_exp(x_exp[K]), .a_mant(x_mant[K]),
        .b_neg(y_neg[J]), .b_bad(y_bad[J]), .b_exp(y_exp[J]), .b_mant(y_mant[J]),
        .o_neg(pn[g][1]), .o_bad(pb[g][1]), .o_exp(pe[g][1]), .o_mant(pm[g][1]));
      p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_s0 (.i_neg(pn[g][0]), .i_bad(pb[g][0]), .i_exp(pe[g][0]),
        .i_mant(pm[g][0]), .o_neg(qn[g][0]), .o_bad(qb[g][0]), .o_exp(qe[g][0]), .o_mant(qm[g][0]));
      p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_s1 (.i_neg(pn[g][1]), .i_bad(pb[g][1]), .i_exp(pe[g][1]),
        .i_mant(pm[g][1]), .o_neg(qn[g][1]), .o_bad(qb[g][1]), .o_exp(qe[g][1]), .o_mant(qm[g][1]));
      p2_fp_add #(.W(24), .R(25)) u_sub (
        .a_neg(qn[g][0]), .a_bad(qb[g][0]), .a_exp(qe[g][0]), .a_mant(qm[g][0]),
        .b_neg(!qn[g][1]), .b_bad(qb[g][1]), .b_exp(qe[g][1]), .b_mant(qm[g][1]),
        .o_neg(en[g]), .o_bad(eb[g]), .o_exp(ee[g]), .o_mant(em[g]));
      p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_se (.i_neg(en[g]), .i_bad(eb[g]), .i_exp(ee[g]), .i_mant(em[g]),
        .o_neg(fn[g]), .o_bad(fb[g]), .o_exp(fe[g]), .o_mant(fm[g]));
    end
  endgenerate
  // det = swamp(Add(swamp(Add(e1, e2)), e3))
  logic        s12n, s12b, w12n, w12b, dn, db, wn, wb;
  ex_t         s12e, w12e, de, we;
  logic [23:0] s12m, w12m, dm, wm;
  p2_fp_add #(.W(24), .R(25)) u_a12 (
    .a_neg(fn[0]), .a_bad(fb[0]), .a_exp(fe[0]), .a_mant(fm[0]),
    .b_neg(fn[1]), .b_bad(fb[1]), .b_exp(fe[1]), .b_mant(fm[1]),
    .o_neg(s12n), .o_bad(s12b), .o_exp(s12e), .o_mant(s12m));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_s12 (.i_neg(s12n), .i_bad(s12b), .i_exp(s12e), .i_mant(s12m),
    .o_neg(w12n), .o_bad(w12b), .o_exp(w12e), .o_mant(w12m));
  p2_fp_add #(.W(24), .R(25)) u_a3 (
    .a_neg(w12n), .a_bad(w12b), .a_exp(w12e), .a_mant(w12m),
    .b_neg(fn[2]), .b_bad(fb[2]), .b_exp(fe[2]), .b_mant(fm[2]),
    .o_neg(dn), .o_bad(db), .o_exp(de), .o_mant(dm));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_sd (.i_neg(dn), .i_bad(db), .i_exp(de), .i_mant(dm),
    .o_neg(wn), .o_bad(wb), .o_exp(we), .o_mant(wm));

  // ---- EdgeTile::Setup's start (the corners are finite here: Setup returned on a bad one)
  // c = swamp(Sub(swamp(Mul(xb, ya)), swamp(Mul(xa, yb))))
  logic [1:0]       cpn, cpb, cqn, cqb;
  ex_t  [1:0]       cpe, cqe;
  logic [1:0][23:0] cpm, cqm;
  logic             c0n, c0b, cn, cb;
  ex_t              c0e, ce;
  logic [23:0]      c0m, cm;
  p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_cm0 (
    .a_neg(ex_neg[1]), .a_bad(1'b0), .a_exp(ex_exp[1]), .a_mant(ex_mant[1]),
    .b_neg(ey_neg[0]), .b_bad(1'b0), .b_exp(ey_exp[0]), .b_mant(ey_mant[0]),
    .o_neg(cpn[0]), .o_bad(cpb[0]), .o_exp(cpe[0]), .o_mant(cpm[0]));
  p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_cm1 (
    .a_neg(ex_neg[0]), .a_bad(1'b0), .a_exp(ex_exp[0]), .a_mant(ex_mant[0]),
    .b_neg(ey_neg[1]), .b_bad(1'b0), .b_exp(ey_exp[1]), .b_mant(ey_mant[1]),
    .o_neg(cpn[1]), .o_bad(cpb[1]), .o_exp(cpe[1]), .o_mant(cpm[1]));
  generate
    for (g = 0; g < 2; g = g + 1) begin : g_cs
      p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_cs (.i_neg(cpn[g]), .i_bad(cpb[g]), .i_exp(cpe[g]), .i_mant(cpm[g]),
        .o_neg(cqn[g]), .o_bad(cqb[g]), .o_exp(cqe[g]), .o_mant(cqm[g]));
    end
  endgenerate
  p2_fp_add #(.W(24), .R(25)) u_csub (
    .a_neg(cqn[0]), .a_bad(cqb[0]), .a_exp(cqe[0]), .a_mant(cqm[0]),
    .b_neg(!cqn[1]), .b_bad(cqb[1]), .b_exp(cqe[1]), .b_mant(cqm[1]),
    .o_neg(c0n), .o_bad(c0b), .o_exp(c0e), .o_mant(c0m));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_cw (.i_neg(c0n), .i_bad(c0b), .i_exp(c0e), .i_mant(c0m),
    .o_neg(cn), .o_bad(cb), .o_exp(ce), .o_mant(cm));
  // dx = Sub(xa, xb), dy = Sub(ya, yb); dxP, dyP their swamps; the steps their saturations
  logic        dxn, dxb, dyn, dyb, dxpn, dxpb, dypn, dypb, dxsn, dxsb, dysn, dysb;
  ex_t         dxe, dye, dxpe, dype, dxse, dyse;
  logic [23:0] dxm, dym, dxpm, dypm, dxsm, dysm;
  p2_fp_add #(.W(24), .R(25)) u_dx (
    .a_neg(ex_neg[0]), .a_bad(1'b0), .a_exp(ex_exp[0]), .a_mant(ex_mant[0]),
    .b_neg(!ex_neg[1]), .b_bad(1'b0), .b_exp(ex_exp[1]), .b_mant(ex_mant[1]),
    .o_neg(dxn), .o_bad(dxb), .o_exp(dxe), .o_mant(dxm));
  p2_fp_add #(.W(24), .R(25)) u_dy (
    .a_neg(ey_neg[0]), .a_bad(1'b0), .a_exp(ey_exp[0]), .a_mant(ey_mant[0]),
    .b_neg(!ey_neg[1]), .b_bad(1'b0), .b_exp(ey_exp[1]), .b_mant(ey_mant[1]),
    .o_neg(dyn), .o_bad(dyb), .o_exp(dye), .o_mant(dym));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_dxp (.i_neg(dxn), .i_bad(dxb), .i_exp(dxe), .i_mant(dxm),
    .o_neg(dxpn), .o_bad(dxpb), .o_exp(dxpe), .o_mant(dxpm));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_dyp (.i_neg(dyn), .i_bad(dyb), .i_exp(dye), .i_mant(dym),
    .o_neg(dypn), .o_bad(dypb), .o_exp(dype), .o_mant(dypm));
  p2_fp_swamp #(.MW(24), .SAT(1'b1)) u_dxs (.i_neg(dxn), .i_bad(dxb), .i_exp(dxe), .i_mant(dxm),
    .o_neg(dxsn), .o_bad(dxsb), .o_exp(dxse), .o_mant(dxsm));
  p2_fp_swamp #(.MW(24), .SAT(1'b1)) u_dys (.i_neg(dyn), .i_bad(dyb), .i_exp(dye), .i_mant(dym),
    .o_neg(dysn), .o_bad(dysb), .o_exp(dyse), .o_mant(dysm));
  // first = swamp(Add(swamp(Mul(dxP, y0)), -swamp(Mul(dyP, x0))))
  logic [1:0]       fpn, fpb, fqn, fqb;
  ex_t  [1:0]       fpe, fqe;
  logic [1:0][23:0] fpm, fqm;
  logic             f0n, f0b, frn, frb;
  ex_t              f0e, fre;
  logic [23:0]      f0m, frm;
  p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_fm0 (
    .a_neg(dxpn), .a_bad(dxpb), .a_exp(dxpe), .a_mant(dxpm),
    .b_neg(y0_neg), .b_bad(y0_bad), .b_exp(y0_exp), .b_mant(y0_mant),
    .o_neg(fpn[0]), .o_bad(fpb[0]), .o_exp(fpe[0]), .o_mant(fpm[0]));
  p2_fp_mul #(.AW(24), .BW(24), .N(24)) u_fm1 (
    .a_neg(dypn), .a_bad(dypb), .a_exp(dype), .a_mant(dypm),
    .b_neg(x0_neg), .b_bad(x0_bad), .b_exp(x0_exp), .b_mant(x0_mant),
    .o_neg(fpn[1]), .o_bad(fpb[1]), .o_exp(fpe[1]), .o_mant(fpm[1]));
  generate
    for (g = 0; g < 2; g = g + 1) begin : g_fs
      p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_fs (.i_neg(fpn[g]), .i_bad(fpb[g]), .i_exp(fpe[g]), .i_mant(fpm[g]),
        .o_neg(fqn[g]), .o_bad(fqb[g]), .o_exp(fqe[g]), .o_mant(fqm[g]));
    end
  endgenerate
  p2_fp_add #(.W(24), .R(25)) u_fadd (
    .a_neg(fqn[0]), .a_bad(fqb[0]), .a_exp(fqe[0]), .a_mant(fqm[0]),
    .b_neg(!fqn[1]), .b_bad(fqb[1]), .b_exp(fqe[1]), .b_mant(fqm[1]),
    .o_neg(f0n), .o_bad(f0b), .o_exp(f0e), .o_mant(f0m));
  p2_fp_swamp #(.MW(24), .SAT(1'b0)) u_fw (.i_neg(f0n), .i_bad(f0b), .i_exp(f0e), .i_mant(f0m),
    .o_neg(frn), .o_bad(frb), .o_exp(fre), .o_mant(frm));
  // start = Add(first, c), saturated
  logic        s0n, s0b, srn, srb;
  ex_t         s0e, sre;
  logic [23:0] s0m, srm;
  p2_fp_add #(.W(24), .R(25)) u_sadd (
    .a_neg(frn), .a_bad(frb), .a_exp(fre), .a_mant(frm),
    .b_neg(cn), .b_bad(cb), .b_exp(ce), .b_mant(cm),
    .o_neg(s0n), .o_bad(s0b), .o_exp(s0e), .o_mant(s0m));
  p2_fp_swamp #(.MW(24), .SAT(1'b1)) u_ss (.i_neg(s0n), .i_bad(s0b), .i_exp(s0e), .i_mant(s0m),
    .o_neg(srn), .o_bad(srb), .o_exp(sre), .o_mant(srm));

  always_ff @(posedge clk) begin
    out_v    <= in_v;
    sw_neg   <= sn;   sw_bad  <= sb;   sw_exp  <= se;   sw_mant  <= sm;
    sat_neg  <= tn;   sat_bad <= tb;   sat_exp <= te;   sat_mant <= tm;
    det_neg  <= wn;   det_bad <= wb;   det_exp <= we;   det_mant <= wm;
    st_neg   <= {srn, frn, dypn, dxpn, dysn, dxsn, cn};
    st_bad   <= {srb, frb, dypb, dxpb, dysb, dxsb, cb};
    st_exp   <= {sre, fre, dype, dxpe, dyse, dxse, ce};
    st_mant  <= {srm, frm, dypm, dxpm, dysm, dxsm, cm};
  end
endmodule
