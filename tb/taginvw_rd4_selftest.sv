// self-checking test for taginvw_tile_buffer's 4-wide aligned read (LANES=4):
// write a 4-lane chunk via the raster stage-B port, read it back with rd4, verify the
// 4 aligned lanes {valid,tag,invW,pt} + 1-cycle latency.
module taginvw_rd4_selftest;
    reg clk = 0; always #5 clk = ~clk;
    reg reset;

    reg          wr_valid; reg [3:0] wr_we; reg [4:0] wr_y, wr_x;
    reg  [31:0]  wr_tag; reg [127:0] wr_invw; reg wr_pt;
    reg          rd4_valid; reg [9:0] rd4_group;
    wire [3:0]   g4_valid, g4_pt;
    wire [31:0]  g4_tag [0:3], g4_invw [0:3];

    taginvw_tile_buffer #(.LANES(4)) dut (
        .clk(clk), .reset(reset),
        .wr_valid(wr_valid), .wr_we(wr_we), .wr_y(wr_y), .wr_x(wr_x),
        .wr_tag(wr_tag), .wr_invw(wr_invw), .wr_pt(wr_pt),
        .clr_valid(1'b0), .clr_addr('0), .clr_depth('0), .clr_tag('0),
        .pbc_valid(1'b0), .pbc_addr('0),
        .sh_rd_valid(1'b0), .sh_rd_id('0),
        .sh_valid(), .sh_tag(), .sh_depth(), .sh_pt(),
        .rd4_valid(rd4_valid), .rd4_group(rd4_group),
        .g4_valid(g4_valid), .g4_tag(g4_tag), .g4_invw(g4_invw), .g4_pt(g4_pt));

    integer errs = 0; integer j;
    task wr(input [4:0] y, xchunk, input [31:0] tag, input [31:0] i0,i1,i2,i3, input pt);
        begin
            wr_y=y; wr_x=xchunk; wr_tag=tag; wr_pt=pt; wr_we=4'hF;
            wr_invw = {i3,i2,i1,i0};
            wr_valid=1; @(posedge clk); #1 wr_valid=0;
        end
    endtask
    task chk(input [9:0] g, input [31:0] tag, input [31:0] i0,i1,i2,i3, input pt);
        reg [31:0] iv [0:3];
        begin
            iv[0]=i0; iv[1]=i1; iv[2]=i2; iv[3]=i3;
            rd4_valid=1; rd4_group=g; @(posedge clk); #1; rd4_valid=0;
            if (g4_valid!==4'hF) begin $display("g%0d valid %b",g,g4_valid); errs=errs+1; end
            if (g4_pt!==(pt?4'hF:4'h0)) begin $display("g%0d pt %b",g,g4_pt); errs=errs+1; end
            for (j=0;j<4;j=j+1) begin
                if (g4_tag[j]!==tag)   begin $display("g%0d tag[%0d] %08x!=%08x",g,j,g4_tag[j],tag); errs=errs+1; end
                if (g4_invw[j]!==iv[j])begin $display("g%0d invw[%0d] %08x!=%08x",g,j,g4_invw[j],iv[j]); errs=errs+1; end
            end
        end
    endtask

    initial begin
        reset=1; wr_valid=0; rd4_valid=0; wr_we=0;
        repeat (3) @(posedge clk); #1 reset=0;
        // chunk (y=0,x=0) -> pixels 0..3
        wr(5'd0, 5'd0, 32'hCAFE0001, 32'h1000,32'h1001,32'h1002,32'h1003, 1'b1);
        // chunk (y=3,x=8) -> pixels 104..107
        wr(5'd3, 5'd8, 32'hCAFE0002, 32'h2000,32'h2001,32'h2002,32'h2003, 1'b0);
        chk(10'd0,   32'hCAFE0001, 32'h1000,32'h1001,32'h1002,32'h1003, 1'b1);
        chk(10'd104, 32'hCAFE0002, 32'h2000,32'h2001,32'h2002,32'h2003, 1'b0);
        if (errs==0) $display("taginvw rd4 selftest: PASS");
        else         $display("taginvw rd4 selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
