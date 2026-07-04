// self-checking test for triangle_setups: write a few ids, read back, verify field
// offsets + ptex/pofs derivation + 10-lane unpack + 1-cycle registered read.
module triangle_setups_selftest import tsp_pkg::*; ;
    reg clk = 0;
    always #5 clk = ~clk;

    reg          we;
    reg  [9:0]   waddr, raddr;
    reg  [31:0]  w_isp, w_tsp, w_tcw;
    reg  [319:0] w_ddx, w_ddy, w_c;
    wire [31:0]  r_tsp, r_tcw;
    wire         r_ptex, r_pofs;
    wire [31:0]  r_ddx [0:9], r_ddy [0:9], r_c [0:9];

    triangle_setups #(.DEPTH(1024), .AW(10)) dut (
        .clk(clk), .we(we), .waddr(waddr),
        .w_isp(w_isp), .w_tsp(w_tsp), .w_tcw(w_tcw),
        .w_ddx(w_ddx), .w_ddy(w_ddy), .w_c(w_c),
        .raddr(raddr),
        .r_tsp(r_tsp), .r_tcw(r_tcw), .r_ptex(r_ptex), .r_pofs(r_pofs),
        .r_ddx(r_ddx), .r_ddy(r_ddy), .r_c(r_c));

    integer errs = 0; integer j;
    task wr(input [9:0] a, input [31:0] isp, tsp, tcw, input [31:0] base);
        begin
            w_isp=isp; w_tsp=tsp; w_tcw=tcw;
            for (j=0;j<10;j=j+1) begin
                w_ddx[32*j +: 32] = base + 32'h100 + j;
                w_ddy[32*j +: 32] = base + 32'h200 + j;
                w_c  [32*j +: 32] = base + 32'h300 + j;
            end
            waddr=a; we=1; @(posedge clk); #1 we=0;
        end
    endtask
    task chk(input [9:0] a, input exp_ptex, exp_pofs, input [31:0] exp_tsp, exp_tcw, base);
        begin
            raddr=a; @(posedge clk); #1;   // data valid the cycle after raddr presented
            if (r_tsp!==exp_tsp) begin $display("id%0d tsp %08x!=%08x",a,r_tsp,exp_tsp); errs=errs+1; end
            if (r_tcw!==exp_tcw) begin $display("id%0d tcw %08x!=%08x",a,r_tcw,exp_tcw); errs=errs+1; end
            if (r_ptex!==exp_ptex) begin $display("id%0d ptex %b!=%b",a,r_ptex,exp_ptex); errs=errs+1; end
            if (r_pofs!==exp_pofs) begin $display("id%0d pofs %b!=%b",a,r_pofs,exp_pofs); errs=errs+1; end
            for (j=0;j<10;j=j+1) begin
                if (r_ddx[j]!==base+32'h100+j) begin $display("id%0d ddx[%0d] %08x",a,j,r_ddx[j]); errs=errs+1; end
                if (r_ddy[j]!==base+32'h200+j) begin $display("id%0d ddy[%0d] %08x",a,j,r_ddy[j]); errs=errs+1; end
                if (r_c  [j]!==base+32'h300+j) begin $display("id%0d c[%0d] %08x",a,j,r_c[j]);   errs=errs+1; end
            end
        end
    endtask

    initial begin
        we=0; waddr=0; raddr=0;
        @(posedge clk);
        wr(10'd5,  (32'd1<<ISP_TEXTURE_BIT)|(32'd1<<ISP_OFFSET_BIT), 32'hAAAA1111, 32'hBBBB2222, 32'h00050000);
        wr(10'd6,  (32'd1<<ISP_TEXTURE_BIT),                          32'hCCCC3333, 32'hDDDD4444, 32'h00060000);
        wr(10'd7,  32'd0,                                             32'hEEEE5555, 32'hFFFF6666, 32'h00070000);
        chk(10'd5, 1'b1, 1'b1, 32'hAAAA1111, 32'hBBBB2222, 32'h00050000);
        chk(10'd6, 1'b1, 1'b0, 32'hCCCC3333, 32'hDDDD4444, 32'h00060000);
        chk(10'd7, 1'b0, 1'b0, 32'hEEEE5555, 32'hFFFF6666, 32'h00070000);
        if (errs==0) $display("triangle_setups selftest: PASS");
        else         $display("triangle_setups selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
