// self-checking test for taginvw_tile_buffer's MULTI-COPY (oversize) mode: the merged
// single-instance buffer that replaced the two ping-pong halves. COPIES independent
// tile images live in ONE simple-dual-port tile_ram, selected by the TOP address bits
// (wr_buf on the write port, rd_buf on the read port).
//
// What it pins down (the things the merge could break):
//   A) COPY ISOLATION      - a write to copy c is visible ONLY in copy c, at the right
//                            bank/address; no aliasing between copies at the same (y,x).
//   B) CONCURRENT W/R      - writing copy A while reading copy B in the SAME cycle (the
//                            whole point of SDP + oversize: the ISP never blocks unless
//                            its write copy IS the spanner's read copy) leaves the read
//                            stream undisturbed and still lands the writes.
//   C) CLEAR isolation     - the CLEAR walk writes only its wr_buf copy.
//   D) PeelBuffers walk    - the pbc valid-clear walk clears only its wr_buf copy.
//   E) 4-wide group select - both halves of an 8-bank chunk read back correctly per copy
//                            (the g_sel_r latch), and the single-pixel shade port
//                            follows rd_buf too.
//
// Parameterized: the Makefile target runs LANES=8/COPIES=4 (the peel_core config),
// LANES=4/COPIES=4 (4-bank chunks: the group IS the chunk) and LANES=8/COPIES=2 (the
// old ping-pong depth, now as two copies of one RAM).
//
module taginvw_copies_selftest import tsp_pkg::*; #(
    parameter integer LANES  = 8,
    parameter integer COPIES = 4
) ;
    localparam integer BW  = $clog2(LANES);
    localparam integer TAW = 10 - BW;                        // in-tile addr width
    localparam integer CBW = (COPIES > 1) ? $clog2(COPIES) : 1;

    // the chunk address of the (y=3, x=8) test chunk: {y[4:0], x[4:BW]}
    localparam [9:0]     TPIX   = {5'd3, 5'd8};
    localparam [TAW-1:0] TCHUNK = TPIX[9:BW];

    reg clk=0; always #5 clk=~clk;
    reg reset;

    reg  [CBW-1:0]      wr_buf, rd_buf;
    reg                 wr_valid;
    reg  [LANES-1:0]    wr_we;
    reg  [4:0]          wr_y, wr_x;
    reg  [31:0]         wr_tag;
    reg  [31*LANES-1:0] wr_invw;
    reg                 wr_pt;
    reg                 clr_valid; reg [TAW-1:0] clr_addr; reg [30:0] clr_depth; reg [31:0] clr_tag;
    reg                 pbc_valid; reg [TAW-1:0] pbc_addr;
    reg                 rdg_valid; reg [9:0] rdg_group;
    reg                 sh_rd_valid; reg [9:0] sh_rd_id;
    wire [3:0]          gg_valid, gg_pt;
    wire [31:0]         gg_tag  [0:3];
    wire [30:0]         gg_invw [0:3];
    wire [3:0]          gg_rs, gg_re;
    wire [tsp_pkg::TI_HASHW-1:0] gg_hash [0:3];
    wire                sh_valid, sh_pt;
    wire [31:0]         sh_tag;
    wire [30:0]         sh_depth;

    taginvw_tile_buffer #(.LANES(LANES), .COPIES(COPIES)) dut (
        .clk(clk), .reset(reset),
        .wr_buf(wr_buf), .rd_buf(rd_buf),
        .wr_valid(wr_valid), .wr_we(wr_we), .wr_y(wr_y), .wr_x(wr_x),
        .wr_tag(wr_tag), .wr_invw(wr_invw), .wr_pt(wr_pt),
        .clr_valid(clr_valid), .clr_addr(clr_addr), .clr_depth(clr_depth), .clr_tag(clr_tag),
        .pbc_valid(pbc_valid), .pbc_addr(pbc_addr),
        .sh_rd_valid(sh_rd_valid), .sh_rd_id(sh_rd_id),
        .sh_valid(sh_valid), .sh_tag(sh_tag), .sh_depth(sh_depth), .sh_pt(sh_pt),
        .rdg_valid(rdg_valid), .rdg_group(rdg_group),
        .gg_valid(gg_valid), .gg_tag(gg_tag), .gg_invw(gg_invw), .gg_pt(gg_pt),
        .gg_rs(gg_rs), .gg_re(gg_re), .gg_hash(gg_hash));

    integer errs = 0;
    integer c, cc, l, k;

    task fail(input string what);
        begin $display("FAIL: %s", what); errs = errs + 1; end
    endtask

    // ---- stimulus helpers -------------------------------------------------------
    // write a whole LANES-wide chunk of copy `cp`: one tag, per-lane invW = iv0+lane.
    task wr_chunk(input integer cp, input [4:0] y, input [4:0] xbase,
                  input [31:0] tag, input [30:0] iv0, input pt);
        begin
            wr_buf   = cp[CBW-1:0];
            wr_valid = 1'b1;
            wr_we    = {LANES{1'b1}};
            wr_y     = y;
            wr_x     = xbase;
            wr_tag   = tag;
            wr_pt    = pt;
            for (k = 0; k < LANES; k = k + 1)
                wr_invw[31*k +: 31] = iv0 + 31'(k);
            @(posedge clk); #1 wr_valid = 1'b0; wr_we = '0;
        end
    endtask

    // present a 4-wide aligned read of copy `cp` at the group holding pixel (y,x);
    // gg_* are valid after the edge (registered read).
    task rd4(input integer cp, input [4:0] y, input [4:0] x);
        begin
            rd_buf    = cp[CBW-1:0];
            rdg_valid = 1'b1;
            rdg_group = {y, x} & ~10'd3;
            @(posedge clk); #1 rdg_valid = 1'b0;
        end
    endtask

    // single-pixel shade read of copy `cp`
    task rd1(input integer cp, input [4:0] y, input [4:0] x);
        begin
            rd_buf      = cp[CBW-1:0];
            sh_rd_valid = 1'b1;
            sh_rd_id    = {y, x};
            @(posedge clk); #1 sh_rd_valid = 1'b0;
        end
    endtask

    // check a just-read group against a chunk written by wr_chunk(tag, iv0):
    // lane l of the group is pixel (gx+l), whose invW is iv0 + (gx+l - xbase).
    task chk_group(input string ctx, input [31:0] tag, input [30:0] iv0,
                   input integer gx_off, input vld, input pt);
        begin
            for (l = 0; l < 4; l = l + 1) begin
                if (gg_valid[l] !== vld)
                    fail($sformatf("%s lane %0d valid %b != %b", ctx, l, gg_valid[l], vld));
                if (vld) begin
                    if (gg_tag[l] !== tag)
                        fail($sformatf("%s lane %0d tag %08x != %08x", ctx, l, gg_tag[l], tag));
                    if (gg_invw[l] !== iv0 + 31'(gx_off + l))
                        fail($sformatf("%s lane %0d invw %0d != %0d", ctx, l,
                                       gg_invw[l], iv0 + 31'(gx_off + l)));
                    if (gg_pt[l] !== pt)
                        fail($sformatf("%s lane %0d pt %b != %b", ctx, l, gg_pt[l], pt));
                end
            end
        end
    endtask

    // per-copy chunk identity used by tests A/B/E
    function automatic [31:0] tag_of(input integer cp);   tag_of  = 32'hC0DE_0000 | (cp << 8); endfunction
    function automatic [30:0] invw_of(input integer cp);  invw_of = 31'd100 * 31'(cp + 1);     endfunction

    initial begin
        reset = 1'b1;
        wr_valid=0; wr_we='0; wr_y=0; wr_x=0; wr_tag=0; wr_invw='0; wr_pt=0;
        clr_valid=0; clr_addr='0; clr_depth='0; clr_tag='0;
        pbc_valid=0; pbc_addr='0;
        rdg_valid=0; rdg_group=0; sh_rd_valid=0; sh_rd_id=0;
        wr_buf='0; rd_buf='0;
        repeat (4) @(posedge clk);
        #1 reset = 1'b0;
        @(posedge clk);

        // ---------------- A) COPY ISOLATION ----------------
        // Every copy gets a DIFFERENT tag/invW at the SAME (y,x) chunk. If the copy
        // index were dropped from the address (or aliased), the last write would win
        // for every copy.
        for (c = 0; c < COPIES; c = c + 1)
            wr_chunk(c, 5'd3, 5'd8, tag_of(c), invw_of(c), c[0]);

        for (c = 0; c < COPIES; c = c + 1) begin
            rd4(c, 5'd3, 5'd8);
            chk_group($sformatf("A copy %0d grp0", c), tag_of(c), invw_of(c), 0, 1'b1, c[0]);
            // E) the OTHER 4-wide group of an 8-bank chunk (g_sel_r half-select)
            if (LANES > 4) begin
                rd4(c, 5'd3, 5'd12);
                chk_group($sformatf("A copy %0d grp1", c), tag_of(c), invw_of(c), 4, 1'b1, c[0]);
            end
            // E) single-pixel shade port follows rd_buf as well
            rd1(c, 5'd3, 5'd9);
            if (sh_tag !== tag_of(c) || sh_depth !== invw_of(c) + 31'd1 || !sh_valid)
                fail($sformatf("A copy %0d sh_rd {%b,%08x,%0d}", c, sh_valid, sh_tag, sh_depth));
        end

        // an untouched address must still read back as "not written" in every copy
        for (c = 0; c < COPIES; c = c + 1) begin
            rd4(c, 5'd7, 5'd8);
            for (l = 0; l < 4; l = l + 1)
                if (gg_tag[l] === tag_of(c))
                    fail($sformatf("A copy %0d: tag leaked to untouched row", c));
        end

        // ---------------- B) CONCURRENT WRITE(A) + READ(B) ----------------
        // Hammer copy 1 with back-to-back writes at the SAME in-tile address the
        // reader is streaming from copy 0. The read stream must be bit-identical to
        // the quiet case, and copy 1 must hold the LAST write.
        if (COPIES > 1) begin
            for (k = 0; k < 8; k = k + 1) begin
                // drive the write and the read in the same cycle
                wr_buf   = CBW'(1);
                wr_valid = 1'b1;
                wr_we    = {LANES{1'b1}};
                wr_y     = 5'd3; wr_x = 5'd8;
                wr_tag   = 32'hBEEF_0000 | k[15:0];
                wr_pt    = 1'b0;
                for (l = 0; l < LANES; l = l + 1)
                    wr_invw[31*l +: 31] = 31'd900 + 31'(k*LANES + l);
                rd_buf    = '0;
                rdg_valid = 1'b1;
                rdg_group = {5'd3, 5'd8} & ~10'd3;
                @(posedge clk); #1;
                wr_valid = 1'b0; wr_we = '0; rdg_valid = 1'b0;
                chk_group($sformatf("B beat %0d", k), tag_of(0), invw_of(0), 0, 1'b1, 1'b0);
            end
            rd4(1, 5'd3, 5'd8);
            chk_group("B copy1 final", 32'hBEEF_0007, 31'd900 + 31'(7*LANES), 0, 1'b1, 1'b0);
            // copy 0 untouched by all that
            rd4(0, 5'd3, 5'd8);
            chk_group("B copy0 after", tag_of(0), invw_of(0), 0, 1'b1, 1'b0);
        end

        // ---------------- C) CLEAR isolation ----------------
        // CLEAR copy (COPIES-1) at the chunk address holding (y=3, x=8..): bg tag +
        // bg depth, valid<-0. Every other copy must survive untouched.
        wr_buf    = CBW'(COPIES-1);
        clr_valid = 1'b1;
        clr_addr  = TCHUNK;
        clr_depth = 31'h7F7F_7F7F;
        clr_tag   = 32'h0BAD_F00D;
        @(posedge clk); #1 clr_valid = 1'b0;

        rd4(COPIES-1, 5'd3, 5'd8);
        for (l = 0; l < 4; l = l + 1) begin
            if (gg_valid[l] !== 1'b0)  fail("C cleared copy: valid should be 0");
            if (gg_tag[l] !== 32'h0BAD_F00D) fail("C cleared copy: bg tag not written");
            if (gg_invw[l] !== 31'h7F7F_7F7F) fail("C cleared copy: bg depth not written");
        end
        for (c = 0; c < COPIES-1; c = c + 1) begin
            rd4(c, 5'd3, 5'd8);
            if (c == 1 && COPIES > 1)
                chk_group("C copy1 survives", 32'hBEEF_0007, 31'd900 + 31'(7*LANES), 0, 1'b1, 1'b0);
            else
                chk_group($sformatf("C copy %0d survives", c), tag_of(c), invw_of(c), 0, 1'b1, c[0]);
        end

        // ---------------- D) PeelBuffers valid-clear walk isolation ----------------
        // Re-arm every copy, then run the pbc write on copy 0 only.
        for (c = 0; c < COPIES; c = c + 1)
            wr_chunk(c, 5'd3, 5'd8, tag_of(c), invw_of(c), 1'b1);

        wr_buf    = '0;
        pbc_valid = 1'b1;
        pbc_addr  = TCHUNK;
        @(posedge clk); #1 pbc_valid = 1'b0;

        rd4(0, 5'd3, 5'd8);
        for (l = 0; l < 4; l = l + 1)
            if (gg_valid[l] !== 1'b0) fail("D pbc copy0: valid should be 0");
        for (c = 1; c < COPIES; c = c + 1) begin
            rd4(c, 5'd3, 5'd8);
            chk_group($sformatf("D copy %0d survives pbc", c), tag_of(c), invw_of(c), 0, 1'b1, 1'b1);
        end

        if (errs == 0)
            $display("taginvw_copies_selftest PASS (LANES=%0d COPIES=%0d)", LANES, COPIES);
        else
            $display("taginvw_copies_selftest FAIL: %0d error(s) (LANES=%0d COPIES=%0d)",
                     errs, LANES, COPIES);
        if (errs != 0) $fatal(1, "taginvw_copies_selftest failed");
        $finish;
    end
endmodule
