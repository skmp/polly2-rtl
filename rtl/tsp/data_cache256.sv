//
// data_cache256 - direct-mapped read cache with a 32-BYTE (256-bit) line for
// the PVR "32-bit VIEW" of VRAM (ISP/TSP param, region array, object lists).
// Single client, one outstanding miss at a time (the param paths are
// serialized). DDR3 read port INJECTED (dreq/dresp); client port is the 256-bit
// bundle (cache_req256_t/cache_resp256_t).
//
// 32-bit vs 64-bit VIEW (refsw pvr_map32, VRAM_MASK=0x7FFFFF, BANK_BIT=0x400000):
//   VRAM is physically 64-bit words. The texture path reads them whole (64-bit
//   view). The param/TA path uses the "32-bit view", where the two 32-bit
//   halves of each physical 64-bit word are DE-INTERLEAVED into two 4 MB banks:
//   a 32-bit-view word index q = {bank=q[20], wofs=q[19:0]} maps to physical
//   64-bit word `wofs`, taking the LOW 32 bits if bank==0 (q < 0x100000 words
//   = < 4 MB) or the HIGH 32 bits if bank==1 (q >= 0x100000). So consecutive
//   32-bit-view words within one bank are the same-half of consecutive physical
//   64-bit words - NOT contiguous 64-bit reads.
//
//   client: pulse creq.req with creq.laddr (32-BYTE 32-bit-VIEW line address =
//           view_byte_addr>>5) -> cresp.ack + cresp.rdata (256-bit: 8 x 32-bit
//           view words, word w = rdata[32*w +: 32]).
//
// A 256-bit line = 8 consecutive 32-bit-view words = 8 physical 64-bit reads
// (wofs_base+0..7), each contributing ONE 32-bit half (low/high per bank). All
// 8 words in a line share one bank (bank bit = view-word bit 20, far above the
// 3 line-offset bits), so no mid-line bank split. line addr laddr[26:0];
// index=laddr[IXW-1:0], tag=laddr[26:IXW]. Bank/wofs come from the view WORD
// address (laddr<<3): bank=(laddr<<3)[20]=laddr[17], wofs_base=(laddr<<3)[19:0].
//
module data_cache256 import tsp_pkg::*; #(
    parameter integer NLINE = 256           // lines; 256 x 256b = 64 Kb ~= 7 M10K
) (
    input                 clk,
    input                 reset,
    // client port (256-bit line)
    input  cache_req256_t  creq,
    output cache_resp256_t cresp,
    // injected DDR3 read port (64-bit beats)
    output ddr_rd_req_t   dreq,
    input  ddr_rd_resp_t  dresp
);
    localparam integer IXW  = $clog2(NLINE);
    localparam integer TAGW = 27 - IXW;

    (* ramstyle = "M10K" *) reg [255:0] data [0:NLINE-1];
    reg [TAGW-1:0] tags [0:NLINE-1];
    reg            vld  [0:NLINE-1];

    wire [IXW-1:0]  r_ix  = creq.laddr[IXW-1:0];
    wire [TAGW-1:0] r_tag = creq.laddr[26:IXW];

    localparam S_RST=0, S_IDLE=1, S_LOOK=2, S_MISS=3, S_FILL=4;
    reg [2:0] st;
    reg [IXW:0] rst_i;         // reset sweep counter (clears vld[])
    reg [IXW-1:0]  m_ix;
    reg [TAGW-1:0] m_tag;
    reg [26:0]     m_laddr;
    reg [2:0]      beat;        // which of the 8 32-bit words of the line
    reg [255:0]    fill;        // assembled line

    // registered outputs
    reg         ack_r;  reg [255:0] rdata_r;
    reg         rd_r;   reg [28:0]  addr_r; reg [7:0] burst_r;
    assign cresp.ack   = ack_r;
    assign cresp.rdata = rdata_r;
    assign dreq.rd     = rd_r;
    assign dreq.addr   = addr_r;
    assign dreq.burst  = burst_r;

    // 32-bit-VIEW word base of this line = m_laddr<<3 (8 words per 32B line).
    // Physical 64-bit word of view-word (base+beat): wofs = (base+beat)[19:0].
    // Bank = view-word bit 20 = (m_laddr<<3)[20] = m_laddr[17] (line-constant).
    wire        m_bank      = m_laddr[17];
    wire [19:0] wofs_base   = {m_laddr[16:0], 3'b000};   // (m_laddr<<3)[19:0]
    wire [19:0] beat_wofs   = wofs_base + {17'b0, beat};
    wire [28:0] beat_word   = {9'b0, beat_wofs};
    // extract this beat's 32-bit half from the 64-bit read (low=bank0, high=bank1)
    wire [31:0] beat_half   = m_bank ? dresp.dout[63:32] : dresp.dout[31:0];

    always @(posedge clk) begin
        if (reset) begin
            st <= S_RST; ack_r <= 0; rd_r <= 0; beat <= 0; rst_i <= 0;
        end else begin
            ack_r <= 1'b0;
            rd_r  <= 1'b0;
            case (st)
            // sweep vld[] clear after reset (one entry/cycle; M10K-friendly)
            S_RST: begin
                vld[rst_i[IXW-1:0]] <= 1'b0;
                if (rst_i == NLINE-1) st <= S_IDLE;
                else rst_i <= rst_i + 1'b1;
            end
            S_IDLE: if (creq.req) begin
                m_ix    <= r_ix;
                m_tag   <= r_tag;
                m_laddr <= creq.laddr;
                st      <= S_LOOK;
            end
            S_LOOK: begin
                if (vld[m_ix] && tags[m_ix] == m_tag) begin
                    rdata_r <= data[m_ix];
                    ack_r   <= 1'b1;
                    st      <= S_IDLE;
                end else begin
                    beat <= 3'd0;
                    st   <= S_MISS;
                end
            end
            // issue a single 64-bit read for this beat's physical word, wait in FILL
            S_MISS: if (!dresp.busy) begin
                rd_r    <= 1'b1;
                addr_r  <= {4'b0011, beat_word[24:0]};
                burst_r <= 8'd1;
                st      <= S_FILL;
            end
            S_FILL: if (dresp.dready) begin
                // take one 32-bit half (low=bank0 / high=bank1) into slot `beat`
                fill[32*beat +: 32] <= beat_half;
                if (beat == 3'd7) begin
                    // last beat: commit the line (combinational assembly so the
                    // just-arrived half is included)
                    data[m_ix] <= { beat_half, fill[223:0] };
                    tags[m_ix] <= m_tag;
                    vld [m_ix] <= 1'b1;
                    rdata_r    <= { beat_half, fill[223:0] };
                    ack_r      <= 1'b1;
                    st         <= S_IDLE;
                end else begin
                    beat <= beat + 3'd1;
                    st   <= S_MISS;
                end
            end
            endcase
        end
    end
endmodule
