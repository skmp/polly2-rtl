//
// tsp_pkg - packed-struct port bundles for dependency injection of the texture
// caches and the DDR3 read port. Using plain packed structs (no SV interfaces)
// keeps the design maximally tool-portable while still letting a cache be
// "injected" into a consumer (tex_fetch/tsp_shade) and the DDR3 port be injected
// into a cache - the concrete instances live at the top and are wired through by
// passing these bundles down the hierarchy.
//
package tsp_pkg;

    // ---- PVR instruction-word bit structs (mirror refsw2 core_structs.h) ----
    // Packed-struct field order is MSB->LSB, i.e. the REVERSE of the C bitfield
    // declaration order (C lists LSB first). Overlay onto a 32-bit word with
    // isp_tsp_t'(word) / tsp_t'(word) / tcw_t'(word), then read w.Field.
    //
    //   union ISP_TSP { u32 Reserved:20; DCalcCtrl:1; CacheBypass:1; UV_16b:1;
    //                   Gouraud:1; Offset:1; Texture:1; ZWriteDis:1; CullMode:2;
    //                   DepthMode:3; }
    typedef struct packed {
        logic [2:0]  DepthMode;    // [31:29]
        logic [1:0]  CullMode;     // [28:27]
        logic        ZWriteDis;    // [26]
        logic        Texture;      // [25]
        logic        Offset;       // [24]
        logic        Gouraud;      // [23]
        logic        UV_16b;       // [22]
        logic        CacheBypass;  // [21]
        logic        DCalcCtrl;    // [20]
        logic [19:0] Reserved;     // [19:0]
    } isp_tsp_t;

    //   union TSP { TexV:3; TexU:3; ShadInstr:2; MipMapD:4; SupSample:1;
    //               FilterMode:2; ClampV:1; ClampU:1; FlipV:1; FlipU:1;
    //               IgnoreTexA:1; UseAlpha:1; ColorClamp:1; FogCtrl:2;
    //               DstSelect:1; SrcSelect:1; DstInstr:3; SrcInstr:3; }
    typedef struct packed {
        logic [2:0]  SrcInstr;     // [31:29]
        logic [2:0]  DstInstr;     // [28:26]
        logic        SrcSelect;    // [25]
        logic        DstSelect;    // [24]
        logic [1:0]  FogCtrl;      // [23:22]
        logic        ColorClamp;   // [21]
        logic        UseAlpha;     // [20]
        logic        IgnoreTexA;   // [19]
        logic        FlipU;        // [18]
        logic        FlipV;        // [17]
        logic        ClampU;       // [16]
        logic        ClampV;       // [15]
        logic [1:0]  FilterMode;   // [14:13]
        logic        SupSample;    // [12]
        logic [3:0]  MipMapD;      // [11:8]
        logic [1:0]  ShadInstr;    // [7:6]
        logic [2:0]  TexU;         // [5:3]
        logic [2:0]  TexV;         // [2:0]
    } tsp_t;

    //   union TCW { TexAddr:21; Reserved:4; StrideSel:1; ScanOrder:1; PixelFmt:3;
    //               VQ_Comp:1; MipMapped:1; }  (PalSelect overlays TexAddr[20:15])
    typedef struct packed {
        logic        MipMapped;    // [31]
        logic        VQ_Comp;      // [30]
        logic [2:0]  PixelFmt;     // [29:27]
        logic        ScanOrder;    // [26]
        logic        StrideSel;    // [25]
        logic [3:0]  Reserved;     // [24:21]
        logic [20:0] TexAddr;      // [20:0]  (PalSelect = TexAddr[20:15])
    } tcw_t;

    // ---- DDR3 raw 64-bit read port ----
    // request: cache -> DDR arbiter
    typedef struct packed {
        logic        rd;        // read strobe (accepted when !resp.busy)
        logic [28:0] addr;      // 64-bit-word address ({4'b0011, waddr[24:0]})
        logic [7:0]  burst;     // burst count (1 for a single 64-bit line)
    } ddr_rd_req_t;
    // response: DDR arbiter -> cache
    typedef struct packed {
        logic        busy;      // cannot accept a read this cycle
        logic [63:0] dout;      // read data
        logic        dready;    // dout valid this cycle
    } ddr_rd_resp_t;

    // ---- framebuffer pixel WRITE port (injected DDR-controller dependency) ----
    // The peel_core streams each shaded tile's colour buffer out through this port,
    // one 32-bit ARGB pixel per accepted cycle at a linear pixel index (y*640+x).
    // Injected: the sim wrapper writes a behavioral fb[] array; mister_top packs
    // pixels into 64-bit words and bursts them to the real DDR framebuffer region.
    typedef struct packed {
        logic        we;        // 1 = present a pixel this cycle (consumed when !busy)
        logic [19:0] pix_idx;   // linear pixel index (y*640 + x), 0..307199
        logic [10:0] px;        // screen x (0..1279: SCALER_CTL.hscale renders
                                // are 1280 wide before the x1/2 write-out)
        logic [9:0]  py;        // screen y (0..479) - addressing + dither phase
        logic [31:0] argb;      // 32-bit ARGB colour
    } fb_wr_req_t;
    typedef struct packed {
        logic        busy;      // 1 = cannot accept a pixel this cycle (hold)
    } fb_wr_resp_t;

    // ---- cache client port (a 64-bit direct-mapped line cache) ----
    // request: client (tex_fetch) -> cache
    typedef struct packed {
        logic        req;       // 1-cycle request strobe
        logic [28:0] waddr;     // 64-bit-word address
    } cache_req_t;
    // response: cache -> client
    typedef struct packed {
        logic        ack;       // 1-cycle response strobe (result valid this cycle)
        logic [63:0] rdata;     // 64-bit line
        logic        ready;     // STREAMING cache (tex_cache_4p): 1 = can accept a new
                                //   req this cycle (backpressure). Plain tex_cache (the
                                //   serial lp path) leaves this 1 when idle / unused.
    } cache_resp_t;

    // (The 256-bit line data-cache client port cache_req256_t/cache_resp256_t was
    //  removed with data_cache256 - all readers now use a direct-DDR 8-word
    //  sliding-window line reader.)

    // ---- PVR core tag (mirrors ISP_BACKGND_T_type, pvr_regs.h:318) ----
    // Packed so that {msb..lsb} == the 32-bit tag word: bit31=invalid,
    // [30:29]=pad, [28]=cache_bypass, [27]=shadow, [26:24]=skip,
    // [23:3]=param_offs_in_words, [2:0]=tag_offset.
    typedef struct packed {
        logic        invalid;              // bit 31  (TAG_INVALID)
        logic [1:0]  pad;                  // bits 30:29
        logic        cache_bypass;         // bit 28
        logic        shadow;               // bit 27
        logic [2:0]  skip;                 // bits 26:24
        logic [20:0] param_offs_in_words;  // bits 23:3
        logic [2:0]  tag_offset;           // bits 2:0
    } core_tag_t;                          // == 32 bits

    // entry type emitted by the object-list parser
    typedef enum logic [1:0] {
        ENT_STRIP = 2'd0,   // triangle strip
        ENT_TRI   = 2'd1,   // triangle array
        ENT_QUAD  = 2'd2    // quad array
    } entry_type_e;

    // ---- decoded object-list entry fields (ObjectListTstrip/Tarray/Qarray
    // layout, refsw_lists_regtypes.h) - NOT the core tag (ISP_BACKGND_T_type
    // has a DIFFERENT bit layout and is built via CoreTagFromDesc by whoever
    // needs it; the parser does not do that repacking). `mask` is meaningful
    // for ENT_STRIP (bit i set => triangle i exists, i=0..5); `count` is
    // meaningful for ENT_TRI/ENT_QUAD (count = number of array elements,
    // i.e. refsw's `prims+1`). The consumer picks which sub-element(s) to
    // process using these raw fields directly. ----
    typedef struct packed {
        logic [20:0] param_offs_in_words;  // as read from the entry (E[20:0])
        logic [2:0]  skip;                 // E[23:21]
        logic        shadow;               // E[24]
        logic [5:0]  mask;                 // strip only: E[30:25]
        logic [4:0]  count;                // array only: prims+1 (1..16)
    } objlist_entry_t;

    // ---- object-list parser output: one ENTRY at a time (not one primitive) ----
    // The parser is a pure LIST WALKER: it reads one object-list entry,
    // classifies it, and presents entry_ready (LEVEL) with entry_type + the
    // decoded entry fields (mask/count/param_offs/skip/shadow) held stable. It
    // does NOT iterate strip triangles or array elements itself, chase
    // param_offs_in_words to the parameter buffer, decode vertices, or build
    // the ISP_BACKGND_T_type core tag - all of that (including which
    // sub-element to process next) is the consumer's job (param_fetch, shared
    // with the TSP plane cache's miss path).
    //
    // Handshake: parser raises entry_ready with fields stable; the consumer
    // processes the WHOLE entry (e.g. iterating every set mask bit / every
    // array index itself) and pulses entry_done (1 cycle) when done with it;
    // the parser then drops entry_ready and advances to the next list entry.
    typedef struct packed {
        logic           entry_ready;   // LEVEL: an entry is presented + stable
        entry_type_e    entry_type;    // ENT_STRIP / ENT_TRI / ENT_QUAD
        objlist_entry_t entry;         // decoded object-list entry fields
    } prim_out_t;
    typedef struct packed {
        logic      entry_done;   // 1-cycle: consumer finished this entry
    } prim_ack_t;

    // one decoded vertex (raw 32-bit param words placed into named fields;
    // float/format interpretation is left to the consumer). UV/ofs are only
    // meaningful when the record's isp word enables Texture/Offset. Produced by
    // param_fetch (tag -> header + vertices), NOT by object_list_parser.
    typedef struct packed {
        logic [31:0] x, y, z;      // position (raw float bits)
        logic [31:0] u, v;         // texture coords (raw; f16 pair packed in u if UV_16b)
        logic [31:0] col;          // base colour (packed ARGB word)
        logic [31:0] ofs;          // offset colour (packed word)
    } vtx_words_t;

    // ---- region_array_parser output: one STATE at a time per tile ----
    // For each region-array entry (tile), the parser strobes the tile's enabled
    // states in order (clear -> op -> pt -> tr -> flush), one per handshake:
    // it raises state_ready (LEVEL) with tile x/y, a one-hot `state`, and (for
    // op/pt/tr) the list base pointer (byte addr = ListPointer.ptr_in_words*4);
    // the consumer processes that state and pulses list_done (1-cycle); the
    // parser then advances to the tile's next enabled state, or the next tile.
    // A tile with NO enabled states is silently skipped. tiles_parsed pulses
    // when the whole region array is consumed (control.last_region, or after
    // 16384 tiles as a runaway guard). ptr is 0 for clear/flush (no list).
    //
    // State derivation from the region entry (refsw RenderCORE):
    //   clear = !control.z_keep          (bit 30 inverted)
    //   op    = !opaque.empty            (opaque   ListPointer)
    //   pt    = !puncht.empty            (puncht   ListPointer)
    //   tr    = !trans.empty             (trans    ListPointer)
    //   flush = !control.no_writeout     (bit 28 inverted -> tile written out)
    typedef enum logic [4:0] {
        RSTATE_CLEAR = 5'b00001,
        RSTATE_OP    = 5'b00010,
        RSTATE_PT    = 5'b00100,
        RSTATE_TR    = 5'b01000,
        RSTATE_FLUSH = 5'b10000
    } region_state_e;
    typedef struct packed {
        logic          list_ready;    // LEVEL: a (tile,state) is presented + stable
        logic [5:0]    tile_x;        // control.tilex (tile column; *32 for pixels)
        logic [5:0]    tile_y;        // control.tiley
        logic [4:0]    state;         // one-hot region_state_e
        logic [26:0]   list_ptr;      // byte addr of the list (op/pt/tr); 0 for clear/flush
        logic          writeout;      // FLUSH only: !control.no_writeout (this entry writes
                                       // out to VRAM). RSTATE_FLUSH is now emitted for EVERY
                                       // entry as the end-of-entry marker (so per-entry PT/TL
                                       // peels happen); writeout=0 means peel+accumulate but
                                       // do NOT post the tile to VO yet.
        logic          z_keep;        // CLEAR only: control.z_keep. RSTATE_CLEAR is now emitted
                                       // for EVERY entry as the start-of-entry marker. z_keep=0
                                       // => full clear (bg tag+depth). z_keep=1 => KEEP depth,
                                       // only invalidate the tag buffer (so this entry's OP
                                       // shade renders ONLY its own OP triangles, not the bg -
                                       // refsw invalidates tags after each RenderParamTags).
    } region_out_t;
    typedef struct packed {
        logic      list_done;   // 1-cycle: consumer finished this state
    } region_ack_t;

    // ---- isp_primitive_iterator output: one triangle at a time ----
    // Iterates a single ENT_STRIP entry's masked triangles (i=0..5 where
    // mask[i] set), reading only XYZ per vertex (UV/color/offset ignored for
    // now). Handshake mirrors object_list_parser: triangle_ready (LEVEL, XYZ
    // x3 + isp word stable) <-> triangle_done (1-cycle pulse). When the strip
    // is exhausted the iterator pulses prim_done (to ITS OWN caller, signalling
    // it is finished with the whole entry - same shape as entry_done one level
    // up the hierarchy).
    typedef struct packed {
        logic [31:0] x, y, z;
    } xyz_t;
    typedef struct packed {
        logic          triangle_ready;   // LEVEL: a triangle's 3 vertices are stable
        logic [31:0]   isp;              // record's ISP_TSP word (Cull/Depth/ZWrite etc)
        xyz_t          v0, v1, v2;       // the triangle's 3 vertices (XYZ only)
        logic          quad;             // 1: ENT_QUAD record - v3x/v3y hold the 4th
                                         // vertex (edges become 12/23/34/41). The 4th
                                         // vertex's Z is never used (refsw2 PlaneStepper3
                                         // takes v0..v2 only), so it is not carried.
        logic [31:0]   v3x, v3y;         // 4th vertex X/Y (valid when quad)
        core_tag_t     tag;              // this triangle's CoreTag (CoreTagFromDesc:
                                         // isp.CacheBypass/shadow/skip/param_offs + i)
        logic          is_pt;            // list-membership: this triangle came from the PT
                                         // list (not TL). Per-triangle so PT and TL can flow
                                         // back-to-back through the FIFOs (drives dt_pt).
        logic          prim_done;        // 1-cycle: whole strip entry finished
    } triangle_out_t;
    typedef struct packed {
        logic      triangle_done;   // 1-cycle: consumer finished this triangle
    } triangle_ack_t;

    // ---- PVR named register file (reg_file) ----
    // The full scalar PVR register set (names, real byte offsets, and bitfield
    // struct types) is AUTO-GENERATED from minicast pvr_regs.h. See
    // tools/gen_pvr_regs.py; regenerate into rtl/tsp/gen/pvr_regs_gen.svh.
    // This provides: OFF_<NAME> (13-bit byte offset) for every scalar register,
    // a packed struct type <name>_reg_t for each bitfield register, and the
    // aggregate pvr_regs_t. Table regions (FOG 0x200, PAL 0x1000) are NOT in the
    // struct - reg_file backs them with M10K + dedicated read ports below.
    localparam [12:0] OFF_FOG_TABLE_LO  = 13'h200;   // FOG_TABLE_START
    localparam [12:0] OFF_FOG_TABLE_HI  = 13'h3FC;   // FOG_TABLE_END
    localparam [12:0] OFF_PAL_RAM_LO    = 13'h1000;  // PALETTE_RAM_START
    localparam [12:0] OFF_PAL_RAM_HI    = 13'h1FFC;  // PALETTE_RAM_END
