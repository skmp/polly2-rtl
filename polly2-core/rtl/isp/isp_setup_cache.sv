//
// isp_setup_cache - direct-mapped TRIANGLE SETUP PARAMETER cache (TR/PT lists only).
//
// One entry per triangle CoreTag, payload = the COMPLETE plane-FIFO record the
// streamed setup retired for that triangle (planes, tl, isp, tag, tile-local bbox,
// PT flag). A hit lets the peel/PT pass loops skip BOTH the record's DDR fetch and
// the whole setup pass for that triangle: the iterator emits a lightweight CACHED
// triangle and peel_core injects this record straight into pq.
//
// SCOPE: entries are valid ONLY within one tile of one render. The setup anchors
// C/c_invw (and clips the bbox) at the TILE ORIGIN, so the record is tile-local by
// construction; the caller invalidates on every tile change and on render go. The
// reuse this targets is passes 2..N of the TL peel / PT resolve loops, which re-walk
// the same lists on the same tile every pass.
//
// INDEX: same construction as the sort cache - param_offs_in_words[7:0] ^
// tag_offset, so the (up to 6) members of one strip land in different sets while
// records still spread by address. Direct mapped, the FULL tag is stored for the
// compare. Probe tags are built with cache_bypass=0 (pre-fetch, the ISP word is not
// available); fills with cache_bypass=1 are REFUSED by the caller, so a cb=1
// triangle can never hit and never evicts - the ISP bit means exactly what it says.
//
// TWO SINGLE-READ RAMS, one write side:
//   * tag RAM  (IXW x 33): the PROBE side (iterator pre-fetch walk). Registered
//     read + compare, sort-cache check cadence: pr_valid -> pr_vq/pr_hit next cycle.
//   * data RAM (IXW x W) : the CONSUME side (fq-head bypass). rd_valid ->
//     rd_vq/rd_data/rd_ok next cycle.
//   Splitting them means probe and consume never contend for a port; both RAMs
//   take every accepted fill.
//
// THE PIN BITMAP is what makes "probe hit -> skip the fetch" sound. Between the
// probe verdict and the bypass consume, the triangle is in flight with NO vertex
// data - if a fill of an ALIASING tag evicted the entry meanwhile, the consume
// would have nothing to raster and no way to recover. So a surviving probe hit
// PINS its index (pin_valid, 1 cycle after the probe, tag still on pr_tag); a
// fill to a pinned index is DROPPED (fills are optional, dropping is always safe);
// the caller UNPINS on every fq pop (bypass consume or setup accept - a partial-hit
// record's pinned triangles flow through setup and unpin there). Two in-flight
// pinned triangles can never share an index: an alias of a pinned tag would have
// MISSED (the store holds the pinned tag), so one bit per index suffices.
//
// The same-edge race (a fill landing while a probe of that index is in flight, or
// on the pin edge itself) is closed CONSERVATIVELY: a fill whose index collides
// with the in-flight probe forces that probe's verdict to MISS, and the fill is
// dropped when it collides with a same-cycle pin. Both directions only cost a
// redundant fetch.
//
module isp_setup_cache #(
    parameter integer W      = 569,   // payload width (the pq record)
    parameter integer IXW    = 8,     // 256 entries
    parameter integer TAGOFF = 512    // payload bit offset of the 32-bit tag (QF_TAG)
)(
    input              clk,
    input              reset,
    input              inval,      // 1-cyc: tile change / render go - drop everything

    // ---- PROBE (iterator pre-fetch walk): verdict 1 cycle later ----
    input              pr_valid,
    input      [31:0]  pr_tag,     // cb=0 probe tag
    output reg         pr_vq,
    output             pr_hit,
    // pin the LAST PROBED tag's index (pr_tag_r - the caller's walk may already
    // present the next tag). Pulsed on the verdict cycle or the one after, only
    // for a SURVIVING hit - one that will be consumed from fq.
    input              pin_valid,

    // ---- UNPIN: every fq pop (bypass consume or setup accept) ----
    input              cl_valid,
    input      [31:0]  cl_tag,

    // ---- FILL (setup retire): dropped when pinned / racing a probe or pin ----
    input              fl_valid,
    input      [31:0]  fl_tag,
    input      [W-1:0] fl_data,

    // ---- CONSUME (fq-head bypass): data 1 cycle later ----
    input              rd_valid,
    input      [31:0]  rd_tag,
    output reg         rd_vq,
    output     [W-1:0] rd_data,
    output             rd_ok       // stored tag matches rd_tag (pins make a miss
                                   // impossible by construction; sim asserts it)
);
    localparam integer NENT = 1 << IXW;

    // set index: param_offs_in_words[IXW-1:0] ^ tag_offset (sort-cache construction)
    function automatic [IXW-1:0] idx(input [31:0] t);
        idx = t[IXW-1+3:3] ^ {{(IXW-3){1'b0}}, t[2:0]};
    endfunction

    // ---- valid / pin bits (flops: single-cycle flash invalidate, no sweep) ----
    reg [NENT-1:0] vld, pin;

    // ---- fill acceptance ----
    // dropped when the target index is pinned, or collides with the probe now in
    // flight / the pin landing this edge (see header).
    wire [IXW-1:0] fl_i = idx(fl_tag);
    reg            pr_infl;                  // a probe verdict is being formed
    reg [31:0]     pr_tag_r;                 // last probed tag (verdict + pin cycles)
    wire           fl_race = (pr_infl || pin_valid) && (fl_i == idx(pr_tag_r));
    wire           fl_go   = fl_valid && !pin[fl_i] && !fl_race;

    // ---- tag RAM (probe side) ----
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] tram [0:NENT-1];
    reg [31:0] t_q;
    reg        pr_hit_r;
    always @(posedge clk) begin
        if (fl_go) tram[fl_i] <= fl_tag;
        t_q <= tram[idx(pr_tag)];
    end
    always @(posedge clk) begin
        if (reset) begin pr_vq <= 1'b0; pr_infl <= 1'b0; end
        else begin
            pr_vq   <= pr_valid;
            pr_infl <= pr_valid;
        end
        // pr_tag_r loads only WITH a probe, so it still names the probed tag on
        // the verdict cycle AND the pin cycle after it (the caller's walk may
        // already present the next tag by then).
        if (pr_valid) pr_tag_r <= pr_tag;
        // registered half of the verdict: entry valid, and no fill evicted it on
        // the read edge (fl_race covers the fill that lands WITH the verdict edge
        // via the drop above; this term covers one landing with the READ edge).
        pr_hit_r <= pr_valid && vld[idx(pr_tag)]
                 && !(fl_go && (fl_i == idx(pr_tag)));
    end
    // the compare half (t_q is only valid now); this is THE verdict, strobed pr_vq
    assign pr_hit = pr_hit_r && (t_q == pr_tag_r);

    // ---- data RAM (consume side) ----
    // The read register loads ONLY on rd_valid: rd_tag tracks the caller's fq head,
    // which advances right after the pop, and the caller may HOLD the read-back for
    // several cycles (pq full) - an unconditional read would re-load d_q from the
    // NEXT head's index and hand the bypass a wrong record.
    (* ramstyle = "M10K, no_rw_check" *) reg [W-1:0] dram [0:NENT-1];
    reg [W-1:0] d_q;
    reg [31:0]  rd_tag_r;
    always @(posedge clk) begin
        if (fl_go) dram[fl_i] <= fl_data;
        if (rd_valid) d_q <= dram[idx(rd_tag)];
    end
    always @(posedge clk) begin
        if (reset) rd_vq <= 1'b0;
        else       rd_vq <= rd_valid;
        if (rd_valid) rd_tag_r <= rd_tag;
    end
    assign rd_data = d_q;
    assign rd_ok   = (d_q[TAGOFF +: 32] == rd_tag_r);

    // ---- valid / pin maintenance ----
    always @(posedge clk) begin
        if (reset || inval) begin
            vld <= '0;
            pin <= '0;
        end else begin
            if (fl_go)     vld[fl_i]          <= 1'b1;
            if (pin_valid) pin[idx(pr_tag_r)] <= 1'b1;
            if (cl_valid)  pin[idx(cl_tag)]   <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // +tscdbg: full event trace (tag, idx) - the pin protocol debugging aid
    always @(posedge clk) if ($test$plusargs("tscdbg")) begin
        if (inval)                $display("[TSC] INVAL");
        if (fl_valid && fl_go)    $display("[TSC] fill  %08x @%02x", fl_tag, fl_i);
        if (fl_valid && !fl_go)   $display("[TSC] fDROP %08x @%02x (pin=%b race=%b)",
                                           fl_tag, fl_i, pin[fl_i], fl_race);
        if (pin_valid)            $display("[TSC] pin   %08x @%02x", pr_tag_r, idx(pr_tag_r));
        if (cl_valid)             $display("[TSC] unpin %08x @%02x (was=%b)",
                                           cl_tag, idx(cl_tag), pin[idx(cl_tag)]);
        if (pr_vq)                $display("[TSC] probe %08x @%02x -> %s",
                                           pr_tag_r, idx(pr_tag_r), pr_hit ? "HIT" : "miss");
        if (rd_valid)             $display("[TSC] read  %08x @%02x", rd_tag, idx(rd_tag));
    end
    integer st_pr, st_hit, st_fill, st_fdrop, st_rd, st_pin;
    always @(posedge clk) begin
        if (reset) begin st_pr<=0; st_hit<=0; st_fill<=0; st_fdrop<=0; st_rd<=0; st_pin<=0; end
        else begin
            if (pr_vq)                st_pr    <= st_pr   + 1;
            if (pr_vq && pr_hit)      st_hit   <= st_hit  + 1;
            if (fl_go)                st_fill  <= st_fill + 1;
            if (fl_valid && !fl_go)   st_fdrop <= st_fdrop+ 1;
            if (rd_vq)                st_rd    <= st_rd   + 1;
            if (pin_valid)            st_pin   <= st_pin  + 1;
            // a consume MUST find its entry - the pins guarantee it
            if (rd_vq && !rd_ok)
                $error("isp_setup_cache: consume MISS for tag %08x (pin protocol broken)",
                       rd_tag_r);
        end
    end
    final $display("=== SETUP$ %m: probes=%0d hits=%0d fills=%0d (dropped=%0d) consumes=%0d pins=%0d ===",
                   st_pr, st_hit, st_fill, st_fdrop, st_rd, st_pin);
`endif
endmodule
