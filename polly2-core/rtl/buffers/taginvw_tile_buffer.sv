//
// taginvw_tile_buffer - the ISP->TSP handoff buffer: the TSP-facing SLICE of the
// peel depth/tag buffer, split out so it can be MULTI-BUFFERED independently of the
// ISP-private u_peel scratch (depth/depth2/tag2 + compare + PeelBuffers RMW).
//
// It holds only the three fields TSP shade actually reads - {valid, tag, invW} -
// and is WRITTEN as a DUPLICATE of peel_tile_buffer's stage-B accept (same write
// data, same enable) plus the CLEAR walk. It has NO depth compare, no depth2/tag2,
// and no PeelBuffers walk: those stay ISP-private in u_peel. Because ISP already
// decided which lanes pass (peel_tile_buffer computes b_pass_lp / ras_pass_op),
// this module is told directly which lanes to write and what to write - it is a
// pure banked store, not a compare.
//
// Storage: ONE simple-dual-port tile_ram, WIDTH = 65 bits/lane {pt, valid, tag[31:0],
// invW[30:0]}, NBANKS = LANES. invW is a 31-bit SIGN-STRIPPED float (depths are
// always positive non-zero). Same banking as peel_tile_buffer: bank = x[BW-1:0],
// addr = {buf, y[4:0], x[4:BW]}. One read port (shade single-pixel | spanner group)
// + one write port (raster stage-B duplicate | CLEAR | PeelBuffers walk).
//
// COPIES = the OVERSIZE factor: this ONE buffer holds COPIES independent tile
// images ("quarters" at COPIES=4), selected by the TOP address bits - wr_buf for
// every write client, rd_buf for every read client. Because the underlying bank is
// simple-dual-port, the producer (ISP) writes copy wr_buf while the consumer
// (spanner) reads copy rd_buf in the SAME cycle. This REPLACES the old two-instance
// ping-pong: peel_core keeps one ready-credit bit per copy and only stalls the ISP
// when the copy it wants to write is still owned by a reader, so with COPIES=4 the
// ISP may run three passes ahead instead of one.
//
// The two ports are independent, but each port still has at most ONE client per
// cycle (the peel_core credit handshake serializes them); the module asserts this
// for the write port (sim). wr_buf/rd_buf may be equal only when peel_core knows
// no reader is live on that copy (e.g. COPIES==1 degenerates to the old single
// buffer); the RAM is read-first, so a same-address collision would return stale
// data rather than corrupt state.
//
module taginvw_tile_buffer import tsp_pkg::*; #(
    parameter integer LANES  = 8,
    parameter integer COPIES = 1,                // 1, 2, 4, 8, ... tile images
    // REG_WRITE=1 puts ONE pipeline register on the whole write port ({we, waddr,
    // wdata} together, so they cannot desynchronize). See the WRITE PORT PIPELINE
    // comment below for why this exists and what it costs. 0 restores the old
    // fully-combinational write (kept so the tb can diff the two).
    parameter bit     REG_WRITE = 1'b1,
    // sim-only: the REG_WRITE read/write collision check at the bottom of this file.
    // Only taginvw_regwrite_selftest turns it off, to probe the stale read on purpose.
    parameter bit     CHK_COLLIDE = 1'b1
) (
    input                       clk,
    input                       reset,

    // ---- copy (buffer image) select: TOP bits of the RAM address ----
    // wr_buf applies to ALL write clients (raster duplicate / CLEAR / pbc walk),
    // rd_buf to ALL read clients (shade single-pixel / spanner 4-wide group).
    input      [(COPIES>1 ? $clog2(COPIES) : 1)-1:0] wr_buf,
    input      [(COPIES>1 ? $clog2(COPIES) : 1)-1:0] rd_buf,

    // ---- RASTER stage-B duplicate: write {valid,tag,invW} for the passing lanes ----
    // wr_we[l] is peel_tile_buffer's per-lane accept for lane l (already masked by
    // inside/pass), wr_y/wr_x the chunk (LANES-aligned), wr_invw the per-lane invW.
    input                       wr_valid,       // any lane may write this cycle
    input      [LANES-1:0]      wr_we,          // per-lane write-enable (accept)
    input      [4:0]            wr_y,
    input      [4:0]            wr_x,           // chunk base (LANES-aligned)
    input      [31:0]           wr_tag,         // fragment CoreTag (same for all lanes)
    input      [31*LANES-1:0]   wr_invw,        // per-lane invW (flat, sign-stripped)
    input                       wr_pt,          // PT-list won (b_which==0): the blend's
                                                // PT alpha-test enable, captured HERE at
                                                // raster stage-B (dt_pt is stale by the
                                                // time the decoupled reader blends).

    // ---- CLEAR: write {valid=1, tag=bg, invW=bg_depth} to all banks at clr_addr ----
    // (refsw ClearBuffers sets tagStatus.valid=true so the OP shade fills col_buf
    //  with the background color.)
    input                       clr_valid,
    input      [10-$clog2(LANES)-1:0] clr_addr,
    input      [30:0]           clr_depth,      // background invW/depth
    input      [31:0]           clr_tag,        // background CoreTag

    // ---- PEELBUFFERS valid-clear walk: mirror u_peel's per-pass reset of the staged
    // bit. u_peel's PeelBuffers RMW sets valid<-0 across the whole tile between peel
    // passes; since shade now reads THIS buffer, it must be cleared the same way (else
    // pass P+1 re-shades pass P's staged pixels). We only clear valid (tag/invW are
    // overwritten by the next pass's raster accepts before they're read). ----
    input                       pbc_valid,
    input      [10-$clog2(LANES)-1:0] pbc_addr,

    // ---- SHADE: single-pixel read (id = {y[4:0], x[4:0]}) ----
    input                       sh_rd_valid,
    input      [9:0]            sh_rd_id,
    output reg                  sh_valid,       // staged-this-pass bit  (1-cyc latency)
    output reg [31:0]           sh_tag,         // pending tag           (1-cyc latency)
    output reg [30:0]           sh_depth,       // depthBufferA (invW)   (1-cyc latency)
    output reg                  sh_pt,          // PT-list-won bit       (1-cyc latency)

    // ---- SPANNER: 4-wide ALIGNED read (group = x & ~3). FIXED 4-wide regardless of
    // LANES (the spanner is not lane-count-parameterized): the aligned pixels {g..g+3}
    // occupy 4 CONSECUTIVE banks starting at bank (g[BANK_BITS-1:0] & ~3) - all of the
    // chunk when LANES==4, the g[2]-selected half of the 8-bank chunk when LANES==8 -
    // so one read of all banks at addr {g[9:5], g[4:BANK_BITS]} returns the whole
    // group. Lane l = pixel (g|l). 1-cyc latency.
    input                       rd4_valid,
    input      [9:0]            rd4_group,
    output     [3:0]            g4_valid,
    output     [31:0]           g4_tag  [0:3],
    output     [30:0]           g4_invw [0:3],
    output     [3:0]            g4_pt
);
    localparam integer NB        = LANES;
    localparam integer BANK_BITS = $clog2(LANES);   // 3 for 8, 2 for 4
    localparam integer TAW       = 10 - BANK_BITS;   // in-tile addr width (7 / 8)
    localparam integer CB        = (COPIES > 1) ? $clog2(COPIES) : 0;  // copy-select bits
    localparam integer AW        = CB + TAW;         // per-bank addr width

    // Parameter sanity. Written as a time-0 procedural check under `ifndef SYNTHESIS`
    // rather than as elaboration-time $error inside a generate: Quartus does not accept
    // SystemVerilog elaboration system tasks there (10170), and every parameter
    // combination peel_core can instantiate is covered by a tb that runs this at time 0.
