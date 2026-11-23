// p2_pkg: the shared formats of docs/ARCHITECTURE.md section 2 (number formats, tags, the stream items, the ISP
// setup descriptor) and the widths of p2_core's interface (section 1.2).
//
// Widths of hardware number formats come from p2_hw_pkg (GENERATED from refcore's *HW structs); the parameter-word
// structs (p2_isptsp_t, p2_tsp_t, p2_tcw_t, p2_region_ctl_t, p2_listptr_t, p2_objent_*_t) and p2_rm_t (refsw3
// RenderMode) are in p2_regs_pkg (GENERATED). This package is hand-written and belongs to the architecture: a change to
// a type here goes with a change to ARCHITECTURE section 2.
//
// Field names follow ARCHITECTURE section 2, except where the name there is an SV keyword (`null`, `edge`): those
// are `null_` and `edges`. The fields of p2_edge_t and p2_ztile_t (section 2.4) are the table's; their units (M2,
// M3, M4) own them and may pack them differently when they land.
package p2_pkg;
  import p2_hw_pkg::*;
  import p2_regs_pkg::*;

  // ---------------------------------------------------------------------------------------------------------------
  // 1.2 p2_core's interface
  // ---------------------------------------------------------------------------------------------------------------
  localparam int P2_VRAM_HALVES   = 2;    // two 32-bit halves (tim 1, pvrsetup.h); half a[22] of a 32-bit-area address
  localparam int P2_VRAM_IDX_BITS = 20;   // 32-bit word index within a 4 MB half: a[21:2]
  localparam int P2_VRAM_SRC_BITS = 3;    // the client id of a request, returned with its response
  // VRAM clients (ARCHITECTURE 3.2)
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_SEQ        = 3'd0;   // C0 p2_seq: region array
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_OLW        = 3'd1;   // C1 p2_isp_olw: object lists
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_ISP_PFETCH = 3'd2;   // C2 p2_isp_pfetch: ISP parameters
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_TSP_PFETCH = 3'd3;   // C3 p2_tsp_pfetch: TSP parameters
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_TEX        = 3'd4;   // C4 p2_tex: texels, VQ codebooks
  localparam logic [P2_VRAM_SRC_BITS-1:0] P2_C_WOUT       = 3'd5;   // C5 p2_wout: framebuffer writes

  // the tile: 32 x 32 pixels, one row of 32 lanes a clock in the ISP
  localparam int P2_TILE_LOG2 = 5;
  localparam int P2_TILE      = 1 << P2_TILE_LOG2;
  localparam int P2_PIX_BITS  = 2 * P2_TILE_LOG2;   // a pixel's index in its tile, row major

  // ---------------------------------------------------------------------------------------------------------------
  // 2.1 number formats (num 1): value = (-1)^neg * mant * 2^exp, mant unnormalized, exp the exponent of mant bit 0;
  // exp is meaningful only when mant != 0; bad: an infinity or a NaN (num 1.1). Every primitive returns the
  // reference's tuple exactly (num 1.3).
  // ---------------------------------------------------------------------------------------------------------------
  localparam int P2_FP_EXP_BITS    = 10;                          // two's complement; reachable -300 .. 259 (num 1.4)
  localparam int P2_FP24_MANT_BITS = P2_ISP_EDGE_SUM_BITS;        // every setup product, sum, reciprocal (num 3.1-3.3)
  localparam int P2_FP20_MANT_BITS = P2_ISP_EDGE_START_BITS;      // edge and depth starts and steps (EdgeHW, DepthHW)
  localparam int P2_FP16_MANT_BITS = P2_TSP_PLANE_COEF_BITS;      // TSP coefficients A, B, C (PlaneHW::coefBits)
  localparam int P2_FP8_MANT_BITS  = 8;                           // mip: the literal Mul(., ., 8), cut(8) (num 3.4)
  localparam int P2_PVAL_MANT_BITS = P2_TSP_PLANE_VALUE_BITS + 1; // plane value; 2^16 only after a carry (num H12a)
  localparam int P2_QUOT_MANT_BITS = 18;                          // divider quotient q in [2^15, 2^17] (num H13)
  // p2_hw_check fails elaboration if a refcore width that one of these formats stands for differs from it

  // every setup operand and result (ISP edge / depth, TSP planes, mip K). The edge unit's swamp value 2^200 is
  // {neg, 0, 200, 1}
  typedef struct packed {
    logic                             neg;
    logic                             bad;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
    logic [P2_FP24_MANT_BITS-1:0]     mant;
  } p2_fp24_t;

  // edge s20, steps; depth start and slopes before blocking (num H2, N = 20)
  typedef struct packed {
    logic                             neg;
    logic                             bad;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
    logic [P2_FP20_MANT_BITS-1:0]     mant;
  } p2_fp20_t;

  // TSP coefficients A, B, C in the set-up store; kept as the tuple because H7b depends on exp (num 1.3, A1)
  typedef struct packed {
    logic                             neg;
    logic                             bad;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
    logic [P2_FP16_MANT_BITS-1:0]     mant;
  } p2_fp16_t;

  // mip K8, w8, ww, d (tsp 8)
  typedef struct packed {
    logic                             neg;
    logic                             bad;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
    logic [P2_FP8_MANT_BITS-1:0]      mant;
  } p2_fp8_t;

  // plane value after the normalizer, W and every attribute value: k = 0 is +0, k = -1 is {1, 1, -143}, exponent
  // floor -128 (num H12a)
  typedef struct packed {
    logic                             neg;
    logic [P2_PVAL_MANT_BITS-1:0]     mant;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
  } p2_pval_t;

  // divider output (num H13)
  typedef struct packed {
    logic                             neg;
    logic [P2_QUOT_MANT_BITS-1:0]     mant;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
  } p2_quot_t;

  // THE stored depth: refsw3 StoredDepth::k, the ISP's order, 32 bits finer than the float word. The only depth the
  // buffers hold and the comparators compare. Made and read only through p2_zword_pkg (ARCHITECTURE 2.1).
  typedef logic signed [63:0] p2_zkey_t;

  // ---------------------------------------------------------------------------------------------------------------
  // 2.2 words and tags
  // ---------------------------------------------------------------------------------------------------------------
  // the full ISP_BACKGND_T word (isp 3.5); refsw3 keeps all 32 bits in tagA, tagB, opTag, refTagC, resTag
  // (ClearBuffers(ISP_BACKGND_T.full)). The span sorter's key is all 32 bits, & ~7 with offset sort (refsw3 SpanSort;
  // p2_sort, M8; this comment said bits 23:0 before M8). Fields as pvr_regs.h ISP_BACKGND_T_type.
  typedef struct packed {
    logic [2:0]  hi;                    // [31:29] 0 for every primitive tag; the background tag keeps what software wrote
    logic        cache_bypass;          // [28]
    logic        shadow;                // [27]
    logic [2:0]  skip;                  // [26:24]
    logic [20:0] param_offs_in_words;   // [23:3] (ARCHITECTURE's param_offs)
    logic [2:0]  tag_offset;            // [2:0]
  } p2_tag_t;

  // refsw_tile.cpp KeyAbove: a background tag of 0xFFFFFFFF IS TAG_BELOW (at equal depth a fragment is drawn over
  // it); there is no separate "below" flag
  localparam logic [31:0] P2_TAG_BELOW = 32'hFFFF_FFFF;

  // ---------------------------------------------------------------------------------------------------------------
  // 2.3 stream formats
  // ---------------------------------------------------------------------------------------------------------------
  // the lists of a region array entry, in the order of p2_entry_t's ptr / empty (refsw3 RegionArrayEntry)
  localparam int P2_LISTS       = 5;
  localparam int P2_LIST_OP     = 0;
  localparam int P2_LIST_OP_MOD = 1;
  localparam int P2_LIST_TR     = 2;
  localparam int P2_LIST_TR_MOD = 3;
  localparam int P2_LIST_PT     = 4;

  // entry (p2_seq to p2_isp_ctl), valid/ready (isp 3.1)
  typedef struct packed {
    logic [5:0]                tilex;         // p2_region_ctl_t.tilex
    logic [5:0]                tiley;
    logic                      no_writeout;
    logic                      pre_sort;      // resolved: entry bit 29 (6-word entries) or ISP_FEED_CFG[0] (5-word)
    logic                      z_keep;
    logic                      last;
    logic [P2_LISTS-1:0][21:0] ptr;           // list word addresses (p2_listptr_t.ptr_in_words, bits 23:2)
    logic [P2_LISTS-1:0]       empty;         // PT is empty for 5-word entries
    logic [15:0]               idx;           // entry number in the render (debug, log)
  } p2_entry_t;

  localparam int P2_EPOCH_BITS = 7;   // the SHADE pass number modulo 128, counted by p2_isp_cut; in the sorter's key

  // run-stream item (p2_isp_cut ... p2_tbuf), valid/ready at every hop; 124 bits. Pass and entry boundaries are the
  // flags eop / eoe on the last item; a null_ item carries flags only (ARCHITECTURE 2.3)
  typedef struct packed {
    logic                     null_;    // ARCHITECTURE's `null`: an item with no pixels, carrying flags only
    p2_tag_t                  tag;
    logic [P2_TILE_LOG2-1:0]  y;        // line
    logic [P2_TILE_LOG2-1:0]  x;        // first column
    logic [P2_TILE_LOG2-1:0]  lenm1;    // length - 1
    p2_rm_t                   rm;       // the pass's RenderMode
    logic [P2_EPOCH_BITS-1:0] epoch;
    logic [P2_TILE-1:0]       vmask;    // stencil bit 0 of pixel x+i at bit i (i < len)
    logic [P2_TILE-1:0]       pmask;    // `rendered` of pixel x+i in PT_PASS0/N (run-only pixels) and PT_MV; 0 otherwise
    logic                     eop;      // the last item of its SHADE pass
    logic                     eoe;      // the last item of its region array entry: its record is at p2_entq's head
  } p2_rs_t;

  // entry record (p2_isp_cut to p2_tbuf through p2_entq); shaded_any is refsw3's tilePixelsShaded != 0
  typedef struct packed {
    logic [5:0] tilex;
    logic [5:0] tiley;
    logic       z_keep;
    logic       no_writeout;
    logic       last;
    logic       shaded_any;
  } p2_entrec_t;

  // feedback (p2_pp_blend to p2_isp_fb, PT passes only), valid/ready, in pixel order. PASS_DONE comes after the
  // pass's last PIXEL message and carries anyfail in `fail`
  typedef enum logic {
    P2_FB_PIXEL     = 1'b0,
    P2_FB_PASS_DONE = 1'b1
  } p2_fb_kind_t;

  typedef struct packed {
    p2_fb_kind_t            kind;
    logic [P2_PIX_BITS-1:0] idx;
    logic                   fail;
    logic                   ro;
  } p2_fb_t;

  // an object list entry that draws (p2_isp_olw to p2_isp_pfetch, ARCHITECTURE 3.4.2 `prim` as built in M6): one item a
  // strip entry (its mask; pfetch reads the block once and makes the triangles) or a triangle / quad array entry (its
  // count); links, type 110 and strips with an empty mask never leave olw (refsw_lists.cpp RenderObjectList)
  typedef enum logic [1:0] {
    P2_OBJ_STRIP = 2'd0,
    P2_OBJ_TRI   = 2'd1,   // type 100: prims + 1 triangles
    P2_OBJ_QUAD  = 2'd2    // type 101: prims + 1 quads
  } p2_obj_kind_t;

  typedef struct packed {
    p2_obj_kind_t kind;
    logic [20:0]  offs;     // param_offs_in_words: the strip's block, the array's first block
    logic [2:0]   skip;
    logic         shadow;
    logic [5:0]   mask;     // strip: triangle i drawn when bit 5 - i is set
    logic [3:0]   prims;    // array: prims + 1 primitives
  } p2_isp_obj_t;

  // the ISP buffer's sweeps (p2_isp_buf, ARCHITECTURE 3.4.7): one row a clock over the 32 rows, each refsw3's per-pixel
  // effect (refsw_tile.cpp)
  typedef enum logic [3:0] {
    P2_SW_CLEAR      = 4'd0,  // ClearBuffers(ISP_BACKGND_T, bgkey(ISP_BACKGND_D), 0): depthA, tagA, stencil 0, valid 1,
                              // rendered 0
    P2_SW_CLRSTATUS  = 4'd1,  // ClearParamStatusBuffer: valid = rendered = 0
    P2_SW_PT_INIT    = 4'd2,  // PeelBuffersPTInitial: depthC = depthA, opTag = refTagC = tagA, tagB = TAG_BELOW,
                              // valid = rendered = 0, stencil 0, everRendered = 0, rcur = rlp = 0 (resPass = -10)
    P2_SW_PT_CHUNK   = 4'd3,  // PeelBuffersPTChunk: rendered: depthC = resDepth, refTagC = resTag; everRendered |=
                              // rendered; valid = rendered = 0; tagB = TAG_BELOW; rcur = rlp = 0
    P2_SW_PASS_START = 4'd4,  // a punch-through pass (PtPass = p): rlp = rcur (resolved in the pass before), rcur = 0
    P2_SW_PT_FINAL   = 4'd5,  // PeelBuffersPTFinal: rendered |= everRendered; depthA, tagA = rendered ? resDepth,
                              // resTag : depthC, opTag
    P2_SW_PEEL       = 4'd6,  // PeelBuffers(key, 0): depthB, tagB = depthA, tagA; depthA = key; valid = rendered = 0;
                              // stencil 0 (tagA kept)
    P2_SW_SAVE       = 4'd7,  // SaveDepth: savedDepth = depthA
    P2_SW_RESTORE    = 4'd8   // RestoreDepth: depthA = savedDepth
  } p2_sweep_t;

  // an assembled primitive in one tile (p2_isp_pfetch to p2_isp_setup, ARCHITECTURE 3.4.3 `asm`), valid/ready: the
  // corners as the TA wrote them (raw IEEE single bits, rasterizer order; corner 4 for a quad only; the depth's three)
  typedef struct packed {
    logic [31:0]       isp;     // the ISP/TSP word: DepthMode / VolumeMode 31:29, CullMode 28:27, ZWriteDis 26
    p2_tag_t           tag;     // CoreTagFromDesc
    p2_rm_t            rm;      // the list's RenderMode
    logic              quad;    // a quad array's primitive: four corners, four edges
    logic [3:0][31:0]  x;
    logic [3:0][31:0]  y;
    logic [2:0][31:0]  z;
    logic [5:0]        tilex;   // the tile the primitive is set up in (the region array entry's)
    logic [5:0]        tiley;
  } p2_asm_t;

  // ---------------------------------------------------------------------------------------------------------------
  // 2.4 ISP setup to rasterizer descriptor, per primitive per tile (edge.h EdgeTile and depth.h DepthTileT at 4f3efe15)
  // ---------------------------------------------------------------------------------------------------------------
  // one edge in one tile (edge.h EdgeTile at refsw3 4f3efe15; ARCHITECTURE 2.4, isp 8.3-8.5). Values in half units of
  // 2^unit (unit = ep - 21, or E - cutUnitBits = 102 for a big edge). The widths are isp 8.5's bounds; M2's
  // testbench (tb/isp_edge) asserts every one on refsw3's own values. Built by p2_isp_edge_block, read by p2_isp_edge_row.
  localparam int P2_EDGE_T0_BITS   = 31;   // t0: |t0| < 2^29 (ordinary, d <= 29), < 2^27 (big)
  localparam int P2_EDGE_STEP_BITS = 28;   // tx, ty: < 2^22 (ordinary), < 2^27 (big)
  localparam int P2_EDGE_FAR_BITS  = 31;   // far32 in [0, 2^30]
  localparam int P2_EDGE_ZSH_BITS  = 4;    // zsh = d - 20: 7 .. 9
  localparam int P2_EDGE_LANE_BITS = 34;   // the row accumulator, the walk and the 32 lanes (isp 8.5: below 2^32.4)
  typedef struct packed {
    logic                                const_v;   // the whole tile has one answer: a bad corner, a point edge, no
                                                    // step, or d = E - unit >= 30 (isp 8.5)
    logic                                const_in;  // ... and that answer
    logic signed [P2_EDGE_T0_BITS-1:0]   t0;        // the start: 2 floor(s20 / 2^unit) + frac; a big edge 2 trunc(s20 / 2^102)
    logic signed [P2_EDGE_STEP_BITS-1:0] tx;        // column step (from -dy), even
    logic signed [P2_EDGE_STEP_BITS-1:0] ty;        // row step (from dx), even
    logic [P2_EDGE_ZSH_BITS-1:0]         zsh;       // zero2 = 2^zsh (tie2 = 2^(zsh + zeroShift - tieShift))
    logic                                big;       // E was capped at blockMax (ep >= 124): the walk decides each row
    logic [P2_EDGE_FAR_BITS-1:0]         far32;     // the walk's far term: tx > 0: (tx mod 2^25) << 5; tx < 0 with
                                                    // tx mod 2^25 == 0: 2^30; else 0 (edge.h Walk L404)
  } p2_edge_t;

  // the depth plane's regime (ARCHITECTURE 2.4; the names are the architecture's)
  typedef enum logic [1:0] {
    P2_Z_CONST = 2'd0,   // one key for the whole tile (refsw3 valid = false)
    P2_Z_REG   = 2'd1,   // a or b infinite (refsw3 ovf = 2): regdepth of a 30-bit register
    P2_Z_BLOCK = 2'd2    // a block-exponent fixed point t = S + 2i DX + 2j DY (refsw3 block = true)
  } p2_zregime_t;

  // the depth plane per tile (depth.h DepthTileT::Setup at refsw3 4f3efe15; ARCHITECTURE 2.4, isp 9.3-9.6). Every start
  // (r0, S) is the plane at the tile's first sample point, (left, top) + HALF_OFFSET[0] / 2 (0de9776b), and every pixel
  // whole steps from it: no field depends on HALF_OFFSET. Built by p2_isp_depth_setup (M3), read by
  // p2_isp_depth_raster; M3's testbench (tb/isp_depth) asserts the widths on refsw3's own values.
  localparam int P2_ZT_S_BITS    = 28;   // S: |S| < 2^27 half units of G (isp 9.4a)
  localparam int P2_ZT_STEP_BITS = 23;   // DX, DY: |DX|, |DY| < 2^21 units of G
  localparam int P2_ZT_T_BITS    = 30;   // the lanes' t = S + 2i DX + 2j DY: |t| < 2^29 (isp 9.4a; widths4f3d 2^28.45)
  localparam int P2_ZT_NSH_BITS  = 5;    // nsh = E - 15 - gexp: -14 .. 14 wherever a start is left (isp 9.6)
  localparam int P2_ZT_REG_BITS  = 30;   // the REG register r mod 2^30 (units of 2^102, its sign at 2^131)
  typedef struct packed {
    p2_zregime_t                        regime;
    p2_zkey_t                           key;    // CONST: the key of every pixel
    logic signed [P2_ZT_REG_BITS-1:0]   r0;     // REG: the start in units of 2^102 (|r0| < 2^26)
    logic signed [1:0]                  sa;     // REG: the overflowed slopes' steps, -1 / 0 / +1 (units of 2^25)
    logic signed [1:0]                  sb;
    logic signed [30:0]                 fa;     // REG: the finite slope's step on the 2^102 grid, +-(0 .. 2^30 - 1)
    logic signed [30:0]                 fb;
    logic signed [P2_ZT_S_BITS-1:0]     S;      // BLOCK: d0 in half units of G
    logic signed [P2_ZT_STEP_BITS-1:0]  DX;     // BLOCK: units of G
    logic signed [P2_ZT_STEP_BITS-1:0]  DY;
    logic signed [9:0]                  gexp;   // BLOCK: G = 2^gexp = 2^(max(e, pair + 5) - 26)
    logic signed [8:0]                  E;      // BLOCK: the clamped block exponent, -122 .. 128
    logic signed [P2_ZT_NSH_BITS-1:0]   nsh;    // BLOCK: E - 15 - gexp (saturated where fbw)
    logic                               fbw;    // BLOCK: the start was cut to zero and E - 15 - gexp < 0: every pixel
                                                // below zero is NegWord's fallback word (num A5)
  } p2_ztile_t;

  typedef enum logic [1:0] {
    P2_SUM_NONE = 2'd0,
    P2_SUM_OR   = 2'd1,   // VolumeMode 1
    P2_SUM_AND  = 2'd2    // VolumeMode 2; VolumeMode 3..7 is P2_SUM_NONE (isp 15 #16)
  } p2_sum_op_t;

  typedef struct packed {
    p2_tag_t                 tag;
    p2_rm_t                  rm;
    logic [2:0]              depth_mode;   // ISP word 31:29
    logic                    zwdis;
    logic                    quad;
    p2_sum_op_t              sum_op;       // MODIFIER only
    logic                    kill;         // no pixel inside: a culled or bad-corner primitive that has a sum_op
    p2_edge_t [3:0]          edges;        // ARCHITECTURE's edge[0:3]
    logic [P2_TILE_LOG2-1:0] jf;           // tile rows to step: non-MODIFIER the row range (isp 8.6) with the
    logic [P2_TILE_LOG2-1:0] jl;           // row-31 shift, clipped to 0..31; MODIFIER 0..31
    logic                    rows_v;
    p2_ztile_t               z;
  } p2_rdesc_t;

endpackage
