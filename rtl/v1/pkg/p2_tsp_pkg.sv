// p2_tsp_pkg: the TSP's own formats (PLAN M9; ARCHITECTURE 3.7.1-3.7.3): the setup job, the fetched primitive, the
// set-up store's words. Hand-written, beside p2_pkg (whose formats are the whole core's); the microprograms are
// p2_tsp_prog_pkg (GENERATED).
package p2_tsp_pkg;
  import p2_regs_pkg::*;
  import p2_pkg::*;

  // the set-up store (ARCHITECTURE 3.7.1, 6: STORE_N 16 [G T6]; SRQ_N 32 [G T6])
  localparam int P2_TSP_STORE_N   = 16;
  localparam int P2_TSP_SIDX_BITS = 4;
  localparam int P2_TSP_SRQ_N     = 32;

  // a setup job (p2_tsp_store's look-ahead to p2_tsp_pfetch): the key and the entry it goes to
  typedef struct packed {
    p2_tag_t                     tag;
    logic                        vsel;     // InVolume: volume 1's words (two volumes) or volume 0's with scaled colours
    logic [P2_TSP_SIDX_BITS-1:0] sidx;
  } p2_tsp_job_t;

  // a fetched primitive (p2_tsp_pfetch to p2_tsp_setup): the words the job's volume uses, the corners after the odd
  // strip triangle's swap (refsw_tile.cpp GetFpuEntry L530-534, decode_pvr_vertex L417-490)
  typedef struct packed {
    p2_tsp_job_t       job;
    logic [31:0]       isp;        // ISP/TSP word
    logic [31:0]       tsp;        // TSP[tv], tv = vsel && !intensity (the two-volume word only with two volumes)
    logic [31:0]       tcw;        // TCW[tv]
    logic [2:0][31:0]  x;
    logic [2:0][31:0]  y;
    logic [2:0][31:0]  z;
    logic [2:0][31:0]  u;          // u, v of volume tv as IEEE single bits (UV_16b expanded: the upper halves)
    logic [2:0][31:0]  v;
    logic [2:0][31:0]  col;        // base colour (ARGB8888) of the volume the colours come from (volume 1 with two
    logic [2:0][31:0]  spc;        // volumes, else 0); offset colour
  } p2_tsp_prim_t;

  // the store's header word of an entry (written when its job starts): what the pixel pipe decodes (ARCHITECTURE
  // 3.7.7 "Dispatch") and the per-channel fallbacks (the third corner's colour and offset colour as sent, scaled for
  // intensity: the bump map's light and offsKept's value, refsw_tile.h IPs3 fallback)
  typedef struct packed {
    logic [31:0] isp;
    logic [31:0] tsp;
    logic [31:0] tcw;
    logic [31:0] col_fb;     // B, G, R, A bytes as ARGB8888
    logic [31:0] ofs_fb;
    logic        vsel;
    logic        intensity;  // the entry's colours are the intensity-scaled ones
    logic [3:0]  cls;        // the setup class (p2_tsp_prog_pkg P2_TSP_CLS_*): which planes and K are set up
  } p2_tsp_hdr_t;

  // one plane of an entry: A, B, C cut to 16 bits (PlaneHW coefBits), the tuples (num 1.3)
  typedef struct packed {
    p2_fp16_t a;
    p2_fp16_t b;
    p2_fp16_t c;
  } p2_tsp_plane_t;

  // the entry's mip K (tsp 8.1): K8, and dz (a determinant of zero: the last level whatever w is, refsw3 dzForce)
  typedef struct packed {
    p2_fp8_t k8;
    logic    dz;
  } p2_tsp_k_t;

  // ---------------------------------------------------------------------------------------------------------------
  // M10: run start, the pixel queue, the pixel pipe to P3 (PLAN M10; ARCHITECTURE 3.7.5-3.7.7; tsp 5-8)
  // ---------------------------------------------------------------------------------------------------------------
  localparam int P2_TSP_NPL      = 11;   // planes of an entry (p2_tsp_prog_pkg P2_TSP_NPLANE; the order P2_TSP_PL_*)
  // the evaluator's integer k in units of 2^unit (tsp 5.3: |k| < 11 x 2^22 < 2^26, a 27-bit two's complement
  // accumulator; agents/spec-tsp/kbound.cpp: 200,000 random planes reach 2^23.8)
  localparam int P2_TSP_KBITS    = 27;
  // F(A'), F(A'/2): |.| <= 2^18 (top(A') + ex - 1 <= e = unit + 22 and ex >= 5, tsp 5.2); hyd = F(C' + B'/2) - F(C'):
  // |B'/2| < 2^(e - ey) <= 2^(unit + 17), so |hyd| <= 2^17 + 1 (num H7b)
  localparam int P2_TSP_STEPBITS = 20;
  localparam int P2_TSP_HYDBITS  = 21;
  // a sample point in half pixels: x0h = 2 (tileLeft + x) + half <= 2 (2016 + 31) + 1 = 4095 (tile x, y 6 bits)
  localparam int P2_TSP_XHBITS   = 13;
  // the pixel queue (ARCHITECTURE 3.7.6, 6: PXQ_PIX 256, PXQ_RUNS 48 [I, MT2 fit])
  localparam int P2_PXQ_RUNS     = 48;
  localparam int P2_PXQ_PIX      = 256;

  // run start's product on the shared ALU (ARCHITECTURE 3.7.4: its multipliers serve run start's exact 16 x 13
  // products): seen(A) x x0h, the halves' exponent -1 folded in by run start (PlaneT::Value ax, by)
  typedef struct packed {
    logic                             neg;
    logic signed [P2_FP_EXP_BITS-1:0] exp;
    logic [28:0]                      mant;     // 16 x 13 bits, exact
  } p2_tsp_rsp_t;

  // one plane's evaluator words for one run (run start to the pixel pipe's P1; tsp 5.2-5.4): the run's first value
  // base = F(C') + F(A' x0h / 2) + F(B' yh / 2), the step F(A'), the SupSample half step F(A' / 2) and half line
  // hyd = F(cut62(C' + B'/2)) - F(C'), on the grid 2^unit
  typedef struct packed {
    logic signed [P2_TSP_KBITS-1:0]    base;
    logic signed [P2_TSP_STEPBITS-1:0] step;
    logic signed [P2_TSP_STEPBITS-1:0] step2;
    logic signed [P2_TSP_HYDBITS-1:0]  hyd;
    logic signed [P2_FP_EXP_BITS-1:0]  unit;
  } p2_tsp_pev_t;

  // one volume of a run: the entry's header and K (read once at run start, ARCHITECTURE 3.7.7 "Dispatch") and its
  // planes' evaluator words
  typedef struct packed {
    p2_tsp_hdr_t                    hdr;
    p2_tsp_k_t                      k;
    p2_tsp_pev_t [P2_TSP_NPL-1:0]   pl;
  } p2_tsp_rvol_t;

  // a run descriptor (p2_tsp_rstart to p2_pxq to p2_pp_issue; ARCHITECTURE 3.7.5 "Out to p2_pxq"): the run, the volumes
  // its pixels use with their store entries (the pins, released after the run's last pixel), the tile, the volumes'
  // words. A null item carries its flags only
  typedef struct packed {
    p2_rs_t                         item;
    logic [1:0]                     need;
    logic [1:0][P2_TSP_SIDX_BITS-1:0] sidx;
    logic [5:0]                     tilex;
    logic [5:0]                     tiley;
    p2_tsp_rvol_t [1:0]             vol;
  } p2_tsp_rdesc_t;

  // a point's control through the pixel pipe (P0 to P3; ARCHITECTURE 3.7.7 P0): the pixel, the volume, the flags
  typedef struct packed {
    logic                       null_;    // a null item: flags only (eop / eoe), no pixel
    logic                       eop;      // the pass's last item: on its last point
    logic                       eoe;
    logic                       last;     // the run's last point: the pins go (rel)
    logic [1:0]                 need;
    logic [1:0][P2_TSP_SIDX_BITS-1:0] sidx;
    p2_tag_t                    tag;
    p2_rm_t                     rm;
    logic [5:0]                 tilex;
    logic [5:0]                 tiley;
    logic [P2_TILE_LOG2-1:0]    y;
    logic [P2_TILE_LOG2-1:0]    x;        // the pixel's column: run.x + n
    logic [P2_TILE_LOG2-1:0]    n;        // whole pixels from the run's first
    logic                       vsel;     // InVolume
    logic                       ro;       // a run-only pixel (PT passes, `rendered`)
    logic                       atest;    // alpha tested
    logic                       super_;   // a SupSample point (TSP bit 12 of the volume)
    logic                       hx;
    logic                       hy;
    logic                       pxlast;   // the pixel's last point (its credit returns)
    p2_tsp_hdr_t                hdr;      // the volume's header words
    p2_tsp_k_t                  k;
  } p2_pp_ctl_t;
endpackage
