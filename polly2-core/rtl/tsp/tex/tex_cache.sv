//
// tex_cache - 64-entry x 64-bit direct-mapped read cache over the DDR3 (raw
// 64-bit read port). One outstanding miss at a time (the shade path is 1
// pixel/iter and stalls), which keeps it tiny. The DDR3 read port is INJECTED as
// a bundle pair (dreq/dresp) so the cache is agnostic to who provides memory.
//
//   client: pulse creq.req with creq.waddr (64-bit-WORD addr) -> cresp.ack pulse
//           + cresp.rdata (hit: soon; miss: after the DDR read completes).
//
// index = waddr[5:0], tag = waddr[28:6]. DDR word at 0x30000000
// (dreq.addr is a RAW word address; the arbiter adds the window prefix and the 8 MB mask).
//
module tex_cache import tsp_pkg::*; (
    input                clk,
    input                reset,
    // client port
    input  cache_req_t   creq,
    output cache_resp_t  cresp,
    // injected DDR3 read port
    output ddr_rd_req_t  dreq,
    input  ddr_rd_resp_t dresp
);
    localparam integer NLINE = 64;
    localparam integer IXW   = 6;
    localparam integer TAGW  = 29 - IXW;

    (* ramstyle = "M10K" *) reg [63:0] data [0:NLINE-1];
    reg [TAGW-1:0] tags [0:NLINE-1];
    reg            vld  [0:NLINE-1];

    wire [IXW-1:0]  r_ix  = creq.waddr[IXW-1:0];
    wire [TAGW-1:0] r_tag = creq.waddr[28:IXW];

    localparam S_IDLE=0, S_LOOK=1, S_MISS=2, S_FILL=3;
    reg [1:0] st;
    reg [IXW-1:0]  m_ix;
    reg [TAGW-1:0] m_tag;
    reg [28:0]     m_waddr;

    // registered outputs, driven onto the bundles
    reg        ack_r;   reg [63:0] rdata_r;
    reg        rd_r;    reg [28:0] addr_r; reg [7:0] burst_r;
    assign cresp.ack   = ack_r;
    assign cresp.rdata = rdata_r;
    assign dreq.rd     = rd_r;
    assign dreq.addr   = addr_r;
    assign dreq.burst  = burst_r;

    integer i;
    always @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE; ack_r <= 0; rd_r <= 0;
            for (i=0;i<NLINE;i=i+1) vld[i] <= 1'b0;
        end else begin
            ack_r <= 1'b0;
            rd_r  <= 1'b0;
            case (st)
            S_IDLE: if (creq.req) begin
                m_ix    <= r_ix;
                m_tag   <= r_tag;
                m_waddr <= creq.waddr;
                st      <= S_LOOK;
            end
            S_LOOK: begin
                if (vld[m_ix] && tags[m_ix] == m_tag) begin
                    rdata_r <= data[m_ix];
                    ack_r   <= 1'b1;
                    st      <= S_IDLE;
                end else st <= S_MISS;
            end
            S_MISS: if (!dresp.busy) begin
                rd_r    <= 1'b1;
                addr_r  <= m_waddr;               // raw; the arbiter decorates
                burst_r <= 8'd1;
                st      <= S_FILL;
            end
            S_FILL: if (dresp.dready) begin
                data[m_ix] <= dresp.dout;
                tags[m_ix] <= m_tag;
                vld [m_ix] <= 1'b1;
                rdata_r    <= dresp.dout;
                ack_r      <= 1'b1;
                st         <= S_IDLE;
            end
            endcase
        end
    end
endmodule
