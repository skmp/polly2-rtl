// p2_mem: the CORE's video memory clients and their arbitration onto the two 32-bit halves (ARCHITECTURE 3.2, 1.2;
// PLAN M6 builds it with the clients C1 p2_isp_olw and C2 p2_isp_pfetch; the others are tied off until their units land).
//
// Address views (conventions 7.3, refcore pvr_mem.cpp pvr_map32 / vri):
//   32-bit view (c_w64 = 0): byte address a goes to half a[22], word a[21:2]; bits 23 and up are dropped (the 8 MB wrap of
//                 pvr_map32: its static bits are only a[1:0] with 8 MB of video memory). Data in c_wdata / c_rdata[31:0],
//                 byte enables c_be[3:0]
//   64-bit view (c_w64 = 1): word A[22:3] of both halves, half 0 in the low 32 bits (`& (VRAM_MASK - 7)`); both halves in
//                 one clock (texture reads, tim 1 [I])
//
// Arbitration [G: fixed priority, the console's SDRAM_ARB_CFG = 0x1f is GAP T14]: per half one grant a clock; the
// highest-numbered client with a request for a free half wins (C5 > C4 > ... > C0); a 64-bit request is granted only
// when both halves are free, before any lower client. A half is free when its request register is empty or is handed
// to the VRAM port this clock. The request register is the only buffering on the way out ("p2_mem adds one clock").
//
// Responses: the VRAM answers each half in its own request order (any latency); every client gets its read data in
// its own request order. A client's reads are counted from grant to the client's pop (c_rv && c_rrdy) and at most
// RSP_N may be outstanding: c_rdy stays low past that. So each (client, half) response FIFO of RSP_N entries never
// overflows and the VRAM port needs no ready on its responses. (As built, M6: ARCHITECTURE 3.2's client interface plus
// c_rrdy, the client's ready for a response: the response buffer of a client is here, not in the client.)
//
// Writes are granted like reads and answer nothing.
module p2_mem
  import p2_pkg::*;
