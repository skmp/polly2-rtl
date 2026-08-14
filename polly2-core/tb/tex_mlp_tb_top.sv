// TB top: tex_fill_engine + the two caches it serves, driven directly.
//
// tex_fetch4_pl already checks end-to-end texel data through the whole fetch pipe
// (including the fill steal, which its scanner exercises for real). This tb targets the
// properties that one cannot see:
//   * one burst per DISTINCT missing line of a quad, with corner dedup
//   * those bursts CONCURRENT, so an n-line batch costs far less than n round trips
//   * VQ wins ISSUE arbitration over COL, and its slots are RESERVED - a VQ fill is
//     blocking a pixel, so speculative COL traffic must never starve it
//   * the per-queue outstanding caps hold (COL_OUT / VQ_OUT)
//   * the arbiter contract: a client must NEVER re-pulse rd while its previous request
//     sits ungranted in the single pending slot (this model has the same one-deep slot as
//     peel_core's arbiter and $errors on the overwrite - the lost-burst deadlock)
//   * the engine writes the data that BELONGS to the line it names
//
// The DDR model mirrors peel_core's arbiter + sim_ddr_fb: one pending slot, an order
// FIFO, an outstanding cap, dead time counting down for all queued commands (so bursts
// overlap) and beats returned strictly in issue order - the property the engine's owner
// FIFO depends on.
module tex_mlp_tb_top import tsp_pkg::*; #(
    parameter integer RD_LAT      = 8,
    parameter integer TEX_OUT_MAX = 16,     // = peel_core's cap for the texel path
    parameter integer CQ          = 16,     // backend pending-read window
    parameter integer CQW         = $clog2(CQ)
) (
    input             clk,
    input             reset,
    input             flush,

    // ---- data-cache corner ports (the four corners move as a group) ----
    input             q_req,
    input      [28:0] q_a0, q_a1, q_a2, q_a3,
    output            q_ready,
    output            q_ack,
    output     [63:0] q_d0, q_d1, q_d2, q_d3,

    // ---- VQ-cache corner ports ----
    input             v_req,
    input      [28:0] v_a0, v_a1, v_a2, v_a3,
    output            v_ready,
    output            v_ack,

    // ---- speculative scan port (stands in for tex_fetch4_ob's scanner) ----
    input             s_req,
    input      [26:0] s_line,
    output            s_ack,

    // ---- observation ----
    output reg [31:0] n_burst,             // bursts accepted by the channel
    output reg [31:0] n_col, n_vq,         // ...split by owner
    output reg [4:0]  n_out, max_out,      // outstanding now / high-water
                                           // 5 bits: TEX_OUT_MAX is 16, and 4'(16)==0
                                           // makes busy permanently true
    output     [4:0]  col_out, vq_out_o,   // per-queue outstanding
    output reg        vq_won,              // a VQ burst issued while COL also had work
    output reg [31:0] n_err
);
    cache_req_t  creq  [0:3], vreq [0:3];
    cache_resp_t cresp [0:3], vresp[0:3];
    assign creq[0].req=q_req; assign creq[0].waddr=q_a0;
    assign creq[1].req=q_req; assign creq[1].waddr=q_a1;
    assign creq[2].req=q_req; assign creq[2].waddr=q_a2;
    assign creq[3].req=q_req; assign creq[3].waddr=q_a3;
    assign vreq[0].req=v_req; assign vreq[0].waddr=v_a0;
    assign vreq[1].req=v_req; assign vreq[1].waddr=v_a1;
    assign vreq[2].req=v_req; assign vreq[2].waddr=v_a2;
    assign vreq[3].req=v_req; assign vreq[3].waddr=v_a3;
    assign q_ready=cresp[0].ready; assign q_ack=cresp[0].ack;
    assign q_d0=cresp[0].rdata; assign q_d1=cresp[1].rdata;
    assign q_d2=cresp[2].rdata; assign q_d3=cresp[3].rdata;
    assign v_ready=vresp[0].ready; assign v_ack=vresp[0].ack;

    ddr_rd_req_t  dreq;  ddr_rd_resp_t dresp;

    wire         tcm_v, tcm_ack, tcf_req, tcf_gnt, tcd_done;
    wire [26:0]  tcm_line, tcf_line;
    wire [255:0] tcf_data;
    wire         vqm_v, vqm_ack, vqf_req, vqf_gnt, vqd_done;
    wire [26:0]  vqm_line, vqf_line;
    wire [255:0] vqf_data;

    tex_cache_4p_1c u_tc4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(creq),.cresp(cresp),
        .pf_req(1'b0),.pf_waddr({4*29{1'b0}}),.pf_gnt(),.pf_ack(),.pf_hit(),.pf_busy(),
        .miss_v(tcm_v),.miss_line(tcm_line),.miss_ack(tcm_ack),
        .fill_req(tcf_req),.fill_line(tcf_line),.fill_data(tcf_data),
        .fill_gnt(tcf_gnt),.demand_done(tcd_done));
    tex_cache_4p_1c u_vq4 (.clk(clk),.reset(reset),.flush(flush),
        .creq(vreq),.cresp(vresp),
        .pf_req(1'b0),.pf_waddr({4*29{1'b0}}),.pf_gnt(),.pf_ack(),.pf_hit(),.pf_busy(),
        .miss_v(vqm_v),.miss_line(vqm_line),.miss_ack(vqm_ack),
        .fill_req(vqf_req),.fill_line(vqf_line),.fill_data(vqf_data),
        .fill_gnt(vqf_gnt),.demand_done(vqd_done));
    tex_fill_engine u_fill (.clk(clk),.reset(reset),.flush(flush),
        .col_miss_v(tcm_v),.col_miss_line(tcm_line),.col_miss_ack(tcm_ack),
        .scan_v(s_req),.scan_line(s_line),.scan_ack(s_ack),
        .col_fill_req(tcf_req),.col_fill_line(tcf_line),.col_fill_data(tcf_data),
        .col_fill_gnt(tcf_gnt),.col_demand_done(tcd_done),
        .vq_miss_v(vqm_v),.vq_miss_line(vqm_line),.vq_miss_ack(vqm_ack),
        .vq_fill_req(vqf_req),.vq_fill_line(vqf_line),.vq_fill_data(vqf_data),
        .vq_fill_gnt(vqf_gnt),.vq_demand_done(vqd_done),
        .dreq(dreq),.dresp(dresp));

    assign col_out  = 5'(u_fill.cq_out);
    assign vq_out_o = 5'(u_fill.vq_out_n);

    // memory content: pure function of the 64-bit-word address
    function automatic [63:0] vword(input [28:0] w);
        reg [31:0] h;
        begin
            h = 32'(w) * 32'd2654435761;
            vword = 64'hC0FFEE0000000000 | ({35'd0, w} << 16) | {48'd0, h[15:0]};
        end
    endfunction

    // ================= channel: peel_core arbiter + sim_ddr_fb =================
    reg         pend;      reg [28:0] pend_a;  reg [7:0] pend_b;
    reg [28:0]  q_word [0:CQ-1];
    reg [7:0]   q_beats[0:CQ-1];
    reg [7:0]   q_lat  [0:CQ-1];
    reg [CQW:0] qwp, qrp;
    wire        q_empty = (qwp == qrp);
    wire        q_full  = (qwp[CQW] != qrp[CQW]) && (qwp[CQW-1:0] == qrp[CQW-1:0]);
    wire [CQW-1:0] qh   = qrp[CQW-1:0];
    reg [63:0]  d_do; reg d_dv;
    integer     qi;
    assign dresp.busy   = pend || (n_out >= 5'(TEX_OUT_MAX));
    assign dresp.dout   = d_do;
    assign dresp.dready = d_dv;
    wire d_accept = pend && !q_full;
    wire d_bt     = !q_empty && (q_lat[qh] == 8'd0);
    wire d_last   = d_bt && (q_beats[qh] <= 8'd1);

    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin
            pend <= 1'b0; qwp <= '0; qrp <= '0;
            n_burst <= '0; n_col <= '0; n_vq <= '0;
            n_out <= 5'd0; max_out <= 5'd0; n_err <= '0; vq_won <= 1'b0;
        end else begin
            // THE contract: one pending slot per client
            if (dreq.rd && pend && !d_accept) begin
                n_err <= n_err + 32'd1;
                $error("tex_mlp_tb: client overwrote an ungranted request (addr %07x lost)", pend_a);
            end
            if (dreq.rd) begin pend <= 1'b1; pend_a <= dreq.addr; pend_b <= dreq.burst; end
            // ONE assignment for n_out. Incrementing it in the accept branch and
            // decrementing it in the last-beat branch loses the increment whenever both
            // land on the same edge (last-in-block wins) - n_out then underflows and
            // pins busy high forever, which reads exactly like an RTL deadlock.
            n_out <= n_out + (d_accept ? 5'd1 : 5'd0) - (d_last ? 5'd1 : 5'd0);
            // VQ-over-COL: a VQ burst went out while the COL queue also had work to issue
            if (u_fill.iss_vq && (u_fill.cq_ip != u_fill.cq_wp)) vq_won <= 1'b1;
            if (u_fill.iss_vq)  n_vq  <= n_vq + 1;
            if (u_fill.iss_col) n_col <= n_col + 1;
            if (d_accept) begin
                q_word [qwp[CQW-1:0]] <= pend_a;
                q_beats[qwp[CQW-1:0]] <= pend_b;
                q_lat  [qwp[CQW-1:0]] <= 8'(RD_LAT);
                qwp     <= qwp + 1'b1;
                pend    <= dreq.rd;
                n_burst <= n_burst + 32'd1;
                if (n_out + 5'd1 > max_out) max_out <= n_out + 5'd1;
            end
            for (qi = 0; qi < CQ; qi = qi + 1)
                if (q_lat[qi] != 8'd0 && !(d_accept && qi == int'({{(32-CQW){1'b0}}, qwp[CQW-1:0]})))
                    q_lat[qi] <= q_lat[qi] - 8'd1;
            if (d_bt) begin
                d_do   <= vword(q_word[qh]); d_dv <= 1'b1;
                q_word [qh] <= q_word[qh] + 29'd1;
                q_beats[qh] <= q_beats[qh] - 8'd1;
                if (d_last) qrp <= qrp + 1'b1;
            end
        end
    end

    // ---- the engine must write the data that BELONGS to the line it names ----
    always @(posedge clk) if (!reset) begin
        if (tcf_req) for (int w=0; w<4; w++)
            if (tcf_data[64*w +: 64] !== vword({tcf_line, 2'b00} + 29'(w)))
                $error("COL fill line %07x word %0d mispaired: got %016x want %016x",
                       tcf_line, w, tcf_data[64*w +: 64],
                       vword({tcf_line, 2'b00} + 29'(w)));
        if (vqf_req) for (int w=0; w<4; w++)
            if (vqf_data[64*w +: 64] !== vword({vqf_line, 2'b00} + 29'(w)))
                $error("VQ fill line %07x word %0d mispaired: got %016x want %016x",
                       vqf_line, w, vqf_data[64*w +: 64],
                       vword({vqf_line, 2'b00} + 29'(w)));
    end

    // ---- ack-time array consistency: does the cache's OWN storage agree with the word
    //      it just returned? Distinguishes "arrays wrong" (write/engine bug) from
    //      "register stale" (pipeline bug). ----
    always @(posedge clk) if (!reset && q_ack) begin
        for (int pp = 0; pp < 4; pp++) begin
            automatic logic [28:0] aw  = (pp==0 ? q_a0 : pp==1 ? q_a1 : pp==2 ? q_a2 : q_a3);
            automatic logic [26:0] ln  = aw[28:2];
            automatic logic [1:0]  ws  = aw[1:0];
            automatic logic [9:0]  ix  = ln[9:0];
            automatic logic [17:0] mv  = (pp < 2) ? u_tc4.u_meta_a.mem[ix] : u_tc4.u_meta_b.mem[ix];
            automatic logic [255:0] dv = (pp < 2) ? u_tc4.u_data_a.mem[ix] : u_tc4.u_data_b.mem[ix];
            automatic logic [63:0]  got = (pp==0 ? q_d0 : pp==1 ? q_d1 : pp==2 ? q_d2 : q_d3);
            if (got !== vword({ln, ws})) begin
                $display("[cyc %0t] ACKBAD port%0d line=%07x ws=%0d | mem: vld=%b tag=%05x (want tag %05x) word=%016x | got=%016x",
                         $time, pp, ln, ws, mv[17], mv[16:0], ln[26:10],
                         dv[64*ws +: 64], got);
            end
        end
    end

endmodule
