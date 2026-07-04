module span_buffer_v2_selftest;
    reg clk=0; always #5 clk=~clk;
    reg we; reg [9:0] waddr,raddr; reg w_shade,w_at; reg [9:0] w_id; reg [31:0] w_invw;
    wire r_shade,r_at; wire [9:0] r_id; wire [31:0] r_invw;
    span_buffer_v2 dut(.clk(clk),.we(we),.waddr(waddr),.w_shade(w_shade),.w_id(w_id),
        .w_invw(w_invw),.w_at(w_at),.raddr(raddr),.r_shade(r_shade),.r_id(r_id),
        .r_invw(r_invw),.r_at(r_at));
    integer errs=0;
    task wr(input [9:0]a,input sh,input[9:0]id,input[31:0]iv,input at);
        begin w_shade=sh;w_id=id;w_invw=iv;w_at=at;waddr=a;we=1;@(posedge clk);#1 we=0; end endtask
    task chk(input [9:0]a,input sh,input[9:0]id,input[31:0]iv,input at);
        begin raddr=a;@(posedge clk);#1;
        if(r_shade!==sh||r_id!==id||r_invw!==iv||r_at!==at) begin
            $display("a%0d got sh%b id%0d iv%08x at%b",a,r_shade,r_id,r_invw,r_at); errs=errs+1; end end endtask
    initial begin we=0;@(posedge clk);
        wr(10'd7,1'b1,10'd300,32'hDEAD,1'b1);
        wr(10'd9,1'b0,10'd301,32'hBEEF,1'b0);
        chk(10'd7,1'b1,10'd300,32'hDEAD,1'b1);
        chk(10'd9,1'b0,10'd301,32'hBEEF,1'b0);
        if(errs==0)$display("span_buffer_v2 selftest: PASS"); else $display("%0d ERRORS",errs);
        $finish; end
endmodule
