# PowerVR2 CORE timing: what a console shows, what it implies, what is still to measure

Written 2026-11-20 for polly2-rtl rtl/v1. This collects everything known about the timing and the pipeline
structure of the CLX2 CORE (ISP, TSP, tile buffers, write-out) that is observable from outside the chip.
Then it proposes a clocked structure for the RTL, and lists the console probes still needed to make that
structure cycle-accurate.

The rule for rtl/v1: **timing comes from mechanisms**: stage latches, queue occupancy, comparators, bypasses,
handshakes and microsequences with fixed step counts. It does not come from latency tables. Every number below
says which mechanism should produce it. Where the mechanism is not known, the entry says so (GAP), together
with the probe that would settle it (section 9).

Sources, all read-only:

- dreamcast-tests (`<root>/dreamcast-tests`): README.md, TODO.md, pvr-tests/PIPELINE_SHAPE.md,
  **pvr-tests/timemeas/REPORT.md** (the timing report) and pvr-tests/timemeas/tables.txt (raw tables, CPU counts
  of 5 ns), and the headers of the tests named below. Logs are in fit/timemeas_logs and fit/accbuf_logs.
- ta-tests/PIPELINE_SHAPE.md and README "ta-perf": the tile accelerator (TA), which is not the CORE but shares
  video memory with it.
- refsw3 (nulldc3 branch skmp/refsw3, refsw3/refcore): refsw_tile.cpp (SpanGen, SpanSort, offsKept,
  tspAlphaStuck, NextTileAccumulationBuffers), refsw_lists.cpp (PT chunks, keep Z, write-out), pvr_isp_edge.h,
  pvr_isp_depth.h, pvr_tsp_plane.h.
- `dreamster/polly2-rtl/polly2-data/dumps/rendertimes.txt`: whole-frame render times of 63 game dumps on a
  console (pvr-renderer).
- polly2-rtl-lite (the old r6b FPGA core) and its design notes. These are **hints only**: an FPGA design, not
  the console.
- VideoLogic patents US5596685 and US5729672 (Martin Ashton). These are **hints only**.

## 0. Tags and units

| tag | meaning |
|---|---|
| **[M]** | measured on a console; the test that shows it is named |
| **[I]** | inferred: the simplest mechanism that explains several [M] facts at once |
| **[G]** | guess: fits the data, but other structures would too |
| **[H]** | hint from polly2-rtl-lite or a patent: not evidence about the console |
| **GAP** | not measured. Section 9 has the probe for each |

- **clk**: a core clock, taken to be 10 ns (100 MHz). The CPU's cycle counter (PRFC0) counts 5 ns (200 MHz);
  timemeas divides by 2. The 100 MHz is the conventional figure. It is consistent with the measured fill rate of
  1.01 clk a pixel (2.02 counts) and with the TA's one parameter word every ~10.5 ns. No test measures it
  independently (GAP, low priority).
- **counts**: 5 ns CPU cycles, as in tables.txt.
- A tile is 32 x 32 pixels. Lines are 0..31 from the tile's top, columns 0..31 from its left.
- "Pitch" means a slope: the cost each added item brings in a stream. "Latency" means a one-off delay. Almost
  every console number here is a pitch. Latencies are hidden by queues and have hardly been measured (section 9,
  T1).


## 1. Chip facts: clock, memory, tile

| fact | value | source |
|---|---|---|
| core clock | 100 MHz (10 ns) | convention, consistent with [M] fill rate 1.01 clk/px |
| CPU clock, cycle counter | 200 MHz, 5 ns | timemeas main.c |
| tile | 32 x 32 px | every test |
| region array entry | 6 words (FPU_PARAM_CFG bit 21 set: 0x0027df77) | common/pvrsetup.h |
| video memory | 8 MB, two 32-bit halves ("chips" in pvrsetup.h): 32-bit area 0x000000-0x3fffff = half 0, 0x400000-0x7fffff = half 1; the 64-bit area interleaves both halves (texture address 0x400000 in the 64-bit area = 0x200000-0x3fffff of both) | common/pvrsetup.h |
| the core's video memory clients | region array, object lists, ISP and TSP parameters, framebuffer write-out (32-bit area); textures, VQ code books and indices (64-bit area); also the TA's writes, the display's reads and the CPU | — |
| registers that shape VRAM timing, as every test and game sets them | SDRAM_REFRESH 0x20, SDRAM_ARB_CFG 0x1f, SDRAM_CFG 0x15d1c951, FB_BURSTCTRL 0x00093f39, FPU_PARAM_CFG 0x0027df77, ISP_FEED_CFG 0x00800408 (translucent cache 512, PT chunk 0x40, discard on), SPAN_SORT_CFG 0x101 | pvrsetup.h; TODO A5: their fields are untimed (GAP) |
| tests' memory layout | framebuffer at 0 (half 0); TA parameters 0x400000-0x4fff00, background 0x4fff00, object lists and region array from 0x500000 (half 1); textures in the 64-bit area from 0x400000 | pvrsetup.h |

**[I] Widths of the VRAM paths, from timing.**
- Texture reads deliver **four 16-bit words a clock** [M timemeas align2]: 64 bits a clock, the width of both
  halves together.
- The framebuffer write-out and the display read look like **one 32-bit word a clock** into one half. The
  write-out fits `max(32.66, words_per_line + ~10.5)` clocks a tile line (section 3.11): 0888 1357/32 = 42.4 =
  32 + 10.4, 888 1105/32 = 34.5 = 24 + 10.5. The display stall is ~3 us a scan line [M timemeas], and 320 words
  (640 px at 16 bpp) take 3.2 us. [G] That the framebuffer sits in one 32-bit half is what makes it 32 bits wide.

**Arbitration [M].**
- The display has priority over the core: with the display on, render times jitter in steps of ~600 counts
  (3 us, ~300 clk), once per scan line (timemeas main.c: "the core waits while it does").
- The core starves the CPU: a render still running starves the CPU's accesses to video memory, and a bulk
  upload hangs the console (dumprender/main.c, pvr-renderer). The tests reset the core (SOFTRESET bits 1:0)
  before bulk VRAM transfers.
- The TA writing during a render: not measured (GAP).
- The arbiter's policy (SDRAM_ARB_CFG): not measured (GAP).


## 2. How the timing is observed, and where it shows in results

### 2.1 Instruments [M]

| instrument | what it reads | resolution | used by |
|---|---|---|---|
| **End-of-render bits**: SB_ISTNRM (0xa05f6900) bit 2 "TSP", bit 1 "ISP", bit 0 "video", polled with interrupts and display off, the CPU's PRFC0 read when a bit appears, STARTRENDER written right after t0 | time from STARTRENDER | poll loop 140 ns (14 clk) a turn. Best of 11 renders x 3 runs: slopes over 64-256 objects repeat to 0.1 clk, single differences to ~5 clk | timemeas, accbuf timing(), ta-perf |
| **Twins** | a scene against the same scene with its polygons behind the background (the ISP's work is the same) or with no objects (the TSP's work is the same); costs are differences | as above | timemeas |
| **Inside / outside** | a modifier volume closed INSIDE_LAST against OUTSIDE_LAST; the ISP's work is the same | as above | timemeas (PT: TSP work alone, agrees with the twins to 0.1 %) |
| **Palette clock** | every pixel is palette index 0 (8 bpp, ARGB8888 entries, decal, point) while the CPU rewrites PALETTE_RAM[0] with a counter, one write per ~25 counts (12 clk); a pixel's colour is when the TSP read the entry | ~5 px (the 8888 palette costs 2 clk/px); ~1 glitch pixel a scene reads a value 116-120 writes old | timemeas TM_ORDER, order.py |
| **Races in the picture** | a picture that depends on when two units meet (deterministic or not across runs) | qualitative | accbuf(_races), blendpos(_races), keepz_races, ptchunk*_races, texctl, spansortcfg |
| **Hangs / error bits** | render never ends (harness: 2 s timeout, SOFTRESET 2 then 0); SB_ISTERR bit 0 "ISP out of cache" | — | bumphang, accbuf, spansortcfg, scalermeas, ispcache |
| **Whole frames** | STARTRENDER to each end-of-render bit for game dumps (display in the game's mode, 1 pass) | ~1 us | rendertimes.txt |

Meaning of the bits:
- **The TSP's bit (bit 2) comes at the end of the last tile's write-out** [M timemeas: it moves with the
  framebuffer format and the clip].
- **The ISP's bit (bit 1) is not the end of the ISP's work in general.** [I] It is the moment the last run of
  the last tile is cut and accepted by the run queue (section 3.5). It comes after ~160 clk a background tile
  while the queue has room (tables.txt section 10: n = 1, 2, 4, 8 tiles: 729, 1061, 1705, 2989 counts). From
  16 tiles on it comes 19,980 clk before the TSP's bit.
- **The video bit (bit 0)**: whole frames show it **80-96 clk before** the TSP's bit (rendertimes.txt: tsp_us -
  video_us = 0.80 or 0.96 us on every scene). timemeas's poll code expects it after the TSP's bit (a comment,
  not a measurement). GAP (T15).

### 2.2 What of the timing shows in results (why rtl/v1 must be clocked)

Each of these is a picture difference or a hang that depends on when units run against each other. A model
without a clock cannot reproduce it:

1. **The order of shading carries state from pixel to pixel**, and that state is visible:
   - tspAlphaStuck: a blend-unit bug state that lasts until the tile ends [M blendsel, blendsel2];
   - offsKept: the last offset colour shaded, read by bump maps without the offset bit, across tiles, renders and
     SOFTRESET [M offspersist];
   - the palette or other registers rewritten during a render [M timemeas order].
   The order comes from the span sorter (deterministic, modelled in refsw3), but with SPAN_SORT_CFG bit 0 off it
   is "near raster order with timing-dependent early runs" [M spansortcfg, unmodelled].
2. **Secondary accumulation buffer against the write-out** [M accbuf, blendpos]:
   - a polygon that reads buffer 2 (SrcSelect) while the previous tile is being written out damages that tile's
     picture in the framebuffer, somewhere else on every run;
   - a polygon that writes buffer 2 (DstSelect) waits for the write-out.
3. **Empty keep-Z tiles against the write-out** [M accbuf, keepz_races]: wrong tiles written, extra time, or a
   hang (two in a row), depending on the ISP's lead.
4. **Punch-through chunk carry** [M ptchunkcarry_races]: whether the pixels resolved by one PT chunk take part in
   the next chunk's first-pass runs. It depends on where the ISP is against the TSP; it is deterministic run to
   run and varies by cell.
5. **Texture reads from the framebuffer being written** [M texctl_bank, earlier version]: a VQ index read that
   lands in the framebuffer of the same render gives what the write-out has put there yet. 376-864 px differed on
   3 pages.
6. **Hangs and stuck states**:
   - bumphang: the render stops at the 16th non-twiddled bilinear bump quad (8th in OP/PT); the count carries
     across renders;
   - SPAN_SORT_CFG 0x100 and 0x10001 hang the core until power-off;
   - two empty keep-Z tiles in a row (written out) hang the render;
   - changing SCALER_CTL between renders stalls the next render;
   - the strip buffer left the core stuck once;
   - a region array without KallistiOS's dummy first entry "sometimes hangs" (pvrsetup.h comment).
7. **End-of-render time** itself: the frame time games see (and the scanline at which the interrupt comes).


## 3. Console facts by stage

The stages as the tests see them: tile sequencer -> ISP (list walk, setup, rasterizer, depth/tag) -> cutter ->
run queue -> span sorter -> TSP setup -> run start -> pixel pipe (texture, shade, blend) -> two tile colour
buffers -> write-out (pack, dither, scaler, clip, strip buffer). PIPELINE_SHAPE.md draws it.

### 3.1 Render start, the region array, fixed per-tile costs, stage overlap

All [M timemeas], 0888 framebuffer unless said; one tile at (0,0) alone in the region array:

