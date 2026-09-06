//
// tsp_shade_v2_pp - FULLY PIPELINED per-pixel TSP shading (1 pixel/clock), v2.
//
// Same math and per-pixel dataflow as tsp_shade_pp, but rebuilt on the NEW, deeper,
// timing-closed building blocks so the whole shader clocks past the 100 MHz floor:
//
//   RCP    : W = 1/invW                       fp_rcp_faster   (5 cyc; was fp_rcp_fast/3)
//   INTERP : attr = (ddx*x + ddy*y + c) * W   interp_unit     (9 cyc; was inline i1/i2/i3)
//   MIP    : exponent-domain LOD              tsp_miplevel    (2 cyc; now streamed)
//   TEX    : float U/V -> 1 filtered ARGB     tex_unit        (uvmap+addr+fetch4+decode+
//                                                              filter; owns the caches +
//                                                              palette; variable latency,
//                                                              its own in_ready backpressure)
//   COMB   : texenv + offset -> ARGB          color_combiner  (3 cyc; now streamed)
//   FOG    : colour clamp + fog blend         fog_lut (7 cyc, in PARALLEL with the front)
//                                             + fog_blend (3 cyc, behind COMB)
//
// The old shader's separate UV / 4x-fetch / FILT stages are ALL subsumed by tex_unit,
// which takes interpolated float U/V (+ decoded per-pixel config) and returns one
// bilinear-filtered ARGB. So v2 is: RCP -> INTERP -> tex_unit -> COMB, with tsp_miplevel
// hanging off the RCP-aligned U/V planes to feed tex_unit's mip select, and f2u8 turning
// the interpolated colour/offset planes (2..9) into the 8-bit base/offset for COMB.
//
// FLOW CONTROL (identical discipline to tsp_shade_pp):
//   - The FRONT (RCP + INTERP + MIP + the colour f2u8/payload lines) is a rigid fixed-
//     latency block gated by ONE clock-enable `en`. It stalls only when a textured pixel
//     at the INTERP output can't be accepted by tex_unit (tex_unit.in_ready == 0, i.e. a
//     texture cache miss-fill). Non-textured pixels never stall.
//   - tex_unit's variable fetch latency is absorbed by carrying the per-pixel COMB payload
//     (colour base/offset, tsp, id, ptx/pof) in an in-order FIFO (pl_*), pushed on issue
//     into tex_unit and popped when tex_unit emits a result (tu_ov). COMB advances on tu_ov,
//     decoupled from the front's `en`.
//
// MEMORY: unlike tsp_shade_pp (which had 4x{tc,vq} caches injected as ports), tex_unit
// OWNS its 2 shared 4-read-port caches and exposes just TWO DDR read ports (tc, vq) to the
// parent arbiter, plus 4 injected palette read ports.
//
module tsp_shade_v2_pp import tsp_pkg::*; #(
    parameter integer IDW = 11            // width of the pass-through pixel id
) (
    input             clk,
    input             reset,
    input             flush,   // render-start: invalidate tex_unit's tex/VQ caches

    // ---- input pixel (buffered by caller; consumed when in_valid && !stall) ----
    input             in_valid,
    input      [IDW-1:0] in_id,           // opaque tag echoed on the output
    input      [10:0] px,                 // ABSOLUTE screen x (tile base | tile offset)
    input      [10:0] py,                 // ABSOLUTE screen y
    input             half,               // pixel-centre select (HALF_OFFSET.tsp_*)
    input             half_texel,         // texel-centre select (HALF_OFFSET.texure_*)
    input      [31:0] invw_in,
    input      [31:0] in_ddx [0:9],
    input      [31:0] in_ddy [0:9],
    input      [31:0] in_c   [0:9],
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    input      [1:0]  pal_fmt,            // global palette-entry format (PAL_RAM_CTRL)
    input             pp_texture,
    input             pp_offset,

    // ---- FOG unit: per-render constants + the FOG_TABLE read port (reg_file) ----
    input      [31:0] fog_den_f32,        // FOG_DENSITY, pre-normalized to f32
    input      [31:0] fog_col_ram,        // FOG_COL_RAM
    input      [31:0] fog_col_vert,       // FOG_COL_VERT
    input      [31:0] fog_clamp_max,      // FOG_CLAMP_MAX
    input      [31:0] fog_clamp_min,      // FOG_CLAMP_MIN
    output fog_rd_req_t  fog_req,
    input  fog_rd_resp_t fog_resp,

    // ---- output ----
    output reg           out_valid,
    output reg [IDW-1:0] out_id,
    output reg [31:0]    out_argb,
    output reg [31:0]    out_tsp,         // pixel's TSP word (SrcInstr/DstInstr for blend)

    // ---- caller sees stall so it can hold the input stable ----
    output            stall,

    // ---- injected palette RAM: 4 read ports (one per corner decoder) ----
    output     [9:0]  pal_addr [0:3],
    input      [31:0] pal_data [0:3],

    // ---- two DDR read ports to the parent arbiter ([0]=tc data, [1]=vq codebook) ----
    output ddr_rd_req_t  ddr_req  [0:2],
    input  ddr_rd_resp_t ddr_resp [0:2]
);
    genvar gi;
    integer s, k;

    // ==============================================================
    // FLOW CONTROL. The front stalls (combinationally) only when a TEXTURED INTERP-output
    // pixel is waiting and tex_unit can't accept it (cache miss-fill) or the COMB payload
    // FIFO is full. This is the SAME discipline as the old tsp_shade_pp (no registered-ready,
    // no skid). It makes `stall` a fanout net off tex_unit.in_ready (~-0.25ns at 120), but
    // it is the control structure that is known NOT to lock up. `iv_wants_fetch`/`pl_room`
    // are forward refs assigned below.
    // ==============================================================
    wire       tu_ready;              // tex_unit.in_ready (combinational)
    wire       iv_wants_fetch;        // an INTERP-output pixel wants a tex_unit slot
    wire       pl_room;               // COMB payload FIFO has space
    assign stall = iv_wants_fetch && (!tu_ready || !pl_room);
    wire en = ~stall;                 // front pipeline clock-enable (off rdy_r, local flop)

    // ==============================================================
    // STAGE RCP: W = 1/invW (fp_rcp_faster, 5 clocks). Everything else is delayed by
    // RCPLAT=5 to stay aligned with rc_W.
    // ==============================================================
    wire        rc_ov; wire [31:0] rc_W;
    fp_rcp_faster u_rc (.clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid & en),
                        .x(invw_in),.out_valid(rc_ov),.y(rc_W));

    localparam RCPLAT = 5;             // fp_rcp_faster latency

    // ==============================================================
    // STAGE FOG-LUT: the pixel's fog alpha from its 1/W (fog_lut, 7 clocks), computed
    // in PARALLEL with RCP+INTERP off the same accepted pixel - it shares only `en`,
    // so it adds NO latency and NO logic to any existing stage. Its 8-bit result is
    // aligned to the tex_unit issue point and then rides the COMB payload FIFO across
    // tex_unit's variable latency: carrying 8 bits there is far cheaper than carrying
    // the 32-bit invW and doing the lookup at the back.
    // NOTE the fog LUT is read off the pixel's INTERPOLATED 1/W (invw_in) rather than
    // refsw2's 1/(1/invW) round-trip; see the fog_lut header.
    // ==============================================================
    wire       fl_ov;
    wire [7:0] fl_alpha;
    fog_lut u_fog (
        .clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid & en),
