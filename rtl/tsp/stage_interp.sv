//
// interp_unit - the tsp_shade_pp INTERP block as a standalone streamed unit, built
// from the PIPELINED FP units (fp_mul_i5_pp / fp_add3_24_pp / fp_mul16_pp).
// (File stage_interp.sv; the timing-harness TOP is a separate module `stage_interp`
// in timming_tests/stage_interp/ that instantiates this.)
//
// Per plane (x10, parallel):
//   i1 : prx = ddx*px , pry = ddy*py            (fp_mul_i5_pp)
//   i2 : sum = prx + pry + c                     (fp_add3_24_pp)
//   i3 : attr = sum * W                          (fp_mul16_pp)
//
// CONVENTION: the FP units do NOT register their own inputs/outputs (combinational in
// and out around their internal stages). So THIS wrapper owns the register at every
// boundary: it registers the FP unit results (i1->i2 and i2->i3 boundaries + the final
// attr) and holds the module inputs. Per-unit internal register counts:
//   fp_mul_i5_pp  : 1 internal  -> +1 wrapper reg = 2 cyc
//   fp_add3_24_pp : 4 internal  -> +1 wrapper reg = 5 cyc
//   fp_mul16_pp   : 1 internal  -> +1 wrapper reg = 2 cyc
// Total INTERP latency = 2 + 5 + 2 = 9 cycles.
//
// DATAFLOW / ALIGNMENT. The pipes chain by valid. The carried operands are delay-
// matched to the pipe they feed:
//   c : consumed by i2 (at the i1-result register) -> delay c by i1's latency (2).
//   W : consumed by i3 (at the i2-result register) -> delay W by i1+i2 latency (7).
// The delay lines are plain flop chains gated by !stall.
//
// HOLD (backpressure): INTERP lives in tsp_shade_pp's `en`-gated front. `stall`=1
// freezes EVERYTHING (FP-unit internal regs + the boundary regs + c/W delay lines).
// in_valid -> out_valid. No input/output buffering at the module edge beyond the
// boundary regs the wrapper owns (caller holds inputs stable while in_valid && !stall).
//
module interp_unit (
    input             clk,
    input             reset,
    input             stall,               // 1 = freeze everything (front-pipe hold)
    input             in_valid,
    input      [31:0] ddx [0:9],
    input      [31:0] ddy [0:9],
    input      [31:0] c   [0:9],
    input      [4:0]  px,
    input      [4:0]  py,
    input      [31:0] w,                    // 1/invW (i3 multiplicand)
    output            out_valid,
    output reg [31:0] attr [0:9]
);
    localparam integer LAT_I1 = 2;          // fp_mul_i5_pp (1 internal) + boundary reg
    localparam integer LAT_I2 = 5;          // fp_add3_24_pp (4 internal) + boundary reg
    localparam integer CDLY   = LAT_I1;         // delay for c  (into i2) = 2
    localparam integer WDLY   = LAT_I1 + LAT_I2; // delay for W (into i3) = 7

    genvar gi;
    integer d, ds;

    // ---- c delay line: c[k] delayed by CDLY, per plane. c_dl[k][CDLY-1] is aligned. ----
    reg [31:0] c_dl [0:9][0:CDLY-1];
    always @(posedge clk) begin
        if (!stall) for (d=0; d<10; d=d+1) begin
            c_dl[d][0] <= c[d];
            for (ds=1; ds<CDLY; ds=ds+1) c_dl[d][ds] <= c_dl[d][ds-1];
        end
    end

    // ---- W delay line: single word delayed by WDLY ----
    reg [31:0] w_dl [0:WDLY-1];
    always @(posedge clk) begin
        if (!stall) begin
            w_dl[0] <= w;
            for (d=1; d<WDLY; d=d+1) w_dl[d] <= w_dl[d-1];
        end
    end
    wire [31:0] w_aligned = w_dl[WDLY-1];

    // per-plane combinational FP-unit outputs + boundary registers
    wire [31:0] prx_c [0:9], pry_c [0:9];   // i1 combinational products
    wire        i1_ov_c [0:9];
    reg  [31:0] prx_r [0:9], pry_r [0:9];   // i1 boundary REGISTER (wrapper-owned)
    reg         i1_v;

    wire [31:0] sum_c [0:9];                 // i2 combinational sum
    wire        i2_ov_c [0:9];
    reg  [31:0] sum_r [0:9];                 // i2 boundary REGISTER
    reg         i2_v;

    wire [31:0] attr_c [0:9];                // i3 combinational product
    wire        i3_ov_c [0:9];

    generate
      for (gi=0; gi<10; gi=gi+1) begin : plane
        // i1: two products (combinational out). in_valid = module in_valid.
        fp_mul_i5_pp u_mx (.clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid),
            .f(ddx[gi]),.k(px),.out_valid(i1_ov_c[gi]),.y(prx_c[gi]));
        fp_mul_i5_pp u_my (.clk(clk),.reset(reset),.stall(stall),.in_valid(in_valid),
            .f(ddy[gi]),.k(py),.out_valid(),.y(pry_c[gi]));

        // i2: prx_r + pry_r + c(aligned). Fed from the i1 boundary register.
        fp_add3_24_pp u_add (.clk(clk),.reset(reset),.stall(stall),.in_valid(i1_v),
            .a(prx_r[gi]),.b(pry_r[gi]),.c(c_dl[gi][CDLY-1]),
            .out_valid(i2_ov_c[gi]),.y(sum_c[gi]));

        // i3: sum_r * W(aligned). Fed from the i2 boundary register.
        fp_mul16_pp u_mul (.clk(clk),.reset(reset),.stall(stall),.in_valid(i2_v),
            .a(sum_r[gi]),.b(w_aligned),.out_valid(i3_ov_c[gi]),.y(attr_c[gi]));
      end
    endgenerate

    // ---- boundary registers (wrapper-owned; the FP units are comb in/out) ----
    always @(posedge clk) begin
        if (reset) begin i1_v <= 1'b0; i2_v <= 1'b0; end
        else if (!stall) begin
            // i1 result -> boundary reg (feeds i2)
            for (d=0; d<10; d=d+1) begin prx_r[d] <= prx_c[d]; pry_r[d] <= pry_c[d]; end
            i1_v <= i1_ov_c[0];
            // i2 result -> boundary reg (feeds i3)
            for (d=0; d<10; d=d+1) sum_r[d] <= sum_c[d];
            i2_v <= i2_ov_c[0];
            // i3 result -> output reg (attr)
            for (d=0; d<10; d=d+1) attr[d] <= attr_c[d];
        end
    end

    // out_valid tracks the i3 result being captured into attr (one more cycle after i2_v).
    reg attr_v;
    always @(posedge clk) begin
        if (reset) attr_v <= 1'b0;
        else if (!stall) attr_v <= i3_ov_c[0];
    end
    assign out_valid = attr_v;
endmodule
