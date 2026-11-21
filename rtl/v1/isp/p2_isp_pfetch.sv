// p2_isp_pfetch: the ISP's parameter fetch and primitive assembly (PLAN M6; ARCHITECTURE 3.4.3; isp 3.3-3.5; refcore
// refsw_lists.cpp RenderTriangleStrip / RenderTriangleArray / RenderQuadArray, CoreTagFromDesc, refsw_tile.cpp
// decode_pvr_vertices at refsw3 4f3efe15). It takes p2_isp_olw's entries, reads what the ISP needs of their parameter
// blocks through client C2 of p2_mem (the ISP/TSP word and each corner's x, y, z), and hands p2_isp_setup one assembled
// primitive (p2_asm_t) at a time, in list order.
//
// Where a block is (refsw_lists.cpp, decode_pvr_vertices):
//   block    (PARAM_BASE & 0xF00000) + param_offs_in_words * 4: the ISP takes PARAM_BASE's bits 23:20 only (dreamcast-
//            tests pvr-tests/ispcache; scenegen's PARAM_BASE 0x40)
//   header   3 words (ISP/TSP word, TSP, TCW), 5 with two volumes; two volumes = shadow && !FPU_SHAD_SCALE[8] (with
//            intensity shadow a shadowed polygon has one volume: sc_ingame2, scenegen MODVOL)
//   vertex   3 + skip * (1 + two volumes) words; x, y, z are its first three (IEEE single bits)
//   strip    one block of up to 8 vertices; triangle i has corners (v[i], v[i+1], v[i+2]) when i is even and
//            (v[i+1], v[i], v[i+2]) when i is odd (the strip's winding kept: RenderTriangleStrip's not_even / even); the
//            vertices up to the last one a set mask bit needs are read (refsw3 decodes all 8: the same corners)
//   arrays   prims + 1 blocks back to back, each with its own header and 3 (4) vertices; the next block follows the
//            last vertex
//   tag      CoreTagFromDesc: {3'b0, ISP word bit 21 (cache bypass), shadow, skip, param_offs, tag_offset}; a strip's
//            param_offs is the entry's and tag_offset its i; an array primitive's param_offs its own block's (its offset
//            from the masked PARAM_BASE in words, 21 bits) and tag_offset 0
//
// Structure [G PF_AHEAD = 2, ARCHITECTURE 6; T2]:
//   sequencer   one word request a clock to C2, at most PF_OUT outstanding (each with its role in the role FIFO)
//   assembler   the responses in order, into one of two vertex buffers (8 vertices x x, y, z, and the ISP/TSP word);
//               a buffer is handed to the emitter when its group's last word is in (a strip, or one array primitive)
//   emitter     a strip's triangles one a clock, an array's primitive, into the asm FIFO (PF_AHEAD) to p2_isp_setup
// [M pfetch: 4 or 8 more words a primitive add ~0 clk: the fetch runs ahead of the 16-clk setup.] The strip alternation
// 19 / 15 is GAP T2; nothing here models it.
module p2_isp_pfetch
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  // the entries, from p2_isp_olw
  input  logic          ob_v,
  output logic          ob_rdy,
  input  p2_isp_obj_t   ob,
  // the walk's RenderMode and tile (p2_isp_ctl), the render's registers
  input  p2_rm_t        rm,
  input  logic [5:0]    tilex,
  input  logic [5:0]    tiley,
  input  logic [31:0]   param_base,       // PARAM_BASE
  input  logic          shad_intensity,   // FPU_SHAD_SCALE[8]
  // to p2_isp_setup
  output logic          asm_v,
  input  logic          asm_rdy,
  output p2_asm_t       asm_o,
  output logic          idle,
  // C2 (p2_mem)
  output logic          m_v,
  input  logic          m_rdy,
  output logic [23:0]   m_addr,
  input  logic          m_rv,
  output logic          m_rrdy,
  input  logic [31:0]   m_rdata
);
  localparam int PF_OUT   = 8;    // word reads outstanding (p2_mem RSP_N) [G]
  localparam int PF_AHEAD = 2;    // assembled primitives ahead of setup [G] ARCHITECTURE 6
  localparam int OB = $clog2(PF_OUT + 1);

  // ---------------------------------------------------------------------------------------------- the sequencer
  logic          s_act, s_first;
  p2_obj_kind_t  s_kind;
  logic [5:0]    s_mask;
  logic [2:0]    s_skip;
  logic          s_shadow;
  logic [4:0]    s_stride;        // 3 + skip (1 + two): at most 17 words
  logic [2:0]    s_hdr;           // 3 or 5 words
  logic [3:0]    s_n;             // array primitives left after this one
  logic [2:0]    s_nvm1;          // vertices of a group - 1
  logic [23:0]   s_woff;          // the block's offset from the masked PARAM_BASE, words
  logic [23:0]   s_vw;            // the current vertex's offset, words
  logic [2:0]    s_v;
  logic [1:0]    s_c;

  // the ISP's parameter base: PARAM_BASE & 0xF00000
  logic [23:0] pb;
  assign pb = {param_base[23:20], 20'd0};

  // what each request is, in request order (the responses come back in it)
  typedef struct packed {
    logic         first;          // the ISP/TSP word: the group's header below is valid
    logic         last;           // the group's last word
    logic [2:0]   v;
    logic [1:0]   c;              // 0 x, 1 y, 2 z
    p2_obj_kind_t kind;
    logic [5:0]   mask;
    logic         shadow;
    logic [2:0]   skip;
    logic [20:0]  toffs;          // the tag's param_offs
  } role_t;
  role_t [PF_OUT-1:0]   rq;
  logic [$clog2(PF_OUT)-1:0] rq_rp, rq_wp;
  logic [OB-1:0]        rq_n;
  role_t                r_new, r_head;

  logic       iss, lastw;
  logic [2:0] in_nvm1;
  // a strip's vertices: up to the one the last set mask bit needs (triangle i = 5 - p for mask bit p uses v[i + 2])
  always_comb begin
    in_nvm1 = 3'd7;
    for (int p = 5; p >= 0; p--)
      if (ob.mask[p])
        in_nvm1 = 3'(7 - p);
    if (ob.kind == P2_OBJ_TRI)
      in_nvm1 = 3'd2;
    else if (ob.kind == P2_OBJ_QUAD)
      in_nvm1 = 3'd3;
  end

  // two volumes: the shadow bit without FPU_SHAD_SCALE's intensity mode (refsw_lists.cpp two_volumes)
  logic in_two;
  assign in_two = ob.shadow && !shad_intensity;
  assign ob_rdy = !s_act;
  assign m_v    = s_act && rq_n != OB'(PF_OUT);
  assign iss    = m_v && m_rdy;
  assign m_addr = pb + ((s_first ? s_woff : s_vw + 24'(s_c)) << 2);
  assign lastw  = !s_first && s_v == s_nvm1 && s_c == 2'd2;

  always_comb begin
    r_new        = '0;
    r_new.first  = s_first;
    r_new.last   = lastw;
    r_new.v      = s_v;
    r_new.c      = s_c;
    r_new.kind   = s_kind;
    r_new.mask   = s_mask;
    r_new.shadow = s_shadow;
    r_new.skip   = s_skip;
    r_new.toffs  = s_woff[20:0];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      s_act <= 1'b0;
    end else begin
      if (ob_v && ob_rdy) begin
        s_act    <= 1'b1;
        s_first  <= 1'b1;
        s_kind   <= ob.kind;
        s_mask   <= ob.mask;
        s_skip   <= ob.skip;
        s_shadow <= ob.shadow;
        s_stride <= 5'd3 + 5'(ob.skip) * (in_two ? 5'd2 : 5'd1);
        s_hdr    <= in_two ? 3'd5 : 3'd3;
        s_n      <= ob.kind == P2_OBJ_STRIP ? 4'd0 : ob.prims;
        s_nvm1   <= in_nvm1;
        s_woff   <= 24'(ob.offs);
      end
      if (iss) begin
        if (s_first) begin
          s_first <= 1'b0;
          s_vw    <= s_woff + 24'(s_hdr);
          s_v     <= '0;
          s_c     <= '0;
        end else if (s_c != 2'd2) begin
          s_c <= s_c + 2'd1;
        end else begin
          s_c  <= '0;
          s_vw <= s_vw + 24'(s_stride);
          s_v  <= s_v + 3'd1;
          if (lastw) begin
            if (s_n == '0)
              s_act <= 1'b0;
            else begin
              // the next array block follows this one's last vertex
              s_n     <= s_n - 4'd1;
              s_woff  <= s_vw + 24'(s_stride);
              s_first <= 1'b1;
            end
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------- the assembler
  logic [1:0]                  full;     // vertex buffer b holds a whole group, not yet emitted
  logic                        fb, eb;   // the buffer being filled, the buffer being emitted
  logic [1:0][7:0][2:0][31:0]  vb;
  logic [1:0][31:0]            bisp;
  typedef struct packed {
    p2_obj_kind_t kind;
    logic [5:0]   mask;
    logic         shadow;
    logic [2:0]   skip;
    logic [20:0]  toffs;
  } bhdr_t;
  bhdr_t [1:0] bh;

  logic apop;
  assign r_head = rq[rq_rp];
  // the response at the head is this group's word; the buffer it goes to must be free
  assign m_rrdy = !full[fb];
  assign apop   = m_rv && m_rrdy;

  always_ff @(posedge clk) begin
    if (rst) begin
      rq_rp <= '0;
      rq_wp <= '0;
      rq_n  <= '0;
      fb    <= 1'b0;
    end else begin
      if (iss) begin
        rq[rq_wp] <= r_new;
        rq_wp     <= rq_wp + 1'b1;
      end
      rq_n <= OB'(rq_n + OB'(iss) - OB'(apop));
      if (apop) begin
        rq_rp <= rq_rp + 1'b1;
        if (r_head.first) begin
          bisp[fb]        <= m_rdata;
          bh[fb].kind     <= r_head.kind;
          bh[fb].mask     <= r_head.mask;
          bh[fb].shadow   <= r_head.shadow;
          bh[fb].skip     <= r_head.skip;
          bh[fb].toffs    <= r_head.toffs;
        end else
          vb[fb][r_head.v][r_head.c] <= m_rdata;
        if (r_head.last)
          fb <= !fb;
      end
    end
  end

  // ---------------------------------------------------------------------------------------------- the emitter
  logic       e_act;
  logic [5:0] rem;          // the triangles still to emit, bit i for strip triangle i (an array primitive: bit 0)
  logic [2:0] ei;
  logic       e_push, e_last;
  always_comb begin
    ei = '0;
    for (int i = 5; i >= 0; i--)
      if (rem[i])
        ei = 3'(i);
  end

  // the asm FIFO
  p2_asm_t [PF_AHEAD-1:0] af;
  localparam int AFB = $clog2(PF_AHEAD + 1);
  logic [AFB-1:0] af_n;
  logic           af_pop;
  assign asm_v  = af_n != '0;
  assign asm_o  = af[0];
  assign af_pop = asm_v && asm_rdy;
  assign e_push = e_act && (af_n != AFB'(PF_AHEAD) || af_pop);
  assign e_last = (rem & ~(6'd1 << ei)) == '0;

  // the primitive: corners in rasterizer order
  p2_asm_t a_new;
  always_comb begin
    logic       odd;
    logic [2:0] c0, c1, c2;
    odd         = ei[0];
    c0          = odd ? 3'(ei + 3'd1) : ei;
    c1          = odd ? ei : 3'(ei + 3'd1);
    c2          = 3'(ei + 3'd2);
    a_new       = '0;
    a_new.isp   = bisp[eb];
    a_new.rm    = rm;
    a_new.tilex = tilex;
    a_new.tiley = tiley;
    a_new.quad  = bh[eb].kind == P2_OBJ_QUAD;
    a_new.tag.cache_bypass        = bisp[eb][21];
    a_new.tag.shadow              = bh[eb].shadow;
    a_new.tag.skip                = bh[eb].skip;
    a_new.tag.param_offs_in_words = bh[eb].toffs;
    if (bh[eb].kind == P2_OBJ_STRIP) begin
      // triangle i: (v[i], v[i+1], v[i+2]), the first two swapped when i is odd (RenderTriangleStrip)
      a_new.tag.tag_offset = ei;
      a_new.x[0] = vb[eb][c0][0];       a_new.y[0] = vb[eb][c0][1];       a_new.z[0] = vb[eb][c0][2];
      a_new.x[1] = vb[eb][c1][0];       a_new.y[1] = vb[eb][c1][1];       a_new.z[1] = vb[eb][c1][2];
      a_new.x[2] = vb[eb][c2][0];       a_new.y[2] = vb[eb][c2][1];       a_new.z[2] = vb[eb][c2][2];
    end else begin
      for (int q = 0; q < 3; q++) begin
        a_new.x[q] = vb[eb][q][0];
        a_new.y[q] = vb[eb][q][1];
        a_new.z[q] = vb[eb][q][2];
      end
      if (bh[eb].kind == P2_OBJ_QUAD) begin
        a_new.x[3] = vb[eb][3][0];
        a_new.y[3] = vb[eb][3][1];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      e_act <= 1'b0;
      eb    <= 1'b0;
      full  <= '0;
      af_n  <= '0;
    end else begin
      // a group's last word fills its buffer
      if (apop && r_head.last)
        full[fb] <= 1'b1;
      if (!e_act && full[eb]) begin
        e_act <= 1'b1;
        // strip triangle i is mask bit 5 - i
        rem   <= bh[eb].kind == P2_OBJ_STRIP ? {bh[eb].mask[0], bh[eb].mask[1], bh[eb].mask[2], bh[eb].mask[3],
                                                bh[eb].mask[4], bh[eb].mask[5]} : 6'd1;
      end
      if (e_push) begin
        rem <= rem & ~(6'd1 << ei);
        if (e_last) begin
          e_act    <= 1'b0;
          full[eb] <= 1'b0;
          eb       <= !eb;
        end
      end
      if (af_pop)
        for (int k = 0; k < PF_AHEAD - 1; k++)
          af[k] <= af[k + 1];
      if (e_push)
        af[af_pop ? int'(af_n) - 1 : int'(af_n)] <= a_new;
      af_n <= AFB'(af_n + AFB'(e_push) - AFB'(af_pop));
    end
  end

  assign idle = !s_act && rq_n == '0 && full == '0 && !e_act && af_n == '0;
endmodule
