// TB top: tex_fetch4_ob over the PIPELINED tex_cache_4p_1c (2-cycle lookup, streaming
// prefetch walker). Single DUT checked against a C++ software model computed from the
// same address->word formula the DDR models serve (no RAM: dout is a pure function of
// address, so DUT and model can never disagree about memory contents).
//
// ONE burst DDR channel, MULTI-OUTSTANDING with randomized per-request latency and
// strictly in-order beats - the whole texel path (both caches + the speculative scanner)
// shares it through tex_fill_engine, so demand fills, VQ second trips and speculative
// lines interleave adversarially on the same port. The C++ TB drives pixel sequences
// (locality walks, pure random, direct-mapped ALIAS stress, VQ-heavy, untextured mix,
// mid-run FLUSH, and a back-to-back THROUGHPUT phase) and checks the output stream IN
// ORDER: payload, then the 4 corner words for textured pixels. pf_issues counts total
// bursts so the TB can require the scanner actually fired.
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

    output reg [31:0] pf_issues            // DDR bursts issued on the shared port
);
    localparam integer PLW = 16;

    wire [21:0] off [0:3];
    assign off[0]=in_off0; assign off[1]=in_off1; assign off[2]=in_off2; assign off[3]=in_off3;

    // the ONE DDR channel for the whole texel path
    ddr_rd_req_t  dreq;
    ddr_rd_resp_t dresp;

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
        else if (dreq.rd && !dresp.busy) pf_issues <= pf_issues + 32'd1;
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

    // ---- fill-pairing check: the engine must write the data that BELONGS to the line
    //      it names. Memory is a pure function of address here, so this is exact. ----
    always @(posedge clk) if (!reset) begin
        if (u_dut.u_fill.col_fill_req) begin
            for (int w = 0; w < 4; w++)
                if (u_dut.u_fill.col_fill_data[64*w +: 64] !==
                    vword({u_dut.u_fill.col_fill_line, 2'b00} + 29'(w)))
                    $error("COL fill line %07x word %0d: got %016x want %016x",
                           u_dut.u_fill.col_fill_line, w,
                           u_dut.u_fill.col_fill_data[64*w +: 64],
                           vword({u_dut.u_fill.col_fill_line, 2'b00} + 29'(w)));
        end
        if (u_dut.u_fill.vq_fill_req) begin
            for (int w = 0; w < 4; w++)
                if (u_dut.u_fill.vq_fill_data[64*w +: 64] !==
                    vword({u_dut.u_fill.vq_fill_line, 2'b00} + 29'(w)))
                    $error("VQ fill line %07x word %0d: got %016x want %016x",
                           u_dut.u_fill.vq_fill_line, w,
                           u_dut.u_fill.vq_fill_data[64*w +: 64],
                           vword({u_dut.u_fill.vq_fill_line, 2'b00} + 29'(w)));
        end
    end

    // ---- ONE multi-outstanding burst DDR model: order FIFO, overlapped dead time,
    //      beats strictly in issue order (the property the engine's owner FIFO needs) ----
    localparam integer CQ = 8, CQW = 3;
    reg [19:0]  q_word [0:CQ-1];
    reg [7:0]   q_beats[0:CQ-1];
    reg [7:0]   q_lat  [0:CQ-1];
    reg [CQW:0] qwp, qrp;
    wire        q_empty = (qwp == qrp);
    wire        q_full  = (qwp[CQW] != qrp[CQW]) && (qwp[CQW-1:0] == qrp[CQW-1:0]);
    wire [CQW-1:0] qh   = qrp[CQW-1:0];
    reg [63:0]  d_do; reg d_dv;
    reg [15:0]  lfsr;
    integer     qi;
    assign dresp.busy   = q_full;
    assign dresp.dout   = d_do;
    assign dresp.dready = d_dv;
    wire d_acc  = dreq.rd && !q_full;
    wire d_bt   = !q_empty && (q_lat[qh] == 8'd0);
    wire d_last = d_bt && (q_beats[qh] <= 8'd1);
    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin
            qwp <= '0; qrp <= '0; lfsr <= 16'hACE1;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            if (d_acc) begin
                q_word [qwp[CQW-1:0]] <= dreq.addr[19:0];
                q_beats[qwp[CQW-1:0]] <= dreq.burst;
                q_lat  [qwp[CQW-1:0]] <= 8'd2 + {4'd0, lfsr[3:0]};   // 2..17 to first beat
                qwp <= qwp + 1'b1;
            end
            for (qi = 0; qi < CQ; qi = qi + 1)
                if (q_lat[qi] != 8'd0 && !(d_acc && qi == int'({{(32-CQW){1'b0}}, qwp[CQW-1:0]})))
                    q_lat[qi] <= q_lat[qi] - 8'd1;
            if (d_bt) begin
                d_do   <= vword(q_word[qh]); d_dv <= 1'b1;
                q_word [qh] <= q_word[qh] + 20'd1;
                q_beats[qh] <= q_beats[qh] - 8'd1;
                if (d_last) qrp <= qrp + 1'b1;
            end
        end
    end
endmodule
