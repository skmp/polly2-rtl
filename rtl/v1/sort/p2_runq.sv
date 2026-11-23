// p2_runq: the run queue between p2_isp_cut and p2_sort (PLAN M8; ARCHITECTURE 3.5). A FIFO of RUNQ_N p2_rs_t,
// functionally transparent: refsw3 has no counterpart (tile.cpp hands SpanGen's spans to SpanSort whole), the order
// in is the order out.
//
// Structure: one simple dual-port RAM (a write port, a read port whose data register, held while no read is issued, is
// the queue's output, read show-ahead by p2_sort: an M10K's shape). A word written at clock t is counted at t + 1, read
// then, and at the output at t + 2. RUNQ_N counts every place, the output register's too.
//
// Cycle: [M tim 3.5 ispq] when the ISP ends, ~430-480 runs are left to shade whatever their length; RUNQ_N is one term
// of ARCHITECTURE 3.5's runs_left(L) = RUNQ_N + 96 + SRQ_N + min(PXQ_RUNS, PXQ_PIX / L) + 1 and is fitted once in MT2
// (300 until then [G]). Pass and entry boundaries take no place (flags on the items, ARCHITECTURE 2.3).
module p2_runq
  import p2_pkg::*;
#(
  parameter int RUNQ_N = 300
) (
  input  logic   clk,
  input  logic   rst,
  input  logic   in_v,
  output logic   in_rdy,
  input  p2_rs_t in_d,
  output logic   out_v,
  input  logic   out_rdy,
  output p2_rs_t out_d,
  output logic [$clog2(RUNQ_N + 1)-1:0] occ    // places taken (statistics; MT2's fit reads it)
);
  localparam int AB = $clog2(RUNQ_N);
  localparam int CB = $clog2(RUNQ_N + 1);

  p2_rs_t        mem [RUNQ_N];
  logic [AB-1:0] wp, rp;
  logic [CB-1:0] n_mem;          // words in the RAM, not yet read
  logic          ov;             // the output register holds a word
  p2_rs_t        od;

  // a read is issued when the output register is free next clock and the RAM has a word
  logic take, rd;
  assign take   = ov && out_rdy;
  assign rd     = n_mem != '0 && (!ov || take);
  assign in_rdy = n_mem + CB'(ov) < CB'(RUNQ_N);
  assign out_v  = ov;
  assign out_d  = od;
  assign occ    = n_mem + CB'(ov);

  logic wr;
  assign wr = in_v && in_rdy;

  always_ff @(posedge clk) begin
    if (wr)
      mem[wp] <= in_d;
    if (rd)
      od <= mem[rp];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wp      <= '0;
      rp      <= '0;
      n_mem   <= '0;
      ov      <= 1'b0;
    end else begin
      if (wr)
        wp <= (wp == AB'(RUNQ_N - 1)) ? '0 : wp + 1'b1;
      if (rd)
        rp <= (rp == AB'(RUNQ_N - 1)) ? '0 : rp + 1'b1;
      n_mem   <= n_mem + CB'(wr) - CB'(rd);
      // the read's word is in the output register (od, above) from the next clock
      if (rd)
        ov <= 1'b1;
      else if (take)
        ov <= 1'b0;
    end
  end
endmodule
