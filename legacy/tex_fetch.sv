//
// tex_fetch - fetch and decode ONE texel to ARGB8888, self-contained FSM.
// Handles: address gen (tex_addr), data-cache read, VQ codebook (2nd read),
// palette ROM lookup, and format decode (tex_decode). Stalls on the caches.
//
//   req + (u,v) + tsp/tcw/text_ctrl -> ack + argb
//
// VQ: read the index line, take the index byte, read the codebook entry (64b)
// from the VQ cache at (TexAddr<<3) + index*8, decode that as the texel word.
// Palette (PAL4/PAL8): index into an internal ROM placeholder.
//
// The two caches are INJECTED as bundle pairs (tc_req/tc_resp, vq_req/vq_resp);
// tex_fetch is agnostic to their implementation.
//
module tex_fetch import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             req,
    input      [10:0] u,
    input      [10:0] v,
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    output reg        ack,
    output reg [31:0] argb,

    // injected caches: data (texel/index) + VQ codebook
    output cache_req_t   tc_req,
    input  cache_resp_t  tc_resp,
    output cache_req_t   vq_req,
    input  cache_resp_t  vq_resp
);
    wire [2:0] texu=tsp[5:3], texv=tsp[2:0];
    wire [20:0] tcw_addr=tcw[20:0];
    wire strdsel=tcw[25], scan=tcw[26];
    wire [2:0] pixfmt=tcw[29:27];
    wire vq=tcw[30];
    wire mipmapped=tcw[31];
    wire [5:0] palsel=tcw[26:21];

    // address gen (combinational). fbpp_shr is the byte-offset shift amount (unused
    // here; byte_addr already folds it in).
    wire [28:0] ta_byte; wire [2:0] ta_fbpp_shr; wire [19:0] ta_off;
    tex_addr u_ta (
        .tcw_addr(tcw_addr),.vq(vq),.scan(scan),.stride_sel(strdsel),.mipmapped(mipmapped),.pixfmt(pixfmt),
        .texu(texu),.texv(texv),.miplevel(4'd0),.text_ctrl(text_ctrl),.u(u),.v(v),
        .byte_addr(ta_byte),.fbpp_shr(ta_fbpp_shr),.offset(ta_off));

    // palette ROM placeholder (ARGB8888)
    (* rom_style = "block" *) reg [31:0] pal_rom [0:255];
    integer pri;
    initial for (pri=0; pri<256; pri=pri+1)
        pal_rom[pri] = {8'hFF, pri[7:0], pri[7:0], pri[7:0]};   // grayscale placeholder
    reg [7:0] pal_idx; wire [31:0] pal_argb = pal_rom[pal_idx];

    // decode (combinational)
    reg [63:0] dec_memtel; reg [3:0] dec_off_lo;
    wire [31:0] dec_argb;
    tex_decode u_dec (.pixfmt(pixfmt),.scan(scan),.memtel(dec_memtel),
                      .offset_lo(dec_off_lo),.pal_argb(pal_argb),.argb(dec_argb));

    // palette index selection from the fetched line (before decode)
    // PAL8: byte at offset&7 ; PAL4: nibble at offset&15
    wire [7:0]  pal8_local  = dec_memtel[8*ta_off[2:0] +: 8];
    wire [3:0]  pal4_nib    = dec_memtel[4*ta_off[3:0] +: 4];
    wire [7:0]  pal8_idx    = {palsel[5:4], pal8_local};          // (PalSelect/16)*256 | local
    wire [7:0]  pal4_idx    = {palsel[3:0], pal4_nib};            // PalSelect*16 | local

    localparam S_IDLE=0,S_RD=1,S_WAIT=2,S_VQ=3,S_VQW=4,S_DEC=5,S_ACK=6;
    reg [2:0] st;
    reg [2:0] vq_bytesel;

    // drive the injected cache request bundles from internal regs
    reg        tcq_r, vqq_r; reg [28:0] tcw_r, vqw_r;
    assign tc_req.req = tcq_r; assign tc_req.waddr = tcw_r;
    assign vq_req.req = vqq_r; assign vq_req.waddr = vqw_r;

    always @(posedge clk) begin
        if (reset) begin st<=S_IDLE; ack<=0; tcq_r<=0; vqq_r<=0; end
        else begin
            ack<=0; tcq_r<=0; vqq_r<=0;
            case (st)
            S_IDLE: if (req) begin tcq_r<=1; tcw_r<=ta_byte[28:3]; st<=S_WAIT; end
            S_WAIT: if (tc_resp.ack) begin
                dec_memtel <= tc_resp.rdata;
                dec_off_lo <= ta_off[3:0];
                vq_bytesel <= ta_byte[2:0];
                st <= vq ? S_VQ : S_DEC;
            end
            // VQ: index byte -> codebook read (each entry = 8 bytes -> waddr+index)
            S_VQ: begin
                vqq_r <= 1;
                vqw_r <= {8'd0, tcw_addr} + dec_memtel[8*vq_bytesel +: 8];
                st <= S_VQW;
            end
            S_VQW: if (vq_resp.ack) begin
                dec_memtel <= vq_resp.rdata;
                // refsw main path: after VQLookup returns the 64-bit codebook
                // entry, DecodeTextel uses the SAME texel offset -> 16-bit lane
                // = offset&3. (dec_off_lo already = ta_off[3:0] from S_WAIT.)
                st <= S_DEC;
            end
            S_DEC: begin
                if (pixfmt==3'd6) pal_idx <= pal8_idx;
                else if (pixfmt==3'd5) pal_idx <= pal4_idx;
                st <= S_ACK;
            end
            S_ACK: begin argb <= dec_argb; ack <= 1; st <= S_IDLE; end
            endcase
        end
    end
endmodule
