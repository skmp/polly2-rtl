//
// isp_sort_cache - per-triangle "fully processed / nothing left visible" tracker
// for the PT/TL layer-peel (RM_TRANSLUCENT_AUTOSORT) loop. VERILATOR-ONLY for now
// (combinational-read RAM; not synthesizable as written - no M10K template).
//
// A direct-mapped, 512-entry cache indexed by the low 9 bits of the triangle's
// CoreTag (== low bits of {param_offs_in_words, tag_offset}). Each entry stores the
// FULL 32-bit CoreTag plus a 2-BIT `done` field - one bit per peel-pass PARITY. A
// ping-pong parity `pp` (toggled by the caller each pass) selects which bit is the
// PREVIOUS-pass view (read for the skip test) and which is the CURRENT-pass view
// (written this pass): read bit = done[~pp], write bit = done[pp].
//
// STICKY / MONOTONIC done: every current-pass write is an RMW that ORs in the
// PREVIOUS-pass bit -> done[pp] <= done[~pp] | new_bit. So once a triangle is marked
// done in some pass it STAYS done in every later pass automatically (no explicit
// skip-forward copy, no A/B buffer swap):
//   * RS_POP provisional  : new_bit=1 -> done[pp] = prev|1 = 1
//   * clear (displace/win/more): new_bit=0 -> done[pp] = prev|0 = prev
//   * skip (prev done)    : new_bit=1 (or via prev|.. ) -> stays 1, carried forward
// The LAST write of a triangle's raster wins: if any clear fired, done[pp]=prev; if
// only the provisional-1 fired (won nothing, never displaced), done[pp]=1.
//
// Reads: 2 combinational read ports (skip-test on port lk; write-RMW reads prev of
// the tag being written, per write lane). A HIT requires an exact full-tag match on a
// LIVE entry (current generation), so an index collision from a different triangle is
// a MISS. Bulk clear bumps a generation counter (per-tile) so every entry goes stale
// in one cycle (Verilator can't non-blocking-reset an array in a loop).
//
`ifndef SYNTHESIS
module isp_sort_cache #(
    parameter integer ENTRIES = 512,
    parameter integer IDXW    = 9,           // clog2(ENTRIES)
    parameter integer WLANES  = 6,           // per-cycle RMW write lanes
    parameter integer GENW    = 16,          // generation counter width
    parameter [31:0]  INVALID = 32'hFFFFFFFF // sentinel core tag (never a real tag)
) (
    input             clk,
    input             reset,

    // ---- ping-pong pass parity: read = done[~pp], write = done[pp] ----
    input             pp,

    // ---- bulk clear (per-tile): bump generation -> all entries stale ----
    input             clr,

    // ---- SKIP-TEST read port (combinational): hit + prev-pass done bit ----
    input      [31:0] lk_tag,
    output            lk_hit,
    output            lk_done,                // done[~pp] of a live matching entry

    // ---- RMW WRITE lanes: done[pp] <= done[~pp] | new_bit, install tag+gen.
    // Each lane is (valid, tag, bit). Lanes target (usually) DIFFERENT tags. If two
    // lanes hit the SAME index this cycle, the HIGHEST-numbered valid lane wins (last
    // write); its new_bit still ORs the prev-pass bit. ----
    input      [WLANES-1:0]    w_valid,
    input      [32*WLANES-1:0] w_tag,
    input      [WLANES-1:0]    w_bit
);
    // storage: {gen, tag[31:0], done[1:0]} per entry
    reg [31:0]     e_tag  [0:ENTRIES-1];
    reg [1:0]      e_done [0:ENTRIES-1];      // [0]=parity0 view, [1]=parity1 view
    reg [GENW-1:0] e_gen  [0:ENTRIES-1];
    reg [GENW-1:0] cur_gen;

    function automatic [IDXW-1:0] idx(input [31:0] t);
        idx = t[IDXW-1:0];
    endfunction
    function automatic live(input [IDXW-1:0] i, input [31:0] t);
        live = (e_gen[i] == cur_gen) && (e_tag[i] == t) && (t != INVALID);
    endfunction
    // previous-pass done bit for a (possibly not-yet-live) entry: 0 if the entry is
    // stale or a different tag (a fresh triangle has no prior-pass done).
    function automatic prevbit(input [IDXW-1:0] i, input [31:0] t);
        prevbit = live(i, t) ? e_done[i][~pp] : 1'b0;
    endfunction

    // ---- SKIP-TEST read (port 1) ----
    wire [IDXW-1:0] lk_i = idx(lk_tag);
    assign lk_hit  = live(lk_i, lk_tag);
    assign lk_done = lk_hit && e_done[lk_i][~pp];

    integer w;
    reg [31:0]     wt;
    reg [IDXW-1:0] wi;
    reg            nb;
    always @(posedge clk) begin
        if (reset)      cur_gen <= '0;
        else if (clr)   cur_gen <= cur_gen + 1'b1;

        if (!reset) begin
            // RMW write lanes. Lowest-to-highest so the highest valid lane to a given
            // index writes last (wins). Each lane reads the PREV-pass bit (port 2..) of
            // its own tag and ORs new_bit; writes the CUR-pass bit, installs tag+gen.
            for (w = 0; w < WLANES; w = w + 1) begin
                wt = w_tag[32*w +: 32];
                wi = idx(wt);
                nb = w_bit[w] | prevbit(wi, wt);   // sticky: prev==1 keeps 1
                if (w_valid[w] && wt != INVALID) begin
                    e_tag [wi]     <= wt;
                    e_gen [wi]     <= cur_gen;
                    e_done[wi][pp] <= nb;          // current-pass bit
                    // If the entry was STALE (first live write this generation), its OTHER
                    // (prev-pass) bit is garbage/uninitialized. Force it to 0 so a later
                    // same-pass write to THIS entry reads prev=0 (not stale junk). Without
                    // this, a triangle's provisional-1 write makes the entry live, then its
                    // win/displace clear reads a garbage prev bit and wrongly stays done.
                    if (!live(wi, wt))
                        e_done[wi][~pp] <= 1'b0;
                end
            end
        end
    end
endmodule
`endif
