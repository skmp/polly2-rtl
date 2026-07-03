//
// fifo_fq - synchronous FIRST-WORD-FALL-THROUGH FIFO. The head entry is always
// presented combinationally on `head_data` with `head_valid`; `pop` consumes it.
// Used for peel_core's triangle FIFO (setup reads the head combinationally).
//
// This lets the payload live in block RAM even though the consumer reads the head
// combinationally (block RAM has no async read): the head is kept in a registered
// output register `head_data`, pre-read one cycle ahead. `pop` IS the advance - it
// consumes head_data and, the same cycle, issues the RAM read of the NEXT head so
// head_data is refreshed next cycle. Back-to-back pops see zero bubble (the 1-cycle
// RAM read latency exactly fills the gap between consecutive heads).
//
// Push-into-the-slot-being-(re)loaded is BYPASSED from wdata, because a no_rw_check
// RAM returns OLD data on a same-address same-cycle read+write; the bypass also makes
// push-into-empty present the new entry on head_data the very next cycle.
//
// With RAMSTYLE="logic" this is a plain register-based FWFT FIFO (the RAM read is
// then a mux, still 1-cycle-registered into head_data - identical behavior).
//
module fifo_fq #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 8,
    parameter integer AW    = 3,           // clog2(DEPTH)
    parameter         RAMSTYLE = "M10K, no_rw_check"
) (
    input                  clk,
    input                  reset,

    // write port
    input                  push,
    input      [WIDTH-1:0] wdata,
    output                 full,

    // read port (FWFT: head presented combinationally, pop to advance)
    input                  pop,
    output     [WIDTH-1:0] head_data,
    output                 head_valid,
    output                 empty,
    output     [4:0]       count
);
    (* ramstyle = RAMSTYLE *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] out_reg;                // registered head (FWFT output register)
    reg             out_valid;
    reg [AW-1:0]    head, tail;
    reg [4:0]       cnt;

    assign full       = (cnt == DEPTH);
    assign empty      = (cnt == 0);
    assign count      = cnt;
    assign head_data  = out_reg;
    assign head_valid = out_valid;

    wire do_push = push && !full;
    wire do_pop  = pop  && out_valid;       // pop consumes the presented head

    // next head after this cycle's pop
    wire [AW-1:0] nh = do_pop ? ((head==DEPTH-1) ? {AW{1'b0}} : head + 1'b1) : head;
    // entries still resident after this cycle's pop (push is folded in via bypass)
    wire [4:0]    avail = cnt - (do_pop ? 5'd1 : 5'd0);
    // does this cycle's push land exactly at the slot we're about to (re)load?
    wire          push_here = do_push && (tail == nh);
    // reload the output register when the current head is consumed or absent
    wire          reload = do_pop || !out_valid;

    always @(posedge clk) begin
        if (reset) begin
            head <= 0; tail <= 0; cnt <= 0; out_valid <= 1'b0;
        end else begin
            if (do_push) begin
                mem[tail] <= wdata;
                tail <= (tail==DEPTH-1) ? {AW{1'b0}} : tail + 1'b1;
            end

            if (do_pop)
                head <= nh;

            if (reload) begin
                if (push_here) begin
                    out_reg   <= wdata;         // bypass: RAM would return stale word
                    out_valid <= 1'b1;
                end else if (avail != 0) begin
                    out_reg   <= mem[nh];       // registered RAM read
                    out_valid <= 1'b1;
                end else begin
                    out_valid <= 1'b0;          // nothing to present next cycle
                end
            end

            cnt <= cnt + (do_push ? 5'd1 : 5'd0) - (do_pop ? 5'd1 : 5'd0);
        end
    end
endmodule
