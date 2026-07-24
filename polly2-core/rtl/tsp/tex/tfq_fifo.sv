//
// tfq_fifo - first-word-fall-through FIFO over a registered-read block RAM
// (M10K-compatible), for the tex_fetch4_q decoupling queues.
//
// The RAM read is registered (1-cycle), so a plain ring buffer cannot present
// its head combinationally. Standard fix: a 2-deep OUTPUT BUFFER (ob0 = head,
// ob1 = next) fed by a self-throttled RAM read pipeline. `pending` = entries
// committed to the output side (ob occupancy + one possible in-flight RAM
// read); a new RAM read is issued only while pending (after this cycle's pop)
// stays under 2, so the buffer can never overflow. Sustains 1 push + 1 pop
// per cycle once primed.
//
//   push accepted when !full (caller must not push when full - asserted in sim)
//   ovalid/odata   : the queue head, valid combinationally (FWFT)
//   pop            : consume the head (only when ovalid - asserted in sim)
//   count          : total occupancy (RAM + in-flight + output buffer), for
//                    caller-side credit checks (e.g. the DATQ in-flight guard)
//
// Total capacity is DEPTH (RAM) + 2 (output buffer); `full` throttles on the
// RAM alone, so callers can treat DEPTH as the usable depth.
//
module tfq_fifo #(
    parameter integer W     = 32,
    parameter integer DEPTH = 64,
    parameter integer AW    = $clog2(DEPTH)
) (
    input               clk,
    input               reset,      // also the flush-clear (drops all contents)
    input               push,
    input  [W-1:0]      wdata,
    output              full,
    output              ovalid,
    output [W-1:0]      odata,
    input               pop,
    output [AW+2:0]     count
);
    (* ramstyle = "M10K, no_rw_check" *) reg [W-1:0] ram [0:DEPTH-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0]   ram_cnt;
    reg          rif;               // a RAM read issued last cycle lands in ram_q now
    reg [W-1:0]  ram_q;
    reg [W-1:0]  ob0, ob1;          // output buffer: ob0 = head
    reg [1:0]    ob_cnt;

    assign ovalid = (ob_cnt != 2'd0);
    assign odata  = ob0;
    assign full   = (ram_cnt == (AW+1)'(DEPTH));

    // occupancy committed to the output side; a read is issued only while this
    // (after the current pop) stays < 2, so ob0/ob1 can always take the landing.
    wire       do_pop  = pop && ovalid;
    wire [2:0] pending = {1'b0, ob_cnt} + {2'd0, rif};
    wire       rd_issue = (ram_cnt != '0) && ((pending - {2'd0, do_pop}) < 3'd2);

    assign count = {2'd0, ram_cnt} + {{(AW){1'b0}}, pending};

    always @(posedge clk) begin
        ram_q <= ram[rp];
        if (push) ram[wp] <= wdata;
        if (reset) begin
            wp <= '0; rp <= '0; ram_cnt <= '0; rif <= 1'b0; ob_cnt <= 2'd0;
        end else begin
            if (push)     wp <= wp + 1'b1;
            if (rd_issue) rp <= rp + 1'b1;
            ram_cnt <= ram_cnt + {{AW{1'b0}}, push} - {{AW{1'b0}}, rd_issue};
            rif     <= rd_issue;

            // output-buffer update: a landing read (rif) appends, a pop shifts.
            case ({rif, do_pop})
              2'b01: begin ob0 <= ob1; ob_cnt <= ob_cnt - 2'd1; end
              2'b10: begin
                  if      (ob_cnt == 2'd0) ob0 <= ram_q;
                  else                     ob1 <= ram_q;
                  ob_cnt <= ob_cnt + 2'd1;
              end
              2'b11: begin
                  // head popped + landing appended: net occupancy unchanged.
                  if (ob_cnt == 2'd1) ob0 <= ram_q;
                  else begin ob0 <= ob1; ob1 <= ram_q; end
              end
              default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
        if (push && full)         $error("tfq_fifo %m: push while full");
        if (pop && !ovalid)       $error("tfq_fifo %m: pop while empty");
        if (rif && ob_cnt == 2'd2 && !do_pop)
                                  $error("tfq_fifo %m: output buffer overflow");
    end
`endif
endmodule
