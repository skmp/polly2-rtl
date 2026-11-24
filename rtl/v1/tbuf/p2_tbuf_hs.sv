// p2_tbuf_hs: when p2_tbuf_ctl's pending action may go (PLAN M12, D6; ARCHITECTURE 3.9 "Empty keep-Z collision", GAP T11).
//
//   P2_HS = 0 (default, refsw3-equivalent until T11): every action waits until the write-out is idle: a WRITE's swap
//            must not move the buffer the running write-out reads, and refsw3 finishes each write-out before the next
//            entry (RenderCORE). This is the result the console gives whenever the write-out is idle at SWAP time:
//            every deterministic accbuf cell.
//   P2_HS = 1 the [G] mechanism for the console's collision (accbuf "T end" / "T flush", keepz_races: an empty keep-Z
//            entry ends at once, a neighbour gets the other buffer's picture, two in a row hang): a SWAP does not wait
//            for the write-out, and a WRITE's start is a pulse that is lost when the write-out is busy (`lost`: the
//            swap happens, the write-out does not start). Not gated (MT8, T11).
module p2_tbuf_hs #(
  parameter int P2_HS = 0
) (
  input  logic is_swap,
  input  logic is_write,
  input  logic wo_busy,
  output logic go,
  output logic lost
);
  generate
    if (P2_HS == 0) begin : g_ref
      assign go   = !wo_busy;
      assign lost = 1'b0;
    end else begin : g_lost
      assign go   = is_swap || is_write;
      assign lost = is_write && wo_busy;
    end
  endgenerate
endmodule
