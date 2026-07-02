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
// (win0=current, win1=prefetched next). Entries are walked as a sequential
// address stream (base+=4), so a single 8-word burst covers 8 entries and the
// walk streams entry words ~1/cycle; a link jump is a rare cold refill.
//
// Handshake: prim.entry_ready (LEVEL, stable) <-> ack.entry_done (1-cycle pulse).
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
    // rd_go with a byte address (raddr) returns the word NEXT cycle in
    // rword/rword_v on a resident line. Each miss fetches a whole 256-bit line
    // (burst=8) into win0 (demand) or win1 (prefetch of win0+1).
    reg  [26:0] raddr; reg rd_go; reg [31:0] rword; reg rword_v;
    reg  [255:0] win0; reg [21:0] w0_tag; reg w0_v;
    reg  [255:0] win1; reg [21:0] w1_tag; reg w1_v;
    reg          dpend; reg [21:0] dline; reg [2:0] dsel;

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
        rword_v   <= 1'b0;
        dreq_rd_r <= 1'b0;

        if (rd_go) begin dpend <= 1'b1; dline <= raddr[26:5]; dsel <= raddr[4:2]; end

        if (dpend) begin
            if (w0_v && w0_tag == dline) begin
                rword <= win0[32*dsel +: 32]; rword_v <= 1'b1; if (!rd_go) dpend <= 1'b0;
            end else if (w1_v && w1_tag == dline) begin
                win0 <= win1; w0_tag <= w1_tag; w0_v <= 1'b1; w1_v <= 1'b0;
                rword <= win1[32*dsel +: 32]; rword_v <= 1'b1; if (!rd_go) dpend <= 1'b0;
            end
        end

        case (fst)
        F_IDLE: begin
            if (dpend && !(w0_v && w0_tag==dline) && !(w1_v && w1_tag==dline)) begin
                f_line <= dline; f_is_pf <= 1'b0; f_beat <= 3'd0; w1_v <= 1'b0;
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

        if (reset) begin w0_v<=0; w1_v<=0; dpend<=0; fst<=F_IDLE; dreq_rd_r<=0; end
    end

    // ---- entry output regs ----
    reg             e_ready_r;
    entry_type_e    e_type_r;
    objlist_entry_t e_fields_r;
    assign prim.entry_ready = e_ready_r;
    assign prim.entry_type  = e_type_r;
    assign prim.entry       = e_fields_r;

    // ---- walk state ----
    localparam S_IDLE   = 3'd0,
               S_RDENT  = 3'd1,   // issue read of entry word
               S_RDENTW = 3'd2,   // wait entry word
               S_CLASS  = 3'd3,   // classify entry
               S_PRESENT= 3'd4,   // hold entry_ready, wait entry_done
               S_DONE   = 3'd5;
    reg [2:0] st;

    reg [26:0] base;              // current entry byte addr
    reg [31:0] ent;               // current entry word

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; busy<=0; done<=0; rd_go<=0; e_ready_r<=0;
        end else begin
            done<=0; rd_go<=0;

            case (st)
            S_IDLE: if (start) begin base<=list_ptr; busy<=1; st<=S_RDENT; end

            S_RDENT:  begin raddr<=base; rd_go<=1'b1; st<=S_RDENTW; end
            S_RDENTW: if (rword_v) begin ent<=rword; base<=base+27'd4; st<=S_CLASS; end

            S_CLASS: begin
                if (ent[31] == 1'b0) begin            // triangle strip
                    e_type_r   <= ENT_STRIP;
                    e_fields_r <= '{ param_offs_in_words:ent[20:0], skip:ent[23:21],
                        shadow:ent[24], mask:ent[30:25], count:5'd0 };
                    st <= S_PRESENT;
                end else begin
                    case (ent[31:29])
                    3'b111: begin                     // link
                        if (ent[28]) st<=S_DONE;
                        else begin base<={ent[23:2],2'b00}; st<=S_RDENT; end
                    end
                    3'b100, 3'b101: begin              // tri / quad array
                        e_type_r   <= (ent[31:29]==3'b101) ? ENT_QUAD : ENT_TRI;
                        e_fields_r <= '{ param_offs_in_words:ent[20:0], skip:ent[23:21],
                            shadow:ent[24], mask:6'd0, count:{1'b0,ent[28:25]}+5'd1 };
                        st <= S_PRESENT;
                    end
                    default: st<=S_RDENT;              // unhandled: skip & continue
                    endcase
                end
            end

            S_PRESENT: begin
                e_ready_r <= 1'b1;
                if (ack.entry_done) begin
                    e_ready_r <= 1'b0;
                    st <= S_RDENT;
                end
            end

            S_DONE: begin busy<=0; done<=1; st<=S_IDLE; end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
