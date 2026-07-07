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
    input      [1:0]  pal_fmt,            // global palette-entry format (PAL_RAM_CTRL)
    input             pp_texture,
    input             pp_offset,

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
    output ddr_rd_req_t  ddr_req  [0:1],
    input  ddr_rd_resp_t ddr_resp [0:1]
);
    genvar gi;
    integer s, k;

    // ==============================================================
    // FLOW CONTROL. The front stalls only when a TEXTURED INTERP-output pixel is waiting
    // and tex_unit can't accept it (cache miss-fill).
    //
    // TIMING: tex_unit.in_ready comes combinationally out of the cache's miss-detect FSM,
    // which is physically FAR from the front (RCP/INTERP/MIP + the delay_rams). Driving the
    // front's clock-enable `en` directly off it makes `stall` a huge-fanout net launching
    // from that far cone into hundreds of front-register ENA pins (and shares its timing
    // domain with the cache wren) - the -0.25ns fail. So we REGISTER the readiness locally
    // (rdy_r) and gate the front off THAT flop; the net now launches next to the front.
    // The registered ready reacts one cycle late, so a 1-DEEP SKID at the tex_unit input
    // catches the single pixel the front may over-issue before the stall lands, and
    // re-presents it. A FIFO would not help throughput here (front and tex_unit are both
    // <=1 px/clk); this is purely a fanout/route cut. `pl_room` (local FIFO counter) is
    // folded into the same registered gate.
    // ==============================================================
    wire       tu_ready;              // tex_unit.in_ready (combinational, far cone)
    wire       iv_wants_fetch;        // an INTERP-output pixel wants a tex_unit slot
    wire       pl_room;               // COMB payload FIFO has space
    wire       sk_full;               // skid holds an un-accepted pixel (forward ref)

    // registered accept-readiness: 1 = the tex_unit input path can take a pixel next cycle.
    // Off the far cache readiness + local FIFO room + skid emptiness, all sampled a cycle
    // early so the front's `en` net is a plain flop output.
    reg        rdy_r;
    always @(posedge clk) begin
        if (reset) rdy_r <= 1'b1;
        else       rdy_r <= tu_ready && pl_room && !sk_full;
    end
    assign stall = iv_wants_fetch && !rdy_r;
    wire en = ~stall;                 // front pipeline clock-enable (off rdy_r, local flop)

    // ==============================================================
    // STAGE RCP: W = 1/invW (fp_rcp_faster, 5 clocks). Everything else is delayed by
    // RCPLAT=5 to stay aligned with rc_W.
    // ==============================================================
    wire        rc_ov; wire [31:0] rc_W;
    fp_rcp_faster u_rc (.clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid & en),
                        .x(invw_in),.out_valid(rc_ov),.y(rc_W));

    localparam RCPLAT = 5;             // fp_rcp_faster latency

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
    reg [4:0]  d_px  [0:RCPLAT-1];
    reg [4:0]  d_py  [0:RCPLAT-1];
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
    wire [4:0]  rc_px  = d_px[RCPLAT-1];
    wire [4:0]  rc_py  = d_py[RCPLAT-1];
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
        .ddx(rcp_ddx),.ddy(rcp_ddy),.c(rcp_c),.px(rc_px),.py(rc_py),.w(rc_W),
        .out_valid(iv_ov),.attr(iv_attr));
    localparam INTERPLAT = 9;

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
    wire [31:0] iv_base = {u8a[5],u8a[4],u8a[3],u8a[2]};
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
    // Owns the caches; asserts in_ready=0 (tu_ready) on a miss-fill (the front's stall).
    // A textured INTERP-output pixel is what wants the tex_unit slot.
    // ==============================================================
    assign iv_wants_fetch = iv_ov;             // any valid INTERP-output pixel needs a slot
    wire tu_issue = iv_ov & en;                // front presents a pixel this cycle

    // ---- per-pixel bundle: EVERYTHING for one pixel = tex_unit inputs + the COMB payload.
    //      Packed so the 1-deep skid holds one over-issued pixel as a single register, and
    //      so the COMB payload stays glued to its texel through the skid (push COMB FIFO on
    //      ACCEPT, from THIS bundle - not from the front `iv_*` which may have advanced). ----
    // field widths: u32 v32 texu3 texv3 mip4 clu clv flu flv addr21 tex vq scan strd mm
    //               pixf3 filt2 pals6 tc5 igna | base32 ofs32 ptsp32 ptx pof | id
    localparam integer TUW =
        32+32 + 3+3+4 + 1+1+1+1 + 21 + 1 + 1+1+1+1 + 3+2+6 + 5 + 1   // tex_unit inputs
        + 32+32+32 + 1+1                                             // comb: base ofs tsp ptx pof
        + IDW;
    wire [TUW-1:0] tu_in = {
        iv_attr[0], iv_attr[1],                        // u(32), v(32)
        tu_texu, tu_texv, iv_mip,                      // texu(3), texv(3), mip(4)
        tu_clampu, tu_clampv, tu_flipu, tu_flipv,      // clu clv flu flv (4)
        tu_texaddr,                                    // tex_addr_in(21)
        iv_ptx,                                        // tex(1)
        tu_vq, tu_scan, tu_stridesel, tu_mipmapped,    // (4)
        tu_pixfmt, tu_filter, tu_palsel,               // pixf(3) filt(2) pals(6)
        iv_tc,                                         // text_ctrl(5)
        tu_ignorea,                                    // ignore_texa(1)
        iv_base, iv_ofs, iv_tsp, iv_ptx, iv_pof,       // COMB payload: base ofs tsp ptx pof
        iv_id                                          // id(IDW)
    };

    // ---- 1-DEEP SKID: holds the pixel the front over-issued while rdy_r was (registered)
    //      high but the REAL tu_ready dropped that same cycle. Re-presents it until taken.
    //      rdy_r sampled !sk_full, so the front is already stalled while the skid is full -
    //      it can never over-issue a SECOND pixel, so 1 entry is sufficient. ----
    reg              sk_v;
    reg  [TUW-1:0]   sk_d;
    assign sk_full = sk_v;

    // what tex_unit sees this cycle: the skid pixel if held, else the fresh front pixel.
    wire            tu_valid = sk_v ? 1'b1 : tu_issue;
    wire [TUW-1:0]  tu_bits  = sk_v ? sk_d : tu_in;
    wire            tu_take  = tu_valid && tu_ready;   // tex_unit accepts (comb) this cycle

    always @(posedge clk) begin
        if (reset) sk_v <= 1'b0;
        else begin
            if (sk_v) begin
                if (tu_ready) sk_v <= 1'b0;            // held pixel accepted -> free skid
            end else if (tu_issue && !tu_ready) begin
                sk_v <= 1'b1; sk_d <= tu_in;           // over-issue -> capture
            end
        end
    end

    // ---- unpack the (skid-or-fresh) bundle: tex_unit inputs (x_*) + COMB payload (P_*) ----
    wire [31:0]    x_u    = tu_bits[TUW-1        -: 32];
    wire [31:0]    x_v    = tu_bits[TUW-1-32     -: 32];
    wire [2:0]     x_texu = tu_bits[TUW-1-64     -: 3];
    wire [2:0]     x_texv = tu_bits[TUW-1-67     -: 3];
    wire [3:0]     x_mip  = tu_bits[TUW-1-70     -: 4];
    wire           x_clu  = tu_bits[TUW-1-74];
    wire           x_clv  = tu_bits[TUW-1-75];
    wire           x_flu  = tu_bits[TUW-1-76];
    wire           x_flv  = tu_bits[TUW-1-77];
    wire [20:0]    x_addr = tu_bits[TUW-1-78     -: 21];
    wire           x_tex  = tu_bits[TUW-1-99];
    wire           x_vq   = tu_bits[TUW-1-100];
    wire           x_scan = tu_bits[TUW-1-101];
    wire           x_strd = tu_bits[TUW-1-102];
    wire           x_mm   = tu_bits[TUW-1-103];
    wire [2:0]     x_pixf = tu_bits[TUW-1-104    -: 3];
    wire [1:0]     x_filt = tu_bits[TUW-1-107    -: 2];
    wire [5:0]     x_pals = tu_bits[TUW-1-109    -: 6];
    wire [4:0]     x_tc   = tu_bits[TUW-1-115    -: 5];
    wire           x_igna = tu_bits[TUW-1-120];
    wire [31:0]    x_base = tu_bits[TUW-1-121    -: 32];
    wire [31:0]    x_ofs  = tu_bits[TUW-1-153    -: 32];
    wire [31:0]    x_tsp  = tu_bits[TUW-1-185    -: 32];
    wire           x_ptx  = tu_bits[TUW-1-217];
    wire           x_pof  = tu_bits[TUW-1-218];
    wire [IDW-1:0] x_id   = tu_bits[IDW-1        : 0];

    wire        tu_ov;
    wire [IDW-1:0] tu_oid;
    wire [31:0] tu_argb;
    tex_unit #(.IDW(IDW)) u_tex (
        .clk(clk),.reset(reset),
        .in_valid(tu_valid),.in_id(x_id),
        .u(x_u),.v(x_v),
        .texu(x_texu),.texv(x_texv),.miplevel(x_mip),
        .clampu(x_clu),.clampv(x_clv),.flipu(x_flu),.flipv(x_flv),
        .tex_addr_in(x_addr),.tex(x_tex),
        .vq(x_vq),.scan(x_scan),.stride_sel(x_strd),.mipmapped(x_mm),
        .pixfmt(x_pixf),.pal_fmt(pal_fmt),.palsel(x_pals),
        .text_ctrl(x_tc),.filter_mode(x_filt),.ignore_texa(x_igna),
        .in_ready(tu_ready),
        .out_valid(tu_ov),.out_id(tu_oid),.out_argb(tu_argb),
        .pal_addr(pal_addr),.pal_data(pal_data),
        .ddr_req(ddr_req),.ddr_resp(ddr_resp));

    // ==============================================================
    // COMB payload FIFO: pushed when tex_unit ACCEPTS a pixel (tu_take), popped on tu_ov
    // (tex_unit result). Carries the per-pixel colour base/offset, tsp, ptx/pof, id across
    // tex_unit's variable latency. The payload is taken from the (skid-or-fresh) bundle so
    // it stays glued to the exact pixel tex_unit accepted - if the skid delayed a pixel, its
    // colour rode along in the skid and enters the FIFO on the SAME cycle as its texel issue.
    // id is also echoed by tex_unit (tu_oid); both must match in order (in-order pipeline).
    // ==============================================================
    localparam integer PLW = 32+32+32+1+1+IDW;   // base, ofs, tsp, ptx, pof, id
    wire [PLW-1:0] pl_in = { x_base, x_ofs, x_tsp, x_ptx, x_pof, x_id };
    localparam integer PLD = 64, PLAW = 6;
    reg  [PLW-1:0] plf [0:PLD-1];
    reg  [PLAW-1:0] pl_h, pl_t; reg [PLAW:0] pl_cnt;
    wire pl_push = tu_take;              // push exactly when tex_unit accepts (skid-safe)
    wire pl_pop  = tu_ov;
    wire [PLW-1:0] pl_out = plf[pl_h];
    assign pl_room = (pl_cnt < PLD-4);
    always @(posedge clk) begin
        if (reset) begin pl_h<=0; pl_t<=0; pl_cnt<=0; end
        else begin
            if (pl_push) begin plf[pl_t] <= pl_in; pl_t <= pl_t + 1'b1; end
            if (pl_pop)  pl_h <= pl_h + 1'b1;
            pl_cnt <= pl_cnt + (pl_push?1:0) - (pl_pop?1:0);
        end
    end
    wire [31:0]    P_base = pl_out[PLW-1        -: 32];
    wire [31:0]    P_ofs  = pl_out[PLW-1-32     -: 32];
    wire [31:0]    P_tsp  = pl_out[PLW-1-64     -: 32];
    wire           P_ptx  = pl_out[PLW-1-96];
    wire           P_pof  = pl_out[PLW-1-97];
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
    color_combiner u_cc (
        .clk(clk),.reset(reset),.in_valid(tu_ov),
        .pp_texture(P_ptx),.pp_offset(P_pof),.shadinstr(c_shad),
        .base(P_base),.textel(cc_textel),.offset(P_ofs),
        .out_valid(cc_ov),.col(comb_col));
    localparam COMBLAT = 3;

    // tsp + id delayed by COMBLAT to align with cc_ov (color_combiner result).
    reg [31:0]    o_tsp [0:COMBLAT-1];
    reg [IDW-1:0] o_id  [0:COMBLAT-1];
    always @(posedge clk) begin
        o_tsp[0]<=P_tsp; o_id[0]<=P_id;
        for (s=1;s<COMBLAT;s=s+1) begin o_tsp[s]<=o_tsp[s-1]; o_id[s]<=o_id[s-1]; end
    end

    always @(posedge clk) begin
        if (reset) out_valid<=0;
        else begin
            out_valid <= cc_ov;
            if (cc_ov) begin
                out_argb <= comb_col;
                out_id   <= o_id[COMBLAT-1];
                out_tsp  <= o_tsp[COMBLAT-1];
            end
        end
    end
endmodule