| what | clk | notes |
|---|---|---|
| one tile, background only, five empty lists, STARTRENDER -> TSP's bit | 2998-3005 (0888), 2695 (16 bit), 2755 (888) | |
| the same, no list pointers | 2859-2864 (0888) | |
| a pointer to an **empty** list adds | REPORT: OP 31, OP mod 30, TR 28, TR mod 20, PT 30; tables.txt 1 (another run, pointers added in that order): 28, 28, 31, 25, 28 | **[I]** the object-list block fetch: a VRAM read latency of ~20-30 clk, not hidden |
| **B**: the background polygon of one entry (32 runs of 32 px) | 1035 (2069 counts, 1.01/px) | shaded in **every** entry, also one that draws nothing and is not written out |
| Z clear + background setup | 142 | keep Z (entry bit 30) skips both: background costs a tile 1177 = 1035 + 142 |
| a tile with nothing to do | 335 + its write-out | keep Z, five empty lists: 1820; no list pointer: 1690 |
| write-out, measured by itself | 1355 (0888) | two entries, the first written out or not |
| an entry that draws nothing (KallistiOS's dummy) | 899 as KOS writes it; **17 with keep Z** (36 counts each of four) | |
| sum check | 335 + 142 + 1035 + 1355 = 2867 against 2859-2864 measured for a background tile with no list pointers | |
| a tile in which polygons are seen | 55-90 more than a background tile, **once** whatever their number | GAP: what it is |
| first entry's ISP work hidden | with one dummy entry in front, the first ~1000 clk of the tile's ISP work are free: 16 quads +20 instead of +460; 64 quads +1123 instead of +2087 | the ISP runs on entry k+1 while the TSP shades entry k |

**Overlap [M].** The stages of consecutive region array entries overlap, so in a render of many tiles a tile
costs about the largest of its ISP, TSP and write-out times:
- first n tiles of background after a dummy entry: 1363 clk a tile at 0888 (write-out bound) and 1041.5 at 16
  bits (TSP bound: B + ~7) (tables.txt 1);
- each further tile of background: 1042 (16 bit), 1096 (888), 1358 (0888).

**[I] Mechanism.** The ISP, the TSP and the write-out are decoupled by queues and by the two tile colour
buffers. The per-tile cost "about the largest" falls out of FIFO back-pressure; no rule computes it.

**GAP:** how the 335 clk divide between the region array fetch, the ISP's start, the TSP's start and the
handovers, and what the 55-90 are. T1 (3.1a) put event times on these; it did not split them into named parts.

### 3.1a T1 results: the CORE's events on an absolute clock (2026-11-20, partial)

Probe: dreamcast-tests pvr-tests/t1stamp_clock (not committed; analysis in agents/nulldc3/hunt/t1stamp). While the
core renders, the CPU writes the time since its STARTRENDER write (PMCTR0 >> 1, clk) into FOG_COL_RAM (stamped
primitives untextured, table fog mode 2, so a pixel's RGB is the register) or into PALETTE_RAM[0] (8 bpp index 0,
decal). A pixel's stored colour is then the latest stamp the TSP read for it. Every scene is also rendered without
stamps and the end-of-render bits polled as timemeas does (B lines). One tile at (0, 0), five empty list pointers,
no entry in front of it, 0888, unless said. Runs 2, 4, 5 x 4 stamped renders a scene (scenes 69-99: run 4 only);
values are means, the ranges in tables_runs245.txt are a few clk.

How far the clock can be trusted:
- [M] Calibration (T1_SET 1): with one stamp write at least every 24 counts, the first background pixel reads
  541-546 (one render 556) at every pace 24-48 and poll interval 2-16; written back to back the stamp's lag varies by up to 28
  counts (14 clk) along a line. Runs used pace 26 (a new stamp every ~12-14 clk), so a run's start is known to a
  stamp interval and a time is the start of a run of equal pixels.
- [I] Zero point: the stamps and STARTRENDER both leave the CPU from an empty write buffer, so their write latency
  is taken to cancel. Not checked independently: all absolute times below carry that assumption; differences
  between scenes do not.
- [M] The fog stamp does not slow the core: TSP bit 2995 unstamped against 2999 fog-stamped (within the poll
  quantum). **The palette stamp does**: with 565 entries the first pixel comes 72 clk later and a tile shades in
  1094 instead of 1049 (16 tiles at 565: pitch 1101-1191 instead of 1041); 8888 entries ~2.1 clk a pixel. The plan's
  assumption that 565 palette entries run at 1.01 clk a pixel is wrong; use the fog stamp.

**Solid results [M]** (end-of-render bits from the unstamped renders, so +- the 14-clk poll quantum):

| event | clk after STARTRENDER | notes |
|---|---|---|
| ISP's bit, reference tile (background, five empty lists) | 342 | 340-347 over all runs |
| first pixel (the background's line 0), reference tile | 545.3 | 96 renders: 536-556, mode 545 |
| last pixel, reference tile | 1594 | first -> last 1049 (see "tile shade" below) |
| TSP's bit, reference tile | 2999 | 1405 after the last pixel (write-out 1355 + ~50) |
| video bit | TSP + 37 | every one-tile scene, display off. With FB_X_CLIP 0..15: TSP + 13. Not seen in some renders of scenes top and kz_row16. Whole frames (2.1) show it 80-96 *before* the TSP's bit: not reconciled (T15) |
| no list pointers (L0): ISP bit / first pixel / last / TSP bit | 202 / 403 / 1452 / 2854 | |
| first pixel after the ISP's bit, one tile whose first shaded run is the background | 184-216 | every such scene, whatever the lists and objects |

**List pointers [M].** Each pointer to an empty list delays the ISP's bit and the first pixel alike, serially:

| pointers | 0 | 1 (OP / OM / TR / TM / PT) | 2 | 3 (TR TM PT / OP OM TR) | 4 | 5 |
|---|---|---|---|---|---|---|
| first pixel | 403 | 434 / 432 / 433 / 424 / 433 | 462 | 485 / 493 | 515 | 545 |
| ISP's bit | 202 | 231 / 231 / 230 / 226 / 229 | 257 | 281 / 292 | 309 | 342 |

About 30 clk a pointer (TR mod ~22), the same as timemeas's 20-31. Keep Z with no background: five pointers against
none move the ISP's bit 133 -> 277 and the TSP's bit 1685 -> 1829, again ~29 each. [I] One list-block fetch
each, not overlapped with the next (the 7.2 "list block fetch latency").

**Entries in front [M].** KallistiOS's dummy entry (empty lists, not written out): the first pixel moves +913 for
one, +1950 for two, +4024 for four, i.e. ~1037 for each after the first; the TSP's bit +900 / +1939 / +4013 (timemeas's
899 for the first). The ISP's bit moves only +17 / +34 / +195. Keep-Z entries with no list pointer: +17.5 / +71 /
+145 for 1 / 4 / 8 (~18 each; timemeas 17). [I] The dummy's cost is its background shading (B 1035) on the TSP
side; the ISP runs ahead through it.

**Tile shade and tile-to-tile [M].**
- Reference tile: first -> last pixel 1049 (96 renders: 1048-1059). Lines start every 32-34 clk (alternating;
  line 0 -> 1: 35).
- Tiles after the first in t4 / t16 (0888, 565, cover, clip; fog-stamped): 1034-1039. Tile 0 of t16_d (a dummy entry in front):
  1034. Tile 1 of t2_isp / t2_isp565 (64 never sprites in that tile): 1052 / 1059.
  **So the 1049 is not "the first tile of a render is 14 clk longer"**: tile 0 after a dummy entry shades in
  1034, and a later tile behind heavy ISP work takes longer. [I] A tile shades in ~1035 when its runs were cut
  ahead of the TSP, and ~14+ clk longer when the TSP had to wait on the cutter; not tested beyond these scenes.
- Last pixel of tile k -> first pixel of tile k+1: 6-7 clk at 565 (pitch 1041, TSP bound, as timemeas's 1042);
  ~300-340 at 0888 (pitch 1340-1381, write-out bound, as timemeas's 1358). Tile 0 -> 1 at 0888: 7 (the second
  colour buffer is free).
- A single 1x1 sprite in a keep-Z tile is shaded at 601-607 whatever its position (0,0), (31,0), (0,31), (16,16),
  (31,31); a 32x1 row at line 0, 16 or 31 starts at 607-610 and lasts 32. Over a background, a pixel at (31,31) is
  shaded in raster order (1653). [I] The TSP does not step through lines without runs.

**Objects [M].** Against the reference tile (first pixel 545, ISP bit 342):

| scene (all in the tile's first entry, no entry in front) | first pixel | ISP's bit |
|---|---|---|
| one never-passing 1x1 sprite (never1) / opaque list only (never1_Lop, against Lop 434 / 231) | +72 / +70 | +78 / +69 |
| one 32x32 sprite over the background (cover) / opaque list only (cover_Lop) | +95 / +96 | +102 / +102 |
| N never-passing sprites, N = 1 -> 64 | +17.0 each | +16.8 each |
| a translucent never-passing sprite (trnever1) | +70 | +89 |
| a translucent or PT sprite over lines 0-15 (tr_top, pt_top): the opaque background's first pixel | 1145 (+600) | +141 |

The first object of the tile costs ~70 (never passing) to ~95 (seen) before the first pixel, against ~17 for each
further one; this is the 55-90 of 3.1, now seen as a delay in front of the first pixel and the ISP's bit.
**What it is is not measured.** A cold-versus-warm explanation (first parameter fetch, a setup started from
nothing) is [I] only, and every scene above is also the render's first tile with no entry in front, so it is
confounded with first-tile start-up. In t4_cover tile 1 also starts 96 later than t4's, but tile 1's start is
pinned by tile 0's end, so that does not separate them. T1_SET 2 (a dummy entry, then 48 never sprites, with and
without a seen sprite; t2_isp with a sprite over tile 1) was built to separate them and has not run.

**The 335 split: not established.** The stamps give times for the ISP's bit (202), the first pixel (403) and the TSP's
bit (2854) of a tile with no list pointers, and the background's 1049 between the first and last pixel. A
decomposition of the 335 into region-array fetch, ISP start, TSP start and a ~156 clk "hand-over" was proposed from
these; the hand-over is only what is left after subtracting the other terms (a residual, not an event the stamps
show), so it is not used. The 335 / 142 split of 3.1 stays [M] as totals, its parts GAP.

**The probe wedged the console.** Two runs left it with the first PVR access of every later program never
returning until a power cycle (once on start right after a clean run, once in scene 95 kz_row00_Lop, which the run
before had passed). Suspects, not isolated: ~10^5 FOG_COL / PALETTE register writes a scene during the render,
region arrays without the dummy entry, keep-Z tiles. A re-run (T1_SET 2, the rest of T1) needs a safer design
first: fewer stamp writes (stamp only around the event of interest, or a coarser pace once calibrated), the dummy
entry in front where the scene allows, and one scene per program run so a wedge loses one scene.

### 3.2 ISP: list walk, setup, rasterizer

Method: objects behind the background polygon (background depth 1, objects 0.5, compare GREATER), or compare
NEVER, or passing and covered afterwards; 64 to 256 of them; TSP's bit against background only. All three give the
same numbers to 0.1 clk.

**Per object [M timemeas ISP, tables.txt 3], clk:**

| object | clk | | object | clk |
|---|---|---|---|---|
| triangle, any size up to 16 lines, any format, any place in the tile | **16.0** | | sprite 8x8 or 1x1 | **19.0** (18.9) |
| triangle of half a pixel | 16.0 | | sprite 32x32 | 32.0 |
| triangle culled by winding / by size (FPU_CULL_VAL) | 15.1 / 15.05 (30.2 / 30.1 counts) | | strip of 6 triangles | 102.0 |
| triangle not culled (control in that run) | 15.85 | | quad 32x32 (strip of 2) | 64.0 |
| quad 8x8 / 1x1 / 32x1, textured or with offset (strip of 2) | **34.0** | | quad 1x32 | 50.0 |
| modifier volume of 2 triangles 32 lines tall, each further one | 65 (first 42-147) | | | |

- **Strips** of k triangles: 16, 34, 53, 68, 87, 102 (k = 1..6). Per added triangle 18, 19, 15, 19, 15: after the
  first, alternately ~19 and 15 (average 17).
- **Size counts only past 16 lines**, +1 a line per triangle:
  - quad 32 wide by height: 34 up to 16 lines, then 36, 42, 50, 58, 64 at 17, 20, 24, 28, 32;
  - sprite 32 tall: 32.
  - **[I]** A setup stage of ~16 clk a triangle feeds a rasterizer that does **one 32-pixel tile line a clock**.
    The two overlap, so a triangle costs about max(setup, lines). The first 16 lines hide behind the next
    triangle's setup.
- **Anomaly: thin triangles** [M tables.txt 3]. A 1-wide quad by height: 34 up to 20 lines, then 39, 45, 50 at
  24, 28, 32 lines: ~25 per triangle at 32 lines where the 32-wide quad gives 32. Each triangle of a 1x32 quad has
  corners spanning all 32 rows but covers pixel centres on ~16 of them. **GAP:** the rule for the rows a triangle
  is stepped over. It is not simply the row range floor(ymin)..floor(ymax+0.5), which is the coverage rule
  [M covmeas]: early exit on uncovered rows? x-extent? (T2).
- **Depth result is invisible in time**: failing, never passing, or passing and writing all cost the same [M].
- **First objects**: totals for N = 1, 2, 4, 8, 16, 32, 64, 128, 256 triangles behind the background are 72, 100,
  126, 156, 288, 428, 946, 1988, 4010. The first object costs 70-100, the next few little, and from ~32 on the
  total is N x slope minus 80-90 (30-60 with three lists instead of five). [I] The first objects' work runs
  beside the tile's fixed part (the TSP's background and the list fetches).
- **FPU_PERP_VAL**: the ISP's cost of a "perpendicular" triangle is not measured (TODO D4, GAP).
- **DCalcCtrl** is not seen by the ISP [M timemeas dcalc twins, within +-8 clk].
- **ISP_FEED_CFG bit 0** changes nothing with 6-word region entries [M].

**[I] What the ISP must do per triangle per tile** (from refsw3's arithmetic, section 4). Edge constants and
slopes and the depth plane are per triangle, but the edges' and the depth's **tile-start values** are per tile:
- first = dx y0 - dy x0;
- start = ((a x0 + b y0) + c) x 1/det.
Both are cut to the tile's block format. So the ~16-clk setup is redone in every tile the triangle is listed
in. [G] One 24-bit soft-float multiply-add datapath used ~12 times in a fixed sequence per triangle fits the
budget (PIPELINE_SHAPE.md [2]).

**GAP:** the microsequence behind 16 / 15 (culled) / 19 (sprite) / 19-15 alternation in strips (T2). Some
candidates to test:
- culled = stops one step early;
- sprite = a 4th edge;
- odd strip triangles = a vertex reorder (the corners are taken (v1, v3, v2), PIPELINE_SHAPE.md [2]).

### 3.3 ISP: passes, modifier volumes, ISP caches

- **Opaque list: one pass.** A modifier volume costs ISP time only (65 a 2-triangle volume) [M]. The TSP shades
  the tile once, after the modifier volumes [M timemeas inside/outside: -11 to +12 clk over 72 scenes].
- **Punch-through: the pixels inside an opaque modifier volume get a second TSP pass** [M]: a PT quad over the tile
  costs 1056 more than its twin, the same quad opaque 168. A second pass over a block costs 81 + 1.0/px untextured,
  146 + 1.0/px textured; a pass that finds nothing still costs ~300 (outside minus no volume: 370-460 for PT
  polygons). Per seen PT triangle 58 clk; a 1-pixel PT run 7.3.
- **PT chunks** [M ptchunk, ptchunkq, ptchunkm, ptchunkcost, ptchunklag]. The PT list is peeled in chunks of
  ISP_FEED_CFG's chunk size in vertices. A primitive joins the chunk while (vertices before it) + its own <=
  size - 2. **Two counter lags**, both latch-timing signatures [I]:
  - the last vertex of a quad right before it is not counted yet;
  - a culled primitive takes no room, but the next primitive is checked with the culled one's 3 vertices still
    counted, then they are gone.
  [G] The chunk occupancy register is updated one primitive late: the fit check for primitive n reads a count
  that has not yet seen the late corrections from primitive n-1 (its 4th vertex, its cull verdict).
- **Translucent sort cache** [M ispcache]: SB_ISTERR bit 0 ("ISP out of cache") from L = size/8 full-tile layers
  (sizes 64-512; 32 and below act as 32). 8x8 triangles need twice as many layers. Never at L = 256 (an 8-bit
  count?). The picture is the sorted one anyway down to size 64. [G] Capacity is in units of ~4 per triangle
  (2 triangles a sprite), possibly 3 edges + depth. Its time against size: GAP (TODO D8).
- **Translucent layers** [M tables.txt 9]: per layer and pixel ~1.02 clk untextured (12 layers against 4, ISP
  pass included). A small layer costs 52 (1x1) / 100 (8x8 or 32x1) untextured, against 39 a seen triangle: ~13
  more a layer pass. [I] Each sorted layer is an ISP pass whose own cost hides behind the TSP's 1 px/clk once the
  layer is large.
- Pre-sorted translucent: drawn in list order, no crowded-line cost (section 3.8).

### 3.4 Cutting the tag buffer into runs

A **run** (span) is a maximal stretch of pixels of one primitive on one line of a tile, in one pass, with the same
modifier-volume state where the pass cuts at volumes [M uvspan, uvrun, volrun, optrun]. Runs are up to 32 px, not
cut at fixed columns. Which pass cuts at volume edges is refsw3 SpanGen's rule.

**Cost [M timemeas cut, run 40]: one clock a run, whatever its length.**

| one tile, extra runs (ALWAYS against NEVER twins) | more runs | lines | ISP's bit later by (clk) |
|---|---|---|---|
| 1 / 2 / 4 / 6 sprites 1x32 | 64 / 128 / 256 / 384 | 32 | 61 / 126 / 252 / 383 |
| 4 sprites 1x16 | 128 | 16 | 127 |
| 8 sprites 1x8 | 128 | 8 | 126 |
| 16 sprites 1x4 (a line of 32 one-pixel runs) | 124 | 4 | 126 |
| 16 sprites 1x8 | 248 | 8 | 252 |

- 0.95-1.02 clk a run in every placement. A line of 32 one-pixel runs costs 31 more than a line that is one run,
  so a whole line is one clock when it is one run. Cutters of 8 or 4 pixels a clock would give 112 / 96 instead of
  126.
- **[I]** The line's boundaries are found at once (31 neighbour compares of tag, volume bit and valid bit), and
  runs leave one a clock, in raster order (a priority encoder over the boundary mask).
- **The ISP's end-of-render bit waits for the last tile's cutting** (sprites in the last of two tiles: the bit
  moves 130 / 254 for 128 / 256 runs).
- **Overlap with the next tile** [M, rule GAP]. Cut runs in tile 1 against W never-passing 1x1 sprites (ISP work
  only, ~19 each) in each following tile; ISP's bit, ALWAYS minus NEVER:

| following tiles | W 0 | W 8 | W 16 | W 32 |
|---|---|---|---|---|
| 128 more runs, one tile after | 70 | 19 | 35 | -2 |
| 128 more runs, two tiles after | 70 | 1 | 0 | 6 |
| 256 more runs, one tile after | 245 | 182 | 175 | 2 |
| 256 more runs, two tiles after | 238 | 89 | -5 | 0 |

  Enough ISP work after the tile hides all of the cutting. It is not a free pair of tag buffers: a background-only
  next tile hides 58 of 128 and 11 of 256. [G] One tag buffer: the next tile's setup and depth-only work
  proceeds, while its first tag write (the background fill / Z clear) waits for the cutter. That does not explain
  58 against 11 (T4).
- **[I] Empty lines**: a background tile is 32 runs and cuts in ~32 clk (part of the ~160 clk a background tile
  the ISP takes). Whether a line with no valid pixel (a later pass) costs a clock: GAP.

### 3.5 ISP -> TSP buffering, and the ISP's lead

**[M timemeas ispq, run 35]** First n tiles of the screen, each with the content below. Lead = TSP's bit minus
ISP's bit at 64 tiles. Pace = clk a tile from 32 to 64 tiles. Runs left = (lead - last write-out) x runs a tile /
pace.

| a tile | primitives | runs | lead (clk) | lead (tiles) | pace | runs left when the ISP ends |
|---|---|---|---|---|---|---|
| background, 0888 | 0 | 32 | 19986 | 14.6 | 1366 | 436 |
| background, 565 | 0 | 32 | 15250 | 14.6 | 1041 | 437 |
| one sprite over the tile | 1 | 32 | 19916 | 14.6 | 1366 | 435 |
| 2 sprites 32x16 (rows) | 2 | 32 | 19894 | 14.6 | 1366 | 434 |
| 4 sprites 32x8 (rows) | 4 | 32 | 19874 | 14.5 | 1366 | 434 |
| 2 sprites 16x32 (columns) | 2 | 64 | 10800 | 7.9 | 1365 | 443 |
| 4 sprites 8x32 (columns) | 4 | 128 | 6288 | 4.6 | 1366 | 462 |
| 32 sprites 1x32 (columns) | 32 | 1024 | 4707 | 0.7 | 7205 | 476 |
| 32 sprites 32x1 (rows) | 32 | 32 | 2882 | 1.7 | 1736 | (28: not queue-bound) |

- **What is buffered between the ISP and the shading is runs**: ~430-480 runs whatever the tile holds. It is not
  time (the 565 framebuffer gives the same 14.6 tiles), not tiles (columns 8x32 lead 4.6 tiles), and not
  primitives (4 rows of 32x8 lead 14.5 tiles where 4 columns of 8x32 lead 4.6).
- **[I]** A run queue of ~512 entries of ~40 bits (parameter tag, line, x, length, volume bit) = ~2.5 KB. When it
  is full, the cutter stalls, and with it the ISP.
- **GAP:**
  - how the ~430-480 split between the run queue proper, the sorter's window of 96 (3.6) and the run-start queue
    (3.8);
  - why longer runs buffer slightly fewer (32 px: 436, 16: 443, 8: 462, 1: 476);
  - whether a run cut in two by a nearer polygon is two entries (in the sorter it is two [M order]);
  - whether a tile boundary takes an entry (T3).
- **The ISP's bit for seen polygons in one tile** (tables.txt 10, clk later than the twin): 1 quad 32x32 +30, 4
  quads 8x32 +209, 32 quads 1x32 +5104, 1024 quads 1x1 +23753. [I] The cutter is held by the full queue until the
  TSP drains it, so the ISP's bit = the last run accepted.
- **Unexplained: 32 rows of 32x1 a tile** [M timemeas rows, pfetch, runs 36-37]. They run at 1736 clk a tile (54.3
  a row) in many tiles: more than the ISP (~19 a sprite) or the TSP (40.7 a sprite in one tile) needs alone.
  - The ISP's bit is the pace, and it leads by only ~2870 clk (one tile's TSP + write-out).
  - Format increments a row: 565 +6.7 (TSP setup +9), 565 offset +9.7 (+25), DCalcCtrl 1 -1.2 (+5); quads 78 =
    2 x 39.
  - Never-passing primitives add ~16 each.
  - Ruled out:
    - a run-counting stage: never-passing primitives make no runs and still add their ISP cost;
    - one setup unit shared by the ISP and the TSP: DCalcCtrl and offset do not add in full;
    - a parameter fetch or VRAM traffic: 4 or 8 more words a primitive add ~0; a 565 framebuffer or no
      write-out add ~0.
  - **[G]** a per-primitive handshake between the ISP and the TSP that partly serialises the ISP's ~16 with the
    TSP's ~38 (54 ~ 16 + 38). The mechanism is not known; it matters for the many-small-primitive scenes (T3).

### 3.6 The span sorter: the order of shading

**[M timemeas order, runs 38-41, 23 scenes, ~17,000 runs; order.py `sort_runs`; modelled in refsw3 SpanSort]**

- **Rule.** The tile's runs enter a window of **96 runs** in raster order as soon as there is room. Repeatedly the
  oldest run in the window chooses the primitive. That primitive and all its runs in the window are shaded, oldest
  first, including runs that enter while it lasts (each run shaded makes room for the next).
  - Out-of-order runs by window size: 92: 395/861, 94: 235/495, 95: 129/246, **96: 6/20**, 97: 150/276, 98: 247/480,
    100: 385/704 (runs 38/39).
  - At 96 what is left is glitch pixels and the early drains.
- A run takes one place whatever its length (up to 24 px tested). A window of 96 pixels, or one place per 8 or 16
  px, all fail.
- No limit on distinct primitives below 96 (limits of 64 or 32 fail).
- **Freed places are reused at once**: a circular FIFO with holes gives 485-631 out of order at 96-320 places.
  [I] The window compacts (a shift structure or an age matrix), not a ring.
- A drained primitive comes back behind every primitive whose runs came in before its next one (that is the
  oldest-run rule). A fixed sweep order fails (scenes 15, 16).
- **Each tile on its own**: the next tile's first pixel comes after this tile's last. A primitive over two tiles is
  not drained across the boundary (run 41). [I] A tile barrier, or the tile in the compare.
- The background polygon is a primitive like the others.
- **The key** [M spansortcfg]: with offset sort (SPAN_SORT_CFG bit 8, as every game sets it) the compare is of the
  parameter offset alone (ISP_BACKGND_T bits 23..3, tag offset bits 2..0 masked), so a strip's triangles are one
  primitive. Without bit 8 it is the whole tag.
- **Sweeps.** With many primitives on every line the tile is shaded in diagonal batches (32 columns of 1x32:
  each column's lines 0-3 to 0-7, then column 0 again from line 4). Each visit is a drain and a setup of its own
  (~45 clk measured, about the textured setup's 48).
- **Early drains [M, not understood, deterministic].** Some whole drains are shaded before the 2 to 9 drains in
  front of them, holding the runs the rule gives them:
  - column 31 of 32 columns of 1x16 (scenes 11, 20, 21), not of 1x32 (scenes 3, 22);
  - the background and column 0 of 16 columns over the background (scene 18).
  [G] A second drain started ahead while the first is still in the setup or run-start stage. GAP (T5).
- **[I] Hardware.** A 96-entry store of runs (~40 bits each). The head entry's key is compared against every entry
  (96 x ~24-bit comparators). Matching entries leave in age order; empty places refill from the run queue at once.
  The rate at which the sorter emits runs and takes them in is not measured (GAP, T5). It is at least the
  run-start pitch (~4 clk a run).

**SPAN_SORT_CFG [M spansortcfg, README; TODO A1]:**
- **No setting changes a picture.** The runs and their first pixels are made before the sorter; it only orders
  them (218 pages and timemeas's 17 layouts, bit for bit).
- **Bit 0 off (0x000)**: near raster order, not exactly. Some runs are shaded early:
  - 32 one-pixel columns over 16 lines: each line's last run right after its x 15;
  - 16 blocks of 8x8: the right-hand block's runs on the next lines;
  - with one pixel of another primitive at (0, 16): the next line's x 21 right after x 23 on every odd line.

  This is deterministic (at most 3 of 1024 runs move between two runs), but it is a matter of clocks: that pixel
  at (0, 31) instead, or no such pixel, gives none. At the start of a tile the setups of the first runs are done
  ahead (up to ~22 runs shaded at once), fewer the more the ISP had to do. **Unmodelled: needs the clocked
  pipeline** (T5).
- **Time with bit 0 off**: up to 4.6x.
  - One tile of 32 one-pixel columns: 12,800 clk sorted against 52,700 not.
  - 16 blocks of 8x8: 6,500 against 8,200.
  - One primitive a pixel: 70,500 either way.

  A run whose primitive is not among the **16 the TSP keeps set up** costs a setup of 44 clk, 19 more the first
  time (a parameter fetch). One of those 16 costs ~12. Which of 17 stay is not least-recently-used (scene 13
  keeps 5 of 17 from line to line). With the sorter on, a first setup is ~64 clk and a later one ~32.
- **Bit 16** (TSP cache bypass, 0x10101): same order (8 out of order against the window), time within 2 %. Its
  pictures were not compared.
- **0x100 and 0x10001 hang the core** until power-off; dcload still loads programs, and the first PVR access never
  returns. 0x100 finished timemeas pages 0-9 and hung on page 10 (64 quads 4x4); 0x10001 finished order scenes
  0-21 and hung on scene 22. The trigger is GAP (each try costs a power cycle).

### 3.7 TSP setup and the store of set-up primitives

**Cost per seen triangle [M timemeas, 1024 polygons of 1x1, both twin and inside/outside methods]:**

| polygon | clk |
|---|---|
| untextured, flat or Gouraud | 39.0 |
| textured: every format, filter, mip or not, fog, palette, 8 texels a pixel | 48.0-48.1 |
| textured with an offset colour that is **not 0** | 64.1 |
| bump map | 49.1 |
| punch-through list (565) | 58.0 |
| translucent list, untextured or 565 | 39.0 |
| + DCalcCtrl 1 (any format, untextured too) | +5.00 +- 0.02 |
| every feature (565 Gouraud + offset + mip bilinear + fog table + DCalcCtrl 1) | 68 (allf, run 42) |
| mipmapping, bilinear, fog table, two volumes | +0 |
| a triangle straddling a volume edge (both parts seen) | set up twice: +68.9 (all features), +39 (untextured) (allfs, run 43) |

- **A triangle takes the larger of its setup and the time of its runs**, e.g. sprites over the tile (clk per
  sprite, untextured):

  | h \ w | 1 | 2 | 4 | 8 | 16 | 32 |
  |---|---|---|---|---|---|---|
  | 1 | 39.0 | 39.1 | 39.1 | 39.3 | 39.8 | 40.7 |
  | 2 | 39.1 | 39.2 | 39.3 | 39.9 | 40.7 | 69.4 |
  | 4 | 39.2 | 39.4 | 39.8 | 40.9 | 70.4 | 139.9 |
  | 8 | 74.7 | 44.5 | 44.6 | 69.6 | 139.9 | 277.8 |
  | 16 | 120.0 | 84.5 | 79.8 | 139.6 | 276.5 | 558.0 |
  | 32 | 226.7 | 157.1 | 150.6 | 272.3 | 554.5 | 1102.0 |

  Tall narrow sprites are bound by their runs (3.8). The quad and 565 versions are in tables.txt 7.
- **Offset colour of 0 costs nothing** [M vol2off, offs3]. All four offset planes are dropped together when every
  offset colour the triangle's shading uses is 0: the three corners for Gouraud, only the flat-shading corner for
  flat; all four bytes count. Then +16 a triangle and +2.1 a run disappear.
- **Planes** [M planes, uvmeas]: untextured 5 (1/w, A, R, G, B), textured 7 (+U/w, V/w), offset 11 (+offset
  A, R, G, B). Flat polygons are three equal corners, so they cost the same as Gouraud.
- **Latency never seen** [M dcalct]. In 64 tiles, each covered by one primitive, a tile pays neither the +5 nor
  even its 39: an untextured tile is 1024 x 1.01 + 7. The setup of a tile's first primitive is done while the tile
  before is still being shaded or written out. The setup runs ahead across primitives and tiles.
- **Look-ahead: ~11-12 new primitives** [M timemeas ahead, ahead2, table 23]. A busy block, then N one-pixel
  sprites on the next line marked with DCalcCtrl 1:

  | N | 16 | 18 | 20 | 22 | 24 | 26 | 28 | 30 | 32 | mean |
  |---|---|---|---|---|---|---|---|---|---|---|
  | set up ahead, block ~840 clk | 11.2 | 10.7 | 10.9 | 9.2 | 11.4 | 11.3 | 11.2 | 11.2 | 11.2 | 11.2 |
  | set up ahead, block ~420 clk | 9.6 | 10.0 | 11.1 | 9.5 | 11.7 | 11.8 | 11.5 | 11.3 | 10.4 | 11.1 |

  Twice the time to work ahead gives the same number, so it is a limit of **storage, not time**. The first 12-13
  sprites of a burst cost a few clk each, every one after that ~40.
  - Odd: a block over lines 0-23 (2500 clk) gives counts wandering between 10 and 23 and tile times jumping by
    up to 200; texels 8 apart give erratic times in multi-tile scenes (not understood).
- **Burst stalls** [M dcalcs]. Sprites of 8 lines that take longer than their setup still pay the +5 in full
  (2x8: 44.5 + 4.8) or in part (4x8: +1.5). Every sprite of a row of sprites needs its setup at the first line of
  that row; the store runs dry. "Larger of the two totals" is wrong; the position of the work in the tile matters.
  A clocked model gets this for free; a formula does not.
- **[I] One store of set-up primitives** serves both: ~11-12 ahead with the sorter on, "the TSP keeps 16" with it
  off (K 9-16 fit). [G] 16 entries, ~4 of them pinned by the primitive being shaded and by those whose runs are
  still queued after run start (3.8), which leaves ~12 for look-ahead. Replacement is not LRU (GAP, T6).
- **Crowded lines** [M timemeas, tables.txt 6]. A quad over the tile and K sprites of 1x32 over it; clk per further
  column per line, with its pixel:

  | columns | 1-12 | 13, 14 | 15, 16 | 17-20 | 21-24 | 25-28 | 29-32 |
  |---|---|---|---|---|---|---|---|
  | untextured | 4.0-4.9 | 5.4 | 5.9 | 6.6 | 8.7 | 11.1 | 10.4 |
  | 565 | 4.4-6.4 | 6.7 | 7.2 | 9.1 | 10.1 | 12.5 | 12.6 |
  | 565 offset | 6.7-8.5 | 9.3 | 10.9 | 11.5 | 13.2 | 16.1 | 16.5 |

  - It is the number of different triangles, not of runs: 17 sprites with 32 runs a line show none; the same 17
    as quads (33 triangles a line) do. 1x8 sprites pay ~+10 for DCalcCtrl (set up about twice).
  - Only in the opaque pass: translucent one-pixel runs with 32 triangles a line cost 4.5.
  - [I] The sorter's sweeps revisit more primitives than the store keeps, so they thrash. Pre-sorted translucent
    runs arrive grouped by polygon, so no sweeps. Not checked against the costs (T6).

### 3.8 Run start and the queue after it

- **The first value of a run** [M uvspan, uvmeas 23.6M readings]: per plane floor(C) + floor(A x0) + floor(B y)
  in screen coordinates, each product cut to the tile's grid on its own. That is a truncating multiplier plus an
  integer adder, 2 products a plane a run; every further pixel adds floor(A). Not cut at fixed columns.
- **Pitch** [M timemeas spanfmt, spanshad, vol2pitch; with nothing left to hide in]:

  | run start, sustained | untextured | 565 | 565 + offset |
  |---|---|---|---|
  | one triangle cut by cheap-shadow volumes | **3.9** | **4.2** | **6.3** |
  | one two-volume triangle cut by volumes | | 4.21 | 6.31 |
  | runs of different triangles | ~4.7 | ~6 | ~8 |
  | same triangle's two parts taking turns (inside/outside) | 4.1-4.5 | 4.1-4.5 | |

  - Flat = Gouraud to the clock; decal = modulate = modulate alpha (4.21). So the cost is not so many clk per
    plane used.
  - The texture's two planes add 0.3 in one context and 1.3 in another. The offset colour's 4 planes add +2.1
    (~2 planes a clock), and only when the offset colour is not 0.
  - A run of 8 or more pixels costs its pixels.
- **Shared arithmetic** [M timemeas share, runs 29-30]. On lines paced by run starts, a new triangle's setup takes
  13.7 clk (565, 7 planes) / 22.8 (offset, 11 planes) out of the run starts: ~2 clk a plane. The rest of the
  setup (34 / 41) runs alongside. Changing triangle costs ~1 clk a change.
  - **[I]** The setup's per-plane work and the run starts share one arithmetic unit. Its rate fits ~4 products a
    clock (a plane's setup ~9 products = 2.25 clk; a run start 2 products a plane).
  - The multiplier count cannot be told from timing (GAP).
- **Is part of a run start kept per line?** [M lineshare..lineshare5, runs 22-26]
  - A triangle's second run on a line costs less than another triangle's: 6-7 clk less with 2-3 runs between,
    5.6 / 4.2 with 4 / 6, 1.4-2.3 with 5, 7, 8.
  - A run added to a line costs 3-12 clk, **alternating with the count of runs on the line** (R's steps from M = 1
    to 8: 5.2, 9.6, 10.3, 10.0, 5.9, 11.7, 3.0), at both column parities.
  - Not a fixed C + B y kept per line and triangle. [G] A stage that takes a line's runs together over a window of
    a few runs (the sorter's drain granularity?) (T7).
- **The queue after run start** [M timemeas spanahead, spanburst, spanpos, spanq; runs 15-19].
  - A burst of run starts is hidden: ~45-70 runs, ~180-290 clk a tile, the same at lines 1, 8 and 20 (so made
    ahead across the tile boundary), and not shrinking when the runs queued before are 4x shorter.
  - [I] A queue of ~150-200 **pixels** of shading (~5-6 tile lines) between run start and the pixel pipe.
  - Its position relative to texturing is not known: the "after texturing" reading was withdrawn (spantex 1-3).
  - The step-wise costs (lines 26-27 ~188 each, 30-31 ~33) are uneven by line position and not the write-out's
    (GAP, T7).

### 3.9 Pixel pipe: fill rate, texture fetch, texture cache

**Per pixel [M timemeas; REPORT.md "Per pixel", several runs; tables.txt 2 and 17-19 hold one run in counts],
clk:**

| format | clk/px | first tile of a render, extra clk |
|---|---|---|
| untextured flat or Gouraud; offset; fog; translucent | 1.01 | 0 |
| 565, 1555, 4444, YUV422, bump, point sampled (twiddled or not), mip point, trilinear pass B | 1.01 | +80 to +110 |
| VQ 565 or YUV422 point (565 mip too) | 1.01 | +105 to +135 |
| palette 4/8 bpp, **16-bit entries**, point (also VQ) | 1.01 | |
| palette bilinear, 16-bit entries | 1.05 (8 bpp), 1.10 (4 bpp) | |
| 565 VQ bilinear | 1.01 | +455 |
| 565 / 1555 / 4444 bilinear (twiddled) | 1.11 | +70 to +80 |
| 565 mip bilinear, trilinear pass A | 1.37 | +55 to +65 |
| **palette with ARGB8888 entries** (PAL_RAM_CTRL 3), point or bilinear, VQ or not | **2.00** | +80 to +185 |
| **YUV422 bilinear** (twiddled, mip, VQ) | **2.00** | +115 (VQ +355) |
| **bilinear on a non-twiddled texture** (565 or YUV422) | **2.07** | +150 |
| 8 texels a pixel, not mipmapped (565, YUV, palette; 565 bilinear too) | 3.27 | +80 to +90 |
| 565 VQ, 8 texels a pixel | 3.58 | |
| YUV422 bilinear, 8 texels a pixel | 4.28 | |
| 565 mip, 8 texels a pixel; trilinear A at 6 texels a pixel | 2.14; 2.18 | +65; +35 |

**Footprint parity** [M timemeas align2, tables.txt 18-19], clk/px, texture stepped s texels a pixel in both
directions, the bilinear 2x2 footprint starting at an even or odd x (the row's parity changes nothing, <= 0.06):

| | s=1 | 2 even | 2 odd | 4 even | 4 odd |
|---|---|---|---|---|---|
| YUV422 bilinear | 2.00 | 2.01 | 2.01 | 2.13 | **3.14** |
| YUV422 point | 1.01 | 1.57 | 1.57 | 2.14 | 2.14 |
| 565 bilinear | 1.11 | 1.57 | 1.86 | 2.14 | 2.14 |
| palette 8 bpp bilinear, ARGB8888 | 2.00 | 2.00 | 2.00 | 2.14 | 2.14 |
| palette 8 bpp point, ARGB8888 | 2.00 | 2.00 | 2.00 | 2.14 | 2.13 |
| palette 8 bpp bilinear, RGB565 | 1.05 | 1.26-1.30 | 1.55-1.61 | 2.14 | 2.14 |
| palette 8 bpp point, RGB565 | 1.01 | 1.26 | 1.26 | 2.14 | 2.14 |

- **Fetch rule [I, fits all 13 numbers]:**
  - **four 16-bit words come in per clock**, and words that came in for the pixel before don't count again;
  - a bilinear YUV pixel takes one clock more after its words are in: 1 + 1 at an even x, 1 + 2 at an odd x that
    shares nothing with the pixel before;
  - a 32-bit texel passes a 16-bit path per filter tap in two steps: the 8888 palette pays exactly +1 a pixel,
    independent of the footprint;
  - a non-twiddled 2x2 footprint spans two memory rows (+1).
  - Ruled out: two converters for any two texels (the start would not matter); one converter per U/V pair (an odd
    start would cost 4); one 64-bit word of four texels a clock (the row's parity would matter).
- **Memory bound**: texels 4 or more apart cost 2.14 clk/px whatever the format. That is bound by the memory,
  and it hides the 8888 / YUV extra clock.
- **Texture cache** [M]:
  - The first tile of a render pays +35 to +455 clk, **every render**: the best of 11 renders of the same scene
    still pays it, though the same texels were read in the render before. [I] The texture cache is invalidated
    at STARTRENDER, or at least does not survive a render.
  - Texels far apart pay +2.25 clk/px every time.
  - Organisation (line size, ways, lines, miss latency): GAP (T8). SPAN_SORT_CFG bit 16 (TSP cache bypass) changes
    time by <= 2 %.
- **Palette RAM** is read per pixel (1024 x 32 bits). The CPU can rewrite it during a render and the TSP sees the
  new value within ~5 px (palette clock). [G] A CPU write port that does not stall the TSP, or stalls it briefly
  (the ~1 glitch pixel a scene).
- **Divider, blend, fog** cost nothing extra per pixel [M]: offset, fog, Gouraud, modulate all at 1.01.
- **Punch-through**: alpha-test failures make later passes (3.3); per pixel of a PT pass ~1.0.
- **SupSample, two-volume PT, bump with offset in OP/PT**: untimed (TODO D1, D2; GAP).

### 3.10 Tile colour buffers, the secondary buffer, keep Z

[M accbuf (9 pages, 3 runs), blendpos, blendsel, keepz, keepz_races; refsw3 NextTileAccumulationBuffers]

- **Exactly two 32x32 colour buffers.** A tile is shaded into one; the other is the **secondary accumulation
  buffer** of the TSP word's select bits (DstSelect writes it, SrcSelect reads it).
- **They swap when the TSP starts the next tile**, which is also **when the previous tile's write-out starts**. A
  tile that is not written out (entry bit 28) does not swap; the next tile is shaded into the same buffer.
- **A polygon that writes buffer 2 (DstSelect) waits until the previous tile's write-out is done.**
  - A whole tile of SEC WRITE costs **+1025** clk over ordinary pixels (0888 and 565 alike); a 4x32 column costs
    +150-190.
  - The bands being written out are never damaged (pages 6, 8: 58 cells, 2 runs).
  - [I] An interlock: the TSP's write into the other buffer stalls on "write-out busy".
- **A polygon that reads buffer 2 (SrcSelect) does not wait**, and the picture being written out is damaged:
  - accbuf page 7: 3-5 of its first lines get pixels of other lines; differs between runs; timing unchanged.
  - blendpos: three runs with the same input, 23,425 / 23,850 / 23,348 wrong pixels, 24,000-29,000 different
    between two runs. In a tile with content the damage starts between pixel 470 and 804 (usually row 16) and goes
    to the end of the tile; the wrong pixels hold other places of buffer 2. In an empty tile it is in every row.
  - [I] The write-out and the TSP's secondary read share one read port with no arbitration, so the write-out
    reads what the TSP addresses. The damage's start = the write-out's position when the reader began; its length
    = how long the reader reads.
  - [I] The run-to-run variation means the write-out's progress against the TSP is not fixed. Candidate
    sources: VRAM refresh, the display (off here), the CPU's polling.
- **Empty keep-Z tiles collide with the write-out** [M accbuf "T end", "T flush"].
  - A keep-Z tile that shades nothing ends at once and does not wait for the previous write-out.
  - Such a tile is not written out.
  - Two in a row (written out) hang the render until SOFTRESET.
  - One followed by other tiles costs ~2390 clk more, and a neighbour gets the other buffer's picture.
  - Held back with n unseen quads (~34 clk ISP each), keep Z tiles become harmless:

    | | 0888 (write-out 1355) | 565 (write-out 1045) |
    |---|---|---|
    | two empty tiles last: the render ends from | n = 36 (~1220 clk) | n = 32 (~1090) |
    | ... every picture right from | n = 56 (~1900) | |
    | one empty tile, then an ordinary tile: no extra time, right, from | n = 96 (not 64) | n = 64 (not 56) |
    | an empty tile, a second with n quads, then an ordinary one: the render ends from | n = 96 (not 64) | n = 64 (not 56) |

    The first threshold is one write-out's time, the others about two, all lower with the shorter write-out.
  - An empty keep-Z tile still takes its turn: the tiles after it alternate buffers as if it had been written out.
  - [I] A tile-done / write-out-start handshake that loses an event when "tile done" comes while the write-out is
    busy.
- **Deterministic but unmodelled** (refsw2/3 have no clock):
  - right after a written tile, the tile two before an empty keep-Z tile gets the picture of the tile between,
    the same every run (accbuf_races, keepz_races);
  - after a keep-Z entry that is not written out, its cell gets the next written tile's picture (keepz_races
    cell 10).
- **Modelled (refsw3)**: after an entry not written out, an empty keep-Z entry writes the buffer out at the place
  of the entry before it, with what that entry drew. Games use this: logo, mem, menu2, menu3, thps2_menu.
- **Keep Z timing** (tables.txt 16):
  - two entries of one tile, the second keep Z: the second shades only what it draws (all hidden: 2981 against
    2974 for the sprite alone);
  - a keep-Z tile covered by an opaque sprite gains 32;
  - an entry that draws nothing costs 17 with keep Z.

### 3.11 Write-out, scaler, clip, strip buffer

- **Cost a tile [M timemeas]: 1045 (0555/565/4444/1555), 1105 (888), 1357 (0888/8888)**, also when the clip
  removes every pixel.
  - Dither changes nothing.
  - Clip at 0888, one tile: all 2998, 16 of 32 lines left 2837, 16 columns / 16x16 / nothing 2686-2687 (= the
    16-bit time).
  - "What 32 bits add is per line written and only when a line is more than 64 bytes."
- **[I] Write-out model**: per tile line, `max(32 + ~0.66, W + ~10.4)` clk, where W = 32-bit words written on the
  line (16 bpp: 16, 888: 24, 8888: 32, 0 if clipped). That gives 1045 / 1105 / 1357 and the clip numbers within a
  few clocks. The tile buffer is read at 1 px a clock whatever the clip, and the VRAM write is one 32-bit word a
  clock plus ~10.4 clk of per-line overhead (row activate or burst setup). FB_BURSTCTRL's write burst field
  (0x00093f39; reading bits 19..16 as that field gives 9, a layout taken from the manual and not checked) is
  untested (GAP, T9).
- **Write-out against shading** [M spantex3]: the write-out costs ~370 clk a tile even at 16 bits (1474 written out
  against 1104 not), so a tile's write-out and the next tile's shading do not fully overlap. GAP: why (T9).
- **Scaler** [M scalermeas, scalertile, ycoeff; modelled in refsw3]:
  - It is a stream through the tiles in region array order. A tile with y = 0 restarts it, and other tiles
    continue it at their own x. [I] One line of vertical-filter state per framebuffer column.
  - Untimed (GAP).
  - **Hardware bug**: with the filter, the last row of the last tile has pixels 1..31 stuck at pixel 0's value.
    [I] The filter's output register does not advance while that row is written: its enable is the arrival of the
    next line, which never comes. An RTL with that enable structure reproduces it.
  - **Changing SCALER_CTL after a render** makes the next render write its first tile and stop, unless SOFTRESET
    (bit 1) comes first. [I] Scaler state survives renders and deadlocks a handshake when the factor changes under
    it.
- **Strip buffer** (FB_R_CTRL bit 22, size bits 21..16) [M sof2sweep; refsw3]: strips of 16 x size lines,
  alternately to FB_W_SOF1 and FB_W_SOF2; size 0 writes nothing. Untimed. Once it left the core stuck for later
  renders.

### 3.12 State that persists, counters, hangs

| state | rule | source |
|---|---|---|
| **bumphang counter** | non-twiddled (scan order) bump maps filtered bilinearly: the render stops in the tile holding the **16th such quad shaded (translucent) / 8th (opaque, PT)**. A quad counts once in every tile it covers; size, magnification, texels and light don't matter. **The count carries to the next render** (ten a render: the second stops at its sixth), SOFTRESET clears it. Twiddled and VQ bump maps, and point sampling, never stop | [M bumphang]; not modelled |
| offsKept | the last vertex's offset colour as sent, of the last primitive with the offset bit **the TSP shaded** (span-sorter order, not setup order); across tiles, renders and SOFTRESET; 0 after power-on | [M offspersist]; refsw3 offsKept |
| tspAlphaStuck | set by a SrcSel+DstSel ONE/SRC_A, ZERO polygon; every later polygon in the tile gets alpha 0 unless 255; cleared at the next tile | [M blendsel]; refsw3 |
| pre-sorted TR modifier glitch | a pre-sorted tile with an empty opaque list and a translucent modifier volume skipped its background (1000 clk less, blended with the previous render's buffer); history-dependent, set/clear rule unknown | [M timemeas tables.txt 14] GAP |
| texture cache | does not survive a render | [I] 3.9 |
| scaler stream | survives renders; a factor change stalls the next render | 3.11 |
| SOFTRESET (bits 1:0) | does not clear the register file (0 of 20 registers changed) | [M pvr-renderer] |

**[G] bumphang is a credit leak.** 16 and 8 look like a resource pool of 16 (e.g. outstanding-request credits of
the path non-twiddled bilinear bump reads take) that leaks one credit a quad, or two a quad in the passes where a
quad's two triangles are shaded apart. If so, the render slows before it stops (T18).

### 3.13 Whole frames

`rendertimes.txt` (pvr-renderer, 63 polly2-data dumps, the console in the game's own video mode so the display
is on, 1 pass, STARTRENDER to each bit):
- 3.6 ms (rez_intro) to 40.1 ms (sa_slow2); typical in-game 8-14 ms; mipmap times out;
- ISP's bit 13-276 us before the TSP's;
- the video bit 0.80 or 0.96 us before the TSP's.

These are whole-frame targets for a clocked model, with three caveats: the display was on (~3 us a line), the
older dump set was used, and there was one pass. Repeat display-off over all 786 dumps (T17).

### 3.14 Neighbours: TA, display, CPU

- **TA** [M ta-perf, ta-tests/PIPELINE_SHAPE.md]:
  - writes about one parameter word per PVR clock: a triangle in one tile 69 ns + 10.5 ns a word (226 ns
    packed);
  - per tile in a polygon's bounds: sprite 1.0 clk, quad strip 1.7, triangle 2.1;
  - end of list 0.8 us + 1.55 clk a tile;
  - input FIFO 8 x 32 bytes (SB_TFREM); object-list write queue of 32 words, drained to 16;
  - store queues 267 ns a block, DMA 54 ns.
  - The TA running against a render: not measured (GAP).
  - **cliptest**: without padding, each polygon is clipped by the user clip that follows it (the TA is still
    working on the last strip when the rectangle changes): a TA pipeline delay.
- **Display**: stalls the core ~3 us a scan line [M].
- **CPU**: register writes to PALETTE_RAM during a render ~12 clk each [M palette clock]. VRAM accesses are
  starved by a running render [M].
- **YUV converter** (TA side, TODO D5): throughput not measured.


## 4. Datapath clues in refsw3's arithmetic (what has to happen per clock)

refsw3 matches the console bit for bit. Several of its rules only make sense with a particular datapath shape:

1. **Edge unit, per edge per tile** (pvr_isp_edge.h; covmeas, hugepos):
   - Block floating point per edge per tile: the start at the tile's first sample as a 20-bit float; the two
     slopes as 20-bit floats cut to 21 bits under the larger one's exponent; a shared unit G = 2^(E-27),
     E = max(exp(larger slope) + 6, exp(start) + 1).
   - Then fixed-point stepping: per-pixel work is adds only.
   - **The decision uses neighbour pixels**: a zero pixel is inside iff the next pixel to its right is not
     negative; in column 31 the column step decides. A row whose value at column 0 is "zero" gets one answer for
     the whole row.
   - [I] A 32-wide row evaluation (all 32 values of the row present at once) is needed to look at x+1. That fits
     "one tile line a clock" (3.2).
   - Far edges: an edge whose start passes 2^128 with a column step >= 2^127 behaves as if its constant were
     +-2^132.06 [M faredge]: the register is wider than the float range. GAP: which case keeps 2^127.
2. **Depth unit** (pvr_isp_depth.h; zblock, ztile, zmeas, zword):
   - Block float per polygon per tile: start = ((a x0 + b y0) + c) x 1/det truncated to 20 bits under the start's
     exponent; slopes cut to 26 bits under it; stepped in fixed point with at least 26 + 29 + 1 bits plus sign
     (reach >= 29 binades).
   - **An overflowing slope steps +-2^127 a pixel in a register whose sign is at 2^131, wrapping every 32 steps,
     counted (sa i + sb j) from the tile's first pixel.** [I] The depth register is an accumulator that adds the
     x-slope per column and the y-slope per row (a DDA), with a fixed width: 5 bits above the step in this regime.
     The stored word is a function of the register alone (kWrap, WrapWord).
   - Stored: 19-bit mantissa above zero; below zero 16 bits, magnitude rounded up.
   - [I] The compare reads the stored word as a signed integer with a negative's fraction inverted: an integer
     comparator, 32 lanes.
3. **TSP plane evaluator** (pvr_tsp_plane.h; uvspan, uvmeas):
   - Evaluated once per run on one grid per tile (22 bits under E). first = floor(C) + floor(A x0) + floor(B y),
     then + floor(A) per pixel; normalised (leading-one count + shift) before the 16-bit cut.
   - [I] Per plane lane: one accumulator stepped per pixel; per run: two truncating products (shared unit, 3.8).
   - **SupSample** steps half pixels (2n + hx steps of A/2), and a point half a line down adds B/2 to C before the
     cut. [G] Up to 4 samples a pixel through the same lanes: up to 4x the pixel-pipe time (D1: GAP).
4. **Divider**: a 512-entry reciprocal table and a 16x16 multiplier per perspective attribute: U, V, 4 colour, 4
   offset (PIPELINE_SHAPE.md [5]). Fill rate is 1 px/clk with all of them, so they are parallel lanes, not
   time-shared.
5. **Mip level**: per polygon K (setup); per pixel w cut to 8 bits, w x w cut to 8, K x w^2 cut to 8: two 8-bit
   multipliers and a leading-one search per pixel. DCalcCtrl 1 adds 5 clk to setup (it evaluates the planes at
   the first vertex: [G] a pass of 3 planes through the shared unit).
6. **Blend**: two 8x9-bit multipliers per channel (8 a pixel), 1 px/clk, a read-modify-write of the tile buffer.
7. **SpanGen** (refsw_tile.cpp): runs cut in raster order, one a clock (3.4). **SpanSort**: the 96-window drain
   (3.6).
8. **PT chunk counter** (refsw_lists.cpp PtChunkTake): `fill - (prevQuad ? 1 : 0) + culledLag + nv > size - 2`.
   [I] Two late-arriving corrections to an occupancy counter (3.3).
9. **offsKept** is set when a primitive with the offset bit is **shaded**, not when it is set up (3.12). [I] It
   is a register in the pixel stage, loaded per primitive as its runs enter shading. A copy in the setup store
   would give "set up last", which the console contradicts (a reader shaded before its tile's setter reads the
   tile before's).


## 5. The VideoLogic patents: structure hints [H]

US5596685 (filed 1994) and its continuation-in-part US5729672 (filed 1995), Martin Ashton, VideoLogic. "Ray
tracing ... infinite surfaces": the ISP of the PowerVR family.

- **Precalculation unit**: multiplier 46 forms A x X0, multiplier 50 B x Y0, adder 48 adds C: "the depth value
  for the first surface at the first pixel" of a block. That is the per-tile start (a x0 + b y0) + c the console
  computes per polygon per tile (section 4.2): **two multipliers and an adder**, matching the order of the sums
  the console has, (a x0 + b y0) + c.
- **Cell array**: "A total of M cells are cascaded together and typically M will equal 32"; "each cell works on
  a single pixel and adjacent cells work on adjacent pixels"; each cell holds A and the running depth and adds A
  for the next pixel ("the depth calculation between horizontally adjacent pixels only requires a single
  addition"). Each cell also has depth/tag registers and a comparator. **One tile line of 32 per clock** is the
  console's rasterizer rate [M 3.2].
- **Time**: cycles = pixels x surfaces ("100 pixels by 10 surfaces which equals 1,000 cycles"); per row "the
  processing time will be equal to the number of planes in or associated with that tile". The console's "+1 clk
  per line per triangle past 16 lines" is the same law, with a triangle's 3 edges and depth as one "plane"
  evaluated in parallel, and setup overlapped.
- **Load balancing**: "rows from tiles with a smaller number of planes contained within them are interleaved with
  rows from tiles with a large number of planes"; two adjacent object lists loaded, tile start registers
  "swapped between as lines from the two different tiles are processed". [H] Possibly related to how the
  console's cutting overlaps the next tile's ISP work (3.4), not shown.
- **Decoupling**: FIFO 60 decouples the cells' output; an N-stage buffer 84 feeds the post-processing (texture
  and shading) unit 80. The console has a run queue there (3.5).
- **Multi-chip**: N ISPs on different output lines of one tile (not the CLX2).
- Instruction words are "typically 96 bits", cached on chip. The patents give no clock rates.


## 6. polly2-rtl-lite: design hints [H] (an FPGA design, not the console)

polly2-rtl-lite (r6b, polly2-core/rtl) is a layer-peeling core that fits a DE10-nano. Its structure is not the
console's:

- RAS_LANES = 8 raster lanes (not 32);
- per-pixel tag + invW peeling with TI_COPIES = 4 tag/invW tile images between the ISP and the TSP (not a run
  queue);
- a 64-entry plane cache keyed by the full tag;
- one shared 64-bit DDR channel with a 7-client priority arbiter.

What carries over:
- **Measured design facts** about decoupling, from the memory notes:
  - spanner_v2 streams plane setups through a ring (RING_N 1024, WINDOW 512, run-ahead <= 223 over 59 dumps);
  - its span ring (2048 slots) was full in 39/59 scenes;
  - raster chaining (no per-triangle drain) and a pipelined 1 px/clk video-out (2.00 -> 1.00 clk/px) were large
    wins.

  Lesson for rtl/v1: the console's queues (run queue ~512, sorter 96, setup store ~16, pixel queue ~150-200) are
  what make its stages overlap, and they must be sized as measured, not larger.
- **Pitfalls** that will recur in a clocked rtl/v1:
  - same-cycle done-against-accept races at drains (spanner streaming);
  - a stage consuming an input several cycles after issue while the source re-latches it (isp_raster_line's `tl`
    at stage 3);
  - occupancy counters read as signed integers (span ring high-water at -2048).
- **Instrumentation**: `+occlog` per-clock unit occupancy traces and the occview viewer (polly2-core/tools/occview)
  are a good pattern for rtl/v1, to compare per-unit busy time against the console's measured pitches.
- **Texture cache**: polly2-lite had to flush its texture/VQ caches on every render for coherency, as the console
  does [I 3.9].


## 7. Proposed pipeline for rtl/v1 (inferred)

This is a structure in which every measured number of section 3 falls out of a mechanism. Every queue depth and
step count is either measured (cited) or a free parameter marked GAP to be fixed by section 9's probes.

```
 STARTRENDER --> [A] TILE SEQUENCER: region array entry fetch (6 words), tile token, flags
                     | (invalidate texture cache; scaler stream state persists)
                     v
 [B] ISP FRONT: object list walker (block fetch ~20-31 clk/list) -> vertex fetch -> SETUP microsequence on one
     24-bit softfloat MAC datapath: tri 16, culled 15, sprite 19, strip 19/15 alternating; per tile (edge and
     depth tile-starts are per tile). 1-deep hand-off register to [C].
                     v
 [C] RASTERIZER: one tile row a clock for the current triangle: 32 lanes x (3 edge accumulators + depth DDA)
     -> 32 depth comparators (integer order) -> depth (8e+19m) / tag / volume-bit row write. Overlaps [B] of the
     next triangle. Z clear + background fill at tile start. Passes: OP, PT chunks (occupancy counter with 1-prim
     lag), TR sorted (sort cache) / pre-sorted.
                     v (tag buffer: single? GAP)
 [D] CUTTER: per row a 31-bit boundary mask (tag, valid, volume); priority encoder -> 1 run/clk, raster order.
     Stalls when [E] is full. ISP end-of-render bit = last run of last tile accepted.
                     v
 [E] RUN QUEUE: FIFO, ~430-480 runs in all to the shading (GAP split), entry ~40 bits
     {tag[23:0], tile/pass marker, y[4:0], x[4:0], len-1[4:0], vol}
                     v
 [F] SPAN SORTER: 96-entry compacting window; head key = oldest entry's (tag & ~7 if offset sort); 96 comparators;
     drain matching entries oldest first; refill free slots from [E] at once; tile barrier. (bit 0 off: bypass)
                     v  per drain: primitive key
 [G] TSP SETUP: lookup in SET-UP STORE (~16 entries; ~12 free for look-ahead; pinned while referenced; replacement
     GAP). Miss: parameter fetch (~19 clk first time) + setup sequence: non-plane part (34-41 clk) + plane part on
     SHARED UNIT (~2 clk/plane: 5/7/11 planes; offset planes dropped when all used offset colours are 0)
     + DCalcCtrl 5. Totals 39/48/64 (PT 58).
                     v
 [H] RUN START on the SHARED UNIT (~4 products/clk, arbitration with [G]'s plane part): per plane
     floor(C)+floor(A x0)+floor(B y); pitch 3.9/4.2/6.3 (+~1 on a triangle change)
                     v
 [I] PIXEL QUEUE ~150-200 px (position relative to texture: GAP)
                     v
 [J] PIXEL PIPE 1 px/clk with stall: plane accumulators -> normalise -> recip table x16x16 per attribute ->
     tex address/mip (2x 8-bit mul) -> TEXTURE CACHE (4 x 16-bit words/clk, reuse of previous pixel's words;
     32-bit texel = 2 steps; YUV bilinear +1; miss -> VRAM 64-bit) -> decode -> filter -> combine/fog ->
     blend (8 x 8x9 mul) RMW -> PT alpha test. offsKept / tspAlphaStuck registers live here.
                     v
 [K] TILE COLOUR BUFFERS: 2 x 1024 x 32 bit, ping-pong. Swap = TSP starts next written tile. Secondary
     read port SHARED with [L] (no arbitration: race); secondary write INTERLOCKED on [L] busy.
                     v
 [L] WRITE-OUT: read 1 px/clk (32.66 clk/line) -> pack/dither -> scaler (column line state) -> clip ->
     strip buffer -> VRAM 32-bit/clk + ~10.4 clk/line overhead. TSP end-of-render bit at the last tile's end.
     Display reads preempt (~3 us/line).
```

### 7.1 How the measured numbers fall out

| measured | mechanism in the proposal |
|---|---|
| tile cost ~ max(ISP, TSP, write-out) | [E], [F], [G], [I] and the two buffers [K] decouple the stages; back-pressure only |
| ISP 16/tri, +1 a line past 16 | [B] 16-step microsequence, [C] 1 row/clk, a 1-deep hand-off: per triangle max(16, rows) |
| ISP's bit 14.6 tiles early, ~436 runs left | [D] blocked by a full [E] (+ [F]); the bit fires on the last push |
| cut 1 clk a run | [D] priority encoder |
| order: 96 window, primitive drains, tile barrier | [F] |
| 39/48/64 per seen triangle; larger of setup and runs | [G] sequential per drain, overlapped with [H]/[J] of earlier drains via the store |
| look-ahead ~11-12, 16 kept with sorter off | [G] store of 16 with ~4 pinned |
| setup costs 2 clk/plane on run-start-paced lines | [G] plane part and [H] share one unit |
| run pitch 3.9/4.2/6.3; 4.7/6/8 across triangles | [H] per-run sequence + coefficient reload on a triangle change |
| ~45-70 runs / 150-200 px of bursts hidden | [I] |
| 1.01 clk/px; +1 for 8888 palette, YUV bilinear, non-twiddled bilinear; 2.14 memory bound | [J] texture cache port shape and VRAM rate |
| SEC WRITE +1025, SEC READ damages the write-out | [K] interlock on write, shared read port |
| empty keep-Z collisions and hang | [K]/[L] handshake: a "tile done" while [L] is busy is lost |
| write-out 1045/1105/1357, clip | [L] read 1 px/clk vs 32-bit writes + line overhead |
| crowded lines (>12 triangles) | [F] sweeps x [G] store thrash |
| PT chunk carry by ISP lead | [C]'s PT pass of chunk n+1 reads the resolved state as of when it runs, against the TSP's progress on chunk n |
| sort-off early runs | [F] bypassed: [G]'s look-ahead and [H]'s queue let a later run start before an earlier one finishes (T5) |
| bumphang | [J] a credit leak (G) |
| scaler last-row bug | [L] filter output register enabled by the next line's arrival |

### 7.2 Free parameters (fix them with section 9)

| parameter | current value | evidence | probe |
|---|---|---|---|
| ISP setup step counts by primitive kind | 16 / 15 / 19 / 19-15 | [M] | T2 |
| rows stepped per triangle (thin triangles) | GAP | [M] anomaly | T2 |
| setup-raster hand-off depth | 1 (G) | "first 16 lines hidden" | T2 |
| list block fetch latency | ~20-31; ~30 serial a pointer on the stamp clock (3.1a) | [M] | T1 (done for empty lists) |
| fixed tile costs 335 / 142 / 55-90 split | GAP (3.1a: event times only; 55-90 cause not measured) | [M] totals | T1 rest (T1_SET 2) |
| tag buffer count, cut/raster overlap rule | GAP | [M] 3.4 | T4 |
| run queue depth and entry rules | ~430-480 total | [M] | T3 |
| sorter emit/fill rate, early drains | GAP | [M] | T5 |
| set-up store size, pinning, replacement | ~16, ~12 ahead | [M] | T6 |
| parameter fetch cost (first setup) | ~19 | [M] sort-off | T6 |
| shared unit products/clk, arbitration priority | ~4 (G) | [M] share | T7 |
| pixel queue depth, unit (px or runs), position | ~150-200 px | [M] | T7 |
| texture cache line/ways/size, miss latency | GAP | [M] 2.14, +2.25 | T8 |
| write-out per-line overhead, burst, bank effects | ~10.4 / line (I) | [M] totals | T9, T10 |
| write-out start latency after swap | GAP | | T10 |
| tile handshake details | GAP | [M] T flush | T11 |
| display / TA / refresh arbitration | ~3 us a line | [M] | T14 |


## 8. Open questions (consolidated)

1. The ISP's per-triangle microsequence and the thin-triangle row rule (3.2).
2. What 32 rows of 32x1 a tile serialise on (1736 a tile; 3.5).
3. How cutting overlaps the next tile's ISP work (3.4).
4. The split of the ~430-480 buffered runs; whether cut runs and tile markers take entries (3.5).
5. The sorter's early drains and its emit rate; the order with the sorter off (3.6).
6. The set-up store: size, pinning, replacement; why crowded lines cost up to 2x in the opaque pass only (3.7).
7. The run-start alternation with the count of runs on a line; the pixel queue's position (3.8).
8. Texture cache organisation; the first-tile cost; 8-texels-apart erratic timing (3.9).
9. Write-out: line overhead vs bursts/banks; why ~370 a tile is not overlapped at 16 bits; start latency (3.11).
10. Tile-buffer handshakes: the exact event loss behind empty keep-Z; secondary-read collision timing and its
    run-to-run jitter (3.10).
11. PT chunk carry against the ISP's lead (2.2, 3.3).
12. bumphang: what leaks, and whether it slows before it stops (3.12).
13. SPAN_SORT_CFG 0x100 / 0x10001 hang triggers (3.6). Each try costs a power cycle.
14. End-of-render bits: video against TSP (2.1).
15. Untimed: SupSample, trilinear and bump in OP/PT, two-volume PT, FPU_PERP_VAL triangles, the scaler, strip
    buffer, translucent sort with many layers, the YUV converter, the TA during a render, SDRAM/burst registers,
    a second console.
16. The fixed 335 clk of an empty tile and the 55-90 of a tile with seen polygons (3.1).


## 9. Console timing probes still needed (prioritized)

All in dreamcast-tests style: pvrtest2.h / pvrsetup.h pages; `bash run2.sh <test> hw=<ip>`; registers forced
with `<test>+<reg>=<value>`. Timing scenes go in timemeas behind a `TM_*` define, with the timemeas method:
one tile or the first n tiles in KallistiOS order, interrupts and display off, SB_ISTNRM polled with PRFC0, best
of 11 x 3 runs, twins. Races go in `<test>_races`.

Each entry: question -> scene -> readout -> what it fixes. Priority is for building a cycle-accurate rtl/v1: the
instruments first, then the stages in pipeline order, weighted by how much end-of-render time they carry.

**T1 (first): an absolute palette clock, for latencies.** `TM_STAMP`. **Partially done 2026-11-20** (3.1a):
variant a) and the list / entry / object / position scenes ran as t1stamp_clock with a FOG_COL_RAM stamp (the 565
palette stamp slows the TSP); results in 3.1a. Open: T1_SET 2 (55-90 against first-tile start-up), b)-e), and a
safer design first: the probe wedged the console twice (3.1a).
- Question: every latency the queues hide (STARTRENDER to the first pixel; region-array and list fetch
  latencies; tile k's last pixel to tile k+1's first; ISP-to-TSP delay per tile; setup latency of a drain;
  SEC WRITE wait start and end).
- Scene: as TM_ORDER, but the CPU loop writes PALETTE_RAM[0] = the elapsed PRFC0 count >> 1 (clk) instead of a
  counter. Use RGB565 palette entries (PAL_RAM_CTRL 1) so the pixel pipe runs at its normal 1.01 clk/px; the
  stamp is then time >> 2 in 16 bits (4-clk units, wraps at 2.6 ms). Use ARGB8888 entries (24 bits) where speed
  does not matter. Framebuffer 0888, decal, point, ONE/ZERO, so the stored RGB is the stamp exactly (565 widened by
  bit replication: take the top 5/6/5 bits).
- Variants:
  - a) background only, 1 / 2 / 16 tiles;
  - b) T only stamp-textured among ordinary polygons (only the probe pixels read the palette, so the rest of the
    scene is not slowed);
  - c) each of order scenes 0-24;
  - d) accbuf's SEC WRITE tiles;
  - e) a tile after k dummy entries.
- Readout: framebuffer pixels = time each was shaded (+- the CPU write period, ~12 clk, plus a constant read-to-
  shade delay, calibrated by a single-pixel scene against the TSP's bit).
- Fixes: section 7.2's latencies; tile-start / tile-end events; the 335 / 142 / 55-90 split; whether pixels of a
  primitive start before its setup ends.

**T2: ISP setup microsequence and the rows rule.** `TM_ISPRAST`.
- Scene: the timemeas ISP method (N = 64, 128, 256 objects behind the background, compare GREATER). Families:
  - right triangles of height h = 1..32 and width w = 1, 2, 4, 8, 16, 32 in all four orientations;
  - slivers whose corners span rows they cover nowhere (row range against covered rows);
  - triangles starting at row 8 / 16 / 24;
  - triangles clipped by the tile at x (covering columns 0-3 only), and in a 4-tile render triangles spanning
    tiles (rows per tile);
  - kinds: strips of 1..8 (odd/even), triangle arrays, separate headers per triangle, sprites, culled by winding
    / by FPU_CULL_VAL (CullMode 1, 2, 3), degenerate (3 equal corners), FPU_PERP_VAL triangles (TODO D4: register
    1/128, 1.0, 2^20), NaN / inf corners, modifier volume triangles (inclusion, exclusion, the closing triangle),
    two-volume polygons, the shadow bit.
- Readout: TSP's bit differences; slopes per object.
- Fixes: [B] step counts per kind; [C] row rule (the 1-wide quad's 25 rows); the hand-off depth (does "16 lines
  hidden" hold for 2, 3 consecutive tall triangles?).

**T3: run queue depth and entry rules; the 32-rows anomaly.** `TM_ISPQ2`.
- Scene: 64 tiles at 565 (TSP-bound), ispq's method.
  - Background tiles with a nearer polygon splitting every line's run into 2, 3 or 4 pieces (do cut runs count
    once or per piece?).
  - Lines cut by volume edges.
  - Run lengths 1..32 at a fixed count of runs a tile (separate run-counted from pixel-counted buffering:
    runs_left = Q + P/len).
  - The same with SPAN_SORT_CFG 0x000 (does the 96 window count?).
  - Keep-Z tiles with no runs between (do tile markers take entries?).
- Rows: 32 primitives of 32x1, 16 of 32x2, 8 of 32x4 (transition), and with the ISP cost per primitive changed
  (triangles 16, sprites 19, strips 17) against the TSP cost (untextured, 565, offset, DCalcCtrl): fit pace =
  a ISP + b TSP. Also stamp-clock the rows (T1) to see what waits.
- Fixes: [E] depth and entry semantics; the per-primitive coupling in 3.5.

**T4: cut / next-tile overlap.** `TM_CUT2`.
- Scene: tile A with R = 128 / 256 extra runs; tile B after it, with: (i) W never-passing 1x1 sprites (setup and
  depth reads, no tag writes); (ii) W passing sprites covered later (tag writes); (iii) keep Z with no
  background; (iv) background only; W = 0..64 in steps of 4.
- Readout: the ISP's bit (ALWAYS minus NEVER twins).
- Fixes: tag buffer count and the overlap rule (row-level hand-off? clear waits? setup proceeds?).

**T5: sorter rates, early drains, sort-off order.** `TM_ORDER` + T1 stamps.
- Scenes: order scenes 11, 18, 20, 21 (early drains) and TM_SORTOFF scenes 32-42, stamped absolutely.
- Readout: each drain's start time against when its runs entered and when the drain before ended. A sorter-bound
  scene (one primitive, one-pixel runs, untextured) gives the sorter's own emit rate.
- Fixes: [F] rates; whether a drain can start while the previous drain's runs are still in [G]/[H] (early
  drains); the clocked mechanism of sort-off early runs.

**T6: the set-up store.** `TM_SETUPK2`.
- Scene: SPAN_SORT_CFG 0x000 (never 0x100 or 0x10001: they hang until power-off), so that the order is raster.
  Lines of one-pixel runs whose primitive sequence is designed against replacement policies:
  - period-P cycles (P = 8..20);
  - A, x1..xk, A patterns with reuse distance k = 1..20;
  - sequences that separate LRU / FIFO / random / pseudo-LRU / most-recently-filled (scene 13's "5 of 17 stay"
    is a known case);
  - with the sorter on: ahead2 with 0, 1, 2, 3 primitives kept busy (pinning).
- Readout: clk a line (hit ~12, miss ~44, first ~63).
- Fixes: [G] size, pinning, replacement, fetch cost; the crowded-lines curve (3.7).

**T7: shared unit and pixel queue.** `TM_SPAN2`.
- Shared unit: share-style lines in every format: untextured flat/Gouraud, textured, 16-bit UV, offset (0 and not
  0), two-volume, bump, SupSample. Setups injected per line.
- Pixel queue: spanahead bursts after lines of 1 / 2 / 4 / 8 / 32-pixel runs and after lines slowed in different
  ways (8 texels apart = texture-bound, 8888 palette = pixel-path-bound, SEC WRITE wait = buffer-bound): which
  slowness the queue hides.
- Also lineshare's alternation with M = 1..16.
- Fixes: [H] products/clk and arbitration; [I] depth, unit and position.

**T8: texture cache.** `TM_TEXC`.
- Scene: 64 tiles, one 565 point-sampled sprite each, texture coordinates chosen so that pixel i reads 64-bit word
  f(i). Patterns:
  - K distinct words cycling (K = 1..256);
  - strides S = 8, 16, 32, 64, 128, 256 B, 2 KB, 4 KB, 8 KB (line size: where the cost steps; associativity:
    aliasing at power-of-two strides; capacity: the K knee);
  - one isolated miss in a run of hits (miss latency);
  - bilinear versions;
  - the same texture rendered twice in one region array against two renders (flush at STARTRENDER?);
  - VQ code book vs index streams.
- Readout: clk/px.
- Fixes: the cache in [J] and the VRAM read latency (64-bit area).

**T9: write-out engine.** `TM_WO`.
- Scene: one tile and 64 tiles; every packmode; FB_X_CLIP leaving 1..32 px a line at 32 bpp and 16 bpp (the
  bytes-per-line threshold, overhead per line); FB_W_LINESTRIDE 640 against 32 (contiguous); FB_W_SOF1 in half 0
  against half 1 (0x000000 / 0x400000), with the parameters on the same or the other half; FB_BURSTCTRL wr_burst
  values (pictures compared too).
- Readout: TSP's bit.
- Fixes: [L]'s per-line overhead and bank effects, and whether framebuffer and parameter reads contend (pfetch's
  "VRAM traffic costs nothing" was with them on different halves).

