// TB top: tex_fetch4_ob over the PIPELINED tex_cache_4p_1c (2-cycle lookup, streaming
// prefetch walker). Single DUT checked against a C++ software model computed from the
// same address->word formula the DDR models serve (no RAM: dout is a pure function of
// address, so DUT and model can never disagree about memory contents).
//
// Three independent burst DDR channels (tc, vq, tc-PREFETCH), each with RANDOMIZED
// per-request latency, so demand fills, VQ second trips and speculative prefetch fills
// interleave adversarially. The C++ TB drives pixel sequences (locality walks, pure
// random, direct-mapped ALIAS stress, VQ-heavy, untextured mix, mid-run FLUSH, and a
// back-to-back THROUGHPUT phase) and checks the output stream IN ORDER: payload, then
// the 4 corner words for textured pixels. pf_issues counts prefetch DDR bursts so the
// TB can require the walker actually fired.
module tex_fetch4_pl_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             flush,

    input             in_valid, in_tex, in_vq,
    input      [20:0] in_texaddr, in_vqaddr,
    input      [21:0] in_off0, in_off1, in_off2, in_off3,
    input      [15:0] in_pl,
    output            in_ready,

    output            out_valid,
    output     [63:0] t0, t1, t2, t3,
    output     [15:0] o_pl,

    output reg [31:0] pf_issues            // prefetch DDR bursts issued (walker fired)
);
    localparam integer PLW = 16;

    wire [21:0] off [0:3];
    assign off[0]=in_off0; assign off[1]=in_off1; assign off[2]=in_off2; assign off[3]=in_off3;

    // 3 DDR channels: 0=tc 1=vq 2=tc PREFETCH
    ddr_rd_req_t  dreq [0:2];
    ddr_rd_resp_t dresp[0:2];

    wire [63:0] texel [0:3];
    assign t0=texel[0]; assign t1=texel[1]; assign t2=texel[2]; assign t3=texel[3];

    wire [PLW-1:0] opl_w;
    assign o_pl = opl_w;

    tex_fetch4_ob #(.PLW(PLW)) u_dut (
        .clk(clk),.reset(reset),.flush(flush),
        .in_valid(in_valid),.tex(in_tex),.vq(in_vq),
        .tex_addr(in_texaddr),.vq_addr(in_vqaddr),.tex_offset(off),.in_pl(in_pl),
        .in_ready(in_ready),
        .out_valid(out_valid),.texel(texel),.out_pl(opl_w),
        .ddr_req(dreq),.ddr_resp(dresp));

    always @(posedge clk) begin
        if (reset) pf_issues <= 32'd0;
        else if (dreq[2].rd && !dresp[2].busy) pf_issues <= pf_issues + 32'd1;
    end

    // ---- memory content: pure function of the 20-bit word address (matches the
    //      C++ model's vword() bit for bit; 32-bit wrapping multiply) ----
    function automatic [63:0] vword(input [19:0] w);
        reg [31:0] h;
        begin
            h = 32'(w) * 32'd2654435761;
            vword = 64'hC0FFEE0000000000 | ({44'd0, w} << 16) | {48'd0, h[15:0]};
        end
    endfunction

    // ---- 3 independent burst DDR models, RANDOM per-request latency ----
    genvar gc;
    generate for (gc = 0; gc < 3; gc = gc + 1) begin : ch
        reg        d_busy; reg [19:0] d_word; reg [7:0] d_beats, d_lat;
        reg [63:0] d_do; reg d_dv;
        reg [15:0] lfsr;
        assign dresp[gc].busy   = d_busy;
        assign dresp[gc].dout   = d_do;
        assign dresp[gc].dready = d_dv;
        always @(posedge clk) begin
            d_dv <= 1'b0;
            if (reset) begin
                d_busy <= 1'b0; lfsr <= 16'hACE1 ^ 16'(gc * 32'h1357);
            end else begin
                lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
                if (!d_busy) begin
                    if (dreq[gc].rd) begin
                        d_busy  <= 1'b1;
                        d_word  <= dreq[gc].addr[19:0];
                        d_beats <= dreq[gc].burst;
                        d_lat   <= 8'd2 + {4'd0, lfsr[3:0]};    // 2..17 cycles to first beat
                    end
                end else begin
                    if (d_lat != 8'd0) d_lat <= d_lat - 8'd1;
                    else begin
                        d_dv   <= 1'b1;
                        d_do   <= vword(d_word);
                        d_word <= d_word + 20'd1;
                        if (d_beats == 8'd1) d_busy <= 1'b0;
                        d_beats <= d_beats - 8'd1;
                    end
                end
            end
        end
    end endgenerate
endmodule
