// TB top: tex_cache_4p_1c's MULTI-OUTSTANDING DEMAND FILL path (MLP) in isolation.
//
// The cache is driven directly (all four corner ports), not through tex_fetch4_ob, so the
// C++ side controls exactly how many DISTINCT lines a bilinear group misses on and can
// time the resulting fill batch. What this tb exists to pin down:
//   * a batch issues ONE burst per distinct missing line, and the corners that share a
//     line are deduped away (iss_mask)
//   * those bursts are actually CONCURRENT (max_out > 1) and a 4-line batch therefore
//     costs far less than 4 serial round trips
//   * data is still correct through aliasing, replay and flush
//   * the arbiter contract is respected: a client must never re-pulse rd while its
//     previous request sits ungranted in the single pending slot (this model has the same
//     one-deep slot as peel_core's arbiter and $errors on the overwrite, which is the
//     deadlock this tb was written after)
//
// BOTH channels MODEL peel_core's arbiter + sim_ddr_fb faithfully - one pending slot, an
// order FIFO, a per-client outstanding cap, RD_LAT dead time that counts down for all
// queued commands (so bursts overlap) and beats returned strictly in issue order. Keep
// TC_OUT_MAX/PF_OUT_MAX/CQ in step with peel_core and sim_ddr_fb: the point of this tb is
// to exercise the configuration that actually ships.
module tex_mlp_tb_top import tsp_pkg::*; #(
    parameter integer RD_LAT     = 8,
    parameter integer TC_OUT_MAX = 4,       // = peel_core TC_OUT_MAX / the cache's FQD
    parameter integer PF_OUT_MAX = 4,       // = peel_core PF_OUT_MAX / the receiver's PFQD
    parameter integer CQ         = 8,       // backend pending-read window (>= both caps)
    parameter integer CQW        = $clog2(CQ)
) (
    input             clk,
    input             reset,
    input             flush,

    // ---- 4 corner ports ----
    input             q_req,                // present all four (they move as a group)
    input      [28:0] q_a0, q_a1, q_a2, q_a3,
    output            q_ready,
    output            q_ack,
    output     [63:0] q_d0, q_d1, q_d2, q_d3,

    // ---- prefetch fill port (to exercise the hitchhike / dedup paths) ----
    input             pfill,
    input      [28:0]  pfaddr,
    output            pfbusy,

    // ---- observation ----
    output reg [31:0] n_burst,              // demand bursts accepted by the channel
    output reg [31:0] n_pburst,             // prefetch bursts accepted
    output reg [3:0]  n_out,                // demand bursts outstanding right now
    output reg [3:0]  max_out,              // high-water of n_out
    output reg [3:0]  n_pout,               // prefetch bursts outstanding right now
    output     [3:0]  pq_occ,               // lines held in the prefetch receiver's ring
    output reg [31:0] n_err                 // protocol violations seen by the model
);
    cache_req_t  creq  [0:3];
    cache_resp_t cresp [0:3];
    assign creq[0].req = q_req; assign creq[0].waddr = q_a0;
    assign creq[1].req = q_req; assign creq[1].waddr = q_a1;
    assign creq[2].req = q_req; assign creq[2].waddr = q_a2;
    assign creq[3].req = q_req; assign creq[3].waddr = q_a3;
    assign q_ready = cresp[0].ready;
    assign q_ack   = cresp[0].ack;
    assign q_d0 = cresp[0].rdata; assign q_d1 = cresp[1].rdata;
    assign q_d2 = cresp[2].rdata; assign q_d3 = cresp[3].rdata;

    ddr_rd_req_t  dreq,  pfreq;
    ddr_rd_resp_t dresp, pfresp;

    tex_cache_4p_1c u_dut (
        .clk(clk),.reset(reset),.flush(flush),
        .creq(creq),.cresp(cresp),
        .pf_req(1'b0),.pf_waddr({4*29{1'b0}}),.pf_gnt(),.pf_ack(),.pf_hit(),.pf_busy(),
        .dreq(dreq),.dresp(dresp),
        .pf_fill(pfill),.pf_faddr(pfaddr),.pf_fbusy(pfbusy),
        .pfreq(pfreq),.pfresp(pfresp));

    // ---- memory content: pure function of the word address (same formula as the
    //      tex_fetch4_pl tb, so the C++ model needs no RAM) ----
    function automatic [63:0] vword(input [28:0] w);
        reg [31:0] h;
        begin
            h = 32'(w) * 32'd2654435761;
            vword = 64'hC0FFEE0000000000 | ({35'd0, w} << 16) | {48'd0, h[15:0]};
        end
    endfunction

    // ================= demand channel: peel_core arbiter + sim_ddr_fb =================
    // one pending slot (like pa/pb per client), an order FIFO of accepted bursts, dead
    // time counting down for ALL queued commands, beats from the head in issue order.
    reg         pend;      reg [28:0] pend_a;  reg [7:0] pend_b;
    reg [28:0]  q_word [0:CQ-1];
    reg [7:0]   q_beats[0:CQ-1];
    reg [7:0]   q_lat  [0:CQ-1];
    reg [CQW:0]    qwp, qrp;
    wire           q_empty = (qwp == qrp);
    wire           q_full  = (qwp[CQW] != qrp[CQW]) && (qwp[CQW-1:0] == qrp[CQW-1:0]);
    wire [CQW-1:0] qh      = qrp[CQW-1:0];
    reg [63:0]  d_do; reg d_dv;
    integer     qi;

    // the cache may present a new request only while its previous one is granted and it
    // is under the outstanding cap - exactly peel_core's tex_dresp[0].busy
    assign dresp.busy   = pend || (n_out >= 4'(TC_OUT_MAX));
    assign dresp.dout   = d_do;
    assign dresp.dready = d_dv;

    wire d_accept = pend && !q_full;
    wire d_beat   = !q_empty && (q_lat[qh] == 8'd0);
    wire d_last   = d_beat && (q_beats[qh] <= 8'd1);

    always @(posedge clk) begin
        d_dv <= 1'b0;
        if (reset) begin
            pend <= 1'b0; qwp <= '0; qrp <= '0;
            n_burst <= 32'd0; n_out <= 4'd0; max_out <= 4'd0; n_err <= 32'd0;
        end else begin
            // THE contract: one pending slot. A second pulse before the grant would lose
            // the first address - the cache must gate on busy (which covers pend).
            if (dreq.rd && pend && !d_accept) begin
                n_err <= n_err + 32'd1;
                $error("tex_mlp_tb: demand client overwrote an ungranted request (addr %07x lost)", pend_a);
            end
            if (dreq.rd) begin pend <= 1'b1; pend_a <= dreq.addr; pend_b <= dreq.burst; end
            if (d_accept) begin
                q_word [qwp[CQW-1:0]] <= pend_a;
                q_beats[qwp[CQW-1:0]] <= pend_b;
                q_lat  [qwp[CQW-1:0]] <= 8'(RD_LAT);
                qwp     <= qwp + 1'b1;
                pend    <= dreq.rd;                 // re-arm if re-pulsed this cycle
                n_burst <= n_burst + 32'd1;
                n_out   <= n_out + 4'd1;
                if (n_out + 4'd1 > max_out) max_out <= n_out + 4'd1;
            end
            for (qi = 0; qi < CQ; qi = qi + 1)
                if (q_lat[qi] != 8'd0 && !(d_accept && qi == int'({{(32-CQW){1'b0}}, qwp[CQW-1:0]})))
                    q_lat[qi] <= q_lat[qi] - 8'd1;
            if (d_beat) begin
                d_do   <= vword(q_word[qh]); d_dv <= 1'b1;
                q_word [qh] <= q_word[qh] + 29'd1;
                q_beats[qh] <= q_beats[qh] - 8'd1;
                if (d_last) begin qrp <= qrp + 1'b1; n_out <= n_out - 4'd1; end
            end
        end
    end

    // ================= prefetch channel: MULTI-outstanding, same shape =================
    // Same one-pending-slot + order-FIFO + cap model as the demand channel (peel_core
    // client 6 with PF_OUT_MAX), deliberately SLOWER per burst than demand so the ring
    // has to hold several lines at once.
    reg         ppend;     reg [28:0] ppend_a; reg [7:0] ppend_b;
    reg [28:0]  p_word [0:CQ-1];
    reg [7:0]   p_beats[0:CQ-1];
    reg [7:0]   p_lat  [0:CQ-1];
    reg [CQW:0]    pwp, prp;
    wire           p_qempty = (pwp == prp);
    wire           p_qfull  = (pwp[CQW] != prp[CQW]) && (pwp[CQW-1:0] == prp[CQW-1:0]);
    wire [CQW-1:0] ph       = prp[CQW-1:0];
    reg [63:0]  p_do;  reg p_dv;
    integer     pqi;
    assign pfresp.busy   = ppend || (n_pout >= 4'(PF_OUT_MAX));
    assign pfresp.dout   = p_do;
    assign pfresp.dready = p_dv;
    wire p_acc_go = ppend && !p_qfull;
    wire p_bt     = !p_qempty && (p_lat[ph] == 8'd0);
    wire p_lastb  = p_bt && (p_beats[ph] <= 8'd1);
    always @(posedge clk) begin
        p_dv <= 1'b0;
        if (reset) begin
            ppend <= 1'b0; pwp <= '0; prp <= '0;
            n_pburst <= 32'd0; n_pout <= 4'd0;
        end else begin
            if (pfreq.rd && ppend && !p_acc_go) begin
                n_err <= n_err + 32'd1;
                $error("tex_mlp_tb: prefetch client overwrote an ungranted request (addr %07x lost)", ppend_a);
            end
            if (pfreq.rd) begin ppend <= 1'b1; ppend_a <= pfreq.addr; ppend_b <= pfreq.burst; end
            if (p_acc_go) begin
                p_word [pwp[CQW-1:0]] <= ppend_a;
                p_beats[pwp[CQW-1:0]] <= ppend_b;
                p_lat  [pwp[CQW-1:0]] <= 8'(RD_LAT) + 8'd6;   // slower than demand on purpose
                pwp      <= pwp + 1'b1;
                ppend    <= pfreq.rd;
                n_pburst <= n_pburst + 32'd1;
                n_pout   <= n_pout + 4'd1;
            end
            for (pqi = 0; pqi < CQ; pqi = pqi + 1)
                if (p_lat[pqi] != 8'd0 && !(p_acc_go && pqi == int'({{(32-CQW){1'b0}}, pwp[CQW-1:0]})))
                    p_lat[pqi] <= p_lat[pqi] - 8'd1;
            if (p_bt) begin
                p_do   <= vword(p_word[ph]); p_dv <= 1'b1;
                p_word [ph] <= p_word[ph] + 29'd1;
                p_beats[ph] <= p_beats[ph] - 8'd1;
                if (p_lastb) begin prp <= prp + 1'b1; n_pout <= n_pout - 4'd1; end
            end
        end
    end

    // ---- ring occupancy, for the tb's depth assertions ----
    // Take the DUT's own occupancy wire: recomputing it here as 4'(wp-rp) evaluated the
    // subtraction at the CAST width, so a 3-bit ring wrap read as 11 instead of 3.
    assign pq_occ = {1'b0, u_dut.pq_occ};
endmodule
