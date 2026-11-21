// p2_isp_fb: punch-through feedback (PLAN M7; ARCHITECTURE 3.4.9; isp 11.4 "After the TSP has shaded a valid pixel",
// 12.3; refcore refsw_tile.cpp RenderParamTags's punch-through branch at refsw3 4f3efe15; dreamcast-tests
// pvr-tests/ptlayers, ptruns).
//
// The TSP's messages (p2_fb_t, in its pixel order), one a clock:
//   PIXEL ro      a pixel resolved in the pass before, shaded for its run only (keepRes): depthB, tagB = depthA, tagA;
//                 valid = 0
//   PIXEL fail    the alpha test failed: the same, and anyfail (MoreToDraw: the next pass looks below this key)
//   PIXEL pass    rendered = 1, rcur = 1 (resPass = PtPass), resTag = tagA, resDepth = depthA, depthB, tagB = depthA,
//                 tagA; valid = 0
//   PASS_DONE     after the pass's last PIXEL: pass_done with anyfail (the OR of its PIXELs' fail) to p2_isp_ctl
// Two stages: the pixel's depthA / tagA are read on the buffer's F port (fb_re; ctl waits for PASS_DONE, so the raster
// and the sweeps are idle), and written back with the message's effect the clock after. PASS_DONE goes out the clock
// after the last write.
module p2_isp_fb
  import p2_pkg::*;
(
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         fb_v,
  output logic                         fb_rdy,
  input  p2_fb_t                       fb,
  // p2_isp_buf
  output logic                         fb_re,
  output logic [P2_TILE_LOG2-1:0]      fb_row,
  input  p2_zkey_t [P2_TILE-1:0]       f_depth,
  input  logic [P2_TILE-1:0][31:0]     f_tag,
  output logic                         fbw_v,
  output logic [P2_TILE_LOG2-1:0]      fbw_row,
  output logic [P2_TILE-1:0]           fbw_lane,
  output logic                         fbw_pass,
  output p2_zkey_t                     fbw_depth,
  output logic [31:0]                  fbw_tag,
  // p2_isp_ctl
  output logic                         pass_done,
  output logic                         anyfail,
  output logic                         idle
);
  assign fb_rdy = 1'b1;
  assign fb_re  = fb_v && fb.kind == P2_FB_PIXEL;
  assign fb_row = fb.idx[P2_PIX_BITS-1:P2_TILE_LOG2];

  logic                    s_v, s_pass, s_done, s_fail, acc;
  logic [P2_TILE_LOG2-1:0] s_row, s_lane;
  always_ff @(posedge clk) begin
    if (rst) begin
      s_v       <= 1'b0;
      s_done    <= 1'b0;
      acc       <= 1'b0;
      pass_done <= 1'b0;
    end else begin
      s_v       <= fb_re;
      s_done    <= fb_v && fb.kind == P2_FB_PASS_DONE;
      pass_done <= s_done;
      if (s_done) begin
        anyfail <= acc | s_fail;
        acc     <= 1'b0;
      end else if (s_v && s_fail)
        acc <= 1'b1;
    end
    s_row  <= fb.idx[P2_PIX_BITS-1:P2_TILE_LOG2];
    s_lane <= fb.idx[P2_TILE_LOG2-1:0];
    s_pass <= !fb.fail && !fb.ro;
    s_fail <= fb.kind == P2_FB_PIXEL ? fb.fail && !fb.ro : fb.fail;
  end
  assign fbw_v     = s_v;
  assign fbw_row   = s_row;
  assign fbw_lane  = P2_TILE'(1) << s_lane;
  assign fbw_pass  = s_pass;
  assign fbw_depth = f_depth[s_lane];
  assign fbw_tag   = f_tag[s_lane];
  assign idle      = !s_v && !s_done && !pass_done;
endmodule
