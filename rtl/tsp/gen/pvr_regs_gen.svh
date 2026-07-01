// ====================================================================
// AUTO-GENERATED from minicast pvr_regs.h by tools/gen_pvr_regs.py
// Do not edit by hand. Scalar PVR registers -> named struct fields;
// bitfield unions -> packed struct types (fields MSB-first to match
// the C LSB-first bit layout). Tables (FOG/PAL) are M10K in reg_file.
// ====================================================================

    localparam [12:0] OFF_ID = 13'h000;
    localparam [12:0] OFF_REVISION = 13'h004;
    localparam [12:0] OFF_SOFTRESET = 13'h008;
    localparam [12:0] OFF_STARTRENDER = 13'h014;
    localparam [12:0] OFF_TEST_SELECT = 13'h018;
    localparam [12:0] OFF_PARAM_BASE = 13'h020;
    localparam [12:0] OFF_REGION_BASE = 13'h02C;
    localparam [12:0] OFF_SPAN_SORT_CFG = 13'h030;
    localparam [12:0] OFF_VO_BORDER_COL = 13'h040;
    localparam [12:0] OFF_FB_R_CTRL = 13'h044;
    localparam [12:0] OFF_FB_W_CTRL = 13'h048;
    localparam [12:0] OFF_FB_W_LINESTRIDE = 13'h04C;
    localparam [12:0] OFF_FB_R_SOF1 = 13'h050;
    localparam [12:0] OFF_FB_R_SOF2 = 13'h054;
    localparam [12:0] OFF_FB_R_SIZE = 13'h05C;
    localparam [12:0] OFF_FB_W_SOF1 = 13'h060;
    localparam [12:0] OFF_FB_W_SOF2 = 13'h064;
    localparam [12:0] OFF_FB_X_CLIP = 13'h068;
    localparam [12:0] OFF_FB_Y_CLIP = 13'h06C;
    localparam [12:0] OFF_FPU_SHAD_SCALE = 13'h074;
    localparam [12:0] OFF_FPU_CULL_VAL = 13'h078;
    localparam [12:0] OFF_FPU_PARAM_CFG = 13'h07C;
    localparam [12:0] OFF_HALF_OFFSET = 13'h080;
    localparam [12:0] OFF_FPU_PERP_VAL = 13'h084;
    localparam [12:0] OFF_ISP_BACKGND_D = 13'h088;
    localparam [12:0] OFF_ISP_BACKGND_T = 13'h08C;
    localparam [12:0] OFF_ISP_FEED_CFG = 13'h098;
    localparam [12:0] OFF_SDRAM_REFRESH = 13'h0A0;
    localparam [12:0] OFF_SDRAM_ARB_CFG = 13'h0A4;
    localparam [12:0] OFF_SDRAM_CFG = 13'h0A8;
    localparam [12:0] OFF_FOG_COL_RAM = 13'h0B0;
    localparam [12:0] OFF_FOG_COL_VERT = 13'h0B4;
    localparam [12:0] OFF_FOG_DENSITY = 13'h0B8;
    localparam [12:0] OFF_FOG_CLAMP_MAX = 13'h0BC;
    localparam [12:0] OFF_FOG_CLAMP_MIN = 13'h0C0;
    localparam [12:0] OFF_SPG_TRIGGER_POS = 13'h0C4;
    localparam [12:0] OFF_SPG_HBLANK_INT = 13'h0C8;
    localparam [12:0] OFF_SPG_VBLANK_INT = 13'h0CC;
    localparam [12:0] OFF_SPG_CONTROL = 13'h0D0;
    localparam [12:0] OFF_SPG_HBLANK = 13'h0D4;
    localparam [12:0] OFF_SPG_LOAD = 13'h0D8;
    localparam [12:0] OFF_SPG_VBLANK = 13'h0DC;
    localparam [12:0] OFF_SPG_WIDTH = 13'h0E0;
    localparam [12:0] OFF_TEXT_CONTROL = 13'h0E4;
    localparam [12:0] OFF_VO_CONTROL = 13'h0E8;
    localparam [12:0] OFF_VO_STARTX = 13'h0EC;
    localparam [12:0] OFF_VO_STARTY = 13'h0F0;
    localparam [12:0] OFF_SCALER_CTL = 13'h0F4;
    localparam [12:0] OFF_PAL_RAM_CTRL = 13'h108;
    localparam [12:0] OFF_SPG_STATUS = 13'h10C;
    localparam [12:0] OFF_FB_BURSTCTRL = 13'h110;
    localparam [12:0] OFF_FB_C_SOF = 13'h114;
    localparam [12:0] OFF_Y_COEFF = 13'h118;
    localparam [12:0] OFF_PT_ALPHA_REF = 13'h11C;
    localparam [12:0] OFF_TA_OL_BASE = 13'h124;
    localparam [12:0] OFF_TA_ISP_BASE = 13'h128;
    localparam [12:0] OFF_TA_OL_LIMIT = 13'h12C;
    localparam [12:0] OFF_TA_ISP_LIMIT = 13'h130;
    localparam [12:0] OFF_TA_NEXT_OPB = 13'h134;
    localparam [12:0] OFF_TA_ISP_CURRENT = 13'h138;
    localparam [12:0] OFF_TA_GLOB_TILE_CLIP = 13'h13C;
    localparam [12:0] OFF_TA_ALLOC_CTRL = 13'h140;
    localparam [12:0] OFF_TA_LIST_INIT = 13'h144;
    localparam [12:0] OFF_TA_YUV_TEX_BASE = 13'h148;
    localparam [12:0] OFF_TA_YUV_TEX_CTRL = 13'h14C;
    localparam [12:0] OFF_TA_YUV_TEX_CNT = 13'h150;
    localparam [12:0] OFF_TA_LIST_CONT = 13'h160;
    localparam [12:0] OFF_TA_NEXT_OPB_INIT = 13'h164;

    typedef struct packed {  // VO_BORDER_COL (32 bits used)
        logic [6:0] res;
        logic        Chroma;
        logic [7:0] Red;
        logic [7:0] Green;
        logic [7:0] Blue;
    } vo_border_col_reg_t;   // == 32 bits

    typedef struct packed {  // FB_R_CTRL (32 bits used)
        logic [7:0] Reserved;
        logic        vclk_div;
        logic        fb_strip_buf_en;
        logic [5:0] fb_stripsize;
        logic [7:0] fb_chroma_threshold;
        logic        R;
        logic [2:0] fb_concat;
        logic [1:0] fb_depth;
        logic        fb_line_double;
        logic        fb_enable;
    } fb_r_ctrl_reg_t;   // == 32 bits

    typedef struct packed {  // FB_W_CTRL (32 bits used)
        logic [7:0] pad1;
        logic [7:0] fb_alpha_threshold;
        logic [7:0] fb_kval;
        logic [3:0] pad0;
        logic        fb_dither;
        logic [2:0] fb_packmode;
    } fb_w_ctrl_reg_t;   // == 32 bits

    typedef struct packed {  // FB_W_LINESTRIDE (32 bits used)
        logic [22:0] pad0;
        logic [8:0] stride;
    } fb_w_linestride_reg_t;   // == 32 bits

    typedef struct packed {  // FB_R_SIZE (32 bits used)
        logic [1:0] fb_res;
        logic [9:0] fb_modulus;
        logic [9:0] fb_y_size;
        logic [9:0] fb_x_size;
    } fb_r_size_reg_t;   // == 32 bits

    typedef struct packed {  // FB_X_CLIP (32 bits used)
        logic [4:0] pad;
        logic [10:0] max;
        logic [4:0] pad1;
        logic [10:0] min;
    } fb_x_clip_reg_t;   // == 32 bits

    typedef struct packed {  // FB_Y_CLIP (32 bits used)
        logic [5:0] pad;
        logic [9:0] max;
        logic [5:0] pad1;
        logic [9:0] min;
    } fb_y_clip_reg_t;   // == 32 bits

    typedef struct packed {  // FPU_SHAD_SCALE (9 bits used)
        logic [22:0] _pad_msb;
        logic        intensity_shadow;
        logic [7:0] scale_factor;
    } fpu_shad_scale_reg_t;   // == 32 bits

    typedef struct packed {  // FPU_PARAM_CFG (32 bits used)
        logic [9:0] res1;
        logic        region_header_type;
        logic        res;
        logic [5:0] tsp_param_burst_threshold;
        logic [5:0] isp_param_burst_threshold;
        logic [3:0] pointer_burst;
        logic [3:0] pointer_first_burst;
    } fpu_param_cfg_reg_t;   // == 32 bits

    typedef struct packed {  // HALF_OFFSET (3 bits used)
        logic [28:0] _pad_msb;
        logic        texure_pixel_half_offset;
        logic        tsp_pixel_half_offset;
        logic        fpu_pixel_half_offset;
    } half_offset_reg_t;   // == 32 bits

    typedef struct packed {  // ISP_BACKGND_T (32 bits used)
        logic        _invalid;
        logic [1:0] _pad;
        logic        cache_bypass;
        logic        shadow;
        logic [2:0] skip;
        logic [20:0] param_offs_in_words;
        logic [2:0] tag_offset;
    } isp_backgnd_t_reg_t;   // == 32 bits

    typedef struct packed {  // ISP_FEED_CFG (32 bits used)
        logic [7:0] res2;
        logic [9:0] tr_cache_size;
        logic [9:0] pt_chunk_size;
        logic        discard_mode;
        logic [1:0] res;
        logic        pre_sort;
    } isp_feed_cfg_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_HBLANK_INT (32 bits used)
        logic [5:0] res3;
        logic [9:0] hblank_in_interrupt;
        logic [1:0] res2;
        logic [1:0] hblank_int_mode;
        logic [1:0] res1;
        logic [9:0] line_comp_val;
    } spg_hblank_int_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_VBLANK_INT (32 bits used)
        logic [5:0] res1;
        logic [9:0] vblank_out_interrupt_line_number;
        logic [5:0] res;
        logic [9:0] vblank_in_interrupt_line_number;
    } spg_vblank_int_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_CONTROL (32 bits used)
        logic [21:0] Reserved;
        logic        csync_on_h;
        logic        sync_direction;
        logic        PAL;
        logic        NTSC;
        logic        force_field2;
        logic        interlace;
        logic        spg_lock;
        logic        mcsync_pol;
        logic        mvsync_pol;
        logic        mhsync_pol;
    } spg_control_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_HBLANK (32 bits used)
        logic [5:0] res1;
        logic [9:0] hbend;
        logic [5:0] res;
        logic [9:0] hstart;
    } spg_hblank_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_LOAD (32 bits used)
        logic [5:0] res1;
        logic [9:0] vcount;
        logic [5:0] res;
        logic [9:0] hcount;
    } spg_load_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_VBLANK (32 bits used)
        logic [5:0] res1;
        logic [9:0] vbend;
        logic [5:0] res;
        logic [9:0] vstart;
    } spg_vblank_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_WIDTH (32 bits used)
        logic [9:0] eqwidth;
        logic [9:0] bpwidth;
        logic [3:0] vswidth;
        logic        res;
        logic [6:0] hswidth;
    } spg_width_reg_t;   // == 32 bits

    typedef struct packed {  // VO_CONTROL (32 bits used)
        logic [9:0] res_2;
        logic [5:0] pclk_delay;
        logic [6:0] res_1;
        logic        pixel_double;
        logic [3:0] field_mode;
        logic        blank_video;
        logic        blank_pol;
        logic        vsync_pol;
        logic        hsync_pol;
    } vo_control_reg_t;   // == 32 bits

    typedef struct packed {  // VO_STARTX (32 bits used)
        logic [21:0] res_1;
        logic [9:0] HStart;
    } vo_startx_reg_t;   // == 32 bits

    typedef struct packed {  // VO_STARTY (32 bits used)
        logic [5:0] res_2;
        logic [9:0] VStart_field2;
        logic [5:0] res_1;
        logic [9:0] VStart_field1;
    } vo_starty_reg_t;   // == 32 bits

    typedef struct packed {  // SCALER_CTL (19 bits used)
        logic [12:0] _pad_msb;
        logic        fieldselect;
        logic        interlace;
        logic        hscale;
        logic [15:0] vscalefactor;
    } scaler_ctl_reg_t;   // == 32 bits

    typedef struct packed {  // SPG_STATUS (32 bits used)
        logic [17:0] res;
        logic        vsync;
        logic        hsync;
        logic        blank;
        logic        fieldnum;
        logic [9:0] scanline;
    } spg_status_reg_t;   // == 32 bits

    typedef struct packed {  // TA_GLOB_TILE_CLIP (32 bits used)
        logic [11:0] reserved2;
        logic [3:0] tile_y_num;
        logic [9:0] reserved;
        logic [5:0] tile_x_num;
    } ta_glob_tile_clip_reg_t;   // == 32 bits

    typedef struct packed {  // TA_YUV_TEX_CTRL (32 bits used)
        logic [6:0] reserved4;
        logic        yuv_form;
        logic [6:0] reserved3;
        logic        yuv_tex;
        logic [1:0] reserved2;
        logic [5:0] yuv_v_size;
        logic [1:0] reserved1;
        logic [5:0] yuv_u_size;
    } ta_yuv_tex_ctrl_reg_t;   // == 32 bits

    typedef struct packed {
        logic [31:0]                 id;
        logic [31:0]                 revision;
        logic [31:0]                 softreset;
        logic [31:0]                 startrender;
        logic [31:0]                 test_select;
        logic [31:0]                 param_base;
        logic [31:0]                 region_base;
        logic [31:0]                 span_sort_cfg;
        vo_border_col_reg_t          vo_border_col;
        fb_r_ctrl_reg_t              fb_r_ctrl;
        fb_w_ctrl_reg_t              fb_w_ctrl;
        fb_w_linestride_reg_t        fb_w_linestride;
        logic [31:0]                 fb_r_sof1;
        logic [31:0]                 fb_r_sof2;
        fb_r_size_reg_t              fb_r_size;
        logic [31:0]                 fb_w_sof1;
        logic [31:0]                 fb_w_sof2;
        fb_x_clip_reg_t              fb_x_clip;
        fb_y_clip_reg_t              fb_y_clip;
        fpu_shad_scale_reg_t         fpu_shad_scale;
        logic [31:0]                 fpu_cull_val;
        fpu_param_cfg_reg_t          fpu_param_cfg;
        half_offset_reg_t            half_offset;
        logic [31:0]                 fpu_perp_val;
        logic [31:0]                 isp_backgnd_d;
        isp_backgnd_t_reg_t          isp_backgnd_t;
        isp_feed_cfg_reg_t           isp_feed_cfg;
        logic [31:0]                 sdram_refresh;
        logic [31:0]                 sdram_arb_cfg;
        logic [31:0]                 sdram_cfg;
        logic [31:0]                 fog_col_ram;
        logic [31:0]                 fog_col_vert;
        logic [31:0]                 fog_density;
        logic [31:0]                 fog_clamp_max;
        logic [31:0]                 fog_clamp_min;
        logic [31:0]                 spg_trigger_pos;
        spg_hblank_int_reg_t         spg_hblank_int;
        spg_vblank_int_reg_t         spg_vblank_int;
        spg_control_reg_t            spg_control;
        spg_hblank_reg_t             spg_hblank;
        spg_load_reg_t               spg_load;
        spg_vblank_reg_t             spg_vblank;
        spg_width_reg_t              spg_width;
        logic [31:0]                 text_control;
        vo_control_reg_t             vo_control;
        vo_startx_reg_t              vo_startx;
        vo_starty_reg_t              vo_starty;
        scaler_ctl_reg_t             scaler_ctl;
        logic [31:0]                 pal_ram_ctrl;
        spg_status_reg_t             spg_status;
        logic [31:0]                 fb_burstctrl;
        logic [31:0]                 fb_c_sof;
        logic [31:0]                 y_coeff;
        logic [31:0]                 pt_alpha_ref;
        logic [31:0]                 ta_ol_base;
        logic [31:0]                 ta_isp_base;
        logic [31:0]                 ta_ol_limit;
        logic [31:0]                 ta_isp_limit;
        logic [31:0]                 ta_next_opb;
        logic [31:0]                 ta_isp_current;
        ta_glob_tile_clip_reg_t      ta_glob_tile_clip;
        logic [31:0]                 ta_alloc_ctrl;
        logic [31:0]                 ta_list_init;
        logic [31:0]                 ta_yuv_tex_base;
        ta_yuv_tex_ctrl_reg_t        ta_yuv_tex_ctrl;
        logic [31:0]                 ta_yuv_tex_cnt;
        logic [31:0]                 ta_list_cont;
        logic [31:0]                 ta_next_opb_init;
    } pvr_regs_t;
    localparam int PVR_REGS_N = 68;

