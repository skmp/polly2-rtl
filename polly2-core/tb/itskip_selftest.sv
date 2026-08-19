// itskip_selftest - isp_primitive_iterator_pf PRE-FETCH sort-cache skip.
//
// Instantiates the REAL iterator + the REAL sort_cache (check port cross-wired
// exactly as peel_core does) + a behavioral 64-bit burst DDR, and drives three
// list walks over the same three entries (TRI array x3, STRIP mask=111000,
// QUAD array x1):
//   pass 1 (skip_en=0): all 7 triangles emit; 5 record bursts (baseline).
//   ENTER {array elem1, strip toff1, quad} as "fully rendered".
//   pass 2 (skip_en=1): array elem1's RECORD and the quad's RECORD must be
//     skipped WITHOUT a DDR burst; the strip fetches once but emits only
//     toff 0/2. Expect 4 triangles, 3 bursts, 3 skipped-triangle stats.
//   DEMOTE strip toff1, pass 3: it must render again (5 triangles, 3 bursts).
// Also spot-checks vertex payloads so the (unchanged) fetch alignment is
// covered by the same run. Self-checking; prints ITSKIP SELFTEST: ALL PASS.
module itskip_selftest import tsp_pkg::*; ;
    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;

    // ---- DUT wires ----
    reg              entry_valid;
    entry_type_e     entry_type;
    objlist_entry_t  entry;
    wire             entry_ack, it_busy;
    triangle_out_t   trio;
    triangle_ack_t   ack;
    reg              skip_en;
    wire             chk_valid;  wire [31:0] chk_tag;
    wire             chk_valid_q, chk_done;
    wire             skp_pulse;  wire [2:0] skp_cnt;
    ddr_rd_req_t     dreq;
    ddr_rd_resp_t    dresp;

    isp_primitive_iterator_pf u_it (
        .clk(clk), .reset(reset),
        .param_base(27'd0), .intensity_shadow(1'b0),
        .entry_valid(entry_valid), .entry_type(entry_type), .entry(entry),
        .entry_pt(1'b0), .entry_ack(entry_ack), .busy(it_busy),
        .trio(trio), .ack(ack),
        .skip_en(skip_en),
        .chk_valid(chk_valid), .chk_tag(chk_tag),
        .chk_valid_q(chk_valid_q), .chk_done(chk_done),
        .skp_pulse(skp_pulse), .skp_cnt(skp_cnt),
        .dreq(dreq), .dresp(dresp));

    // ---- sort cache (WAYS=8 as in the 8-lane core) ----
    localparam integer WAYS = 8;
    reg               en_valid; reg [31:0] en_tag;
    reg  [WAYS-1:0]   wr_valid; reg [WAYS*32-1:0] wr_tag;
    wire              sc_ready;
    sort_cache #(.WAYS(WAYS)) u_sort (
        .clk(clk), .reset(reset), .ready(sc_ready),
        .en_valid(en_valid), .en_tag(en_tag),
        .wr_valid(wr_valid), .wr_tag(wr_tag),
        .chk_valid(chk_valid), .chk_tag(chk_tag),
        .chk_valid_q(chk_valid_q), .chk_done(chk_done));

    // ---- behavioral burst DDR (as object_list_parser_tb_top) ----
    localparam integer RD_LAT = 8;
    reg [63:0] vram [0:65535];
    reg busy_r; reg [15:0] word_r; reg [8:0] beats_r; reg [7:0] lat_r;
    reg [63:0] dout_r; reg dready_r;
    integer    n_bursts;                 // record bursts issued (the metric)
    assign dresp.busy = busy_r; assign dresp.dout = dout_r; assign dresp.dready = dready_r;
    always @(posedge clk) begin
        dready_r <= 1'b0;
        if (reset) begin busy_r <= 1'b0; n_bursts <= 0; end
        else if (!busy_r) begin
            if (dreq.rd) begin
                busy_r <= 1'b1; word_r <= dreq.addr[15:0];
                beats_r <= {1'b0, dreq.burst}; lat_r <= RD_LAT[7:0];
                n_bursts <= n_bursts + 1;
            end
        end else if (lat_r != 0) lat_r <= lat_r - 8'd1;
        else begin
            dout_r <= vram[word_r]; dready_r <= 1'b1; word_r <= word_r + 16'd1;
            if (beats_r <= 9'd1) busy_r <= 1'b0;
            beats_r <= beats_r - 9'd1;
        end
    end

    // ---- triangle consumer: ack every presented triangle, record it ----
    integer     n_got;
    reg [31:0]  got_tag [0:31];
    reg [31:0]  got_v0x [0:31];
    always @(posedge clk) begin
        if (reset) begin ack.triangle_done <= 1'b0; n_got <= 0; end
        else begin
            ack.triangle_done <= 1'b0;
            if (trio.triangle_ready && !ack.triangle_done) begin
                got_tag[n_got] <= trio.tag;
                got_v0x[n_got] <= trio.v0.x;
                n_got <= n_got + 1;
                ack.triangle_done <= 1'b1;
            end
        end
    end

    // ---- skipped-triangle stat accumulator ----
    integer n_skipped;
    always @(posedge clk) begin
        if (reset) n_skipped <= 0;
        else if (skp_pulse) n_skipped <= n_skipped + {29'd0, skp_cnt};
    end

    // ================= record layout (skip=1, shadow=0) =================
    // stride = 3+skip = 4 words/vertex, hdr = 3 words (ISP,TSP,TCW).
    localparam [20:0] PO_ARR  = 21'h100;   // TRI array, 3 records of 15 words
    localparam [20:0] PO_STR  = 21'h200;   // STRIP, mask=111000 (tris 0,1,2)
    localparam [20:0] PO_QUAD = 21'h300;   // QUAD array, 1 record of 19 words
    localparam [20:0] ARR_RECW = 21'd15;   // 3 + 3*4

    function automatic [31:0] tagof(input [20:0] po, input [2:0] toff);
        tagof = {1'b0, 2'b00, 1'b0 /*cb*/, 1'b0 /*shadow*/, 3'd1 /*skip*/, po, toff};
    endfunction

    integer i, errors;
    task automatic chk_eq(input [31:0] a, input [31:0] b, input [127:0] what);
        if (a !== b) begin
            errors = errors + 1;
            $display("FAIL %0s: got %08x want %08x", what, a, b);
        end
    endtask

    // present one entry until the iterator consumes it
    task automatic put(input entry_type_e t, input [20:0] po, input [5:0] mask,
                       input [4:0] count);
        begin
            entry            = '{ param_offs_in_words: po, skip: 3'd1,
                                  shadow: 1'b0, mask: mask, count: count };
            entry_type       = t;
            entry_valid      = 1'b1;
            @(posedge clk); while (!entry_ack) @(posedge clk);
            entry_valid      = 1'b0;
        end
    endtask

    task automatic walk_all;   // present the 3 entries, wait for full drain
        begin
            put(ENT_TRI,   PO_ARR,  6'd0,      5'd3);
            put(ENT_STRIP, PO_STR,  6'b111000, 5'd0);
            put(ENT_QUAD,  PO_QUAD, 6'd0,      5'd1);
            @(posedge clk); while (it_busy) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic enter(input [31:0] t);
        begin en_tag = t; en_valid = 1'b1; @(posedge clk); en_valid = 1'b0; @(posedge clk); end
    endtask

    integer base_got, base_bursts;
    initial begin
        errors = 0;
        entry_valid = 0; skip_en = 0; en_valid = 0; wr_valid = '0; wr_tag = '0;
        for (i = 0; i < 65536; i = i + 1) vram[i] = {32'h0, i[31:0]};  // word w = w
        repeat (5) @(posedge clk); reset = 0;
        @(posedge clk); while (!sc_ready) @(posedge clk);

        // ---------- pass 1: no filtering ----------
        walk_all();
        chk_eq(n_got, 7, "pass1 tri count");
        chk_eq(n_bursts, 5, "pass1 burst count");
        chk_eq(got_tag[0], tagof(PO_ARR, 3'd0),              "p1 arr0 tag");
        chk_eq(got_tag[1], tagof(PO_ARR + ARR_RECW, 3'd0),   "p1 arr1 tag");
        chk_eq(got_tag[2], tagof(PO_ARR + 2*ARR_RECW, 3'd0), "p1 arr2 tag");
        chk_eq(got_tag[3], tagof(PO_STR, 3'd0),              "p1 strip0 tag");
        chk_eq(got_tag[4], tagof(PO_STR, 3'd1),              "p1 strip1 tag");
        chk_eq(got_tag[5], tagof(PO_STR, 3'd2),              "p1 strip2 tag");
        chk_eq(got_tag[6], tagof(PO_QUAD, 3'd0),             "p1 quad tag");
        // vertex alignment spot check: arr0 v0.x = word[po+hdr] = po+3
        chk_eq(got_v0x[0], {11'd0, PO_ARR} + 32'd3, "p1 arr0 v0.x");
        chk_eq(got_v0x[3], {11'd0, PO_STR} + 32'd3, "p1 strip v0.x");

        // ---------- mark {arr elem1, strip toff1, quad} fully rendered ----------
        enter(tagof(PO_ARR + ARR_RECW, 3'd0));
        enter(tagof(PO_STR, 3'd1));
        enter(tagof(PO_QUAD, 3'd0));

        // ---------- pass 2: pre-fetch filtering ----------
        base_got = n_got; base_bursts = n_bursts; skip_en = 1;
        walk_all();
        chk_eq(n_got - base_got, 4,       "pass2 tri count");
        chk_eq(n_bursts - base_bursts, 3, "pass2 burst count (2 skipped records)");
        chk_eq(n_skipped, 3,              "pass2 skipped-triangle stat");
        chk_eq(got_tag[base_got+0], tagof(PO_ARR, 3'd0),              "p2 arr0 tag");
        chk_eq(got_tag[base_got+1], tagof(PO_ARR + 2*ARR_RECW, 3'd0), "p2 arr2 tag");
        chk_eq(got_tag[base_got+2], tagof(PO_STR, 3'd0),              "p2 strip0 tag");
        chk_eq(got_tag[base_got+3], tagof(PO_STR, 3'd2),              "p2 strip2 tag");

        // ---------- demote strip toff1 -> it must render again ----------
        wr_tag[31:0] = tagof(PO_STR, 3'd1); wr_valid = 8'h01;
        @(posedge clk); wr_valid = '0; @(posedge clk); @(posedge clk);
        base_got = n_got; base_bursts = n_bursts;
        walk_all();
        chk_eq(n_got - base_got, 5,       "pass3 tri count");
        chk_eq(n_bursts - base_bursts, 3, "pass3 burst count");
        chk_eq(got_tag[base_got+3], tagof(PO_STR, 3'd1), "p3 strip1 back");
        chk_eq(got_tag[base_got+4], tagof(PO_STR, 3'd2), "p3 strip2 tag");

        if (errors == 0) $display("ITSKIP SELFTEST: ALL PASS");
        else begin $display("ITSKIP SELFTEST: %0d FAILURES", errors); $fatal; end
        $finish;
    end

    initial begin #200000; $display("ITSKIP SELFTEST: TIMEOUT"); $fatal; end
endmodule
