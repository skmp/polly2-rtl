//
// object_list_parser - pure list walker. Reads ONLY the object-list region of
// VRAM (never the parameter buffer) and presents ONE OBJECT-LIST ENTRY at a
// time: its type (strip / tri array / quad array) and decoded fields
// (param_offs_in_words, skip, shadow, mask, count). It does NOT iterate strip
// triangles or array elements, chase param_offs_in_words into the parameter
// buffer, decode vertices, or build the ISP_BACKGND_T_type core tag - all of
// that is the consumer's job.
//
// Mirrors refsw RenderObjectList (refsw_lists.cpp) at the level of walking
// entries and following links.
//
// Object-list entry word E (32-bit), bitfields LSB-first:
//   Tstrip  : param_offs=E[20:0] skip=E[23:21] shadow=E[24] mask=E[30:25] is_not_ts=E[31]
//   T/Qarray: param_offs=E[20:0] skip=E[23:21] shadow=E[24] prims=E[28:25] type=E[31:29]
//   Link    : next_ptr_words=E[23:2] end_of_list=E[28] type=E[31:29]
// type 0b111=link, 0b100=tri array, 0b101=quad array. bit31==0 => triangle strip.
//
// MEMORY: DIRECT DDR read port (dreq/dresp, single 64-bit channel via the shared
// arbiter). Reads 8 WORDS AT A TIME: a 256-bit line (8 view-words = 8 physical
// beats, same bank) is fetched as one burst into a 2-line sliding window
// (win0=current, win1=prefetched next).
//
// STREAMING WALK (this revision): the walk is a CURSOR decoding straight out of
// the resident window - no per-word read-request/response round trip. A one-deep
// STAGING register between decode and the present port means the next entry is
// already decoded when the consumer acks, so entries stream at the handshake's
// ceiling of 1 entry / 2 cycles (the consumer's ack is a registered 1-cycle
// pulse) instead of the old ~5-cycle S_RDENT/S_RDENTW/S_CLASS/S_PRESENT loop.
// Links and skipped words consume one decode cycle each, hidden behind present.
//
// Handshake: prim.entry_ready (LEVEL, fields stable while ready && !acked) <->
// ack.entry_done (1-cycle pulse).
//
module object_list_parser import tsp_pkg::*; (
    input                 clk,
    input                 reset,
    input                 start,        // 1-cycle: begin at list_ptr
    input      [26:0]     list_ptr,     // byte address of the object list
    output reg            busy,
    output reg            done,         // 1-cycle: list fully walked

    output prim_out_t      prim,
    input  prim_ack_t       ack,

    // direct DDR3 read port (64-bit beats, via shared arbiter)
    output ddr_rd_req_t    dreq,
    input  ddr_rd_resp_t   dresp
);
    // ============ 8-word (256-bit) line reader: 2-line window + prefetch ============
    // The walk CURSOR (base) selects its word combinationally from whichever window
    // line holds it. A cursor line resident only in win1 is PROMOTED to win0 (keeps
    // the sequential w0+1 prefetch relation meaningful). A cursor line resident in
    // neither is demand-fetched into win0; win0's successor line prefetches into
    // win1 in the background.
    reg  [255:0] win0; reg [21:0] w0_tag; reg w0_v;
    reg  [255:0] win1; reg [21:0] w1_tag; reg w1_v;

    reg  [26:0] base;             // walk cursor: byte addr of the next entry word
    reg         eol_pend;         // end-of-list decoded; drain staging/present
    wire [21:0] c_line = base[26:5];
    wire [2:0]  c_sel  = base[4:2];
    wire        c_in0  = w0_v && (w0_tag == c_line);
    wire        c_in1  = w1_v && (w1_tag == c_line);
    wire        cw_avail = c_in0 || c_in1;
    wire [31:0] cw = c_in0 ? win0[32*c_sel +: 32] : win1[32*c_sel +: 32];
    wire        c_want = busy && !eol_pend;   // the walk wants the cursor's line

    localparam F_IDLE=2'd0, F_MISS=2'd1, F_FILL=2'd2;
    reg [1:0]   fst;
    reg [21:0]  f_line; reg f_is_pf; reg [2:0] f_beat; reg [255:0] f_acc;
    wire        f_bank    = f_line[17];
    wire [19:0] f_wofs_b  = {f_line[16:0], 3'b000};
    wire [28:0] f_base_wd = {9'b0, f_wofs_b};
    wire [31:0] f_half    = f_bank ? dresp.dout[63:32] : dresp.dout[31:0];

    reg        dreq_rd_r; reg [28:0] dreq_addr_r; reg [7:0] dreq_burst_r;
    assign dreq.rd    = dreq_rd_r;
    assign dreq.addr  = dreq_addr_r;
    assign dreq.burst = dreq_burst_r;

    always @(posedge clk) begin
        dreq_rd_r <= 1'b0;

        // promote win1 -> win0 when the cursor has advanced/jumped into win1
        if (c_want && !c_in0 && c_in1) begin
            win0 <= win1; w0_tag <= w1_tag; w0_v <= 1'b1; w1_v <= 1'b0;
        end

        case (fst)
        F_IDLE: begin
            if (c_want && !cw_avail) begin
                f_line <= c_line; f_is_pf <= 1'b0; f_beat <= 3'd0; w1_v <= 1'b0;
                fst <= F_MISS;
            end else if (w0_v && !(w1_v && w1_tag == w0_tag + 22'd1)) begin
                f_line <= w0_tag + 22'd1; f_is_pf <= 1'b1; f_beat <= 3'd0;
                fst <= F_MISS;
            end
        end
        F_MISS: if (!dresp.busy) begin
            dreq_rd_r    <= 1'b1;
            dreq_addr_r  <= {4'b0011, f_base_wd[24:0]};
            dreq_burst_r <= 8'd8;                       // 8 words at a time
            fst          <= F_FILL;
        end
        F_FILL: if (dresp.dready) begin
            f_acc[32*f_beat +: 32] <= f_half;
            if (f_beat == 3'd7) begin
                if (f_is_pf) begin win1 <= { f_half, f_acc[223:0] }; w1_tag <= f_line; w1_v <= 1'b1; end
                else          begin win0 <= { f_half, f_acc[223:0] }; w0_tag <= f_line; w0_v <= 1'b1; end
                fst <= F_IDLE;
            end else f_beat <= f_beat + 3'd1;
        end
        default: fst <= F_IDLE;
        endcase

        if (reset) begin w0_v<=0; w1_v<=0; fst<=F_IDLE; dreq_rd_r<=0; end
    end

    // ---- entry output regs ----
    reg             e_ready_r;
    entry_type_e    e_type_r;
    objlist_entry_t e_fields_r;
    assign prim.entry_ready = e_ready_r;
    assign prim.entry_type  = e_type_r;
    assign prim.entry       = e_fields_r;

    // ============ STREAMING WALK: decode stage -> staging -> present stage ============
    // DECODE consumes one cursor word per cycle whenever staging is free: entries
    // fill staging; links jump the cursor; EOL sets eol_pend; unhandled words skip.
    // PRESENT loads staging whenever it is free (idle, or the cycle the consumer's
    // ack pulse arrives), so with a saturated consumer entries flow every 2 cycles
    // and decode has spare cycles to absorb links/skips without stalling present.
    reg             stg_v;
    entry_type_e    stg_type;
    objlist_entry_t stg_fields;

    always @(posedge clk) begin
        if (reset) begin
            busy<=0; done<=0; e_ready_r<=0; stg_v<=0; eol_pend<=0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    base <= list_ptr; busy <= 1'b1;
                    stg_v <= 1'b0; eol_pend <= 1'b0;
                end
            end else begin
                // ---- decode stage (one word/cycle into free staging) ----
                if (!eol_pend && !stg_v && cw_avail) begin
                    if (cw[31] == 1'b0) begin              // triangle strip
                        stg_type   <= ENT_STRIP;
                        stg_fields <= '{ param_offs_in_words:cw[20:0], skip:cw[23:21],
                            shadow:cw[24], mask:cw[30:25], count:5'd0 };
                        stg_v <= 1'b1;
                        base  <= base + 27'd4;
                    end else begin
                        case (cw[31:29])
                        3'b111: begin                       // link / end-of-list
                            if (cw[28]) eol_pend <= 1'b1;
                            else        base <= {3'b000, cw[23:2], 2'b00};
                        end
                        3'b100, 3'b101: begin               // tri / quad array
                            stg_type   <= (cw[31:29]==3'b101) ? ENT_QUAD : ENT_TRI;
                            stg_fields <= '{ param_offs_in_words:cw[20:0], skip:cw[23:21],
                                shadow:cw[24], mask:6'd0, count:{1'b0,cw[28:25]}+5'd1 };
                            stg_v <= 1'b1;
                            base  <= base + 27'd4;
                        end
                        default: base <= base + 27'd4;      // unhandled: skip & continue
                        endcase
                    end
                end

                // ---- present stage (loads staging when idle or being acked) ----
                if (!e_ready_r || ack.entry_done) begin
                    if (stg_v) begin
                        e_type_r   <= stg_type;
                        e_fields_r <= stg_fields;
                        e_ready_r  <= 1'b1;
                        stg_v      <= 1'b0;
                    end else if (ack.entry_done)
                        e_ready_r <= 1'b0;
                end

                // ---- list end: everything decoded AND presented/acked ----
                if (eol_pend && !stg_v && !e_ready_r) begin
                    busy <= 1'b0; done <= 1'b1; eol_pend <= 1'b0;
                end
            end
        end
    end
endmodule
