//
// mac16 - one combinational reduced-precision multiply-add lane:
//   q = (a * b)  (sub ? - : +)  c
// using fp_mul16 (16-bit-mantissa multiply) + fp_add24 (~24-bit add).
// Pure combinational; the setup datapath registers q once per cycle, so each
// scheduled MAC op costs exactly one clock.
//
// To use as a plain add/sub, drive b = 1.0 (0x3f800000).
// To use as a plain multiply, drive c = 0 and sub = 0.
//
module mac16 (
    input  [31:0] a,
    input  [31:0] b,
    input  [31:0] c,
    input         sub,
    output [31:0] q
);
    wire [31:0] p;
    fp_mul16 u_mul (.a(a), .b(b), .y(p));
    fp_add24 u_add (.a(p), .b_in(c), .sub(sub), .y(q));
endmodule
