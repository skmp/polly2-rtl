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
  // (ClearBuffers(ISP_BACKGND_T.full)). The sort key is bits 23:0. Fields as pvr_regs.h ISP_BACKGND_T_type.
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

  // ---------------------------------------------------------------------------------------------------------------
  // 2.4 ISP setup to rasterizer descriptor, per primitive per tile (edge.h EdgeTile, depth.h DepthTileT at 708fb8cd)
  // ---------------------------------------------------------------------------------------------------------------
  // one edge (edge.h EdgeTile); the widths are ARCHITECTURE 2.4's bounds, asserted by M2
  typedef struct packed {
    logic               const_v;   // the whole tile has one answer: bad corner, point edge, or d = E - unit >= 30
    logic               const_in;  // ... and that answer
    logic signed [30:0] t0;        // start in half units of 2^unit
    logic signed [22:0] tx;        // column step (from -dy), half units, even
    logic signed [22:0] ty;        // row step (from dx), half units, even
    logic [3:0]         zsh;       // zero2 = tie2 = 2^zsh half units, zsh = d - 20
    logic               big;       // E was capped (ep >= 124): the walk decides each row
    logic signed [33:0] f0;        // the start in half units of 2^fine, fine = unit - 6 = ep - 27
    logic signed [29:0] fx;        // the steps in the same fine units
    logic signed [29:0] fy;
    logic [2:0]         hsh;       // H = 2^131 in fine half units: hsh = 132 - fine - 31 (31..35 encoded 0..4)
    logic [3:0]         zfsh;      // z = 2^(136 - ep) fine half units (8..12)
    logic [35:0]        far32;     // fx > 0 ? (32 fx) mod H : 0 (edge.h Walk)
  } p2_edge_t;

  // the depth plane's regime (ARCHITECTURE 2.4; the names are the architecture's)
  typedef enum logic [1:0] {
    P2_Z_CONST = 2'd0,   // one key for the whole tile
    P2_Z_REG   = 2'd1,   // a or b infinite (refsw3 ovf = 2): regdepth of a 30-bit register
    P2_Z_BLOCK = 2'd2    // a block-exponent fixed point t = S + (2i + h) DX + (2j + h) DY
  } p2_zregime_t;

  // the depth plane per tile (depth.h DepthTileT::Setup)
  typedef struct packed {
    p2_zregime_t        regime;
    p2_zkey_t           key;    // CONST
    logic signed [29:0] r0;     // REG: units of 2^102
    logic signed [1:0]  sa;     // REG: -1 / 0 / +1
    logic signed [1:0]  sb;
    logic signed [30:0] fa;     // REG: the finite slope's step on the 2^102 grid, mod 2^30
    logic signed [30:0] fb;
    logic signed [27:0] S;      // BLOCK: d0 in half units of G
    logic signed [22:0] DX;     // BLOCK: units of G
    logic signed [22:0] DY;
    logic signed [9:0]  gexp;   // BLOCK: G = 2^gexp
    logic signed [8:0]  E;      // BLOCK: the clamped block exponent, -122 .. 128
    logic [4:0]         nsh;    // BLOCK: E - 15 - gexp
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
