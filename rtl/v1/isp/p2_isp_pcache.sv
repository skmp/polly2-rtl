// p2_isp_pcache: the ISP primitive cache, replays of set-up descriptors (PLAN M7; ARCHITECTURE 3.4.11; isp 11.4, 11.6;
// dreamcast-tests pvr-tests/ispcache; timemeas "blend": a later sorted pass costs no setup).
//
// Functionally transparent: a replay gives the raster the descriptors setup would compute again, in their order.
//   fill     the descriptors the raster takes from the setup side while fill_en (a punch-through chunk's pass 0, the
//            translucent sort's pass 0) are recorded in order, up to PCACHE_N [G: 256]. TR: a unit counter adds 4 a
//            triangle and 8 a quad [M ispcache: ISP_FEED_CFG[23:14] counts about 4 a triangle, 8 a sprite]; when it
//            would reach ISP_FEED_CFG[23:14] (sizes below 32 act as 32 [M]) the cache has overflowed: ovf, and the
//            descriptor and the ones after it are not recorded (the later passes walk the list again [G]; the 8-bit
//            "never at 256" behaviour is GAP). PT: a chunk of more than PCACHE_N descriptors overflows likewise (its
//            later passes are walks, p2_isp_ptc's full-walk mode [G])
//   replay   rp_* streams the recorded descriptors, first to last, one a clock at most (a registered read and one
//            descriptor ahead); rp_done when the last was taken
//   reset    at a punch-through phase's start, at each chunk, at the sort's start: empty, ovf = 0
module p2_isp_pcache
  import p2_pkg::*;
#(
  parameter int PCACHE_N = 256     // [G] ARCHITECTURE 6, T13
) (
  input  logic          clk,
  input  logic          rst,
  input  logic          reset,
  input  logic          tr,               // count units (the translucent sort) or descriptors (punch-through)
  input  logic [9:0]    tr_size,          // ISP_FEED_CFG[23:14]
  // fill: a descriptor the raster takes from the setup side
  input  logic          fill_en,
  input  logic          fill_v,
  input  p2_rdesc_t     fill_d,
  output logic          ovf,
  // replay
  input  logic          rp_start,
  output logic          rp_v,
  input  logic          rp_rdy,
  output p2_rdesc_t     rp,
  output logic          rp_busy
);
  localparam int NB = $clog2(PCACHE_N + 1);
  p2_rdesc_t mem [PCACHE_N];
  logic [NB-1:0] n, rptr;
  logic [11:0]   units;

  // the fill
  logic [11:0] u_add, lim;
  logic        fits;
  always_comb begin
    u_add = fill_d.quad ? 12'd8 : 12'd4;
    lim   = (tr_size < 10'd32) ? 12'd32 : {2'b00, tr_size};
    fits  = n != NB'(PCACHE_N) && (!tr || units + u_add < lim);
  end
  always_ff @(posedge clk) begin
    if (rst || reset) begin
      n     <= '0;
      units <= '0;
      ovf   <= 1'b0;
    end else if (fill_en && fill_v && !ovf) begin
      if (fits) begin
        mem[n[NB-2:0]] <= fill_d;
        n              <= n + NB'(1);
        units          <= units + u_add;
      end else
        ovf <= 1'b1;
    end
  end

  // the replay: one descriptor ahead in the read register
  logic take, rd_next;
  assign take    = rp_v && rp_rdy;
  assign rd_next = rp_busy && rptr != n && (!rp_v || take);
  always_ff @(posedge clk) begin
    if (rst) begin
      rp_busy <= 1'b0;
      rp_v    <= 1'b0;
    end else begin
      if (rd_next) begin
        rp   <= mem[rptr[NB-2:0]];
        rptr <= rptr + NB'(1);
        rp_v <= 1'b1;
      end else if (take)
        rp_v <= 1'b0;
      if (rp_busy && rptr == n && (!rp_v || take) && !rd_next)
        rp_busy <= 1'b0;
      if (rp_start) begin
        rp_busy <= 1'b1;
        rptr    <= '0;
        rp_v    <= 1'b0;
      end
    end
  end
endmodule
