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
//   INTERP (3 substages, 10 planes in ||):
//     i1 : ddx*x , ddy*y                       (fp_mul_i5)
//     i2 : ddx*x + ddy*y + c                    (fp_add3_24, fused 3-way: 1 stage)
//     i3 : * W  -> attr[0..9]                   (fp_mul16)
//   UV   : attr(U,V) -> 4 texel corners + frac  (tex_uvmap)  ; pack base/ofs
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
    // FLOW CONTROL. The front (RCP..UV) is a rigid fixed-latency block gated by one
    // clock-enable `en`. The TEX stage is now a set of STREAMING fetchers over the
    // pipelined tex_cache_4p: they accept a pixel every cycle and only deassert
    // in_ready during a genuine cache miss-fill. So the ONLY stall source is a texture
    // cache miss - `en` freezes the whole front while a textured UV-stage pixel cannot
    // be accepted by the fetchers. Non-textured pixels never stall.
    //
    // The variable fetch latency is absorbed by carrying the per-pixel FILT payload in
    // an in-order FIFO (pl_*), popped when the fetchers emit a result (tf_ov). FILT and
    // downstream advance on tf_ov, decoupled from the front's `en`.
    // ==============================================================
    wire [3:0] tf_ready;              // per-corner "can accept" (== cache ready)
    wire       fetch_ready = &tf_ready;
    // stall the front only when a TEXTURED UV pixel is waiting and the fetch can't take
    // it. (vU/U_ptx defined in the UV stage below.)
    wire       uv_wants_fetch;        // = vU (forward ref; assigned in UV stage)
    wire       rf_room;               // corner result FIFOs have space (forward ref)
    wire       pl_room;               // payload FIFO has space (forward ref)
    assign stall = uv_wants_fetch && (!fetch_ready || !rf_room || !pl_room);
    wire en = ~stall;                 // front pipeline clock-enable

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

    // RCP latency realignment: everything else is delayed by RCPLAT to arrive
    // with rc_W. The three WIDE arrays (ddx/ddy/c, 10 planes x 32b = 960 FF each
    // as a flop chain) are carried in M10K delay lines instead of ALM registers.
    // The narrow scalars stay as a plain flop shift chain - too shallow/small to
    // benefit from block RAM, and mixing them in would only add addressing logic.
    localparam RCPLAT = 3;

    // --- wide operands via M10K delay lines (packed 10 x 32b per line) ---
    wire [319:0] q_ddx, q_ddy, q_c;   // RCP-aligned, == d_*[RCPLAT-1] of old chain
    wire [319:0] in_ddx_p, in_ddy_p, in_c_p;
    genvar pk;
    generate
      for (pk=0; pk<10; pk=pk+1) begin : pack
        assign in_ddx_p[pk*32 +: 32] = in_ddx[pk];
        assign in_ddy_p[pk*32 +: 32] = in_ddy[pk];
        assign in_c_p  [pk*32 +: 32] = in_c[pk];
      end
    endgenerate
    delay_ram #(.WIDTH(320),.DELAY(RCPLAT)) u_dl_ddx (.clk(clk),.reset(reset),.en(en),.din(in_ddx_p),.dout(q_ddx));
    delay_ram #(.WIDTH(320),.DELAY(RCPLAT)) u_dl_ddy (.clk(clk),.reset(reset),.en(en),.din(in_ddy_p),.dout(q_ddy));
    delay_ram #(.WIDTH(320),.DELAY(RCPLAT)) u_dl_c   (.clk(clk),.reset(reset),.en(en),.din(in_c_p),  .dout(q_c));
    // per-plane aligned views (replace old d_ddx[RCPLAT-1][gi] etc.)
    wire [31:0] rcp_ddx [0:9];
    wire [31:0] rcp_ddy [0:9];
    wire [31:0] rcp_c   [0:9];
    generate
      for (pk=0; pk<10; pk=pk+1) begin : unpack
        assign rcp_ddx[pk] = q_ddx[pk*32 +: 32];
        assign rcp_ddy[pk] = q_ddy[pk*32 +: 32];
        assign rcp_c[pk]   = q_c  [pk*32 +: 32];
      end
    endgenerate

    // --- narrow scalars: plain flop shift chain (unchanged) ---
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
            d_px[0]<=px; d_py[0]<=py; d_tsp[0]<=tsp; d_tcw[0]<=tcw; d_tc[0]<=text_ctrl;
            d_ptx[0]<=pp_texture; d_pof[0]<=pp_offset; d_id[0]<=in_id;
            for (s=1;s<RCPLAT;s=s+1) begin
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
    // STAGE INTERP: 10 planes, 3 substages. attr = (ddx*x + ddy*y + c) * W
    // ==============================================================
    // i1: products (ddx*x, ddy*y), carry c/W;  i2 (FUSED 3-way add): ddx*x+ddy*y+c;
    // i3: *W -> attr. The old separate i2(+)/i3(+c) stages are folded into one
    // fp_add3_24 (single align+normalize) -> one fewer interp substage.
    reg [31:0] i1_prx [0:9], i1_pry [0:9];   // ddx*x, ddy*y
    reg [31:0] i1_c   [0:9], i1_W;
    reg [31:0] i2_sum [0:9], i2_W;           // fused sum (x+y+c), W carried
    reg [31:0] i3_attr[0:9];                 // sum*W (was i4_attr)
    // valid + payload shift through the 3 interp substages
    reg        v1,v2,v3;
    reg [4:0]  px1,px2,px3, py1,py2,py3;
    reg [31:0] tsp1,tsp2,tsp3, tcw1,tcw2,tcw3;
    reg [4:0]  tcc1,tcc2,tcc3;
    reg        ptx1,ptx2,ptx3, pof1,pof2,pof3;
    reg [IDW-1:0] id1,id2,id3;

    // combinational units per plane, driven by the appropriate stage regs
    wire [31:0] mprx [0:9], mpry [0:9];       // ddx*x, ddy*y (i1 inputs)
    wire [31:0] asum3[0:9];                   // i2: prx+pry+c (fused 3-way)
    wire [31:0] mattr[0:9];                   // i3: sum3 * W
    generate
      for (gi=0; gi<10; gi=gi+1) begin : plane
        // i1: RCP-aligned planes * pixel coord
        fp_mul_i5 mx (.f(rcp_ddx[gi]), .k(rc_px), .y(mprx[gi]));
        fp_mul_i5 my (.f(rcp_ddy[gi]), .k(rc_py), .y(mpry[gi]));
        // i2: fused (ddx*x) + (ddy*y) + c in one align/normalize
        fp_add3_24 a23 (.a(i1_prx[gi]), .b(i1_pry[gi]), .c(i1_c[gi]), .y(asum3[gi]));
        // i3: sum3 * W
        fp_mul16 m4 (.a(i2_sum[gi]), .b(i2_W), .y(mattr[gi]));
      end
    endgenerate

    // ==============================================================
    // MIP LEVEL (exponent-domain LOD). refsw:
    //   ddx = U.ddx + V.ddx ; ddy = U.ddy + V.ddy
    //   dMip = min(|ddx|,|ddy|) * W * sizeU * MipMapD/4 ; sizeU = 8<<TexU
    //   MipLevel = #halvings until dMip<=1.5, clamped 0..11
    // We approximate in the exponent domain (cheap, ~+/-1 level near boundaries):
    //   log2(dMip) ~= (e_min-127) + (e_W-127) + (3+TexU) + (log2(MipMapD)-2)
    //   e_x = biased exponent (f[30:23]); sum of two floats approximated by the
    //   larger exponent. MipLevel = clamp(round(log2(dMip)), 0, TexU+3).
    // Computed off the RCP-aligned planes (plane 0 = U, plane 1 = V) and rc_W.
    // ==============================================================
    wire [3:0] mip_lvl;
    tsp_miplevel u_mip (
        .ddxU(rcp_ddx[0]), .ddxV(rcp_ddx[1]),
        .ddyU(rcp_ddy[0]), .ddyV(rcp_ddy[1]),
        .w(rc_W),
        .texu(d_tsp[RCPLAT-1][5:3]), .mipmapd(d_tsp[RCPLAT-1][11:8]),
        .mipmapped(d_tcw[RCPLAT-1][31]),
        .miplevel(mip_lvl));

    // carry the computed mip level through the interp substages to the UV/TEX stage
    reg [3:0] mip1, mip2, mip3;

    always @(posedge clk) begin
        if (reset) begin v1<=0;v2<=0;v3<=0; end
        else if (en) begin
            // i1: capture products; carry c and W
            for (k=0;k<10;k=k+1) begin
                i1_prx[k]<=mprx[k]; i1_pry[k]<=mpry[k]; i1_c[k]<=rcp_c[k];
            end
            i1_W<=rc_W; v1<=rc_ov; mip1<=mip_lvl;
            px1<=rc_px; py1<=rc_py; tsp1<=d_tsp[RCPLAT-1]; tcw1<=d_tcw[RCPLAT-1];
            tcc1<=d_tc[RCPLAT-1]; ptx1<=d_ptx[RCPLAT-1]; pof1<=d_pof[RCPLAT-1];
            id1<=d_id[RCPLAT-1];

            // i2 (FUSED): prx+pry+c in one step; carry W
            for (k=0;k<10;k=k+1) i2_sum[k]<=asum3[k];
            i2_W<=i1_W; v2<=v1; mip2<=mip1;
            px2<=px1;py2<=py1;tsp2<=tsp1;tcw2<=tcw1;tcc2<=tcc1;ptx2<=ptx1;pof2<=pof1;id2<=id1;

            // i3: sum3 * W -> attr
            for (k=0;k<10;k=k+1) i3_attr[k]<=mattr[k];
            v3<=v2; mip3<=mip2;
            px3<=px2;py3<=py2;tsp3<=tsp2;tcw3<=tcw2;tcc3<=tcc2;ptx3<=ptx2;pof3<=pof2;id3<=id2;
        end
    end

    // ==============================================================
    // STAGE UV: attr(U,V) -> corners + fracs; pack base/offset colours
    // ==============================================================
    wire [2:0] u_texv=tsp3[2:0], u_texu=tsp3[5:3];
    wire u_clampv=tsp3[15],u_clampu=tsp3[16],u_flipv=tsp3[17],u_flipu=tsp3[18];
    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v; wire [7:0] ufr,vfr;
    tex_uvmap u_uv (
        .u(i3_attr[0]), .v(i3_attr[1]), .texu(u_texu), .texv(u_texv),
        .miplevel(mip3),
        .clampu(u_clampu),.clampv(u_clampv),.flipu(u_flipu),.flipv(u_flipv),
        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),
        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(ufr),.vfrac(vfr));

    // float -> u8 per colour/offset channel (planes 2..9), shared f2u8 module.
    wire [7:0] u8a [2:9];
    generate
      for (gi = 2; gi <= 9; gi = gi + 1) begin : cvt
        f2u8 u_c (.f(i3_attr[gi]), .u(u8a[gi]));
      end
    endgenerate

    // UV-stage registers
    reg        vU;
    reg [10:0] U00u,U00v,U01u,U01v,U10u,U10v,U11u,U11v; reg [7:0] Uuf,Uvf;
    reg [31:0] U_base, U_ofs, U_tsp, U_tcw; reg [4:0] U_tc;
    reg        U_ptx, U_pof; reg [IDW-1:0] U_id; reg [3:0] U_mip;
    always @(posedge clk) begin
        if (reset) vU<=0;
        else if (en) begin
            vU<=v3;
            U00u<=c00u;U00v<=c00v;U01u<=c01u;U01v<=c01v;
            U10u<=c10u;U10v<=c10v;U11u<=c11u;U11v<=c11v;Uuf<=ufr;Uvf<=vfr;
            U_base<={u8a[5],u8a[4],u8a[3],u8a[2]};
            U_ofs <={u8a[9],u8a[8],u8a[7],u8a[6]};
            U_tsp<=tsp3; U_tcw<=tcw3; U_tc<=tcc3; U_ptx<=ptx3; U_pof<=pof3; U_id<=id3;
            U_mip<=mip3;
        end
    end


