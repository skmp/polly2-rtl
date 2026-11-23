// p2_tsp_pfetch: the TSP's parameter fetch (PLAN M9; ARCHITECTURE 3.7.2; tsp 2.2 at refsw3 4f3efe15: refsw_tile.cpp
// GetFpuEntry L523-534, decode_pvr_vertices L493-515, decode_pvr_vertex L417-490). It takes p2_tsp_store's setup jobs
// one at a time, reads what the job's volume needs of the tag's parameter block through VRAM client C3 of p2_mem (the
// 32-bit view, one word a request) and hands p2_tsp_setup the fetched primitive (p2_tsp_prim_t).
//
// Where the words are:
//   block    PARAM_BASE + param_offs_in_words * 4 with the FULL PARAM_BASE (the TSP's, unlike the ISP's & 0xF00000: GAP
//            isp 3.3, tsp 22 #1), in the 8 MB of the 32-bit view (p2_mem drops address bits 23 and up)
//   header   the ISP/TSP word, TSP[0], TCW[0], and with two volumes (shadow && !FPU_SHAD_SCALE[8]) TSP[1], TCW[1]
//   vertex   3 + skip (1 + two volumes) words a vertex; tag_offset vertices skipped, then three read; the fields from the
//            ISP word's bits, not from skip: x, y, z; [Texture: u, v, or with UV_16b one word: u = w & 0xFFFF0000, v =
//            w << 16]; the base colour; [Offset: the offset colour]; with two volumes the same again for volume 1
//   the job  vsel with two volumes reads volume 1's fields (u1, v1, col1, spc1) and TSP[1] / TCW[1]; otherwise volume 0's
//            (the intensity entry too: its colours are volume 0's, scaled by p2_tsp_setup)
//   swap     an odd tag_offset swaps vertices 0 and 1 (the rasterizer's order: the setup's arithmetic depends on it)
// Structure [G]: one job at a time; the header's words, then (once the ISP word is in: the fields depend on it) the
// vertices' words, one request a clock, at most PF_OUT outstanding, the responses in request order; a fetched
// primitive goes into a FIFO of PF_AHEAD to p2_tsp_setup, so the next job's fetch runs beside the setup. [M sort-off: a
// first setup costs ~19 clk more than a later one, ARCHITECTURE 3.7.2: this fetch, not hidden behind a setup.]
module p2_tsp_pfetch
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  // setup jobs (p2_tsp_store), valid/ready
  input  logic          jb_v,
  output logic          jb_rdy,
  input  p2_tsp_job_t   jb,
  // the render's registers
  input  logic [31:0]   param_base,       // PARAM_BASE
  input  logic          shad_intensity,   // FPU_SHAD_SCALE[8]
  // the fetched primitive to p2_tsp_setup, valid/ready
  output logic          pr_v,
  input  logic          pr_rdy,
  output p2_tsp_prim_t  pr,
  output logic          idle,
  // VRAM client C3 (p2_mem), 32-bit view, reads
  output logic          m_v,
  input  logic          m_rdy,
  output logic [23:0]   m_addr,
  input  logic          m_rv,
  output logic          m_rrdy,
  input  logic [31:0]   m_rdata
);
  localparam int PF_OUT   = 8;    // word reads outstanding (p2_mem RSP_N) [G]
  localparam int PF_AHEAD = 2;    // fetched primitives ahead of setup [G]
  localparam int OB = $clog2(PF_OUT + 1);

  // the fields of a vertex, in their order in the block
  localparam logic [2:0] F_X = 3'd0, F_Y = 3'd1, F_Z = 3'd2, F_U = 3'd3, F_V = 3'd4, F_UV = 3'd5, F_COL = 3'd6, F_SPC = 3'd7;

  // ---------------------------------------------------------------------------------------------- the job
  typedef enum logic [2:0] { S_IDLE, S_HDR, S_WAIT, S_VTX, S_DONE } st_t;
  st_t          st;
  p2_tsp_job_t  j;
  logic         j_v1;             // the job reads volume 1's fields
  logic [2:0]   j_nh;             // header words: 3 or 5
  logic [4:0]   j_stride;         // 3 + skip (1 + two): at most 17 words
  logic [23:0]  j_base;           // the block's byte address
  logic [2:0]   j_isp;            // the ISP/TSP word's Texture, Offset, UV_16b
  logic         isp_in;           // the ISP word has come back
  logic [2:0]   s_h;              // the next header word
  logic [1:0]   s_k;              // the next vertex
  logic [2:0]   s_f;              // the next field
  logic [5:0]   n_exp, n_got;     // words asked for, words back

  // the fields present (from the ISP word)
  logic tex, ofs, uv16;
  assign tex  = j_isp[2];
  assign ofs  = j_isp[1];
  assign uv16 = j_isp[0];
  function automatic logic present(input logic [2:0] f, input logic t, input logic o, input logic u16);
    case (f)
      F_X, F_Y, F_Z, F_COL: return 1'b1;
      F_U, F_V:             return t && !u16;
      F_UV:                 return t && u16;
      default:              return o;          // F_SPC
    endcase
  endfunction
  // a field's word in its vertex: x, y, z 0..2; volume 0's from 3, volume 1's after them
  logic [4:0] nvol, f_off;
  assign nvol = (tex ? (uv16 ? 5'd1 : 5'd2) : 5'd0) + 5'd1 + (ofs ? 5'd1 : 5'd0);
  always_comb begin
    logic [4:0] a, t;
    a = 5'd3 + (j_v1 ? nvol : 5'd0);
    t = tex ? (uv16 ? 5'd1 : 5'd2) : 5'd0;
    case (s_f)
      F_X:   f_off = 5'd0;
      F_Y:   f_off = 5'd1;
      F_Z:   f_off = 5'd2;
      F_U:   f_off = a;
      F_V:   f_off = a + 5'd1;
      F_UV:  f_off = a;
      F_COL: f_off = a + t;
      default: f_off = a + t + 5'd1;
    endcase
  end
  // the next field present after s_f (8: the vertex is done)
  logic [3:0] f_next;
  always_comb begin
    f_next = 4'd8;
    for (int f = 7; f >= 0; f--)
      if (f > int'(s_f) && present(3'(f), tex, ofs, uv16))
        f_next = 4'(f);
  end

  // what each request is, in request order
  typedef struct packed {
    logic       hdr;
    logic [2:0] h;
    logic [1:0] k;
    logic [2:0] f;
  } role_t;
  role_t [PF_OUT-1:0]         rq;
  logic [$clog2(PF_OUT)-1:0]  rq_rp, rq_wp;
  logic [OB-1:0]              rq_n;
  role_t                      r_new, r_head;
  logic                       iss, rsp;

  logic [23:0] woff;           // the request's word offset in the block
  always_comb begin
    woff = '0;
    if (st == S_HDR) woff = 24'(s_h);
    else woff = 24'(j_nh) + (24'(j.tag.tag_offset) + 24'(s_k)) * 24'(j_stride) + 24'(f_off);
  end
  assign m_v    = (st == S_HDR || st == S_VTX) && rq_n != OB'(PF_OUT);
  assign iss    = m_v && m_rdy;
  assign m_addr = j_base + (woff << 2);
  always_comb begin
    r_new     = '0;
    r_new.hdr = st == S_HDR;
    r_new.h   = s_h;
    r_new.k   = s_k;
    r_new.f   = s_f;
  end
  assign r_head = rq[rq_rp];
  assign rsp    = m_rv && m_rrdy;

  // ---------------------------------------------------------------------------------------------- the assembly
  logic [4:0][31:0]       hw;      // the header words
  logic [2:0][7:0][31:0]  vw;      // the vertices' fields
  p2_tsp_prim_t           pv;      // the primitive as it goes out
  logic                   fq_full, fq_push;
  assign fq_push = st == S_DONE && n_got == n_exp && !fq_full;
  assign jb_rdy  = st == S_IDLE;
  assign idle    = st == S_IDLE && rq_n == '0;

  always_comb begin
    logic [2:0] o;
    pv     = '0;
    pv.job = j;
    pv.isp = hw[0];
    pv.tsp = (j_v1) ? hw[3] : hw[1];
    pv.tcw = (j_v1) ? hw[4] : hw[2];
    for (int k = 0; k < 3; k++) begin
      // after the odd triangle's swap: corner k is fetched vertex o
      o = 3'(k);
      if (j.tag.tag_offset[0] && k < 2) o = 3'(1 - k);
      pv.x[k]   = vw[o][F_X];
      pv.y[k]   = vw[o][F_Y];
      pv.z[k]   = vw[o][F_Z];
      pv.u[k]   = uv16 ? (vw[o][F_UV] & 32'hFFFF0000) : vw[o][F_U];
      pv.v[k]   = uv16 ? (vw[o][F_UV] << 16) : vw[o][F_V];
      pv.col[k] = vw[o][F_COL];
      pv.spc[k] = vw[o][F_SPC];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      st    <= S_IDLE;
      rq_rp <= '0;
      rq_wp <= '0;
      rq_n  <= '0;
    end else begin
      if (iss) begin
        rq[rq_wp] <= r_new;
        rq_wp     <= rq_wp + 1'b1;
      end
      if (rsp)
        rq_rp <= rq_rp + 1'b1;
      rq_n <= rq_n + OB'(iss) - OB'(rsp);
      if (rsp) begin
        n_got <= n_got + 6'd1;
        if (r_head.hdr) begin
          hw[r_head.h] <= m_rdata;
          if (r_head.h == 3'd0) begin
            j_isp  <= {m_rdata[25], m_rdata[24], m_rdata[22]};
            isp_in <= 1'b1;
          end
        end else begin
          vw[r_head.k][r_head.f] <= m_rdata;
        end
      end
      case (st)
        S_IDLE: if (jb_v) begin
          j        <= jb;
          j_v1     <= jb.vsel && jb.tag.shadow && !shad_intensity;
          j_nh     <= (jb.tag.shadow && !shad_intensity) ? 3'd5 : 3'd3;
          j_stride <= 5'd3 + ({2'b00, jb.tag.skip} << (jb.tag.shadow && !shad_intensity));
          j_base   <= param_base[23:0] + {jb.tag.param_offs_in_words, 2'b00};
          isp_in   <= 1'b0;
          s_h      <= '0;
          n_exp    <= '0;
          n_got    <= '0;
          vw       <= '0;
          st       <= S_HDR;
        end
        S_HDR: if (iss) begin
          n_exp <= n_exp + 6'd1;
          s_h   <= s_h + 3'd1;
          if (s_h == j_nh - 3'd1) st <= S_WAIT;
        end
        S_WAIT: if (isp_in || (rsp && r_head.hdr && r_head.h == 3'd0)) begin
          s_k <= '0;
          s_f <= F_X;
          st  <= S_VTX;
        end
        S_VTX: if (iss) begin
          n_exp <= n_exp + 6'd1;
          if (f_next == 4'd8) begin
            s_f <= F_X;
            if (s_k == 2'd2) st <= S_DONE;
            else s_k <= s_k + 2'd1;
          end else begin
            s_f <= f_next[2:0];
          end
        end
        S_DONE: if (fq_push) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign m_rrdy = 1'b1;

  // ---------------------------------------------------------------------------------------------- the FIFO to setup
  p2_tsp_prim_t [PF_AHEAD-1:0] fq;
  logic [$clog2(PF_AHEAD)-1:0] fq_rp, fq_wp;
  logic [$clog2(PF_AHEAD+1)-1:0] fq_n;
  logic fq_pop;
  assign fq_full = fq_n == ($clog2(PF_AHEAD+1))'(PF_AHEAD);
  assign pr_v    = fq_n != '0;
  assign pr      = fq[fq_rp];
  assign fq_pop  = pr_v && pr_rdy;
  always_ff @(posedge clk) begin
    if (rst) begin
      fq_rp <= '0;
      fq_wp <= '0;
      fq_n  <= '0;
    end else begin
      if (fq_push) begin
        fq[fq_wp] <= pv;
        fq_wp     <= fq_wp + 1'b1;
      end
      if (fq_pop)
        fq_rp <= fq_rp + 1'b1;
      fq_n <= fq_n + ($clog2(PF_AHEAD+1))'(fq_push) - ($clog2(PF_AHEAD+1))'(fq_pop);
    end
  end
endmodule
