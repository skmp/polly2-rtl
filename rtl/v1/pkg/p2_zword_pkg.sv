// p2_zword_pkg: every function that makes or reads a stored-depth key (p2_zkey_t), named after refsw3 (refcore
// pvr_isp_depth.h StoredDepth at 708fb8cd, and the background block of refsw_lists.cpp RenderCORE); the one boundary
// the stored-depth format lives behind (ARCHITECTURE 2.1, 3.11 H14).
//
// SIGNATURES ONLY (PLAN M0). The bodies are M1b's (PLAN M1b, num H14 as superseded by ARCHITECTURE 0.1). Until then
// every function returns 0 and, in simulation, stops with an error when it is called.
//
// The names are short and common (neg, big, bits): call them package-qualified, p2_zword_pkg::neg(e, m), rather than
// through a wildcard import, so they cannot collide with a unit's own signals.
package p2_zword_pkg;
  import p2_pkg::*;

  // StoredDepth::Key32: the word read as a signed 32-bit key, a negative word's fraction bits inverted;
  // 0x80000000 (-0) is 0 (zsign, bgspec, bgneg, bgneg2)
  function automatic logic signed [31:0] key32(input logic [31:0] w);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::key32 is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Bits: the key of the word w, key32(w) << 32
  function automatic p2_zkey_t bits(input logic [31:0] w);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::bits is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Between: between the word w and the next one in the ISP's order, at off (1 .. 2^32 - 1):
  // (key32(w) << 32) + off
  function automatic p2_zkey_t between(input logic [31:0] w, input logic [31:0] off);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::between is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::FromFp: v as a float word, to nearest, ties to even, on the denormal grid below 2^-126; Saturated
  // from 2^128 and for a bad v. v has at most 19 bits here (cut_19 of a pixel's value, DepthHW::storedBits)
  function automatic p2_zkey_t from_fp(input p2_fp20_t v);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::from_fp is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Big: a depth above zero of 2^128 or more, at most 19 bits, above every float word (depthgaps_bigpos,
  // depthgaps_bigord)
  function automatic p2_zkey_t big(input p2_fp20_t v);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::big is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Neg: a depth below zero of block exponent e (-122 .. 128) and value m 2^(e - 16), m < 0; the float
  // word in the block's top binade, between two fields' words outside it (perpmean_*, depthgaps_neg*)
  function automatic p2_zkey_t neg(input logic signed [9:0] e, input logic signed [30:0] m);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::neg is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Flat(v, startBits, storedBits): a flat depth as the depth unit stores one (a plane without slopes,
  // a determinant-zero mean); a bad v is saturated(v.neg)
  function automatic p2_zkey_t flat(input p2_fp24_t v);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::flat is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // StoredDepth::Saturated: +-2^127, the depth of a polygon whose plane overflows (bgbig, bgspec, zsign page 15)
  function automatic p2_zkey_t saturated(input logic sign);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::saturated is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // DepthTileT::RegDepth: the depth of an overflowing plane's 30-bit register r (two's complement, units of 2^102;
  // refsw3 wraps its 64-bit r to these 30 bits first) (zword, nantr_*, depthgaps_mm)
  function automatic p2_zkey_t regdepth(input logic signed [29:0] r);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::regdepth is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

  // the background's key from ISP_BACKGND_D (refsw_lists.cpp RenderCORE, the bgZ block; bgdepth, bgtie, bgneg,
  // bgneg2, bgspec, bgbig, depthgaps_bglow*, depthgaps_bgpin)
  function automatic p2_zkey_t bgkey(input logic [31:0] bg);
`ifndef SYNTHESIS
    $error("p2_zword_pkg::bgkey is not implemented yet (M1b)");
`endif
    return '0;
  endfunction

endpackage
