// p2_fp_rom_tb_top: make fp-rom (tb/fp/fp_rom_tb.cpp). The measured-table ROMs of PLAN M1c, each clock: the bump
// mapper's SIN and two COS ports (BumpMapper reads SIN[S], COS[S] and COS[4 x] a pixel: p2_pp_shade's instances) and
// the write-out's dither (p2_wout's). Outputs registered (latency 1, tb/fp/fp_tb.h).
module p2_fp_rom_tb_top (
  input  logic       clk,
  input  logic       in_v,
  input  logic [7:0] sin_i,
  input  logic [7:0] cos_i,
  input  logic [7:0] cos2_i,
  input  logic [1:0] dy,
  input  logic [1:0] dx,
  output logic       out_v,
  output logic [7:0] sin_v,
  output logic [7:0] cos_v,
  output logic [7:0] cos2_v,
  output logic [3:0] dith_v
);
  p2_hw_check u_hw_check ();

  logic [7:0] s, c, c2;
  logic [3:0] d;

  p2_rom_bm_sin u_sin (.i(sin_i), .v(s));
  p2_rom_bm_cos u_cos (.i(cos_i), .v(c));
  p2_rom_bm_cos u_cos2 (.i(cos2_i), .v(c2));
  p2_rom_dither u_dither (.y(dy), .x(dx), .v(d));

  always_ff @(posedge clk) begin
    out_v  <= in_v;
    sin_v  <= s;
    cos_v  <= c;
    cos2_v <= c2;
    dith_v <= d;
  end
endmodule
