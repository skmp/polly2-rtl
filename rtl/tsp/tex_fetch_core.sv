//
// tex_fetch_core - one corner's streaming texel fetch pipeline (part of tex_fetch).
//
// This is tex_fetch_pp WITH THE ADDRESS GENERATION REMOVED: the byte address + the
// per-corner side bits are now supplied by tex_addrgen / tex_base_addr, so this core
// keeps ONLY the (subtle, hard-won) streaming cache pipeline + VQ 2nd-trip + decode.
// The T0/T1/T2/D logic below is a VERBATIM lift from tex_fetch_pp - do not "clean it
// up"; its stall/hold discipline is exact.
//
// STREAMING: accepts a new request every cycle (valid/ready); in_ready deasserts ONLY
// during a genuine cache miss-fill. Results leave IN ISSUE ORDER at 1/clk.
//   T0 : present tc_req (data cache) ; accepted when tc_resp.ready
//   T1 : tc word landed. If VQ, present vq_req (codebook addr from the tc word).
//   T2 : vq word landed (VQ) / tc word (non-VQ)
//   D  : tex_decode -> argb
//
// side-data bundle (identical layout to tex_fetch_pp), MSB..LSB:
//   [42] textured [41:39] pixfmt [38] scan [37:34] off_lo [33:31] off_bytesel
//   [30] vq [29:27] vq_bytesel [26:6] tcw_addr [5:0] palsel
// Built by the caller from tex_addrgen.offset (off_lo/bytesel) + tex_base_addr config.
//
module tex_fetch_core import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             in_valid,
    input             in_textured,
    output            in_ready,
    // pre-computed address + side (from tex_addrgen / tex_base_addr)
    input      [28:0] byte_addr,      // full texel byte address (waddr = byte_addr[28:3])
    input      [42:0] in_side,        // side-data bundle (layout above)
    input             out_ready,
    output reg        out_valid,
    output reg [31:0] argb,

    // injected caches: data (texel/index) + VQ codebook
    output cache_req_t   tc_req,
    input  cache_resp_t  tc_resp,
    output cache_req_t   vq_req,
    input  cache_resp_t  vq_resp
);
    localparam integer SW = 43;

    // ============================================================================
    // FIXED-LATENCY STREAMING PIPELINE (verbatim from tex_fetch_pp).
    // ============================================================================
    reg          t0_v, t1_v, t2_v;
    reg [SW-1:0] t0_s, t1_s, t2_s;
    reg [63:0]   t0_mem;
    reg          t0_dv;
    reg [63:0]   t1_mem;
    reg [63:0]   t2_mem;
    reg          t2_dv;

    // T1 pixel VQ-ness + its derived codebook address (from the HELD tc word).
    wire         t1_isvq   = t1_s[30] && t1_s[42];
    wire [2:0]   t1_vqbsel = t1_s[29:27];
    wire [20:0]  t1_taddr  = t1_s[26:6];
    wire [7:0]   t1_vqbyte = t1_mem[8*t1_vqbsel +: 8];
    wire [28:0]  t1_vqaddr = {8'd0, t1_taddr} + {21'd0, t1_vqbyte};
    wire         t2_isvq   = t2_s[30] && t2_s[42];

    wire d_adv   = out_ready;
    wire d_free  = !d_v || d_adv;

    wire t2_here  = t2_dv || (t2_v && t2_isvq && vq_resp.ack);
    wire [63:0] t2_word = t2_dv ? t2_mem : vq_resp.rdata;
    wire t2_adv   = t2_v && t2_here && d_free;
    wire t2_free  = !t2_v || t2_adv;

    wire vq_need  = t1_v && t1_isvq;
    wire t1_okvq  = !vq_need || vq_resp.ready;
    wire t1_adv   = t1_v && t1_okvq && t2_free;
    wire t1_free  = !t1_v || t1_adv;

    wire t0_bypass = t0_v && !t0_s[42];
    wire t0_here  = t0_bypass || t0_dv || (t0_v && tc_resp.ack);
    wire [63:0] t0_word = t0_dv ? t0_mem : tc_resp.rdata;
    wire t0_adv   = t0_v && t0_here && t1_free;
    wire t0_free  = !t0_v || t0_adv;

    // ---- T0 issue ----
    assign in_ready   = t0_free && (!in_textured || tc_resp.ready);
    wire   accept     = in_valid && in_ready;
    assign tc_req.req   = accept && in_textured;
    assign tc_req.waddr = { 3'b0, byte_addr[28:3] };

    // ---- T1 vq issue ----
    assign vq_req.req   = vq_need && t2_free && vq_resp.ready;
    assign vq_req.waddr = t1_vqaddr;

    // ============ DECODE stage (fed from T2) ============
    reg        d_v;
    reg [63:0] d_memtel;
    reg [SW-1:0] d_side;

    (* rom_style = "block" *) reg [31:0] pal_rom [0:255];
    integer pri;
    initial for (pri=0; pri<256; pri=pri+1)
        pal_rom[pri] = {8'hFF, pri[7:0], pri[7:0], pri[7:0]};
    wire        d_txd    = d_side[42];
    wire [2:0]  d_pixfmt = d_side[41:39];
    wire        d_scan   = d_side[38];
    wire [3:0]  d_off_lo = d_side[37:34];
    wire [2:0]  d_off_b  = d_side[33:31];
    wire [5:0]  d_palsel = d_side[5:0];
    wire [7:0]  pal8_local = d_memtel[8*d_off_b +: 8];
    wire [3:0]  pal4_nib   = d_memtel[4*d_off_lo +: 4];
    wire [7:0]  pal8_idx   = {d_palsel[5:4], pal8_local};
    wire [7:0]  pal4_idx   = {d_palsel[3:0], pal4_nib};
    wire [7:0]  d_pal_idx  = (d_pixfmt==3'd6) ? pal8_idx :
                             (d_pixfmt==3'd5) ? pal4_idx : 8'd0;
    wire [31:0] d_pal_argb = pal_rom[d_pal_idx];

    wire [31:0] dec_argb;
    tex_decode u_dec (.pixfmt(d_pixfmt),.scan(d_scan),.memtel(d_memtel),
                      .offset_lo(d_off_lo),.pal_argb(d_pal_argb),.argb(dec_argb));

    always @(posedge clk) begin
        if (reset) begin
            t0_v<=0; t0_dv<=0; t1_v<=0; t2_v<=0; t2_dv<=0; d_v<=0; out_valid<=0;
            t0_s<=0; t1_s<=0; t2_s<=0; d_side<=0;
            t0_mem<=0; t1_mem<=0; t2_mem<=0; d_memtel<=0; argb<=0;
        end else begin
            if (accept)      begin t0_v <= 1'b1; t0_s <= in_side; t0_dv <= 1'b0; end
            else if (t0_adv)       t0_v <= 1'b0;

            if (t0_v && !t0_dv && tc_resp.ack && !t0_adv) begin
                t0_mem <= tc_resp.rdata; t0_dv <= 1'b1;
            end

            if (t0_adv)      begin t1_v <= 1'b1; t1_s <= t0_s; t1_mem <= t0_word; end
            else if (t1_adv)       t1_v <= 1'b0;

            if (t1_adv)      begin t2_v <= 1'b1; t2_s <= t1_s; t2_mem <= t1_mem;
                                   t2_dv <= !(t1_s[30] && t1_s[42]); end
            else if (t2_adv)       t2_v <= 1'b0;

            if (t2_v && t2_isvq && !t2_dv && vq_resp.ack && !t2_adv) begin
                t2_mem <= vq_resp.rdata; t2_dv <= 1'b1;
            end

            if (t2_adv)      begin d_v <= 1'b1; d_side <= t2_s; d_memtel <= t2_word; end
            else if (d_adv)        d_v <= 1'b0;

            out_valid <= d_v && d_adv;
            if (d_v && d_adv) argb <= d_txd ? dec_argb : 32'h00000000;
        end
    end
endmodule
