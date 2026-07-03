//
// fifo_eq - small register-based synchronous FIFO with a COMBINATIONAL (zero-latency)
// head. Used for peel_core's object-list entry FIFO, whose consumer (the prefetching
// iterator) reads the head combinationally with no read-latency tolerance.
//
// Unlike fifo_pq (registered read) and fifo_fq (FWFT registered prefetch), the head
// here is a direct combinational mux of the storage array: head_data == mem[head],
// head_valid == !empty. That mux is why this variant is register-only (RAMSTYLE has no
// effect / storage is logic) - block RAM has no async read. It stays cheap because the
// entry FIFO is narrow and shallow.
//
// Write: assert `push` with `!full`, payload on `wdata`, stored at the tail.
// Read : head_data/head_valid track the head every cycle; assert `pop` to advance.
//
module fifo_eq #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 8,
    parameter integer AW    = 3            // clog2(DEPTH)
) (
    input                  clk,
    input                  reset,

    // write port
    input                  push,
    input      [WIDTH-1:0] wdata,
    output                 full,

    // read port (combinational head, zero latency)
    input                  pop,
    output     [WIDTH-1:0] head_data,
    output                 head_valid,
    output                 empty,
    output     [4:0]       count
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0]    head, tail;
    reg [4:0]       cnt;

    assign full       = (cnt == DEPTH);
    assign empty      = (cnt == 0);
    assign count      = cnt;
    assign head_data  = mem[head];          // combinational: zero read latency
    assign head_valid = !empty;

    wire do_push = push && !full;
    wire do_pop  = pop  && !empty;

    always @(posedge clk) begin
        if (reset) begin
            head <= 0; tail <= 0; cnt <= 0;
        end else begin
            if (do_push) begin
                mem[tail] <= wdata;
                tail <= (tail==DEPTH-1) ? {AW{1'b0}} : tail + 1'b1;
            end
            if (do_pop)
                head <= (head==DEPTH-1) ? {AW{1'b0}} : head + 1'b1;

            cnt <= cnt + (do_push ? 5'd1 : 5'd0) - (do_pop ? 5'd1 : 5'd0);
        end
    end
endmodule
