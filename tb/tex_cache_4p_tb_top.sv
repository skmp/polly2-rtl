// TB top: streaming tex_cache_4p over a behavioral burst+latency DDR (VRAM).
// Exercises back-to-back requests, in-order results, hit/miss/refill, and the
// accept/miss same-cycle hazard. Exposes the 4 ports + vram to C++.
module tex_cache_4p_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input      [3:0]  p_req,          // per-port request strobe
    input      [28:0] p_waddr0,
    input      [28:0] p_waddr1,
    input      [28:0] p_waddr2,
    input      [28:0] p_waddr3,
    output     [3:0]  p_ready,        // per-port accept (backpressure)
    output     [3:0]  p_ack,          // per-port result-valid
    output     [63:0] p_rdata0,
    output     [63:0] p_rdata1,
    output     [63:0] p_rdata2,
    output     [63:0] p_rdata3
);
    cache_req_t  creq [0:3];
    cache_resp_t cresp[0:3];
    assign creq[0].req = p_req[0]; assign creq[0].waddr = p_waddr0;
    assign creq[1].req = p_req[1]; assign creq[1].waddr = p_waddr1;
    assign creq[2].req = p_req[2]; assign creq[2].waddr = p_waddr2;
    assign creq[3].req = p_req[3]; assign creq[3].waddr = p_waddr3;
    assign p_ack    = { cresp[3].ack,   cresp[2].ack,   cresp[1].ack,   cresp[0].ack   };
    assign p_rdata0 = cresp[0].rdata; assign p_rdata1 = cresp[1].rdata;
    assign p_rdata2 = cresp[2].rdata; assign p_rdata3 = cresp[3].rdata;

    assign p_ready = { cresp[3].ready, cresp[2].ready, cresp[1].ready, cresp[0].ready };

    ddr_rd_req_t  dreq;
    ddr_rd_resp_t dresp;
    tex_cache_4p u_c (.clk(clk),.reset(reset),.creq(creq),
                      .cresp(cresp),.dreq(dreq),.dresp(dresp));

    // behavioral burst+latency DDR: rd pulse (latched) -> RD_LAT -> `burst` beats,
    // dout=vram[word++]. Matches frontend_tsp_pp_tb_top's reader contract.
    localparam integer RD_LAT = 8;
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];
    reg        d_busy; reg [19:0] d_word; reg [7:0] d_beats, d_lat;
    reg [63:0] d_do; reg d_dv;
    reg        pend; reg [28:0] pa; reg [7:0] pb;
    assign dresp.busy   = d_busy || pend;
    assign dresp.dout   = d_do;
    assign dresp.dready = d_dv;
    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin d_busy<=1'b0; pend<=1'b0; end
        else begin
            if (dreq.rd) begin pend<=1'b1; pa<=dreq.addr; pb<=dreq.burst; end
            if (!d_busy) begin
                if (pend) begin
                    d_busy<=1'b1; d_word<=pa[19:0]; d_beats<=pb; d_lat<=RD_LAT[7:0];
                    pend <= dreq.rd;   // clear grant unless re-pulsed same cycle
                end
            end else if (d_lat != 0) d_lat <= d_lat - 8'd1;
            else begin
                d_do<=vram[d_word]; d_dv<=1'b1; d_word<=d_word+20'd1;
                if (d_beats <= 8'd1) d_busy<=1'b0;
                d_beats <= d_beats - 8'd1;
            end
        end
    end
endmodule
