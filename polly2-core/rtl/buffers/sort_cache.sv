//
// sort_cache - peel "fully rendered" triangle filter (the sorting cache).
//
// One entry per (tag mod 128) in WAYS ways, one way per ISP raster lane. The
// entry tracks the predicate "this triangle can never be selected by a future
// peel pass":
//
//   ENTER  (triangle issued to the rasterizer): presume done - write {tag, 1}
//          into ALL ways, replacing whatever aliased there.
//   DEMOTE (a raster lane sees the triangle LOSE a pixel it could still need -
//          its resident tag displaced by a closer candidate, or the incoming
//          candidate rejected while still BEHIND the peel boundary): write
//          {tag, 0} into THAT LANE's way only.
//
// A triangle whose ways all still hold {tag, 1} at the end of a pass kept
// every pixel it touched (or was already peeled there) - it has been fully
// rendered, and the NEXT pass can skip it before parameter fetch/setup.
//
//   CHECK  : registered read of all ways; done = every way matches the tag
//            with its bit set. Any mismatch (alias replaced it, a lost enter,
//            a demote) reads as "not done" -> render. All failure modes are
//            conservative.
//
// SINGLE write port per way: way w's demote and the enter broadcast share it,
// DEMOTE WINS on a same-cycle conflict. A swallowed enter leaves a stale or
// partial entry -> the all-way agreement test fails -> the triangle renders
// (safe). A swallowed demote could false-skip live geometry, so it must never
// lose. Causality guarantees a triangle's own enter precedes its own demotes
// (its tag can only be displaced after it was rasterized, 30+ cycles after
// issue), so "demote wins" never reorders a single triangle's own history.
//
// Caller rules (peel_core):
//   * consult CHECK only from the SECOND peel pass of a tile onward: every
//     triangle checked in pass p>=1 was entered/demoted in pass p-1 of the
//     SAME tile, so cross-tile / cross-frame staleness self-corrects through
//     the tag compare (an aliased-away entry mismatches -> renders).
//   * check at the point where the previous pass's raster is COMPLETE for
//     this tile (e.g. the fetch-FIFO consume side): the A/B pre-walk overlaps
//     the previous pass, so a check made mid-pass could read a not-yet-demoted
//     entry and skip a triangle that is still going to lose a pixel.
//   * allow 1 cycle after the last demote write before trusting a check (the
//     registered read of a same-edge write returns the OLD entry).
//   * do NOT demote when the displaced resident is the SetTagToMax filler -
//     only real triangle tags carry state here.
//
// INDEX: param_offs_in_words[6:0] ^ tag_offset (tag[9:3] ^ tag[2:0]) - the
// record address XOR the triangle-within-record offset, so the (up to 6)
// members of one strip land in different sets instead of fighting over one,
// while different records still spread by address. The index is a hash, not a
// slice, so each way stores the FULL tag for the agreement compare.
//
// WAYS x M10K (128 x 33 each): {done, tag[31:0]}.
//
module sort_cache #(
    parameter integer TAGW = 32,
    parameter integer IXW  = 10,               // 1024 entries
    parameter integer WAYS = 4                // one demote port per raster lane
)(
    input                   clk,
    input                   reset,
    output                  ready,            // low during the invalidate sweep

    // ---- ENTER / broadcast: {en_tag, done=1} into all ways ----
    input                   en_valid,
    input  [TAGW-1:0]       en_tag,

    // ---- WAY demote: lane w lost this tag -> {its wr_tag slice, done=0} in way w ----
    // (flat bus, house style - Quartus dislikes unpacked-array ports across modules)
    input  [WAYS-1:0]       wr_valid,
    input  [WAYS*TAGW-1:0]  wr_tag,

    // ---- CHECK: result 1 cycle later; chk_done=1 -> skip this triangle ----
    input                   chk_valid,
    input  [TAGW-1:0]       chk_tag,
    output reg              chk_valid_q,
    output                  chk_done
);
    localparam integer NENT = 1 << IXW;
    localparam integer SW   = 1 + TAGW;            // {done, full tag}

    // set index: param_offs_in_words[IXW-1:0] ^ tag_offset (zero-extended)
    function automatic [IXW-1:0] idx(input [TAGW-1:0] t);
        idx = t[IXW-1+3:3] ^ {{(IXW-3){1'b0}}, t[2:0]};
    endfunction

    // post-reset sweep: entries power up unknown; a garbage {tag,1} would
    // false-skip, so invalidate every entry once (like the tex$ S_RST walk).
    reg [IXW:0] rst_i;
    assign ready = rst_i[IXW];
    always @(posedge clk) begin
        if (reset)      rst_i <= '0;
        else if (!ready) rst_i <= rst_i + 1'b1;
    end

    // registered check tag, compared against the registered way reads below.
    reg [TAGW-1:0] q_tag;
    always @(posedge clk) begin
        if (reset) chk_valid_q <= 1'b0;
        else begin
            chk_valid_q <= chk_valid && ready;
            q_tag       <= chk_tag;
        end
    end

    wire [WAYS-1:0] way_done;
    assign chk_done = &way_done;

    genvar gw;
    generate
      for (gw = 0; gw < WAYS; gw = gw + 1) begin : way
        (* ramstyle = "M10K, no_rw_check" *) reg [SW-1:0] mem [0:NENT-1];

        // one write port: sweep, else this way's demote, else the enter broadcast.
        wire [TAGW-1:0] wtag = wr_tag[TAGW*gw +: TAGW];
        wire            wv = !ready || wr_valid[gw] || en_valid;
        wire [IXW-1:0]  wa = !ready        ? rst_i[IXW-1:0]
                           : wr_valid[gw]  ? idx(wtag)
                           :                 idx(en_tag);
        wire [SW-1:0]   wd = !ready        ? {SW{1'b0}}
                           : wr_valid[gw]  ? {1'b0, wtag}
                           :                 {1'b1, en_tag};

        reg [SW-1:0] rq;
        always @(posedge clk) begin
            if (wv) mem[wa] <= wd;
            rq <= mem[idx(chk_tag)];
        end

        // agreement: registered read matches the registered tag with done set.
        assign way_done[gw] = (rq == {1'b1, q_tag});
      end
    endgenerate

`ifndef SYNTHESIS
    // stats: how much the filter would save, and how often an enter lost its slot.
    integer st_enter, st_demote, st_check, st_skip, st_enter_lost;
    always @(posedge clk) begin
        if (reset) begin
            st_enter<=0; st_demote<=0; st_check<=0; st_skip<=0; st_enter_lost<=0;
        end else begin
            if (en_valid && ready)         st_enter  <= st_enter + 1;
            if (chk_valid_q)               st_check  <= st_check + 1;
            if (chk_valid_q && chk_done)   st_skip   <= st_skip + 1;
            st_demote <= st_demote + $countones(wr_valid);
            if (en_valid && ready && (|wr_valid)) st_enter_lost <= st_enter_lost + 1;
        end
    end
    final $display("=== SORT$ %m: enters=%0d demotes=%0d checks=%0d SKIPS=%0d (enter-lost=%0d) ===",
                   st_enter, st_demote, st_check, st_skip, st_enter_lost);
`endif
endmodule
