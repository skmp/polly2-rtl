// p2_pp_ss: the pixel pipe's P9 SupSample average (PLAN M11; ARCHITECTURE 3.7.7 P9; tsp 18 at refsw3 4f3efe15:
// refsw_tile.cpp PixelFlush_tsp's SupSample block, its last loop). A SupSample pixel's four points come from P8 in the
// order P0 issues them, (hx, hy) = (0, 0), (1, 0), (0, 1), (1, 1) = c4[0 .. 3]; each was shaded, fogged and faded on
// its own. Their colours are averaged per channel, each row's two and then the rows:
//
//   c = (((c0 + c1) >> 1) + ((c2 + c3) >> 1)) >> 1          [supsample, supsample2, ssmip, sscolor: the base and offset
//                                                           colours, the fog and the texels of each point]
// Points 0 - 2 are kept here (c0, then the first row's sum, then c2) and leave nothing; the fourth leaves the pixel,
// with its control (the pixel's last point: its run's last, eop and eoe are on it). Without SupSample (and a null item)
// a point passes through. Combinational out (into p2_pp_blend's P9 register); the keeping registers load when the point
// advances.
module p2_pp_ss
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          stall,
  input  logic          i_v,
  input  p2_pp_pt_t     i_pt,
  input  logic [31:0]   i_col,
  output logic          o_v,
  output p2_pp_pt_t     o_pt,
  output logic [31:0]   o_col
);
  logic        sup;
  logic [1:0]  k;
  logic [31:0] c0, c2;
  logic [3:0][8:0] s01;                  // the first row's sums c0 + c1
  assign sup = i_pt.ctl.super_ && !i_pt.ctl.null_;
  assign k   = {i_pt.ctl.hy, i_pt.ctl.hx};

  logic [31:0] avg;
  always_comb
    for (int ch = 0; ch < 4; ch++) begin
      logic [9:0] s23, s;
      s23 = {2'b0, c2[8 * ch +: 8]} + {2'b0, i_col[8 * ch +: 8]};
      s   = ({1'b0, s01[ch]} >> 1) + (s23 >> 1);
      avg[8 * ch +: 8] = 8'(s >> 1);
    end

  assign o_v   = i_v && (!sup || k == 2'd3);
  assign o_pt  = i_pt;
  assign o_col = sup ? avg : i_col;

  always_ff @(posedge clk)
    if (i_v && !stall && sup)
      case (k)
        2'd0: c0 <= i_col;
        2'd1:
          for (int ch = 0; ch < 4; ch++)
            s01[ch] <= {1'b0, c0[8 * ch +: 8]} + {1'b0, i_col[8 * ch +: 8]};
        2'd2: c2 <= i_col;
        default: ;
      endcase
endmodule
