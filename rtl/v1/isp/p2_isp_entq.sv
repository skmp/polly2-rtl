// p2_isp_entq: p2_entq, the entry records from p2_isp_cut to p2_tbuf (PLAN M7; ARCHITECTURE 2.3 "Entry record"):
// a FIFO of ENT_N [G: 32] p2_entrec_t. The cutter pushes a record when its eoe item is accepted (a full queue stalls
// the cutter at that item); p2_tbuf (here the testbench) pops it when the eoe item reaches it.
module p2_isp_entq
  import p2_pkg::*;
#(
  parameter int ENT_N = 32
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        in_v,
  output logic        in_rdy,
  input  p2_entrec_t  in_d,
  output logic        out_v,
  input  logic        out_rdy,
  output p2_entrec_t  out_d
);
  localparam int AB = $clog2(ENT_N);
  p2_entrec_t      m [ENT_N];
  logic [AB-1:0]   wp, rp;
  logic [AB:0]     n;
  assign in_rdy = n != (AB + 1)'(ENT_N);
  assign out_v  = n != '0;
  assign out_d  = m[rp];
  always_ff @(posedge clk) begin
    if (rst) begin
      wp <= '0;
      rp <= '0;
      n  <= '0;
    end else begin
      if (in_v && in_rdy) begin
        m[wp] <= in_d;
        wp    <= wp + 1'b1;
      end
      if (out_v && out_rdy)
        rp <= rp + 1'b1;
      n <= n + (AB + 1)'(in_v && in_rdy) - (AB + 1)'(out_v && out_rdy);
    end
  end
endmodule