// Write-decode: case over byte offset OFF, writing DATA (32b) into
// the packed-vector slice of the matching field of R (pvr_regs_t).
`define PVR_REG_WRITE_CASE(R, OFF, DATA) \
    OFF_ID: R[2144 +: 32] <= DATA; \
    OFF_REVISION: R[2112 +: 32] <= DATA; \
    OFF_SOFTRESET: R[2080 +: 32] <= DATA; \
    OFF_STARTRENDER: R[2048 +: 32] <= DATA; \
    OFF_TEST_SELECT: R[2016 +: 32] <= DATA; \
    OFF_PARAM_BASE: R[1984 +: 32] <= DATA; \
    OFF_REGION_BASE: R[1952 +: 32] <= DATA; \
    OFF_SPAN_SORT_CFG: R[1920 +: 32] <= DATA; \
    OFF_VO_BORDER_COL: R[1888 +: 32] <= DATA; \
    OFF_FB_R_CTRL: R[1856 +: 32] <= DATA; \
    OFF_FB_W_CTRL: R[1824 +: 32] <= DATA; \
    OFF_FB_W_LINESTRIDE: R[1792 +: 32] <= DATA; \
    OFF_FB_R_SOF1: R[1760 +: 32] <= DATA; \
    OFF_FB_R_SOF2: R[1728 +: 32] <= DATA; \
    OFF_FB_R_SIZE: R[1696 +: 32] <= DATA; \
    OFF_FB_W_SOF1: R[1664 +: 32] <= DATA; \
    OFF_FB_W_SOF2: R[1632 +: 32] <= DATA; \
    OFF_FB_X_CLIP: R[1600 +: 32] <= DATA; \
    OFF_FB_Y_CLIP: R[1568 +: 32] <= DATA; \
    OFF_FPU_SHAD_SCALE: R[1536 +: 32] <= DATA; \
    OFF_FPU_CULL_VAL: R[1504 +: 32] <= DATA; \
    OFF_FPU_PARAM_CFG: R[1472 +: 32] <= DATA; \
    OFF_HALF_OFFSET: R[1440 +: 32] <= DATA; \
    OFF_FPU_PERP_VAL: R[1408 +: 32] <= DATA; \
    OFF_ISP_BACKGND_D: R[1376 +: 32] <= DATA; \
    OFF_ISP_BACKGND_T: R[1344 +: 32] <= DATA; \
    OFF_ISP_FEED_CFG: R[1312 +: 32] <= DATA; \
    OFF_SDRAM_REFRESH: R[1280 +: 32] <= DATA; \
    OFF_SDRAM_ARB_CFG: R[1248 +: 32] <= DATA; \
    OFF_SDRAM_CFG: R[1216 +: 32] <= DATA; \
    OFF_FOG_COL_RAM: R[1184 +: 32] <= DATA; \
    OFF_FOG_COL_VERT: R[1152 +: 32] <= DATA; \
    OFF_FOG_DENSITY: R[1120 +: 32] <= DATA; \
    OFF_FOG_CLAMP_MAX: R[1088 +: 32] <= DATA; \
    OFF_FOG_CLAMP_MIN: R[1056 +: 32] <= DATA; \
    OFF_SPG_TRIGGER_POS: R[1024 +: 32] <= DATA; \
    OFF_SPG_HBLANK_INT: R[992 +: 32] <= DATA; \
    OFF_SPG_VBLANK_INT: R[960 +: 32] <= DATA; \
    OFF_SPG_CONTROL: R[928 +: 32] <= DATA; \
    OFF_SPG_HBLANK: R[896 +: 32] <= DATA; \
    OFF_SPG_LOAD: R[864 +: 32] <= DATA; \
    OFF_SPG_VBLANK: R[832 +: 32] <= DATA; \
    OFF_SPG_WIDTH: R[800 +: 32] <= DATA; \
    OFF_TEXT_CONTROL: R[768 +: 32] <= DATA; \
    OFF_VO_CONTROL: R[736 +: 32] <= DATA; \
    OFF_VO_STARTX: R[704 +: 32] <= DATA; \
    OFF_VO_STARTY: R[672 +: 32] <= DATA; \
    OFF_SCALER_CTL: R[640 +: 32] <= DATA; \
    OFF_PAL_RAM_CTRL: R[608 +: 32] <= DATA; \
    OFF_SPG_STATUS: R[576 +: 32] <= DATA; \
    OFF_FB_BURSTCTRL: R[544 +: 32] <= DATA; \
    OFF_FB_C_SOF: R[512 +: 32] <= DATA; \
    OFF_Y_COEFF: R[480 +: 32] <= DATA; \
    OFF_PT_ALPHA_REF: R[448 +: 32] <= DATA; \
    OFF_TA_OL_BASE: R[416 +: 32] <= DATA; \
    OFF_TA_ISP_BASE: R[384 +: 32] <= DATA; \
    OFF_TA_OL_LIMIT: R[352 +: 32] <= DATA; \
    OFF_TA_ISP_LIMIT: R[320 +: 32] <= DATA; \
    OFF_TA_NEXT_OPB: R[288 +: 32] <= DATA; \
    OFF_TA_ISP_CURRENT: R[256 +: 32] <= DATA; \
    OFF_TA_GLOB_TILE_CLIP: R[224 +: 32] <= DATA; \
    OFF_TA_ALLOC_CTRL: R[192 +: 32] <= DATA; \
    OFF_TA_LIST_INIT: R[160 +: 32] <= DATA; \
    OFF_TA_YUV_TEX_BASE: R[128 +: 32] <= DATA; \
    OFF_TA_YUV_TEX_CTRL: R[96 +: 32] <= DATA; \
    OFF_TA_YUV_TEX_CNT: R[64 +: 32] <= DATA; \
    OFF_TA_LIST_CONT: R[32 +: 32] <= DATA; \
    OFF_TA_NEXT_OPB_INIT: R[0 +: 32] <= DATA;