**T10: a write-out clock through the secondary-buffer collision.** `accbuf_wo_races`.
- Scene: tile k ordinary at 0888 with every pixel unique (x, y coded). Tile k+1 holds one SrcSelect (SEC COPY)
  pixel or a 1x4 column, delayed by n unseen quads (n = 0..48, ~34 clk each).
- Readout: tile k's framebuffer cell. The damaged pixels show where the write-out was when the read happened, and
  what it read (buffer-2 contents at the TSP's address).
- 3 runs each, for the jitter.
- Fixes: [L] start latency after the swap, its rate per pixel and per line, and the [K] shared-port mechanism.

**T11: tile handshake.** Refine accbuf "T flush": n in steps of 1 around 30-40, 50-60, 56-100 at 565 and 0888;
plus T1 stamps on the tiles around an empty keep-Z tile (when the extra ~2390 clk are spent). Fixes: the lost
event in [K]/[L].

**T12: PT chunk carry against the ISP's lead.** `ptchunkcarry2_races`.
- Scene: ptchunkcarry_races's cells (k = 6, 7 fillers), each preceded in its own tile by m unseen quads
  (m = 0..40) or in the tile before (to set how far the ISP leads), plus T1 stamps.
- Readout: carry / no carry per cell.
- Fixes: what event the chunk-2 pass races against (the TSP finishing chunk 1's pass? its resolve write-back?).

**T13: passes.** `TM_PASS`.
- Per-pass costs: a PT pass that finds nothing (~300), PT chunks 1..4 a tile with empty and full passes,
  translucent sorted layers 1..64 at ISP_FEED_CFG sort cache sizes 512..32 (D8: does overflow cost time?),
  pre-sorted against sorted, the PT volume pass.
- Fixes: [C]'s pass sequencing, the sort cache's role in time.

**T14: VRAM contention.** `TM_VRAM`.
- Scene: timemeas scenes (texture-bound, write-out-bound, list-bound) with:
  - the display on at each FB_R_CTRL depth (stall a line; its correlation with SPG_STATUS);
  - the TA fed by DMA during the render (TA input after STARTRENDER: TA cost and render cost);
  - SDRAM_REFRESH, SDRAM_ARB_CFG swept (TODO A5, D7; check the pictures);
  - CPU single-word VRAM reads during a render. **Risk**: bulk accesses hang the console; keep to a few words,
    with a watchdog.
- Fixes: the arbiter model.

**T15: end-of-render bits.** Poll each bit in its own tight loop (three runs, one bit each), one tile and 64
tiles, every packmode, written out or not, scaler 0x400 / 0x401, strip buffer. Fixes: when bits 0 / 1 / 2 fire
relative to the write-out's last word (rendertimes: video 80-96 clk before the TSP's bit; timemeas comment says
after).

**T16: untimed features.** timemeas formats extended:
- SupSample (TODO D1): per pixel and per run, point / bilinear / mip / fog / offset;
- trilinear (two passes);
- bump in OP/PT;
- two-volume PT inside / outside;
- 16-bit UV;
- FPU_PERP_VAL triangles (D4);
- the YUV converter's throughput (D5, TA side).

Fixes: [J] lanes (is SupSample 4 samples through 1 lane = 4 clk/px?).

**T17: whole frames and hot tiles (TODO D6, C11).** pvr-renderer over all 786 polly2-data dumps with the display
off (as timemeas): STARTRENDER to each bit; then for the slowest tiles, one-entry region arrays per tile. The
busy dumps (garou_intro, garou_title, gunbird2_title, td6_menu) per tile. Fixes: the frame-level acceptance
targets (section 10).

**T18: bumphang's counter.** Time per tile of non-twiddled bilinear bump quads before the stop (does each leak
slow the next?), interleaved with other bilinear textures, with point-sampled bump maps between, a TA-only
SOFTRESET (bit 0) against a core reset (bit 1), and 1 / 2 triangles a quad. Fixes: what the 16 / 8 count is.

