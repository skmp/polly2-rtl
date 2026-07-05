// self-checking test for dense_span_buffer: write a few spans at dense slots, read them
// back (1-cyc registered read), verify {start,id,rep,invw[0:3],at} per slot.
module dense_span_buffer_selftest;
    reg clk=0; always #5 clk=~clk;
    reg          we; reg [9:0] waddr, w_start, w_id; reg [2:0] w_rep;
    reg  [31:0]  w_invw [0:3]; reg w_at;
    reg  [9:0]   raddr;
    wire [9:0]   r_start, r_id; wire [2:0] r_rep; wire [31:0] r_invw [0:3]; wire r_at;

    dense_span_buffer #(.DEPTH(1024)) dut (
        .clk(clk), .we(we), .waddr(waddr), .w_start(w_start), .w_id(w_id), .w_rep(w_rep),
        .w_invw(w_invw), .w_at(w_at),
        .raddr(raddr), .r_start(r_start), .r_id(r_id), .r_rep(r_rep), .r_invw(r_invw), .r_at(r_at));

    integer errs=0, q;
    task wr(input [9:0] slot, input [9:0] st, input [9:0] id, input [2:0] rep,
            input [31:0] iv0, input at);
        begin
            we=1; waddr=slot; w_start=st; w_id=id; w_rep=rep; w_at=at;
            for(q=0;q<4;q=q+1) w_invw[q]=iv0+q;
            @(posedge clk); #1 we=0;
        end
    endtask
    task chk(input [9:0] slot, input [9:0] st, input [9:0] id, input [2:0] rep,
             input [31:0] iv0, input at);
        integer k;
        begin
            raddr=slot; @(posedge clk); #1;         // registered read: valid now
            if(r_start!==st) begin $display("slot%0d start %0d!=%0d",slot,r_start,st); errs=errs+1; end
            if(r_id!==id)    begin $display("slot%0d id %0d!=%0d",slot,r_id,id); errs=errs+1; end
            if(r_rep!==rep)  begin $display("slot%0d rep %0d!=%0d",slot,r_rep,rep); errs=errs+1; end
            if(r_at!==at)    begin $display("slot%0d at %b!=%b",slot,r_at,at); errs=errs+1; end
            for(k=0;k<4;k=k+1) if(r_invw[k]!==iv0+k[31:0]) begin $display("slot%0d invw%0d %08x!=%08x",slot,k,r_invw[k],iv0+k[31:0]); errs=errs+1; end
        end
    endtask

    initial begin
        we=0; raddr=0; w_start=0; w_id=0; w_rep=0; w_at=0; for(q=0;q<4;q=q+1) w_invw[q]=0;
        repeat(2) @(posedge clk);
        // dense slots 0,1,2 with distinct spans
        wr(10'd0, 10'd  0, 10'd100, 3'd4, 32'hA000_0000, 1'b1);
        wr(10'd1, 10'd 37, 10'd101, 3'd1, 32'hB000_0000, 1'b0);
        wr(10'd2, 10'd512, 10'd102, 3'd2, 32'hC000_0000, 1'b1);
        wr(10'd3, 10'd1020,10'd103, 3'd3, 32'hD000_0000, 1'b0);
        @(posedge clk);
        chk(10'd0, 10'd  0, 10'd100, 3'd4, 32'hA000_0000, 1'b1);
        chk(10'd1, 10'd 37, 10'd101, 3'd1, 32'hB000_0000, 1'b0);
        chk(10'd2, 10'd512, 10'd102, 3'd2, 32'hC000_0000, 1'b1);
        chk(10'd3, 10'd1020,10'd103, 3'd3, 32'hD000_0000, 1'b0);
        // moving-address streaming read (0->1->2) tracks the address
        // 1-cyc registered read: r_* AFTER an edge reflects the raddr stable BEFORE that edge.
        // Present a moving address each cycle; the output tracks it one cycle behind.
        raddr=10'd0; @(posedge clk); #1;   // r_* = slot 0
        if(r_id!==10'd100) begin $display("stream: slot0 id=%0d != 100",r_id); errs=errs+1; end
        raddr=10'd1; @(posedge clk); #1;   // r_* = slot 1
        if(r_id!==10'd101) begin $display("stream: slot1 id=%0d != 101",r_id); errs=errs+1; end
        raddr=10'd2; @(posedge clk); #1;   // r_* = slot 2
        if(r_id!==10'd102) begin $display("stream: slot2 id=%0d != 102",r_id); errs=errs+1; end
        if(errs==0) $display("dense_span_buffer selftest: PASS");
        else        $display("dense_span_buffer selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