`ifndef SYNTHESIS
        .dbg_px(px),.dbg_py(py),
`endif
        .invw(invw_in),.fog_den(fog_den_f32),
        .fog_req(fog_req),.fog_resp(fog_resp),
        .out_valid(fl_ov),.fog_alpha(fl_alpha));
    localparam FOGLAT = 7;             // fog_lut latency

    // --- wide operands (ddx/ddy/c, 10 planes x 32b) via M10K delay lines ---
    wire [319:0] q_ddx, q_ddy, q_c;
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

    // --- narrow scalars: plain flop shift chain ---
    reg [10:0] d_px  [0:RCPLAT-1];
    reg [10:0] d_py  [0:RCPLAT-1];
    reg [31:0] d_tsp [0:RCPLAT-1];
    reg [31:0] d_tcw [0:RCPLAT-1];
    reg [4:0]  d_tc  [0:RCPLAT-1];
    reg        d_ptx [0:RCPLAT-1];
    reg        d_pof [0:RCPLAT-1];
    reg [IDW-1:0] d_id[0:RCPLAT-1];
    always @(posedge clk) begin
        if (en) begin
            d_px[0]<=px; d_py[0]<=py; d_tsp[0]<=tsp; d_tcw[0]<=tcw; d_tc[0]<=text_ctrl;
            d_ptx[0]<=pp_texture; d_pof[0]<=pp_offset; d_id[0]<=in_id;
            for (s=1;s<RCPLAT;s=s+1) begin
                d_px[s]<=d_px[s-1]; d_py[s]<=d_py[s-1]; d_tsp[s]<=d_tsp[s-1];
                d_tcw[s]<=d_tcw[s-1]; d_tc[s]<=d_tc[s-1];
                d_ptx[s]<=d_ptx[s-1]; d_pof[s]<=d_pof[s-1]; d_id[s]<=d_id[s-1];
            end
        end
    end
    wire [10:0] rc_px  = d_px[RCPLAT-1];
    wire [10:0] rc_py  = d_py[RCPLAT-1];
    wire [31:0] rc_tsp = d_tsp[RCPLAT-1];
    wire [31:0] rc_tcw = d_tcw[RCPLAT-1];
    wire [4:0]  rc_tc  = d_tc[RCPLAT-1];
    wire        rc_ptx = d_ptx[RCPLAT-1];
    wire        rc_pof = d_pof[RCPLAT-1];
    wire [IDW-1:0] rc_id = d_id[RCPLAT-1];

    // ==============================================================
    // STAGE INTERP: attr = (ddx*x + ddy*y + c) * W, 10 planes. interp_unit, 9 cycles.
    // ==============================================================
    wire        iv_ov;
    wire [31:0] iv_attr [0:9];
    interp_unit u_iv (
        .clk(clk),.reset(reset),.stall(stall),.in_valid(rc_ov),
        .ddx(rcp_ddx),.ddy(rcp_ddy),.c(rcp_c),.px(rc_px),.py(rc_py),.half(half),.w(rc_W),
        .out_valid(iv_ov),.attr(iv_attr));
    localparam INTERPLAT = 10;   // +1: the coordinate conversion (see interp_unit)

    // ==============================================================
    // MIP LEVEL (exponent-domain LOD). Off the RCP-aligned U/V planes (0=U, 1=V) and rc_W.
    // tsp_miplevel is 2 cycles; its result is carried through the remaining INTERP latency
    // to align with iv_attr at the tex_unit input.
    // ==============================================================
    wire        mip_ov;
    wire [3:0]  mip_lvl;
    tsp_miplevel u_mip (
        .clk(clk),.reset(reset),.stall(stall),.in_valid(rc_ov),
        .ddxU(rcp_ddx[0]), .ddxV(rcp_ddx[1]),
        .ddyU(rcp_ddy[0]), .ddyV(rcp_ddy[1]),
        .w(rc_W),
        .texu(rc_tsp[5:3]), .mipmapd(rc_tsp[11:8]),
        .mipmapped(rc_tcw[31]),
        .out_valid(mip_ov), .miplevel(mip_lvl));

    // mip (2 cyc) -> align to iv_attr (INTERP 9 cyc): delay mip by INTERPLAT-2 = 7.
    localparam MIPDLY = INTERPLAT - 2;
    reg [3:0] mip_dl [0:MIPDLY-1];
    always @(posedge clk) if (en) begin
        mip_dl[0] <= mip_lvl;
        for (s=1;s<MIPDLY;s=s+1) mip_dl[s] <= mip_dl[s-1];
    end
    wire [3:0] iv_mip = mip_dl[MIPDLY-1];

    // ---- per-pixel config carried alongside INTERP (delayed RCP->INTERP output). The
    //      RCP-aligned scalars (rc_tsp/rc_tcw/rc_tc/rc_ptx/rc_pof/rc_id) must be delayed
    //      by INTERPLAT to land with iv_attr / iv_mip at the tex_unit input. ----
    reg [31:0] c_tsp [0:INTERPLAT-1], c_tcw [0:INTERPLAT-1];
    reg [4:0]  c_tc  [0:INTERPLAT-1];
    reg        c_ptx [0:INTERPLAT-1], c_pof [0:INTERPLAT-1];
    reg [IDW-1:0] c_id[0:INTERPLAT-1];
    always @(posedge clk) if (en) begin
        c_tsp[0]<=rc_tsp; c_tcw[0]<=rc_tcw; c_tc[0]<=rc_tc;
        c_ptx[0]<=rc_ptx; c_pof[0]<=rc_pof; c_id[0]<=rc_id;
        for (s=1;s<INTERPLAT;s=s+1) begin
            c_tsp[s]<=c_tsp[s-1]; c_tcw[s]<=c_tcw[s-1]; c_tc[s]<=c_tc[s-1];
            c_ptx[s]<=c_ptx[s-1]; c_pof[s]<=c_pof[s-1]; c_id[s]<=c_id[s-1];
        end
    end
    // fog alpha (FOGLAT deep) -> align with iv_ov (RCPLAT+INTERPLAT deep): delay the rest.
    localparam FOGDLY = RCPLAT + INTERPLAT - FOGLAT;
    reg [7:0] fog_dl [0:FOGDLY-1];
    always @(posedge clk) if (en) begin
        fog_dl[0] <= fl_alpha;
        for (s=1;s<FOGDLY;s=s+1) fog_dl[s] <= fog_dl[s-1];
    end
    wire [7:0] iv_fa = fog_dl[FOGDLY-1];

