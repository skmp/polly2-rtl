// p2_pxq: the pixel queue (PLAN M10; ARCHITECTURE 3.7.6): a FIFO of run descriptors between run start (p2_tsp_rstart) and
// the pixel pipe's issue (p2_pp_issue). Functionally transparent.
//
// Run start pushes a run when both a run entry (P2_PXQ_RUNS) and the run's len pixel credits (P2_PXQ_PIX) are free; a
// null item takes an entry and no credit. P0 returns the credits as it issues pixels (one a pixel, at its last point),
// and frees the entry when it takes the run. [M tim 3.8 spanahead: a burst of run starts is hidden, ~45-70 runs,
// 180-290 clk; ARCHITECTURE 6: PXQ_PIX 256, PXQ_RUNS 48, fitted in MT2 (I); its place before texturing is GAP T7.]
// The entries are one RAM (P2_PXQ_RUNS words of the descriptor, written at the tail, read at the head; the head word
// is presented from a register: a show-ahead FIFO) [die: region 9's small macros, ARCHITECTURE 3.12].
module p2_pxq
  import p2_pkg::*;
  import p2_tsp_pkg::*;
(
  input  logic          clk,
  input  logic          rst,
  // run start
  input  logic          i_v,
  output logic          i_rdy,
  input  p2_tsp_rdesc_t i_d,
  // the pixel pipe's issue (P0)
  output logic          o_v,
  input  logic          o_rdy,
  output p2_tsp_rdesc_t o_d,
  input  logic          cred_ret,       // a pixel issued: its credit back
  // statistics (reported: MT2 / T7)
  output logic [5:0]    t_runs,
  output logic [8:0]    t_pix
);
  localparam int N  = P2_PXQ_RUNS;
  localparam int AB = $clog2(N);

  p2_tsp_rdesc_t mem [N];
  logic [AB-1:0] wp, rp;
  logic [AB:0]   n;            // entries in the RAM
  logic [8:0]    cred;         // free pixel credits
  logic [5:0]    ilen;
  logic          push, pop, head_v, head_take, ram_pop;

  assign ilen  = i_d.item.null_ ? 6'd0 : 6'(i_d.item.lenm1) + 6'd1;
  // P2_PXQ_RUNS runs in all: the RAM's and the head register's
  assign i_rdy = ((AB+1)'(n) + (AB+1)'(head_v) < (AB+1)'(N)) && cred >= 9'(ilen);
  assign push  = i_v && i_rdy;

  // the head register (show-ahead): filled from the RAM when empty or being taken
  assign o_v       = head_v;
  assign pop       = o_v && o_rdy;
  assign head_take = (!head_v || pop) && n != '0;
  assign ram_pop   = head_take;

  always_ff @(posedge clk) begin
    if (push) mem[wp] <= i_d;
    if (head_take) o_d <= mem[rp];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wp     <= '0;
      rp     <= '0;
      n      <= '0;
      cred   <= 9'(P2_PXQ_PIX);
      head_v <= 1'b0;
    end else begin
      if (push) wp <= (wp == AB'(N - 1)) ? '0 : wp + AB'(1);
      if (ram_pop) rp <= (rp == AB'(N - 1)) ? '0 : rp + AB'(1);
      n <= n + (AB+1)'(push) - (AB+1)'(ram_pop);
      if (head_take) head_v <= 1'b1;
      else if (pop) head_v <= 1'b0;
      cred <= cred - (push ? 9'(ilen) : 9'd0) + (cred_ret ? 9'd1 : 9'd0);
    end
  end

  assign t_runs = 6'(n) + 6'(head_v);
  assign t_pix  = 9'(P2_PXQ_PIX) - cred;
endmodule
