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
        .clk(clk),.reset(reset),
        .in_valid(tu_issue),.in_id(iv_id),
        .u(iv_attr[0]),.v(iv_attr[1]),
        .texu(tu_texu),.texv(tu_texv),.miplevel(iv_mip),
        .clampu(tu_clampu),.clampv(tu_clampv),.flipu(tu_flipu),.flipv(tu_flipv),
        .tex_addr_in(tu_texaddr),.tex(iv_ptx),
        .vq(tu_vq),.scan(tu_scan),.stride_sel(tu_stridesel),.mipmapped(tu_mipmapped),
        .pixfmt(tu_pixfmt),.pal_fmt(pal_fmt),.palsel(tu_palsel),
        .text_ctrl(iv_tc),.filter_mode(tu_filter),.ignore_texa(tu_ignorea),
        .in_ready(tu_ready),
        .out_valid(tu_ov),.out_id(tu_oid),.out_argb(tu_argb),
        .pal_addr(pal_addr),.pal_data(pal_data),
        .ddr_req(ddr_req),.ddr_resp(ddr_resp));

    // ==============================================================
    // COMB payload FIFO: pushed when tex_unit ACCEPTS a pixel (tu_take), popped on tu_ov
    // (tex_unit result). Carries the per-pixel colour base/offset, tsp, ptx/pof, id across
    // tex_unit's variable latency. Pushed on issue (tu_issue) with the front's iv_* payload;
    // popped on tu_ov. Since tex_unit is in-order lockstep, the k-th pushed payload lines up
    // with the k-th texel result. id is also echoed by tex_unit (tu_oid) for cross-check.
    // ==============================================================
    localparam integer PLW = 32+32+32+1+1+IDW;   // base, ofs, tsp, ptx, pof, id
    wire [PLW-1:0] pl_in = { iv_base, iv_ofs, iv_tsp, iv_ptx, iv_pof, iv_id };
    localparam integer PLD = 64, PLAW = 6;
    reg  [PLW-1:0] plf [0:PLD-1];
    reg  [PLAW-1:0] pl_h, pl_t; reg [PLAW:0] pl_cnt;
    wire pl_push = tu_issue;                    // push on front issue (== tex_unit accept)
    // Pop on a tex_unit result, but NEVER when the FIFO is empty. In steady state a tu_ov
    // always has a matching prior push (tex_unit is in-order & lossless), so this gate is a
    // no-op there. It ONLY suppresses spurious tu_ov pulses during the reset/startup window
    // (the whole pipe momentarily shows out_valid=1 before it settles) that would otherwise
    // underflow pl_cnt (0 - N wraps to ~127), latch pl_room=0, and deadlock the front.
    wire pl_pop  = tu_ov && (pl_cnt != 0);
    wire [PLW-1:0] pl_out = plf[pl_h];
    assign pl_room = (pl_cnt < PLD-4);
`ifndef SYNTHESIS
    reg dl_dfired = 1'b0, dl_xfired = 1'b0, dl_hw_fired = 1'b0;   // one-shot flags
    integer dl_npush = 0, dl_npop = 0;        // cumulative push/pop counters
`endif
    always @(posedge clk) begin
        if (reset) begin pl_h<=0; pl_t<=0; pl_cnt<=0; end
        else begin
            if (pl_push) begin plf[pl_t] <= pl_in; pl_t <= pl_t + 1'b1; end
            if (pl_pop)  pl_h <= pl_h + 1'b1;
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
            // in THIS block ever exceeds 40. If this never prints but the dump shows cnt=97,
            // then the dump's pl_cnt is a DIFFERENT signal than this block updates (aliasing).
            if (pl_cnt > 7'd40 && !dl_hw_fired) begin
                dl_hw_fired <= 1'b1;
                $display("[shade RAW] FIFO cnt exceeded 40: pl_cnt=%0d h=%0d t=%0d push=%b pop=%b t=%0t",
                         pl_cnt, pl_h, pl_t, pl_push, pl_pop, $time);
            end
`endif
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
                $display("  pl_cnt=%0d  pl_room=%b  pl_push=%b  pl_pop=%b  pl_h=%0d pl_t=%0d",
                         pl_cnt, pl_room, pl_push, pl_pop, pl_h, pl_t);
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
