//
// tex_addroffsgen_ib - relative texture offset for the 4 bilinear corners.
//
// Computes ONLY the relative texel offset (no base, no fbpp byte-scale, no mip add).
// Two layouts, selected by `twiddled`:
//   twiddled=1 : Morton bit-interleave of (u,v)  (PVR twiddled textures)
//   twiddled=0 : linear  u + stride*v            (scan-order textures)
//
// SIZES IN EXPONENT FORM: u_log2/v_log2 in 0..10 -> size 1<<log2 (1..1024).
//
// SEPARABLE TWIDDLE via a SHARED part1by1 ROM. The Morton spread decomposes (verified
// bit-exact vs the original tex_addr loop) into ONE fixed function part1by1(x) = "spread
// each bit to even positions" plus a size-dependent linear TAIL:
//   m = min(u_log2, v_log2)
//   spreadV(v) = part1by1(v & (2^m-1))        |  ((v >> m) << 2m)    [V-tail if V>m]
//   spreadU(u) = part1by1(u & (2^m-1)) << 1   |  ((u >> m) << 2m)    [U-tail if U>m]
//   twiddle(u,v) = spreadU(u) | spreadV(v)     (disjoint bit positions)
// part1by1 is a fixed 1024x20 M10K ROM, read for u0,u1,v0,v1. This replaces the deep
// size-dependent mux tree (the old ~913 ALM / 36 MHz version) with a ROM + shifts.
//
// PIPELINE: ONE internal register = the M10K ROM read (needed to infer block RAM).
//   comb-in : coord -> ROM address ; stride*v (linear) ; carry sizes/coords/twiddled
//   [REG]   : ROM data (4x part1by1) + delayed sizes/coords/twiddled/linear
//   comb-out: mask + tail + OR -> twiddle ; mux twiddle/linear -> offset[0:3]
// Per convention the WRAPPING unit owns the input and output registers; this module
// has only the (unavoidable) ROM-read register in the middle.
//
// corner order (matches tex_uvmap / tex_fetch): 0=(u1,v1) 1=(u0,v1) 2=(u1,v0) 3=(u0,v0)
//
module tex_addroffsgen_ib (
    input             clk,
    input             reset,
    input             stall,
    input             in_valid,
    input      [3:0]  u_log2,     // log2(U size), 0..10
    input      [3:0]  v_log2,     // log2(V size), 0..10
    input      [10:0] stride,     // linear row pitch (modulo), 1..1024
    input             twiddled,   // 1 = Morton, 0 = linear (from tcw; passthrough)
    input      [9:0]  u0, u1,     // 2 distinct U coords (0..1023)
    input      [9:0]  v0, v1,     // 2 distinct V coords

    output            out_valid,
    output     [20:0] offset [0:3],
    output            twiddled_o
);
    // ---------- part1by1 ROM (1024 x 20, M10K): spread bits of x to even positions ----------
    (* ramstyle = "M10K" *) reg [19:0] p1_rom [0:1023];
    integer ri, rb;
    initial begin
        for (ri=0; ri<1024; ri=ri+1) begin
            p1_rom[ri] = 20'd0;
            for (rb=0; rb<10; rb=rb+1)
                p1_rom[ri][2*rb] = ri[rb];      // bit rb -> position 2*rb
        end
    end

    // ---------- INPUT BUFFER (the "_ib" register): a DIRECT clock latch on the raw
    //      inputs. NOTHING combinational feeds this flop, so upstream combinational logic
    //      (e.g. tex_uvmap / tex_base_addr) has the full cycle to reach it. ALL of this
    //      module's logic (ROM permute, min, mask, tail, mul, mux) is combinational AFTER
    //      the latch, producing combinational outputs the wrapper then registers. ----
    reg        v_r;
    reg [3:0]  r_ulog2, r_vlog2;
    reg [10:0] r_stride;
    reg        r_tw;
    reg [9:0]  r_u0, r_u1, r_v0, r_v1;
    always @(posedge clk) begin
        if (reset) v_r <= 1'b0;
        else if (!stall) begin
            v_r     <= in_valid;
            r_ulog2 <= u_log2; r_vlog2 <= v_log2;
            r_stride<= stride; r_tw <= twiddled;
            r_u0    <= u0; r_u1 <= u1; r_v0 <= v0; r_v1 <= v1;
        end
    end

    // ---------- comb (all off the registered inputs) ----------
    // part1by1 spread (free wiring): p1(x) places bit b at position 2b.
    wire [19:0] p1_u0 = p1_rom[r_u0], p1_u1 = p1_rom[r_u1];
    wire [19:0] p1_v0 = p1_rom[r_v0], p1_v1 = p1_rom[r_v1];

    // linear products
    wire [20:0] sv0 = {10'd0, r_stride} * {11'd0, r_v0};
    wire [20:0] sv1 = {10'd0, r_stride} * {11'd0, r_v1};

    // min exponent + mask
    wire [3:0]  m  = (r_ulog2 <= r_vlog2) ? r_ulog2 : r_vlog2;   // min(U,V)
    wire [4:0]  m2 = {m, 1'b0};                                  // 2*m
    wire [20:0] ilv_mask = (21'd1 << m2) - 21'd1;                // keep positions [0..2m-1]

    // spreadV(v) = (part1by1(v) & ilv_mask) | ((v>>m) << 2m)   [interleave | linear tail]
    // spreadU(u) = ((part1by1(u) & ilv_mask) << 1) | ((u>>m) << 2m)
    function [20:0] mkV(input [19:0] p1, input [9:0] cv);
        mkV = ({1'b0, p1} & ilv_mask) | ({11'd0, (cv >> m)} << m2);
    endfunction
    function [20:0] mkU(input [19:0] p1, input [9:0] cu);
        mkU = (({1'b0, p1} & ilv_mask) << 1) | ({11'd0, (cu >> m)} << m2);
    endfunction

    wire [20:0] sU0 = mkU(p1_u0, r_u0), sU1 = mkU(p1_u1, r_u1);
    wire [20:0] sV0 = mkV(p1_v0, r_v0), sV1 = mkV(p1_v1, r_v1);

    wire [20:0] tw [0:3];
    wire [20:0] lin[0:3];
    assign tw[0]  = sU1 | sV1;   assign lin[0] = {11'd0, r_u1} + sv1;
    assign tw[1]  = sU0 | sV1;   assign lin[1] = {11'd0, r_u0} + sv1;
    assign tw[2]  = sU1 | sV0;   assign lin[2] = {11'd0, r_u1} + sv0;
    assign tw[3]  = sU0 | sV0;   assign lin[3] = {11'd0, r_u0} + sv0;

    genvar gi;
    generate for (gi=0; gi<4; gi=gi+1) begin : corner
        assign offset[gi] = r_tw ? tw[gi] : lin[gi];
    end endgenerate

    assign twiddled_o = r_tw;
    assign out_valid  = v_r;
endmodule