`ifndef SYNTHESIS
    // -------- tex_uvmap VECTOR DUMP (sim only) -------------------------------------
    // One line per accepted textured pixel at the UV stage. Captures the tex_uvmap
    // INPUTS (interpolated U/V float, texu/texv/mip, clamp/flip) and its OUTPUTS (the 4
    // bilinear corner texel coords + ufrac/vfrac). This is a complete, self-contained
    // regression vector for tex_uvmap: given the inputs, tex_uvmap must reproduce
    // the corners+fracs. Enabled with +uvdump[=<file>] (default uv_vectors.log).
    //   fields: seq id attrU attrV tsp tcw mip ptx  c00u c00v c01u c01v c10u c10v c11u c11v ufrac vfrac
    integer      uvd_fd = 0;
    reg          uvd_en = 1'b0;
    reg [1023:0] uvd_name;
    integer      uvd_seq = 0;
    initial begin
        if ($value$plusargs("uvdump=%s", uvd_name)) uvd_en = 1'b1;
        else if ($test$plusargs("uvdump")) begin uvd_en = 1'b1; uvd_name = "uv_vectors.log"; end
        if (uvd_en) begin
            uvd_fd = $fopen(uvd_name, "w");
            $fwrite(uvd_fd, "# tex_uvmap vectors: one line per accepted textured pixel\n");
            $fwrite(uvd_fd, "# seq id attrU attrV tsp tcw mip ptx c00u c00v c01u c01v c10u c10v c11u c11v ufrac vfrac\n");
        end
    end
    always @(posedge clk) begin
        if (!reset && uvd_en && v3 && en && ptx3) begin
            $fwrite(uvd_fd, "%0d %0d %08x %08x %08x %08x %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    uvd_seq, id3, i3_attr[0], i3_attr[1], tsp3, tcw3, mip3, ptx3,
                    c00u, c00v, c01u, c01v, c10u, c10v, c11u, c11v, ufr, vfr);
            uvd_seq = uvd_seq + 1;
        end
    end
    final if (uvd_en && uvd_fd != 0) begin
        $fflush(uvd_fd); $fclose(uvd_fd);
        $display("[tsp_shade_pp] tex_uvmap vectors: %0d pixels -> %0s", uvd_seq, uvd_name);
    end
`endif

    // ==============================================================
    // STAGE TEX: 4 STREAMING tex_fetch_pp (one per bilinear corner). Every valid UV
    // pixel is presented as a request; the fetchers accept it when the shared cache is
    // ready (fetch_ready) and the front advances (en) on that same accept. Results
    // stream out later (tf_ov) IN ORDER; the per-pixel FILT payload rides an in-order
    // FIFO (pl_*) popped on tf_ov so it re-aligns with the arriving texels.
    // ==============================================================
    wire tex_start = vU & en;                    // a pixel is issued to the fetchers
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
        // The 4 corner fetchers are now a FIXED-LATENCY pipeline over the 1-cycle cache
        // (tex_cache_4p_1c), which freezes ALL 4 ports together on a miss-fill. All four
        // therefore run in perfect lockstep and emit tf_ov SIMULTANEOUSLY, in issue order.
        // No per-corner reordering is possible, so out_ready is tied high (no back-pressure)
        // and the corner-join is a plain simultaneous capture (below).
        tex_fetch_pp u_tf (
            .clk(clk),.reset(reset),
            .in_valid(tex_start),.in_textured(U_ptx),.in_ready(tf_ready[gi]),
            .u(cu[gi]),.v(cv[gi]),.miplevel(U_mip),
            .tsp(U_tsp),.tcw(U_tcw),.text_ctrl(U_tc),
            .out_ready(1'b1),
            .out_valid(tf_ov[gi]),.argb(tf_argb[gi]),
            .tc_req(tc_req[gi]),.tc_resp(tc_resp[gi]),
            .vq_req(vq_req[gi]),.vq_resp(vq_resp[gi]));
      end
    endgenerate
    assign uv_wants_fetch = vU;                  // any valid UV pixel needs a fetch slot

    // ---- CORNER JOIN (lockstep): all 4 corners emit the same cycle (tf_ov[0..3] identical),
    // in issue order, so the four texels this cycle belong to ONE pixel. No FIFO / no
    // back-pressure - just take the 4 argb directly. res_v = the (shared) emit strobe. ----
    wire res_v = tf_ov[0];
    assign rf_room = 1'b1;                        // no corner FIFO -> never a room stall
    wire [31:0] cj0 = tf_argb[0];
    wire [31:0] cj1 = tf_argb[1];
    wire [31:0] cj2 = tf_argb[2];
    wire [31:0] cj3 = tf_argb[3];

    // ---- in-order FILT payload FIFO: pushed on issue (tex_start), popped on result
    //      (tf_ov[0]; all 4 corners' out_valid are identical since lockstep). ----
    localparam integer PLW = 32+32+32+5+1+1+8+8+IDW;  // base,ofs,tsp,tc,ptx,pof,uf,vf,id
    wire [PLW-1:0] pl_in = { U_base, U_ofs, U_tsp, U_tc, U_ptx, U_pof, Uuf, Uvf, U_id };
    // Depth must cover the WHOLE fetch in-flight window (worst case VQ: tc + vp + vq
    // FIFOs in series + cache/decode latency, ~50), else the payload wraps and ids
    // misalign with texels. 64 + a room gate on the front keeps it safe.
    localparam integer PLD = 64, PLAW = 6;
    reg  [PLW-1:0] plf [0:PLD-1];
    reg  [PLAW-1:0] pl_h, pl_t; reg [PLAW:0] pl_cnt;
    wire pl_push = tex_start;
    wire pl_pop  = res_v;                // pop payload when the corner-join completes
    wire [PLW-1:0] pl_out = plf[pl_h];
    assign pl_room = (pl_cnt < PLD-4);   // headroom for in-flight issues
    always @(posedge clk) begin
        if (reset) begin pl_h<=0; pl_t<=0; pl_cnt<=0; end
        else begin
            if (pl_push) begin plf[pl_t] <= pl_in; pl_t <= pl_t + 1'b1; end
            if (pl_pop)  pl_h <= pl_h + 1'b1;
            pl_cnt <= pl_cnt + (pl_push?1:0) - (pl_pop?1:0);
        end
    end
    // unpack the popped payload (aligned with tf_argb this cycle)
    wire [31:0]    P_base = pl_out[PLW-1              -: 32];
    wire [31:0]    P_ofs  = pl_out[PLW-1-32           -: 32];
    wire [31:0]    P_tsp  = pl_out[PLW-1-64           -: 32];
    wire [4:0]     P_tc   = pl_out[PLW-1-96           -: 5];
    wire           P_ptx  = pl_out[PLW-1-101];
    wire           P_pof  = pl_out[PLW-1-102];
    wire [7:0]     P_uf   = pl_out[PLW-1-103          -: 8];
    wire [7:0]     P_vf   = pl_out[PLW-1-111          -: 8];
    wire [IDW-1:0] P_id   = pl_out[IDW-1              : 0];

    // ==============================================================
    // STAGE T: CAPTURE the 4 corner texels + the popped payload the cycle a fetch
    // result arrives (res_v). This registered capture avoids a same-cycle cross-block
    // read of the fetcher's registered argb outputs (which races the filter's
    // combinational recompute). Everything downstream reads these T_* regs.
    // ==============================================================
    reg        vT;
    reg [31:0] T_c0,T_c1,T_c2,T_c3;
    reg [31:0] T_base,T_ofs,T_tsp; reg [7:0] T_uf,T_vf;
    reg        T_ptx,T_pof; reg [IDW-1:0] T_id;
    always @(posedge clk) begin
        if (reset) vT<=0;
        else begin
            vT <= res_v;
            if (res_v) begin
                T_c0<=cj0; T_c1<=cj1; T_c2<=cj2; T_c3<=cj3;
                T_base<=P_base; T_ofs<=P_ofs; T_tsp<=P_tsp; T_uf<=P_uf; T_vf<=P_vf;
                T_ptx<=P_ptx; T_pof<=P_pof; T_id<=P_id;
            end
        end
    end

    // ==============================================================
    // STAGE FILT: bilinear/nearest blend from the captured T_* regs.
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
        else begin
            vF <= vT;
            if (vT) begin
                F_textel <= T_ptx ? t_filt : 32'h00000000;
                F_base<=T_base; F_ofs<=T_ofs; F_tsp<=T_tsp;
                T_ptx_r<=T_ptx; T_pof_r<=T_pof; F_id<=T_id;
            end
        end
    end

    // ==============================================================
    // STAGE COMB: texenv + offset -> ARGB
    // ==============================================================
    wire [1:0] c_shad = F_tsp[7:6];
    wire [31:0] comb_col;
    color_combiner u_cc (.pp_texture(T_ptx_r),.pp_offset(T_pof_r),.shadinstr(c_shad),
                         .base(F_base),.textel(F_textel),.offset(F_ofs),.col(comb_col));
`ifndef SYNTHESIS
    // -------- OUTPUT-side dump: emitted (id, argb) IN OUTPUT ORDER. Compared against the
    // UV-stage input dump's id sequence to detect any miss/hit-timing REORDER or offset:
    // for an in-order pipeline out_id[k] must equal the k-th issued id. A mismatch means
    // a cache-miss delay offset a texel/payload against the wrong pixel. Same +uvdump gate.
    integer      ovd_fd = 0;
    reg          ovd_en = 1'b0;
    reg [1023:0] ovd_name;
    integer      ovd_seq = 0;
    initial begin
        if ($value$plusargs("uvdump=%s", ovd_name)) begin ovd_en=1'b1; ovd_name="uv_out.log"; end
        else if ($test$plusargs("uvdump")) begin ovd_en=1'b1; ovd_name="uv_out.log"; end
        if (ovd_en) begin
            ovd_fd = $fopen(ovd_name, "w");
            $fwrite(ovd_fd, "# out order: seq out_id out_argb (ptx bit of the pixel)\n");
        end
    end
    always @(posedge clk) begin
        if (!reset && ovd_en && vF) begin
            $fwrite(ovd_fd, "%0d %0d %08x %0d\n", ovd_seq, F_id, comb_col, T_ptx_r);
            ovd_seq = ovd_seq + 1;
        end
    end
    final if (ovd_en && ovd_fd != 0) begin
        $fflush(ovd_fd); $fclose(ovd_fd);
        $display("[tsp_shade_pp] output-order dump: %0d pixels -> %0s", ovd_seq, ovd_name);
    end
`endif

    // COMB advances on vF (a FILT result), decoupled from the front's `en`.
    always @(posedge clk) begin
        if (reset) out_valid<=0;
        else begin
            out_valid <= vF;
            if (vF) begin
                out_argb <=comb_col;
                out_id   <=F_id;
                out_tsp  <=F_tsp;   // aligned with out_argb (blend in the caller)
            end
        end
    end
endmodule
