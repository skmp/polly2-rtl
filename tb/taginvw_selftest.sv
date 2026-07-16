// self-checking test for taginvw_tile_buffer's 4-wide aligned read (rd4/g4), LANES=4 AND
// LANES=8 (two DUTs).
//
// The raster writes ONE tag per write with a per-lane we mask, so 4 DISTINCT tags in an
// aligned group take 4 writes. This exercises what peel_core's spanner actually needs:
// four independent per-lane tags/invW read back in one rd4. (The earlier uniform-tag test
// hid both the 2-bank aliasing and the stuck-address bugs seen in the render.)
// The LANES=8 DUT additionally exercises the subgroup select (rd4_group[2] picks the low
// or high 4-bank half of the 8-lane chunk, registered alongside the RAM read).
module taginvw_selftest import tsp_pkg::*; ;
    localparam LANES = 4;
    reg clk=0; always #5 clk=~clk;
    reg reset;

    reg               wr_valid;
    reg  [LANES-1:0]  wr_we;
    reg  [4:0]        wr_y, wr_x;
    reg  [31:0]       wr_tag;
    reg  [32*LANES-1:0] wr_invw;
    reg               wr_pt;
    reg               clr_valid; reg [7:0] clr_addr; reg [31:0] clr_depth, clr_tag;
    reg               pbc_valid; reg [7:0] pbc_addr;
    reg               rd4_valid; reg [9:0] rd4_group;
    wire [3:0]        g4_valid, g4_pt;
    wire [31:0]       g4_tag [0:3];
    wire [31:0]       g4_invw [0:3];

    taginvw_tile_buffer #(.LANES(LANES)) dut (
        .clk(clk), .reset(reset),
        .wr_valid(wr_valid), .wr_we(wr_we), .wr_y(wr_y), .wr_x(wr_x),
        .wr_tag(wr_tag), .wr_invw(wr_invw), .wr_pt(wr_pt),
        .clr_valid(clr_valid), .clr_addr(clr_addr), .clr_depth(clr_depth), .clr_tag(clr_tag),
        .pbc_valid(pbc_valid), .pbc_addr(pbc_addr),
        .sh_rd_valid(1'b0), .sh_rd_id(10'd0),
        .sh_valid(), .sh_tag(), .sh_depth(), .sh_pt(),
        .rd4_valid(rd4_valid), .rd4_group(rd4_group),
        .g4_valid(g4_valid), .g4_tag(g4_tag), .g4_invw(g4_invw), .g4_pt(g4_pt));

    // ---- second DUT: LANES=8 (the peel_core configuration). Same 4-wide rd4 port; an
    // aligned group is now half of an 8-lane chunk, selected by rd4_group[2]. ----
    reg               w8_valid;
    reg  [7:0]        w8_we;
    reg  [4:0]        w8_y, w8_x;
    reg  [31:0]       w8_tag;
    reg  [32*8-1:0]   w8_invw;
    reg               r8_valid; reg [9:0] r8_group;
    wire [3:0]        h4_valid, h4_pt;
    wire [31:0]       h4_tag [0:3];
    wire [31:0]       h4_invw [0:3];

    taginvw_tile_buffer #(.LANES(8)) dut8 (
        .clk(clk), .reset(reset),
        .wr_valid(w8_valid), .wr_we(w8_we), .wr_y(w8_y), .wr_x(w8_x),
        .wr_tag(w8_tag), .wr_invw(w8_invw), .wr_pt(1'b0),
        .clr_valid(1'b0), .clr_addr(7'd0), .clr_depth(32'd0), .clr_tag(32'd0),
        .pbc_valid(1'b0), .pbc_addr(7'd0),
        .sh_rd_valid(1'b0), .sh_rd_id(10'd0),
        .sh_valid(), .sh_tag(), .sh_depth(), .sh_pt(),
        .rd4_valid(r8_valid), .rd4_group(r8_group),
        .g4_valid(h4_valid), .g4_tag(h4_tag), .g4_invw(h4_invw), .g4_pt(h4_pt));

    integer errs=0;

    // write ONE lane (single tag, single-lane we mask) at chunk (y, x-aligned).
    // lane = which pixel in the group (0..3); places tag/invw into that bank.
    task wr1(input [4:0] y, input [4:0] xbase, input [1:0] lane,
             input [31:0] tag, input [31:0] invw);
        begin
            wr_valid = 1'b1;
            wr_we    = (4'b0001 << lane);
            wr_y     = y;
            wr_x     = xbase;
            wr_tag   = tag;
            wr_invw  = { invw, invw, invw, invw };   // all banks; only `lane` is enabled
            wr_pt    = 1'b0;
            @(posedge clk); #1 wr_valid = 1'b0; wr_we = '0;
        end
    endtask

    // present a 4-wide read of the group containing pixel (y, xbase); sample NEXT cycle.
    task rd4(input [4:0] y, input [4:0] xbase);
        begin
            rd4_valid = 1'b1;
            rd4_group = {y, xbase} & ~10'd3;   // group base = pixel index & ~3
            @(posedge clk); #1;                // registered read: g4 valid now
        end
    endtask

    task chk_tag(input [1:0] lane, input [31:0] want);
        begin
            if (g4_tag[lane] !== want) begin
                $display("FAIL lane %0d tag %08x != want %08x", lane, g4_tag[lane], want);
                errs=errs+1;
            end
        end
    endtask
    task chk_invw(input [1:0] lane, input [31:0] want);
        begin
            if (g4_invw[lane] !== want) begin
                $display("FAIL lane %0d invw %08x != want %08x", lane, g4_invw[lane], want);
                errs=errs+1;
            end
        end
    endtask

    // ---- LANES=8 DUT helpers ----
    // write ONE lane (0..7) of the 8-wide chunk at (y, x-aligned-to-8).
    task wr1_8(input [4:0] y, input [4:0] xbase, input [2:0] lane,
               input [31:0] tag, input [31:0] invw);
        begin
            w8_valid = 1'b1;
            w8_we    = (8'b0000_0001 << lane);
            w8_y     = y;
            w8_x     = xbase;
            w8_tag   = tag;
            w8_invw  = {8{invw}};                    // all banks; only `lane` is enabled
            @(posedge clk); #1 w8_valid = 1'b0; w8_we = '0;
        end
    endtask

    // present a 4-wide read of the group containing pixel (y, xbase); sample NEXT cycle.
    task rd4_8(input [4:0] y, input [4:0] xbase);
        begin
            r8_valid = 1'b1;
            r8_group = {y, xbase} & ~10'd3;   // group base = pixel index & ~3
            @(posedge clk); #1;               // registered read (+ registered subgroup sel)
        end
    endtask

    task chk8_tag(input [1:0] lane, input [31:0] want);
        begin
            if (h4_tag[lane] !== want) begin
                $display("FAIL(L8) lane %0d tag %08x != want %08x", lane, h4_tag[lane], want);
                errs=errs+1;
            end
        end
    endtask
    task chk8_invw(input [1:0] lane, input [31:0] want);
        begin
            if (h4_invw[lane] !== want) begin
                $display("FAIL(L8) lane %0d invw %08x != want %08x", lane, h4_invw[lane], want);
                errs=errs+1;
            end
        end
    endtask

    initial begin
        reset=1; wr_valid=0; wr_we=0; clr_valid=0; pbc_valid=0; rd4_valid=0;
        wr_y=0; wr_x=0; wr_tag=0; wr_invw=0; wr_pt=0; clr_addr=0; clr_depth=0; clr_tag=0; pbc_addr=0; rd4_group=0;
        w8_valid=0; w8_we=0; w8_y=0; w8_x=0; w8_tag=0; w8_invw=0; r8_valid=0; r8_group=0;
        repeat(3) @(posedge clk); #1 reset=0;

        // ---- group at (y=0, x=0): 4 DISTINCT tags, one per lane ----
        wr1(5'd0, 5'd0, 2'd0, 32'hAAAA0000, 32'h1111_0000);
        wr1(5'd0, 5'd0, 2'd1, 32'hBBBB0001, 32'h2222_0001);
        wr1(5'd0, 5'd0, 2'd2, 32'hCCCC0002, 32'h3333_0002);
        wr1(5'd0, 5'd0, 2'd3, 32'hDDDD0003, 32'h4444_0003);

        // ---- group at (y=0, x=4): 4 more distinct tags (address-decode check) ----
        wr1(5'd0, 5'd4, 2'd0, 32'hE0E00000, 32'h5555_0000);
        wr1(5'd0, 5'd4, 2'd1, 32'hE1E10001, 32'h5555_0001);
        wr1(5'd0, 5'd4, 2'd2, 32'hE2E20002, 32'h5555_0002);
        wr1(5'd0, 5'd4, 2'd3, 32'hE3E30003, 32'h5555_0003);

        // ---- group at (y=3, x=8): non-zero y (y-address-decode check) ----
        wr1(5'd3, 5'd8, 2'd0, 32'h30300000, 32'h6666_0000);
        wr1(5'd3, 5'd8, 2'd1, 32'h31310001, 32'h6666_0001);
        wr1(5'd3, 5'd8, 2'd2, 32'h32320002, 32'h6666_0002);
        wr1(5'd3, 5'd8, 2'd3, 32'h33330003, 32'h6666_0003);

        @(posedge clk);

        // ---- read back group (0,0): expect the 4 distinct tags, one per lane ----
        rd4(5'd0, 5'd0);
        if (g4_valid !== 4'b1111) begin $display("FAIL grp(0,0) g4_valid=%b != 1111", g4_valid); errs=errs+1; end
        chk_tag(0,32'hAAAA0000); chk_tag(1,32'hBBBB0001); chk_tag(2,32'hCCCC0002); chk_tag(3,32'hDDDD0003);
        chk_invw(0,32'h1111_0000); chk_invw(1,32'h2222_0001); chk_invw(2,32'h3333_0002); chk_invw(3,32'h4444_0003);

        // ---- read back group (0,4): must differ from group 0 (address advances) ----
        rd4(5'd0, 5'd4);
        chk_tag(0,32'hE0E00000); chk_tag(1,32'hE1E10001); chk_tag(2,32'hE2E20002); chk_tag(3,32'hE3E30003);

        // ---- read back group (3,8): non-zero y ----
        rd4(5'd3, 5'd8);
        chk_tag(0,32'h30300000); chk_tag(1,32'h31310001); chk_tag(2,32'h32320002); chk_tag(3,32'h33330003);

        // ---- STREAMING read: change rd4_group EVERY cycle (as the spanner does). The read
        // is 1-cycle registered (rdata<=mem[ra]): g4 THIS cycle = data for the group presented
        // LAST cycle. Present g0,g4,g8 on consecutive edges; the g4 outputs lag by one, so we
        // check them one cycle behind. Catches a stuck/held read (data not tracking address).
        // Registered read = rdata<=mem[ra] with ra combinational off rd4_group. So the
        // output valid AFTER an edge reflects the rd4_group that was stable BEFORE that edge.
        // Model the spanner: drive rd4_group, tick, THEN the data is valid (sample after tick).
        rd4_valid = 1'b1;
        rd4_group = 10'd0;  @(posedge clk); #1;   // data for g0 now valid
        if (g4_tag[0]!==32'hAAAA0000) begin $display("FAIL stream g0 lane0=%08x != AAAA0000", g4_tag[0]); errs=errs+1; end
        rd4_group = 10'd4;  @(posedge clk); #1;   // data for g4 now valid
        if (g4_tag[0]!==32'hE0E00000) begin $display("FAIL stream g4 lane0=%08x != E0E00000", g4_tag[0]); errs=errs+1; end
        rd4_group = 10'd8;  @(posedge clk); #1;   // data for g8 (empty)
        if (g4_valid!==4'b0000) begin $display("FAIL stream g8 valid=%b != 0000", g4_valid); errs=errs+1; end
        rd4_group = 10'd0;  @(posedge clk); #1;   // back to g0
        if (g4_tag[2]!==32'hCCCC0002) begin $display("FAIL stream g0-return lane2=%08x != CCCC0002", g4_tag[2]); errs=errs+1; end

        // ---- CONCURRENT write+read to DIFFERENT groups in the same cycle (peel_core does
        // this: ISP stage-B writes producer half while spanner reads consumer half; here one
        // instance, but exercises the shared raddr/waddr paths co-asserted). ----
        rd4_group = 10'd0; rd4_valid = 1'b1;
        wr_valid = 1'b1; wr_we = 4'b0001; wr_y = 5'd10; wr_x = 5'd12; wr_tag = 32'h99990000;
        wr_invw = {4{32'h7777_0000}}; wr_pt = 1'b0;
        @(posedge clk); #1;                        // read g0 while writing (10,12) lane0
        wr_valid = 1'b0; wr_we = '0;
        if (g4_tag[0]!==32'hAAAA0000) begin $display("FAIL concurrent r/w: g0 lane0=%08x != AAAA0000", g4_tag[0]); errs=errs+1; end

        rd4_valid=0;

        // ==================== LANES=8 DUT ====================
        // one 8-wide chunk at (y=0, x=0): 8 DISTINCT tags, one per lane. Groups 0 (low
        // half, rd4_group[2]=0) and 4 (HIGH half, rd4_group[2]=1) read from the SAME
        // chunk address; only the subgroup select differs.
        wr1_8(5'd0, 5'd0, 3'd0, 32'hA0A00000, 32'h1111_1000);
        wr1_8(5'd0, 5'd0, 3'd1, 32'hA1A10001, 32'h1111_1001);
        wr1_8(5'd0, 5'd0, 3'd2, 32'hA2A20002, 32'h1111_1002);
        wr1_8(5'd0, 5'd0, 3'd3, 32'hA3A30003, 32'h1111_1003);
        wr1_8(5'd0, 5'd0, 3'd4, 32'hA4A40004, 32'h1111_1004);
        wr1_8(5'd0, 5'd0, 3'd5, 32'hA5A50005, 32'h1111_1005);
        wr1_8(5'd0, 5'd0, 3'd6, 32'hA6A60006, 32'h1111_1006);
        wr1_8(5'd0, 5'd0, 3'd7, 32'hA7A70007, 32'h1111_1007);

        // second chunk at (y=3, x=8..15): high-half group only (address-decode check)
        wr1_8(5'd3, 5'd8, 3'd4, 32'hB4B40004, 32'h2222_2004);
        wr1_8(5'd3, 5'd8, 3'd5, 32'hB5B50005, 32'h2222_2005);
        wr1_8(5'd3, 5'd8, 3'd6, 32'hB6B60006, 32'h2222_2006);
        wr1_8(5'd3, 5'd8, 3'd7, 32'hB7B70007, 32'h2222_2007);

        @(posedge clk);

        // low half of chunk 0: lanes 0..3
        rd4_8(5'd0, 5'd0);
        if (h4_valid !== 4'b1111) begin $display("FAIL(L8) grp(0,0) valid=%b != 1111", h4_valid); errs=errs+1; end
        chk8_tag(0,32'hA0A00000); chk8_tag(1,32'hA1A10001); chk8_tag(2,32'hA2A20002); chk8_tag(3,32'hA3A30003);
        chk8_invw(0,32'h1111_1000); chk8_invw(3,32'h1111_1003);

        // HIGH half of the SAME chunk: lanes 4..7 (the subgroup-select path)
        rd4_8(5'd0, 5'd4);
        if (h4_valid !== 4'b1111) begin $display("FAIL(L8) grp(0,4) valid=%b != 1111", h4_valid); errs=errs+1; end
        chk8_tag(0,32'hA4A40004); chk8_tag(1,32'hA5A50005); chk8_tag(2,32'hA6A60006); chk8_tag(3,32'hA7A70007);
        chk8_invw(0,32'h1111_1004); chk8_invw(3,32'h1111_1007);

        // high half of chunk (3, 8..15): non-zero y + non-zero chunk addr
        rd4_8(5'd3, 5'd12);
        chk8_tag(0,32'hB4B40004); chk8_tag(1,32'hB5B50005); chk8_tag(2,32'hB6B60006); chk8_tag(3,32'hB7B70007);
        // its LOW half was never written -> invalid
        rd4_8(5'd3, 5'd8);
        if (h4_valid !== 4'b0000) begin $display("FAIL(L8) grp(3,8) valid=%b != 0000", h4_valid); errs=errs+1; end

        // STREAMING read alternating LOW/HIGH halves every cycle (as the spanner walks a
        // scanline): the registered subgroup select must track the registered RAM read.
        r8_valid = 1'b1;
        r8_group = 10'd0;  @(posedge clk); #1;   // g0 (low)  valid now
        if (h4_tag[0]!==32'hA0A00000) begin $display("FAIL(L8) stream g0 lane0=%08x != A0A00000", h4_tag[0]); errs=errs+1; end
        r8_group = 10'd4;  @(posedge clk); #1;   // g4 (HIGH, same chunk) valid now
        if (h4_tag[0]!==32'hA4A40004) begin $display("FAIL(L8) stream g4 lane0=%08x != A4A40004", h4_tag[0]); errs=errs+1; end
        r8_group = {5'd3, 5'd12}; @(posedge clk); #1;   // high half, other chunk
        if (h4_tag[3]!==32'hB7B70007) begin $display("FAIL(L8) stream g(3,12) lane3=%08x != B7B70007", h4_tag[3]); errs=errs+1; end
        r8_group = 10'd0;  @(posedge clk); #1;   // back to g0 (low)
        if (h4_tag[2]!==32'hA2A20002) begin $display("FAIL(L8) stream g0-return lane2=%08x != A2A20002", h4_tag[2]); errs=errs+1; end
        r8_valid = 0;

        if (errs==0) $display("taginvw_selftest: PASS");
        else         $display("taginvw_selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
