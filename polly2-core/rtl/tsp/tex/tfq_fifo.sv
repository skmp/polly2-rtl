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
    parameter integer W      = 32,
    parameter integer DEPTH  = 64,
    parameter integer AW     = $clog2(DEPTH),
    parameter integer LA_MAX = 16      // lookahead window cap (entries past rp)
) (
    input               clk,
    input               reset,      // also the flush-clear (drops all contents)
    input               push,
    input  [W-1:0]      wdata,
    output              full,
    output              ovalid,
    output [W-1:0]      odata,
    input               pop,
    output [AW+2:0]     count,
    // ---- LOOKAHEAD side-read (optional; tie la_adv low when unused) ----
    // A persistent pointer into the RAM-resident tail of the queue: la_data
    // presents the entry AT the pointer; la_adv advances it (so the consumer's
    // next probe RESUMES from where the last one stopped, up to LA_MAX entries
    // past the FWFT read pointer). Shares the ONE RAM read port: refreshes
    // steal cycles the FWFT refill leaves idle - no second port, no shadow RAM.
    // The pointer self-clamps to the read pointer as the head drains.
    input               la_adv,
    output              la_ov,      // la_data holds the entry at the pointer
    output [W-1:0]      la_data
);
    (* ramstyle = "M10K, no_rw_check" *) reg [W-1:0] ram [0:DEPTH-1];
    reg [AW-1:0] wp, rp;
    reg [AW:0]   ram_cnt;
    reg          rif;               // a RAM read issued last cycle lands in ram_q now
    reg [W-1:0]  ram_q;
    reg [W-1:0]  ob0, ob1;          // output buffer: ob0 = head
    reg [1:0]    ob_cnt;
    // lookahead state: absolute (wrap-MSB) mirrors of rp/wp so window tests are
    // plain subtractions; la_a tracks the pointer, la_q/la_qv the settled data.
    reg [AW:0]   rp_a, wp_a, la_a;
    reg [W-1:0]  la_q;
    reg          la_qv;
    reg          la_land;           // an la refresh read lands in ram_q now
    assign la_ov   = la_qv;
    assign la_data = la_q;
    wire [AW:0] la_win  = wp_a - la_a;              // entries at/after the pointer
    wire        la_val  = (la_win != '0);           // pointer names a real entry
    wire        la_want = la_val && !la_qv && !la_land;  // needs a refresh read

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
        // ONE RAM read port: the FWFT refill has priority; a lookahead refresh
        // steals the idle cycles.
        ram_q <= ram[rd_issue ? rp : la_a[AW-1:0]];
        if (push) ram[wp] <= wdata;
        if (reset) begin
            wp <= '0; rp <= '0; ram_cnt <= '0; rif <= 1'b0; ob_cnt <= 2'd0;
            rp_a <= '0; wp_a <= '0; la_a <= '0; la_qv <= 1'b0; la_land <= 1'b0;
        end else begin : body
            reg [AW:0] nla;
            if (push)     begin wp <= wp + 1'b1; wp_a <= wp_a + 1'b1; end
            if (rd_issue) begin rp <= rp + 1'b1; rp_a <= rp_a + 1'b1; end
            ram_cnt <= ram_cnt + {{AW{1'b0}}, push} - {{AW{1'b0}}, rd_issue};
            rif     <= rd_issue;

            // ---- lookahead pointer update ----
            nla = la_a;
            if (la_adv && la_qv && ((la_a - rp_a) < (AW+1)'(LA_MAX)))
                nla = la_a + 1'b1;          // consumer done with this entry
            // self-clamp: never fall behind the FWFT read pointer (those entries
            // are heading into the output buffer / demand path)
            if (((nla - (rp_a + {{AW{1'b0}}, rd_issue})) >> AW) != '0)
                nla = rp_a + {{AW{1'b0}}, rd_issue};
            if (nla != la_a) la_qv <= 1'b0;      // pointer moved: data stale
            else if (la_land) begin              // refresh read landed
                la_q  <= ram_q;
                la_qv <= 1'b1;
            end
            la_a    <= nla;
            la_land <= !rd_issue && la_want;

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
