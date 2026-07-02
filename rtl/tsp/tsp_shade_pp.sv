//
// tsp_shade_pp - FULLY PIPELINED per-pixel TSP shading (1 pixel/clock).
//
// Same math as tsp_shade, but every stage runs concurrently so one pixel enters
// and one result leaves per clock (after the fixed fill latency), except when a
// texture cache miss stalls the whole pipe.
//
// Per-stage convention (as requested):
//   - clk
//   - inputs buffered (caller holds them stable when in_valid)
//   - outputs buffered
//   - in_valid bit -> propagates to out_valid bit
// Stages are glued with registers; a single global STALL freezes every stage's
// registers together when any of the 4 parallel texel fetchers is still working.
//
// Stages (fill latency ~ 3 + 4 + 1 + Ttex + 1 + 1):
//   RCP  : W = 1/invW                         (fp_rcp_fast, 3 clocks)
//   INTERP (4 substages, 10 planes in ||):
//     i1 : ddx*x , ddy*y                       (fp_mul_i5)
//     i2 : + (ddx*x + ddy*y)                    (fp_add24)
//     i3 : + c                                  (fp_add24)
//     i4 : * W  -> attr[0..9]                   (fp_mul16)
//   UV   : attr(U,V) -> 4 texel corners + frac  (tex_uv2texel)  ; pack base/ofs
//   TEX  : 4 || tex_fetch_pp (t00,t01,t10,t11)  ; STALLS on cache miss
//   FILT : bilinear/nearest blend               (tex_filter)
//   COMB : texenv + offset                       (color_combiner)
//
// The 10 interpolation planes, tsp/tcw/text_ctrl/pp_* are per-pixel (a pixel may
// belong to a different triangle than its neighbour), so they flow through the
// pipeline alongside the data - not held as module-global config.
//
// 4 texel caches are INJECTED (one tc/vq pair per corner). The caller wires 8
// tex_cache instances (4 corners x {data, VQ}).
//
module tsp_shade_pp import tsp_pkg::*; #(
    parameter integer IDW = 10            // width of the pass-through pixel id
) (
    input             clk,
    input             reset,

    // ---- input pixel (buffered by caller; consumed when in_valid && !stall) ----
    input             in_valid,
    input      [IDW-1:0] in_id,           // opaque tag echoed on the output
    input      [4:0]  px,
    input      [4:0]  py,
    input      [31:0] invw_in,
    input      [31:0] in_ddx [0:9],
    input      [31:0] in_ddy [0:9],
    input      [31:0] in_c   [0:9],
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    input             pp_texture,
    input             pp_offset,

    // ---- output ----
    output reg           out_valid,
    output reg [IDW-1:0] out_id,
    output reg [31:0]    out_argb,
    output reg [31:0]    out_tsp,        // pixel's TSP word (SrcInstr/DstInstr for blend)

    // ---- caller sees stall so it can hold the input stable ----
    output            stall,

    // ---- injected caches: 4 corners x {data, VQ} ----
    output cache_req_t   tc_req [0:3],
    input  cache_resp_t  tc_resp [0:3],
    output cache_req_t   vq_req [0:3],
    input  cache_resp_t  vq_resp [0:3]
);
    genvar gi;

    // ==============================================================
    // global stall: any texel fetcher busy freezes the whole pipe.
    // ==============================================================
    wire [3:0] tf_busy;
    assign stall = |tf_busy;
    wire en = ~stall;                 // pipeline clock-enable

    // ==============================================================
    // helper: per-pixel config bundle that rides through the pipe
    // (10 planes are handled specially; scalars packed here)
    // ==============================================================
    // tsp fields used downstream
    function [31:0] passthru; input dummy; passthru=0; endfunction

    // ==============================================================
    // STAGE RCP: W = 1/invW (fp_rcp_fast, 3 clocks). Everything else is
    // delayed by 3 to stay aligned.
    // ==============================================================
    wire        rc_ov; wire [31:0] rc_W;
    fp_rcp_fast u_rc (.clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid & en),
                      .x(invw_in),.out_valid(rc_ov),.y(rc_W));

    // 3-deep shift regs for the operands that must arrive with rc_W
    localparam RCPLAT = 3;
    reg [31:0] d_ddx [0:RCPLAT-1][0:9];
    reg [31:0] d_ddy [0:RCPLAT-1][0:9];
    reg [31:0] d_c   [0:RCPLAT-1][0:9];
    reg [4:0]  d_px  [0:RCPLAT-1];
    reg [4:0]  d_py  [0:RCPLAT-1];
    reg [31:0] d_tsp [0:RCPLAT-1];
    reg [31:0] d_tcw [0:RCPLAT-1];
    reg [4:0]  d_tc  [0:RCPLAT-1];
    reg        d_ptx [0:RCPLAT-1];
    reg        d_pof [0:RCPLAT-1];
    reg [IDW-1:0] d_id[0:RCPLAT-1];

    integer s, k;
    always @(posedge clk) begin
        if (en) begin
            // stage 0 samples the module inputs
            for (k=0;k<10;k=k+1) begin
                d_ddx[0][k]<=in_ddx[k]; d_ddy[0][k]<=in_ddy[k]; d_c[0][k]<=in_c[k];
            end
            d_px[0]<=px; d_py[0]<=py; d_tsp[0]<=tsp; d_tcw[0]<=tcw; d_tc[0]<=text_ctrl;
            d_ptx[0]<=pp_texture; d_pof[0]<=pp_offset; d_id[0]<=in_id;
            for (s=1;s<RCPLAT;s=s+1) begin
                for (k=0;k<10;k=k+1) begin
                    d_ddx[s][k]<=d_ddx[s-1][k]; d_ddy[s][k]<=d_ddy[s-1][k]; d_c[s][k]<=d_c[s-1][k];
                end
                d_px[s]<=d_px[s-1]; d_py[s]<=d_py[s-1]; d_tsp[s]<=d_tsp[s-1];
                d_tcw[s]<=d_tcw[s-1]; d_tc[s]<=d_tc[s-1];
                d_ptx[s]<=d_ptx[s-1]; d_pof[s]<=d_pof[s-1]; d_id[s]<=d_id[s-1];
            end
        end
    end
    // aliases for the RCP-aligned values (stage RCPLAT-1)
    wire [4:0]  rc_px = d_px[RCPLAT-1];
    wire [4:0]  rc_py = d_py[RCPLAT-1];

    // ==============================================================
    // STAGE INTERP: 10 planes, 4 substages. attr = (ddx*x+ddy*y+c)*W
    // ==============================================================
    // i1 regs: products; i2: +; i3: +c; i4: *W -> attr
    reg [31:0] i1_prx [0:9], i1_pry [0:9];   // ddx*x, ddy*y
    reg [31:0] i1_c   [0:9], i1_W;
    reg [31:0] i2_sum [0:9], i2_c [0:9], i2_W;
    reg [31:0] i3_sum [0:9], i3_W;
    reg [31:0] i4_attr[0:9];
    // valid + payload shift through the 4 interp substages
    reg        v1,v2,v3,v4;
    reg [4:0]  px1,px2,px3,px4, py1,py2,py3,py4;
    reg [31:0] tsp1,tsp2,tsp3,tsp4, tcw1,tcw2,tcw3,tcw4;
    reg [4:0]  tcc1,tcc2,tcc3,tcc4;
    reg        ptx1,ptx2,ptx3,ptx4, pof1,pof2,pof3,pof4;
    reg [IDW-1:0] id1,id2,id3,id4;

    // combinational units per plane, driven by the appropriate stage regs
    wire [31:0] mprx [0:9], mpry [0:9];       // ddx*x, ddy*y (i1 inputs)
    wire [31:0] asum [0:9];                   // i2: prx+pry
    wire [31:0] asc  [0:9];                   // i3: sum + c
    wire [31:0] mattr[0:9];                   // i4: sum3 * W
    generate
      for (gi=0; gi<10; gi=gi+1) begin : plane
        // i1: RCP-aligned planes * pixel coord
        fp_mul_i5 mx (.f(d_ddx[RCPLAT-1][gi]), .k(rc_px), .y(mprx[gi]));
        fp_mul_i5 my (.f(d_ddy[RCPLAT-1][gi]), .k(rc_py), .y(mpry[gi]));
        // i2: prx + pry
        fp_add24 a2 (.a(i1_prx[gi]), .b_in(i1_pry[gi]), .sub(1'b0), .y(asum[gi]));
        // i3: sum + c
        fp_add24 a3 (.a(i2_sum[gi]), .b_in(i2_c[gi]),   .sub(1'b0), .y(asc[gi]));
        // i4: sum3 * W
        fp_mul16 m4 (.a(i3_sum[gi]), .b(i3_W), .y(mattr[gi]));
      end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin v1<=0;v2<=0;v3<=0;v4<=0; end
        else if (en) begin
            // i1: capture products; carry c and W
            for (k=0;k<10;k=k+1) begin
                i1_prx[k]<=mprx[k]; i1_pry[k]<=mpry[k]; i1_c[k]<=d_c[RCPLAT-1][k];
            end
            i1_W<=rc_W; v1<=rc_ov;
            px1<=rc_px; py1<=rc_py; tsp1<=d_tsp[RCPLAT-1]; tcw1<=d_tcw[RCPLAT-1];
            tcc1<=d_tc[RCPLAT-1]; ptx1<=d_ptx[RCPLAT-1]; pof1<=d_pof[RCPLAT-1];
            id1<=d_id[RCPLAT-1];

            // i2: prx+pry; carry c, W
            for (k=0;k<10;k=k+1) begin i2_sum[k]<=asum[k]; i2_c[k]<=i1_c[k]; end
            i2_W<=i1_W; v2<=v1;
            px2<=px1;py2<=py1;tsp2<=tsp1;tcw2<=tcw1;tcc2<=tcc1;ptx2<=ptx1;pof2<=pof1;id2<=id1;

            // i3: sum + c; carry W
            for (k=0;k<10;k=k+1) i3_sum[k]<=asc[k];
            i3_W<=i2_W; v3<=v2;
            px3<=px2;py3<=py2;tsp3<=tsp2;tcw3<=tcw2;tcc3<=tcc2;ptx3<=ptx2;pof3<=pof2;id3<=id2;

            // i4: sum3 * W -> attr
            for (k=0;k<10;k=k+1) i4_attr[k]<=mattr[k];
            v4<=v3;
            px4<=px3;py4<=py3;tsp4<=tsp3;tcw4<=tcw3;tcc4<=tcc3;ptx4<=ptx3;pof4<=pof3;id4<=id3;
        end
    end

    // ==============================================================
    // STAGE UV: attr(U,V) -> corners + fracs; pack base/offset colours
    // ==============================================================
    wire [2:0] u_texv=tsp4[2:0], u_texu=tsp4[5:3];
    wire u_clampv=tsp4[15],u_clampu=tsp4[16],u_flipv=tsp4[17],u_flipu=tsp4[18];
    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v; wire [7:0] ufr,vfr;
    tex_uv2texel u_uv (
        .u(i4_attr[0]), .v(i4_attr[1]), .texu(u_texu), .texv(u_texv),
        .clampu(u_clampu),.clampv(u_clampv),.flipu(u_flipu),.flipv(u_flipv),
        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),
        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(ufr),.vfrac(vfr));

    // float -> u8 per colour/offset channel (planes 2..9), shared f2u8 module.
    wire [7:0] u8a [2:9];
    generate
      for (gi = 2; gi <= 9; gi = gi + 1) begin : cvt
        f2u8 u_c (.f(i4_attr[gi]), .u(u8a[gi]));
      end
    endgenerate

    // UV-stage registers
    reg        vU;
    reg [10:0] U00u,U00v,U01u,U01v,U10u,U10v,U11u,U11v; reg [7:0] Uuf,Uvf;
    reg [31:0] U_base, U_ofs, U_tsp, U_tcw; reg [4:0] U_tc;
    reg        U_ptx, U_pof; reg [IDW-1:0] U_id;
    always @(posedge clk) begin
        if (reset) vU<=0;
        else if (en) begin
            vU<=v4;
            U00u<=c00u;U00v<=c00v;U01u<=c01u;U01v<=c01v;
            U10u<=c10u;U10v<=c10v;U11u<=c11u;U11v<=c11v;Uuf<=ufr;Uvf<=vfr;
            U_base<={u8a[5],u8a[4],u8a[3],u8a[2]};
            U_ofs <={u8a[9],u8a[8],u8a[7],u8a[6]};
            U_tsp<=tsp4; U_tcw<=tcw4; U_tc<=tcc4; U_ptx<=ptx4; U_pof<=pof4; U_id<=id4;
        end
    end

    // ==============================================================
    // STAGE TEX: 4 parallel tex_fetch_pp. They accept a request when the
    // UV stage presents a valid textured pixel (vU && U_ptx) that has not yet
    // been issued. While any is busy, `stall` is asserted (freezing all pipe
    // regs), so the request lines stay stable and no new UV pixel advances.
    //
    // tex_issued tracks that the current UV-stage pixel's fetch has already been
    // launched, so we don't re-issue it on the completion cycle (when the pipe
    // briefly un-stalls but the same pixel is still in the UV register).
    // ==============================================================
    reg tex_issued;
    wire tex_start = vU & U_ptx & ~tex_issued;   // launch a fetch this clock
    wire [31:0] tf_argb [0:3];
    wire [3:0]  tf_ov;
    // corner (u,v) select per fetcher
    wire [10:0] cu [0:3], cv [0:3];
    assign cu[0]=U00u; assign cv[0]=U00v;
    assign cu[1]=U01u; assign cv[1]=U01v;
    assign cu[2]=U10u; assign cv[2]=U10v;
    assign cu[3]=U11u; assign cv[3]=U11v;
    generate
      for (gi=0; gi<4; gi=gi+1) begin : tf
        tex_fetch_pp u_tf (
            .clk(clk),.reset(reset),
            .in_valid(tex_start),
            .u(cu[gi]),.v(cv[gi]),
            .tsp(U_tsp),.tcw(U_tcw),.text_ctrl(U_tc),
            .out_valid(tf_ov[gi]),.argb(tf_argb[gi]),.busy(tf_busy[gi]),
            .tc_req(tc_req[gi]),.tc_resp(tc_resp[gi]),
            .vq_req(vq_req[gi]),.vq_resp(vq_resp[gi]));
      end
    endgenerate

    // tex_issued: set when a fetch launches; cleared when the pipe advances
    // (en=1) past this UV pixel. `stall` (=|tf_busy) keeps en=0 until the
    // fetchers finish, so between launch and completion the pipe is frozen.
    always @(posedge clk) begin
        if (reset) tex_issued <= 1'b0;
        else if (tex_start)   tex_issued <= 1'b1;   // launched (during stall)
        else if (en)          tex_issued <= 1'b0;   // advanced to the next pixel
    end

    // TEX-stage output register: capture the 4 corners as the pixel advances.
    // Because the pipe stalls while any fetcher is busy, when en finally rises
    // the fetch results (tf_argb) are valid and the UV payload is still present.
    reg        vT;
    reg [31:0] T_c0,T_c1,T_c2,T_c3;
    reg [31:0] T_base,T_ofs,T_tsp; reg [4:0] T_tc;
    reg        T_ptx,T_pof; reg [7:0] T_uf,T_vf; reg [IDW-1:0] T_id;
    always @(posedge clk) begin
        if (reset) vT<=0;
        else if (en) begin
            vT<=vU;
            T_c0<=tf_argb[0]; T_c1<=tf_argb[1]; T_c2<=tf_argb[2]; T_c3<=tf_argb[3];
            T_base<=U_base; T_ofs<=U_ofs; T_tsp<=U_tsp; T_tc<=U_tc;
            T_ptx<=U_ptx; T_pof<=U_pof; T_uf<=Uuf; T_vf<=Uvf; T_id<=U_id;
        end
    end

    // ==============================================================
    // STAGE FILT: bilinear/nearest blend
    // ==============================================================
    wire [1:0] f_filt = T_tsp[14:13];
    wire       f_bilinear = (f_filt != 2'd0);
    wire       f_ignorea  = T_tsp[19];
    wire [31:0] t_filt;
    tex_filter u_flt (.filter(f_bilinear),.ignore_texa(f_ignorea),
                      .ufrac(T_uf),.vfrac(T_vf),
                      .t00(T_c0),.t01(T_c1),.t10(T_c2),.t11(T_c3),.textel(t_filt));
    reg        vF;
    reg [31:0] F_textel, F_base, F_ofs, F_tsp; reg T_ptx_r, T_pof_r;
    reg [IDW-1:0] F_id;
    always @(posedge clk) begin
        if (reset) vF<=0;
        else if (en) begin
            vF<=vT;
            F_textel <= T_ptx ? t_filt : 32'h00000000;
            F_base<=T_base; F_ofs<=T_ofs; F_tsp<=T_tsp;
            T_ptx_r<=T_ptx; T_pof_r<=T_pof; F_id<=T_id;
        end
    end

    // ==============================================================
    // STAGE COMB: texenv + offset -> ARGB
    // ==============================================================
    wire [1:0] c_shad = F_tsp[7:6];
    wire [31:0] comb_col;
    color_combiner u_cc (.pp_texture(T_ptx_r),.pp_offset(T_pof_r),.shadinstr(c_shad),
                         .base(F_base),.textel(F_textel),.offset(F_ofs),.col(comb_col));
    always @(posedge clk) begin
        if (reset) out_valid<=0;
        else if (en) begin
            out_valid<=vF;
            out_argb <=comb_col;
            out_id   <=F_id;
            out_tsp  <=F_tsp;   // aligned with out_argb (blend unit lives in the caller)
        end
    end
endmodule
