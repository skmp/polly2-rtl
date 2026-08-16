// self-checking test for taginvw_tile_buffer's STORED SPAN BOUNDARIES (rs/re) and the
// stored dedup HASH - the two fields that let spanner_v2 drop its cross-lane 32-bit tag
// comparators and its pc_slot hash out of the RAM -> address loop.
//
// The property under test is a whole-buffer INVARIANT, not a waveform, so this tb keeps a
// software model of the tile (per-pixel tag/valid, plus the id of the write that last
// touched each pixel) and, after every write, checks every adjacent pixel pair:
//
//   edge[p] := rs[p] | re[p-1]          (how the spanner recovers a boundary)
//
//   1) SOUND  : edge[p]==0  =>  tag[p]==tag[p-1] AND valid[p]==valid[p-1].
//               This is the one that MUST hold. A false 0 merges two triangles into one
//               span and shades the second one with the first one's planes.
//   2) EXACT  : edge[p] == (last_write_id[p] != last_write_id[p-1]).
//               Stronger than (1): it says the scheme never reports a boundary that isn't
//               one. A false 1 is harmless for correctness but splits a run into two
//               spans, so letting it rot would quietly give back the coalescing the
//               spanner exists to do. Checked at group-interior lanes only - lane 0 of a
//               group is a boundary by construction (the walk never crosses one) and the
//               buffer deliberately forces rs there.
//   3) HASH   : hash[p] == ti_hash(tag[p]) for every pixel, including the blind-cleared
//               ones the pbc walk writes (tag=0 -> hash=0).
//
// The write patterns are chosen to hit the cases the boundary scheme has to survive:
//   A) CLEAR walk           - one whole-chunk write per chunk: interior must have NO edges.
//   B) full-run overwrite   - a later run that COVERS an earlier boundary must ERASE it
//                             (the case a set-only "edge" bit would get wrong, leaving a
//                             stale split forever).
//   C) depth-fail holes     - a write mask with interior gaps: every gap must produce a
//                             boundary on BOTH sides (the resumed old triangle is a new
//                             span), which is the "write 1 on the first failure" case.
//   D) randomized soak      - random masks/tags over the whole tile, checked every write.
//
module spanedge_selftest import tsp_pkg::*; #(
    parameter integer LANES  = 8,
    parameter integer COPIES = 4,
    parameter integer GW     = 4,
    parameter integer NRAND  = 3000
) ;
    localparam integer BW  = $clog2(LANES);
    localparam integer TAW = 10 - BW;                  // in-tile addr width
    localparam integer CBW = (COPIES > 1) ? $clog2(COPIES) : 1;
    localparam integer GB  = $clog2(GW);

    reg clk=0; always #5 clk=~clk;
    reg reset;

    reg  [CBW-1:0]      wr_buf, rd_buf;
    reg                 wr_valid;
    reg  [LANES-1:0]    wr_we;
    reg  [4:0]          wr_y, wr_x;
    reg  [31:0]         wr_tag;
    reg  [31*LANES-1:0] wr_invw;
    reg                 wr_pt;
    reg                 clr_valid; reg [TAW-1:0] clr_addr; reg [30:0] clr_depth; reg [31:0] clr_tag;
    reg                 pbc_valid; reg [TAW-1:0] pbc_addr;
    reg                 rdg_valid; reg [9:0] rdg_group;
    wire [GW-1:0]       gg_valid, gg_pt, gg_rs, gg_re;
    wire [31:0]         gg_tag  [0:GW-1];
    wire [30:0]         gg_invw [0:GW-1];
    wire [TI_HASHW-1:0] gg_hash [0:GW-1];

    taginvw_tile_buffer #(.LANES(LANES), .COPIES(COPIES), .GW(GW)) dut (
        .clk(clk), .reset(reset),
        .wr_buf(wr_buf), .rd_buf(rd_buf),
        .wr_valid(wr_valid), .wr_we(wr_we), .wr_y(wr_y), .wr_x(wr_x),
        .wr_tag(wr_tag), .wr_invw(wr_invw), .wr_pt(wr_pt),
        .clr_valid(clr_valid), .clr_addr(clr_addr), .clr_depth(clr_depth), .clr_tag(clr_tag),
        .pbc_valid(pbc_valid), .pbc_addr(pbc_addr),
        .sh_rd_valid(1'b0), .sh_rd_id(10'd0),
        .sh_valid(), .sh_tag(), .sh_depth(), .sh_pt(),
        .rdg_valid(rdg_valid), .rdg_group(rdg_group),
        .gg_valid(gg_valid), .gg_tag(gg_tag), .gg_invw(gg_invw), .gg_pt(gg_pt),
        .gg_rs(gg_rs), .gg_re(gg_re), .gg_hash(gg_hash));

    // ---------------- software model of the copy under test ----------------
    // m_wid = the serial number of the write that last touched the pixel. Two adjacent
    // pixels are in the same span iff this matches, which is the EXACT property (2).
    reg [31:0] m_tag [0:1023];
    reg        m_val [0:1023];
    integer    m_wid [0:1023];
    integer    wid;                                    // next write serial number

    integer errs = 0;

    // Every task below is `automatic` and declares its own loop variables: the soak loop
    // calls them from inside its own for-loop, and a shared module-level counter would be
    // reset by the callee on every iteration (a non-terminating outer loop, not a wrong
    // answer - it simply never finishes).
    task automatic fail(input string ctx);
        begin $display("FAIL %s", ctx); errs = errs + 1; end
    endtask

    // deterministic xorshift32 - $urandom(seed) RESEEDS on every call, so passing the same
    // variable each time yields the same number forever.
    reg [31:0] rng = 32'h5EED_1234;
    function automatic [31:0] rnd();
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng;
        end
    endfunction

    // ---------------- driven writes, mirrored into the model ----------------
    // Every task advances one clock with exactly one write client asserted, then stamps
    // the model with the same effect, so the model and the RAM stay in lockstep by
    // construction rather than by a separate end-of-test reconciliation.
    task automatic do_raster(input [4:0] y, input [4:0] xb, input [LANES-1:0] mask,
                             input [31:0] tag);
        integer i, p;
        begin
            wr_valid=1'b1; wr_we=mask; wr_y=y; wr_x=xb; wr_tag=tag;
            for (i = 0; i < LANES; i = i + 1) wr_invw[31*i +: 31] = 31'(100 + i);
            @(posedge clk); #1;
            wr_valid=1'b0; wr_we='0;
            wid = wid + 1;
            for (i = 0; i < LANES; i = i + 1) if (mask[i]) begin
                p = {y, xb} + i;
                m_tag[p] = tag; m_val[p] = 1'b1; m_wid[p] = wid;
            end
        end
    endtask

    task automatic do_clear(input [TAW-1:0] addr, input [31:0] tag);
        integer i, p;
        begin
            clr_valid=1'b1; clr_addr=addr; clr_depth=31'h1234; clr_tag=tag;
            @(posedge clk); #1;
            clr_valid=1'b0;
            wid = wid + 1;
            for (i = 0; i < LANES; i = i + 1) begin
                p = {addr, i[BW-1:0]};                 // bank i of this chunk
                m_tag[p] = tag; m_val[p] = 1'b0; m_wid[p] = wid;
            end
        end
    endtask

    task automatic do_pbc(input [TAW-1:0] addr);
        integer i, p;
        begin
            pbc_valid=1'b1; pbc_addr=addr;
            @(posedge clk); #1;
            pbc_valid=1'b0;
            wid = wid + 1;
            for (i = 0; i < LANES; i = i + 1) begin
                p = {addr, i[BW-1:0]};
                m_tag[p] = 32'd0; m_val[p] = 1'b0; m_wid[p] = wid;
            end
        end
    endtask

    // ---------------- the checker ----------------
    // Reads every aligned group of the tile and applies (1) (2) (3). `ctx` names the
    // phase so a failure points at the pattern that produced it.
    task automatic check_all(input string ctx);
        reg edg, exp_edg;
        integer l, p, g;
        begin
            for (g = 0; g < 1024; g = g + GW) begin
                rdg_valid = 1'b1; rdg_group = g[9:0];
                @(posedge clk); #1;
                rdg_valid = 1'b0;
                for (l = 0; l < GW; l = l + 1) begin
                    p = g + l;
                    // (3) the stored hash must still describe the stored tag
                    if (gg_hash[l] !== ti_hash(gg_tag[l]))
                        fail($sformatf("%s px%0d hash %03x != ti_hash(tag %08x)=%03x",
                                       ctx, p, gg_hash[l], gg_tag[l], ti_hash(gg_tag[l])));
                    // the model must agree about the payload, else the boundary check
                    // below is testing the wrong tile
                    if (gg_tag[l] !== m_tag[p])
                        fail($sformatf("%s px%0d tag %08x != model %08x",
                                       ctx, p, gg_tag[l], m_tag[p]));
                    if (gg_valid[l] !== m_val[p])
                        fail($sformatf("%s px%0d valid %b != model %b",
                                       ctx, p, gg_valid[l], m_val[p]));
                    if (l == 0) continue;              // group start: boundary by construction

                    edg     = gg_rs[l] | gg_re[l-1];
                    exp_edg = (m_wid[p] != m_wid[p-1]);
                    // (1) SOUND: no boundary reported => the spanner will coalesce these
                    // two pixels into one span, so they had better be the same fragment.
                    if (!edg && (m_tag[p] !== m_tag[p-1] || m_val[p] !== m_val[p-1]))
                        fail($sformatf("%s px%0d MERGED across a real boundary (tag %08x/%08x val %b/%b)",
                                       ctx, p, m_tag[p-1], m_tag[p], m_val[p-1], m_val[p]));
                    // (2) EXACT: and it reports a boundary exactly when there is one.
                    if (edg !== exp_edg)
                        fail($sformatf("%s px%0d edge=%b (rs=%b re[-1]=%b) want %b (wid %0d/%0d)",
                                       ctx, p, edg, gg_rs[l], gg_re[l-1], exp_edg,
                                       m_wid[p-1], m_wid[p]));
                end
            end
        end
    endtask

    task automatic clear_whole_tile(input [31:0] tag);
        integer i;
        begin
            for (i = 0; i < (1024/LANES); i = i + 1) do_clear(TAW'(i), tag);
        end
    endtask

    reg [LANES-1:0] rmask;
    reg [4:0]       ry, rxb;
    integer         nchunk, i, it;

    initial begin
        reset=1; wr_valid=0; wr_we='0; wr_y=0; wr_x=0; wr_tag=0; wr_invw='0; wr_pt=0;
        clr_valid=0; clr_addr=0; clr_depth=0; clr_tag=0; pbc_valid=0; pbc_addr=0;
        rdg_valid=0; rdg_group=0; wr_buf='0; rd_buf='0; wid=0;
        for (i = 0; i < 1024; i = i + 1) begin m_tag[i]=0; m_val[i]=0; m_wid[i]=-1; end
        repeat (3) @(posedge clk);
        reset=0; @(posedge clk); #1;

        // ---- A) CLEAR walk: one write per chunk, so the ONLY boundaries in the whole
        // tile are the chunk starts. Interior lanes must report none.
        clear_whole_tile(32'h0BAD_F00D);
        check_all("A clear");

        // ---- B) a run, then a WIDER run that swallows its boundary. The inner boundary
        // must disappear: this is what a set-only edge bit could not do.
        do_raster(5'd4, 5'd0, LANES'(1) << 2, 32'hAAAA_0001);       // single pixel at lane 2
        check_all("B one-px");
        do_raster(5'd4, 5'd0, {LANES{1'b1}}, 32'hAAAA_0002);        // cover the whole chunk
        check_all("B swallow");

        // ---- C) interior holes: lanes that FAILED the depth test are not written, so the
        // pixel under the hole keeps the OLD fragment and both of its sides are boundaries.
        do_raster(5'd5, 5'd0, {LANES{1'b1}}, 32'hBBBB_0001);        // lay down a full run
        check_all("C base");
        if (LANES >= 8) begin
            do_raster(5'd5, 5'd0, LANES'('b0110_1101), 32'hBBBB_0002);  // two interior gaps
            check_all("C holes");
            do_raster(5'd5, 5'd0, LANES'('b1000_0001), 32'hBBBB_0003);  // both ends only
            check_all("C ends");
        end else begin
            do_raster(5'd5, 5'd0, LANES'('b0101), 32'hBBBB_0002);
            check_all("C holes");
        end

        // ---- pbc walk over a chunk that currently holds several runs: collapses it back
        // to one run of tag 0, so every interior boundary must go away again.
        do_pbc(TAW'({5'd5, 5'd0} >> BW));
        check_all("C pbc");

        // ---- D) randomized soak over the whole tile, checked after every write.
        // check_all is 1024/GW cycles, so the soak is throttled to keep the run short
        // while still checking often enough to localize a failure.
        nchunk = 1024/LANES;
        for (it = 0; it < NRAND; it = it + 1) begin
            rmask = LANES'(rnd());
            ry    = 5'(rnd());
            rxb   = 5'((rnd() % (32/LANES)) * LANES);
            case (rnd() % 16)
                0:       do_clear(TAW'(rnd() % nchunk), 32'h0BAD_F00D);
                1:       do_pbc  (TAW'(rnd() % nchunk));
                default: do_raster(ry, rxb, rmask, rnd());
            endcase
            if ((it % 250) == 249) check_all($sformatf("D rand@%0d", it));
        end
        check_all("D final");

        if (errs == 0)
            $display("spanedge_selftest PASS (LANES=%0d COPIES=%0d GW=%0d)", LANES, COPIES, GW);
        else
            $display("spanedge_selftest FAIL: %0d errors (LANES=%0d COPIES=%0d GW=%0d)",
                     errs, LANES, COPIES, GW);
        if (errs != 0) $fatal(1);
        $finish;
    end
endmodule
