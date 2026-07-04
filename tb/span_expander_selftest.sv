// self-checking test for span_expander: feed sparse spans (honoring sp_ready), capture
// the per-pixel writes, verify {shade,id,invw,at} per covered pixel + rep-cycle pacing.
module span_expander_selftest;
    reg clk=0; always #5 clk=~clk;
    reg reset;

    reg          sp_we; reg [9:0] sp_idx; reg [2:0] sp_rep;
    reg  [31:0]  sp_invw [0:3]; reg [3:0] sp_shmask; reg [9:0] sp_id; reg sp_at;
    wire         sp_ready;
    wire         xe_we; wire [9:0] xe_addr; wire xe_shade; wire [9:0] xe_id;
    wire [31:0]  xe_invw; wire xe_at;

    span_expander dut (
        .clk(clk), .reset(reset),
        .sp_we(sp_we), .sp_idx(sp_idx), .sp_rep(sp_rep), .sp_invw(sp_invw),
        .sp_shmask(sp_shmask), .sp_id(sp_id), .sp_at(sp_at), .sp_ready(sp_ready),
        .xe_we(xe_we), .xe_addr(xe_addr), .xe_shade(xe_shade), .xe_id(xe_id),
        .xe_invw(xe_invw), .xe_at(xe_at));

    // captured per-pixel memory
    reg        got_v [0:31];
    reg        got_sh [0:31]; reg [9:0] got_id [0:31]; reg [31:0] got_iv [0:31]; reg got_at [0:31];
    always @(posedge clk) if (xe_we && !reset) begin
        got_v[xe_addr]<=1; got_sh[xe_addr]<=xe_shade; got_id[xe_addr]<=xe_id;
        got_iv[xe_addr]<=xe_invw; got_at[xe_addr]<=xe_at;
    end

    integer errs=0; integer q; integer stalls;
    // present a span, honoring sp_ready; hold sp_we=0 while it expands.
    task send(input [9:0] idx, input [2:0] rep, input [3:0] sm, input [9:0] id, input at, input [31:0] base);
        begin
            while (!sp_ready) @(posedge clk);
            sp_idx=idx; sp_rep=rep; sp_shmask=sm; sp_id=id; sp_at=at;
            for (q=0;q<4;q=q+1) sp_invw[q]=base+q;
            sp_we=1; @(posedge clk); #1 sp_we=0;
            // wait out expansion (rep>1 -> sp_ready low for a few cycles)
            stalls=0; while (!sp_ready && stalls<10) begin @(posedge clk); stalls=stalls+1; end
        end
    endtask
    task chk(input [9:0] idx, input [2:0] rep, input [3:0] sm, input [9:0] id, input at, input [31:0] base);
        integer k;
        begin
            for (k=0;k<rep;k=k+1) begin
                if (!got_v[idx+k]) begin $display("px%0d not written",idx+k); errs=errs+1; end
                if (got_sh[idx+k]!==sm[k]) begin $display("px%0d shade %b!=%b",idx+k,got_sh[idx+k],sm[k]); errs=errs+1; end
                if (got_id[idx+k]!==id)    begin $display("px%0d id %0d!=%0d",idx+k,got_id[idx+k],id); errs=errs+1; end
                if (got_iv[idx+k]!==base+k)begin $display("px%0d invw %08x!=%08x",idx+k,got_iv[idx+k],base+k); errs=errs+1; end
                if (got_at[idx+k]!==at)    begin $display("px%0d at %b!=%b",idx+k,got_at[idx+k],at); errs=errs+1; end
            end
        end
    endtask

    initial begin
        reset=1; sp_we=0; for(q=0;q<32;q=q+1) got_v[q]=0;
        repeat(3) @(posedge clk); #1 reset=0;
        send(10'd0, 3'd4, 4'b1011, 10'd100, 1'b1, 32'hA000);   // rep4, lane2 not shaded
        send(10'd4, 3'd1, 4'b0001, 10'd101, 1'b0, 32'hB000);   // rep1
        send(10'd6, 3'd2, 4'b0011, 10'd102, 1'b1, 32'hC000);   // rep2
        send(10'd8, 3'd3, 4'b0111, 10'd103, 1'b0, 32'hD000);   // rep3
        repeat(4) @(posedge clk);
        chk(10'd0, 3'd4, 4'b1011, 10'd100, 1'b1, 32'hA000);
        chk(10'd4, 3'd1, 4'b0001, 10'd101, 1'b0, 32'hB000);
        chk(10'd6, 3'd2, 4'b0011, 10'd102, 1'b1, 32'hC000);
        chk(10'd8, 3'd3, 4'b0111, 10'd103, 1'b0, 32'hD000);
        if (errs==0) $display("span_expander selftest: PASS");
        else         $display("span_expander selftest: %0d ERRORS", errs);
        $finish;
    end
endmodule
