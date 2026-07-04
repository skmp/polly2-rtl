// self-checking test for span_buffer_v2: write spans at run-start indices, read back,
// verify {id, rep, invw[0:3], shmask, at} pack/unpack + 1-cycle registered read.
module span_buffer_v2_selftest;
    reg clk = 0;
    always #5 clk = ~clk;

    reg          we;
    reg  [9:0]   waddr, raddr;
    reg  [9:0]   w_id;
    reg  [2:0]   w_rep;
    reg  [31:0]  w_invw [0:3];
    reg  [3:0]   w_shmask;
    reg          w_at;
    wire [9:0]   r_id;
    wire [2:0]   r_rep;
    wire [31:0]  r_invw [0:3];
    wire [3:0]   r_shmask;
    wire         r_at;

    span_buffer_v2 #(.DEPTH(1024)) dut (
        .clk(clk), .we(we), .waddr(waddr),
        .w_id(w_id), .w_rep(w_rep), .w_invw(w_invw), .w_shmask(w_shmask), .w_at(w_at),
        .raddr(raddr),
        .r_id(r_id), .r_rep(r_rep), .r_invw(r_invw), .r_shmask(r_shmask), .r_at(r_at));

    integer errs = 0; integer j;
    task wr(input [9:0] a, input [9:0] id, input [2:0] rep, input [3:0] sm, input at, input [31:0] base);
        begin
            w_id=id; w_rep=rep; w_shmask=sm; w_at=at;
            for (j=0;j<4;j=j+1) w_invw[j]=base+j;
            waddr=a; we=1; @(posedge clk); #1 we=0;
        end
    endtask
    task chk(input [9:0] a, input [9:0] id, input [2:0] rep, input [3:0] sm, input at, input [31:0] base);
        begin
            raddr=a; @(posedge clk); #1;
            if (r_id!==id)        begin $display("a%0d id %0d!=%0d",a,r_id,id); errs=errs+1; end
            if (r_rep!==rep)      begin $display("a%0d rep %0d!=%0d",a,r_rep,rep); errs=errs+1; end
            if (r_shmask!==sm)    begin $display("a%0d shmask %b!=%b",a,r_shmask,sm); errs=errs+1; end
            if (r_at!==at)        begin $display("a%0d at %b!=%b",a,r_at,at); errs=errs+1; end
            for (j=0;j<4;j=j+1) if (r_invw[j]!==base+j) begin $display("a%0d invw[%0d] %08x",a,j,r_invw[j]); errs=errs+1; end
        end
    endtask

    initial begin
        we=0; waddr=0; raddr=0;
        @(posedge clk);
        wr(10'd0,  10'd100, 3'd4, 4'hF, 1'b1, 32'h1000);
        wr(10'd4,  10'd101, 3'd2, 4'h3, 1'b0, 32'h2000);
        wr(10'd6,  10'd200, 3'd1, 4'h1, 1'b1, 32'h3000);
        chk(10'd0, 10'd100, 3'd4, 4'hF, 1'b1, 32'h1000);
        chk(10'd4, 10'd101, 3'd2, 4'h3, 1'b0, 32'h2000);
        chk(10'd6, 10'd200, 3'd1, 4'h1, 1'b1, 32'h3000);
        if (errs==0) $display("span_buffer_v2 selftest: PASS");
        else         $display("span_buffer_v2 selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
