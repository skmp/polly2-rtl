//
// tex_unit - the full texture pipeline: interpolated (float) U/V -> one bilinear-filtered
// ARGB texel. Assembles the 7 texture modules with delay-matched payload lines and the
// fetch backpressure stalling the front.
//
//   tex_uvmap (3)         : float U/V -> 4 corner coords (cu0/cu1/cv0/cv1) + ufrac/vfrac
//   tex_base_addr (comb)  : per-pixel shared addressing (u_log2/stride/twiddled/mip_add/
//                           fbpp_shr/tex_addr/vq_addr + decode config)
//   tex_addroffsgen_ib(1) : 4 corner relative texel offsets
//   tex_add_mip (comb)    : + mip, *fbpp -> 4 byte offsets
//   tex_fetch4_ob (~3,stall): 4 raw 64-bit words (owns the 2 caches)
//   tex_decode x4 (3)     : 4 raw words -> 4 ARGB texels (injected palette, x4 ports)
//   tex_filter (6)        : bilinear/nearest blend -> 1 ARGB texel
//
// STALL: tex_fetch4_ob.in_ready (0 = cache filling) freezes the FRONT (uvmap +
// addroffsgen + the front payload delay lines) via their `stall` inputs. The back half
// (decode/filter) has no stall - it drains on valid (bubbles when the front is frozen).
//
// PALETTE: 4 injected read ports (one per corner decoder), like the 4 cache ports.
//
// NOTE: the payload delay-line depths are documented per line; verify against the actual
// module latencies if any sub-module's pipeline depth changes.
//
module tex_unit import tsp_pkg::*; #(
    parameter integer IDW = 11
) (
    input             clk,
    input             reset,

    // ---- pixel in (float U/V + per-pixel texture config) ----
    input             in_valid,
    input      [IDW-1:0] in_id,
    input      [31:0] u, v,              // interpolated float U/V
    input      [2:0]  texu, texv,
    input      [3:0]  miplevel,
    input             clampu, clampv, flipu, flipv,
    // texture config (decoded named params, forwarded to base_addr/decode/filter)
    input      [20:0] tex_addr_in,       // TCW.TexAddr (word base)
    input             tex,               // textured pixel (0 -> fetch bypass, texel = 0)
    input             vq, scan, stride_sel, mipmapped,
    input      [2:0]  pixfmt,
    input      [1:0]  pal_fmt,
    input      [5:0]  palsel,
    input      [4:0]  text_ctrl,
    input      [1:0]  filter_mode,       // TSP.FilterMode (0 = point)
    input             ignore_texa,

    output            in_ready,          // 0 = stall (fetch cache filling); hold inputs

    // ---- texel out ----
    output            out_valid,
    output     [IDW-1:0] out_id,
    output     [31:0] out_argb,

    // ---- injected palette RAM: 4 read ports (one per corner decoder) ----
    output     [9:0]  pal_addr [0:3],
    input      [31:0] pal_data [0:3],

    // ---- two DDR read ports to the parent arbiter ([0]=tc, [1]=vq) ----
    output ddr_rd_req_t  ddr_req  [0:1],
    input  ddr_rd_resp_t ddr_resp [0:1]
);
    genvar gi;
    integer d;

    // ============================================================================
    // FRONT STALL: the fetch's in_ready gates the whole front.
    // ============================================================================
    wire fetch_ready;                         // tex_fetch4_ob.in_ready
    wire front_stall = ~fetch_ready;
    assign in_ready = fetch_ready;

    // ============================================================================
    // STAGE UVMAP (3 cyc): float U/V -> 4 corner coords + fracs.
    // ============================================================================
    wire        uv_ov;
    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v;
    wire [7:0]  ufr, vfr;
    tex_uvmap u_uv (
        .clk(clk),.reset(reset),.stall(front_stall),.in_valid(in_valid),
        .u(u),.v(v),.texu(texu),.texv(texv),.miplevel(miplevel),
        .clampu(clampu),.clampv(clampv),.flipu(flipu),.flipv(flipv),
        .out_valid(uv_ov),
        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),
        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(ufr),.vfrac(vfr));
    // corners are {cu0,cu1} x {cv0,cv1}: cu1=c00u, cu0=c01u, cv1=c00v, cv0=c11v.
    wire [9:0] cu0 = c01u[9:0], cu1 = c00u[9:0];
    wire [9:0] cv0 = c11v[9:0], cv1 = c00v[9:0];

    // ============================================================================
    // STAGE BASE (comb): per-pixel shared addressing. Fed by the SAME cycle's config
    // (config is per-pixel constant; delayed by UVMAP latency to align with uv_ov).
    // ============================================================================
    // delay the per-pixel config by UVMAP latency (3) so it aligns with uv_ov.
    localparam integer UVLAT = 3;
    reg [20:0] d_texaddr [0:UVLAT-1];
    reg [2:0]  d_texu    [0:UVLAT-1], d_texv [0:UVLAT-1];
    reg [3:0]  d_mip     [0:UVLAT-1];
    reg [2:0]  d_pixfmt  [0:UVLAT-1];
    reg [1:0]  d_palfmt  [0:UVLAT-1];
    reg [5:0]  d_palsel  [0:UVLAT-1];
    reg [4:0]  d_tctrl   [0:UVLAT-1];
    reg [1:0]  d_filt    [0:UVLAT-1];
    reg        d_tex[0:UVLAT-1], d_vq[0:UVLAT-1], d_scan[0:UVLAT-1],
               d_strd[0:UVLAT-1], d_mm[0:UVLAT-1], d_igna[0:UVLAT-1];
    reg [IDW-1:0] d_id [0:UVLAT-1];
    always @(posedge clk) if (!front_stall) begin
        d_texaddr[0]<=tex_addr_in; d_texu[0]<=texu; d_texv[0]<=texv; d_mip[0]<=miplevel;
        d_pixfmt[0]<=pixfmt; d_palfmt[0]<=pal_fmt; d_palsel[0]<=palsel; d_tctrl[0]<=text_ctrl;
        d_filt[0]<=filter_mode; d_tex[0]<=tex; d_vq[0]<=vq; d_scan[0]<=scan;
        d_strd[0]<=stride_sel; d_mm[0]<=mipmapped; d_igna[0]<=ignore_texa; d_id[0]<=in_id;
        for (d=1; d<UVLAT; d=d+1) begin
            d_texaddr[d]<=d_texaddr[d-1]; d_texu[d]<=d_texu[d-1]; d_texv[d]<=d_texv[d-1];
            d_mip[d]<=d_mip[d-1]; d_pixfmt[d]<=d_pixfmt[d-1]; d_palfmt[d]<=d_palfmt[d-1];
            d_palsel[d]<=d_palsel[d-1]; d_tctrl[d]<=d_tctrl[d-1]; d_filt[d]<=d_filt[d-1];
            d_tex[d]<=d_tex[d-1]; d_vq[d]<=d_vq[d-1]; d_scan[d]<=d_scan[d-1];
            d_strd[d]<=d_strd[d-1]; d_mm[d]<=d_mm[d-1]; d_igna[d]<=d_igna[d-1]; d_id[d]<=d_id[d-1];
        end
    end
    localparam integer L = UVLAT-1;          // aligned-with-uv_ov index

    wire [3:0]  bu_log2, bv_log2; wire [10:0] bstride; wire btwiddled;
    wire [23:0] bmip_add; wire [2:0] bfbpp_shr; wire [20:0] btex_addr, bvq_addr;
    wire        bo_scan, bo_vq; wire [2:0] bo_pixfmt; wire [1:0] bo_palfmt; wire [5:0] bo_palsel;
    tex_base_addr u_base (
        .tex_addr_in(d_texaddr[L]),.vq(d_vq[L]),.scan(d_scan[L]),.stride_sel(d_strd[L]),
        .mipmapped(d_mm[L]),.pixfmt(d_pixfmt[L]),.pal_fmt(d_palfmt[L]),.palsel(d_palsel[L]),
        .texu(d_texu[L]),.texv(d_texv[L]),.miplevel(d_mip[L]),.text_ctrl(d_tctrl[L]),
        .u_log2(bu_log2),.v_log2(bv_log2),.stride(bstride),.twiddled(btwiddled),
        .mip_add(bmip_add),.fbpp_shr(bfbpp_shr),.tex_addr(btex_addr),.vq_addr(bvq_addr),
        .o_scan(bo_scan),.o_vq(bo_vq),.o_pixfmt(bo_pixfmt),.o_pal_fmt(bo_palfmt),.o_palsel(bo_palsel));

    // ============================================================================
    // STAGE ADDROFFS (_ib, 1 cyc): 4 corner texel offsets. Fed by uvmap corners + base.
    // ============================================================================
    wire        ao_ov;
    wire [20:0] ao_offset [0:3];
    tex_addroffsgen_ib u_ao (
        .clk(clk),.reset(reset),.stall(front_stall),.in_valid(uv_ov),
        .u_log2(bu_log2),.v_log2(bv_log2),.stride(bstride),.twiddled(btwiddled),
        .u0(cu0),.u1(cu1),.v0(cv0),.v1(cv1),
        .out_valid(ao_ov),.offset(ao_offset),.twiddled_o());

    // mip_add / fbpp_shr / tex_addr / vq_addr / tex / vq must be delayed by ADDROFFS
    // latency (1) to align with ao_offset.
    reg [23:0] a_mip;   reg [2:0] a_fbpp;   reg [20:0] a_texaddr, a_vqaddr;
    reg        a_tex, a_vq;
    // decode config delayed to align at tex_decode (see below); scan for decode is per-pixel.
    always @(posedge clk) if (!front_stall) begin
        a_mip<=bmip_add; a_fbpp<=bfbpp_shr; a_texaddr<=btex_addr; a_vqaddr<=bvq_addr;
        a_tex<=d_tex[L]; a_vq<=bo_vq;
    end

    // ---- OFFSET REGISTER (critical-path cut #1): tex_addroffsgen_ib is input-buffered,
    //      so ALL its combinational logic (part1by1 + mask + tail + mux) is on its OUTPUT
    //      side. Register that output here BEFORE tex_add_mip so the addroffsgen cone and
    //      the add_mip cone are separate clocks. Frozen with the front.
    reg [20:0] r_off [0:3];
    reg [23:0] r1_mip;  reg [2:0] r1_fbpp;
    reg [20:0] r1_texaddr, r1_vqaddr;
    reg        r1_tex, r1_vq, r1_iss;
    always @(posedge clk) begin
        if (reset) r1_iss <= 1'b0;
        else if (!front_stall) begin
            for (d=0; d<4; d=d+1) r_off[d] <= ao_offset[d];
            r1_mip <= a_mip; r1_fbpp <= a_fbpp;
            r1_texaddr <= a_texaddr; r1_vqaddr <= a_vqaddr; r1_tex <= a_tex; r1_vq <= a_vq;
            r1_iss <= ao_ov;
        end
    end

    // ============================================================================
    // STAGE ADDMIP (comb, off the offset register): 4 byte offsets.
    // ============================================================================
    wire [21:0] byte_off [0:3];
    tex_add_mip u_am (.texel_offset(r_off),.mip_add(r1_mip),.fbpp_shr(r1_fbpp),
                      .byte_offset(byte_off));

    // ---- ADDRESS REGISTER (critical-path cut #2): splits add_mip from the cache-read
    //      cone (fetch addr adder -> M10K addr). Frozen with the front (holds the fetch
    //      input stable while !fetch_ready, as the streaming protocol requires).
    reg [21:0] r_boff [0:3];
    reg [20:0] r_texaddr, r_vqaddr;
    reg        r_tex, r_vq, r_iss;
    always @(posedge clk) begin
        if (reset) r_iss <= 1'b0;
        else if (!front_stall) begin
            for (d=0; d<4; d=d+1) r_boff[d] <= byte_off[d];
            r_texaddr <= r1_texaddr; r_vqaddr <= r1_vqaddr; r_tex <= r1_tex; r_vq <= r1_vq;
            r_iss <= r1_iss;
        end
    end

    // ============================================================================
    // STAGE FETCH (streaming, owns caches): 4 raw 64-bit words.
    // ============================================================================
    wire        f_ov;
    wire [63:0] f_word [0:3];
    tex_fetch4_ob u_fetch (
        .clk(clk),.reset(reset),
        .in_valid(r_iss),.tex(r_tex),.vq(r_vq),.in_ready(fetch_ready),
        .tex_addr(r_texaddr),.vq_addr(r_vqaddr),.tex_offset(r_boff),
        .out_valid(f_ov),.texel(f_word),
        .ddr_req(ddr_req),.ddr_resp(ddr_resp));

    // ============================================================================
    // Payload for DECODE/FILTER (rides an in-order delay line from the ADDROFFS-stage
    // issue, popped when the fetch emits - fetch is variable-latency, so this MUST be a
    // FIFO the depth of the fetch in-flight window). For a first cut we ride a shift
    // register clocked on the fetch's own advance (f issue -> f_ov). Since the fetch here
    // has no reordering (lockstep) and out_ready is tied high, the payload can ride a
    // shallow shift register matched to the fetch latency. Depth FETCHLAT covers T0..T2.
    // The offset low bits (byte lane / nibble) go to decode as `offset`.
    // ============================================================================
    localparam integer FETCHLAT = 3;         // T0->T1->T2
    // decode/filter payload captured at the fetch-issue cycle (ao_ov), delayed FETCHLAT.
    reg [3:0]  p_off  [0:3][0:FETCHLAT-1];   // per-corner offset[3:0] (lane/nibble)
    reg [2:0]  p_pixfmt[0:FETCHLAT-1];
    reg [1:0]  p_palfmt[0:FETCHLAT-1];
    reg        p_scan [0:FETCHLAT-1];
    reg [5:0]  p_palsel[0:FETCHLAT-1];
    reg [7:0]  p_uf[0:FETCHLAT-1], p_vf[0:FETCHLAT-1];
    reg [1:0]  p_filt[0:FETCHLAT-1];
    reg        p_igna[0:FETCHLAT-1], p_tex[0:FETCHLAT-1];
    reg [IDW-1:0] p_id[0:FETCHLAT-1];
    // NB: the offset low bits per corner = byte_off[gi][3:0]; the uvmap fracs + config
    // are the per-pixel values delayed to the ao_ov (fetch-issue) cycle. The config was
    // registered at d_*[L] (uvmap-aligned); it needs +1 (addroffs) more to reach issue.
    // config/fracs delayed to the fetch-ISSUE cycle (r_iss). issue is +3 from the uvmap-
    // aligned d_*[L]: +1 addroffs (i1_*), +1 offset register (i2_*), +1 address register
    // (i_*). Three delay stages.
    reg [2:0]  i1_pixfmt; reg [1:0] i1_palfmt; reg i1_scan; reg [5:0] i1_palsel;
    reg [7:0]  i1_uf, i1_vf; reg [1:0] i1_filt; reg i1_igna, i1_tex; reg [IDW-1:0] i1_id;
    reg [2:0]  i2_pixfmt; reg [1:0] i2_palfmt; reg i2_scan; reg [5:0] i2_palsel;
    reg [7:0]  i2_uf, i2_vf; reg [1:0] i2_filt; reg i2_igna, i2_tex; reg [IDW-1:0] i2_id;
    reg [2:0]  i_pixfmt; reg [1:0] i_palfmt; reg i_scan; reg [5:0] i_palsel;
    reg [7:0]  i_uf, i_vf; reg [1:0] i_filt; reg i_igna, i_tex; reg [IDW-1:0] i_id;
    always @(posedge clk) if (!front_stall) begin
        // stage 1: uvmap-aligned -> addroffs-aligned (ao_ov)
        i1_pixfmt<=bo_pixfmt; i1_palfmt<=bo_palfmt; i1_scan<=bo_scan; i1_palsel<=bo_palsel;
        i1_uf<=ufr; i1_vf<=vfr; i1_filt<=d_filt[L]; i1_igna<=d_igna[L]; i1_tex<=d_tex[L]; i1_id<=d_id[L];
        // stage 2: addroffs-aligned -> offset-register cycle (r1_iss)
        i2_pixfmt<=i1_pixfmt; i2_palfmt<=i1_palfmt; i2_scan<=i1_scan; i2_palsel<=i1_palsel;
        i2_uf<=i1_uf; i2_vf<=i1_vf; i2_filt<=i1_filt; i2_igna<=i1_igna; i2_tex<=i1_tex; i2_id<=i1_id;
        // stage 3: offset-register -> address-register cycle (r_iss)
        i_pixfmt<=i2_pixfmt; i_palfmt<=i2_palfmt; i_scan<=i2_scan; i_palsel<=i2_palsel;
        i_uf<=i2_uf; i_vf<=i2_vf; i_filt<=i2_filt; i_igna<=i2_igna; i_tex<=i2_tex; i_id<=i2_id;
    end
    // shift the payload down FETCHLAT stages. Stage-0 captures at the fetch-issue cycle
    // (r_iss): the offset lane bits come from the REGISTERED r_boff (what the fetch reads),
    // and the config from the r_iss-aligned i_*. Both freeze with the front (front_stall).
    always @(posedge clk) if (!front_stall) begin
        p_off[0][0]<=r_boff[0][3:0]; p_off[1][0]<=r_boff[1][3:0];
        p_off[2][0]<=r_boff[2][3:0]; p_off[3][0]<=r_boff[3][3:0];
        p_pixfmt[0]<=i_pixfmt; p_palfmt[0]<=i_palfmt; p_scan[0]<=i_scan; p_palsel[0]<=i_palsel;
        p_uf[0]<=i_uf; p_vf[0]<=i_vf; p_filt[0]<=i_filt; p_igna[0]<=i_igna; p_tex[0]<=i_tex; p_id[0]<=i_id;
        for (d=1; d<FETCHLAT; d=d+1) begin
            p_off[0][d]<=p_off[0][d-1]; p_off[1][d]<=p_off[1][d-1];
            p_off[2][d]<=p_off[2][d-1]; p_off[3][d]<=p_off[3][d-1];
            p_pixfmt[d]<=p_pixfmt[d-1]; p_palfmt[d]<=p_palfmt[d-1]; p_scan[d]<=p_scan[d-1];
            p_palsel[d]<=p_palsel[d-1]; p_uf[d]<=p_uf[d-1]; p_vf[d]<=p_vf[d-1];
            p_filt[d]<=p_filt[d-1]; p_igna[d]<=p_igna[d-1]; p_tex[d]<=p_tex[d-1]; p_id[d]<=p_id[d-1];
        end
    end
    localparam integer F = FETCHLAT-1;       // aligned-with-f_ov index

    // ============================================================================
    // STAGE DECODE x4 (3 cyc): raw word -> ARGB per corner.
    // ============================================================================
    wire [31:0] dec_argb [0:3];
    wire [3:0]  dec_ov;
    generate for (gi=0; gi<4; gi=gi+1) begin : dec
        tex_decode u_dec (
            .clk(clk),.reset(reset),.stall(1'b0),.in_valid(f_ov),
            .pixfmt(p_pixfmt[F]),.pal_fmt(p_palfmt[F]),.scan_order(p_scan[F]),
            .palsel(p_palsel[F]),.memtel(f_word[gi]),.offset(p_off[gi][F]),
            .pal_addr(pal_addr[gi]),.pal_data(pal_data[gi]),
            .out_valid(dec_ov[gi]),.argb(dec_argb[gi]));
    end endgenerate

    // decode-payload (fracs/filter/id) delayed by DECLAT (3) to align with dec_ov.
    localparam integer DECLAT = 3;
    reg [7:0] q_uf[0:DECLAT-1], q_vf[0:DECLAT-1]; reg [1:0] q_filt[0:DECLAT-1];
    reg       q_igna[0:DECLAT-1], q_tex[0:DECLAT-1]; reg [IDW-1:0] q_id[0:DECLAT-1];
    always @(posedge clk) begin
        q_uf[0]<=p_uf[F]; q_vf[0]<=p_vf[F]; q_filt[0]<=p_filt[F]; q_igna[0]<=p_igna[F];
        q_tex[0]<=p_tex[F]; q_id[0]<=p_id[F];
        for (d=1; d<DECLAT; d=d+1) begin
            q_uf[d]<=q_uf[d-1]; q_vf[d]<=q_vf[d-1]; q_filt[d]<=q_filt[d-1];
            q_igna[d]<=q_igna[d-1]; q_tex[d]<=q_tex[d-1]; q_id[d]<=q_id[d-1];
        end
    end
    localparam integer Q = DECLAT-1;

    // ============================================================================
    // STAGE FILTER (6 cyc): bilinear/nearest blend -> 1 ARGB.
    // corners: t00=(u+1,v+1)=dec[0] t01=(u+0,v+1)=dec[1] t10=(u+1,v+0)=dec[2] t11=(u+0,v+0)=dec[3]
    // ============================================================================
    wire        filt_ov;
    wire [31:0] filt_argb;
    tex_filter u_flt (
        .clk(clk),.reset(reset),.in_valid(dec_ov[0]),
        .filter(q_filt[Q] != 2'd0),.ignore_texa(q_igna[Q]),
        .ufrac(q_uf[Q]),.vfrac(q_vf[Q]),
        .t00(dec_argb[0]),.t01(dec_argb[1]),.t10(dec_argb[2]),.t11(dec_argb[3]),
        .out_valid(filt_ov),.textel(filt_argb));

    // id delayed by FILTLAT (6) to align with filt_ov.
    localparam integer FILTLAT = 6;
    reg [IDW-1:0] r_id [0:FILTLAT-1];
    always @(posedge clk) begin
        r_id[0]<=q_id[Q];
        for (d=1; d<FILTLAT; d=d+1) r_id[d]<=r_id[d-1];
    end

    assign out_valid = filt_ov;
    assign out_argb  = filt_argb;
    assign out_id    = r_id[FILTLAT-1];
endmodule
