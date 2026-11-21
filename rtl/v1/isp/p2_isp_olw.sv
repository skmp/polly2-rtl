// p2_isp_olw: the object list walker (PLAN M6; ARCHITECTURE 3.4.2; isp 5, 3.2; refcore refsw_lists.cpp RenderObjectList
// at refsw3 4f3efe15). It reads an object list through client C1 of p2_mem and hands every entry that draws to
// p2_isp_pfetch, in list order.
//
// The words (ObjectListEntry, refsw_lists_regtypes.h):
//   bit 31 = 0       a triangle strip: triangles i = 0 .. 5 with mask bit 5 - i (RenderTriangleStrip); one item with its
//                    mask. A strip whose mask is 0 draws nothing and is not handed on
//   type 100 / 101   a triangle / quad array of prims + 1 primitives (RenderTriangleArray / RenderQuadArray); one item
//   type 111         a link: end_of_list (bit 28) ends the walk, otherwise the walk goes on at next_block_ptr * 4
//   type 110         nothing (refsw3 prints "not handled" and goes on; GAP isp 15 #15)
//
// Read-ahead [G OLW_AHEAD = 8 words, ARCHITECTURE 6; T1]: from the list's start (and from a link's target) the walker
// requests consecutive words while fewer than OLW_AHEAD are requested and not yet consumed; the words wait in p2_mem's
// response buffer for C1 (RSP_N >= OLW_AHEAD). At a link or the end of the list the words requested past it are
// consumed and dropped (counted, in order: the client's responses come back in request order). The words read past the
// end are never used. [M tim 3.1: a pointer to an empty list costs 20-31 clk: this read's latency through p2_mem and the
// VRAM.] Following a link costs one more read latency.
//
// Command: start (cmd_v) with the list's byte address in the 32-bit view (the entry's ptr_in_words * 4). The walk is
// done (idle) when the end of the list has been consumed, every word requested has come back, and the last item was
// taken by pfetch.
//
// Scan (cmd_scan with cmd_v; PLAN M7, ARCHITECTURE 3.4.1 OpInPt, isp 11.3; refsw_lists.cpp ObjectListHasPrimitive): the
// same walk, handing nothing on: it stops at the first strip entry with a mask bit or the first triangle / quad array
// entry (has_prim = 1: the list HOLDS a primitive, whether it draws or not: pvr-tests/optcull) or at end_of_list
// (has_prim = 0); the words requested past the stop are dropped as at a link.
//
// Chunk pause (ARCHITECTURE 3.4.2): when p2_isp_ptc holds a primitive of the next punch-through chunk, the walk is held
// by back-pressure (pfetch, setup and the hand-off fill up behind it) at its position, and goes on when ctl starts the
// next chunk; no command is needed.
module p2_isp_olw
  import p2_pkg::*;
  import p2_regs_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  // the walk
  input  logic          cmd_v,
  input  logic [23:0]   cmd_addr,
  input  logic          cmd_scan,
  output logic          idle,
  output logic          has_prim,       // the last scan's answer
  // the entries that draw, to p2_isp_pfetch
  output logic          ob_v,
  input  logic          ob_rdy,
  output p2_isp_obj_t   ob,
  // C1 (p2_mem)
  output logic          m_v,
  input  logic          m_rdy,
  output logic [23:0]   m_addr,
  input  logic          m_rv,
  output logic          m_rrdy,
  input  logic [31:0]   m_rdata
);
  localparam int OLW_AHEAD = 8;     // [G] ARCHITECTURE 6, T1
  localparam int AB = $clog2(OLW_AHEAD + 1);

  logic          walking;           // words are still to be requested and consumed (the end not yet met)
  logic          scan;              // the walk is a scan
  logic [23:0]   fa;                // the next word to request
  logic [AB-1:0] ahead;             // requested and not yet consumed
  logic [AB-1:0] drop;              // of those, requested past a link or the end: consumed and dropped

  // ---------------------------------------------------------------------------------------------- the word at the head
  p2_objent_t      w_ent;
  p2_objent_type_t w_typ;
  p2_objent_tstrip_t w_strip;
  p2_objent_tarray_t w_arr;
  p2_objent_link_t w_link;
  assign w_ent   = p2_objent_t'(m_rdata);
  assign w_typ   = p2_objent_type_t'(m_rdata);
  assign w_strip = p2_objent_tstrip_t'(m_rdata);
  assign w_arr   = p2_objent_tarray_t'(m_rdata);
  assign w_link  = p2_objent_link_t'(m_rdata);

  logic is_strip, is_arr, is_link, emits;
  assign is_strip = !w_ent.is_not_triangle_strip;
  assign is_arr   = w_ent.is_not_triangle_strip && (w_typ.type_ == 3'b100 || w_typ.type_ == 3'b101);
  assign is_link  = w_ent.is_not_triangle_strip && w_typ.type_ == 3'b111;
  assign emits    = (is_strip && w_strip.mask != '0) || is_arr;

  logic live, w_use, take_link, take_hit;
  assign live      = m_rv && drop == '0 && walking;       // a word of the list
  assign w_use       = live && (scan || !emits || ob_rdy);
  assign m_rrdy    = (drop != '0) || (walking && (scan || !emits || ob_rdy));
  assign take_link = w_use && is_link;
  assign take_hit  = w_use && scan && emits;

  always_comb begin
    ob        = '0;
    ob.offs   = w_strip.param_offs_in_words;
    ob.skip   = w_strip.skip;
    ob.shadow = w_strip.shadow;
    ob.mask   = w_strip.mask;
    ob.prims  = w_arr.prims;
    ob.kind   = is_strip ? P2_OBJ_STRIP : (w_typ.type_ == 3'b100 ? P2_OBJ_TRI : P2_OBJ_QUAD);
  end
  assign ob_v = live && emits && !scan;

  // ---------------------------------------------------------------------------------------------- the requests
  // none in the clock a link is consumed: the words in flight are then exactly the ones to drop
  assign m_v    = walking && !take_link && !take_hit && ahead != AB'(OLW_AHEAD);
  assign m_addr = fa;

  logic pop;
  assign pop = m_rv && m_rrdy;
  always_ff @(posedge clk) begin
    if (rst) begin
      walking <= 1'b0;
      ahead   <= '0;
      drop    <= '0;
    end else begin
      ahead <= AB'(ahead + AB'(m_v && m_rdy) - AB'(pop));
      if (m_v && m_rdy)
        fa <= fa + 24'd4;
      if (drop != '0 && pop)
        drop <= drop - AB'(1);
      if (take_link) begin
        // the words requested after the link: in flight, dropped as they come back (this one is popped now)
        drop <= AB'(ahead - AB'(1));
        if (w_link.end_of_list)
          walking <= 1'b0;
        else
          fa <= {w_link.next_block_ptr_in_words, 2'b00};
      end
      // a scan's answer: the list holds a primitive (stop here), or the end of the list (no)
      if (take_hit) begin
        drop     <= AB'(ahead - AB'(1));
        walking  <= 1'b0;
        has_prim <= 1'b1;
      end
      if (cmd_v) begin
        walking  <= 1'b1;
        scan     <= cmd_scan;
        has_prim <= 1'b0;
        fa       <= cmd_addr;
      end
    end
  end
  assign idle = !walking && ahead == '0;

`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (!rst && cmd_v && !idle)
      $error("p2_isp_olw: a walk started before the last one ended");
`endif
endmodule