#(
  parameter int NC    = 6,   // clients C0 .. C5 (ARCHITECTURE 3.2)
  parameter int RSP_N = 8    // reads a client may have outstanding [G]
)
(
  input  logic                                      clk,
  input  logic                                      rst,
  // clients
  input  logic [NC-1:0]                             c_v,
  output logic [NC-1:0]                             c_rdy,
  input  logic [NC-1:0]                             c_we,
  input  logic [NC-1:0]                             c_w64,
  input  logic [NC-1:0][23:0]                       c_addr,
  input  logic [NC-1:0][7:0]                        c_be,
  input  logic [NC-1:0][63:0]                       c_wdata,
  output logic [NC-1:0]                             c_rv,
  input  logic [NC-1:0]                             c_rrdy,
  output logic [NC-1:0][63:0]                       c_rdata,
  // the two VRAM halves (p2_core's ports, ARCHITECTURE 1.2)
  output logic [P2_VRAM_HALVES-1:0]                         vh_req_v,
  input  logic [P2_VRAM_HALVES-1:0]                         vh_req_rdy,
  output logic [P2_VRAM_HALVES-1:0]                         vh_req_we,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_IDX_BITS-1:0]   vh_req_idx,
  output logic [P2_VRAM_HALVES-1:0][3:0]                    vh_req_be,
  output logic [P2_VRAM_HALVES-1:0][31:0]                   vh_req_wdata,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]   vh_req_src,
  input  logic [P2_VRAM_HALVES-1:0]                         vh_rsp_v,
  input  logic [P2_VRAM_HALVES-1:0][31:0]                   vh_rsp_data,
  input  logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]   vh_rsp_src
);
  localparam int H  = P2_VRAM_HALVES;
  localparam int RB = $clog2(RSP_N + 1);
  localparam int PB = $clog2(RSP_N);

  // ---------------------------------------------------------------------------------------------- the request registers
  logic [H-1:0]                       q_v, q_we;
  logic [H-1:0][P2_VRAM_IDX_BITS-1:0] q_idx;
  logic [H-1:0][3:0]                  q_be;
  logic [H-1:0][31:0]                 q_wd;
  logic [H-1:0][P2_VRAM_SRC_BITS-1:0] q_src;
  logic [H-1:0]                       hfree;
  assign vh_req_v     = q_v;
  assign vh_req_we    = q_we;
  assign vh_req_idx   = q_idx;
  assign vh_req_be    = q_be;
  assign vh_req_wdata = q_wd;
  assign vh_req_src   = q_src;
  always_comb
    for (int h = 0; h < H; h++)
      hfree[h] = !q_v[h] || vh_req_rdy[h];

  // ---------------------------------------------------------------------------------------------- arbitration
  logic [NC-1:0][RB-1:0] outst;           // reads granted and not yet popped by the client
  logic [NC-1:0]         grant;
  logic [NC-1:0][H-1:0]  ghalf;           // the halves a grant takes
  always_comb begin
    logic [H-1:0] taken;
    taken = '0;
    grant = '0;
    ghalf = '0;
    for (int c = NC - 1; c >= 0; c--) begin
      logic [H-1:0] need;
      logic         credit;
      need   = c_w64[c] ? 2'b11 : (c_addr[c][22] ? 2'b10 : 2'b01);
      credit = c_we[c] || outst[c] != RB'(RSP_N);
      if (c_v[c] && credit && (need & (hfree & ~taken)) == need) begin
        grant[c] = 1'b1;
        ghalf[c] = need;
        taken    = taken | need;
      end
    end
  end
  assign c_rdy = grant;

  // ---------------------------------------------------------------------------------------------- response routing
  // per client the order of its outstanding reads: which halves each one waits for
  logic [NC-1:0][RSP_N-1:0][H-1:0] ord;
  logic [NC-1:0][PB-1:0]           ord_rp, ord_wp;
  // per client and half the responses that came back
  logic [NC-1:0][H-1:0][RSP_N-1:0][31:0] rf;
  logic [NC-1:0][H-1:0][PB-1:0]          rf_rp, rf_wp;
  logic [NC-1:0][H-1:0][RB-1:0]          rf_n;

  logic [NC-1:0] pop;
  always_comb begin
    for (int c = 0; c < NC; c++) begin
      logic [H-1:0] w;
      logic         ready;
      w     = ord[c][ord_rp[c]];
      ready = outst[c] != '0;
      for (int h = 0; h < H; h++)
        if (w[h] && rf_n[c][h] == '0)
          ready = 1'b0;
      c_rv[c]    = ready;
      // a 32-bit read's word in the low half of c_rdata, whichever half it came from
      c_rdata[c] = w == 2'b11 ? {rf[c][1][rf_rp[c][1]], rf[c][0][rf_rp[c][0]]}
                              : {32'd0, w[1] ? rf[c][1][rf_rp[c][1]] : rf[c][0][rf_rp[c][0]]};
    end
  end
  assign pop = c_rv & c_rrdy;

  always_ff @(posedge clk) begin
    if (rst) begin
      q_v    <= '0;
      outst  <= '0;
      ord_rp <= '0;
      ord_wp <= '0;
      rf_rp  <= '0;
      rf_wp  <= '0;
      rf_n   <= '0;
    end else begin
      for (int h = 0; h < H; h++)
        if (vh_req_rdy[h])
          q_v[h] <= 1'b0;
      for (int c = 0; c < NC; c++) begin
        if (grant[c]) begin
          for (int h = 0; h < H; h++)
            if (ghalf[c][h]) begin
              q_v[h]   <= 1'b1;
              q_we[h]  <= c_we[c];
              q_idx[h] <= c_w64[c] ? c_addr[c][22:3] : c_addr[c][21:2];
              q_be[h]  <= c_w64[c] ? c_be[c][4*h +: 4] : c_be[c][3:0];
              q_wd[h]  <= c_w64[c] ? c_wdata[c][32*h +: 32] : c_wdata[c][31:0];
              q_src[h] <= P2_VRAM_SRC_BITS'(c);
            end
          if (!c_we[c]) begin
            ord[c][ord_wp[c]] <= ghalf[c];
            ord_wp[c]         <= PB'(ord_wp[c] + PB'(1));
          end
        end
        if (pop[c]) begin
          ord_rp[c] <= PB'(ord_rp[c] + PB'(1));
          for (int h = 0; h < H; h++)
            if (ord[c][ord_rp[c]][h])
              rf_rp[c][h] <= PB'(rf_rp[c][h] + PB'(1));
        end
        outst[c] <= RB'(outst[c] + RB'(grant[c] && !c_we[c]) - RB'(pop[c]));
        for (int h = 0; h < H; h++) begin
          logic push;
          push = vh_rsp_v[h] && vh_rsp_src[h] == P2_VRAM_SRC_BITS'(c);
          if (push) begin
            rf[c][h][rf_wp[c][h]] <= vh_rsp_data[h];
            rf_wp[c][h]           <= PB'(rf_wp[c][h] + PB'(1));
          end
          rf_n[c][h] <= RB'(rf_n[c][h] + RB'(push) - RB'(pop[c] && ord[c][ord_rp[c]][h]));
        end
      end
    end
  end

`ifndef SYNTHESIS
  // a response for a client with nothing outstanding on that half would overflow its FIFO
  always_ff @(posedge clk)
    if (!rst)
      for (int h = 0; h < H; h++)
        if (vh_rsp_v[h] && int'(vh_rsp_src[h]) < NC && rf_n[vh_rsp_src[h]][h] == RB'(RSP_N))
          $error("p2_mem: half %0d answered client %0d past its %0d outstanding reads", h, vh_rsp_src[h], RSP_N);
`endif
endmodule
