// TB top: tex_fetch4_q (queued/coalescing fetch, DUT) vs tex_fetch4_ob (lockstep,
// GOLDEN) over one shared behavioral VRAM, each with its own pair of burst+latency
// DDR channels (tc + vq, RANDOMIZED per-request latency). The C++ TB drives the
// same pixel sequence into both (independent handshakes/gaps), collects both
// output streams and compares them in order (+ a software model).
module tex_fetch4_q_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             flush,

    // ---- DUT (tex_fetch4_q) ----
    input             q_valid, q_tex, q_vq,
    input      [20:0] q_texaddr, q_vqaddr,
    input      [21:0] q_off0, q_off1, q_off2, q_off3,
    input      [15:0] q_pl,
    output            q_ready, q_ov,
    output     [63:0] q_t0, q_t1, q_t2, q_t3,
    output     [15:0] q_opl,

    // ---- GOLDEN (tex_fetch4_ob) ----
    input             g_valid, g_tex, g_vq,
    input      [20:0] g_texaddr, g_vqaddr,
    input      [21:0] g_off0, g_off1, g_off2, g_off3,
    input      [15:0] g_pl,
    output            g_ready, g_ov,
    output     [63:0] g_t0, g_t1, g_t2, g_t3,
    output     [15:0] g_opl
);
    localparam integer PLW = 16;

    wire [21:0] q_off [0:3];
    assign q_off[0]=q_off0; assign q_off[1]=q_off1; assign q_off[2]=q_off2; assign q_off[3]=q_off3;
    wire [21:0] g_off [0:3];
    assign g_off[0]=g_off0; assign g_off[1]=g_off1; assign g_off[2]=g_off2; assign g_off[3]=g_off3;

    // 4 DDR channels: 0=q.tc 1=q.vq 2=g.tc 3=g.vq
    ddr_rd_req_t  dreq [0:3];
    ddr_rd_resp_t dresp[0:3];

    wire [63:0] q_texel [0:3];
    wire [63:0] g_texel [0:3];
    assign q_t0=q_texel[0]; assign q_t1=q_texel[1]; assign q_t2=q_texel[2]; assign q_t3=q_texel[3];
    assign g_t0=g_texel[0]; assign g_t1=g_texel[1]; assign g_t2=g_texel[2]; assign g_t3=g_texel[3];

    tex_fetch4_q #(.PLW(PLW)) u_dut (
        .clk(clk),.reset(reset),.flush(flush),
        .in_valid(q_valid),.tex(q_tex),.vq(q_vq),
        .tex_addr(q_texaddr),.vq_addr(q_vqaddr),.tex_offset(q_off),.in_pl(q_pl),
        .in_ready(q_ready),
        .out_valid(q_ov),.texel(q_texel),.out_pl(q_opl),
        .ddr_req(dreq[0:1]),.ddr_resp(dresp[0:1]));

    tex_fetch4_ob #(.PLW(PLW)) u_gold (
        .clk(clk),.reset(reset),.flush(flush),
        .in_valid(g_valid),.tex(g_tex),.vq(g_vq),
        .tex_addr(g_texaddr),.vq_addr(g_vqaddr),.tex_offset(g_off),.in_pl(g_pl),
        .in_ready(g_ready),
        .out_valid(g_ov),.texel(g_texel),.out_pl(g_opl),
        .ddr_req(dreq[2:3]),.ddr_resp(dresp[2:3]));

    // ---- shared VRAM + 4 independent burst DDR models, RANDOM per-request latency ----
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];

    genvar gc;
    generate for (gc = 0; gc < 4; gc = gc + 1) begin : ch
        reg        d_busy; reg [19:0] d_word; reg [7:0] d_beats, d_lat;
        reg [63:0] d_do; reg d_dv;
        reg        pend; reg [28:0] pa; reg [7:0] pb;
        reg [15:0] lfsr;
        assign dresp[gc].busy   = d_busy || pend;
        assign dresp[gc].dout   = d_do;
        assign dresp[gc].dready = d_dv;
        always @(posedge clk) begin
            d_dv <= 1'b0;
            if (reset) begin
                d_busy<=1'b0; pend<=1'b0; lfsr <= 16'hACE1 ^ 16'(gc*16'h1357);
            end else begin
                lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
                if (dreq[gc].rd) begin pend<=1'b1; pa<=dreq[gc].addr; pb<=dreq[gc].burst; end
                if (!d_busy) begin
                    if (pend) begin
                        d_busy<=1'b1; d_word<=pa[19:0]; d_beats<=pb;
                        d_lat<={4'd0, lfsr[3:0]} + 8'd2;   // 2..17 cycles
                        pend <= dreq[gc].rd;
                    end
                end else if (d_lat != 0) d_lat <= d_lat - 8'd1;
                else begin
                    d_do<=vram[d_word]; d_dv<=1'b1; d_word<=d_word+20'd1;
                    if (d_beats <= 8'd1) d_busy<=1'b0;
                    d_beats <= d_beats - 8'd1;
                end
            end
        end
    end endgenerate
endmodule
