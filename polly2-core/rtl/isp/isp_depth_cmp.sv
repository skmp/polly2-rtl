//
// isp_depth_cmp - refsw opaque DepthMode compare, one lane, combinational.
//
// pass = "does the new invW pass against the stored depth" per ISP DepthMode
// (refsw: 0 never, 1 less, 2 equal, 3 less-or-equal, 4 greater, 5 not-equal,
// 6 greater-or-equal, 7 always; "reject" cases inverted to a pass flag).
//
// Depths are 31-bit SIGN-STRIPPED floats (always positive non-zero, so the
// sign bit is not stored anywhere): positive floats order like unsigned
// integers, so this is a plain unsigned compare. No NaN/inf handling (DaZ is
// handled upstream). Instantiate one per rasterizer lane.
//
module isp_depth_cmp (
    input      [2:0]  mode,   // ISP DepthMode (isp_word[31:29])
    input      [30:0] nw,     // new depth (invW, sign-stripped)
    input      [30:0] ob,     // stored depth (sign-stripped)
    output reg        pass
);
    reg lt,eq,gt;
    always @* begin
        eq = (nw==ob);
        gt = (nw>ob);
        lt = ~eq & ~gt;
        case (mode)
            3'd0: pass = 1'b0;      // never
            3'd1: pass = lt;        // less  (new < old)
            3'd2: pass = eq;        // equal
            3'd3: pass = lt|eq;     // less-or-equal
            3'd4: pass = gt;        // greater
            3'd5: pass = ~eq;       // not-equal
            3'd6: pass = gt|eq;     // greater-or-equal
            3'd7: pass = 1'b1;      // always
        endcase
    end
endmodule
