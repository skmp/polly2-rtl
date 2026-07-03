//
// fifo_pq - synchronous FIFO with a REGISTERED (1-cycle-latency) read, sized to pack
// its payload into one block-RAM word per entry. Used for peel_core's plane FIFO.
//
// Read discipline (matches peel_core's plane FIFO / RS_POP stage): assert `pop` with
// the FIFO non-empty; the head word appears on `rdata` the NEXT cycle, flagged by
// `rvalid`. The caller latches rdata while rvalid is high (it is a registered RAM
// read, so it cannot be consumed the same cycle pop is asserted - the consumer needs
// a 1-cycle "just popped" state). `pop` also advances the head immediately.
//
// Write: assert `push` with `!full` and the payload on `wdata`; stored at the tail.
//
// M10K safety: push and pop never target the same address in the same cycle in the
// intended use (pop only when !empty -> head!=tail; push blocked at full -> when
// head==tail via the caller's full backpressure), so `no_rw_check` is safe. The
// module does NOT internally bypass a same-address read/write - callers must uphold
// that (peel_core's plane FIFO does: out_ready = !full gates the producer).
//
module fifo_pq #(
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

    // read port (registered: rdata/rvalid one cycle after pop)
    input                  pop,
    output reg [WIDTH-1:0] rdata,
    output reg             rvalid,
    output                 empty,
    output     [4:0]       count
);
    (* ramstyle = RAMSTYLE *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW:0] head, tail;                  // one extra bit unused here; ring is [AW-1:0]
    reg [4:0]  cnt;

    assign full  = (cnt == DEPTH);
    assign empty = (cnt == 0);
    assign count = cnt;

    wire do_push = push && !full;
    wire do_pop  = pop  && !empty;

    always @(posedge clk) begin
        if (reset) begin
            head <= 0; tail <= 0; cnt <= 0; rvalid <= 1'b0;
        end else begin
            rvalid <= 1'b0;

            if (do_push) begin
                mem[tail[AW-1:0]] <= wdata;
                tail <= (tail[AW-1:0]==DEPTH-1) ? {(AW+1){1'b0}} : tail + 1'b1;
            end

            if (do_pop) begin
                rdata  <= mem[head[AW-1:0]];   // registered read -> valid next cycle
                rvalid <= 1'b1;
                head   <= (head[AW-1:0]==DEPTH-1) ? {(AW+1){1'b0}} : head + 1'b1;
            end

            cnt <= cnt + (do_push ? 5'd1 : 5'd0) - (do_pop ? 5'd1 : 5'd0);
        end
    end
endmodule
