// compare fp_add3_24(a,b,c) against chained fp_add24(fp_add24(a,b),c)
module fp_add3_tb_top (
    input  [31:0] a, b, c,
    output [31:0] y3,          // fused 3-way
    output [31:0] y2           // chained reference (a+b)+c
);
    fp_add3_24 u3 (.a(a), .b(b), .c(c), .y(y3));
    wire [31:0] ab;
    fp_add24 uab (.a(a), .b_in(b), .sub(1'b0), .y(ab));
    fp_add24 uc  (.a(ab), .b_in(c), .sub(1'b0), .y(y2));
endmodule