`ifndef SYNTHESIS
    // +fapx=<X> +fapy=<Y> : check the fog alpha is paired with the RIGHT fragment.
    // The FOG_MISALIGNED assert below only compares VALID strobes, so an alpha carried
    // one fragment out of step still satisfies it. This delays px/py by the same
    // RCPLAT+INTERPLAT the fragment takes to reach the tex_unit issue point and prints
    // the alpha that is about to be attached to it.
    integer fapx = -1, fapy = -1;
    initial begin
        void'($value$plusargs("fapx=%d", fapx));
        void'($value$plusargs("fapy=%d", fapy));
    end
    localparam integer FADLY = RCPLAT + INTERPLAT;
    reg [10:0] fa_px [0:FADLY-1], fa_py [0:FADLY-1];
    reg [31:0] fa_iw [0:FADLY-1];
    integer fk;
    always @(posedge clk) if (en) begin
        fa_px[0] <= px; fa_py[0] <= py; fa_iw[0] <= invw_in;
        for (fk=1; fk<FADLY; fk=fk+1) begin
            fa_px[fk] <= fa_px[fk-1]; fa_py[fk] <= fa_py[fk-1]; fa_iw[fk] <= fa_iw[fk-1];
        end
    end
    always @(posedge clk)
        if (!reset && en && fapx >= 0 && iv_ov
            && fa_px[FADLY-1] == fapx[10:0] && fa_py[FADLY-1] == fapy[10:0])
            $display("[FA] (%0d,%0d) at tex-issue: fragment invw=%08x  fog_alpha=%0d  (FOGLAT=%0d FOGDLY=%0d)",
                     fa_px[FADLY-1], fa_py[FADLY-1], fa_iw[FADLY-1], iv_fa, FOGLAT, FOGDLY);
`endif
`ifndef SYNTHESIS
    // The fog LUT and the RCP+INTERP front are rigid en-gated chains off the SAME accepted
    // pixel, so their valids must land together at the tex_unit issue point. A wrong FOGLAT
    // would silently shear every pixel's fog alpha onto a neighbour instead of failing.
    reg fog_vdl [0:FOGDLY-1];
    reg fog_align_fired = 1'b0;
    always @(posedge clk) if (en) begin
        fog_vdl[0] <= fl_ov;
        for (s=1;s<FOGDLY;s=s+1) fog_vdl[s] <= fog_vdl[s-1];
    end
    always @(posedge clk)
        if (!reset && en && !fog_align_fired && !$isunknown(fog_vdl[FOGDLY-1])
            && (fog_vdl[FOGDLY-1] != iv_ov)) begin
            fog_align_fired <= 1'b1;
            $display("[tsp_shade_v2_pp] FOG MISALIGNED: fog valid=%b vs interp valid=%b @t=%0t (FOGLAT/FOGDLY wrong)",
                     fog_vdl[FOGDLY-1], iv_ov, $time);
        end
`endif

    wire [31:0] iv_tsp = c_tsp[INTERPLAT-1];
    wire [31:0] iv_tcw = c_tcw[INTERPLAT-1];
    wire [4:0]  iv_tc  = c_tc[INTERPLAT-1];
    wire        iv_ptx = c_ptx[INTERPLAT-1];
    wire        iv_pof = c_pof[INTERPLAT-1];
    wire [IDW-1:0] iv_id = c_id[INTERPLAT-1];

    // ---- colour/offset planes (2..9) -> u8 (combinational f2u8), packed for COMB. These
    //      are consumed at the tex_unit ISSUE cycle (iv_ov) and ride the COMB payload FIFO. ----
    wire [7:0] u8a [2:9];
    generate for (gi=2; gi<=9; gi=gi+1) begin : cvt
        f2u8 u_c (.f(iv_attr[gi]), .u(u8a[gi]));
    end endgenerate
    // TSP.UseAlpha (bit 20) = 0 forces the BASE colour's alpha to 255 AFTER
    // interpolation (refsw2 InterpolateBase: `if (!pp_UseAlpha) rv.a = 255`) - the
    // vertex alpha plane is ignored. Without this, an alpha-blended UseAlpha=0 poly
    // (e.g. the bios BACKGROUND: SRCALPHA/INVSRCALPHA with vertex alpha 0) blends to
    // pure dst and shades whatever the colour buffer last held (black on a cold
    // buffer). Offset colour alpha is NOT affected (refsw2 InterpolateOffs).
    wire [31:0] iv_base = {(iv_tsp[20] ? u8a[5] : 8'd255),u8a[4],u8a[3],u8a[2]};
    wire [31:0] iv_ofs  = {u8a[9],u8a[8],u8a[7],u8a[6]};

    // ==============================================================
    // Decode the per-pixel TCW/TSP fields for tex_unit (same bit layout as tex_fetch_pp).
    //   TCW: [20:0]=TexAddr [25]=StrideSel [26]=ScanOrder [26:21]=PalSelect
    //        [29:27]=PixelFmt [30]=VQ [31]=MipMapped
    //   TSP: [2:0]=TexV [5:3]=TexU [11:8]=MipMapD [14:13]=FilterMode [19]=IgnoreTexA
    //        [15]=ClampV [16]=ClampU [17]=FlipV [18]=FlipU
    // ==============================================================
    wire [20:0] tu_texaddr = iv_tcw[20:0];
    wire        tu_stridesel= iv_tcw[25];
    wire        tu_scan     = iv_tcw[26];
    wire [5:0]  tu_palsel   = iv_tcw[26:21];
    wire [2:0]  tu_pixfmt   = iv_tcw[29:27];
    wire        tu_vq       = iv_tcw[30];
    wire        tu_mipmapped= iv_tcw[31];
    wire [2:0]  tu_texv     = iv_tsp[2:0];
    wire [2:0]  tu_texu     = iv_tsp[5:3];
    wire [1:0]  tu_filter   = iv_tsp[14:13];
    wire        tu_clampv   = iv_tsp[15];
    wire        tu_clampu   = iv_tsp[16];
    wire        tu_flipv    = iv_tsp[17];
    wire        tu_flipu    = iv_tsp[18];
    wire        tu_ignorea  = iv_tsp[19];

    // ==============================================================
    // STAGE TEX: tex_unit - float U/V (attr[0]=U, attr[1]=V) + config -> 1 filtered ARGB.
    // Owns the caches; asserts in_ready=0 (tu_ready) on a miss-fill (the front's stall). A
    // textured INTERP-output pixel wants the tex_unit slot. Fed DIRECTLY off the front (no
    // skid): a pixel issues when iv_ov & en, and the front holds it stable while stalled -
    // the same discipline the old tsp_shade_pp used.
    // ==============================================================
    assign iv_wants_fetch = iv_ov;             // any valid INTERP-output pixel needs a slot
    wire tu_issue = iv_ov & en;                // a pixel is accepted into tex_unit this cyc

    wire        tu_ov;
    wire [IDW-1:0] tu_oid;
    wire [31:0] tu_argb;
    tex_unit #(.IDW(IDW)) u_tex (
        .clk(clk),.reset(reset),.flush(flush),
        .in_valid(tu_issue),.in_id(iv_id),
        .u(iv_attr[0]),.v(iv_attr[1]),
        .texu(tu_texu),.texv(tu_texv),.miplevel(iv_mip),
        .clampu(tu_clampu),.clampv(tu_clampv),.flipu(tu_flipu),.flipv(tu_flipv),
        .tex_addr_in(tu_texaddr),.tex(iv_ptx),
        .vq(tu_vq),.scan(tu_scan),.stride_sel(tu_stridesel),.mipmapped(tu_mipmapped),
        .pixfmt(tu_pixfmt),.pal_fmt(pal_fmt),.palsel(tu_palsel),
        .text_ctrl(iv_tc),.filter_mode(tu_filter),.ignore_texa(tu_ignorea),
        .half_texel(half_texel),
        .in_ready(tu_ready),
        .out_valid(tu_ov),.out_id(tu_oid),.out_argb(tu_argb),
        .pal_addr(pal_addr),.pal_data(pal_data),
        .ddr_req(ddr_req),.ddr_resp(ddr_resp));

`ifndef SYNTHESIS
    // ---- +uvx=<X> +uvy=<Y> : decode the INTERPOLATED U/V at the tex_unit ISSUE point ----
    // The shade-input dump carries the plane COEFFICIENTS, not the interpolated attribute,
    // so it cannot show whether the TSP pixel-centre offset actually landed. This can: it
    // prints the U/V that tex_unit is about to consume, plus the 8.8 fixed value and the
    // texel/fraction that tex_uvmap will derive from it. For a 1:1 sprite with both
    // offsets active the expected result is frac=0 (the -128 texel bias exactly cancels
    // the +0.5 pixel centre); frac=128 means one of the two did not land.
    reg [10:0] pxd [0:INTERPLAT-1], pyd [0:INTERPLAT-1];
    always @(posedge clk) if (en) begin
        pxd[0] <= rc_px; pyd[0] <= rc_py;
        for (k = 1; k < INTERPLAT; k = k + 1) begin pxd[k] <= pxd[k-1]; pyd[k] <= pyd[k-1]; end
    end
    wire [10:0] iv_px = pxd[INTERPLAT-1];
    wire [10:0] iv_py = pyd[INTERPLAT-1];
    integer uvx = -1, uvy = -1;
    initial begin
        void'($value$plusargs("uvx=%d", uvx));
        void'($value$plusargs("uvy=%d", uvy));
    end
    real      uv_u, uv_v;
    integer   uv_szu, uv_szv, uv_raw, uv_ui, uv_rawv, uv_vi;
    // manual IEEE-754 decode: $bitstoshortreal exists but Verilator refuses to promote
    // its shortreal result to real, so do the unpack here.
    function real f2r(input [31:0] f);
        real m; integer e;
        begin
            if (f[30:23] == 8'd0) f2r = 0.0;
            else begin
                e = $signed({1'b0, f[30:23]}) - 127;
                m = 1.0 + $itor({9'd0, f[22:0]}) / 8388608.0;
                f2r = m * (2.0 ** e);
                if (f[31]) f2r = -f2r;
            end
        end
    endfunction
    always @(posedge clk)
        if (!reset && tu_issue && uvx >= 0 && iv_px == uvx[10:0] && iv_py == uvy[10:0]) begin
            uv_u    = f2r(iv_attr[0]);
            uv_v    = f2r(iv_attr[1]);
            // V has its OWN size (TSP.TexV), which need not equal TexU - decode both.
            uv_szu  = 8 << tu_texu;                       // mip 0
            uv_szv  = 8 << tu_texv;
            uv_raw  = $rtoi(uv_u * uv_szu * 256.0);
            // mirror tex_unit: point sampling takes NO texel bias
            uv_ui   = uv_raw  - ((half_texel && tu_filter != 2'd0) ? 128 : 0);
            uv_rawv = $rtoi(uv_v * uv_szv * 256.0);
            uv_vi   = uv_rawv - ((half_texel && tu_filter != 2'd0) ? 128 : 0);
            // the REMAINDER is what sizes any epsilon/rounding fix: it says how far
            // below the exact 8.8 boundary the interpolated value actually lands.
            $display("[UVR] (%0d,%0d) u_exact=%.6f (rem %.6f)  v_exact=%.6f (rem %.6f)",
                     iv_px, iv_py,
                     uv_u * uv_szu * 256.0, uv_u * uv_szu * 256.0 - uv_raw,
                     uv_v * uv_szv * 256.0, uv_v * uv_szv * 256.0 - uv_rawv);
            $display("[UV] (%0d,%0d) U=%f V=%f | sizeU=%0d ui_raw=%0d ui=%0d -> u_texel=%0d u_frac=%0d | sizeV=%0d vi_raw=%0d vi=%0d -> v_texel=%0d v_frac=%0d | half=%b half_texel=%b",
                     iv_px, iv_py, uv_u, uv_v,
                     uv_szu, uv_raw,  uv_ui,  uv_ui  >>> 8, uv_ui  & 255,
                     uv_szv, uv_rawv, uv_vi,  uv_vi  >>> 8, uv_vi  & 255,
                     half, (half_texel && tu_filter != 2'd0));
        end
`endif

    // ==============================================================
    // COMB payload FIFO: pushed when tex_unit ACCEPTS a pixel (tu_take), popped on tu_ov
    // (tex_unit result). Carries the per-pixel colour base/offset, tsp, ptx/pof, id across
    // tex_unit's variable latency. Pushed on issue (tu_issue) with the front's iv_* payload;
    // popped on tu_ov. Since tex_unit is in-order lockstep, the k-th pushed payload lines up
    // with the k-th texel result. id is also echoed by tex_unit (tu_oid) for cross-check.
    // ==============================================================
    localparam integer PLW = 32+32+32+1+1+8+IDW; // base, ofs, tsp, ptx, pof, fogalpha, id
    wire [PLW-1:0] pl_in = { iv_base, iv_ofs, iv_tsp, iv_ptx, iv_pof, iv_fa, iv_id };
    localparam integer PLD = 64, PLAW = 6;
    // ---- M10K FWFT payload FIFO ----
    // The body lives in block RAM; only the HEAD is a register. A head register is
    // unavoidable rather than a style choice: pl_out is consumed COMBINATIONALLY in
    // the same cycle tu_ov fires, and tu_ov is tex_unit's result-valid - it cannot be
    // back-pressured and is not known a cycle ahead. A plain registered-read FIFO
    // would therefore deliver the payload one cycle late on EVERY pop (depth does not
    // help; read latency is not a function of occupancy). Keeping the head in a
    // register and refilling it from the RAM behind is exactly what makes the pop
    // zero-latency - i.e. FWFT.
    //   Read-ahead: raddr is the pointer we will load NEXT (pl_rp_nxt), not the
    //   current one, so back-to-back pops stream at 1/cycle instead of alternating.
    //   Write bypass: an entry pushed at cycle T cannot be read out of the RAM at
    //   T+1 (same-address read-during-write returns the pre-write value), so the
    //   just-written datum is forwarded from a 1-deep register. This is the path the
    //   empty->push->pop sequence takes, which is every tex-pipe restart.
    wire [PLW-1:0]  pl_q;
    reg  [PLW-1:0]  pl_hd;      reg pl_hd_v;      // FWFT head
    reg  [PLAW:0]   pl_wp, pl_rp;                 // extra MSB disambiguates full/empty
    reg  [PLAW:0]   pl_cnt;
    wire pl_push = tu_issue;                    // push on front issue (== tex_unit accept)
    // Pop on a tex_unit result, but NEVER when the FIFO is empty. In steady state a tu_ov
    // always has a matching prior push (tex_unit is in-order & lossless), so this gate is a
    // no-op there. It ONLY suppresses spurious tu_ov pulses during the reset/startup window
    // (the whole pipe momentarily shows out_valid=1 before it settles) that would otherwise
    // underflow pl_cnt (0 - N wraps to ~127), latch pl_room=0, and deadlock the front.
    wire pl_pop  = tu_ov && (pl_cnt != 0);
    wire pl_head_free = !pl_hd_v || pl_pop;       // head slot can take a new entry
    wire pl_ram_has   = (pl_wp != pl_rp);         // an entry sits in the RAM body
    wire [PLAW:0] pl_rp_nxt = (pl_head_free && pl_ram_has) ? pl_rp + 1'b1 : pl_rp;
    // 1-deep write forwarding (see the read-during-write note above)
    reg  [PLW-1:0] pl_pw_d; reg [PLAW:0] pl_pw_a; reg pl_pw_v;
    wire [PLW-1:0] pl_src = (pl_pw_v && (pl_pw_a == pl_rp)) ? pl_pw_d : pl_q;
    bram_sdp #(.W(PLW), .D(PLD)) u_plf (
        .clk(clk), .we(pl_push), .waddr(pl_wp[PLAW-1:0]), .din(pl_in),
        .re(1'b1),  .raddr(pl_rp_nxt[PLAW-1:0]), .q(pl_q));
    wire [PLW-1:0] pl_out = pl_hd;
    assign pl_room = (pl_cnt < PLD-4);
`ifndef SYNTHESIS
    reg dl_dfired = 1'b0, dl_xfired = 1'b0, dl_hw_fired = 1'b0;   // one-shot flags
    integer dl_npush = 0, dl_npop = 0;        // cumulative push/pop counters
`endif
    always @(posedge clk) begin
        if (reset) begin
            pl_wp<=0; pl_rp<=0; pl_cnt<=0; pl_hd_v<=1'b0; pl_pw_v<=1'b0;
        end else begin
            pl_pw_v <= pl_push; pl_pw_a <= pl_wp; pl_pw_d <= pl_in;
            if (pl_push) pl_wp <= pl_wp + 1'b1;
            // FWFT head maintenance: refill from the RAM body when one is queued,
            // else take a same-cycle push directly (the RAM copy is skipped by
            // advancing pl_rp past it), else go empty.
            if (pl_head_free) begin
                if (pl_ram_has)      begin pl_hd <= pl_src; pl_hd_v <= 1'b1; pl_rp <= pl_rp + 1'b1; end
                else if (pl_push)    begin pl_hd <= pl_in;  pl_hd_v <= 1'b1; pl_rp <= pl_rp + 1'b1; end
                else                 pl_hd_v <= 1'b0;
            end
            pl_cnt <= pl_cnt + (pl_push?1:0) - (pl_pop?1:0);
`ifndef SYNTHESIS
            // UNDERFLOW/OVERFLOW CATCH: a pop with the FIFO empty (tu_ov without a prior
            // push) means tex_unit emitted a SPURIOUS result -> pl_cnt wraps negative ->
            // deadlock. An overflow means room-gating failed. Dump the first occurrence.
            if (dl_en && pl_pop && !pl_push && pl_cnt == 0)
                $display("[tsp_shade_v2_pp] FIFO UNDERFLOW: tu_ov popped empty FIFO. tu_issue=%b tu_ready=%b iv_ov=%b stall=%b en=%b",
                         tu_issue, tu_ready, iv_ov, stall, en);
            if (dl_en && pl_push && !pl_pop && pl_cnt >= PLD[PLAW:0])
                $display("[tsp_shade_v2_pp] FIFO OVERFLOW @cnt=%0d: push past depth.", pl_cnt);
            // CUMULATIVE push/pop counters + per-cycle trace once cnt climbs. Settles whether
            // pushes outnumber pops (shader mis-accounts tu_issue vs tex_unit accept), or pops
            // simply stopped. tex_unit's own tracker shows its accepts~=emits, so if pushes
            // here >> pops, tu_issue is pulsing more than tex_unit accepts (double-push).
            dl_npush <= dl_npush + (pl_push?1:0);
            dl_npop  <= dl_npop  + (pl_pop?1:0);
            if (dl_en && pl_cnt >= 7'd48 && (pl_push || pl_pop))
                $display("[shade FIFO] t=%0t cnt=%0d push=%b pop=%b (Spush=%0d Spop=%0d) | tu_issue=%b tu_ready=%b tu_ov=%b iv_ov=%b stall=%b en=%b room=%b",
                         $time, pl_cnt, pl_push, pl_pop, dl_npush, dl_npop, tu_issue, tu_ready, tu_ov, iv_ov, stall, en, pl_room);
            if (dl_en && !dl_dfired && pl_cnt >= 7'd64) begin
                dl_dfired <= 1'b1;
                $display("[tsp_shade_v2_pp] FIFO OVERFLOWED: cnt=%0d  totalPush=%0d totalPop=%0d (diff=%0d)",
                         pl_cnt, dl_npush, dl_npop, dl_npush - dl_npop);
            end
            // X-CATCH (decisive): an X on pl_push/pl_pop poisons pl_cnt permanently, and
            // `X >= 48` is FALSE so all the threshold traces above stay silent while the dump
            // still prints a garbage %0d value. Fires ONCE the first time push/pop/cnt go X.
            if (!dl_xfired && ($isunknown(pl_push) || $isunknown(pl_pop) || $isunknown(pl_cnt))) begin
                dl_xfired <= 1'b1;
                $display("[tsp_shade_v2_pp] X POISON @t=%0t: pl_push=%b pl_pop=%b pl_cnt=%b  (tu_ov=%b tu_issue=%b) <- tex_unit out_valid went X",
                         $time, pl_push, pl_pop, pl_cnt, tu_ov, tu_issue);
            end
            // RAW HIGH-WATER (NO gate at all - not even dl_en): announce the first time pl_cnt
            // in THIS block ever exceeds 56 (just under the pl_room gate at 60). The pipelined
            // fetch legitimately holds ~50 pixels in flight (32-deep pre-cache FIFO + the
            // T0a..T2b stages), so the old threshold of 40 fired on every healthy run. If this
            // never prints but the dump shows cnt=97, then the dump's pl_cnt is a DIFFERENT
            // signal than this block updates (aliasing).
            if (pl_cnt > 7'd56 && !dl_hw_fired) begin
                dl_hw_fired <= 1'b1;
                $display("[shade RAW] FIFO cnt exceeded 56: pl_cnt=%0d h=%0d t=%0d push=%b pop=%b t=%0t",
                         pl_cnt, pl_rp, pl_wp, pl_push, pl_pop, $time);
            end
`endif
        end
    end
    wire [31:0]    P_base = pl_out[PLW-1        -: 32];
    wire [31:0]    P_ofs  = pl_out[PLW-1-32     -: 32];
    wire [31:0]    P_tsp  = pl_out[PLW-1-64     -: 32];
    wire           P_ptx  = pl_out[PLW-1-96];
    wire           P_pof  = pl_out[PLW-1-97];
    wire [7:0]     P_fa   = pl_out[IDW          +: 8];   // fog_lut alpha for this pixel
    wire [IDW-1:0] P_id   = pl_out[IDW-1        : 0];

    // ==============================================================
    // STAGE COMB: texenv + offset -> ARGB. color_combiner is streamed (3 cyc). It consumes
    // the popped payload aligned with tu_ov (tex_unit's ARGB result). A non-textured pixel
    // forces textel = 0 (base-only). tsp/id ride color_combiner's latency to the output.
    // ==============================================================
    wire [1:0]  c_shad = P_tsp[7:6];
    wire [31:0] cc_textel = P_ptx ? tu_argb : 32'h00000000;
    wire        cc_ov;
    wire [31:0] comb_col;
    // in_valid = pl_pop (a real FIFO pop), NOT raw tu_ov. color_combiner consumes the POPPED
    // payload (P_base/P_ofs/P_tsp/...), so its valid must align with an actual pop. This also
    // suppresses spurious tex_unit out_valid pulses (e.g. the reset/startup glitch): a tu_ov
    // with an empty FIFO does not pop, so it produces no result - it can't over-count the
    // core's shade-drain accounting (sh_out_n) or collide the color-buffer read clients.
    color_combiner u_cc (
        .clk(clk),.reset(reset),.in_valid(pl_pop),
        .pp_texture(P_ptx),.pp_offset(P_pof),.shadinstr(c_shad),
        .base(P_base),.textel(cc_textel),.offset(P_ofs),
        .out_valid(cc_ov),.col(comb_col));
    localparam COMBLAT = 3;

    // ==============================================================
    // STAGE FOG: colour clamp + fog blend (fog_blend, 3 cyc), BEHIND the combiner - the
    // reference applies both after ColorCombiner and before BlendingUnit. Its own three
    // stages keep the clamp, the multiply and the accumulate apart, so nothing here
    // lengthens an existing combinational path.
    // ==============================================================
    localparam FOGBLAT = 3;
    localparam OUTLAT  = COMBLAT + FOGBLAT;

    // per-pixel payload the fog stage needs, delayed to the COMB result (tap COMBLAT-1)
    // and on to the pipe output (tap OUTLAT-1).
    reg [31:0]    o_tsp [0:OUTLAT-1];
    reg [IDW-1:0] o_id  [0:OUTLAT-1];
    reg [7:0]     o_fa  [0:COMBLAT-1];    // fog_lut alpha
    reg [7:0]     o_ofa [0:COMBLAT-1];    // offset alpha (per-vertex fog weight)
    reg           o_pof [0:COMBLAT-1];    // ISP.Offset (gates per-vertex fog)
    always @(posedge clk) begin
        o_tsp[0]<=P_tsp; o_id[0]<=P_id;
        o_fa[0]<=P_fa;   o_ofa[0]<=P_ofs[31:24]; o_pof[0]<=P_pof;
        for (s=1;s<OUTLAT;s=s+1) begin o_tsp[s]<=o_tsp[s-1]; o_id[s]<=o_id[s-1]; end
        for (s=1;s<COMBLAT;s=s+1) begin
            o_fa[s]<=o_fa[s-1]; o_ofa[s]<=o_ofa[s-1]; o_pof[s]<=o_pof[s-1];
        end
    end
    wire [31:0] fb_tsp = o_tsp[COMBLAT-1];

    wire        fb_ov;
    wire [31:0] fog_col;
    fog_blend u_fb (
        .clk(clk),.reset(reset),.in_valid(cc_ov),
        .col(comb_col),
        .fog_alpha(o_fa[COMBLAT-1]),.offs_a(o_ofa[COMBLAT-1]),
        .fog_ctrl(fb_tsp[23:22]),.color_clamp(fb_tsp[21]),.pp_offset(o_pof[COMBLAT-1]),
        .fog_col_ram(fog_col_ram),.fog_col_vert(fog_col_vert),
        .fog_clamp_max(fog_clamp_max),.fog_clamp_min(fog_clamp_min),
        .out_valid(fb_ov),.out_col(fog_col));

    always @(posedge clk) begin
        if (reset) out_valid<=0;
        else begin
            out_valid <= fb_ov;
            if (fb_ov) begin
                out_argb <= fog_col;
                out_id   <= o_id[OUTLAT-1];
                out_tsp  <= o_tsp[OUTLAT-1];
            end
        end
    end

`ifndef SYNTHESIS
    // ============================================================================
    // DEADLOCK WATCHDOG (sim only). The pipe deadlocks intermittently under cache
    // misses. This counts cycles where the shader is STUCK - a pixel is being
    // presented (in_valid) but is stalled (stall) AND nothing is draining out the
    // back (no tu_ov, no cc_ov, no out_valid) - and once that persists past a
    // threshold, dumps every handshake so we can see WHICH stage is wedged:
    //   stall   = iv_wants_fetch && (!tu_ready || !pl_room)
    //     -> !tu_ready  : tex_unit can't accept (its cache is stuck mid-fill)
    //     -> !pl_room   : COMB payload FIFO is full and never draining (tu_ov dead)
    //   tu_ov never firing while in-flight -> tex_unit swallowed a result (payload
    //     desync under a miss). Enabled with +dlwatch[=<N cycles>] (default 4096).
    integer      dl_thresh = 4096;
    reg          dl_en = 1'b0;
    integer      dl_stuck = 0;      // consecutive stuck cycles
    reg          dl_fired = 1'b0;   // one-shot per stuck episode
    integer      dl_arg;
    // (dl_xfired/dl_dfired one-shots for the FIFO X-catch/divergence catch above.)
    initial begin
        if ($value$plusargs("dlwatch=%d", dl_arg)) begin dl_en = 1'b1; dl_thresh = dl_arg; end
        else if ($test$plusargs("dlwatch"))        begin dl_en = 1'b1; end
    end
    // "stuck" = presenting a stalled pixel with no result anywhere in the drain path.
    wire dl_draining = tu_ov || cc_ov || out_valid;
    wire dl_stuck_now = in_valid && stall && !dl_draining;
    always @(posedge clk) begin
        if (reset) begin dl_stuck <= 0; dl_fired <= 1'b0; end
        else if (dl_en) begin
            if (dl_stuck_now) dl_stuck <= dl_stuck + 1;
            else begin dl_stuck <= 0; dl_fired <= 1'b0; end

            if (dl_stuck_now && dl_stuck >= dl_thresh && !dl_fired) begin
                dl_fired <= 1'b1;
                $display("=========================================================");
                $display("[tsp_shade_v2_pp] DEADLOCK: stuck %0d cycles. State dump:", dl_stuck);
                $display("  in_valid=%b  stall=%b  en=%b", in_valid, stall, en);
                $display("  --- front ---");
                $display("  rc_ov=%b  iv_ov=%b  iv_wants_fetch=%b", rc_ov, iv_ov, iv_wants_fetch);
                $display("  --- tex_unit handshake ---");
                $display("  tu_issue=%b  tu_ready=%b  tu_ov=%b  (tu_ready=0 => tex_unit/cache wedged)", tu_issue, tu_ready, tu_ov);
                $display("  --- COMB payload FIFO ---");
                $display("  pl_cnt=%0d  pl_room=%b  pl_push=%b  pl_pop=%b  pl_rp=%0d pl_wp=%0d",
                         pl_cnt, pl_room, pl_push, pl_pop, pl_rp, pl_wp);
                $display("    (pl_room=0 & pl_pop stuck 0 => tu_ov never fires => result swallowed)");
                $display("  --- back ---");
                $display("  cc_ov=%b  out_valid=%b", cc_ov, out_valid);
                $display("  --- DDR ports (tex_unit -> arbiter) ---");
                $display("  tc: rd=%b addr=%h burst=%0d | busy=%b dready=%b",
                         ddr_req[0].rd, ddr_req[0].addr, ddr_req[0].burst, ddr_resp[0].busy, ddr_resp[0].dready);
                $display("  vq: rd=%b addr=%h burst=%0d | busy=%b dready=%b",
                         ddr_req[1].rd, ddr_req[1].addr, ddr_req[1].burst, ddr_resp[1].busy, ddr_resp[1].dready);
                $display("=========================================================");
            end
        end
    end
`endif
endmodule
