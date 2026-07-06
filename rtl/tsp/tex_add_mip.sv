//
// tex_add_mip - glue between tex_addroffsgen_ib and tex_fetch4_ob (combinational).
//
// Turns each corner's RELATIVE TEXEL offset (from tex_addroffsgen_ib) into a BYTE offset
// (for tex_fetch4_ob), applying the mip base offset (in texel space, BEFORE the fbpp
// byte-scale - it cannot be folded into the word base; see tex_base_addr) and the fbpp
// scale. Per refsw tex_addr:
//   off_full  = corner_texel_offset + mip_add          [texels]
//   byte_off  = (off_full << 1) >> fbpp_shr            [bytes]  (= off*fbpp/16)
//
// The mip add is the "4 extra adders" (one per corner). Byte offset can reach 22 bits
// (16bpp, twiddle+mip on a 1024x1024), so the output is 22 bits.
//
// COMBINATIONAL: the wrapping unit registers the outputs.
//
module tex_add_mip (
    input      [20:0] texel_offset [0:3],   // per-corner relative texel offset
    input      [23:0] mip_add,               // mip base offset in TEXELS (0 if !mipmapped)
    input      [2:0]  fbpp_shr,              // byte scale (byte_off = (off<<1)>>fbpp_shr)

    output     [21:0] byte_offset [0:3]      // per-corner byte offset (for tex_fetch4_ob)
);
    genvar gi;
    generate for (gi=0; gi<4; gi=gi+1) begin : corner
        // off_full = texel_offset + mip_add  (24b: mip_add is 24b, texel_offset 21b)
        wire [23:0] off_full = {3'd0, texel_offset[gi]} + mip_add;
        // byte_off = (off_full << 1) >> fbpp_shr. (off_full<<1) is 25b; >>shr (0..5).
        wire [24:0] byte_off = {off_full, 1'b0} >> fbpp_shr;
        assign byte_offset[gi] = byte_off[21:0];
    end endgenerate
endmodule
