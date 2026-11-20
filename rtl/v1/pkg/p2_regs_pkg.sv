// GENERATED: do not edit. tools/gen/gen_regs.py from nulldc3 libswirl/hw/pvr/pvr_regs.h,
// refsw3/refcore/core_structs.h, refsw3/refcore/refsw_lists_regtypes.h and refsw3/refcore/refsw_lists.h (enum RenderMode).
// Regenerate: make regs-pkg; check: make regs-pkg-check. Structs are MSB first (the C bitfields are LSB first);
// a field named like an SV keyword has a trailing underscore (type_).
package p2_regs_pkg;

  // ---- register byte offsets in the 8 KB block (libswirl/hw/pvr/pvr_regs.h <NAME>_addr) ----
  localparam logic [12:0] P2_REG_ID                   = 13'h0000;
  localparam logic [12:0] P2_REG_REVISION             = 13'h0004;
  localparam logic [12:0] P2_REG_SOFTRESET            = 13'h0008;
  localparam logic [12:0] P2_REG_STARTRENDER          = 13'h0014;
  localparam logic [12:0] P2_REG_TEST_SELECT          = 13'h0018;
  localparam logic [12:0] P2_REG_PARAM_BASE           = 13'h0020;
  localparam logic [12:0] P2_REG_REGION_BASE          = 13'h002C;
  localparam logic [12:0] P2_REG_SPAN_SORT_CFG        = 13'h0030;
  localparam logic [12:0] P2_REG_VO_BORDER_COL        = 13'h0040;
  localparam logic [12:0] P2_REG_FB_R_CTRL            = 13'h0044;
  localparam logic [12:0] P2_REG_FB_W_CTRL            = 13'h0048;
  localparam logic [12:0] P2_REG_FB_W_LINESTRIDE      = 13'h004C;
  localparam logic [12:0] P2_REG_FB_R_SOF1            = 13'h0050;
  localparam logic [12:0] P2_REG_FB_R_SOF2            = 13'h0054;
  localparam logic [12:0] P2_REG_FB_R_SIZE            = 13'h005C;
  localparam logic [12:0] P2_REG_FB_W_SOF1            = 13'h0060;
  localparam logic [12:0] P2_REG_FB_W_SOF2            = 13'h0064;
  localparam logic [12:0] P2_REG_FB_X_CLIP            = 13'h0068;
  localparam logic [12:0] P2_REG_FB_Y_CLIP            = 13'h006C;
  localparam logic [12:0] P2_REG_FPU_SHAD_SCALE       = 13'h0074;
  localparam logic [12:0] P2_REG_FPU_CULL_VAL         = 13'h0078;
  localparam logic [12:0] P2_REG_FPU_PARAM_CFG        = 13'h007C;
  localparam logic [12:0] P2_REG_HALF_OFFSET          = 13'h0080;
  localparam logic [12:0] P2_REG_FPU_PERP_VAL         = 13'h0084;
  localparam logic [12:0] P2_REG_ISP_BACKGND_D        = 13'h0088;
  localparam logic [12:0] P2_REG_ISP_BACKGND_T        = 13'h008C;
  localparam logic [12:0] P2_REG_ISP_FEED_CFG         = 13'h0098;
  localparam logic [12:0] P2_REG_SDRAM_REFRESH        = 13'h00A0;
  localparam logic [12:0] P2_REG_SDRAM_ARB_CFG        = 13'h00A4;
  localparam logic [12:0] P2_REG_SDRAM_CFG            = 13'h00A8;
  localparam logic [12:0] P2_REG_FOG_COL_RAM          = 13'h00B0;
  localparam logic [12:0] P2_REG_FOG_COL_VERT         = 13'h00B4;
  localparam logic [12:0] P2_REG_FOG_DENSITY          = 13'h00B8;
  localparam logic [12:0] P2_REG_FOG_CLAMP_MAX        = 13'h00BC;
  localparam logic [12:0] P2_REG_FOG_CLAMP_MIN        = 13'h00C0;
  localparam logic [12:0] P2_REG_SPG_TRIGGER_POS      = 13'h00C4;
  localparam logic [12:0] P2_REG_SPG_HBLANK_INT       = 13'h00C8;
  localparam logic [12:0] P2_REG_SPG_VBLANK_INT       = 13'h00CC;
  localparam logic [12:0] P2_REG_SPG_CONTROL          = 13'h00D0;
  localparam logic [12:0] P2_REG_SPG_HBLANK           = 13'h00D4;
  localparam logic [12:0] P2_REG_SPG_LOAD             = 13'h00D8;
  localparam logic [12:0] P2_REG_SPG_VBLANK           = 13'h00DC;
  localparam logic [12:0] P2_REG_SPG_WIDTH            = 13'h00E0;
  localparam logic [12:0] P2_REG_TEXT_CONTROL         = 13'h00E4;
  localparam logic [12:0] P2_REG_VO_CONTROL           = 13'h00E8;
  localparam logic [12:0] P2_REG_VO_STARTX            = 13'h00EC;
  localparam logic [12:0] P2_REG_VO_STARTY            = 13'h00F0;
  localparam logic [12:0] P2_REG_SCALER_CTL           = 13'h00F4;
  localparam logic [12:0] P2_REG_PAL_RAM_CTRL         = 13'h0108;
  localparam logic [12:0] P2_REG_SPG_STATUS           = 13'h010C;
  localparam logic [12:0] P2_REG_FB_BURSTCTRL         = 13'h0110;
  localparam logic [12:0] P2_REG_FB_C_SOF             = 13'h0114;
  localparam logic [12:0] P2_REG_Y_COEFF              = 13'h0118;
  localparam logic [12:0] P2_REG_PT_ALPHA_REF         = 13'h011C;
  localparam logic [12:0] P2_REG_TA_OL_BASE           = 13'h0124;
  localparam logic [12:0] P2_REG_TA_ISP_BASE          = 13'h0128;
  localparam logic [12:0] P2_REG_TA_OL_LIMIT          = 13'h012C;
  localparam logic [12:0] P2_REG_TA_ISP_LIMIT         = 13'h0130;
  localparam logic [12:0] P2_REG_TA_NEXT_OPB          = 13'h0134;
  localparam logic [12:0] P2_REG_TA_ISP_CURRENT       = 13'h0138;
  localparam logic [12:0] P2_REG_TA_GLOB_TILE_CLIP    = 13'h013C;
  localparam logic [12:0] P2_REG_TA_ALLOC_CTRL        = 13'h0140;
  localparam logic [12:0] P2_REG_TA_LIST_INIT         = 13'h0144;
  localparam logic [12:0] P2_REG_TA_YUV_TEX_BASE      = 13'h0148;
  localparam logic [12:0] P2_REG_TA_YUV_TEX_CTRL      = 13'h014C;
  localparam logic [12:0] P2_REG_TA_YUV_TEX_CNT       = 13'h0150;
  localparam logic [12:0] P2_REG_TA_LIST_CONT         = 13'h0160;
  localparam logic [12:0] P2_REG_TA_NEXT_OPB_INIT     = 13'h0164;
  localparam logic [12:0] P2_REG_FOG_TABLE_START      = 13'h0200;
  localparam logic [12:0] P2_REG_FOG_TABLE_END        = 13'h03FC;
  localparam logic [12:0] P2_REG_TA_OL_POINTERS_START = 13'h0600;
  localparam logic [12:0] P2_REG_TA_OL_POINTERS_END   = 13'h0F5C;
  localparam logic [12:0] P2_REG_PALETTE_RAM_START    = 13'h1000;
  localparam logic [12:0] P2_REG_PALETTE_RAM_END      = 13'h1FFC;

  // ---- register fields (libswirl/hw/pvr/pvr_regs.h union <NAME>_type, its first struct) ----
  typedef struct packed {   // FB_R_CTRL
    logic [7:0]    Reserved;                          // [31:24]
    logic          vclk_div;                          // [23]
    logic          fb_strip_buf_en;                   // [22]
    logic [5:0]    fb_stripsize;                      // [21:16]
    logic [7:0]    fb_chroma_threshold;               // [15:8]
    logic          R;                                 // [7]
    logic [2:0]    fb_concat;                         // [6:4]
    logic [1:0]    fb_depth;                          // [3:2]
    logic          fb_line_double;                    // [1]
    logic          fb_enable;                         // [0]
  } p2_fb_r_ctrl_t;
  typedef struct packed {   // FB_R_SIZE
    logic [1:0]    fb_res;                            // [31:30]
    logic [9:0]    fb_modulus;                        // [29:20]
    logic [9:0]    fb_y_size;                         // [19:10]
    logic [9:0]    fb_x_size;                         // [9:0]
  } p2_fb_r_size_t;
  typedef struct packed {   // VO_BORDER_COL
    logic [6:0]    res;                               // [31:25]
    logic          Chroma;                            // [24]
    logic [7:0]    Red;                               // [23:16]
    logic [7:0]    Green;                             // [15:8]
    logic [7:0]    Blue;                              // [7:0]
  } p2_vo_border_col_t;
  typedef struct packed {   // SPG_STATUS
    logic [17:0]   res;                               // [31:14]
    logic          vsync;                             // [13]
    logic          hsync;                             // [12]
    logic          blank;                             // [11]
    logic          fieldnum;                          // [10]
    logic [9:0]    scanline;                          // [9:0]
  } p2_spg_status_t;
  typedef struct packed {   // SPG_HBLANK_INT
    logic [5:0]    res3;                              // [31:26]
    logic [9:0]    hblank_in_interrupt;               // [25:16]
    logic [1:0]    res2;                              // [15:14]
    logic [1:0]    hblank_int_mode;                   // [13:12]
    logic [1:0]    res1;                              // [11:10]
    logic [9:0]    line_comp_val;                     // [9:0]
  } p2_spg_hblank_int_t;
  typedef struct packed {   // SPG_VBLANK_INT
    logic [5:0]    res1;                              // [31:26]
    logic [9:0]    vblank_out_interrupt_line_number;  // [25:16]
    logic [5:0]    res;                               // [15:10]
    logic [9:0]    vblank_in_interrupt_line_number;   // [9:0]
  } p2_spg_vblank_int_t;
  typedef struct packed {   // SPG_CONTROL
    logic [21:0]   Reserved;                          // [31:10]
    logic          csync_on_h;                        // [9]
    logic          sync_direction;                    // [8]
    logic          PAL;                               // [7]
    logic          NTSC;                              // [6]
    logic          force_field2;                      // [5]
    logic          interlace;                         // [4]
    logic          spg_lock;                          // [3]
    logic          mcsync_pol;                        // [2]
    logic          mvsync_pol;                        // [1]
    logic          mhsync_pol;                        // [0]
  } p2_spg_control_t;
  typedef struct packed {   // SPG_HBLANK
    logic [5:0]    res1;                              // [31:26]
    logic [9:0]    hbend;                             // [25:16]
    logic [5:0]    res;                               // [15:10]
    logic [9:0]    hstart;                            // [9:0]
  } p2_spg_hblank_t;
  typedef struct packed {   // SPG_LOAD
    logic [5:0]    res1;                              // [31:26]
    logic [9:0]    vcount;                            // [25:16]
    logic [5:0]    res;                               // [15:10]
    logic [9:0]    hcount;                            // [9:0]
  } p2_spg_load_t;
  typedef struct packed {   // SPG_VBLANK
    logic [5:0]    res1;                              // [31:26]
    logic [9:0]    vbend;                             // [25:16]
    logic [5:0]    res;                               // [15:10]
    logic [9:0]    vstart;                            // [9:0]
  } p2_spg_vblank_t;
  typedef struct packed {   // SPG_WIDTH
    logic [9:0]    eqwidth;                           // [31:22]
    logic [9:0]    bpwidth;                           // [21:12]
    logic [3:0]    vswidth;                           // [11:8]
    logic          res;                               // [7]
    logic [6:0]    hswidth;                           // [6:0]
  } p2_spg_width_t;
  typedef struct packed {   // SCALER_CTL (19 bits used)
    logic [12:0]   pad_msb;                           // [31:19]
    logic          fieldselect;                       // [18]
    logic          interlace;                         // [17]
    logic          hscale;                            // [16]
    logic [15:0]   vscalefactor;                      // [15:0]
  } p2_scaler_ctl_t;
  typedef struct packed {   // FB_X_CLIP
    logic [4:0]    pad;                               // [31:27]
    logic [10:0]   max;                               // [26:16]
    logic [4:0]    pad1;                              // [15:11]
    logic [10:0]   min;                               // [10:0]
  } p2_fb_x_clip_t;
  typedef struct packed {   // FB_Y_CLIP
    logic [5:0]    pad;                               // [31:26]
    logic [9:0]    max;                               // [25:16]
    logic [5:0]    pad1;                              // [15:10]
    logic [9:0]    min;                               // [9:0]
  } p2_fb_y_clip_t;
  typedef struct packed {   // VO_CONTROL
    logic [9:0]    res_2;                             // [31:22]
    logic [5:0]    pclk_delay;                        // [21:16]
    logic [6:0]    res_1;                             // [15:9]
    logic          pixel_double;                      // [8]
    logic [3:0]    field_mode;                        // [7:4]
    logic          blank_video;                       // [3]
    logic          blank_pol;                         // [2]
    logic          vsync_pol;                         // [1]
    logic          hsync_pol;                         // [0]
  } p2_vo_control_t;
  typedef struct packed {   // VO_STARTX
    logic [21:0]   res_1;                             // [31:10]
    logic [9:0]    HStart;                            // [9:0]
  } p2_vo_startx_t;
  typedef struct packed {   // VO_STARTY
    logic [5:0]    res_2;                             // [31:26]
    logic [9:0]    VStart_field2;                     // [25:16]
    logic [5:0]    res_1;                             // [15:10]
    logic [9:0]    VStart_field1;                     // [9:0]
  } p2_vo_starty_t;
  typedef struct packed {   // ISP_BACKGND_T (29 bits used)
    logic [2:0]    pad_msb;                           // [31:29]
    logic          cache_bypass;                      // [28]
    logic          shadow;                            // [27]
    logic [2:0]    skip;                              // [26:24]
    logic [20:0]   param_offs_in_words;               // [23:3]
    logic [2:0]    tag_offset;                        // [2:0]
  } p2_isp_backgnd_t_t;
  typedef struct packed {   // ISP_FEED_CFG
    logic [7:0]    res2;                              // [31:24]
    logic [9:0]    tr_cache_size;                     // [23:14]
    logic [9:0]    pt_chunk_size;                     // [13:4]
    logic          discard_mode;                      // [3]
    logic [1:0]    res;                               // [2:1]
    logic          pre_sort;                          // [0]
  } p2_isp_feed_cfg_t;
  typedef struct packed {   // FB_W_CTRL
    logic [7:0]    pad1;                              // [31:24]
    logic [7:0]    fb_alpha_threshold;                // [23:16]
    logic [7:0]    fb_kval;                           // [15:8]
    logic [3:0]    pad0;                              // [7:4]
    logic          fb_dither;                         // [3]
    logic [2:0]    fb_packmode;                       // [2:0]
  } p2_fb_w_ctrl_t;
  typedef struct packed {   // FB_W_LINESTRIDE
    logic [22:0]   pad0;                              // [31:9]
    logic [8:0]    stride;                            // [8:0]
  } p2_fb_w_linestride_t;
  typedef struct packed {   // FPU_SHAD_SCALE (9 bits used)
    logic [22:0]   pad_msb;                           // [31:9]
    logic          intensity_shadow;                  // [8]
    logic [7:0]    scale_factor;                      // [7:0]
  } p2_fpu_shad_scale_t;
  typedef struct packed {   // FPU_PARAM_CFG
    logic [9:0]    res1;                              // [31:22]
    logic          region_header_type;                // [21]
    logic          res;                               // [20]
    logic [5:0]    tsp_param_burst_threshold;         // [19:14]
    logic [5:0]    isp_param_burst_threshold;         // [13:8]
    logic [3:0]    pointer_burst;                     // [7:4]
    logic [3:0]    pointer_first_burst;               // [3:0]
  } p2_fpu_param_cfg_t;
  typedef struct packed {   // HALF_OFFSET (3 bits used)
    logic [28:0]   pad_msb;                           // [31:3]
    logic          texure_pixel_half_offset;          // [2]
    logic          tsp_pixel_half_offset;             // [1]
    logic          fpu_pixel_half_offset;             // [0]
  } p2_half_offset_t;
  typedef struct packed {   // TA_GLOB_TILE_CLIP
    logic [11:0]   reserved2;                         // [31:20]
    logic [3:0]    tile_y_num;                        // [19:16]
    logic [9:0]    reserved;                          // [15:6]
    logic [5:0]    tile_x_num;                        // [5:0]
  } p2_ta_glob_tile_clip_t;
  typedef struct packed {   // TA_YUV_TEX_CTRL
    logic [6:0]    reserved4;                         // [31:25]
    logic          yuv_form;                          // [24]
    logic [6:0]    reserved3;                         // [23:17]
    logic          yuv_tex;                           // [16]
    logic [1:0]    reserved2;                         // [15:14]
    logic [5:0]    yuv_v_size;                        // [13:8]
    logic [1:0]    reserved1;                         // [7:6]
    logic [5:0]    yuv_u_size;                        // [5:0]
  } p2_ta_yuv_tex_ctrl_t;

  // ---- parameter words (refsw3/refcore/core_structs.h, refsw3/refcore/refsw_lists_regtypes.h) ----
  typedef struct packed {   // PCW (core_structs.h)
    logic [2:0]    ParaType;                          // [31:29]
    logic          EndOfStrip;                        // [28]
    logic          Res_1;                             // [27]
    logic [2:0]    ListType;                          // [26:24]
    logic          Group_En;                          // [23]
    logic [2:0]    Res_2;                             // [22:20]
    logic [1:0]    Strip_Len;                         // [19:18]
    logic [1:0]    User_Clip;                         // [17:16]
    logic [7:0]    Reserved;                          // [15:8]
    logic          Shadow;                            // [7]
    logic          Volume;                            // [6]
    logic [1:0]    Col_Type;                          // [5:4]
    logic          Texture;                           // [3]
    logic          Offset;                            // [2]
    logic          Gouraud;                           // [1]
    logic          UV_16bit;                          // [0]
  } p2_pcw_t;
  typedef struct packed {   // PCW.1 (core_structs.h)
    logic [3:0]    PTEOS;                             // [31:28]
    logic [18:0]   padin2;                            // [27:9]
    logic          S6X;                               // [8]
    logic [7:0]    padin;                             // [7:0]
  } p2_pcw_ta_t;
  typedef struct packed {   // ISP_TSP (core_structs.h)
    logic [2:0]    DepthMode;                         // [31:29]
    logic [1:0]    CullMode;                          // [28:27]
    logic          ZWriteDis;                         // [26]
    logic          Texture;                           // [25]
    logic          Offset;                            // [24]
    logic          Gouraud;                           // [23]
    logic          UV_16b;                            // [22]
    logic          CacheBypass;                       // [21]
    logic          DCalcCtrl;                         // [20]
    logic [19:0]   Reserved;                          // [19:0]
  } p2_isptsp_t;
  typedef struct packed {   // ISP_TSP.modvol (core_structs.h)
    logic [2:0]    VolumeMode;                        // [31:29]
    logic [1:0]    CullMode;                          // [28:27]
    logic [26:0]   res;                               // [26:0]
  } p2_isptsp_modvol_t;
  typedef struct packed {   // ISP_Modvol (core_structs.h)
    logic [2:0]    DepthMode;                         // [31:29]
    logic [1:0]    CullMode;                          // [28:27]
    logic          VolumeLast;                        // [26]
    logic [25:0]   id;                                // [25:0]
  } p2_isp_modvol_t;
  typedef struct packed {   // TSP (core_structs.h)
    logic [2:0]    SrcInstr;                          // [31:29]
    logic [2:0]    DstInstr;                          // [28:26]
    logic          SrcSelect;                         // [25]
    logic          DstSelect;                         // [24]
    logic [1:0]    FogCtrl;                           // [23:22]
    logic          ColorClamp;                        // [21]
    logic          UseAlpha;                          // [20]
    logic          IgnoreTexA;                        // [19]
    logic          FlipU;                             // [18]
    logic          FlipV;                             // [17]
    logic          ClampU;                            // [16]
    logic          ClampV;                            // [15]
    logic [1:0]    FilterMode;                        // [14:13]
    logic          SupSample;                         // [12]
    logic [3:0]    MipMapD;                           // [11:8]
    logic [1:0]    ShadInstr;                         // [7:6]
    logic [2:0]    TexU;                              // [5:3]
    logic [2:0]    TexV;                              // [2:0]
  } p2_tsp_t;
  typedef struct packed {   // TCW (core_structs.h)
    logic          MipMapped;                         // [31]
    logic          VQ_Comp;                           // [30]
    logic [2:0]    PixelFmt;                          // [29:27]
    logic          ScanOrder;                         // [26]
    logic          StrideSel;                         // [25]
    logic [3:0]    Reserved;                          // [24:21]
    logic [20:0]   TexAddr;                           // [20:0]
  } p2_tcw_t;
  typedef struct packed {   // TCW.1 (core_structs.h) (27 bits used)
    logic [4:0]    pad_msb;                           // [31:27]
    logic [5:0]    PalSelect;                         // [26:21]
    logic [20:0]   pading_0;                          // [20:0]
  } p2_tcw_pal_t;
  typedef struct packed {   // RegionArrayEntryControl (refsw_lists_regtypes.h)
    logic          last_region;                       // [31]
    logic          z_keep;                            // [30]
    logic          pre_sort;                          // [29]
    logic          no_writeout;                       // [28]
    logic [13:0]   res1;                              // [27:14]
    logic [5:0]    tiley;                             // [13:8]
    logic [5:0]    tilex;                             // [7:2]
    logic [1:0]    res0;                              // [1:0]
  } p2_region_ctl_t;
  typedef struct packed {   // ListPointer (refsw_lists_regtypes.h)
    logic          empty;                             // [31]
    logic [6:0]    pad1;                              // [30:24]
    logic [21:0]   ptr_in_words;                      // [23:2]
    logic [1:0]    pad0;                              // [1:0]
  } p2_listptr_t;
  typedef struct packed {   // ObjectListTstrip (refsw_lists_regtypes.h)
    logic          is_not_triangle_strip;             // [31]
    logic [5:0]    mask;                              // [30:25]
    logic          shadow;                            // [24]
    logic [2:0]    skip;                              // [23:21]
    logic [20:0]   param_offs_in_words;               // [20:0]
  } p2_objent_tstrip_t;
  typedef struct packed {   // ObjectListTarray (refsw_lists_regtypes.h)
    logic [2:0]    type_;                             // [31:29]
    logic [3:0]    prims;                             // [28:25]
    logic          shadow;                            // [24]
    logic [2:0]    skip;                              // [23:21]
    logic [20:0]   param_offs_in_words;               // [20:0]
  } p2_objent_tarray_t;
  typedef struct packed {   // ObjectListQarray (refsw_lists_regtypes.h)
    logic [2:0]    type_;                             // [31:29]
    logic [3:0]    prims;                             // [28:25]
    logic          shadow;                            // [24]
    logic [2:0]    skip;                              // [23:21]
    logic [20:0]   param_offs_in_words;               // [20:0]
  } p2_objent_qarray_t;
  typedef struct packed {   // ObjectListLink (refsw_lists_regtypes.h)
    logic [2:0]    type_;                             // [31:29]
    logic          end_of_list;                       // [28]
    logic [3:0]    pad4;                              // [27:24]
    logic [21:0]   next_block_ptr_in_words;           // [23:2]
    logic [1:0]    pad3;                              // [1:0]
  } p2_objent_link_t;
  typedef struct packed {   // ObjectListEntry (refsw_lists_regtypes.h)
    logic          is_not_triangle_strip;             // [31]
    logic [30:0]   pad0;                              // [30:0]
  } p2_objent_t;
  typedef struct packed {   // ObjectListEntry.1 (refsw_lists_regtypes.h)
    logic [2:0]    type_;                             // [31:29]
    logic [28:0]   pad1;                              // [28:0]
  } p2_objent_type_t;

  // ---- enums (pvr_regs.h, core_structs.h, refsw_lists.h) ----
  typedef enum logic [2:0] {
    P2_RM_OPAQUE = 3'd0,
    P2_RM_PUNCHTHROUGH_PASS0 = 3'd1,
    P2_RM_PUNCHTHROUGH_PASSN = 3'd2,
    P2_RM_PUNCHTHROUGH_MV = 3'd3,
    P2_RM_TRANSLUCENT_AUTOSORT = 3'd4,
    P2_RM_TRANSLUCENT_PRESORT = 3'd5,
    P2_RM_MODIFIER = 3'd6
  } p2_rm_t;   // RenderMode
  typedef enum logic [2:0] {
    P2_Pixel1555 = 3'd0,
    P2_Pixel565 = 3'd1,
    P2_Pixel4444 = 3'd2,
    P2_PixelYUV = 3'd3,
    P2_PixelBumpMap = 3'd4,
    P2_PixelPal4 = 3'd5,
    P2_PixelPal8 = 3'd6,
    P2_PixelReserved = 3'd7
  } p2_pixfmt_t;   // PixelFormat
  typedef enum logic [1:0] {
    P2_fbde_0555 = 2'd0,
    P2_fbde_565 = 2'd1,
    P2_fbde_888 = 2'd2,
    P2_fbde_C888 = 2'd3
  } p2_fb_depth_t;   // fb_depth_enum

endpackage