`include "pvr_regs_gen.svh"

    // PAL / FOG table read-port bundles (injected read: addr in -> data out).
    typedef struct packed { logic [9:0] raddr; } pal_rd_req_t;   // 0..1023
    typedef struct packed { logic [31:0] rdata; } pal_rd_resp_t;
    typedef struct packed { logic [6:0] raddr; } fog_rd_req_t;   // 0..127
    typedef struct packed { logic [31:0] rdata; } fog_rd_resp_t;

    // ISP word (ISP_TSP) bit positions (LSB-first, core_structs.h:59):
    //   CacheBypass=21, UV_16b=22, Gouraud=23, Offset=24, Texture=25,
    //   ZWriteDis=26, CullMode=[28:27], DepthMode=[31:29].
    localparam int ISP_CACHEBYPASS_BIT = 21;
    localparam int ISP_UV16_BIT        = 22;
    localparam int ISP_GOURAUD_BIT     = 23;
    localparam int ISP_OFFSET_BIT      = 24;
    localparam int ISP_TEXTURE_BIT     = 25;

    // ---- tsp_setup dependency injected into the plane cache ----
    // request out (plane cache -> setup) : start + vertices/flags
    typedef struct packed {
        logic        start;
        logic        gouraud, texture, offset;
        logic [31:0] x1,y1,z1, x2,y2,z2, x3,y3,z3, xbase,ybase;
        logic [31:0] u1,v1, u2,v2, u3,v3;
        logic [31:0] col1,col2,col3, ofs1,ofs2,ofs3;
    } setup_req_t;
    // response in (setup -> plane cache) : streamed planes + done
    typedef struct packed {
        logic        plane_valid;
        logic [3:0]  plane_idx;
        logic [31:0] o_ddx, o_ddy, o_c;
        logic        done;
    } setup_resp_t;

endpackage