`ifndef SYNTHESIS
    initial begin
        if (COPIES & (COPIES - 1))
            $error("taginvw_tile_buffer: COPIES must be a power of two (got %0d)", COPIES);
        // (the old GW group-width checks are gone with the parameter: the spanner
        //  read port is FIXED 4-wide regardless of LANES - see the rd4_* comment.)
    end
`endif
    localparam integer TW_INVW   = 0;    // [30:0] depthBufferA (invW, sign-stripped)
    localparam integer TW_TAG    = 31;   // [31:0] tagBufferA
    localparam integer TW_VALID  = 63;   // [0]    tagStatus.valid
    localparam integer TW_PT     = 64;   // [0]    PT-list-won (blend alpha-test enable)
    localparam integer TI_W      = 65;

    reg  [NB-1:0]        we;
    reg  [AW*NB-1:0]     waddr;
    reg  [AW*NB-1:0]     raddr;
    reg  [TI_W*NB-1:0]   wdata;
    wire [TI_W*NB-1:0]   rdata;

    // -------------------- WRITE PORT PIPELINE --------------------
    // THE WRITE ENABLE ARRIVES FROM A DEPTH COMPARE THAT ARRIVES FROM AN M10K READ.
    // wr_we is peel_tile_buffer's stage-B accept (ras_pass_lp), which is combinational
    // off ITS tile_ram's read data through isp_depth_cmp_lp's compare chain. Unregistered,
    // that made peel M10K rdata -> 5-level compare -> we[] mux -> THIS M10K's write-enable
    // pin one single-cycle path: 11.3 ns, -5.391 at 143 MHz - the worst path in the whole
    // design, ending on an M10K WE (2.478 ns of setup) after 2.07 ns of route.
    //
    // Registering it is sound because this buffer is a pure DUPLICATE store: unlike u_peel
    // it never reads its own contents to decide a write, so there is no read-modify-write
    // loop to close and the write can simply land a cycle later. The one thing that must
    // hold is that no READER touches a copy within a cycle of its last write - the tile_ram
    // is read-first, so a read landing on the same cycle as the delayed write returns
    // stale data. peel_core guarantees it: the per-copy ti_ready credit is only asserted
    // from states gated on `consumer_idle && fq_empty` (raster fully drained), and the TSP
    // side cannot issue its first read until the cycle after it observes that credit. The
    // assertion at the bottom of this file states the invariant directly and runs on every
    // scene in golden-check.
    reg  [NB-1:0]        we_q;
    reg  [AW*NB-1:0]     waddr_q;
    reg  [TI_W*NB-1:0]   wdata_q;
    always @(posedge clk) begin
        if (reset) we_q <= '0;
        else       we_q <= we;
        waddr_q <= waddr;
        wdata_q <= wdata;
    end
    wire [NB-1:0]      ram_we    = REG_WRITE ? we_q    : we;
    wire [AW*NB-1:0]   ram_waddr = REG_WRITE ? waddr_q : waddr;
    wire [TI_W*NB-1:0] ram_wdata = REG_WRITE ? wdata_q : wdata;

    tile_ram #(.WIDTH(TI_W), .NBANKS(NB), .COPIES(COPIES)) u_ram (
        .clk(clk), .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
        .raddr(raddr), .rdata(rdata)
    );

    // copy-select as an address OFFSET (copy << TAW), i.e. the TOP CB bits of the
    // bank address. Written as a shift rather than a concatenation so it degenerates
    // cleanly to a constant 0 when COPIES==1 (CB==0, no copy bits at all).
    wire [AW-1:0] wbase = (COPIES > 1) ? (AW'(wr_buf) << TAW) : {AW{1'b0}};
    wire [AW-1:0] rbase = (COPIES > 1) ? (AW'(rd_buf) << TAW) : {AW{1'b0}};

    // broadcast one AW-bit bank address {copy, in-tile addr} onto all NB banks
    function automatic [AW*NB-1:0] bcast_addr(input [AW-1:0] a);
        integer b;
        begin
            bcast_addr = '0;
            for (b = 0; b < NB; b = b + 1) bcast_addr[AW*b +: AW] = a;
        end
    endfunction
    // ... for a raster chunk: {wr_buf, {y[4:0],x[4:0]} >> BANK_BITS}. The in-tile
    // part is the 10-bit pixel index shifted past the bank bits taken as ONE slice,
    // not {y, x[4:BANK_BITS]}: at LANES=32 a chunk is a whole row and that inner
    // slice goes zero-width.
    function automatic [AW*NB-1:0] pack_addr(input [4:0] y, input [4:0] xchunk);
        reg [9:0] pix;
        begin
            pix = {y, xchunk};
            pack_addr = bcast_addr(wbase | AW'(pix[9:BANK_BITS]));
        end
    endfunction

    // -------------------- READ port (single-pixel OR 4-wide aligned group) --------------
    always @(*) begin
        raddr = '0;
        if (rd4_valid)        raddr = bcast_addr(rbase | AW'(rd4_group[9:BANK_BITS]));
        else if (sh_rd_valid) raddr = bcast_addr(rbase | AW'(sh_rd_id [9:BANK_BITS]));
    end

    // 4-wide group outputs: select the 4-bank slice holding the aligned group
    // (combinational off the registered read rdata, 1-cyc after rd4_group presented).
    // The slice base is the group's position within the LANES-bank chunk - constant 0
    // when LANES==4, the latched g[2] half-select when LANES==8 (latched at the read,
    // like sh_lane_r, so it tracks the registered rdata). G4B stays 1 bit when
    // LANES==4 so the declarations elaborate; the base is then forced to 0.
    localparam integer G4B = (BANK_BITS > 2) ? BANK_BITS - 2 : 1;
    reg [G4B-1:0] g4_half_r;
    always @(posedge clk) begin
        if (reset) g4_half_r <= '0;
        else if (rd4_valid) g4_half_r <= (BANK_BITS > 2) ? rd4_group[2 +: G4B] : '0;
    end
    genvar gl;
    generate
      for (gl = 0; gl < 4; gl = gl + 1) begin : g4lane
        wire [TI_W-1:0] lw = rdata[TI_W*(4*g4_half_r + gl) +: TI_W];
        assign g4_valid[gl] = lw[TW_VALID];
        assign g4_pt   [gl] = lw[TW_PT];
        assign g4_tag  [gl] = lw[TW_TAG  +: 32];
        assign g4_invw [gl] = lw[TW_INVW +: 31];
      end
    endgenerate

    // -------------------- WRITE port mux --------------------
    integer cw;
    always @(*) begin
        we    = '0;
        waddr = '0;
        wdata = '0;

        if (clr_valid) begin                       // CLEAR: {valid=0,tag,invW} all banks
            we    = {NB{1'b1}};
            waddr = bcast_addr(wbase | AW'(clr_addr));
            for (cw = 0; cw < NB; cw = cw + 1) begin
                wdata[TI_W*cw + TW_INVW +: 31] = clr_depth;
                wdata[TI_W*cw + TW_TAG  +: 32] = clr_tag;
                // valid<-0, MATCHING the old u_peel CLEAR (it left PW_VALID at the
                // wdata='0 default). OP shade ignores valid (shades every pixel); the
                // PEEL passes gate on valid, so a CLEAR-set valid=1 would make peel
                // passes shade background pixels the reference skips (extra shading +
                // plane-cache misses). Keep it 0.
                wdata[TI_W*cw + TW_VALID]      = 1'b0;
            end
        end else if (pbc_valid) begin              // PeelBuffers valid-clear walk
            // Blind-write valid=0 (tag/invW become 0 but are never read while valid=0;
            // the next peel pass's raster accept overwrites all three before any read).
            we    = {NB{1'b1}};
            waddr = bcast_addr(wbase | AW'(pbc_addr));
            // wdata already all-zero from the reset above -> valid=0, tag=0, invW=0.
        end else if (wr_valid) begin               // stage-B accept duplicate
            waddr = pack_addr(wr_y, wr_x);
            for (cw = 0; cw < NB; cw = cw + 1) begin
                we[cw] = wr_we[cw];
                wdata[TI_W*cw + TW_INVW +: 31] = wr_invw[31*cw +: 31];
                wdata[TI_W*cw + TW_TAG  +: 32] = wr_tag;
                wdata[TI_W*cw + TW_VALID]      = 1'b1;
                wdata[TI_W*cw + TW_PT]         = wr_pt;   // PT-list-won (same for all lanes)
            end
        end
    end

    // -------------------- SHADE single-pixel read output --------------------
    // 1-cycle latency: sh_rd_valid presented this cycle -> fields next cycle.
    reg [BANK_BITS-1:0] sh_lane_r;
    always @(posedge clk) begin
        if (reset) sh_lane_r <= '0;
        else if (sh_rd_valid) sh_lane_r <= sh_rd_id[BANK_BITS-1:0];
    end
    always @(*) begin
        sh_valid = rdata[TI_W*sh_lane_r + TW_VALID];
        sh_tag   = rdata[TI_W*sh_lane_r + TW_TAG  +: 32];
        sh_depth = rdata[TI_W*sh_lane_r + TW_INVW +: 31];
        sh_pt    = rdata[TI_W*sh_lane_r + TW_PT];
    end

`ifndef SYNTHESIS
    integer ck;
    integer collide_cnt = 0;        // REG_WRITE read/write collisions seen (tb-visible)
    always @(posedge clk) if (!reset) begin
        if ((clr_valid + wr_valid + pbc_valid) > 1)
            $error("taginvw_tile_buffer: multiple WRITE clients (%b%b%b)",
                   clr_valid, wr_valid, pbc_valid);
        // REG_WRITE SAFETY INVARIANT. The delayed write lands on the same cycle as
        // whatever read is presented now; the RAM is read-first, so if they collide on
        // a bank address the reader silently gets stale data. peel_core's ti_ready
        // credit is supposed to make that impossible (producer copy != consumer copy,
        // and the last write precedes the credit). Check it rather than trust it -
        // this runs across all 42 golden-check scenes.
        if (REG_WRITE && (rd4_valid || sh_rd_valid))
            for (ck = 0; ck < NB; ck = ck + 1)
                if (we_q[ck] && (waddr_q[AW*ck +: AW] == raddr[AW*ck +: AW])) begin
                    // counted as well as reported, so a tb can prove the detector is
                    // live rather than merely silent (taginvw_regwrite_selftest does).
                    collide_cnt <= collide_cnt + 1;
                    if (CHK_COLLIDE)
                        $error("taginvw_tile_buffer: REG_WRITE collision - bank %0d addr %0h written (delayed) while read; reader would see stale data",
                               ck, raddr[AW*ck +: AW]);
                end
    end
`endif
endmodule
