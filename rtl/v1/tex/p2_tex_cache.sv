// p2_tex_cache: the pixel pipe's P5, the texture cache and its fetch (PLAN M11; ARCHITECTURE 3.8, 6; client C4 of
// p2_mem). No functional rule: refsw3 reads emu_vram directly (refsw_tile.cpp TextureFetch, VQLookup); the words it gives
// are video memory's at the render's start (coherence with the write-out C5 is GAP T8: no snooping; a render whose
// texture reads meet its own write-out is a VRAM-race render, ARCHITECTURE 3.2.1). Its organisation is the placeholder of
// ARCHITECTURE 6 [G T8]: direct-mapped, 8 KB, 64-byte lines (128 lines of eight 64-bit words), invalidated at `flush`
// (a render's start) [I: the first tile of a render pays +35 .. +455, tim 3.9].
//
//   lookup      the point in the P4 register asks for up to four 64-bit words (p2_tex_req_t: the taps the filter reads);
//               each tap whose line is present is read the clock it asks (four read ports) and kept in the tap's own
//               register (`got`): a gather stage, so that a line filled for one tap may evict another's after it was
//               taken (taps of one point in lines of one set) [I tim 3.9: "four 16-bit words come in a clock"]
//   VQ          two dependent reads: the four index bytes first (phase 0), then the four code book entries at
//               code book + index (phase 1), each a lookup of its own [tsp 9.4]
//   miss        one line fill at a time: the first missing tap's line, eight 64-bit reads on C4 (the 64-bit view, both
//               halves a clock), the line's valid bit cleared at the first read and set with its tag at the eighth
//               response
//   tex_stall   the point is not ready: a tap not yet in, or VQ's index phase; into the pipe's global stall
//   swap        TEXT_CONTROL[17]: the two bytes of every 16-bit unit of the words P6 decodes swapped (texels, palette
//               indices, code book entries); the VQ index bytes are taken from the word as it is [texctl pages 2, 3, 11;
//               texctl_addr; texctl page 3: VQ palette 8 bpp read at ^ 9 with bit 16 too]
// The four words go to P6 (p2_tex_decode) in the P5 register. The bumphang counter of ARCHITECTURE 3.8 (a hang feature,
// MT9 / D6) is not here.
module p2_tex_cache
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst,
  input  logic                  flush,
  input  logic                  stall,       // the pipe's global stall (tex_stall included)
  input  logic                  swap16,      // TEXT_CONTROL[17]
  input  logic                  i_v,
  input  p2_pp_pt_t             i_pt,
  input  p2_tex_req_t           i_req,
  output logic                  tex_stall,
  output logic                  o_v,
  output p2_pp_pt_t             o_pt,
  output p2_tex_req_t           o_req,
  output logic [3:0][63:0]      o_word,
  // C4 (p2_mem, 64-bit view)
  output logic                  m_v,
  input  logic                  m_rdy,
  output logic [23:0]           m_addr,
  input  logic                  m_rv,
  output logic                  m_rrdy,
  input  logic [63:0]           m_rdata,
  // taps (statistics)
  output logic                  t_fill,
  output logic                  t_miss
);
  localparam int NW = P2_TEXC_LINES * 8;

  logic [63:0]               cdata [NW];
  logic [P2_TEXC_TAGB-1:0]   ctag  [P2_TEXC_LINES];
  logic [P2_TEXC_LINES-1:0]  cval;

  logic                      pend, phase;
  logic [3:0]                got;
  logic [3:0][63:0]          gw;
  logic [3:0][7:0]           vqi;          // VQ: the index bytes (phase 1)
  assign pend = i_v && i_req.need != 4'b0000;

  // ---------------------------------------------------------------------------------------------- the four lookups
  logic [3:0][19:0]  ta;
  logic [3:0]        hit, avail;
  logic [3:0][63:0]  word;
  always_comb
    for (int t = 0; t < 4; t++) begin
      logic [P2_TEXC_SETB-1:0] st;
      ta[t]    = (i_req.vq && phase) ? (i_req.cbase + 20'(vqi[t])) : i_req.waddr[t];
      st       = ta[t][9:3];
      hit[t]   = cval[st] && ctag[st] == ta[t][19:10];
      word[t]  = got[t] ? gw[t] : cdata[{st, ta[t][2:0]}];
      avail[t] = !i_req.need[t] || got[t] || hit[t];
    end
  logic all_in, idx_done;
  assign all_in    = avail == 4'b1111;
  assign idx_done  = pend && i_req.vq && !phase && all_in;      // VQ: the indices are in, the entries next
  assign tex_stall = pend && !(all_in && (!i_req.vq || phase));

  // ---------------------------------------------------------------------------------------------- the fill
  logic        f_busy;
  logic [16:0] f_line;                    // word address bits 19:3
  logic [3:0]  f_req, f_rsp;              // reads issued, responses taken
  logic        f_start;
  logic [16:0] f_next;
  always_comb begin
    f_start = 1'b0;
    f_next  = '0;
    if (pend && !f_busy && !all_in)
      for (int t = 3; t >= 0; t--)
        if (!avail[t]) begin
          f_start = 1'b1;
          f_next  = ta[t][19:3];
        end
  end
  assign m_v    = f_busy && f_req != 4'd8;
  assign m_addr = {1'b0, f_line, f_req[2:0], 3'd0};
  assign m_rrdy = 1'b1;
  assign t_fill = f_busy;
  assign t_miss = f_start;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      cval   <= '0;
      f_busy <= 1'b0;
    end else begin
      if (f_start) begin
        f_busy           <= 1'b1;
        f_line           <= f_next;
        f_req            <= '0;
        f_rsp            <= '0;
        cval[f_next[6:0]] <= 1'b0;
      end
      if (m_v && m_rdy) f_req <= f_req + 4'd1;
      if (f_busy && m_rv) begin
        cdata[{f_line[6:0], f_rsp[2:0]}] <= m_rdata;
        f_rsp <= f_rsp + 4'd1;
        if (f_rsp == 4'd7) begin
          f_busy             <= 1'b0;
          ctag[f_line[6:0]]  <= f_line[16:7];
          cval[f_line[6:0]]  <= 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------------------------- the taps' registers
  always_ff @(posedge clk) begin
    if (rst) begin
      got   <= '0;
      phase <= 1'b0;
    end else if (pend && !stall) begin
      got   <= '0;                        // the point leaves
      phase <= 1'b0;
    end else if (idx_done) begin
      got   <= '0;
      phase <= 1'b1;
      for (int t = 0; t < 4; t++)
        vqi[t] <= word[t][8 * i_req.ibyte[t] +: 8];
    end else if (pend)
      for (int t = 0; t < 4; t++)
        if (i_req.need[t] && !got[t] && hit[t]) begin
          got[t] <= 1'b1;
          gw[t]  <= word[t];
        end
  end

  always_ff @(posedge clk) begin
    if (rst) o_v <= 1'b0;
    else if (!stall) o_v <= i_v;
    if (i_v && !stall) begin
      o_pt   <= i_pt;
      o_req  <= i_req;
      for (int t = 0; t < 4; t++)
        o_word[t] <= swap16 ? {word[t][55:48], word[t][63:56], word[t][39:32], word[t][47:40], word[t][23:16],
                               word[t][31:24], word[t][7:0], word[t][15:8]} : word[t];
    end
  end
endmodule
