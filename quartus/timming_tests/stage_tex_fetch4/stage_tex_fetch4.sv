//
// stage_tex_fetch4 - timing harness for tex_fetch4 (4-corner texel fetch: 4 addresses
// in -> 4 texels out; owns the 2 tex_cache_4p_1c caches + the pre-cache request FIFO
// and prefetch walker).
//
// DDR-backed harness (like stage_tex): the HPS sysmem_lite bridge + one MULTI-
// OUTSTANDING Avalon read master (verbatim discipline from simplex_pvr_top) + the REAL
// peel_core DDR read arbiter (7 clients, order-FIFO beat routing; unused clients tied
// off) mux tex_fetch4's THREE DDR ports (tc, vq, tc prefetch) onto the single DDR read
// channel. An HPS-writable input bank feeds the per-corner byte addresses + offsets +
// shared decode config + the decode payload; texel/out_pl (+ out_valid/in_ready) are
// raw-captured and XOR-folded to `digest`.
//
module stage_tex_fetch4 import tsp_pkg::*; (
    input             reset_req,
    input             cold_req,
    output            core_clk,
    output            core_reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    // decode payload width: tex_unit's FPLW at IDW=11 (16+3+2+1+1+6+8+8+2+1+1+11), so
    // the pre-cache request FIFO's M10K geometry matches the real instantiation.
    localparam integer PLW = 60;

    // ------------------------------------------------------------------
    // HPS DDR3 bridge (sysmem_lite): core clock/reset + one Avalon read port.
    // ------------------------------------------------------------------
    wire clk_100m, reset_100m;
    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

    wire        r1_clk = clk_100m;
    wire [28:0] r1_addr;
    wire  [7:0] r1_burstcnt;
    wire        r1_waitrequest;
    wire [63:0] r1_readdata;
    wire        r1_readdatavalid;
    wire        r1_read;

    sysmem_lite u_sysmem (
        .reset_core_req    (reset_req),
        .reset_out         (reset_100m),
        .clock             (clk_100m),
        .reset_hps_cold_req(cold_req),
        .reset_hps_warm_req(1'b0),
        .ram1_clk          (r1_clk),
        .ram1_address      (r1_addr),
        .ram1_burstcount   (r1_burstcnt),
        .ram1_waitrequest  (r1_waitrequest),
        .ram1_readdata     (r1_readdata),
        .ram1_readdatavalid(r1_readdatavalid),
        .ram1_read         (r1_read),
        .ram1_writedata    (64'd0),
        .ram1_byteenable   (8'hFF),
        .ram1_write        (1'b0),
        .ram2_clk          (clk_100m),
        .ram2_address      (29'd0), .ram2_burstcount(8'd0), .ram2_waitrequest(),
        .ram2_readdata(), .ram2_readdatavalid(), .ram2_read(1'b0),
        .ram2_writedata(64'd0), .ram2_byteenable(8'd0), .ram2_write(1'b0),
        .vbuf_clk          (clk_100m),
        .vbuf_address(28'd0), .vbuf_burstcount(8'd0), .vbuf_waitrequest(),
        .vbuf_readdata(), .vbuf_readdatavalid(), .vbuf_read(1'b0),
        .vbuf_writedata(128'd0), .vbuf_byteenable(16'd0), .vbuf_write(1'b0)
    );

    // ---- DDR read master (Avalon ram1): MULTI-OUTSTANDING, verbatim discipline from
    //      simplex_pvr_top - accepts a new command whenever the bridge takes it and the
    //      outstanding-BEAT budget allows, while earlier bursts still stream back (the
    //      arbiter's order FIFO routes returned beats by issue order, which the Avalon
    //      bridge preserves). ----
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    localparam integer RD_MAX_BEATS = 128;   // outstanding-beat budget (4x8-beat wc)
    reg [9:0]  rd_beats   = 10'd0;  // beats accepted but not yet returned
    reg        rd_flush   = 1'b0;   // bursts orphaned by a reset: swallow their beats
    wire       rd_cap     = ({2'd0, rd_beats} + {4'd0, ddr_req.burst}) <= 12'(RD_MAX_BEATS);
    wire       rd_issue   = ddr_req.rd && !reset_100m && !rd_flush && rd_cap;
    assign r1_read     = rd_issue;
    assign r1_addr     = ddr_req.addr;
    assign r1_burstcnt = ddr_req.burst;
    wire       rd_accept  = rd_issue && !r1_waitrequest;
    wire       rd_beat    = r1_readdatavalid && (rd_beats != 10'd0);
    assign ddr_resp.busy   = r1_waitrequest || !rd_cap || rd_flush || reset_100m;
    assign ddr_resp.dout   = r1_readdata;
    assign ddr_resp.dready = rd_beat && !rd_flush;
    always @(posedge clk_100m) begin
        if (reset_100m && rd_beats != 10'd0) rd_flush <= 1'b1;
        else if (rd_beats == 10'd0)          rd_flush <= 1'b0;
        rd_beats <= rd_beats + (rd_accept ? {2'd0, ddr_req.burst} : 10'd0)
                             - (rd_beat   ? 10'd1                 : 10'd0);
    end

    // ---- REAL peel_core DDR read arbiter (verbatim; only the 3 tex clients live).
    //      7 clients, priority high->low: tc, vq, ts, pr, ol, ra, tc-PREFETCH (client 6
    //      LOWEST so a speculative line never delays a demand fill). MULTI-OUTSTANDING:
    //      up to DDR_OUT bursts in flight; an order FIFO routes returned beats. ----
    ddr_rd_req_t  ra_dreq, ol_dreq, pr_dreq, ts_dreq;
    ddr_rd_resp_t ra_dresp, ol_dresp, pr_dresp, ts_dresp;
    ddr_rd_req_t  tex_dreq;  ddr_rd_resp_t tex_dresp;
    // ---- texel path: ONE client, wired straight to the DDR master ----
    // The texel path used to present 2-3 clients here and this harness carried a private
    // copy of peel_core's arbiter to mux them. tex_fill_engine now does that muxing INSIDE
    // the texel path (which is the point of the change - keep it local, off the long haul
    // to the arbiter), and every other client in this harness is tied off, so the local
    // arbiter was pure overhead and would have misrepresented the logic under test.
    assign ddr_req = tex_dreq;
    assign tex_dresp = ddr_resp;

    // ---- input register bank ----
    //   0..3 : tex_offset[0..3]  (22b each, bytes)
    //   4    : tex_addr[20:0]    (data base, 64-bit-word)
    //   5    : vq_addr[20:0]     (VQ codebook base, 64-bit-word)
    //   6    : { flush[3], in_valid[2], vq[1], tex[0] }
    //   8,9  : in_pl (decode payload; PLW=60 -> {reg9[27:0], reg8})
    localparam integer NREG = 16;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk_100m) begin
        if (reset_100m) for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        else if (wr_en && wr_addr < NREG) in_reg[wr_addr] <= wr_data;
    end
    wire [21:0] tex_offset [0:3];
    genvar gp;
    generate for (gp=0; gp<4; gp=gp+1) begin : unpack
        assign tex_offset[gp] = in_reg[gp][21:0];
    end endgenerate
    wire [20:0] w_texaddr = in_reg[4][20:0];
    wire [20:0] w_vqaddr  = in_reg[5][20:0];
    wire        w_tex     = in_reg[6][0];
    wire        w_vq      = in_reg[6][1];
    wire        w_iv      = in_reg[6][2];
    wire        w_flush   = in_reg[6][3];
    wire [PLW-1:0] w_pl   = { in_reg[9][27:0], in_reg[8] };

    // ---- DUT: tex_fetch4 (rewrite: raw 64-bit words out; owns the pre-cache request
    //      FIFO + prefetch walker; 3 DDR ports) ----
    wire [63:0] texel [0:3];
    wire [PLW-1:0] tex_opl;
    wire        tex_ov, tex_ready;
    tex_fetch4_ob #(.PLW(PLW)) u_dut (
        .clk(clk_100m),.reset(reset_100m),.flush(w_flush),
        .in_valid(w_iv),.tex(w_tex),.vq(w_vq),.in_ready(tex_ready),
        .tex_addr(w_texaddr),.vq_addr(w_vqaddr),.tex_offset(tex_offset),.in_pl(w_pl),
        .out_valid(tex_ov),.texel(texel),.out_pl(tex_opl),
        .ddr_req(tex_dreq),.ddr_resp(tex_dresp));

    // ---- OUTPUT FOLD (no output buffer): tex_fetch4_ob is OUTPUT-BUFFERED (texel/
    //      out_valid come straight off its T2 register), so the harness adds NO capture
    //      register - it XOR-folds the DUT's registered outputs directly into `digest`.
    //      The measured path is the DUT's internal register -> its output pin (the thing
    //      we want to time); the fold into digest is just keep-alive. ----
    always @(posedge clk_100m) begin
        if (reset_100m) digest <= 1'b0;
        else            digest <= ^{ texel[0]^texel[1]^texel[2]^texel[3],
                                     tex_opl, tex_ov, tex_ready };
    end
endmodule
