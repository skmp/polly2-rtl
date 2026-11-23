// p2_tsp_pkg: the TSP's own formats (PLAN M9; ARCHITECTURE 3.7.1-3.7.3): the setup job, the fetched primitive, the
// set-up store's words. Hand-written, beside p2_pkg (whose formats are the whole core's); the microprograms are
// p2_tsp_prog_pkg (GENERATED).
package p2_tsp_pkg;
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
endpackage
