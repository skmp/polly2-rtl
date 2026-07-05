// self-checking test for taginvw_tile_buffer's 4-wide aligned read (rd4/g4), LANES=4.
//
// The raster writes ONE tag per write with a per-lane we mask, so 4 DISTINCT tags in an
// aligned group take 4 writes. This exercises what peel_core's spanner actually needs:
// four independent per-lane tags/invW read back in one rd4. (The earlier uniform-tag test
// hid both the 2-bank aliasing and the stuck-address bugs seen in the render.)
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

    initial begin
        reset=1; wr_valid=0; wr_we=0; clr_valid=0; pbc_valid=0; rd4_valid=0;
        wr_y=0; wr_x=0; wr_tag=0; wr_invw=0; wr_pt=0; clr_addr=0; clr_depth=0; clr_tag=0; pbc_addr=0; rd4_group=0;
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
        if (errs==0) $display("taginvw_selftest: PASS");
        else         $display("taginvw_selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