(The two SPAN_SORT_CFG hangs cost a power cycle each and need the user present. They are listed in TODO A1 and
left out here.)


## 10. Acceptance: what the clocked rtl/v1 must reproduce

1. **timemeas** (pvr-tests/timemeas/tables.txt sections 1-30, REPORT.md tables): every per-object, per-run,
   per-pixel and per-tile number. Compare the model's STARTRENDER-to-bit times scene by scene; the model has no poll
   loop, so compare the minimum against the console's minimum (+- the 14-clk poll quantum).
2. **ispq / rows / pfetch / cut**: the ISP's bit leads and paces.
3. **order**: order.py's out-of-order counts at the 96 window (6 / 20 in runs 38 / 39, the residue the early
   drains); the clocked model should also produce the early drains.
4. **spansortcfg** sort-off orders (timemeas_spansort0_order.log, sortoff logs): exact, once T5 explains them.
5. **Races**: accbuf_races, blendpos_races (statistically: damage start 470-804), keepz_races,
   ptchunkrun_races, ptchunkcarry_races: the deterministic cells exactly.
6. **accbuf "T" lines**: T end, T stall, T flush thresholds.
7. **rendertimes.txt** (and T17's display-off version): whole frames.
8. **Hangs**: bumphang's tile of stop and carry-over; two empty keep-Z tiles; SCALER_CTL change.


## Appendix A. Throughput and storage, in one place

| work | clk |
|---|---|
| ISP: triangle / strip (alternately 19, 15) / sprite / culled | 16 / 17 avg / 19 / 15 |
| ISP: line beyond 16, per triangle | 1 |
| ISP: list pointer present (empty list) | 20-31 |
| ISP: per background tile while unblocked | ~160 |
| ISP: modifier volume, 2 triangles 32 lines | 65 |
| cut: per run | 1 |
| tile: nothing to do / Z clear + background setup / background shading | 335 / 142 / 1035 |
| TSP setup per seen triangle: untextured / textured / +offset / PT / translucent | 39 / 48 / 64 / 58 / 39 |
| DCalcCtrl 1 per seen triangle | +5 |
| re-setup (sorter on) / without sorter / first (incl. fetch) | ~32 / 44 / ~63 |
| setup taken from run-start-paced lines | ~2 per plane (13.7 for 7, 22.8 for 11) |
| run start sustained: untextured / textured / offset | 3.9 / 4.2 / 6.3 |
| run of a different triangle | ~4.7 / 6 / 8 |
| pixel: most formats / twiddled bilinear / mip bilinear | 1.01 / 1.11 / 1.37 |
| pixel: 8888 palette, YUV bilinear / non-twiddled bilinear | 2.00 / 2.07 |
| pixel: texels 4+ apart (memory bound) / 8 texels a pixel | 2.14 / 3.27 |
| PT second pass over a block | 81 + 1.0/px (untextured), 146 + 1.0/px (textured) |
| empty pass | ~300 |
| SEC WRITE whole tile | +1025 |
| write-out: 16 / 24 / 32 bpp | 1045 / 1105 / 1357 |
| display, per scan line | ~300 (3 us) |

| storage | size | tag |
|---|---|---|
| depth buffer | 1024 x (8-bit exponent + 19-bit mantissa + sign) | [I] |
| tag buffer + stencil/volume bits | 1024 x (24-bit tag + a few bits); count GAP | [I] |
| ISP -> TSP run queue (with window and run-start queue) | ~430-480 runs x ~40 bits | [M] count, [I] width |
| span sorter window | 96 runs + 96 key comparators | [M] |
| set-up store | ~16 primitives (11 planes x A, B, C 16-bit floats + mip K + words) | [M] count, [G] content |
| pixel queue | ~150-200 px | [M] |
| reciprocal table | 512 entries | [M] |
| bump tables | 2 x 256 bytes | [M] |
| fog table / palette | 128 / 1024 entries | registers |
| tile colour buffers | 2 x 1024 x 32 bits | [M] |
| PT chunk counter | vertices, compare against size - 2, 1-primitive lag | [M] |
| translucent sort cache | ISP_FEED_CFG size (512), ~4 units a triangle | [G] |
| bumphang count | 16 / 8, persists across renders | [M] |
| scaler line state | one framebuffer line | [I] |
