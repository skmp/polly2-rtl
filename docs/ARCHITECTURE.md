# polly2-rtl architecture: the CORE as hardware

Role: architect. Revision 2, 2026-11-20, revised in answer to the review of revision 1. Appendix A maps each
objection to the change. This document turns the specifications into hardware units with interfaces, state and
clocked behaviour, and it is the reference for anyone implementing `rtl/v1`. Its companion is [PLAN.md](PLAN.md),
which sets the build order, the gates and the console probes.

Inputs, all read only:
- the bit-level specifications [spec/isp.md](spec/isp.md), [spec/tsp.md](spec/tsp.md) and
  [spec/numerics.md](spec/numerics.md), pinned at nulldc3 `708fb8cd`, their edge-unit and depth-unit sections at
  `4f3efe15` (§0.1, §0.1b below);
- the timing collection [timing.md](timing.md);
- the repository rules [conventions.md](conventions.md) and [reuse.md](reuse.md);
- **refsw3: nulldc3 `skmp/refsw3` @ `4f3efe15`** (`refsw3/refcore`, tree clean). This includes, after the specs'
  first pin `2d08a440`:
  - `6784ea3d` "the edge unit past 2^124: wrap, push and end of the edge";
  - `708fb8cd` "the depth unit below zero, past 2^128 and at its range's ends";
  - `1040c4aa` "the big-edge walk in units of 2^102; end against ZERO; row 31 for every polygon" (edge, §0.1b);
  - `0de9776b` "depth at the tile's corner without HALF_OFFSET; the zero rule in coordinates and edges" (depth);
  - `2bee80f2` "the TSP adds a zero as the ISP does; MipSelect with Sdet 0; texfar's leftovers" (TSP);
  - `4f3efe15` "a determinant of 2^126 or more has a reciprocal of zero" (depth, TSP planes);
- **dreamcast-tests @ `a932980`**. This includes `961c5e4` (25 faredge / hugepos console sets), `b7f8991`
  (depthgaps_*, zovf_* sets) and `a932980` (edge2_*, depth2_*, tsp2_*, trsort_*: every regress test exact).

Where this document and a spec disagree on a functional rule, **the spec wins** and this document is wrong. Where a
spec and refsw3 disagree, **refsw3 wins** and the spec is wrong (conv §1).

## 0. Notation and rules

**References.**

| reference | meaning |
|---|---|
| `isp §8.3` | docs/spec/isp.md section 8.3 |
| `tsp §5.3` | docs/spec/tsp.md section 5.3 |
| `num H6`, `num §2.8` | docs/spec/numerics.md primitive H6 / section 2.8 |
| `tim §3.2`, `tim T4` | docs/timing.md section 3.2 / probe T4 |
| `conv §7.3` | docs/conventions.md section 7.3 |
| `edge.h`, `depth.h`, `plane.h`, `tile.cpp`, `lists.cpp` | refcore `pvr_isp_edge.h`, `pvr_isp_depth.h`, `pvr_tsp_plane.h`, `refsw_tile.cpp`, `refsw_lists.cpp`; at `4f3efe15` for the edge unit (§2.4 `p2_edge_t`, §3.4.4 steps 1-5, §3.4.5 edge lanes and walk) and the depth unit (§2.4 `p2_ztile_t`, §3.4.4 steps 6-7, §3.4.5 depth lanes), at `708fb8cd` elsewhere |

**Tags**, as in the specs:
- **[M]** a console measurement shows it, and the test is named.
- **[I]** inferred: the simplest structure that explains several [M] facts.
- **[G]** a guess that fits. Every [G] that changes a clock is a free parameter in §6.
- **GAP** unmeasured, with the probe that closes it.
- **[A]** an architecture choice. No console fact tells the alternatives apart, and **neither the functional result
  nor any clock** depends on the choice. A choice that can move a clock is [G], not [A].

### 0.1 Where the specs were behind refsw3 `708fb8cd` (done)

The specs were transcribed at `2d08a440`. On the points below refsw3 moved, and this document followed refsw3. **All
of them are re-transcribed** (spec refresh, 2026-11-20): isp.md, numerics.md and tsp.md are pinned at `708fb8cd` now,
which supersedes their first pin `2d08a440` (the inputs list above gives the current pins). The "now in" column says where each rule is.

| spec section (at `2d08a440`) | superseded by | what changed | status: now in |
|---|---|---|---|
| isp §7.1, §7.2 | `6784ea3d` edge.h `EdgeWinding` | the edge sign and both culls use the **swamped** determinant; plain `Winding` only reports bad corners | done: isp §7.1, §7.2; num §2.12, §5.1 |
| isp §8.2-8.5, num §3 EdgeHW, num H7a, num §8 A1 (edge site), num G3, isp §15 #1 | `6784ea3d` edge.h `EdgeTile::Setup`, `Walk` | products and sums at 2^128 swamp; the start saturates to 2^127 (the 2^132 rule is gone); E capped at `blockMax` 129; an edge with a step of 2^123 or more ("big") is walked down the tile (§3.4.5); its units, end and far value revised by `1040c4aa` (§0.1b) | done: isp §8.2, §8.3, §8.4a, §8.4b (the walk), §8.5 (widths re-checked), §15 #1, #24; num §3.1, H7a (`fp_swamp`), §8 (A1, G3, G10, G13) |
| isp §8.6 | `6784ea3d` tile.cpp `RasterizeTriangle` | a polygon whose first row is the tile's row 31 starts at row 30 when any edge is big (every polygon since `1040c4aa`, §0.1b) | done: isp §8.6, §15 #25 |
| isp §9.3-9.7, num H14, num §4 (depth flavour), num §8 A3, isp §15 #2-#6, #8, #10 | `708fb8cd` depth.h | the stored depth is an order key 32 bits finer than the word (`StoredDepth::k`); negative depths are a block exponent and a fixed point (`Neg`); positive depths from 2^128 lie above every word (`Big`); `RegDepth` replaces kWrap / WrapWord; the constant's overflow (old ovf 1) steps as a block from a forced start; the float form is unreachable; new zero rule in the depth adds; the determinant-zero mean handles infinite corners; new background word below zero | done: isp §4.2 (background), §6.3 (limits, zero rule), §9.1-9.7, §10.1, §13, §15 #2-#11, #26, #27 (row numbers kept), §16, §17; num §1.2-1.4, §3.2, §3.5, §4, §5.2, H10-H12, H14 (a-i), §7, §8 (A2, A3 closed, A5, D2, G4-G7, G12) |
| tsp (all) | — | `708fb8cd` only factors out `pvrfp::OneThird()`; no functional change | done: tsp header, §4.4 (with the ISP's own zero rule beside the TSP's), §20, §22 #2 |

Found while re-transcribing, for this document (it is not edited here; the spec sections named are the reference):
- **`nsh` can be negative.** `nsh = E - 15 - gexp` is below 0 when E is clamped at 128 with `gexp > 113` (-15 .. 14 in
  the run). With a nonzero start `M = t * 2^-nsh` (a left shift); with a start cut to zero refsw3 stores its fallback
  word 0xFF000000 (isp §9.6, num A5). Neither happened at a covered pixel in 300,000 random planes
  (`agents/spec-refresh/widths708.cpp`), but `At` returns them, so a lockstep over every lane meets them. §2.4's
  5-bit unsigned `nsh` did not hold them; since the depth spec sync it is 5 bits signed (-14..14 with a start) beside
  a fallback flag `fbw` (isp §9.6).
- **M can exceed 2^23** at such pixels (2^34.1 in the run, bounded by 2^43; never above 2^23 at a covered pixel).
  §2.1's "`|M| < 2^23` in the 30-bit form" holds for covered pixels only.
- **The TR peel's reset `bits(0x7F7FFFFF)` is not above every depth**: a `Big` depth (2^128 and up) is above it
  (isp §11.2).
- **The depth zero rule** reads "the bit under the leading one", which refsw3 computes with a shift by -1 for a
  one-bit mantissa (num D2); H10 implements the value rule `|v| < 1.5 * 2^-126`.

### 0.1b Where the specs are behind refsw3 `4f3efe15`

Four refsw3 commits followed `708fb8cd` (nulldc3 r8 round 1, dreamcast-tests `a932980`: every regress test exact,
hugepos_rules and hugepos_v5 included). The edge rows are transcribed (spec sync, 2026-11-20), the depth rows too
(depth spec sync, 2026-11-20), the TSP rows by M9 (2026-11-23): every spec is at `4f3efe15`. `pvr_softfp.h` did not change in any of the four: no shared primitive moved. The TSP's
plane adds now take the depth setup's zero rule (`2bee80f2`) and its reciprocal the same 2^126 limit (`4f3efe15`),
so H10's DEPTH and TSP flavours are closer than before (num §4.2); M2 already brought `p2_fp_rng_add` /
`p2_fp_rng_recip` there.

| commit | what changed | status: now in |
|---|---|---|
| `1040c4aa` edge.h `EdgeTile::Setup`, `Walk`; tile.cpp `RasterizeTriangle` | a big edge (E cut to 129) keeps its start and steps in units of 2^(E - 27) = 2^102, cut toward zero, its ordinary rows too (`EdgeHW::cutUnitBits` 27); the walk uses those values (no finer grid: `f0 = t0`, `fx = tx`, `fy = ty`, `z = zero2`, `H = 2^30` half units); the end compares the far value against ZERO, not 0; the far value is `R + (32 sx mod 2^131)` for sx > 0, `R + 2^131` for sx < 0 a multiple of 2^126, `R` otherwise; the row-31 shift applies to every polygon | done: isp §0, §8.2-8.6, §15 #1, #24, #25, §16, §17; num header, §3.1, §4.2, §5.1, §5.4, H11 `unitsAt`, G13; this document §2.4, §3.4.4, §3.4.5, §7; PLAN M2 |
| `0de9776b` depth.h `DepthTileT::Setup`, `At`; tile.cpp | the depth start at the tile's first sample point (the corner with HALF_OFFSET[0] clear), every pixel whole steps from it (`h = 0` in the hardware); the zero rule in the depth setup's coordinate differences, edge sums and determinant (`DepthHW::zeroRuleCoords`, `zeroRuleEdges`). **The edge unit is not affected**: its `c`, `dx`, `dy` and `EdgeWinding` determinant use plain `pvrfp::Add` / `Sub` (isp §6.2); the depth unit computes its own `e`, `det` and coordinate differences (§3.4.4 step 6). Measured, no code change: REG's off-grid negative slopes toward zero, positive denormals by value, Big cut to 19 bits, REG's words among other planes' depths | edge: isp §6.2, §6.3 note, §15 #26, num G7. Depth: **done** (depth spec sync): isp §0, §6.3, §9.1-9.7, §15 #5, #6, #13, #26, §16, §17; num header, §0, §1.4, §2.5, §3.2, §4.1-4.3, §5.2, §5.5, H10, H12b, H14, §7.1, §7.3, §8 (A4, A5, D2, G5-G7); this document §2.4 `p2_ztile_t`, §3.4.4 steps 6-7, §3.4.5 depth lanes; PLAN M3 |
| `2bee80f2` plane.h, tile.cpp | the TSP's plane adds take the ISP's zero rule; MipSelect with Sdet 0 takes the last level; a mipmapped texture declared taller than wide | **done** (TSP spec re-transcription, M9, 2026-11-23): tsp header, §4.1, §4.4, §8.1, §8.2, §9.1, §22; this document §3.7.3 (the dropped-offset table); PLAN M9 |
| `4f3efe15` depth.h, plane.h; tile.cpp (comment) | a depth determinant of 2^126 or more (exactly included), or infinite, has a reciprocal of zero: depth 0 at every pixel; the TSP planes follow (every coefficient zero); the translucent sort orders such depths as the depth test (KeyAbove, no code change) | depth: **done** (isp §6.3, §9.3 steps 1 and 1b, §10.3, §15 #7, §16; num §0, §1.4, §3.2, §3.5, §4.1-4.3, §5.2, H10, G5; this document §2.4 CONST, §3.4.4 step 7; PLAN M3). TSP: **done** (M9: tsp §4.3; this document §3.7.3; PLAN M9) |

### 0.2 Rules this architecture follows

1. **Functional: refsw3, bit for bit.** Every unit names the spec sections and refsw3 functions it implements. The
   RTL never encodes a rule refsw3 lacks. A disagreement goes to `OPEN_ITEMS.md` and becomes a request for a console
   test (conv §1).
2. **Timing from mechanisms.** The mechanisms are:
   - queues with depths;
   - occupancy and credits;
   - row-per-clock, run-per-clock and pixel-per-clock datapaths;
   - microprograms **generated from refsw3's operation graph** by a scheduler (§3.4.4, §3.7.3);
   - interlocks, drains and hand-over points.

   No latency table, countdown ROM or per-primitive cost constant decides when anything proceeds (conv §4.7). Every
   free parameter is in §6, with the probe that fixes it.
3. **One clock**, `clk`, the 100 MHz core clock (tim §1, conv §4.4). Nothing measured points to a second domain inside
   the CORE. VRAM, the display and the CPU are outside it. The testbench models VRAM with its own timing (§3.2.1).
4. **Three ordered streams carry the work.** Every order that shows in a result (isp §1 items 1-7, tsp §3.4) is a
   property of one of them (§4):
   - the **entry stream**: tile sequencer to ISP;
   - the **run stream**: ISP to run queue to sorter to TSP to pixel pipe to tile buffers to write-out. Pass and entry
     boundaries ride on it as flags (§2.3);
   - the **feedback stream**: pixel pipe back to the ISP, for punch-through passes only.
5. **Races come from structure.** The console shows races that refsw3 does not model (tim §2.2):
   - PT chunk carry;
   - empty keep-Z collisions;
   - secondary-buffer reads against the write-out;
   - texture, VQ index or parameter reads of framebuffer words the same render writes (tim §2.2 item 5);
   - the order with the sorter off.

   The RTL gets these from its structure, and only where a race window opens. Outside the window the result is
   refsw3's. A race mechanism whose console form is unknown sits in one named sub-block, so that a probe result
   changes one place. Functional gates classify race renders mechanically (§3.2.1, PLAN §1.6) rather than by hand.
6. **The physical ports of every storage array are part of the design** (§3.4.7). Simulation never has more ports
   than the synthesized RAMs.

## 1. Top level

### 1.1 Block diagram

```
 reg port ──► p2_regs ── live register fields, FOG_TABLE, PALETTE_RAM ──► (every unit)
                │ start / soft reset / end-of-render events
                ▼
 ┌──────── p2_seq ─── entry stream ───┐
 │ (region array)                     ▼
 │   ┌───────────────────────────────── ISP ─────────────────────────────────────────────────┐
 │   │ p2_isp_ctl (phases, passes, chunks)                                                    │
 │   │ p2_isp_olw ─► p2_isp_pfetch ─► p2_isp_setup ─► p2_isp_ptc ─► hand-off ─► p2_isp_raster  │
 │   │ (lists)       (params, assembly) (edges+depth)   (PT chunks)   ▲   │      (row/clk)     │
 │   │                                       │                       │   ▼                    │
 │   │                                       └──► p2_isp_pcache ─────┘  p2_isp_pix            │
 │   │                                            (replay of set-up descriptors, §3.4.11)     │
 │   │ p2_isp_buf (per-pixel state, 32 rows x 32 lanes; §3.4.7 ports) ◄── raster, cut, fb    │
 │   │ p2_isp_cut (runs, 1/clk) ──────┐                     p2_isp_fb ◄──────────┐ feedback │
 │   └────────────────────────────────┼──────────────────────────────────────────┼──────────┘
 │                         run stream ▼                p2_entq (entry records) ──┼──────────┐
 │   p2_runq ─► p2_sort (96 window) ─► SRQ ─► p2_tsp_rstart ─► p2_pxq ─► p2_pp ──┴─► p2_tbuf ─► p2_wout
 │                                     │        ▲  ▲                     │  ▲     (2 tile    (line FIFO,
 │                                     ▼        │  │ shared ALU          │  │      buffers)   scaler,
 │                          p2_tsp_store ◄─ p2_tsp_setup ◄─ p2_tsp_pfetch ▼  │                 pack, clip)
 │                          (16 set-up       (planes, mip K)          p2_tex (coord, addr,
 │                           primitives)                              cache, decode, filter)
 │
 └── p2_mem: VRAM clients C0 seq, C1 olw, C2 isp_pfetch, C3 tsp_pfetch, C4 tex, C5 wout ──► VRAM half ports H0, H1
```

Unit folders (conv §3): `regs/`, `mem/`, `seq/`, `isp/` (with `p2_isp_pcache`), `sort/` (with `p2_runq`), `tsp/`
(setup, store, run start, pixel queue, pixel pipe), `tex/`, `tbuf/` (with `p2_entq`), `wout/`, `lib/fp/` (conv's
`lib/` and numerics' `fp/` are one folder).

### 1.2 External interfaces of `p2_core`

| port group | signals (widths) | protocol |
|---|---|---|
| clock, reset | `clk`, `rst` (power-on, synchronous, active high) | one domain |
| register port | `reg_wr`, `reg_rd`, `reg_addr[12:2]` (word index in the 8 KB block, PVR offsets 0x000-0x1FFC), `reg_wdata[31:0]`, `reg_rdata[31:0]` | a write takes effect at the next edge; a read returns its data one clock later |
| VRAM half h = 0, 1 | `vh_req_v[h]`, `vh_req_rdy[h]`, `vh_req_we[h]`, `vh_req_idx[h][19:0]` (32-bit word index within the 4 MB half), `vh_req_be[h][3:0]`, `vh_req_wdata[h][31:0]`, `vh_req_src[h][2:0]` (client id); `vh_rsp_v[h]`, `vh_rsp_data[h][31:0]`, `vh_rsp_src[h][2:0]` | valid/ready per request; read responses in request order per half, any latency |
| events | `ev_isp`, `ev_tsp`, `ev_vid` (1-clock pulses: SB_ISTNRM bits 1, 2, 0); `ev_isp_ovf` (SB_ISTERR bit 0, "ISP out of cache") | pulses; `ev_isp_ovf` is driven by `p2_isp_pcache`'s unit counter (§3.4.11) only when `P2_ISTERR=1` (PLAN D11), otherwise tied 0 as refsw3 has no such rule |
| debug taps (sim only, `ifndef SYNTHESIS`) | `+occlog`, `+rendlog`, `+fbdump`, per-unit `+<unit>trace`; ISP and TSP state read ports for the tile testbenches (PLAN §1.3) | conv §7.5; backdoor reads, not counted as RAM ports |

**Two 32-bit halves, not one 64-bit port** [I].
- Video memory is two 32-bit halves (tim §1, pvrsetup.h).
- The 32-bit area maps a byte address `a` to half `a[22]`, word `a[21:2]`. The 64-bit area maps `A` to word
  `A[22:3]` of both halves, half 0 in the low 32 bits. This is `pvr_map32` (conv §7.3).
- Texture reads are 64 bits a clock (tim §1 [I]), so they take both halves in the same clock. The write-out writes
  one 32-bit word a clock into one half.
- With two halves, a parameter read in half 1 and a framebuffer write in half 0 can proceed in the same clock. That
  is the reading under which pfetch's "VRAM traffic costs nothing" was measured. What contends with what is GAP
  (T9, T14), and it lives in `p2_mem` and the VRAM model.

### 1.3 Render lifecycle

1. The testbench (p2-offline) writes the whole register block (conv §7.4), then STARTRENDER (0x014).
2. `p2_regs` pulses `start`. This does the following:
   - `p2_seq` resets its per-render state and starts at REGION_BASE;
   - `p2_tbuf` resets its per-render state (`prevWrittenOut = havePrev = 0`, refsw3 RenderCORE);
   - `p2_wout` resets the scaler stream (§3.10);
   - `p2_tsp_store` invalidates every entry. refsw3 clears its cache at every region array entry (`ClearFpuCache`),
     which is functionally transparent; whether the console keeps set-up primitives across entries is [G] (§6, T6);
   - `p2_tex_cache` invalidates [I tim §3.9: the first tile of every render pays +35..+455].
3. Entries flow down the three streams. The ISP may run ahead of the TSP by the run-stream capacity (§3.5, §5).
4. **End-of-render events.**
   - `ev_isp` fires when the run queue accepts the item that carries `eoe` for the `last_region` entry
     [I tim §2.1: "the last run accepted"].
   - `ev_tsp` fires when the write-out of the last written tile has had its last VRAM write accepted. If the last
     entry is not written out, it fires when that entry's `eoe` item leaves `p2_tbuf` [M: the bit moves with the
     framebuffer format and the clip].
   - `ev_vid` fires when the write-out's tile-buffer reader has read the last pixel of the last tile [G].
     rendertimes shows it 80-96 clk before `ev_tsp`, which this places on the write-out line FIFO (§3.10, `WO_FIFO`);
     GAP T15.
5. **SOFTRESET (0x008) bit 1** asserts `soft_rst` for one clock.
   - It resets every controller, queue, counter and pipeline valid bit. The ISP buffers' valid / rendered bits count
     as controller state; their contents are not cleared.
   - It clears the bumphang counter [M tim §3.12] and the scaler stall (§3.10).
   - It does **not** clear:
     - the register file [M pvr-renderer: 0 of 20 registers changed];
     - `offsKept` [M offspersist];
     - the two tile colour buffers or the buffer select (conv §4.4; GAP G8).

   Bit 0 is the TA's (out of scope, G7). The other bits are GAP.

### 1.4 State that persists across renders

| state | unit | cleared by | evidence |
|---|---|---|---|
| tile colour buffers 2 x 1024 x 32 bit, and which is buffer 1 | p2_tbuf | never (power-on contents GAP G8) | [M accbuf page 2, page 4 cell 6] |
| `offsKept` (32 bit) | p2_pp_shade | power-on only (0) | [M offspersist] |
| ISP depthA, tagA, stencil | p2_isp_buf | never (written by the first entry's Z clear) | isp §1 item 7 |
| bumphang counter | p2_tex_cache [G] | soft reset | [M bumphang]; not in refsw3: a hang feature, PLAN MT9 |
| scaler "factor at last render" (for the stall) | p2_wout | soft reset | [M scalermeas]; a hang feature, PLAN MT9 |
| pre-sorted TR-modifier glitch state | p2_isp_ctl, sub-block `p2_isp_ctl_tg` (§3.4.1) | unknown | [M timemeas tables.txt 14, history-dependent]; GAP T21, refsw3 has none, so the sub-block is empty |
| register file, FOG_TABLE, PALETTE_RAM | p2_regs | power-on only | [M] |

## 2. Shared formats (`p2_pkg`, `p2_hw_pkg`, `p2_zword_pkg`)

Every width comes from `p2_hw_pkg.sv`, which is generated from the refcore `*HW` structs (conv §5): EdgeHW now
includes `blockMax` (129), `cutUnitBits` (27, since `1040c4aa`; `tools/gen/gen_hw_pkg.cpp` lists the members, so it
is added in M2) and `walkExp` (131). The literal numbers below are the current values; RTL code uses the
package names. All structs are packed. To keep Quartus 17 happy, there are no struct parameters (conv §4.2).

### 2.1 Number formats (num §1)

| type | fields (MSB first) | bits | where | numerics |
|---|---|---|---|---|
| `p2_fp24_t` | `neg`, `bad`, `exp[9:0]` (two's complement: exponent of mantissa bit 0), `mant[23:0]` (unnormalized) | 36 | every setup operand and result (ISP edge/depth, TSP planes, mip K). The edge unit's swamp value 2^200 is the tuple `{neg, 0, 200, 1}` | num §1.1, §1.3: the reference tuple exactly, `out.exp = max(L, top - N)`; `exp` meaningful only when `mant != 0` |
| `p2_fp20_t` | as above, `mant[19:0]` | 32 | edge `s20`, steps; depth start and slopes before blocking | num H2 (N = 20) |
| `p2_fp16_t` | as above, `mant[15:0]` | 28 | TSP coefficients A, B, C in the set-up store | tsp §4.3; kept as the tuple because H7b depends on `exp` (num §1.3, A1) |
| `p2_fp8_t` | as above, `mant[7:0]` | 20 | mip K8, w8, ww, d | tsp §8 |
| `p2_pval_t` | `neg`, `mant[16:0]` (0 = zero; 2^16 only after a carry), `exp[9:0]` | 28 | plane value after the normalizer: the 1/w value W and every attribute value | num H12a: `k = 0` is +0, `k = -1` is `{1, 1, -143}`, exponent floor -128 |
| `p2_quot_t` | `neg`, `mant[17:0]` (q in [2^15, 2^17]), `exp[9:0]` | 29 | divider output | num H13 |
| `p2_zkey_t` | `logic signed [63:0]` | 64 | **the stored depth**: refsw3 `StoredDepth::k`, the ISP's order, 32 bits finer than the float word. It is the only depth the buffers hold and the comparators compare (depth.h: `bits` is "for logs and the probes only") | depth.h `StoredDepth`; replaces revision 1's 32-bit `p2_zword_t` |

`p2_zword_pkg` holds every function that makes or reads a key, as combinational SV functions named after refsw3:
`key32(w)` (signed word key, `0x80000000` → 0, negative fractions inverted), `bits(w) = key32(w) << 32`,
`between(w, off) = (key32(w) << 32) + off`, `from_fp` (RNE, denormal grid, `Saturated` from 2^128), `big`, `neg(E,
M)`, `flat`, `regdepth(r)`, `bgkey` (from ISP_BACKGND_D, lists.cpp RenderCORE), `saturated(neg)`. This is the one
module boundary the stored-depth format lives behind. The testbench converts a key back to refsw3's `bits` for logs
and the depth tap: the inverse exists on every reachable key, because `|M| < 2^23` in the 30-bit form (§3.4.5).

Wide internal values (H7b/c: 62/64-bit) never leave their primitive. The edge unit no longer has a wide add.

### 2.2 Words and tags

| type | fields | bits | spec |
|---|---|---|---|
| `p2_tag_t` | the full ISP_BACKGND_T word: `[31:29]` (0 for every primitive tag; whatever software wrote for the background tag), `cache_bypass` 28, `shadow` 27, `skip` 26:24, `param_offs` 23:3, `tag_offset` 2:0 | **32** | isp §3.5. refsw3 keeps all 32 bits in tagA, tagB, opTag, refTagC, resTag (`ClearBuffers(ISP_BACKGND_T.full)`). Sort key = bits 23:0 |
| `TAG_BELOW` | the constant `32'hFFFF_FFFF` | — | tile.cpp `KeyAbove`. A background tag of 0xFFFFFFFF **is** TAG_BELOW, as in refsw3: at equal depth a fragment is then drawn over it. No separate "below" flag |
| `p2_isptsp_t`, `p2_tsp_t`, `p2_tcw_t`, `p2_region_ctl_t`, `p2_listptr_t`, `p2_objent_t` | generated from `core_structs.h`, `refsw_lists_regtypes.h` | 32 each | isp §3, tsp §0 |
| `p2_rm_t` | refsw3 `RenderMode`: 0 OPAQUE, 1 PT_PASS0, 2 PT_PASSN, 3 PT_MV, 4 TR_AUTOSORT, 5 TR_PRESORT, 6 MODIFIER | 3 | refsw_lists.h |

### 2.3 Stream formats

**Entry** (`p2_entry_t`, p2_seq to p2_isp_ctl), valid/ready:

| field | bits | meaning (isp §3.1) |
|---|---|---|
| `tilex`, `tiley` | 6 + 6 | |
| `no_writeout`, `pre_sort`, `z_keep`, `last` | 4 | `pre_sort` already resolved: entry bit 29 (6-word entries) or ISP_FEED_CFG[0] (5-word) |
| `ptr[0:4]` | 5 x 22 | list word addresses (bits 23:2), in the order OP, OP_MOD, TR, TR_MOD, PT |
| `empty[0:4]` | 5 | PT is empty for 5-word entries |
| `idx` | 16 | entry number in the render (debug, log) |

**Run-stream item** (`p2_rs_t`, 124 bits, valid/ready at every hop):

| field | bits | meaning |
|---|---|---|
| `null` | 1 | 1: an item with no pixels, carrying flags only (below) |
| `tag` | 32 | `p2_tag_t` |
| `y`, `x`, `lenm1` | 5 + 5 + 5 | line, first column, length - 1 |
| `rm` | 3 | the pass's RenderMode |
| `epoch` | 7 | the SHADE pass number modulo 128, counted by p2_isp_cut: as built (M7) the passes that emitted a run (an empty pass emits nothing and does not count). It goes into the sorter's key (§3.6) |
| `vmask[31:0]` | 32 | stencil bit 0 of pixel x+i at bit i (i < len) |
| `pmask[31:0]` | 32 | `rendered` of pixel x+i, in PT_PASS0/N (run-only pixels, refsw3 `keepRes`) and PT_MV (alpha-tested pixels); 0 otherwise |
| `eop` | 1 | the last item of its SHADE pass |
| `eoe` | 1 | the last item of its region array entry: its record is at the head of `p2_entq` |

Why per-pixel masks [A: required by function, the console's encoding is unknown]:
- In TR_PRESORT, in the PT passes, and in OPAQUE with OpInPt, volume edges do not end runs (isp §12.1). Yet
  `InVolume = stencil0 && shadow` is per pixel (tsp §2.3, isp §11.5). Hence `vmask`.
- A run is cut by tag (all 32 bits), valid bit and volume state only. In a PT pass run-only and fresh pixels share a
  run; in PT_MV a resolved PT tag can equal an opaque tag (the same parameter block in the OP and the PT list, or
  ISP_BACKGND_T pointing at a PT block), so `rendered` varies within a run. Hence `pmask`, per pixel, in both.

**Pass and entry boundaries are flags, not items** [I: the ispq fit, §3.5]. The last item of a SHADE carries
`eop`. The last item of an entry carries `eoe`. A `null` item is pushed only when a flag has no run to ride on: a PT
pass is never empty, and an empty non-PT SHADE emits nothing, so in practice a `null` item appears only when the
entry's end is decided after its last run was pushed (§3.4.8).

**Entry record** (`p2_entrec_t`, p2_isp_cut to p2_tbuf through `p2_entq`, `ENT_N` deep [G: 32]):
`{tilex, tiley, z_keep, no_writeout, last, shaded_any}`. `shaded_any` is refsw3's `tilePixelsShaded != 0`. The cutter
pushes it when it emits the `eoe` item; p2_tbuf pops it when the `eoe` item reaches it. A full `p2_entq` stalls the
cutter at the `eoe` item.

**Feedback** (`p2_fb_t`, p2_pp_blend to p2_isp_fb, PT passes only), valid/ready, in pixel order:
`{kind: PIXEL | PASS_DONE, idx[9:0], fail, ro}`. PASS_DONE comes after the pass's last PIXEL message, when the
`eop` item has left P11, and carries `anyfail`.

**Inside the ISP (M6, `p2_pkg`).** `p2_isp_obj_t` (p2_isp_olw to p2_isp_pfetch: one object list entry that draws, §3.4.2
"As built") and `p2_sweep_t` (p2_isp_ctl to p2_isp_buf: the sweep to run, §3.4.7; M6 has CLEAR and CLRSTATUS).

### 2.4 ISP setup to rasterizer descriptor (`p2_rdesc_t`)

Per primitive per tile (edge.h `EdgeTile` and depth.h `DepthTileT`, both at `4f3efe15`):

| field | bits | meaning |
|---|---|---|
| `tag`, `rm`, `depth_mode` (ISP word 31:29), `zwdis`, `quad` | 32 + 3 + 3 + 1 + 1 | |
| `sum_op` | 2 | MODIFIER only: 0 none, 1 OR (VolumeMode 1), 2 AND (VolumeMode 2). VolumeMode 3..7 is 0 (isp §15 #16) |
| `kill` | 1 | no pixel is inside: a culled or bad-corner primitive that still has a `sum_op` (§3.4.4) |
| `edge[0:3]` (`p2_edge_t`) | 4 x ~210 | below |
| `jf`, `jl`, `rows_v` | 5 + 5 + 1 | tile rows to step. Non-MODIFIER: the row range (isp §8.6) with the row-31 shift (§3.4.4 step 5, every polygon), clipped to 0..31. MODIFIER: 0..31 |
| `z` (`p2_ztile_t`) | ~140 | below |

**`p2_edge_t`** (edge.h `EdgeTile` at `4f3efe15`):

| field | bits | meaning |
|---|---|---|
| `const_v`, `const_in` | 2 | the whole tile has one answer: a bad corner (nothing inside), a point edge (inside), or `d = E - unit >= 30` (the start's sign; isp §8.5's proof, still valid: big edges have `d = 27`) |
| `t0` | 31 signed | start in half units of 2^unit (`unit = ep - 21`, or 102 for a big edge, whose start is cut toward zero: even, `|t0| < 2^27`) |
| `tx`, `ty` | 28 signed | column step (from -dy) and row step (from dx), in half units, even. Ordinary `|tx|, |ty| < 2^22`; big `< 2^27` |
| `zsh` | 4 | `zero2 = tie2 = 2^zsh` half units, `zsh = d - 20`: d = 27..29 for an ordinary edge, **27 for a big edge** (E capped at 129, unit 102): 7..9 (4 bits, `P2_EDGE_ZSH_BITS`) |
| `big` | 1 | E was capped (`ep >= 124`, a step of 2^123 or more): the walk below decides each row, on the same `t0`, `tx`, `ty`, `zero2` (refsw3's `f0`, `fx`, `fy`, `z`); `H = 2^30` half units (2^131) is a constant |
| `far32` | 31 | the walk's far-value term, precomputed: `tx > 0 ? (tx mod 2^25) << 5` (= `(32 sx) mod 2^131`), `tx < 0` with `tx mod 2^25 == 0` (sx a multiple of 2^126) `? 2^30` (= 2^131), else 0 |

The fields `f0` (34), `fx`, `fy` (30), `hsh`, `zfsh` and `708fb8cd`'s 36-bit `far32` are gone: since `1040c4aa` the
walk runs on the edge's own grid (isp §8.3, §8.4b).

**`p2_ztile_t`** (depth.h `DepthTileT::Setup` at `4f3efe15`; regime names are this document's). Every start (`r0`,
`S`) is the plane at the tile's **first sample point**, `(left, top)` plus `HALF_OFFSET[0] / 2` on both axes (isp
§9.3), and every pixel is whole steps from it, so no field or lane depends on HALF_OFFSET (`0de9776b`):

| regime | when | fields | per pixel |
|---|---|---|---|
| CONST | determinant infinite, or of 2^126 or more (`top(det) - 1 >= 126`; key 0, `4f3efe15`); zero plane or start and slopes below 2^-126 (key 0); determinant zero or perpendicular (`flat(mean)`); bad start with both slopes zero (`saturated` / `from_fp(cut19)`) | `key` (`p2_zkey_t`) | `key` |
| REG | a or b infinite (refsw3 `ovf = 2`) | `r0` (30 signed, units of 2^102, from `first0` at the sample point), `sa`, `sb` (2 signed, -1/0/+1), `fa`, `fb` (31 signed: the finite slope's step on the 2^102 grid, mod 2^30) | `regdepth(r0 + (sa i + sb j) 2^25 + i fa + j fb)` |
| BLOCK | otherwise, including a forced start of +-2^127 when the constant or the start overflowed (refsw3 `forced`) | `S` (28 signed: `d0` in half units of G), `DX`, `DY` (23 signed, units of G), `gexp` (10: G = 2^gexp), `E` (9: the clamped block exponent, -122..128), `nsh` (5 signed: `E - 15 - gexp`, -14..14 with a start), `fbw` (1: the start was cut to zero and `E - 15 - gexp < 0`: every pixel below zero is NegWord's fallback word, num A5) | `t = S + 2i DX + 2j DY` (30 signed); `t >= 0`: `cut19(t 2^(gexp-1))` then `big` from 2^128 else `from_fp`; `t < 0`: `fbw` ? the fallback word : `neg(E, nsh >= 0 ? t >>> nsh : t << -nsh)` |

refsw3's float form (`block == false` with a valid plane) needs `pair - 21 + 24 - unit > 100`. With
`startOnSlopes = 1` that is unreachable: a non-zero start cut onto the slopes' grid has `top >= pair - 20`, so the
left side is at most 49. The RTL has no float regime. The testbench asserts that refsw3 never takes it (num §8 A3
closed; revision 1's D3 is withdrawn).

`gexp = max(top(first), pair + 5) - 26` (unclamped). Every refsw3 value is a multiple of G: when the start's top is
at least `pair + 5`, `G = 2^unit`; otherwise the start was cut onto `2^(pair - 21) = G` and the slopes below it.
`|t| < 2^27 + 62 x 2^22 < 2^29`: isp §9.4a's bound, now without `h` (refsw3's `At` steps `h = centers -
startCenters` half pixels, 0 when asked at the point it set up at, which is what the ISP does: tile.cpp L813, L863).
`agents/spec-sync-depth/widths4f3d.cpp` (300,000 planes, both sample points) measured 2^28.45 at most, `nsh` -7..14
at pixels with a start, the fallback only at pixels no triangle covers. PLAN M3 asserts these on every pixel.
`708fb8cd`'s `h = -1` corner step (a start at the centre stepped back half a pixel) is gone: it is one of M3's
mutants.

## 3. Units

Each unit lists:
- **Function**: the spec sections and refsw3 functions it owns;
- **Interfaces**;
- **State**;
- **Cycle behaviour**: the mechanism, the measurement that pins it, and what is unknown.

### 3.1 `p2_regs`: registers, tables, events

**Function.** Owns isp §2 and tsp §0 (register tables).
- The 8 KB register block, with fields decoded through `p2_regs_pkg`. That package is generated from nulldc3
  `pvr_regs.h` (conv §5).
- FOG_TABLE (0x200-0x3FC, 128 x 16 used bits) and PALETTE_RAM (0x1000-0x1FFC, 1024 x 32) as RAMs.
- STARTRENDER (0x014) produces a `start` pulse. SOFTRESET (0x008) bit 1 produces `soft_rst`.
- `p2_regs` has no arithmetic. Each consumer decodes its fields itself: perpVal in p2_isp_setup and p2_tsp_setup
  (num §2.12); FPU_CULL_VAL in p2_isp_setup.

**Interfaces.**
- Register port (§1.2).
- Every other register is a live wire, as refsw3 reads them at the time of use. Mid-render CPU writes to registers
  other than the palette and the fog table are GAP, and out of scope for p2-offline.
- PALETTE_RAM read ports: four per clock (the four bilinear texels, p2_tex_decode), plus the CPU write port.
- FOG_TABLE read port: one per clock (p2_pp_fog).

**Cycle.**
- A palette write is visible to a read in the next clock [G]. timemeas TM_ORDER shows the TSP seeing a new entry
  within ~5 px.
- A CPU write never stalls a reader [G]. The ~1 glitch pixel a scene is GAP (tim §3.9).

### 3.2 `p2_mem`: VRAM clients and arbitration

**Function.**
- The address views (conv §7.3): the 32-bit area through `pvr_map32`, and the 64-bit area at
  `& (VRAM_MASK - 7)`, wrapping at 8 MB as refsw3 does. Owns tsp §9.3 "64-bit view" and isp §3 "32-bit view".
- Six clients, each with its own in-order response channel.
- Out-of-range behaviour is refsw3's: wrap at 8 MB. The console draws nothing there, or reads run-to-run varying
  data (README texctl); GAP isp §15 #14.

**Client interface** (client N):
- request: `cN_v`, `cN_rdy`, `cN_we`, `cN_addr[23:0]` (byte address in the client's view), `cN_w64`, `cN_be[7:0]`,
  `cN_wdata[63:0]`;
- response: `cN_rv`, `cN_rdata[63:0]`.

| client | view | access | owner |
|---|---|---|---|
| C0 | 32-bit | region array reads | p2_seq |
| C1 | 32-bit | object list reads | p2_isp_olw |
| C2 | 32-bit | ISP parameter reads | p2_isp_pfetch |
| C3 | 32-bit | TSP parameter reads | p2_tsp_pfetch |
| C4 | 64-bit | texel words, VQ code book entries, VQ index bytes | p2_tex_cache |
| C5 | 32-bit; 64-bit view for render to texture (FB_W_SOF1 bit 24) | framebuffer writes with byte enables | p2_wout |

**Arbitration.**
- One grant per half per clock. A 64-bit request is granted only when both halves are free.
- Fixed priority [G]: C5 > C4 > C3 > C2 > C1 > C0. The console's policy (SDRAM_ARB_CFG = 0x1f) is GAP T14.
- No buffering beyond one request register per half [G].

**Cycle.** `p2_mem` adds one clock (the request register). Everything else about VRAM timing is the testbench
model's.

**As built (M6, `rtl/v1/mem/p2_mem.sv`; PLAN M6).** Clients C1 and C2 are connected, the others tied off (`tb/isp_tile`).
Where it differs from the text above:
- **The client interface has a response ready**, `cN_rrdy`, and **the response buffer of a client is in `p2_mem`**: per
  client an order FIFO (which halves each outstanding read waits for) and per client and half a response FIFO of
  `RSP_N` = 8 [G] words. A client may have at most `RSP_N` reads outstanding from grant to its pop (`cN_rv && cN_rrdy`):
  `cN_rdy` stays low past that, so the VRAM ports need no ready on their responses (§1.2 as written) and the FIFOs never
  overflow (asserted). A client's reads come back in its own request order whichever half answers first (the
  `order-by-arrival` mutant).
- A 32-bit request takes half `a[22]`, word `a[21:2]`; bits 23 and up are dropped, which is `pvr_map32`'s 8 MB wrap
  (its static bits are only `a[1:0]` with 8 MB). The 64-bit view (`cN_w64`) takes word `A[22:3]` of both halves.
- The VRAM model (`tb/common/vram_model.h`, §3.2.1) has a request queue of 4 a half, `VR_LAT` 8, rows of 512 words with
  `VR_ROW` 2 [G] (not fitted yet). `+vramvary` adds 0 .. 12 clocks to a request, drops `vh_req_rdy` one clock in four at
  random, and stalls a half for up to 63 clocks one clock in 64. The hazard detector's bitmaps are there (no client
  writes in M6).

#### 3.2.1 The VRAM model (`tb/common/vram_model.h`; testbench, not RTL)

Data comes from `refcore::emu_vram` in the 64-bit physical order: half 0 is bytes `8w..8w+3`, half 1 is
`8w+4..8w+7` (conv §7.3).

**Visibility rule** [A for the model; the console's point is GAP]: a request takes effect **at the clock it is
granted**. A write commits to `emu_vram` then. A read samples `emu_vram` then and returns the data `VR_LAT` clocks
later. Reads and writes of one render are thus ordered by grant time.

**Per half**:
- a request queue;
- a read latency `VR_LAT` (default 8 [G]);
- a row model: an access to a row other than the open one costs `VR_ROW` clocks (default fitted to the write-out's
  ~10.4 clk a line, tim §3.11 [G]; the row size from SDRAM_CFG is GAP);
- refresh: `VR_RC` clocks every `VR_REF`, from SDRAM_REFRESH (GAP);
- optional display stalls (~300 clk a 64 µs line [M tim §3.14]; off by default, as timemeas runs);
- `+vramvary=<seed>`: random extra latency;
- `VR_LAT` sweep builds, caique's RAM_LAT style (reuse §2.2). Gates state the value they assumed.

**The hazard detector.** refsw3 finishes tile k's framebuffer writes before tile k+1 is processed. The RTL overlaps
them with later tiles' shading, the texture cache and parameter read-ahead. So a render whose reads (C0-C4) touch a
word that C5 writes in the same render can legitimately differ from refsw3, as it does on the console
[M texctl_bank, earlier version: 376-864 px on 3 pages, "what the write-out has put there yet"].
- The model keeps two bitmaps of 2M 32-bit words per render: written by C5, and read by C0-C4.
- At render end, a non-empty intersection marks the render **VRAM-race**. The `p2:` line reports the count and the
  first word.
- The functional gates compare VRAM-race renders but report them in their own class, never as a pass or a fail
  (PLAN §1.6). They are race scenes, like the `*_races` tests.
- `+vramvary` and every `VR_LAT` must give identical pictures on every render **not** marked VRAM-race. On marked
  renders the picture may change; that is the race.

### 3.3 `p2_seq`: tile sequencer

**Function.** Owns isp §3.1 and the walk part of isp §1 (lists.cpp `ReadRegionArrayEntry`, the RenderCORE loop).
- Reads region array entries from REGION_BASE: 6 words if FPU_PARAM_CFG[21], else 5.
- Decodes the control word and the five list pointers. For 5-word entries the PT list is empty and `pre_sort` comes
  from ISP_FEED_CFG[0].
- Emits entries in memory order up to and including `last_region` (a do-while).

**Interfaces.** Out: `ent_v`, `ent_rdy`, `ent` (`p2_entry_t`). Memory: C0.

**State.** Next entry address (24 bits), an entry FIFO `SEQ_AHEAD` deep [G: 2], the render-running flag.

**Cycle.**
- One 32-bit read a word. Entries are fetched ahead.
- [M] A tile with nothing to do costs 335 clk plus its write-out (tim §3.1). This unit's share is the entry fetch
  latency; the split is GAP T1.

### 3.4 ISP

The ISP works on one entry at a time. Its units share one per-pixel state (`p2_isp_buf`). It runs ahead of the TSP
by the run stream's capacity. It waits for the TSP only:
- in punch-through passes (the alpha test feedback, §3.4.1);
- when the run queue or `p2_entq` is full.

#### 3.4.1 `p2_isp_ctl`: entry, phase, chunk and pass controller

**Function.** The phase order of isp §1 and §4.1, exactly as refsw3 RenderCORE (lists.cpp) runs it:

```
!z_keep: buf.CLEAR(key = bgkey(ISP_BACKGND_D), tag = ISP_BACKGND_T)        isp §4.2 (superseded below zero, §0.1)
 z_keep: buf.CLRSTATUS (valid = rendered = 0)
if OP:   walk(OP, OPAQUE); if OP_MOD: walk(OP_MOD, MODIFIER)             isp §4.1, §11.1, §11.2
OpInPt = PT && olw.scan_has_prim(PT)                                       isp §11.3
SHADE(OPAQUE)                                                              isp §12
if PT:   buf.PT_INIT; pcache.reset
         for chunk = 0, 1, ...:                                            (until the walk has met end of list)
            chunk > 0: buf.PT_CHUNK
            for pass = 0, 1, ...:
               buf.PASS_START                    (rlp := rcur; rcur := 0)
               more = 0
               pass == 0: walk(PT, PASS0) through ptc: fills pcache with this chunk's members (§3.4.11)
               pass >= 1: replay(pcache, PASSN)
               if !more: break
               SHADE(PT_PASS0); wait PASS_DONE; if !anyfail: break
         buf.PT_FINAL
         if OP_MOD: walk(OP_MOD, MODIFIER); SHADE(PT_MV)                   isp §11.4 PT_MOD
if TR:   pre_sort: buf.CLRSTATUS; walk(TR, PRESORT) with SHADE(PRESORT) after every primitive      isp §11.5
         else:     buf.SAVE; pass = 0
                   do { buf.PEEL(bits(0x7F7FFFFF)); more = 0;
                        pass == 0 ? walk(TR, AUTOSORT) filling pcache : replay(pcache, AUTOSORT);
                        if TR_MOD: walk(TR_MOD, MODIFIER); SHADE(AUTOSORT); pass++ } while more;
                   buf.RESTORE                                                                isp §11.6
entry end: the last SHADE's last item carries eoe, or a null eoe item (§3.4.8)
```

- A **walk** is: olw streams primitives; pfetch assembles them; setup computes descriptors; ptc gates them (PT
  pass 0); pcache records them (PT pass 0, AUTOSORT pass 0); the raster steps rows; pix applies the rule. A walk is
  **done** when olw reports end of list (or ptc reports "chunk full", PT) and the raster pipeline is empty.
- A **replay** feeds pcache's descriptors to the hand-off register in their recorded order. It has no olw, pfetch or
  setup work. When pcache overflowed during the fill, the replay is a walk instead (§3.4.11).
- `more` is refsw3's MoreToDraw. p2_isp_pix sets it in PT and AUTOSORT walks; p2_isp_fb carries `anyfail` for the
  PT SHADE.
- **The modifier volume summary has no phase of its own.** The closing triangle applies it in its own row writes
  (§3.4.7). A closing triangle that setup culls or finds a bad corner in still goes to the raster as a `kill`
  descriptor (§3.4.4), because refsw3's RenderTriangle summarizes after every VolumeMode 1/2 triangle, rasterized or
  not.
- **PT chunks** follow refsw3's membership exactly (§3.4.10). refsw3 re-counts the list from its start in every
  pass. The RTL counts once, continuing the walk at the primitive that did not fit. Both give the same members,
  because the count depends only on the list and the cull verdicts.
- Also owns the GAP choices isp §15 #16-18 as refsw3 has them: VolumeMode 3..7 is 0; keep Z keeps the stencil;
  OP_MOD is never walked with neither an OP nor a PT list.
- **Pre-sorted TR-modifier glitch** [M timemeas tables.txt 14: a pre-sorted tile with an empty opaque list and a
  translucent modifier volume once skipped its background, ~1000 clk less, blended over the previous render's
  buffer; history-dependent]. refsw3 never skips the background, and neither does the RTL. The decision
  "SHADE(OPAQUE) of this entry" goes through one sub-block, `p2_isp_ctl_tg`, which is a pass-through until T21
  finds the set / clear rule.

**Interfaces.**
- Entry in.
- Commands:
  - to olw: `walk` or `scan`, list address, rm;
  - to pcache: `fill`, `replay`, `reset`;
  - to ptc: start of PT walk;
  - to buf: the sweep ops;
  - to cut: `shade(rm, last_of_entry)`, plus "this primitive's rows" for PRESORT.
- Status in: `more` from pix, `walk_done`, `cut_done`, `pass_done` + `anyfail` from fb, `chunk_full` and `list_end`
  from ptc / olw.

**State.** Phase, OpInPt, chunk, pass, `more`, the current entry.

**As built (M6, `rtl/v1/isp/p2_isp_ctl.sv`).** The phases Z (CLEAR with `bgkey(ISP_BACKGND_D)` and ISP_BACKGND_T, all
32 bits; CLRSTATUS for keep Z), OP and OP_MOD (only with an OP list); then the entry ends (OpInPt, the SHADE passes, PT
and TR are M7's). A walk ends when olw, pfetch, setup, the raster and pix are all idle (each has an `idle` output; M6 added
them to M4's `p2_isp_setup` and `p2_isp_raster`). **The phase halt** (sim, PLAN §1.3): with `halt_en`, after each phase
the controller sits in a halt state with `halted` and `halt_phase` (tb/common/isp_live.h's numbers: Z 0, OP 1, OP_MOD 2)
until `resume`; a phase the entry does not have neither runs nor halts. Each transition is one clock (`CTL_T`).

**As built (M7, `rtl/v1/isp/p2_isp_ctl.sv`; PLAN M7).** Every phase of the function above, in RenderCORE's order. A
sweep, a list walk and a SHADE are generic states with the phase in a register; one state (`S_NEXT`) halts and sets up
what follows. Where the tree differs from the text:
- **OpInPt** is olw's scan (`walk_scan`, olw `has_prim`: the list *holds* a primitive), run between OP_MOD and the OPAQUE
  SHADE. The OPAQUE SHADE's issue goes through `p2_isp_ctl_tg` (a pass-through, `shade_in` = 1).
- **A punch-through chunk after the first** starts its pass 0 by moving ptc's current chunk (`pt_set_cur`): the
  descriptor ptc held in setup's 1-deep hand-off is its first member, and olw, pfetch and setup, which waited behind it
  by back-pressure, go on (olw has no pause command). Between walks ptc passes nothing (§3.4.10 as built).
- **A chunk that overflows pcache** (more than `PCACHE_N` = 256 descriptors) puts ptc in full-walk mode for the rest of
  the punch-through phase: every later walk starts at the list's start with the counter restarted, and a descriptor of
  another chunk is dropped, not held (refsw3's own way of walking). scenegen's PTLONG scenes (a third generator) reach
  it; a chunk holds at most 340 triangles (size 0x3ff).
- **TR_PRESORT**: ctl blocks the hand-off (`ho_block`) after each descriptor the raster takes until its rows are written
  (the raster and pix idle) and its SHADE is issued. A culled or bad-corner primitive has no descriptor and gets no
  SHADE: refsw3's SHADE after it is empty (every valid pixel was shaded by the SHADE before).
- **The entry's end** (§3.4.8): the SHADE ctl knows at its issue to be the entry's last carries `last` (OP_SHADE with
  no PT and no TR list, PT_MV_SHADE with no TR list, the sort's pass that found `more` = 0); otherwise END sends the
  cutter a null eoe item. The next entry is accepted when END (or the entry's last sweep, RESTORE) is done.
- **Phase halt**: every halt first waits for the cutter to be idle, so that a phase's runs are all out (TR_PS's last
  SHADE too). In free-running mode nothing waits for the cutter but its command slot and PASS_DONE.
- `P2_PTCARRY` is a parameter; only 0 is built (a simulation `$fatal` otherwise) until T12.
- Status outputs for the testbench: the entry's punch-through chunks, passes (walks), SHADEs and sort passes
  (`st_*`).

**Cycle.**
- Each controller transition takes one clock [G; §6 `CTL_T`, T13].
- A pointer to an empty list costs 20-31 [M tim §3.1]: olw's first read.
- The fixed 142 of Z clear and background setup, and the 55-90 a tile with seen polygons, are GAP T1 / T13.
- **Entry k+1 starts** (its Z phase) as soon as entry k's last SHADE has been issued to the cutter. buf's row
  barrier (§3.4.7) holds every row write of entry k+1 until the cutter has passed that row. This is how the ISP runs
  on entry k+1 while the TSP shades entry k [M tim §3.1: "with one dummy entry in front, the first ~1000 clk of the
  tile's ISP work are free"].
- **A PT pass waits for its PASS_DONE** (refsw3 order). PASS_DONE comes after the pass's last pixel, which is behind
  every item queued before the pass: up to ~436 runs, about 14 background tiles when the ISP is far ahead (§3.5). So
  this default makes **every PT pass drain the whole run stream**, and the ISP's lead collapses in every tile with a
  punch-through pass. That is a strong claim no test has checked: probe T20.
- **PT chunk carry race** (isp §11.4 "Timing-dependent", tim §2.2 item 4, README ptchunkcarry_races). Facts: with A
  and k fillers in a chunk and B in the next, the pixels A resolved take part in B's first pass as run-only pixels for
  k = 0..5 always, never for k = 8, 9; for k = 6, 7 only in the first tile row and in the first tile after empty
  ones. refsw3 never carries, and neither does this default. The two candidate mechanisms, which T12 must tell
  apart:
  - **K1, early chunk exit.** ctl leaves chunk c after the cutter has finished the chunk's last SHADE, without
    waiting for its PASS_DONE. PT_CHUNK is applied later, behind the feedback, and B's raster in chunk c+1 can read
    rows the sweep has not reached. Carry happens when B's rows are rasterized before the chunk's last feedback has
    landed, so more fillers (more set-up time before B) carry less. This needs a rule for an `anyfail` that arrives
    after the exit (replay the chunk, or a rule the console has). It predicts **more** carry when the TSP is far
    behind (ISP ahead).
  - **K2, the chunk sweep keeps the last pass's resolves.** PT_CHUNK does not clear `rcur` and does not fold
    `resDepth` into `depthC` for pixels resolved in the chunk's last pass, until some later event. Until then those
    pixels look "resolved last pass" to chunk c+1's pass 0 and join B's runs. The race is between that event and B's
    raster rows. Its direction against the ISP's lead depends on what the event is.

  Either mechanism lives in `p2_isp_ctl` (the wait) and `p2_isp_buf` (the sweep), selected by `P2_PTCARRY` (0
  refsw3, 1 K1, 2 K2). Until T12, the carrying cells are expected failures keyed to T12 (PLAN §1.5).

#### 3.4.2 `p2_isp_olw`: object list walker

**Function.** Owns isp §5 and §3.2 (lists.cpp `RenderObjectList`, `ObjectListHasPrimitive`).
- Reads words from `ptr * 4` upward.
- A strip (bit 31 = 0) gives triangles i = 0..5 whose mask bit (5 - i) is set, in that order.
- Type 100 gives `prims + 1` triangles, type 101 `prims + 1` quads.
- Type 111 is a link: `end_of_list` (bit 28) stops; otherwise the walk jumps to `next_block_ptr * 4`.
- Type 110 is ignored (GAP, isp §15 #15).
- `scan` mode is `ObjectListHasPrimitive`: true at the first strip with a mask or the first array, false at
  `end_of_list`.
- **Pause**: when ptc reports "chunk full", olw and pfetch hold their position (list pointer, strip block and index,
  read-ahead) until ctl starts the next chunk's walk.

**Interfaces.**
- Command: `addr[23:0]`, `rm`, `mode`; `pause`, `resume`.
- Out: `prim_v`, `prim_rdy`, `prim` (`kind` STRIP_TRI / TRI / QUAD; `offs[20:0]`: the block for an array, the strip
  block for a strip; `skip`, `shadow`; `i[2:0]` (strip index); `n` (array count)). Then `walk_done`, `has_prim`.
- Memory: C1.

**State.** The read pointer, a read-ahead word buffer `OLW_AHEAD` [G: 8 words].

**Cycle.**
- [M] An empty list costs 20-31 clk: this unit's first read latency, through p2_mem and the VRAM model.
- Following a link costs one more read latency [G].
- Whether the walker reads in blocks is GAP T1.

**As built (M6, `rtl/v1/isp/p2_isp_olw.sv`).**
- olw hands pfetch **one item per list entry that draws** (`p2_pkg::p2_isp_obj_t`: kind STRIP / TRI / QUAD, `offs`,
  `skip`, `shadow`, the strip's `mask`, the array's `prims`), not one per triangle: pfetch reads a strip's block once and
  makes its triangles (§3.4.3). A strip with an empty mask, type 110 and links never leave olw.
- The `OLW_AHEAD` = 8 read-ahead: olw requests consecutive words while fewer than 8 are requested and not consumed; the
  words wait in `p2_mem`'s response buffer for C1. At a link (or the end) the words requested past it are counted and
  dropped as they come back, in order; in the clock a link is consumed no new word is requested.
- `scan` (ObjectListHasPrimitive, OpInPt) and the chunk pause are M7's.

**As built (M7).** `cmd_scan` makes the walk a scan (refsw_lists.cpp `ObjectListHasPrimitive`): nothing is handed on;
it stops at the first strip with a mask bit or the first array (`has_prim` = 1) or at end_of_list (0), dropping the words
read ahead as at a link. The chunk pause is back-pressure only (§3.4.1 as built).

#### 3.4.3 `p2_isp_pfetch`: parameter fetch and primitive assembly

**Function.** Owns isp §3.3, §3.4 and §3.5 (lists.cpp `RenderTriangleStrip` / `Array` / `QuadArray`,
`CoreTagFromDesc`, `decode_pvr_vertices`).
- Block address: `(PARAM_BASE & 0xF00000) + offs * 4`.
- Reads word 0 (the ISP/TSP word). The header is 3 or 5 words; vertices are `3 + skip * (1 + twoVol)` words, with
  `twoVol = shadow && !FPU_SHAD_SCALE[8]`. Of each vertex it reads x, y and z (IEEE bits).
- **Strip**: one block of up to 8 vertices. Triangle i has corners (v[i], v[i+1], v[i+2]) when i is even, and
  (v[i+1], v[i], v[i+2]) when i is odd. Reading only the vertices the mask needs gives the same result.
- **Triangle array**: back-to-back blocks, each with its own header and 3 vertices. The tag offset is 0. The tag's
  `param_offs` is the block's own.
- **Quad array**: as the triangle array, with 4 vertices.
- **Tag** (CoreTagFromDesc): `{3'b0, ISP word bit 21 (cache bypass), shadow, skip, param_offs, i}`, 32 bits.

**Interfaces.**
- In: prim stream.
- Out: `asm_v`, `asm_rdy`, `asm` (`p2_pkg::p2_asm_t`, M4):
  - `isp` (the ISP/TSP word), `tag`, `rm`;
  - `x[0:3][31:0]`, `y[0:3][31:0]`, `z[0:2][31:0]` (raw IEEE single bits, rasterizer order);
  - `quad`;
  - `tilex`, `tiley`: the tile the primitive is set up in (the setup is per primitive per tile).
- Memory: C2.

**State.** A strip vertex buffer (8 x 3 words). An assembled-primitive FIFO `PF_AHEAD` [G: 2].

**Cycle.**
- [M pfetch] 4 or 8 more words a primitive add ~0 clk. So the fetch runs at least one primitive ahead of setup,
  hidden behind the 16-clk setup.
- [M] Strips cost 16 for the first triangle, then alternately ~19 and 15 (18, 19, 15, 19, 15). The mechanism is GAP
  T2. Candidates: a strip block's 64-bit-aligned vertex reads; the odd triangles' corner swap costing a reload.

**As built (M6, `rtl/v1/isp/p2_isp_pfetch.sv`).** Three stages: a **sequencer** (one word request a clock to C2, at most
`PF_OUT` = 8 [G] outstanding, each with its role in a role FIFO: the ISP/TSP word, or vertex v's x, y or z), an
**assembler** (the responses in order into one of **two vertex buffers**, 8 vertices x {x, y, z} and the ISP/TSP word;
a buffer is handed on when its group's last word is in: a strip, or one array primitive) and an **emitter** (a strip's
triangles one a clock, an array's primitive, into the `PF_AHEAD` = 2 asm FIFO). A strip's vertices are read up to the
last one a set mask bit needs (refsw3 decodes all 8: the same corners). An array primitive's tag offset is its block's
offset from the masked PARAM_BASE in words, cut to 21 bits; its next block follows its last vertex.

#### 3.4.4 `p2_isp_setup`: per-primitive, per-tile setup (precalculation)

**Function.** Owns isp §6, §7, §8.1-8.3, §8.6, §9.1-9.5 setup parts (with §0.1's supersessions), num §4.2 (edge
and ISP depth flavours). refsw3: tile.cpp `RasterizeTriangle` up to the row loop, `TriangleCulled`; edge.h
`Winding` (bad corners only), `EdgeWinding`, `EdgeTile::Setup`, `RowRange`, `SetFirstRow`; depth.h
`DepthTileT::Setup`. Inputs are the corners in rasterizer order; outputs are `p2_rdesc_t` (§2.4).

1. **Bad corners**: any of x, y of corners 1-3 (and 4 for a quad) infinite or NaN (`FromBits` `bad`). Nothing is
   drawn and nothing is culled. Plain `Winding` contributes only this flag; its determinant is no longer used.
2. **The swamped determinant** (edge.h `EdgeWinding`, unranged 24/24/25, `FromBits` inputs). With
   `sw(v) = v >= 2^128 ? {v.neg, 0, 200, 1} : v` (num H7a's replacement, §3.11):
   `e(j,k) = sw(Sub(sw(x_j y_k), sw(x_k y_j)))`, `e1 = e(1,2)`, `e2 = e(2,0)`, `e3 = e(0,1)`,
   `det = sw(Add(sw(Add(e1, e2)), e3))`. Two swamp values of one sign cancel exactly to +0 (the Add's cancellation
   rule); a swamp value drops any finite operand (reach 25). `sgn = (det.neg && det != 0) ? +1 : -1`.
   [M faredge_m131, faredge_ecap, faredge_walk, faredge_far32: plain determinant 296 / 1,007 / 647 / 408 tiles
   wrong, swamped 0.]
3. **Cull** (CullMode != 0, no bad corner) on the **swamped** `det`: CulledBySize against `|FPU_CULL_VAL|`, then
   CulledByFacing (num H9) [M faredge_cull: 484 of 1,200 regions wrong with the plain determinant].
4. **Edges**, per edge per tile (edge.h `EdgeTile::Setup`; quads have E12, E23, E34, E41, the winding from corners
   1-3):
   - `c = sw(Sub(sw(xb ya), sw(xa yb)))`. The products are those of step 2, in the other order, so they may be shared;
     each edge computes its own Sub, because the zero's sign can differ between `c` and `-e`.
   - `dx = Sub(xa, xb)`, `dy = Sub(ya, yb)`; `dxP = sw(dx)`, `dyP = sw(dy)` for the start's products; the steps use
     `dx`, `dy` saturated to +-2^127 when at least 2^128 [M hugepos_v4-v6, hugepos_cov, hugepos_sw2, hugepos_rules
     page 8].
   - `first = sw(Add(sw(dxP y0), -sw(dyP x0)))`; `start = Add(first, c)`; `start >= 2^128` gives +-2^127.
     [M faredge_cmax 4,800 / 4,800 tiles; faredge_k132.] There is no 2^132 rule and no wide add.
   - `s20 = cut20(start)`, `sx = cut20(-dy)`, `sy = cut20(dx)`, `ep = max(top dx, top dy)`, `es = top start`,
     `E = min(max(ep + 6, es + 1), 129)` [M faredge_m131, faredge_ecap: 129 exact; 130 has 1,424 tiles wrong],
     `unit = ep - 21`, or `E - 27 = 102` when E was capped (`big`) [M edge2_walk pages 3-5: 900 / 900 tiles; 2^(E - 26)
     240 wrong, `708fb8cd`'s two grids 339], `d = E - unit`.
   - Blocking into `t0`, `tx`, `ty`, `zsh`, or `const`: the steps cut below `unit` toward zero; `t0` floored with the
     half-unit bit, or for a big edge `s20` cut toward zero onto 2^102 with no half unit [M edge2_walk pages 3-5: 5
     tiles wrong floored]. A big edge adds only `far32` (§2.4); its walk uses these fields.
5. **Row range** (isp §8.6, edge.h `RowRange`, not for MODIFIER): `floor(y)`, `floor(y + 1/2)` through FloorScaled
   (num H11, clamp 2^40), min and max over the corners. Then:
   - **the row-31 shift**: if the first row is the tile's row 31, the first row becomes 30, for every polygon
     [M faredge_walk pages 0-3: 366 of 3,537 tiles wrong without; faredge_far32 390 against 0; edge2_walk page 6:
     43 tiles wrong with the shift for big edges only (`6784ea3d`), 0 for every polygon; edge2_row31 300 / 300, the
     user tile clip has no part]. `jf` no longer waits for step 4's `big` flags;
   - clipped to the tile to give `jf`, `jl`. A big edge's walk starts at `jf` (refsw3 `SetFirstRow`), and at row 0
     for MODIFIER.
6. **Depth plane**, ranged (depth.h `Setup` L415-426 at `4f3efe15`; `FromSingle(., 1)` inputs). The depth flavour of H10:
   - every product and every sum is checked against 2^128 and 2^-126 where it is made: a product below 2^-126 is a
     zero with its sign, a sum below it is +0;
   - **the zero rule**: a zero added to a number of 2^-126 .. 1.5 x 2^-126 of the other sign gives +0; added to any
     other number it gives that number exactly; every zero sum is +0 [M depthgaps_zadd 109 / 109,
     depthgaps_field1 2,000 / 2,000]. Since `0de9776b` also in the depth unit's own coordinate differences, edges
     `x_j y_k - x_k y_j` and determinant (refsw3's `subC`, `addE`, isp §6.3) [M depth2_zcoord 80 / 80, depth2_zedge
     65 / 65]; these are computed with the depth flavour and are **not** shared with step 2 / 4's edge values, which
     have no zero rule (isp §6.2). Every addition of the depth program issues with the zero rule on;
   - an infinite operand: `bad`, as the TSP flavour (zero times infinity is zero; infinities of opposite sign sum to
     +0).

   `a = sum3(z_k (y_j - y_l))`, `b` likewise, `c = (z1 e1 + z3 e3) + z2 e2`, `det = (e1 + e2) + e3`;
   `Perpendicular(det)` makes det zero.
7. **Depth regime and tile start** (§2.4 table), in refsw3's order:
   - det infinite: CONST key 0 [M trsort_recip page 10, trsort_auto];
   - `|det| >= 2^126` (`top(det) - 1 >= 126`, exactly 2^126 included): CONST key 0, whatever a, b, c are
     (`4f3efe15`, the reciprocal's range) [M trsort_recip 160 / 160 (2^126 kept: 24 wrong), trsort_recipovf 80 / 80,
     trsort_auto 240 / 240, trsort_garb 160 / 160]. A compare on det's exponent before the reciprocal issues; the
     program runs on (§3.4.4 Cycle: depth never shows in the time) and the regime mux selects CONST;
   - det non-zero: `inv0 = recip24(det)` (det in [2^-126, 2^126), so `inv0` in (2^-126, 2^126]),
     `first0 = ((a x00 + b y00) + c) inv0` at the tile's **first sample point**, `x00 = left + HALF_OFFSET[0] / 2`,
     `y00` likewise (`0de9776b`) [M depth2_halfc, depth2_halfo 16 / 16];
     - a or b infinite: REG, with `sa`, `sb`, `fa`, `fb` (`a inv` cut to 20 bits, then to 2^102 toward zero, mod
       2^30) and `r0` (a bad `first0` is +-2^25, else `cut20(first0)` on 2^102 toward zero) [M zovf_creg,
       zovf_wrap, nantr_pos, depthgaps_rstart, depthgaps_rcut; depth2_cneg (toward zero below 2^102 too),
       depth2_halfc (the start at the corner)];
     - `first0` or c bad: with both slopes zero, CONST `saturated` / `from_fp(cut19(first0))`; otherwise BLOCK from a
       forced start of +-2^127 (or `first0`) [M depthgaps_infstart, depthgaps_edges, zovf];
   - det zero or perpendicular: CONST `flat(mean)`, with `mean = ((z1 + z2) + z3) x OneThird()` and the infinite
     corner rule (an exponent-field-255 corner adds as an infinity; two of opposite sign as their fractions say)
     [M perpmean_word 16,384 / 16,384, depthgaps_dzinf 48 / 48];
   - otherwise BLOCK: `A = a inv`, `B = b inv` (24 bits), `under()` on A, B, first; `pair`; start
     `cut20(first)`, then onto `2^(pair - 21)`; `gexp`, `E`, `S`, `DX`, `DY`, `nsh`, `fbw` (§2.4). A zero start with zero
     slopes is CONST 0.
8. **Summary-only descriptor.** A MODIFIER triangle with VolumeMode 1 or 2 that is culled or has a bad corner is
   still handed over, with `kill = 1` and its `sum_op`, so that the raster applies the summary (§3.4.7). Every other
   culled or bad primitive skips the hand-off.

**Datapath.** One microprogrammed datapath, `p2_isp_alu`:
- `ISP_NM` truncating multipliers (num H5 24x24 to 24), each with the H10 depth-flavour wrapper switchable per issue;
- `ISP_NA` adders (num H6 24/25), the same;
- one reciprocal (num H8; refsw3's `inv0`, `inv` and `invS` are one value);
- the swamp compare (§3.11), H9 and H11;
- an operand register file.

**The programs are generated, not written** [A for the method; the result is checked against [M]].
- `tools/gen/gen_setup_prog.cpp` holds, per primitive class (TRI, QUAD, MODIFIER TRI), the operation graph of the
  refsw3 functions above: nodes are pvr_softfp operations, edges are data dependencies.
- A **graph check** proves the graph is refsw3. Evaluated with pvr_softfp, the graph's outputs equal
  `RasterizeTriangle`'s setup and `DepthTileT::Setup` on random and directed primitives (PLAN M4).
- A **list scheduler** maps the graph onto `ISP_NM` multipliers, `ISP_NA` adders and one reciprocal with latencies
  `L_MUL`, `L_ADD`, `L_RCP`. It emits the microprogram ROM (an SV package) and the program length.
- The free parameters are the resources and latencies (§6), never the program length. The measured lengths (16
  triangle, 19 sprite) are a **check** on those parameters (PLAN MT1). If no parameter set gives 16 and 19, the graph
  or the structure is wrong, and the program is not padded.

Operation count per triangle per tile, without sharing (the scheduler's input; it may share the step 2 / step 4
products):
- swamped determinant: 6 multiplies, 5 adds;
- 3 edges: 6 multiplies (`dxP y0`, `dyP x0`), 3 Subs for `c` (products shared), 6 Subs for dx, dy, 6 adds for
  first and start;
- depth: 6 coordinate differences, 15 multiplies (terms of a, b, c, e's), 11 adds, 1 reciprocal, 5 multiplies and
  2 adds for `first0`, A, B, plus REG's 2.

That is about 33 multiplies, 37 adds and 1 reciprocal. A quad's 4th edge adds 2 multiplies and 5 adds.

**As built (M4, `tools/gen/gen_setup_prog.cpp`; PLAN M4).** The scheduler's input counts, without the sharing of the
determinant's products with the edges' `c` that the graph makes: TRI and MODIFIER TRI 33 multiplies, 41 additions, 1
reciprocal; QUAD 39, 46, 1 (the quad's E31 and E41 need 4 products of their own, and the 4th edge's dx, dy, first and
start). The units' flavours are per issue (`p2_isp_alu`): multiplies MUL_E (Mul, then the swamp; operand a may be read
through the swamp: `dxP`, `dyP`), MUL_R (the depth setup's ranged `mul`), MUL_U (A, B); additions ADD_E (plain, then
nothing, the swamp or the saturation), ADD_Z (the depth setup's `addRule`, every zero-rule switch 1; the post-operation
PERP is FPU_PERP_VAL), ADD_M1 / ADD_M2 (the determinant-zero mean's sums with the corners' fractions); the reciprocal.
The depth unit's products are its own (the PLAN M4 mutant "the shared product used for the depth unit" fails the graph
check). Every value has its own register (106 over the three classes, the 20 inputs loaded at the accept). The graph's
outputs are the values the **hand-off step** reads (each edge's dx, dy and saturated start, the swamped determinant; the
depth unit's a, b, c, det, first0, A, B and the mean): the fixed logic after the arithmetic runs there, one copy shared
with M2 / M3's fixed-latency units: `p2_isp_edge_steps` (sat, cut20, ep), `p2_isp_edge_fin` (the blocking),
`p2_isp_rowrange` and `p2_isp_rowclip` (the rows), `p2_fp_cull` on the swamped determinant, `p2_isp_depth_fin` (the
regime and the fields, `flat(mean)`). The graph check (PLAN M4 item 1) compares the outputs with verbatim copies of
refsw3's code (`tb/isp_setup/ref_copies_setup.h`) and EdgeWinding.

At the ARCHITECTURE 6 parameters (`ISP_NM` 3, `ISP_NA` 3, `L_MUL` 1, `L_ADD` 2, `L_RCP` 2) the scheduler gives **TRI
16** (culled / bad 15), **QUAD 18**, MODIFIER TRI 16: the triangle and the culled triangle are the measured 16 and
15.05 - 15.1, **the sprite is one clock short of the measured 19 (18.9)**. No parameter set of the sweep (`make
isp-prog-sweep`: `ISP_NM`, `ISP_NA` 1 .. 6, `L_MUL`, `L_ADD` 1 .. 3, `L_RCP` 1 .. 6) gives 16 and 19 together; the
nearest are 16 / 18 (`L_ADD` 2, the chosen set) and 16 / 17. With the real M2 / M3 datapaths the quad's extra work (6
multiplies, 5 additions) costs 2 steps on three adders, not 3; the program is not padded (above). Where the third clock
comes from is GAP T2, beside the strip alternation (candidates: corner 4 read late, the 4th edge's start serialised behind
the third's, a quad-specific step of the fixed logic).

The sequencer (`p2_isp_setup`): the accept loads the input registers and latches FPU_CULL_VAL, FPU_PERP_VAL and
HALF_OFFSET[0] with the primitive (constant over a render); step 0 is the clock after; every step issues its micro-word,
nothing stalls inside a program; the hand-off step waits while the 1-deep hand-off is full, and the next primitive is
accepted in the clock its hand-off is written (or, culled or bad without `kill`, in the clock of the step before, the
cull's determinant being readable there: the generator checks it). A `kill` descriptor and a MODIFIER triangle carry rows
0 .. 31. The ptc strobe (`pc_v`, `pc_culled`, `pc_quad`) comes at each program's end.

**Interfaces.**
- In: `asm` stream.
- Out: `rd_v`, `rd_rdy`, `rd` (`p2_rdesc_t`) into ptc and then a **1-deep hand-off register** to the rasterizer
  [I tim §3.2].
- To ptc: per primitive `{culled, quad}`. A bad corner counts as stored, not culled (isp §11.4).

**State.** The operand registers, the program counter, the hand-off register.

**Cycle.** [M tim §3.2] 16 clk a triangle, 15 culled, 19 a sprite, strip triangles alternately 19 / 15.
- The program length comes from the scheduler. The hand-off write is the program's last step, so a culled or bad
  primitive that skips the hand-off takes one step less (15). The cull verdict is known early, but the program does
  not exit early: everything is computed and only the hand-off is suppressed. That is the simplest reading of 15
  against 16 [G].
- Depth never shows in the time [M], so every depth regime runs the same program.
- FPU_PERP_VAL triangles: cost GAP (tim §3.2, dreamcast-tests TODO.md item D4). Big edges: cost GAP (T2).
- The strip alternation is GAP T2.

#### 3.4.5 `p2_isp_raster`: the row stepper (32 lanes, one tile row a clock)

**Function.** Owns isp §8.4, §8.5 and the per-pixel depth (edge.h `InsideOrdinary`, `RowMask`, `Walk`, `Inside`;
depth.h `At`, `NegWord`, `RegDepth`).
- For each row j in `jf..jl` (MODIFIER: 0..31), one row a clock.
- **Edge lanes.** Each edge has one set of 32 lanes, **34 bits wide** (derived, isp §8.5 at `4f3efe15`). Lane i
  computes `v_i = base + i step` (`i step` by a per-lane constant shift-and-add of at most 5 terms) and decides with
  a threshold `thr`: inside when `v > thr`; outside when `v < -thr`; a value in the zone is inside when
  `v_{i+1} = v_i + step >= -thr`; in column 31 when `step > 0`. A per-edge row stage picks `(base, step, thr)` for
  the row; since `1040c4aa` every choice is on the edge's one grid (2^unit, 2^102 for a big edge), `step = tx` and
  `thr = zero2` always:
  - an ordinary edge, and a big edge's unwrapped rows: `base = r = t0 + j ty`. The row-zero rule applies first:
    `|r| <= zero2` gives the whole row by `(|tx| <= tie2 ? ty > 0 : tx > 0)`;
  - a big edge's wrapped or pushed rows: `base = rw` or `rw +- 2H`. Here a row in the zone is whole by `tx > 0`
    (edge.h `RowMask`).

  The 34-bit width is derived: on a big edge `|r| <= 2^30` where the ordinary rule is taken and `|tx| < 2^27`
  (`r + 32 tx` below 2^32.4), a pushed value below `3 x 2^30`; an ordinary edge with `d <= 29` uses 31 bits.
  `agents/spec-sync-edge/widths4f3.cpp` measured 2^32.31 at most; PLAN M2 asserts it. (`708fb8cd`'s 40 bits were for
  the walk's finer grid, gone.)
- **The big-edge walk** (edge.h `Walk`), one row a clock beside the lanes, from row `jf` (0 for MODIFIER), in half
  units of 2^102 (`H = 2^30`, `Z = zero2 = 2^7`, constants):
  ```
  r     = t0 + j ty                         34-bit accumulator (|r| < 2^32), the lanes' row base
  rw    = r wrapped into [-H, H)            the low 31 bits of r, sign-extended
  above = rw + far32 > Z                    the far value above ZERO (far32: §2.4)
  |rw| <= Z:                  row = (rw == r) ? ordinary : (tx > 0 ? all : tx == 0 ? (ty > 0 ? all : none) : none)
  tx == 0 or sign rw == sign tx:  row = (rw == r) ? ordinary : (rw > 0 ? all : none)
  else: mid = rw + 16 tx
        mid outside [-H, H):  row = lanes(rw + sign(rw) 2H)          the push (mid overflows 31 bits)
        else:                 row = (rw == r) ? ordinary : lanes(rw)
  dead:                       row = none
  if j > jf && wasAbove && !above: dead := 1 for the rows after j
  wasAbove := above
  ```
  [M faredge 1,340 / 1,340; faredge_walk, _m131, _ecap, _k132, _cmax, _cull, _far32; every hugepos set, hugepos_rules
  3,600 / 3,600 and hugepos_v5 2,400 / 2,400 since `1040c4aa`; edge2_walk, edge2_end, edge2_mult (the end against
  ZERO, the far value with sx < 0: R alone, R + 2^131 for a multiple of 2^126); no refsw3-known residual is left.]
  The far value's `2^131` for a negative multiple of 2^126 has a one-adder reading (isp §8.4b: 32 sx enters as sign
  and low bits, invert + 1, the carry out of the + 1 not gated by the sign) [I]; the RTL may build it that way or
  from the precomputed `far32`, the function is the same. The walk state (`wasAbove`, `dead`) depends only on the
  rows before, so the raster stepping `jf..jl` in order is exact. A future row-skip rule (T2) must still advance it
  on skipped rows.
- Inside = AND of 3 (4) edges, forced 0 by `kill`.
- **Depth lanes** (§2.4 `p2_ztile_t`), 32 lanes:
  - BLOCK: `t = S + 2i DX + 2j DY` (30-bit signed; the same at centres and corners since `0de9776b`: only the
    start, made in §3.4.4 step 7, depends on HALF_OFFSET[0]), kept as a row base plus lane offsets. Each lane
    converts `t` to a key: `t >= 0` normalizes to 19 bits at `2^(gexp - 1)`, then `big` from 2^128 or `from_fp`;
    `t < 0` is `neg(E, t >>> nsh)` (a left shift for `nsh < 0`), or the fallback word with `fbw`. num §8 A2 cannot
    occur: the 30-bit form is exact, and the testbench asserts equality with refsw3's 64-bit truncation;
  - REG: lane register `r = r0 + (sa i + sb j) 2^25 + i fa + j fb` (mod 2^30), key `regdepth(r)`;
  - CONST: the key.

**Interfaces.**
- In: the hand-off register.
- Out, per row: `row_v`, `row_j[4:0]`, `in_mask[31:0]`, `zk[0:31]` (`p2_zkey_t`), plus the descriptor's tag, rm,
  depth_mode, zwdis, `sum_op`, to p2_isp_pix.

**State.** Row counter, edge row accumulators and walk state, depth row base, lane offset registers.

**Cycle.** [M tim §3.2] One row a clock. Rows stepped = `jl - jf + 1`. MODIFIER triangles, and every
`kill` descriptor, step all 32 rows.
- A triangle costs `max(setup program length, rows)` through the 1-deep hand-off:
  - a 32 x 32 quad: 2 x 32 = 64 ✓;
  - quad 32 wide by h lines: 2 x (h + 1) for h ≥ 17 ✓ (34 / 36 / 42 / 50 / 58 / 64 at h ≤ 16 / 17 / 20 / 24 / 28 /
    32);
  - a 2-triangle modifier volume of 32 lines: 32 + 32 = 64 against 65 measured. The summary costs no clock here
    (§3.4.7). The missing clock is GAP T2 [G: a one-clock hand-off bubble after a `sum_op` descriptor, `MV_GAP`
    in §6].
- **Prediction to check (T2)**: every modifier volume triangle costs 32, whatever its size; a culled closing
  triangle costs 32 too.
- **Anomaly** [M]: 1-wide quads step fewer rows (~25 at 32 lines). The rule is GAP T2. refsw3's `RowOutside` is a
  software early-out [R]. The default does not skip rows.
- **Replays** (§3.4.11) enter the hand-off register directly: a replayed primitive costs its rows only.

#### 3.4.6 `p2_isp_pix`: fragment rules (32 lanes)

**Function.** Owns isp §10.2, §10.3, §11.1, §11.2 (parity), the §11.4 PT ISP rule, the §11.5 rule and the §11.6 sort
rule: tile.cpp `PixelFlush_isp`, `KeyAbove`. Per lane with `in_mask[i]`, in the row's stage R2 (below):

| rm | rule |
|---|---|
| OPAQUE, TR_PRESORT | DepthMode compare of `zk` against `depthA` (signed 64-bit key compare), then on pass: `!zwdis` gives `depthA = zk`; `tagA = tag`; `valid = 1` |
| MODIFIER | `zk > depthA` (mode 4 always, strictly greater): `stencil[1] ^= 1`; `stencil[2] = 1`; then the row's summary (§3.4.7) |
| PT_PASS0/N | `rendered && !rlp` reject; `!KeyAbove(zk, tag, depthC, refTagC)` reject; `tagB != TAG_BELOW && !KeyAbove(depthB, tagB, zk, tag)` reject; `valid && !KeyAbove(zk, tag, depthA, tagA)` reject; else `more = 1`, `depthA = zk`, `tagA = tag`, `valid = 1` |
| TR_AUTOSORT | `valid && KeyAbove(zk, tag, depthA, tagA)` gives `more = 1`, reject; `!KeyAbove(zk, tag, depthB, tagB)` reject; `valid` gives `more = 1`; then `depthA = zk`, `tagA = tag`, `valid = 1` |

`KeyAbove(aK, aT, bK, bT)`: `aK != bK` gives `aK > bK`; else `bT == 0xFFFFFFFF` gives `aT != 0xFFFFFFFF`; else
`aT != 0xFFFFFFFF && aT[23:0] > bT[23:0]`. One 64-bit key comparator, two 32-bit equality compares and one 24-bit
compare per operand pair; 3 KeyAbove units per lane, used by the PT rule.

**Interfaces.** In: the raster row. Buffer row read (stage R1) and row write (stage R2) on buf's raster ports.
Out: `more`.

**State.** None of its own. Pipeline registers only.

**Pipeline and hazard** [I].
- R0: row values. R1: lane decisions, depth keys, buffer row read. R2: rules, buffer row write.
- Consecutive rows of different primitives can be the same row (the last row of primitive k and the first of k+1, one
  clock apart). R1's read is then bypassed from R2's write data.
- With the bypass there is **no stall**, which is what [M] "depth processing never shows in the time" requires.
- The per-pixel fragment order of isp §1 item 1 (list order) holds, because rows of one primitive are processed in
  order, and primitives in list order through one pipeline.

**As built (M6, `rtl/v1/isp/p2_isp_pix.sv`).** The OPAQUE / TR_PRESORT rule and the MODIFIER rule with the folded
summary; the PT and AUTOSORT rules are M7's. Stages: R0 is the raster's row register (pix issues buf's F read with its
row); R1 has the read data, the lane decisions and the rules; R2 writes. **Two bypass sources, not one**: the RAM read
is sampled at the edge that ends R0's clock, which is also the edge where the row two clocks ahead (R3) is written, so
R1 takes per lane from R2's write data (this clock's write: the same row one clock apart) and from R3 (the write of the
clock before: two clocks apart); the flip-flop fields (stencil, valid) are read in R1, where the write of the clock
before is already in them, so only a row one clock apart would need a bypass from R2. valid has it (M7's punch-through
rows write and read it). The stencil has none: only MODIFIER rows write it, and a MODIFIER triangle (a kill descriptor
too) steps all 32 rows (`p2_isp_rowclip`), so two volume rows of one row number are at least 32 clocks apart; tb/isp_tile's
`t_mrow` check fails a run where they are one clock apart (none in M6's inputs). The depth and tag bypasses: both
occur in console data: the dumps hit the R3 case in 3 tiles (the row-31 shift: a primitive ending in row 31, the next
starting in row 31, so in row 30); the R2 case needs the first primitive's pixels in its last stepped row, which with
centre sampling only a tile clip gives (and the row-31 shift then moves the next one up a row), so corner sampling and
an integer top (scenegen ROWS's pairs). The summary is `f_sum(f_parity(stencil, hit), sum_op)` per pixel of the row.

**As built (M7).** The PT_PASS0 / N and TR_AUTOSORT rules of the table, with `KeyAbove` as a function (one 64-bit key
compare and the tag compares; three uses in the PT rule, two in the sort's). depthB, tagB, depthC and refTagC come with
the F read (one row address for every non-C RAM, §3.4.7 as built); rendered and rlp are flip-flops read in R1. The raster
never writes them, so they need no bypass; valid's bypass from R2 is now read (PT and sort rows). `more` is a register:
set by any lane of a row in R1, cleared by ctl before each PT or sort walk. **The row barrier is at R0**: a row enters
R0's read only when `bar_ok[row]` (the cutter has passed it), otherwise the raster holds it (`out_rdy` = 0).

#### 3.4.7 `p2_isp_buf`: per-pixel ISP state

**Function.** Owns isp §10.1, §13 (per pixel), and the buffer operations of isp §4.2, §11.2, §11.4 and §11.6
(tile.cpp `ClearBuffers`, `ClearParamStatusBuffer`, `PeelBuffersPTInitial`, `PeelBuffersPTChunk`,
`PeelBuffersPTFinal`, `PeelBuffers`, `SummarizeStencilOr` / `And`, `SaveDepth`, `SaveDepthAt`, `RestoreDepth`).

**Storage and physical ports.** 32 rows x 32 lanes. Wide fields are RAMs, one RAM per lane and field (32 words of
the field's width; conv §4.2's "one array per write lane"), read and written a row at a time at one address. Narrow
fields are flip-flops.

| field | bits | storage | write port: its users | read ports |
|---|---|---|---|---|
| depthA | 64 | RAM, **2 read copies** | one: raster R2, sweeps CLEAR / PEEL / PT_FINAL / RESTORE | F: raster R1, sweeps, feedback; C: cutter (AUTOSORT `SaveDepthAt`) |
| tagA | 32 | RAM, **2 read copies** | one: raster R2, CLEAR, PT_FINAL | F: raster R1, PT_INIT, PEEL, feedback; C: cutter |
| depthB, tagB | 64 + 32 | RAM | one: PEEL, PT_INIT / PT_CHUNK (tagB = TAG_BELOW), feedback | F: raster R1 |
| depthC, refTagC, opTag | 64 + 32 + 32 | RAM | one: PT_INIT, PT_CHUNK | F: raster R1, PT_FINAL |
| resTag | 32 | RAM | one: feedback | sweeps |
| resDepth / savedDepth | 64 | RAM [A: one array; resDepth is live in PT phases, savedDepth from SAVE to RESTORE, never both] | one: feedback (PT), cutter (AUTOSORT), SAVE | sweeps |
| valid, rendered, stencil[2:0], rcur, rlp, everRendered | 8 | flip-flops | raster, cutter (valid in PRESORT), feedback, sweeps | any |

**Why one write port suffices** (no arbitration, no loser):
- raster, replays and sweeps are issued by ctl one after the other, so they never write in the same clock;
- the cutter writes only savedDepth (RAM) and valid (flops);
- the feedback writes only in a PT SHADE, while the raster and the sweeps wait for PASS_DONE;
- the row barrier (below) keeps any two concurrent units on different rows;
- the flip-flop fields have one write enable per unit and pixel. Two units never write the same pixel in one clock,
  by the same arguments. The RTL asserts it.

**Why two read copies** of depthA and tagA: the cutter of epoch e reads them while the next epoch's raster (R1)
reads them on other rows. Every other wide field has one reader at a time. Writes go to both copies. MQ checks that
the synthesized RAMs have exactly these ports (PLAN MQ).

**Sweep engine.** CLEAR, CLRSTATUS, PT_INIT, PT_CHUNK, PT_FINAL, PASS_START, PEEL(key), SAVE, RESTORE: one row a clock
over 32 rows [G], each exactly refsw3's per-pixel effect. PT_INIT clears the stencil (refsw3 `PeelBuffersPTInitial`).

**Modifier volume summary, folded into the closing triangle** [I: same function; a rasterized closer pays no clock
for it, which fits 65 = 2 x 32 + 1; a culled closer's 32 rows are [G], T2].
- A descriptor with `sum_op` steps all 32 rows. At R2 of each row, after the row's parity updates, every pixel of
  the row with `stencil[2]` set gets `stencil = {2'b00, s0 | s1}` (OR) or `{2'b00, s0 & s1}` (AND). The stencil row
  write is a full-row write of the flip-flops.
- This equals refsw3's `Summarize*` after the triangle. The closer's row j write is the last write to row j of this
  volume, and the summary acts on each pixel alone.
- A culled or bad closer arrives as a `kill` descriptor (§3.4.4) and applies only the summary.
- No pending state exists, so revision 1's open questions do not arise: a second pending op, a masked write, the
  barrier, the debug view. A summary is an ordinary raster row write and obeys the row barrier like one.

**Row barrier.** A 32-bit `cut_done` vector from p2_isp_cut. A raster, replay or sweep write to row j of a *later*
SHADE epoch waits until the cutter has passed row j of the current epoch [G T4]. The cutter needs the tag rows of a
finished pass; the next pass or entry overwrites them. With no port conflicts, the barrier alone decides how cutting
overlaps the next epoch's ISP work.

**Debug read port** (sim, backdoor): the whole state of a pixel, for the tile testbench (PLAN §1.3).

**Cycle.**
- The sweeps' costs are GAP T13: "a pass that finds nothing still costs ~300", "Z clear + background setup 142".
- [M tim §3.4] A background-only next tile hides 58 of 128 cut clocks, but only 11 of 256. The barrier predicts the
  CLEAR sweep (32) plus the list fetch (~26), about 58, in both cases. The 256 case is GAP T4.

**As built (M6, `rtl/v1/isp/p2_isp_buf.sv`).** depthA and tagA (RAMs, one per lane, the F and C copies written
together), stencil and valid (flip-flops), the one write port shared by the raster's R2 and the sweep engine (a raster
write during a sweep is asserted against), the sweeps CLEAR (depthA = key, tagA = tag, stencil = 0, **valid = 1**:
refsw3's ClearBuffers sets `tagStatus = {true, false}`, so the background is shaded) and CLRSTATUS (valid = 0), 32 clocks
each. The debug port reads a row of every field and (sim only) writes one: the tile testbench's compare and its resync
(PLAN §1.3 "As built"). The other fields, sweeps and the row barrier are M7's.

**As built (M7).** Every field of the table. Wide fields are `p2_isp_lram` instances (32 rows x 32 lanes, one array a
lane, a registered row read, lane write enables); depthA and tagA have the F and C copies, written together. Every
non-C RAM read goes to **one row address**: the sweep engine's while it runs, else the feedback's, else the raster's (ctl
keeps them apart in time). resPass is two flip-flops, `rcur` (resolved in this pass) and `rlp` (in the pass before:
refsw3's `ptResolvedLastPass`); PASS_START moves rcur into rlp. **The sweeps have two stages**: A issues the row's reads
(when `bar_ok` lets the row go), B writes it the clock after (33 clocks a sweep; CLEAR and CLRSTATUS too, 32 in M6).
The cutter writes valid (TR_PRESORT) and savedDepth (TR_AUTOSORT) with its own enables; the feedback one pixel's
depthB, tagB, valid, and on a pass rendered, rcur, resTag, resDepth. The checks that no two writers meet are
simulation assertions. The debug port reads and writes every field.

#### 3.4.8 `p2_isp_cut`: the ISP side of a SHADE pass

**Function.** Owns isp §12.1, §12.3 (the ISP-local parts) and §4.4 (`tilePixelsShaded`, as `shaded_any`), and tsp
§3.1 (tile.cpp `SpanGen<rm>`). Per row j = 0..31:
- `part[i]` = `valid`, or for PT_MV `stencil0 && (rendered || OpInPt)`.
- `vol[i]` = `stencil0`, forced to 0 in TR_PRESORT, both PT passes, and OPAQUE when OpInPt.
- A run boundary at i is `part[i] && (!part[i-1] || tag[i] != tag[i-1] || vol[i] != vol[i-1])`, comparing **all 32**
  tag bits. The boundary mask feeds a priority encoder.
- Each run gets `vmask` from the stencil0 bits, `pmask` from `rendered` (PT_PASS0/N, PT_MV; else 0), `rm`, and the
  pass's `epoch`.
- Side effects:
  - TR_PRESORT: `valid = 0` for the cut pixels;
  - TR_AUTOSORT: `savedDepth = depthA` for the cut pixels (refsw3 `SaveDepthAt`: the shaded pixels are exactly the
    valid ones, so no feedback is needed);
  - `shaded_any |= 1`.
- **Flags.** The pass's last run carries `eop`. If ctl issued the SHADE as the entry's last, it also carries `eoe`,
  and the cutter pushes the entry record into `p2_entq`. If ctl decides the entry's end only after the last SHADE
  was cut, the cutter emits a `null` item with `eoe`. That happens when the entry ends after a PT pass with no
  OP_MOD and no TR (known after PASS_DONE), or in PRESORT when olw had not yet seen end of list at the last SHADE.
  An empty non-PT SHADE emits nothing.

**Interfaces.**
- In: `shade(rm, last_of_entry)`, `end_entry` from ctl.
- Buf: cut ports.
- Out: run stream push to p2_runq (`rs_v`, `rs_rdy`, `p2_rs_t`); `p2_entq` push.
- `cut_done[31:0]` to buf; `cut_idle`; `ev_isp` (the last entry's `eoe` item accepted).

**State.** Row pointer, the current row's boundary mask, `shaded_any`, the epoch counter (7 bits).

**Cycle.** [M tim §3.4] **One run a clock whatever its length**: 0.95-1.02 clk a run; a line of 32 one-pixel runs
costs 31 more than a line of one run.
- Mechanism: a row read (pipelined), 31 neighbour compares, and a priority encoder that emits one run a clock.
- An empty row costs 0 clocks [G] (GAP T3).
- Stalls when p2_runq or p2_entq is full [M ispq]. So `ev_isp` is "the last run accepted" [I].

**As built (M7, `rtl/v1/isp/p2_isp_cut.sv`).** A one-command slot (`cmd_rdy`) in front of the command being cut, so
that ctl can issue the next SHADE while this one is cut. Stage A finds the next row with a part pixel from the row
pointer (a priority encoder over the 32 rows' part bits, computed from the flip-flop fields; rows without one cost no
clock) and issues its C read with its flip-flops latched; B holds the row and emits one run a clock, the side effects in
its first clock; A issues the next row in B's last clock, so a row of k runs costs k clocks. Choices the text left open:
- **The pass's last run** (`eop`) is known from A: no row is left for it. The flip-flops of the rows after B's cannot
  tell once A has passed them, because a later epoch may then write them.
- **The epoch counts the passes that emitted a run**: an empty pass emits nothing and does not count (refsw3's empty
  SHADE passes, e.g. a culled pre-sorted triangle's, have no counterpart in the RTL).
- **The barrier** (`bar_ok`): every row while nothing is cut; while a SHADE is cut and no other waits in the slot, the
  rows it has finished (B done, or skipped by A); no row while a SHADE waits in the slot.
- A last SHADE with no run, and END, emit a null item with eoe and the entry record. The entry record goes into
  `p2_entq`, which is `rtl/v1/isp/p2_isp_entq.sv` (a FIFO of `ENT_N` = 32); a full queue stalls the eoe item.

#### 3.4.9 `p2_isp_fb`: punch-through feedback

**Function.** Owns isp §11.4 "After the TSP has shaded a valid pixel", and §12.3 (tile.cpp `RenderParamTags`'s PT
branch).
- Per PIXEL message, on the buffer's feedback ports:
  - `ro`: `depthB, tagB = depthA, tagA`; `valid = 0`;
  - `fail`: `more = 1`, `depthB, tagB = depthA, tagA`; `valid = 0`;
  - pass: `rendered = 1`, `rcur = 1`, `valid = 0`, `resTag = tagA`, `resDepth = depthA`, `depthB, tagB = depthA,
    tagA`.
- PASS_DONE: report `anyfail` to ctl.

**Cycle.**
- One message a clock [G].
- The pixel pipe's 1 px/clk sets the rate. In a PT SHADE the raster and the sweeps are idle (ctl waits), so the
  feedback ports are free. The cutter reads other rows: a pixel is fed back only after its run, and so its row, was
  cut.

**As built (M7, `rtl/v1/isp/p2_isp_fb.sv`).** Two stages: a PIXEL message reads the pixel's depthA / tagA on the F port,
the clock after its effect is written; `pass_done` goes to ctl the clock after the last write, with `anyfail` the OR of
the pass's PIXEL fails and PASS_DONE's own. One message a clock (`fb_rdy` = 1).

#### 3.4.10 `p2_isp_ptc`: punch-through chunk counter

**Function.** Owns isp §11.4 "Chunks" (lists.cpp `PtChunkTake`, `ptChunkCulled`, `TriangleCulled`):
```
S = ISP_FEED_CFG[13:4] (0..1023); T = S - 2 as a 12-bit SIGNED value (-2..1021)
walk start: fill = 0; chunkAt = 0; prevQuad = 0; culled = 0
per primitive with its mask bit:   culled (setup's verdict, swamped determinant) -> culled = 3, skip
                                   else nv = quad ? 4 : 3
                                        if fill > 0 && (fill - prevQuad) + culled + nv > T (signed): chunkAt++, fill = 0
                                        fill += nv; prevQuad = (nv == 4); culled = 0
                                        member of the current chunk iff chunkAt == chunk
```
- The compare is signed. For S = 0 or 1 every primitive is its own chunk, as refsw3's `int` compare gives; an
  unsigned `S - 2` would put the whole list in one chunk. (Any S up to 7 gives one primitive a chunk: the smallest
  check after a first primitive is `(3 - 0) + 0 + 3 = 6 > S - 2`.)
- A bad-corner primitive counts as stored (isp §15 #19 GAP). A `kill` descriptor never occurs in PT (no MODIFIER).
- With the walk continuing across chunks (§3.4.1), "chunkAt++" is the "chunk full" event. The primitive that caused
  it is held in the hand-off register, as the first member of the next chunk, while the current chunk's passes run.

**Interfaces.**
- In: setup's `{culled, quad}` and descriptor per primitive. The counter needs the cull verdict, so it sits after
  setup.
- Out: `member` to pcache and the hand-off; `chunk_full` to ctl and olw.

**Cycle.**
- The two lags (the quad's 4th vertex, the culled 3) are [I] an occupancy counter updated one primitive late
  (tim §3.3). In this structure they are the counter's update rule, not timing.
- Primitives of earlier chunks are not walked again (§3.4.11), which is a timing claim: T13.

**As built (M7, `rtl/v1/isp/p2_isp_ptc.sv`).** Between setup's hand-off and the raster's input mux. `pt` (the whole
punch-through phase) enables the counter: a culled or bad-corner primitive behind a held descriptor still finishes its
setup program and strobes, so the counter counts while the passes replay. `en` (a punch-through walk) enables the gate:
in the phase, a member passes only during a walk, a later chunk's descriptor is held (`hold`), and in full-walk mode
(`fw`, set by pcache's overflow during a fill, cleared at PT_INIT) dropped. Each descriptor's chunk is latched when setup
pushes it into the hand-off (setup's new `pc_desc` strobe beside `pc_v`). `more_chunks` (`chunkAt != cur`) tells ctl
that another chunk follows; `restart` zeroes the counter for a walk from the list's start (chunk 0, and every walk in
full-walk mode).

#### 3.4.11 `p2_isp_pcache`: the ISP primitive cache (replays of set-up descriptors)

**Evidence.**
- [M timemeas "blend", REPORT "Translucent"] a small translucent layer costs 52 clk (1x1, untextured), from 12
  stacked layers against 4. If every autosort pass walked and set up all L primitives again (19 clk a sprite),
  the ISP alone would cost `19 (144 - 16) / 8 = 304` clk per added layer. So later passes do not set primitives up
  again.
- [M ispcache] SB_ISTERR bit 0 "ISP out of cache" from L = (translucent cache size) / 8 full-tile layers:
  ISP_FEED_CFG[23:14] counts about 4 units a triangle, 8 a sprite, and never at L = 256. The picture is the sorted
  one anyway, down to a size of 64.
- [manual 3.4.3.1 "ISP Cache Size", cited by refsw3 for PT chunks] punch-through chunks exist because the passes
  replay a bounded store. Under a re-walk no chunk would be needed.

**Function.** Functionally transparent: a replay gives the descriptors setup would compute again.
- **TR autosort.** Pass 0's walk records every TR descriptor in list order. Passes 1.. replay them. A unit counter
  adds 4 a triangle and 8 a quad [M]. When it reaches ISP_FEED_CFG[23:14] (sizes below 32 act as 32 [M]), the cache
  has overflowed:
  - `ev_isp_ovf` pulses (with `P2_ISTERR=1`, PLAN D11);
  - the later passes **walk the list again** instead of replaying [G];
  - the 8-bit "never at 256" behaviour is GAP.

  TR_MOD is walked again every pass [G]. Translucent cache sizes below 64 give wrong pictures on the console and are
  not modelled (isp §15 #21).
- **PT chunks.** Chunk c's pass-0 walk records its members. Passes 1.. replay them. The chunk boundary is ptc's
  vertex count [M ptchunk]. A chunk larger than `PCACHE_N` descriptors replays as walks [G].
- **What is stored** [G]: set-up descriptors (`p2_rdesc_t`, including the big-edge walk state). The TR units (4 a
  triangle, possibly 3 edges and a depth plane) fit that reading. The PT count in vertices fits a vertex store
  better. A vertex store would redo setup on replay (16 clk a primitive a pass). T13 decides, for PT separately from
  TR.

**Interfaces.** `fill` (descriptors from ptc / setup), `replay` (to the hand-off register, in order), `reset` (at PT
start, at AUTOSORT start, at the next chunk). Counters `units`, `n`, flag `ovf`.

**State.** `PCACHE_N` descriptors [G: 256, from 1023 / 4 units], the counters.

**Cycle.** A replay issues one descriptor per hand-off: a primitive costs `max(1, rows)` [G], against
`max(16, rows)` for a walked one.

**As built (M7, `rtl/v1/isp/p2_isp_pcache.sv`).** `PCACHE_N` = 256 descriptors (`p2_rdesc_t`) in one array. A fill
records the descriptors the raster takes from the setup side while ctl enables it (a chunk's pass 0, the sort's pass 0);
the translucent units count 4 a triangle, 8 a quad, against ISP_FEED_CFG[23:14] (32 at least): a descriptor that would
bring the count to the size overflows the cache (`ovf`), and it and the ones after it are not recorded. A punch-through
chunk overflows at its 257th member. The replay has one descriptor in a read register ahead (one a clock at most).
Reset at PT_INIT, at PT_CHUNK and at the sort's first PEEL. The raster's input is a mux (`src_rp`, ctl's) between the
replay and the setup side; in TR_PRESORT the setup side is blocked between a descriptor and its SHADE.

### 3.5 `p2_runq`: the run queue

**Function.** A FIFO of `p2_rs_t`. Functionally transparent.

**Interfaces.** Push from cut, pop to sort.

**State.** `RUNQ_N` entries.

**Cycle.** [M tim §3.5 ispq] When the ISP ends, ~430-480 runs are still to be shaded, whatever their length.

**The accounting (MT2's fitting target).** At the ISP's end every queue up to the pixel pipe is full:

`runs_left(L) = RUNQ_N + 96 + SRQ_N + min(PXQ_RUNS, PXQ_PIX / L) + 1`

The terms are: the run queue, the sorter window (full, §3.6), the SRQ, the pixel queue's runs (credits in pixels,
§3.7.6), and the run in the pipe. Pass and entry flags take no entries (§2.3).

| run length L (ispq row) | measured | with RUNQ_N 300, SRQ_N 32, PXQ_PIX 256, PXQ_RUNS 48 |
|---|---|---|
| 32 (background) | 436 | 428 + 8 = 436 |
| 16 (2 columns) | 443 | 428 + 16 = 444 |
| 8 (4 columns) | 462 | 428 + 32 = 460 |
| 1 (32 columns of 1) | 476 | 428 + 48 = 476 |

- The run-length dependence is the pixel-credit signature: P/32, P/16, P/8, then the run cap.
- **Markers taking entries make the fit worse.** One item a tile adds 13 items at L = 32 but 0.5 at L = 1, which
  moves the increments the wrong way; no positive PXQ_PIX fits the four points with it. Hence flags (§2.3).
- These values also give spanahead's hidden bursts: PXQ_RUNS 48 runs and 256 px ≈ 256 clk, against [M] 45-70 runs,
  180-290 clk.
- MT2 fits `RUNQ_N`, `PXQ_PIX`, `PXQ_RUNS` once on these four points with `SRQ_N` fixed, and gates the ispq rows not
  used in the fit (background 565: 437; one sprite: 435; 2 and 4 sprite rows: 434, 434) and spanahead (PLAN MT2).
- Not explained by this: the 32 rows of 32x1 pace (1736 clk a tile, lead 2882), GAP T3.

**As built (M8, `rtl/v1/sort/p2_runq.sv`).** One simple dual-port RAM of `RUNQ_N` = 300 words (a write port; a read
port whose data register is the queue's output, read show-ahead by p2_sort: an M10K's shape) and a word count. A word
written at clock t is read at t + 1 and is at the output at t + 2; `RUNQ_N` counts every place, the output register's
too. `occ` (the places taken) is a statistics port for MT2's fit.

### 3.6 `p2_sort`: the span sorter

**Function.** Owns tsp §3.2 and isp §12.2 (tile.cpp `SpanSort`).
- A window of **96** items in age order, compacting [M: 95 / 97 put 129-276 runs out of order].
- **Key** = `{epoch, tag & (SPAN_SORT_CFG[8] ? ~32'h7 : ~32'h0)}`. The epoch keeps passes apart. All of pass e's
  items are older than pass e+1's, and a drain takes the key of `window[0]`, the oldest item. So every item of pass e
  leaves before any item of pass e+1, and within each pass the order is SpanSort's. The window stays full across pass
  and tile boundaries; revision 1's PASS_END barrier is gone. The 7-bit epoch cannot alias, since the window holds at
  most 96 passes.
- **Drain.** `prim = key(window[0])`. Each step selects the **oldest** item with `key == prim`, emits it, closes the
  gap, and refills from the run queue. The drain ends when no item matches; the next starts from the new `window[0]`.
- **Emit condition** [G]: a step may emit only while the window is full (96 items) or the oldest epoch is closed
  (its `eop` item has entered the window). Then the window holds exactly what SpanSort's window holds for that pass
  (the next min(96, remaining) runs), so the order is SpanSort's whatever the cutter's pace. Whether the console
  waits like this is GAP T5; the early drains may be the console not waiting.
- **Flags.** A pass's runs leave in a different order from the one they came in, so `eop` / `eoe` move from the item
  that carried them to the last item of the epoch to leave. That item is the one emitted when no other entry of
  that epoch is left in the window and the epoch is closed. Detection: a second 96-way match on the epoch alone.
  A `null` item gets an epoch of its own and leaves when it reaches `window[0]`.
- `SPAN_SORT_CFG[0] = 0`: bypass, raster order (refsw3).

**Interfaces.** In from p2_runq. Out to the SRQ (§3.7.1): `p2_rs_t` plus `new_drain`.

**State.** 96 x `p2_rs_t`, 96 valid bits, the drain key, the oldest epoch's closed flag and its saved `eoe`.

**Cycle.**
- One emit and one fill a clock [G] (T5). 96 key comparators against `prim`, 96 epoch comparators, an age priority
  encoder [I].
- The early drains are GAP T5: some drains shaded 2-9 drains early, deterministic, not understood. Candidates [G]: a
  drain started while the one before is still in setup / run start; an emit before the window is full.
- Sort-off order: refsw3 has raster order; the console has near-raster order with timing-dependent early runs. GAP
  T5.
- The SPAN_SORT_CFG 0x100 and 0x10001 hangs are not modelled (PLAN §5, D6).

**As built (M8, `rtl/v1/sort/p2_sort.sv`).** The text above, with the choices it left open:
- **The window** is 96 places of `p2_rs_t` in flip-flops, place 0 the oldest, compacting: the step that frees a place
  moves every place above it down one, and the run queue's head goes behind the youngest in the same clock
  (`in_rdy` = not full or a place freed this clock: one emit and one fill a clock).
- **The key compare is all 32 tag bits** (`& ~7` with SPAN_SORT_CFG[8]), as refsw3's SpanSort (`(cfg & 0x100) ? ~7 :
  ~0` on `parameter_tag_t`), not timing.md's "bits 23..3": the shadow bit and the skip field are in the key (the TWINS
  class of scenegen relies on it; p2_pkg's tag comment said bits 23:0 and was corrected).
- **A drain's first step** emits window[0] in the clock the drain starts (prim is taken from window[0] combinationally
  and registered); a drain ends either on the pass's last item (no extra clock) or with a clock that finds no match.
- **The emit condition** holds every step of a drain, its end included, with the sorter on; with it off (bypass)
  window[0] leaves every clock and the flags stay where they came in (the general re-attachment rule gives the same).
- **Closed**: the oldest pass is closed when an eop item is in the window or its eop item has left early (`sv_closed`,
  with its eoe in `sv_eoe`); any eop item in the window is the oldest pass's or a later one's, and a later one came in
  after the oldest's.
- **A null item** matches no key and is not counted by the epoch match: it leaves alone when it reaches window[0] with
  no drain in progress (p2_isp_cut gives it the epoch the next pass will have, so the epoch alone could not tell them
  apart).
- Ports: SPAN_SORT_CFG[0] and [8] as `cfg_on` / `cfg_offs`, `new_drain` with the item, and statistics (`t_full`,
  `t_wait`: a step held by the emit condition, `t_end`: a drain end without an emit).
- **p2_entq** stays `rtl/v1/isp/p2_isp_entq.sv` (M7; §1.1's folder list puts it under `tbuf/`, not moved): in M8's
  testbench top it sits beside p2_runq / p2_sort as in p2_core, pushed with the eoe item going into the run queue and
  popped when the eoe item leaves the sorter.

### 3.7 TSP

#### 3.7.1 `p2_tsp_store`: the set-up store and look-ahead

**Function.** Owns tsp §2.2 "refsw3 caches 32 set-up primitives" (tile.cpp `GetFpuEntry`, `ClearFpuCache`), and the
console's store (tim §3.7). Functionally transparent: setup is a pure function of the parameters and the volume
select.
- 16 entries keyed by `(tag[31:0], vsel)`. `vsel` = the volume a run's pixel uses:
  - `InVolume && !intensity` selects volume 1's TSP, TCW, U, V and colours;
  - `InVolume && intensity` selects volume 0's words with scaled colours.

  [M allfs: a triangle straddling a volume edge is set up twice.]
- **SRQ**: a FIFO between the sorter and run start, `SRQ_N` deep [G].
- **Look-ahead**: a pointer walks the SRQ from its head. For each run, and for each `vsel` its `vmask` needs (one,
  or both for a run with mixed `vmask` and the shadow bit), a key not in the store gets a free entry and a setup job.
- **Pins**: an entry is pinned while any run that references it is between the look-ahead pointer and the pixel
  pipe's last store read (p2_pp_blend). Replacement among unpinned entries: FIFO [G]; [M] it is not LRU (GAP T6).
- **Across entries and tiles**: entries are kept [G]. refsw3 clears per entry, which is transparent; the console's
  rule is GAP T6 (§6 `STORE_KEEP`).

**Interfaces.**
- SRQ in and out.
- Setup jobs to p2_tsp_pfetch / p2_tsp_setup, with completion.
- Entry read ports for p2_tsp_rstart and the pixel pipe stages (by index).

**State.** 16 entries (§3.7.3 lists their content), keys, valid, ready, pin counts; the SRQ.

**Cycle.** [M tim §3.7]
- Look-ahead is ~11-12 new primitives: a storage limit, not time.
- With the sorter off, "the TSP keeps 16": a re-setup costs 44, plus 19 the first time.
- 16 entries with ~4 pinned give both [G].
- Crowded lines (more than ~12 triangles a line, opaque only): store thrash under the sorter's sweeps [I], not
  checked (T6).

**As built (M9, `rtl/v1/tsp/p2_tsp_store.sv`; PLAN M9).** The text above, with the choices it left open:
- **The SRQ** is `P2_TSP_SRQ_N` = 32 items in flip-flops (`p2_tsp_pkg`), each with its `new_drain`, the volumes it
  needs and their entry indices; three pointers: push, the look-ahead, the head. `new_drain` rides along to run start
  (M10's coefficient reload); the look-ahead does not need it (it looks every run up).
- **The look-ahead** takes one key a clock: the item's volume 0 first, then volume 1 (an item that needs both takes two
  clocks); a null item passes at once. A run needs volume 1 when some pixel n < len has `vmask[n]` with the shadow bit
  and rm not PT_PASS0 / PT_PASSN, volume 0 when some pixel has not (refsw3 RenderParamTags / PixelFlush_tsp's
  `InVolume`; the intensity mode does not change which volume a pixel uses, only what volume 1's entry holds).
- **Keys** are compared on all 32 tag bits and vsel in a 16-way match. A miss takes the first unpinned entry from the
  one after the last taken (FIFO replacement [G T6]) and pushes a setup job into a queue of `JOB_N` 2 [G]; with no
  unpinned entry or no room for the job the look-ahead waits (a storage limit, tim §3.7).
- **Pins** are counts: +1 for each key the look-ahead resolves to the entry (hit or new), -1 for each volume of each
  run released (`rel`, the run's last store read: the pixel pipe's P10 in M11; the testbench in M9). An entry is
  ready from its job's last store write; the head leaves only when every entry it needs is ready.
- **The words** of an entry: a header (`p2_tsp_hdr_t`: the ISP / TSP / TCW words of the volume, the fallbacks, the
  setup class) and K (`p2_tsp_k_t`: K8, dz) in a RAM each, and the 11 planes (`p2_tsp_plane_t`: A, B, C as `p2_fp16_t`,
  84 bits) in **four banks** (plane p in bank p mod 4, three rows an entry), one write and one read port each; the setup
  writes one plane a clock, the read port gives one word a clock, the clock after (die: §3.12).
- **Across entries and tiles** the entries are kept (`STORE_KEEP` [G T6]); `flush` (a render's start: the parameters
  and registers change) empties the store.
- **Not transparent in refsw3 for one tag**: GetFpuEntry's cache is cleared with its tags at 0, so a tag of
  0x00000000 (param_offs 0, skip 0, no shadow, tag_offset 0) right after ClearFpuCache finds slot 0's zeroed entry and
  is never set up there; the RTL sets it up like any other. Unreachable in practice (skip is at least 1 in every list a
  TA writes and in all 6,085 captured background tags); M9's reference primes slot 0 first and the request to nulldc3
  is PLAN §4's.
- Statistics (reported, not gated: T6): SRQ occupancy, entries pinned, the look-ahead's waits, jobs, hits. In M9's
  testbench (random back-pressure, run start holding the ALU ~18 % of clocks): at most 14 entries pinned, the SRQ full
  (32) behind setup-bound stretches.

**As built (M10).** A second read port for run start's coefficient reload, the **row read** (`rw_*`): row r of an
entry, the planes 4r .. 4r + 3 from the four banks at once, with the header and K, the clock after (the four equal
macros of die region 5 read side by side, §3.12). It has the banks' read ports when it and M9's one-word port ask in one
clock (only the M9 testbench uses the one-word port). The pins now go when a run's last point leaves the pixel pipe's
end, P3 in M10 (`rel` from the tb top, `p2_tsp_run_tb_top`), P10 from M11 (`p2_pp_blend`'s `rel`: a run's last point
leaving P10, §3.7.7 As built (M11)).

#### 3.7.2 `p2_tsp_pfetch`: TSP parameter fetch

**Function.** Owns tsp §2.2 (tile.cpp `GetFpuEntry`, `decode_pvr_vertices` / `decode_pvr_vertex`).
- `addr = PARAM_BASE + offs * 4`, with the **full** PARAM_BASE (GAP: isp §3.3, tsp §22 #1).
- Words: ISP/TSP, TSP[0], TCW[0], and TSP[1], TCW[1] if `twoVol`.
- Skips `tag_offset` vertices, then reads 3 vertices in the decode_pvr_vertex layout:
  - x, y, z;
  - [u, v, or the packed 16-bit uv];
  - colour;
  - [offset colour];
  - with twoVol: [u1, v1], colour1, [offset colour1].
- Swaps v0 and v1 when `tag_offset` is odd. The background tag is fetched the same way.

**Interfaces.** Job in (tag); decoded primitive out; memory C3.

**Cycle.** [M sort-off] A first setup costs ~19 clk more than a later one [I]: this fetch.

**As built (M9, `rtl/v1/tsp/p2_tsp_pfetch.sv`).** One job at a time: the header's 3 or 5 words, then (once the ISP
word is back: the fields depend on it) the three vertices' x, y, z and the fields of the job's volume only (volume 1's
u1, v1, col1, spc1 and TSP[1] / TCW[1] for vsel with two volumes; volume 0's otherwise, the intensity entry too), one
word request a clock to C3, at most `PF_OUT` 8 outstanding, the responses in order; the odd tag_offset's swap of
vertices 0 and 1 on the way out; a FIFO of `PF_AHEAD` 2 fetched primitives to the setup, so the next job's fetch runs
beside a setup. The address is the full PARAM_BASE + param_offs x 4 (GAP isp §3.3), 24 bits (p2_mem drops bit 23: the
8 MB view). An untextured primitive is 3 + 3 x 4 = 15 words, a textured offset one 3 + 3 x 7 = 24.

#### 3.7.3 `p2_tsp_setup`: plane setup and mip K

**Function.** Owns tsp §2.3, §4.1-4.6, §8.1 (K), num §4.2 TSP flavour and the mip flavour (H10, `radd` reach 53,
GAP G1), num §3.3 (PlaneHW). refsw3: plane.h `PlaneT::Setup`, `IPs3::Setup`, `SetupIntensity`, `MipSelect` (K
part). Per job `(tag, vsel)`:
- **The 1/w plane**: e's; `ta`, `tb`, `tc`; `Sa = (ta0 + ta1) + ta2`, `Sb` likewise, `Sc = (tc0 + tc2) + tc1` (1/w);
  `Sdet = (e0 + e1) + e2`.
  - The third-addition zero rule (zeroReach 2).
  - Perpendicular.
  - The flat mean with `withZero` (tsp §4.4, num §4.2), the factor `OneThird()`.
  - `recip24`; `A0, B0, C0`; `cut16`.
- **Attribute planes**: U, V and colours B, G, R, A, offset B, G, R, A, of the selected volume. Each is `a_i * t_i`
  of the 1/w terms, `Sc = (t0 + t1) + t2`. Colours enter as `c * 2^-8` (SingleBits). Flat shading uses v3's value at
  all three corners.
  - Intensity (`vsel = 1`, FPU_SHAD_SCALE[8]): colours `(c * scale) >> 8` for B, G, R per vertex (tsp §4.6).
- **Mip K** (only when the TCW is mipmapped): numerators from the undivided sums, length with 0x95F612, times
  `inv2`, times bias times size, `K8` (tsp §8.1).
  - DCalcCtrl 1: `radd` at reach 53, first vertex = vertex 0 after the swap (GAP G1, tsp §8.1).
  - **num §8 DEFECT D1**: refsw3 divides by zero when `Sdet == 0`. The RTL needs a defined value, and refsw3 must
    define it first (PLAN §5, D4).

**Store entry content.**
- 11 planes x (A, B, C as `p2_fp16_t`) = 924 bits.
- `K8` (`p2_fp8_t` + special flags).
- The ISP, TSP and TCW words of the selected volume.
- Fallbacks: v3's colour and offset per channel as sent, scaled for intensity, 8 bytes. These are also the bump
  light and `offsKept`'s value.
- Flags: textured, offset, gouraud, two_vol, intensity, and `ofs_zero`.

**Offset planes dropped** [M tim §3.7 vol2off, offs3: "+16 a triangle and +2.1 a run disappear"]. When every offset
colour the shading uses is 0, the console skips their setup.
- The predicate is evaluated on **the values the entry uses**: Gouraud, the three corners; flat, v3; for the
  intensity entry (`vsel = 1`), the scaled colours. A non-zero colour that scales to 0 counts as 0 there, because
  refsw3 computes that plane from the scaled values. (Whether the console's skip, a timing matter, looks at the
  scaled or the sent values is GAP.)
- The RTL then writes the planes' coefficients without multiplying. They must still equal refsw3's tuples exactly
  (`mant = 0`; the sign is visible through `seen(±0) = ±2^-127`, tsp §5.1). With `AT = +0` on all three corners,
  refsw3 (plane.h `PlaneT::Setup` at `4f3efe15`) gives, branch by branch:

  | branch of PlaneT::Setup | A | B | C |
  |---|---|---|---|
  | `det` zero or perpendicular (and not bad): the flat branch | +0 | +0 | ±0 with the sign of the 1/w `mean` (a bad mean: its sign) |
  | `det` bad (infinite): `inv = 0` with det's sign | ±0, `det.neg` | ±0, `det.neg` | ±0, `det.neg` |
  | reciprocal zero (below 2^-126, or `|det| >= 2^126`): `inv = 0` with det's sign | as above | as above | as above |
  | ordinary | as above | as above | as above |

  Each term `AT_k x t_k` is a zero (`+0 x ±inf = ±0` in the TSP flavour) and, since `2bee80f2`, **every sum that is
  zero is +0** (`addTerm`), so every sum is +0 and every coefficient `+0 x inv` has inv's sign, `det.neg` (`recip24`'s
  and the zero reciprocal's sign). The table before M9 had `AND(sign t_k) XOR det.neg` there: the AND of the
  both-zero Add, which `addTerm` no longer returns (it was the rule before tsp2_zadd, refsw3 `TSP_ZERO=1`); M9's graph
  check and its A3 class prove the table above.
- PLAN M9 proves this table against `fpu_entry` on a directed class: all-zero offsets x {det 0, perpendicular, det
  bad, `|det| > 2^126`, ordinary} x {1/w terms of every sign, zero, infinite} x {Gouraud, flat} x {intensity on,
  off}.

**Datapath.** Setup jobs run on `p2_tsp_alu` (§3.7.4):
- the non-plane part: fetch, the 1/w plane, det, reciprocal, mip K;
- the plane part: about 12 products and 6 sums an attribute plane, sharing the ALU with run start.

**Programs, generated as in §3.4.4.** `tools/gen/gen_setup_prog.cpp` holds the operation graph of `IPs3::Setup` and
MipSelect's K part per class (untextured, textured, offset, bump, DCalcCtrl 1, each with or without the dropped
offset planes). The graph check proves it against `fpu_entry`. The scheduler maps it onto `ALU_NM` / `ALU_NA` / one
reciprocal, with the plane part's issue slots arbitrated against run start. The measured 39 / 48 / 64 / 48 (the offset
planes dropped) and +5.00 are checks on the parameters (MT4), not inputs (the generator's sweep compares those five; the
bump map's measured 49 runs the textured class's program, M10's fix of this line: it had quoted 49 where the sweep uses
48).

**Cycle.** [M tim §3.7] 39 clk a seen triangle untextured, 48 textured, 64 with a nonzero offset, 49 bump, 58 PT
(565), 39 translucent; DCalcCtrl 1 adds 5.00.
- [M share] ~2 clk a plane taken from run-start-paced lines: 13.7 for 7 planes, 22.8 for 11.
- [M dcalct] Setup latency was never seen.
- **PT's 58 against 48 has no structural cause** in this design, and the RTL does not add one: a PT primitive runs
  the textured program. MT4 reports 58 and does not gate it (GAP, T6).

**As built (M9, `rtl/v1/tsp/p2_tsp_setup.sv`, `tools/gen/gen_tsp_prog.cpp` -> `rtl/v1/pkg/p2_tsp_prog_pkg.sv`).**
- **Classes** (the generator's, chosen at the accept from the fetched words): UNTEX (the 1/w plane and the four
  colour planes: an untextured polygon reads no other plane, PixelFlush_tsp); TEX (+ U, V); TEX_O (+ the four offset
  planes: Texture && Offset && the volume's texture not a bump map, the only case PixelFlush_tsp interpolates them; a
  bump map and Offset without Texture read only the fallback); TEX_D (the offset planes dropped: every offset colour the
  entry uses is 0, Gouraud the three corners, flat v3, the intensity entry the scaled ones); each textured one with K
  when the volume's TCW is mipmapped, DCalcCtrl 0 (_M0) or 1 (_M1): 10 programs. A plane the class leaves out is a
  plane no pixel of the entry reads; the gate compares the live words.
- **The graphs** are `PlaneT::Setup`'s per plane (the 1/w plane's e_k, terms, sums `Sc = (t0 + t2) + t1`, Sdet, inv,
  A0 / B0 / C0, the mean with withZero in its first addition; each attribute plane `a_k (w_k d)` from the 1/w plane's
  terms, `Sc = (t0 + t1) + t2`, A0 / B0 / C0 and the flat C `attr_3 x mean`) and MipSelect's K part: the numerators of
  the undivided sums (kind and product, their difference, the quotient check against 1/det^2), the two lengths
  (0x95F612), the longer, once times 1/det^2, with DCalcCtrl 1 the sums at the first vertex (radd, reach 53). MipSelect's
  path for a zero reciprocal (the divided coefficients) needs no multiply: those coefficients are zeros (tsp §8.1), so
  its numerators are 0 or, by the infinite products' rule, an infinity; `inv2` carries that case as a marker. Counts:
  UNTEX 71 multiplies, 43 additions, 1 reciprocal; TEX 97, 55, 1; TEX_O 149, 79, 1; K adds 16 multiplies and 13
  additions (DCalcCtrl 1: 22, 19) and a second reciprocal (MipSelect's has no 2^126 limit).
- **The outputs are the store writes** (one a step, the store's write port, scheduled like a unit): W_PL a plane (flat:
  Sdet zero, or perpendicular to FPU_PERP_VAL, read from Sdet's register by p2_fp_perp: A = B = +0, C = cut16 of the
  flat C; else cut16 of A0, B0, C0), W_DR a dropped plane (the table above, from Sdet's and the mean's signs), W_K
  (K8 from best, the bias, 0 read as 4, and the size; dzForce for Sdet zero). The header is written at the accept.
- **Scheduling** as M4's (§3.4.4): every value has its own register (312 over the ten classes, 41 inputs); a program
  ends with its last store write, and the next job is accepted in that clock (the generator checks that every result
  is written by then). At the §6 parameters (`TSP_NM` 4, `TSP_NA` 4, `L_MUL` 1, `L_ADD` 2, `L_RCP` 2) the lengths are
  UNTEX 20, TEX 26, TEX_M0 31, TEX_M1 32, TEX_O 39, TEX_O_M0 44, TEX_O_M1 45, TEX_D 29, TEX_D_M0 34, TEX_D_M1 36.
  Against the measured 39 / 48 / 64 / 48 (offsets dropped) / +5 (MT4's check, not an input; PLAN 0 rule 6): no parameter set of the
  sweep (`make tsp-prog-sweep`) comes within 16 (the nearest, 2 multipliers and 2 adders: 37 / 50 / 76, dropping the
  offsets 50); the measured offset planes cost 16 for four planes (4 a plane) where the graphs' 13 multiplies a plane
  cost 6.5 at two multipliers: the console's attribute plane is cheaper than PlaneT::Setup's operation count, or its
  measured 39 includes a fetch the program does not. Not padded; MT4 / T6, T7.
- **Run start's use of the ALU** (`hold`): a step waits while run start has the ALU [G: the whole step, not slot by
  slot]; single assignment keeps that safe. M9's testbench holds it on random clocks (~18 %).
- Clocks in M9's testbench (VR_LAT 8, run start holding ~18 %, the reader taking every word of every run): 47.8
  clocks a setup job, 39.0 from a job's accept to its last store write.

#### 3.7.4 `p2_tsp_alu`: the shared arithmetic unit

**Function.** Implements no rule of its own. It is the num H5, H6, H10, H8 and H11 instances that setup and run start
use:
- `ALU_NM` multipliers 24x24 to 24, which also serve run start's exact 16 x 13 products;
- `ALU_NA` adders;
- one reciprocal;
- the floors.

**Interfaces.** Two issue ports (setup, run start) with a grant. Results go back in order per port.

**Cycle.** [I tim §3.8] ~4 products a clock.
- Arbitration [G]: run start first, setup's plane part takes the free slots.
- The multiplier count cannot be told from timing (GAP T7).

**As built (M9, `rtl/v1/tsp/p2_tsp_alu.sv`).** `P2_TSP_NM` 4 multipliers, `P2_TSP_NA` 4 adders, one reciprocal and the
operand register file, as M4's p2_isp_alu; the operations per issue: MUL_T (the setup's and MipSelect's ranged mul),
MUL_K (MipSelect's kind with its product), MUL_Q (the numerator's quotient check), MUL_I2 (1/det^2), MUL_B (the longer
length times 1/det^2), MUL_P (plain); ADD_T (addTerm: p2_fp_rng_add TSP), ADD_W (the mean's first addition with
withZero), ADD_R (radd), ADD_N (the numerator: p2_fp_mip_minor), ADD_LX / ADD_LN / ADD_BS (the lengths' and K's
comparisons, p2_fp_le), ADD_P (plain); RCP_T / RCP_M (p2_fp_rng_recip). The run-start port is `hold` only in M9 (M10
adds run start's own issues).

**As built (M10).** Run start's issues: in a clock run start holds the ALU (`rs_v` = the setup's `hold`; the setup's
whole step waits, as in M9), each of the `P2_TSP_NM` 4 multipliers makes one exact product `seen(A) x x0h` (16 x 13
bits, `p2_fp_mul` N 29: PlaneT::Value's `Mul(a_, FromHalves(x0Halves), 62)`, the halves' 2^-1 left to run start), the
result on `rs_p` `P2_TSP_L_MUL` (1) clock later. In this RTL the run-start product is its own 16 x 13 array beside the
slot's 24 x 24 ones, selected by the same issue (whether the console's multiplier array serves both is GAP T7; MQ may
merge them). Two planes a clock (A' x0h and B' yh each).

#### 3.7.5 `p2_tsp_rstart`: run start

**Function.** Owns tsp §5.1-5.4 (plane.h `PlaneT::Value` up to the integer `k`) and num H4 `seen`, H7b, H11
FloorUnits. For each run at the SRQ head, and each plane of each referenced entry:
- `A', B', C' = seen(A, B, C)`.
- `ex = BL(tileLeft + 16)`, `ey = BL(tileTop + 16)`.
- `e = max(top C', top A' + ex - 1, top B' + ey - 1)`, `unit = e - 22`.
- `x0h = 2 (tileLeft + x) + half`, `yh = 2 (tileTop + y) + half`, with `half = HALF_OFFSET[1]`.
- `base = F(C') + F(A' x0h / 2) + F(B' yh / 2)`: 27-bit; products exact, 16 x 13 bits; F floors, with F(-0) = -1.
- `step = F(A')`.
- SupSample (TSP bit 12): `step2 = F(A' / 2)`, `hyd = F(cut62(C' + B'/2)) - F(C')` (num H7b, ARTIFACT A1, with the
  90-exponent window).

**Interfaces.**
- In: the SRQ head (run plus store indices). Store read.
- Out to p2_pxq: a run descriptor: the run fields and flags, store index(es), and per plane `base[26:0]`,
  `step[19:0]`, `hyd`, `unit[9:0]`. `null` items pass.

**Cycle.** [M tim §3.8]
- Pitch 3.9 / 4.2 / 6.3 clk a run within one triangle (untextured / textured / offset).
- ~4.7 / 6 / 8 across triangles.
- Mechanism: 2 products a plane on the shared ALU, plus a coefficient reload on a store-index change [I].
- A run of 8 or more pixels costs its pixels: p2_pxq back-pressure.
- lineshare (the alternation with the number of runs on a line, 3-12 clk) is GAP T7.
- Mixed-`vmask` runs need both volumes' planes: double cost [G], not measured (T19).

**As built (M10, `rtl/v1/tsp/p2_tsp_rstart.sv`; PLAN M10).** The text above, with the choices it left open:
- **The tile** comes from the entries' records (`er_*`: one taken before an entry's first item, dropped after its eoe
  item; `p2_entq`'s records in M12, the testbench's in M10): `p2_rs_t` has no tile. HALF_OFFSET[1] is an input.
- **The coefficient cache**: per volume the last entry read, keyed by (tag, volume, tile) [G T7]: its header, K, and per
  plane A', B' and the run-independent words (unit, F(C'), step, step2, hyd). A setup is a pure function of the key, the
  parameter block and the registers, so a key in the cache needs no read whatever store index it has (new_drain is not
  needed for it; `flush`, a render's start, empties it). A miss reloads the volume through the store's row read (§3.7.1):
  rows 0 and 1, and row 2 when the class has the offset planes (its class from row 0's header, which arrives as row 1 is
  read); **four lanes**, one a bank, each with seen (p2_fp_in_seen x 3), the grid (three bit lengths, `e`, `unit = e -
  22`), F(C'), F(A'), F(A'/2) (p2_fp_floor, ZNEG) and the half line (p2_fp_half_line, H7b). The lanes take the run's tile,
  not the record's (the next entry's record can arrive while an eoe run reloads: a bug the random section found).
- **The products**: the run's planes (the entry's class: UNTEX 5, TEX* 7, TEX_O* / TEX_D* 11; a run with mixed vmask both
  volumes', one volume after the other), two planes (four products) a clock on the ALU (§3.7.4), floored to the plane's
  grid (p2_fp_floor MW 29, ZNEG: a product of x0h = 0 is a zero on the coefficient's side, F(-0) = -1) and summed with
  F(C') into `base` (27 bits: `p2_tsp_pev_t`).
- **The descriptor** (`p2_tsp_rdesc_t`: the item, the volumes and their store indices, the tile, per volume the header,
  K and the 11 planes' `p2_tsp_pev_t {base 27, step 20, step2 20, hyd 21, unit 10}`) waits in an output register for
  p2_pxq; the next head is taken in the clock it leaves. A null item passes with its flags.
- **Clocks** (reported, not gated: T7, MT5; `make tsp-run`'s pitch item, runs of one pixel, the output never held):
  4.00 / 5.00 / 7.00 clk a run within one triangle (5 / 7 / 11 planes: the product clocks + 1) against the measured
  3.9 / 4.2 / 6.3; 8.08 / 9.10 / 12.10 across two triangles alternating (every run a reload: 2-3 row reads, a clock for
  the last row's data, then the products) against ~4.7 / 6 / 8. The console reloads in about 1-2 clocks more than a run
  within one triangle, this RTL in 4-5: its reload does not overlap the products (a row's planes could start their
  products the clock after the row arrives). Left for MT5, with the alternation of lineshare (T7).

#### 3.7.6 `p2_pxq`: the pixel queue

**Function.** A FIFO of run descriptors. Functionally transparent.

**State.** `PXQ_RUNS` entries, and a pixel credit counter of `PXQ_PIX`. Run start pushes a run when both a run entry
and `len` pixel credits are free; P0 returns the credits as it issues pixels.

**Cycle.** [M tim §3.8 spanahead] A burst of run starts is hidden: ~45-70 runs, 180-290 clk. With the §3.5 fit:
`PXQ_PIX = 256`, `PXQ_RUNS = 48` [I, MT2].
- Its position relative to texturing is GAP T7: the "after texturing" reading was withdrawn.

**As built (M10, `rtl/v1/tsp/p2_pxq.sv`).** One RAM of `P2_PXQ_RUNS` descriptors and a show-ahead head register (the
two together hold `P2_PXQ_RUNS` 48 runs), a credit counter of `P2_PXQ_PIX` 256 pixels: a run goes in when a run's place
and its `len` credits are free (a null item takes no credit), P0 returns one credit at each pixel's last point. The
credits are a timing mechanism only: the mutant without them passes the value comparison, as it must (`tsp-run-mutants`
credits-off). In M10's testbench the queue reaches 48 runs and its 256 pixels (the console sets, P3's output held a
third of the clocks).

One pixel (or, with SupSample, one point) a clock through fixed stages, with one global stall. The stages and the
units that own them:

| stage | unit | function (spec) |
|---|---|---|
| P0 issue | `p2_pp_issue` | Takes a run from the pxq head and emits pixels `n = 0..len-1` (x = run.x + n). Per pixel: `InVolume = vmask[n] && tag.shadow && rm ∉ {PT_PASS0, PT_PASSN}`; `ro = rm ∈ {PT_PASS0, PT_PASSN} && pmask[n]`; `atest = rm ∈ {PT_PASS0, PT_PASSN} \|\| (rm == PT_MV && pmask[n])`; the store index for `vsel`. SupSample: 4 points (hx, hy) = (0,0), (1,0), (0,1), (1,1) [G T16]. **Pass drain**: after the `eop` item's last pixel, P0 issues nothing until that pixel has left P10 [G, below] (M11: not after a TR_PRESORT pass, As built (M11) below). |
| P1 plane | `p2_pp_plane` | Per plane `k = base + n step` (accumulator), or with SupSample `base + (2n + hx) step2 + hy hyd`. Then num H12a to `p2_pval_t` (tsp §5.3-5.5). 11 normalizers. |
| P2 divide | `p2_pp_div` | `den = W` (the 1/w value): `DenominatorSeen`, the zero rule, `recip_mant` (512 x (t 18, n 9) ROM generated from the header, num H13). **One reciprocal a pixel**, shared by all quotients. Quotients U, V, base x4, offset x4 (16x17 multiplier, floored at 17 fraction bits). Mip `w = Divide(1, W)` (tsp §6, num H13). |
| P3 colour, coordinate, level | `p2_pp_col`, `p2_pp_mip`, `p2_tex_coord` | ColorRounded (num H15, max 65535 then the `>> 8` multiply and 255 clamp of InterpolateBase); UseAlpha; offset colours (tsp §7). Mip `w8`, `ww`, `d`, level, `k`; mipChoose (pass B +1, 1x1 clamp, raster level 0, SupSample finer) (tsp §8.2-8.3). TexCoordFixed / CoordKeep, half texel, mip coordinate, declared V, clamp below 0, texel and 5-bit weights, ClampFlip (tsp §9.1). |
| P4-P6 texture | `p2_tex_addr`, `p2_tex_cache`, `p2_tex_decode`, `p2_tex_filter` | §3.8 |
| P7 shade | `p2_pp_shade` | BumpMapper (tsp §12, SIN / COS ROMs from the header), ColorCombiner + offset (tsp §13), `offsKept` (tsp §14). `offsKept` is **one register in this stage**: read and loaded here, in pixel order, so its value follows the TSP order (tsp §3.4) [I tim §4 item 9]. |
| P8 fog | `p2_pp_fog` | Colour clamp, table fog (FOG_TABLE read here: shading-time values), table mode 2, vertex fog (tsp §15); trilinear fade of the finished colour (tsp §16). |
| P9 SupSample | `p2_pp_ss` | Accumulates the 4 points: `((c0 + c1) >> 1 + (c2 + c3) >> 1) >> 1` (tsp §18). Without SupSample it passes through. |
| P10 blend | `p2_pp_blend` | The stuck-alpha register (`tspAlphaStuck`, tsp §19.3: set after a pixel of a setter, cleared after an `eoe` item, refsw3 `ClearFpuCache`); alpha test (tsp §19.1); BlendingUnit (tsp §19.2): `src = SrcSelect ? buffer2[idx] : colour`, `dst = DstSelect ? buffer2[idx] : buffer1[idx]`, then the write to `DstSelect ? buffer2 : buffer1`. The write is suppressed for run-only pixels (`ro`: both buffers keep their words, refsw3 keepRes) and when SrcSelect && DstSelect. |
| P11 feedback | `p2_pp_blend` | PT passes: `p2_fb_t {idx, fail, ro}` to the ISP; after the `eop` item's last pixel, PASS_DONE. Flags go on to p2_tbuf. |

**Dispatch.** The decode of `gentable.h` (tsp §2.4) is per-pixel control decode in P0 from the store entry's words.
It is control, not numbers.

**Hazards.**
- **Blend read-modify-write.** Consecutive pixels can hit the same `idx`: TR_PRESORT puts primitive k's last pixel and
  k+1's first pixel at the same place, one clock apart. The P10 read is then forwarded from the P10 write [I: no
  stall is measured]. PLAN M11 has a mutant with the forward off.
- `offsKept` and `tspAlphaStuck` are single-stage registers. The per-pixel order of tsp §3.4 holds because pixels
  pass P7 and P10 in TSP order.
- Run-only pixels still count for `offsKept`, stuck alpha and `shaded` (tsp §19.4).

**Cycle.**
- **B = 1035 clk for 1024 px in 32 runs** [M timemeas, REPORT "Fixed costs of a tile"] is where "1.01 clk/px" comes from. In this
  design: 1024 pixel clocks + the pass drain `D_PP` ≈ 11 (P0 to P10). **The pass drain** [G] is the mechanism for the
  11. It is fitted once on B (MT6), and then checked against [M] a small translucent layer: 52 = 39 (setup) + 1 px +
  `D_PP` + ~1 (tim §3.3 "~13 more a layer pass"). No other per-run or per-marker cost exists. Runs of 8 or more pixels
  cost their pixels [M].
- Divider, blend and fog cost nothing extra [M], because they are parallel lanes.
- The stalls: texture (§3.8); the buffer-2 interlock (§3.9); SupSample's 4 clocks a pixel [G T16]; the pass drain.

**As built (M10: P0-P3, `rtl/v1/tsp/p2_pp_issue.sv`, `p2_pp_plane.sv`, `p2_pp_div.sv`, `p2_pp_col.sv`, `p2_pp_mip.sv`).**
One global stall (in M10 the end of P3 held: the testbench's back-pressure); every stage register holds while it is set.
- **P0** takes the pxq head into its run register and emits one point a clock, the next run's first point the clock
  after the last one's (no bubble between runs): the point's control `p2_pp_ctl_t` (the pixel, InVolume and the volume's
  header and K, ro, atest, the SupSample point (hx, hy) in the order (0, 0), (1, 0), (0, 1), (1, 1), the run's last
  point, eop / eoe on the item's last point; a null item one point of flags). The run's plane words go to P1 with its
  first point. The pass drain: after the point that carries eop, P0 issues nothing until that point has left the pipe's
  end (P3 here, P10 from M11). The mutant without the drain passes the values (a timing mechanism, MT6).
- **P1** (`p2_pp_plane`): accumulators per plane and volume, `acc = base + n step` and `acc2 = base + 2n step2`, both
  volumes stepping at every pixel's last point (a run with mixed vmask: either volume's value at every pixel; the
  mutant that steps only the pixel's volume is caught); the point's k (`acc`, or `acc2 + hx step2 + hy hyd`), and 11
  normalizers (p2_fp_value_norm, H12a).
- **P2** (`p2_pp_div`): one p2_fp_div_den of W and 11 p2_fp_div_quot: U, V, the colours, the offset colours and the mip
  level's w = Divide(1.0, W) (MipSelect's own, DenominatorSeen included).
- **P3** (`p2_pp_col`, `p2_pp_mip`): ColorRounded (p2_fp_color_round: base MAX 65535 then the clamp to 255, UseAlpha;
  offset MAX 255) and the level: w8 = cut8(|w|), ww = cut8(w8 w8) with the exponent at most 127, d = cut8(K8 ww) (two
  8 x 8 p2_fp_mul and bit lengths), L, M, the determinant zero (dz: past the last level), and mipChoose (SupSample one
  level finer, pass B + 1, the 1x1 clamp, raster level 0) for a textured volume whose TCW is mipmapped (PixelFlush_tsp
  calls mipChoose only with pp_Texture).
- The P3 point carries W and the values (for P8's fog in M11: the TSP's own 1/w), the quotients, the colours and the
  level and k to the stages after it; a run's pins go at its last point's exit.
- Clocks (reported, not gated: MT5 / MT6) in M10's testbench: 1.5 clk a pixel on the console sets (runs of ~13 pixels,
  P3 held a third of the clocks by the testbench), the pass drain 3 clocks a pass (P1-P3).

**As built (M11: P3's p2_tex_coord, P4-P11; `rtl/v1/tsp/p2_pp_shade.sv`, `p2_pp_fog.sv`, `p2_pp_ss.sv`, `p2_pp_blend.sv`;
the texture units in `rtl/v1/tex/`, §3.8; the whole pipe `rtl/v1/tsp/p2_tsp_pp.sv`; PLAN M11).** The table above, with the
choices it left open:
- **One module for the pipe**, `p2_tsp_pp` (P0-P11 and the palette RAM; the tile buffers `p2_tbuf` beside it): the TSP tile
  testbench, the M10 testbench (which reads P3's points as taps, its back-pressure the pipe's external stall) and
  `p2_core` (M12) instance it. **The global stall** = P5's `tex_stall` || P11's `fb_block` || `ext_stall` (the testbench's
  in M11; M12: the buffer-2 interlock). Every stage register holds while it is set.
- **Stage registers** (each unit registers its outputs, as in M10): P3 (p2_pp_col, p2_pp_mip, p2_tex_coord), P4
  (p2_tex_addr), P5 (p2_tex_cache), P6 (p2_tex_filter, behind p2_tex_decode), P7 (p2_pp_shade), P8 (p2_pp_fog), then
  p2_pp_ss (combinational, with its keeping registers) into p2_pp_blend's P9 register, P10 the blend and the write,
  P11 the feedback queue. A point carries `p2_pp_pt_t` (its control, the base and offset colours, W, the level and k,
  TexCoordFixed's U, V) to P7; the colours after.
- **P7 offsKept** is one register in p2_pp_shade, loaded by a non-null point of a volume with Texture && Offset (its light:
  the header's `ofs_fb`) as it leaves P7, read by every point there (pixel order, tsp 3.4); no reset (it outlives renders
  and resets; the testbench loads a capture's value through `ok_we`). The mutant that loads it at P0 instead is caught
  (offspersist).
- **P9**: SupSample's four points (0, 0), (1, 0), (0, 1), (1, 1) in P0's order; c0, then the first row's sum, then c2
  kept; the fourth leaves the pixel with its control (the run's last, eop, eoe are on it).
- **P10**: the tile-buffer words are read as a point enters the P9 register (buffer 1 always, buffer 2 when SrcSelect
  or DstSelect: the secondary port, §3.9), the data in P10; the stuck alpha, the alpha test (alpha < PT_ALPHA_REF, the
  whole register), BlendingUnit, the write (not for a run-only pixel, nor SrcSelect && DstSelect). **The P10 forward**:
  a point's read issued in the clock the point before writes the same word of the same buffer takes the written value
  (`fw1` / `fw2`); the mutant without it is caught on scenegen seed 180, a pre-sorted primitive whose first pixel is the
  one before's last (no console page of M11's inputs has one; agents/m11 mutscan) and on the unit section's repeated
  pixels. **tspAlphaStuck**: set after a setter's pixel (run-only too), cleared after the eoe point.
- **P11**: a two-entry queue of `p2_fb_t`: PIXEL {idx, fail, ro} a punch-through-pass pixel, PASS_DONE {anyfail: the
  pass's fail on pixels not run-only} after its eop point (a point that cannot put its one or two messages in holds the
  pipe: `fb_block`).
- **The pass drain and the pins at P10**: `drain_done` and `rel` when the point leaves P10. **The drain is not taken
  after a TR_PRESORT pass** (M11's choice, §3.7.7 "Hazards"): pre-sorted primitives, a pass each, go through back to back,
  the forward carrying the blended value [I: no stall measured; tim 3.3]. The drain after every other pass is P0 - P10
  (11 stages; `D_PP` is MT6's fit); the mutant without it passes the values, as it must.
- **Clocks** (reported, not gated: MT6, T8; `make tsp-tile` on the tile subset and M11's pages, VR_LAT 8 with
  `--vramvary 7`, random feedback back-pressure and holds): see PLAN M11's gate results (2.44 clk a pixel over the
  subset, 37 % of the clocks texture stalls, a line fill ~140 clk under --vramvary's random latency, ~18 without; 1.03 on
  the untextured blend pages, 4-9 on SupSample and VQ-bank pages: four points a pixel, scattered texels).

### 3.8 Texture: `p2_tex_coord`, `p2_tex_addr`, `p2_tex_cache`, `p2_tex_decode`, `p2_tex_filter`

**Function.**
- `p2_tex_coord`: tsp §9.1 (in P3).
- `p2_tex_addr`: tsp §9.2-9.4.
  - Texel index: raster `tu + stride tv` (stride from TEXT_CONTROL[4:0] x 32 if StrideSel, else the U size);
    twiddled (v bit 2k, u bit 2k+1); mipmapped `MipPoint[s] + twiddle`.
  - Bits per texel, 64-bit word address, lane / byte / nibble.
  - VQ: index address `((start + o) ^ (bank << 19)) + 2048`, then `^ 1` when TEXT_CONTROL[16]; code book entry
    `start + index * 8`.
  - Four texels for bilinear, each through ClampFlip; strided textures ignore flip.
- `p2_tex_decode`: tsp §9.5, §9.6, §10.
  - TEXT_CONTROL[17] byte swap.
  - Palette index and PALETTE_RAM read at shading time.
  - Expansion by bit replication.
  - YUV422 pairing by x and the fitted conversion; the 1x1 mip level read as 565.
  - Bump raw; reserved format 7 raw (GAP); strided-bilinear shift-only widening.
- `p2_tex_filter`: tsp §11.
  - Point.
  - Bilinear in two truncated 5-bit steps.
  - Bump R channel around the circle.
  - IgnoreTexA.
  - Trilinear without MipMapped is point.
- `p2_tex_cache`: no functional rule (refsw3 reads `emu_vram` directly).
  - It fetches 64-bit words through C4.
  - VQ makes two dependent reads: the index byte, then the code book word.
  - Invalidated at `start` [I].
  - **Coherence with C5 is GAP**: whether a texture or VQ index read of a word the write-out has written in this
    render sees the new value. Default: no snooping; the cache is only invalidated at `start`. Such renders are
    VRAM-race renders (§3.2.1).
  - Also holds the **bumphang counter** [G]: non-twiddled bilinear bump-map quads, 16 TR / 8 OP-PT, persistent; the
    render stops (a hang). This is a timing and hang feature (PLAN MT9, D6).

**Interfaces.**
- P4 request: up to 4 texel requests `{word address[19:0], lane}`, the format, VQ and index addresses.
- P6 response: 4 raw texels (16-bit, or 32-bit palette entries after decode).
- A `tex_stall` into the global pipe stall.

**Cycle.** [M tim §3.9; the fetch rule is [I], fitting all 13 align2 numbers]
- **Four 16-bit words come in a clock.** Words that came in for the pixel before do not count again. This is a gather
  stage with the previous pixel's word set as a register. Twiddled 565 bilinear stepping 1 texel a pixel costs 1.11.
- A 32-bit texel (an ARGB8888 palette entry) passes the 16-bit tap path in two steps: +1 clk.
- YUV bilinear: one clock more after its words are in. 1 + 1 at an even x, 1 + 2 at an odd x sharing nothing.
- A non-twiddled 2x2 footprint spans two memory rows: +1.
- Texels 4 or more apart: 2.14 clk/px, bound by memory, through the VRAM model's C4 rate.
- The first tile of a render pays +35..+455: cache invalidated at `start`.
- Cache organisation (line, ways, size, miss latency): GAP T8. Initial [G]: direct-mapped, 8 KB, 64-byte lines.
  SPAN_SORT_CFG bit 16 (bypass) changes time by ≤ 2 % and is not modelled.

**As built (M11, `rtl/v1/tex/`; PLAN M11).** The text above, with the choices it left open:
- **p2_tex_coord (P3)**: TexCoordFixed of U at 3 + TexU + 8 and of V at 3 + TexV + 8 (3 + TexU + 8 for a mipmapped texture
  declared shorter), p2_fp_tex_coord (H11) twice, registered with P3; the half texel, the level's shift, CoordKeep of the
  declared-shorter V and the clamp below zero are P4's (they need the level).
- **p2_tex_addr (P4)**: the four taps of TextureFilter's order 00, 01, 10, 11 (tap 11 the point sample); the dispatch's
  filter (FilterMode >= 2 without MipMapped is point); ClampFlip at the level's size (no flip when strided); twop as
  bit interleaving (v bit i at 2i, u bit i at 2i + 1 up to the smaller size, the larger's bits on top: TexCache.cpp
  twiddle_slow); MipPoint; the byte offset by fBitsPerPixel; the 64-bit word address (& 0x7FFFF8); VQ's index byte
  address ((start + offset) ^ (bank << 19)) + 2048, ^ 1 with TEXT_CONTROL[16], and the code book's first word; the 5-bit
  weights; YUV's 1x1 level as 565. Point sampling asks for tap 11 only (refsw3 fetches all four and uses one).
- **p2_tex_cache (P5)**: the placeholder of §6: 128 lines x 64 B, direct-mapped (data 1024 x 64 bits with four read
  ports, tags and valid bits in flip-flops), one fill at a time (eight 64-bit C4 reads, the line's valid bit cleared at
  the first, set with its tag at the eighth response; RSP_N 8 lets the eight go back to back), invalidated at `flush`.
  **The gather**: a tap's word is kept in its own register the clock its line is in, and the point leaves when every
  tap it needs is kept or hits, so lines of one set that the four taps need in turn cannot evict each other for ever.
  VQ: the index bytes (phase 0, one clock more), then the code book entries at code book + index (phase 1). The words
  go to P6 with **TEXT_CONTROL[17]'s byte swap** applied here (the VQ index bytes are taken before it). No snooping of
  C5; the bumphang counter (MT9, D6) is not here.
- **p2_tex_decode, p2_tex_pal (P6)**: the palette RAM (1024 x 32, four asynchronous read ports, one write port from the
  register side) read with the palette index taken off the word in the same clock; YUV paired by x; ExpandToARGB8888;
  the strided bilinear widening. **p2_tex_filter (P6)**: point, the two-step bilinear, the bump angle round the circle,
  IgnoreTexA; registered.
- **Clocks** (reported, not gated: T8): a textured point that hits costs nothing more; a miss holds the pipe for the fill
  (VR_LAT 8 + the arbiter: ~12-16 clk a line); VQ one clock more a point. The measured 1.11 clk/px (twiddled 565
  bilinear), +1 for 8888 palette entries and YUV bilinear, +1 for a non-twiddled 2x2 across two rows are not modelled
  beyond the gather and the misses (T8; MT6).

### 3.9 `p2_tbuf`: the two tile buffers and the entry-end controller

**Function.** Owns tsp §17.1 and isp §4.4. refsw3: tile.cpp `NextTileAccumulationBuffers`, `GetColorOutputBuffer`,
and RenderCORE's end-of-entry logic.
- Two RAMs of 1024 x 32 bits (B, G, R, A), and `sel` (which is buffer 1). Never cleared.
- **End-of-entry decision** when an `eoe` item arrives (its record from `p2_entq`), with `prevWrittenOut`,
  `havePrev` and `prevTile` (reset per render):
  - `emptyKeepZ = z_keep && !shaded_any && prevWrittenOut`;
  - `emptyAfterNoWrite = z_keep && !shaded_any && !prevWrittenOut && havePrev`;
  - `writeTile = emptyAfterNoWrite ? prevTile : tile`;
  - action:
    - NONE when `no_writeout`;
    - SWAP when `emptyKeepZ`;
    - WRITE(writeTile), then SWAP, otherwise.
- **When the action happens** [M tim §3.10: "they swap when the TSP starts the next tile, which is also when the
  previous tile's write-out starts"]:
  - at the next entry's first item at P10, or at the end of the render;
  - WRITE waits until the write-out is idle, then swaps, then starts the write-out of the new secondary buffer at
    `writeTile`. The secondary buffer is the old buffer 1, which holds the finished tile.

**Ports.**
- Primary read (P10, `buffer1[idx]`).
- **Secondary read, shared with the write-out** [I tim §3.10]: one read port on the secondary buffer. Its address is
  P10's when P10 reads buffer 2, which is for SrcSelect (`src`) and for DstSelect (`dst`, refsw3 BlendingUnit); else
  the write-out's. Both take the data.
  - So a SrcSelect pixel during a write-out damages the write-out's picture: the write-out reads what the TSP
    addresses [M accbuf page 7, blendpos].
- Write (P10): either buffer.
- **The buffer-2 interlock.** A pixel with **DstSelect** stalls at P10 while the write-out is busy [M: +1025 a SEC
  WRITE tile; the bands being written out are never damaged]. Its buffer-2 read waits with it, so it never uses the
  shared port during a write-out.
  - A pixel with SrcSelect && DstSelect writes nothing. Whether it waits is GAP. Default [G]: it waits, because the
    interlock decodes the DstSelect bit, not the suppressed write. (Its buffer-2 read would otherwise also race the
    write-out.)

**Empty keep-Z collision** [M accbuf "T end" / "T flush", keepz_races]. GAP T11.
- The facts: an empty keep-Z entry ends at once and does not wait for the previous write-out. One costs ~2390 clk
  more, and a neighbour gets the other buffer's picture. Two in a row hang the render.
- [G] Mechanism, in a sub-block `p2_tbuf_hs`: a SWAP action does not wait for write-out idle, so it can flip `sel`
  under a running write-out. The write-out's "start" is a pulse that is lost if the write-out is busy.
- refsw3's result holds whenever the write-out is idle at SWAP time. That is every deterministic accbuf cell.

**Cycle.** Tile cost ≈ max(ISP, TSP, write-out) follows from the WRITE wait (back-pressure) [M tim §3.1].

**As built (M11: the RAMs and the secondary port, `rtl/v1/tbuf/p2_tbuf.sv`; the controller is M12's).**
- Two RAMs of 1024 x 32 (`ram0`, `ram1`), `sel` (which is buffer 1), `swap` (the testbench in M11, the controller from
  M12). Each RAM one read port and one write port: buffer 1's read port is P10's; buffer 2's is the **secondary port**,
  P10's address when P10 reads buffer 2 (the point's SrcSelect or DstSelect), else the write-out's (`wo_re`, `wo_gnt`).
  Reads are registered and **the word goes to the register of the reader that asked** (P10's, held while its point is
  held; the write-out's): a write-out read under a held P10 point does not take that point's word (a bug the tile
  testbench found; the mutant `wo-takes-p10` is caught).
- Writes: P10's, to either buffer through `sel`. A debug port (the testbench's) writes and reads any word by logical
  buffer while the pipe is idle.
- Not yet: the actions on eoe, the write-out start, the DstSelect interlock (M12).

### 3.10 `p2_wout`: write-out, scaler, clip, strip buffer

**Function.** Owns tsp §17.2-17.4: refsw3 RenderCORE `put`, the dither table, pack modes 0-6, `putRow`,
`filtered`, `emitRows`, `endStream`, the strip buffer.
- Reads the secondary buffer in tile raster order.
- **Scaler** (factor = SCALER_CTL[15:0]):
  - 0x400: lines go to their own rows.
  - 0: nothing is written (GAP).
  - Otherwise a stream with an 8-line ring of 32 px x 32 bits, line and row counters (the row counter uses 10 bits),
    a start of 0 / 1024, and `streamX`.
  - A written tile with y = 0 restarts the stream.
  - Y_COEFF filter when factor > 0x400; the 4-bit line blend; hscale pair averaging.
  - At the render's end, `endStream(stuck = true)`. The filter's last-row stuck pixel is the hardware bug,
    reproduced as refsw3 has it.
- **Pixel clip** (inclusive, framebuffer coordinates after the scaler).
- **Strip buffer** (FB_R_CTRL[22], 16 x size lines, the strip counter only grows, SOF1 / SOF2).
- **Address**: `base + line * stride * 8 + X * bpp`.
- **Pack**: modes 0-6 with the dither add before truncation; mode 7 invalid (GAP).
- **VRAM writes**: through `pvr_map32` (32-bit view, C5 half writes with byte enables), or the 64-bit view for render
  to texture.
- **State** per render, reset at `start`: the scaler stream and the strip counter. The SCALER_CTL value of the last
  render is kept for the stall (below).

**Interfaces.**
- Start and `writeTile` from p2_tbuf; `busy` / `done` back.
- Secondary-buffer read port (shared, §3.9).
- C5. `ev_tsp`, `ev_vid`.

**Cycle.** [M tim §3.11] 1045 / 1105 / 1357 clk a tile (16 / 24 / 32 bpp), also fully clipped; dither changes nothing.
- [I] Per line: `max(32 + 0.66, W + 10.4)`, with W = 32-bit words a line.
- Mechanism:
  - a tile-buffer reader at 1 px a clock into a **line FIFO of `WO_FIFO` pixels** [G: 64];
  - a packer;
  - a VRAM writer issuing 1 word a clock, whose per-line cost of ~10.4 comes from the VRAM model's row change
    (§3.2.1) [G T9].
- `WO_FIFO` is a free parameter (§6). It sets how far the reader runs ahead of the writer, and so:
  - where a SrcSelect reader meets the write-out (the blendpos damage start, 470-804);
  - `ev_tsp - ev_vid` (80-96 clk in rendertimes, if `ev_vid` is the reader's end).

  It is fitted on those two (T10, T15).
- The reader's extra +0.66 a line [G]: a row turnaround.
- Write-out against shading: ~370 clk a tile not overlapped at 16 bpp [M spantex3], GAP T9. Candidate [G]: C4's
  64-bit texture reads need both halves while C5 holds half 0.
- Scaler and strip buffer: untimed (GAP).
- **SCALER_CTL changed between renders**: the next render writes its first tile and stops unless soft reset
  [M scalermeas]. [I] The scaler state survives renders and deadlocks a handshake when the factor changes under it.
  A hang feature: PLAN MT9, D6.

### 3.11 `lib/fp`: the numerics primitives (num §6) and where they are instanced

| primitive | instances (unit: site) |
|---|---|
| H1 lzc | everywhere (16, 17, 24, 25, 34, 50, 64, 128 bits) |
| H2 cut | isp_setup (20, 24), isp_raster (19), tsp_setup (16, 24), pp_mip (8) |
| H3 cut_below | isp_setup (edge `unit`, 2^102 for a big edge's steps and start; depth `pair - 21`, 2^102 for REG) |
| H4 inputs | isp_setup (`from_bits` edge, `from_single` depth), tsp_setup (`from_single`, `single_bits` colours), tsp_rstart (`seen`), FPU_CULL_VAL / FPU_PERP_VAL decode |
| H5 mul | isp_alu (24x24), tsp_alu (24x24, 16x13 exact), tsp_setup (`OneThird` 0xAAAAAB, 0x95F612), isp_setup (`OneThird`), pp_mip (24 x 5 to 8, 8x8 to 8), pp_fog (8 x 16 integer) |
| H6 add | isp_alu (24/25), tsp_alu (24/25; 24/53 for mip `radd`) |
| **H7a `fp_swamp`** (replaces revision 1's `edge_start_sat`) | isp_setup: `sw(v) = top(v) > 128 ? {v.neg, 0, 200, 1} : v` after each of the edge flavour's products and sums that edge.h swamps; and the start's saturation (`>= 2^128` gives +-2^127). A compare and a mux; no wide add |
| H7b tsp_half_line | tsp_rstart (SupSample) |
| H7c mip_minor_sub | tsp_setup (mip numerators) |
| H8 recip24 | isp_alu (depth: one value for `inv0`, `inv`, `invS`), tsp_alu (TSP det, mip) |
| H9 cmp | isp_setup (cull on the swamped det, perp), tsp_setup (perp, mip `AtMost`) |
| H10 range | isp_alu (**depth flavour at `4f3efe15`**: limits per product and sum, the zero rule in every addition (coordinates, edges, determinant included), the 2^126 determinant limit, §3.4.4 steps 6-7), tsp_alu (TSP, mip flavours) |
| H11 floor | isp_setup (FloorScaled row range; edge `unitsAt` at `unit`; depth grid shifts; REG `r0`, `fa`, `fb`), tsp_rstart (FloorUnits), tex_coord (TexCoordFixed / CoordKeep) |
| H12a tsp_value_norm | pp_plane (11 instances) |
| H12b depth_block_to_fp | isp_raster (32 lanes, positive `t` only; exact in the 30-bit form) |
| H13 tsp_div | pp_div (1 reciprocal + 11 products a pixel) |
| **H14 `p2_zword_pkg`** (depth.h `StoredDepth` at `708fb8cd`, unchanged at `4f3efe15`; num H14) | isp_raster (`from_fp`, `big`, `neg`, `regdepth`), isp_setup (`flat`, `saturated`), isp_pix (the 64-bit key compare), isp_ctl (`bgkey`) |
| H15 color_round | pp_col (8 instances) |

Every primitive takes and returns the reference tuple as flat ports (num §6). Combinational by default. A unit may
register a primitive's output as one of its pipeline stages; its lockstep testbench then compares at that latency.

### 3.12 Die agreement (M2-M11)

PLAN 0 rule 9: the HOLLY die shot (18 probable blocks, each labelled with a confidence; an interpretation of one
optical image, not a reverse-engineering result) is a tie-breaker for grouping, boundaries and RAM sizes; console
measurements and refsw3 win. The units built so far against it (die block numbers as the annotation's; no RTL was
changed for this note):

| unit (milestone) | die block | agrees | departs, or the die says nothing |
|---|---|---|---|
| ISP edge and depth raster, 32 lanes, one tile row a clock (`p2_isp_edge_raster` M2, `p2_isp_depth_raster` M3, joined under the row stepper `p2_isp_raster` M4) | 1 ISP PE array (high): 32 identical units, two halves of 16; 2 spine (plane broadcast, row control) | 32 identical lanes, one per tile column; one row stepper broadcasting the descriptor to all lanes, as the spine between the halves | the die's two halves of 16 are not a boundary here (one 32-lane array); the per-lane logic (edge sums, depth key) is not checked against the PE stripe's size |
| `p2_isp_pix` (M6, M7) | 1 (the PE's logic stripe) | the fragment rules per lane, beside the lane's storage | - |
| `p2_isp_buf` (M6, M7) | 1 (the PE's register tiles) | per-pixel state held per column (one RAM per lane and field, 32 rows deep), next to its lane; the second photo's ~6 small macros a PE (per-column state in RAM macros, not flip-flops) agree | the width: refsw3's state (64-bit depth keys, depthB / C, resTag, resDepth / savedDepth, two read copies of depthA / tagA) is far more than the die's register tiles look able to hold; the fields and widths follow refsw3 and the testbench's liveness compare, and which of them the console shares is open |
| `p2_isp_cut` (M7) | 3 span RLC / PE row interface (low): the strip over the array | run-length cut of one 32-pixel row a clock, at the array's edge | - |
| `p2_isp_setup` on one ALU (`ISP_NM` 3, `ISP_NA` 3, one reciprocal; M4) | 11 ISP setup FPU (low), apart from 12 TSP setup FPU; 10's "ISP precalc" beside the array | a setup datapath of the ISP's own, not shared with the TSP's; the three small macros stacked in 11 may be its constants / microprogram or operand store (here a ROM and registers) | 10 and 11 may split precalculation from setup; here they are one unit; operator counts are the scheduler's fit to the measured lengths, the die gives none |
| `p2_isp_pcache` (`PCACHE_N` 256 descriptors in one array; M7) | 6 ISP primitive cache (low): one wide and one narrow SRAM | a dedicated ISP-side store of the replayed primitives | one array here, two macros there (a wide one and a narrow one: descriptors and a count or tag, or vertices and something else); what is stored and how many is T13 / GAP, the die gives no size |
| `p2_isp_olw`, `p2_isp_pfetch` (M6) | none identified (probably near 15) | - | the die says nothing (no macro of their own) |
| `p2_isp_ctl`, `p2_isp_ptc`, `p2_isp_fb` (M6, M7) | none: control logic | - | the die says nothing |
| `p2_isp_entq` (the queue `p2_entq`, `ENT_N` 32 records; M7) | none identified (perhaps beside 7 span sorter queue) | - | the die says nothing; 32 records is [G] |
| `p2_runq` (one RAM of `RUNQ_N` 300 x 124 bits, 37 Kbit; M8) and `p2_sort` (96 places in flip-flops; M8) | 7 span sorter queue (low): two long SRAMs, about 0.93 mm² each (about 60 Kbit each at the palette RAM's density, research/REPORT.md "Region 16's size") | the run queue is one long RAM between the ISP's cut strip (3) and the TSP side, as one of 7's two macros; its size (37 Kbit at 124 bits a run) is below one macro's estimated 60 Kbit, and the console's run word is likely narrower (timing.md 3.6: ~40 bits; vmask / pmask are this design's, [A]) | the second macro has no counterpart: the window here is flip-flops, because it compacts (a freed place is reused at once, timemeas order) and a shift structure is the plain way to do that; the console may keep the window's payload in the second RAM, indexed by place, with only keys and an age order in logic. Not changed: the measurements fix the window's behaviour, not its storage, and the function and clocks here do not depend on it. That 7 holds the sorter at all is low confidence (REPORT.md: they could serve the write-out) |
| `p2_mem` (clients C1, C2; response FIFOs of `RSP_N` 8 per client and half; M6) | 15 texture memory arbiter / VRAM interface (low) | one arbiter for every VRAM client | no RAM macro is visible in 15 for the response buffers (small: flip-flops either way); the arbitration and buffer depths are GAP T9 / T14 |

| `p2_tsp_store`'s planes: 16 entries x 11 planes x 84 bits (14.8 Kbit) in four banks, plane p in bank p mod 4 (M9) | 5 TSP parameter cache (low): four equal SRAMs in a 2 x 2 | the four equal macros: the store's planes split four ways, the setup writing one plane a clock and run start reading per plane; the banks are the die's choice where nothing measured decides (T6) | the size: 16 entries [G T6] and the 84-bit planes (A, B, C kept as tuples, `p2_fp16_t`) are this design's; the die's macros may hold fewer, narrower words (a 16-bit float as 1 + 8 + 15 bits would be 72 a plane) |
| `p2_tsp_store`'s header and K: two RAMs of 16 words, 166 and 21 bits (M9) | 5's one wide and one narrow SRAM to the right of the 2 x 2 (second photo) | a wide word per entry (the ISP / TSP / TCW words and the fallbacks) beside a narrow one (K) | the keys, pins and the SRQ are flip-flops here (a 16-way key match and a pointer walk); the narrow macro could as well be the keys |
| `p2_tsp_setup` on `p2_tsp_alu` (`TSP_NM` 4, `TSP_NA` 4, two reciprocal issues a K job; M9) | 12 TSP setup FPU (low), apart from 11 (ISP setup) with a visible boundary between them | a setup datapath of the TSP's own, not the ISP's: no unit is shared with p2_isp_alu (the TSP's adders' zero rule reaches below the range, the ISP's does not; one adder each) | operator counts are the scheduler's at §6's values, which do not reach the measured lengths (§3.7.3 As built); the die gives no count; run start sharing this ALU (§3.7.4) is the architecture's [I tim §3.8], not the die's |
| `p2_tsp_pfetch` (client C3, M9) | none identified (near 15) | - | the die says nothing |
| `p2_tsp_store`'s row read for run start (M10): the four banks read side by side, a row of four planes a clock | 5's 2 x 2 of equal macros | four macros with a port each make a four-plane row a clock natural; the reload's four lanes (one a bank) follow it | the die gives no port count; the console's reload cost (~1-2 clk, tim 3.8) says the reload reads wide, which agrees |
| `p2_tsp_rstart` (M10): the coefficient cache (2 volumes x 11 planes of A', B', unit, F(C'), steps, hyd; flip-flops), four reload lanes, the products on 12's ALU | none of its own: logic between 5 and 12 | run start beside the parameter cache and the setup FPU it shares (12) | the cache is flip-flops here (it is read whole every run); the die shows no macro for it |
| `p2_pxq` (M10): one RAM of 48 run descriptors (~2.7 Kbit each, 130 Kbit) and a credit counter | 9 TSP pixel datapath (low): the ~25 small light macros in its lower-left part (second photo) | a queue of runs inside the pixel datapath, in RAM | the size: this design's descriptor carries every plane's words of both volumes (2 x 11 x 98 bits); the console's is surely narrower (base per run, the steps per primitive), and 130 Kbit is more than 9's small macros look able to hold. Not changed: the values and the measured queue depths (45-70 runs, T7) do not depend on it |
| `p2_pp_issue` .. `p2_pp_mip` (P0-P3, M10): the accumulators, 11 normalizers, one reciprocal (the 512 x 27-bit ROM, p2_fp_recip_rom) and 11 16 x 17 multipliers, the colour rounding, the level's two 8 x 8 multipliers | 9 TSP pixel datapath (low) | the per-pixel arithmetic in one datapath block; the reciprocal's ROM may be one of 9's small macros (or 18, "a small ROM") | the die gives no count of multipliers; one reciprocal a pixel is [I PIPELINE_SHAPE 5], not the die's |
| `p2_tex_cache` (M11): 8 KB, 1024 x 64-bit data words with four read ports, 128 tags in flip-flops | 8 texture caches (low): two small (second photo: two long) SRAMs | a texture cache of its own, near the TSP datapath and the memory arbiter (15) | two macros there against one data array with four read ports here (bilinear's four taps a clock); the console's may be two banks (even / odd words, or data and tags) serving the taps in fewer ports over more clocks; the organisation is the placeholder of §6 [G T8], the values do not depend on it, and its clocks are not gated (T8). Not changed |
| `p2_tex_pal` (M11): 1024 x 32 (32 Kbit), four read ports | 10 palette or fog RAM (low): the long SRAM, ~0.48 mm² | one RAM of 1024 x 32: the long macro's estimated size (research/REPORT.md: "if that SRAM is the 32-Kbit palette") agrees | four read ports here, one macro there; the measured +1 clk for an 8888 palette entry (tim 3.9) says a narrower path, read in steps: T8, not modelled |
| `p2_pp_fog`'s FOG_TABLE (M11): 128 x 16 bits in the fog stage | 9's small macros, or 10 | a small table beside the fog arithmetic | the die gives no place for it (10 is too large for 2 Kbit) |
| `p2_pp_shade`, `p2_pp_fog`, `p2_pp_ss`, `p2_pp_blend` (M11) | 9 TSP pixel datapath (low) | the per-pixel arithmetic in one block; the bump mapper inside it, no block of its own (NOTES "Corrections") | - |
| `p2_tbuf` (M11): two RAMs of 1024 x 32 (8 KB), each one read and one write port; the secondary port shared by P10 and the write-out | 4 tile accumulation buffers (medium): four macros of the densest RAM, each two sub-arrays over a shared periphery (8 sub-arrays) | two buffers of 4 KB, 8 KB in all, and a dual-port macro type (one blended into while the other is written out) | four macros against two RAMs: each buffer may be two macros (16-bit halves, or half a tile each), the 8 sub-arrays a further split; not modelled (the ports and their sharing are the measured part, tim 3.10) |

## 4. Ordering and hazards: the observable orders and the mechanism that keeps each

| observable order (spec) | mechanism |
|---|---|
| per pixel, fragments of a pass in list order (isp §1 item 1) | olw emits in list order; pcache replays in recorded order. Rows of one primitive go in order through one in-order pipeline. The same-row R1/R2 bypass (§3.4.6) |
| a volume closes after its last triangle (isp §1 item 2) | the closing triangle's own row writes apply the summary after the row's parity update; a culled or bad closer is a `kill` descriptor (§3.4.7) |
| pre-sort: each primitive shaded before the next is rasterized (isp §1 item 3) | ctl issues SHADE(PRESORT) after each primitive. The next primitive's row writes wait on the row barrier. The TSP blends in run-stream order |
| phases of an entry strictly ordered (isp §1 item 4) | ctl's phase sequence, walk-done (pipeline empty) before SHADE, `cut_done` before overwrite |
| PT / TR passes iterate (isp §1 item 5) | PT: wait for PASS_DONE. TR autosort: `more` is ISP-local, so no wait |
| passes and tiles do not mix in the sorter (tsp §3.2) | the epoch in the sorter's key (§3.6) |
| run order changes the TSP's carried state only (isp §1 item 6, tsp §3.4) | the sorter's deterministic rule and emit condition. `offsKept` and stuck alpha are single-stage registers in P7 and P10 |
| state carries between entries whatever their tile (isp §1 item 7) | one ISP buffer set, never cleared except by CLEAR |
| two tile buffers swap per written entry (tsp §17.1) | p2_tbuf actions at the next entry's first item, in order with the pixels |
| blend read-modify-write per pixel in TSP order | the P10 forward |
| palette / fog table read at shading time (tsp §3.4) | the reads are in P6 / P8, live RAMs |
| a render's VRAM reads against its own framebuffer writes (not in refsw3) | grant-time visibility in the VRAM model; renders where it matters are flagged VRAM-race (§3.2.1) |

## 5. How the measured numbers fall out (cycle summary)

| measured [M] (tim §) | mechanism | unit | free parameter | probe |
|---|---|---|---|---|
| ISP 16 / 15 culled / 19 sprite / strip 19-15 (3.2) | generated setup program; culled skips the hand-off (M4: 16 / 15 / **18**, the sprite one short: 3.4.4) | isp_setup | `ISP_NM`, `ISP_NA`, `L_*` | T2 |
| +1 a line per triangle past 16 lines (3.2) | raster 1 row/clk behind a 1-deep hand-off: `max(16, rows)` | isp_raster | hand-off depth 1 | T2 |
| thin triangles step ~25 rows of 32 (3.2) | GAP (no row skipping by default) | isp_raster | row-skip rule | T2 |
| 2-triangle volume 65 (3.2) | 32 rows each (no row range), summary folded; the 65th clock GAP | isp_raster | `MV_GAP` | T2 |
| list pointer present 20-31 (3.1) | olw's first read through mem + VRAM latency | olw, VRAM model | `VR_LAT` | T1 |
| cut 1 clk a run (3.4) | priority encoder, 1 run/clk | isp_cut | — | — |
| ISP bit 14.6 tiles early; 436 / 443 / 462 / 476 runs left (3.5) | cut blocked by full queues; `ev_isp` at the last accept; §3.5 formula | runq, sort, SRQ, pxq | `RUNQ_N`, `PXQ_PIX`, `PXQ_RUNS` (fitted, MT2) | T3 |
| order: window 96, drains, passes / tiles apart (3.6) | sorter with the epoch key | sort | — (96 [M]) | T5 |
| early drains, sort-off order (3.6) | GAP | sort, store | emit rule, rates | T5 |
| TSP setup 39 / 48 / 64 / 49, +5 DCalcCtrl (3.7; the 49 is the bump map's measured figure, which runs the textured class's program: §3.7.3 compares 48) | generated programs on the shared ALU | tsp_setup, tsp_alu | `ALU_NM`, `ALU_NA`, `L_*` | T6, T7 |
| PT setup 58 (3.7) | none (GAP, not padded) | — | — | T6 |
| look-ahead ~11-12, "keeps 16" sort-off (3.7) | 16-entry store, ~4 pinned | tsp_store | `STORE_N` 16, pin rule, `SRQ_N` | T6 |
| ~2 clk a plane taken from run starts (3.8) | ALU arbitration | tsp_alu | priority | T7 |
| run start 3.9 / 4.2 / 6.3; 4.7 / 6 / 8 (3.8) | 2 products a plane a run; reload on an index change | tsp_rstart | — | T7 |
| bursts of ~45-70 runs hidden (3.8) | pixel credits | pxq | `PXQ_PIX`, `PXQ_RUNS` (from MT2) | T7 |
| B = 1035 per entry, "1.01 clk/px" (3.1, 3.9) | 1024 px + the pass drain | pp | `D_PP` (fitted once, MT6) | — |
| small TR layer 52 (3.3) | 39 setup + 1 px + `D_PP` + ~1; ISP replays from pcache | pp, pcache | — (check) | T13 |
| +1 for 8888 palette, YUV bilinear, non-twiddled bilinear; 2.14 memory bound (3.9) | texel gather 4 x 16 bit/clk with reuse; two-step 32-bit taps; YUV converter; row span | tex | cache | T8 |
| first tile +35..+455 (3.9) | cache invalidated at `start` | tex_cache | — | T8 |
| SEC WRITE +1025 / SEC READ damage (3.10) | DstSelect interlock / shared read port | tbuf | `WO_FIFO` | T10 |
| empty keep-Z ~2390, hang (3.10) | `p2_tbuf_hs` [G] | tbuf | handshake form | T11 |
| write-out 1045 / 1105 / 1357, clip (3.11) | 1 px/clk reader, line FIFO, 1 word/clk writer, per-line row cost | wout, VRAM model | `VR_ROW`, `WO_FIFO` | T9 |
| tile ≈ max(ISP, TSP, write-out) (3.1); 16-bit pace 1041.5-1042 | queues + tbuf WRITE wait: max(1035, 1045) | all | — | — |
| PT chunk carry by the ISP's lead (2.2) | GAP: K1 / K2 | isp_ctl, isp_buf | `P2_PTCARRY` | T12 |
| bumphang 16 / 8, persistent (3.12) | counter in tex_cache [G] | tex_cache | what counts | T18 |
| pre-sorted TR-mod background skip (3.12) | GAP | isp_ctl_tg | set / clear rule | T21 |

## 6. Free parameters (initial values; each is fixed by a probe, by a one-time fit on the data named, or kept as GAP)

| parameter | initial | evidence | fixed by |
|---|---|---|---|
| `SEQ_AHEAD`, `OLW_AHEAD`, `PF_AHEAD` | 2, 8, 2 | [G] | T1, T2 |
| `CTL_T`: clocks a ctl transition | 1 | [G] | T13 |
| `ISP_NM`, `ISP_NA`, `L_MUL`, `L_ADD`, `L_RCP` (ISP) | 3, 3, 1, 2, 2 (M4): the scheduler gives TRI 16, QUAD 18; no set gives 16 / 19 (3.4.4) | [M] lengths are the check; fitted on the triangle, so the 16 is reported, not gated | T2, MT1 |
| row-skip rule for thin triangles | none | [M] anomaly | T2 |
| `MV_GAP`: bubble after a `sum_op` descriptor | 1 | [G] 65 = 64 + 1 | T2 |
| row barrier form (cut vs next writes) | per row | [G] | T4 |
| sweep costs (CLEAR, PEEL, PT_*) | 32 clk each (as built M7: 33, a read stage and a write stage) | [G] | T13 |
| `PCACHE_N`; replay cost; what pcache stores; TR_MOD re-walked; PT replay (vs vertices, vs re-walk) | 256; max(1, rows); descriptors; yes; replay (as built M7: a PT chunk past 256 walks its later passes, ptc full-walk mode) | [I] TR, [G] PT | T13 |
| `RUNQ_N` | 300 | [M] ispq, fitted | MT2 (fit) |
| flags instead of marker items | flags | [I] ispq fit (§3.5) | T3 |
| `ENT_N` (`p2_entq`) | 32 | [G] | T3 |
| sorter emit / fill per clock; emit condition | 1 / 1; full or oldest epoch closed | [G] | T5 |
| `SRQ_N` | 32 | [G] | T6 |
| `STORE_N`, replacement, pin extent, `STORE_KEEP` across entries | 16, FIFO, to P10, kept | [M] / [G] | T6 |
| `ALU_NM`, `ALU_NA`, `L_*` (TSP), arbitration | 4, 4, 1 / 2 / 2 (M9: lengths UNTEX 20, TEX 26, TEX_O 39, +5 for K, +1 for DCalcCtrl 1; none of the sweep reaches 39 / 48 / 64), run start first (a held step) | [I] / [G] | T7, MT4 |
| `JOB_N` (store to pfetch), `PF_OUT`, `PF_AHEAD` (TSP fetch) | 2, 8, 2 (M9) | [G] | T6 |
| `PXQ_PIX`, `PXQ_RUNS`, position | 256, 48, before texturing (as built M10: `P2_PXQ_PIX`, `P2_PXQ_RUNS` in p2_tsp_pkg) | [M] ispq + spanahead, fitted | MT2 (fit), T7 |
| `D_PP`: the pass drain | 11 (the P0-P10 depth; as built M10: the drain ended at P3's exit, 3 stages; M11: at P10's exit, 11 stages, and none after a TR_PRESORT pass, §3.7.7 As built (M11)) | [M] B = 1035 | MT6 (fit) |
| run start's coefficient cache and reload | as built M10: one entry a volume, keyed (tag, volume, tile); rows of four planes; the reload not overlapped with the products (4.00 / 5.00 / 7.00 within, 8.1 / 9.1 / 12.1 across, against 3.9 / 4.2 / 6.3 and ~4.7 / 6 / 8) | [I] / [G] | T7, MT5 |
| SupSample points per clock | 1 | [G] | T16 |
| texture cache organisation, miss latency, C5 coherence | direct-mapped 8 KB, 64 B lines, no snoop (as built M11: four read ports, one fill at a time, the taps gathered; §3.8 As built (M11)) | [G] | T8 |
| `VR_LAT`, `VR_ROW`, refresh, half contention, arbitration priority | 8, fitted, off, as §3.2 | [G] | T9, T14 |
| `WO_FIFO` | 64 px | [G] | T10, T15 |
| write-out line overhead | in the VRAM model | [I] | T9, T10 |
| SrcSelect && DstSelect waits for the write-out | yes | [G] | T10 |
| `p2_tbuf_hs` handshake | as §3.9 | [G] | T11 |
| `P2_PTCARRY` (K1 / K2 / none) | none (refsw3) | [M] races | T12 |
| `ev_vid` event | the reader's last pixel | [G] | T15 |
| bumphang counter | 16 TR / 8 OP-PT quads | [M] count, [G] structure | T18 |
| `p2_isp_ctl_tg` glitch rule | none | [M] once | T21 |

## 7. Traceability: every rule has an owner

### 7.1 isp.md (with §0.1's supersessions)

| section | rule | owner unit(s) | milestone (PLAN) |
|---|---|---|---|
| 1 | order of processing | isp_ctl (phases), seq (walk) | M6, M7 |
| 2 | registers the ISP reads | regs; consumers | M0 |
| 3.1 | region array entry | seq | M12 |
| 3.2 | object list entries | isp_olw | M6 |
| 3.3 | parameter blocks, PARAM_BASE & 0xF00000, two volumes | isp_pfetch | M6 |
| 3.4 | primitive assembly, odd-strip swap | isp_pfetch | M6 |
| 3.5 | tag (32 bits), sort key | isp_pfetch (build), isp_pix (key), sort (key) | M6, M8 |
| 4.1 | per entry: OP_MOD only with OP; PT_MOD; TR_MOD only in autosort; background not rasterized | isp_ctl | M7 |
| 4.2 | Z clear, background key (`bgkey` at `708fb8cd`) | isp_buf (CLEAR), zword_pkg | M1, M6 |
| 4.3 | accumulation across entries | isp_buf (no clear), tbuf | M6, M12 |
| 4.4 | end of entry: emptyKeepZ, emptyAfterNoWrite, swap | isp_cut (`shaded_any`, entq), tbuf | M7, M12 |
| 5 | list walk, ObjectListHasPrimitive | isp_olw | M6 |
| 6.1-6.3 | soft float, inputs, range rules (depth flavour at `4f3efe15`: the zero rule in every addition, the 2^126 determinant limit) | lib/fp (H4, H5, H6, H10) | M1, M3 |
| 7.1 | bad corners; the winding from the **swamped** determinant (`EdgeWinding`) | isp_setup (H7a swamp) | M2 |
| 7.2 | cull by size / facing on the swamped determinant | isp_setup (H9) | M2 |
| 7.3 | FPU_PERP_VAL | isp_setup (H9) | M3 |
| 8.1-8.3 | edges, EdgeHW (blockMax, cutUnitBits, walkExp), edge setup with swamping, E cap, a big edge's 2^102 grid | isp_setup | M2 |
| 8.4 | inside decision (ordinary and big-edge walk: wrap, push, end against ZERO, far value) | isp_raster | M2 |
| 8.5 | RTL widths (31-bit ordinary, 34-bit lanes and walk, d ≥ 30 constant, d 27 big) | isp_raster, `p2_edge_t` | M2 |
| 8.6 | row range, row-31 shift (every polygon) | isp_setup (compute), isp_raster (apply) | M2 |
| 9.1-9.3 | DepthHW (zeroRuleCoords, zeroRuleEdges), plane setup, the start at the first sample point, regimes CONST (det infinite or >= 2^126) / REG / BLOCK | isp_setup | M3 |
| 9.4a | block plane, 30-bit stepping; the float form unreachable | isp_setup, isp_raster | M3 |
| 9.4b | determinant-zero mean, infinite corners | isp_setup | M3 |
| 9.5 | overflowing planes: REG (`regdepth`), forced start | isp_setup, isp_raster | M3 |
| 9.6 | storing a depth (`from_fp`, `big`, `neg`, `flat`) | isp_raster, zword_pkg | M1, M3 |
| 9.7 | depth order: the 64-bit key | zword_pkg, isp_pix | M1 |
| 10.1 | buffers | isp_buf | M6 |
| 10.2 | DepthMode per list | isp_pix | M6 |
| 10.3 | KeyAbove, first reference = what is there, TAG_BELOW = 0xFFFFFFFF | isp_pix | M7 |
| 11.1 | opaque | isp_pix, isp_ctl | M6 |
| 11.2 | modifier volumes, the summary folded into the closer, culled closers | isp_pix, isp_buf, isp_setup (`kill`), isp_ctl | M6 |
| 11.3 | OpInPt | isp_olw (scan), isp_ctl, isp_cut | M7 |
| 11.4 | PT chunks (signed compare), passes, feedback, chunk / final, PT_MOD | isp_ptc, isp_ctl, isp_pix, isp_fb, isp_buf, isp_pcache | M7 |
| 11.5 | translucent pre-sorted | isp_ctl, isp_pix, isp_cut | M7 |
| 11.6 | translucent autosort, savedDepth, replays | isp_ctl, isp_pix, isp_buf, isp_cut, isp_pcache | M7 |
| 12.1 | runs (SpanGen), `pmask` | isp_cut | M7 |
| 12.2 | run order (SpanSort) | sort | M8 |
| 12.3 | who updates the ISP buffers after shading | isp_cut (presort, autosort), isp_fb (PT) | M7 |
| 13 | state summary | isp_buf, isp_ctl, tbuf | M6, M7 |
| 14 | timing anchors, races | §5 of this document | MT1-MT9 |
| 15 | GAPs | per unit, as refsw3 (#1-#6, #8, #10 resolved at `708fb8cd`; #5, #6 (but a slope of 2^128 after the division), #7, #13, #26 at `0de9776b` / `4f3efe15`; #21 SB_ISTERR in pcache, D11; #22 the pre-sorted glitch in isp_ctl_tg) | — |
| 17 | lockstep points | PLAN §1 | — |

### 7.2 tsp.md

| section | rule | owner unit(s) | milestone |
|---|---|---|---|
| 0 | registers | regs | M0 |
| 1 | pass order per entry | isp_ctl (source), run-stream flags, pp | M7, M12 |
| 2.1 | ISP hand-over (tag, valid, rendered, inside) | `p2_rs_t` (cut) | M7 |
| 2.2 | parameter fetch, vertex decode, odd swap, background | tsp_pfetch | M9 |
| 2.3 | planes a primitive has, two volumes, InVolume | tsp_setup, pp_issue | M9 |
| 2.4 | gentable dispatch | pp_issue (decode) | M10 |
| 3.1 | span generation | isp_cut | M7 |
| 3.2 | span sort | sort | M8 |
| 3.3 | pixel order in a span | pp_issue | M10 |
| 3.4 | observable order | pp_shade (`offsKept`), pp_blend (stuck), §4 | M11, MT3 |
| 4.1-4.5 | plane setup, sums, division, det 0 / perp mean, colour planes, dropped offset planes (§3.7.3 table) | tsp_setup (H5, H6, H8, H10) | M9 |
| 4.6 | intensity shadow | tsp_setup | M9 |
| 5.1 | `seen` | tsp_rstart (H4) | M10 |
| 5.2-5.4 | grid, run start, SupSample half steps | tsp_rstart (H11, H7b) | M10 |
| 5.5 | value format | pp_plane (H12a) | M1, M10 |
| 6.1-6.3 | divider | pp_div (H13) | M1, M10 |
| 7 | colour rounding | pp_col (H15) | M1, M10 |
| 8.1 | mip K | tsp_setup (H7c, H10 mip) | M9 |
| 8.2-8.3 | mip per pixel, mipChoose | pp_mip | M10 |
| 9.1 | coordinates, ClampFlip | tex_coord (H11) | M11 |
| 9.2-9.4 | texel index, twiddle, MipPoint, word / lane, VQ | tex_addr | M11 |
| 9.5 | byte swap | tex_decode | M11 |
| 9.6 | palette | tex_decode, regs (PALETTE_RAM) | M11 |
| 10 | texel decode, YUV, bump raw, stride widening | tex_decode | M11 |
| 11 | filtering | tex_filter | M11 |
| 12 | bump mapper | pp_shade | M11 |
| 13 | colour combiner | pp_shade | M11 |
| 14 | offset colour, `offsKept` | pp_shade | M11 |
| 15 | colour clamp, fog | pp_fog, regs (FOG_TABLE) | M11 |
| 16 | trilinear fade | pp_fog | M11 |
| 17.1 | tile buffers, swap, write-out logic | tbuf | M12 |
| 17.2 | clip, address, strip buffer, RTT | wout | M12 |
| 17.3 | pack, dither | wout | M12 |
| 17.4 | scaler | wout | M12 |
| 18 | SupSample | pp_issue, pp_plane, pp_ss, tsp_rstart | M10, M11 |
| 19.1 | alpha test (PT passes; PT_MV per `pmask`) | pp_blend | M11 |
| 19.2 | blend unit (buffer-2 reads for SrcSelect and DstSelect) | pp_blend, tbuf | M11 |
| 19.3 | stuck alpha | pp_blend | M11 |
| 19.4 | per-pass handling, run-only pixels | pp_issue, pp_blend, isp_fb | M7, M11 |
| 20 | tables: reciprocal, SIN / COS, dither, MipPoint, 1/3, length constant | pp_div, pp_shade, wout, tex_addr, tsp_setup / isp_setup (ROMs generated from the header, num H13) | M1, M11 |
| 21 | timing | §5 | MT1-MT9 |
| 22 | GAPs | per unit, as refsw3 | — |
| A, B | c digits; SIN / COS | ROM generators (tools/gen) | M1, M11 |

### 7.3 numerics.md

| section / primitive | owner | milestone |
|---|---|---|
| §1 the number, representation contract, exponent range | `p2_fp*_t`, every primitive | M1 |
| §2.1-2.12 operations | lib/fp H1-H11 | M1 |
| §3 configurations EdgeHW (now with blockMax, walkExp) / DepthHW / PlaneHW, constants | `p2_hw_pkg` (generated) | M0 |
| §4 range rules, four flavours (the depth flavour per `4f3efe15`) | H10 instances in isp_alu, tsp_alu | M1, M2, M3, M9 |
| §5 call sites | the units of §3.11 | M2-M11 |
| H1-H6, H8-H13, H15 | lib/fp | M1 |
| H7a (now `fp_swamp`) | isp_setup | M1, M2 |
| H14 (now `p2_zword_pkg` at `708fb8cd`, unchanged at `4f3efe15`) | zword_pkg | M1, M3 |
| §8 A1 wide adds | H7b (tsp_rstart), H7c (tsp_setup). The edge site is gone | M1 |
| §8 A2 64-bit truncation | isp_raster (exact in 30 bits; tb asserts) | M3 |
| §8 A3 float fallback | unreachable at `708fb8cd` and `4f3efe15`; tb asserts | M3 |
| §8 A4 unreachable clamps | tb assertions | M1 |
| §8 D1 MipSelect divide by zero | tsp_setup (needs refsw3's definition, D4) | M9 |
| §8 G1-G13 | as refsw3, per unit (G3, G4, G12 resolved at `708fb8cd`; G13 at `1040c4aa`; G6, G7 and G5 but a REG slope of 2^128 after the division at `0de9776b` / `4f3efe15`) | — |

### 7.4 refsw3 functions to units

| refsw3 (`708fb8cd`) | unit |
|---|---|
| `RenderCORE` (walk) / `ReadRegionArrayEntry` | seq |
| `RenderCORE` (phase order, background key) | isp_ctl |
| `RenderCORE` (end of entry, put, dither, scaler, strip) | tbuf, wout |
| `RenderObjectList`, `ObjectListHasPrimitive` | isp_olw |
| `RenderTriangleStrip` / `Array` / `QuadArray`, `CoreTagFromDesc`, `decode_pvr_vertices` (ISP use) | isp_pfetch |
| `RenderTriangle` (chunk check, summary after every closer, presort shade) | isp_ptc, isp_setup (`kill`), isp_raster, isp_ctl |
| `PtChunkTake`, `TriangleCulled` | isp_ptc, isp_setup |
| `RasterizeTriangle` (setup part), `Winding` (bad only), `EdgeWinding`, `EdgeTile::Setup`, `RowRange`, `SetFirstRow`, the row-31 shift, `DepthTileT::Setup`, `CulledBySize` / `Facing`, `Perpendicular`, `OneThird` | isp_setup |
| `EdgeTile::InsideOrdinary`, `RowMask`, `Walk`, `Inside`; `DepthTileT::At`, `NegWord`, `RegDepth` | isp_raster |
| `StoredDepth::Key32`, `Bits`, `Between`, `Neg`, `Flat`, `Big`, `Saturated`, `FromFp` | zword_pkg |
| `PixelFlush_isp`, `KeyAbove` | isp_pix |
| `ClearBuffers`, `ClearParamStatusBuffer`, `PeelBuffers*`, `Summarize*`, `SaveDepth*`, `RestoreDepth` | isp_buf |
| `SpanGen` | isp_cut |
| `SpanSort` | sort |
| `RenderParamTags` (ISP side, feedback) | isp_cut, isp_fb |
| `RenderParamTags` (TSP side), `PixelFlush_tsp` dispatch | pp_issue, pp_blend |
| `GetFpuEntry`, `ClearFpuCache` | tsp_store, tsp_pfetch; pp_blend (stuck-alpha clear) |
| `decode_pvr_vertex` (TSP use) | tsp_pfetch |
| `IPs3::Setup`, `SetupIntensity`, `PlaneT::Setup`, `MipSelect` (K part) | tsp_setup |
| `PlaneT::Value`, `PlaneStepper3::Val` | tsp_rstart (to `k`), pp_plane (stepping, normalize) |
| `RecipTable`, `DenominatorSeen`, `Divide` | pp_div |
| `ColorRounded`, `InterpolateBase`, `InterpolateOffs` | pp_col |
| `MipSelect` (per-pixel part), `mipChoose` | pp_mip |
| `TexCoordFixed`, `CoordKeep`, `ClampFlip` | tex_coord |
| `TexOffsetGen`, `TexAddressGen`, `TexStride`, `VQIndexAddress`, `twop` | tex_addr |
| `TextureFetch`, `DecodeTextel`, `ExpandToARGB8888`, `YUV422` | tex_cache (fetch), tex_decode |
| `TextureFilter` | tex_filter |
| `BumpMapper`, `bumpLight`, `shade`, `ColorCombiner`, `offsKept` | pp_shade |
| `FogUnit`, `LookupFogTable`, `fade` | pp_fog |
| SupSample block of `PixelFlush_tsp` | pp_issue, pp_ss |
| `tspAlphaStuck`, `BlendingUnit`, `BlendMul`, `BlendCoefs` | pp_blend |
| `NextTileAccumulationBuffers`, `GetColorOutputBuffer` | tbuf |

## 8. Architecture-level GAPs and choices to revisit

1. **Run item encoding** (`vmask`, `pmask`, flags). Functionally required; the console's encoding is unknown. It
   matters for timing only through the queue counts (T3).
2. **Per-volume setup store key.** Measured "set up twice" [M allfs]. Mixed-`vmask` runs are not measured (T19).
3. **Sweeps as 32-clock row passes** (T13). The summary has no sweep.
4. **The row barrier** between the cutter and the next writes (T4).
5. **Race sub-blocks**, each to be fitted by its probe:
   - PT chunk carry (isp_ctl / isp_buf, `P2_PTCARRY`): T12;
   - empty keep-Z handshake (`p2_tbuf_hs`): T11;
   - the secondary-read race (the tbuf port mux, `WO_FIFO`): T10;
   - the VRAM read-after-write race (VRAM model, tex_cache coherence): flagged, not modelled further (T8).
6. **The ISP primitive cache**: what it stores, the PT replay, TR_MOD, the overflow behaviour (T13). SB_ISTERR
   modelling is owner decision D11.
7. **The texture cache**: a placeholder organisation until T8.
8. **Hangs** (bumphang, the SPAN_SORT_CFG 0x100 / 0x10001 hangs, double empty keep-Z, the SCALER_CTL stall). Modelled
   only where a mechanism is stated, and behind a build switch. Owner decision D6.
9. **SOFTRESET's effect** on the tile buffers, the buffer select and the caches (G8).
10. **What the TA does during a render** (G7). The display stalls (G9) are a VRAM-model option, off by default.
11. **The pre-sorted TR-modifier background skip** (`p2_isp_ctl_tg`): history-dependent, set / clear rule unknown.
    T21.
12. **The 64-bit depth key**: 4 fields x 64 bits per pixel. An exact narrower encoding (class, E, M) exists, but it
    needs the key function at every compare. The key is kept until a synthesis report says otherwise (MQ).
13. **refsw3's own open points** that the RTL copies: the edge ones (the walk's unit size, the row-31 shift for
    ordinary polygons, the walk's end rule with `sx < 0`) are measured and closed by `1040c4aa` (edge2_*; PLAN F17
    closed); why row 31 is not known, and the far value's 2^131 has only a reading [I]. The depth ones (the zero rule
    in the coordinate differences and determinant, the order of REG and Big keys among other planes' depths) are
    measured by `0de9776b` (depth2_*) and transcribed (§0.1b; PLAN F18 closed but for a slope of 2^128 or more after
    the division); the determinant of 2^126 or more by `4f3efe15` (trsort_*; PLAN F14 closed).

## Appendix A. Revision 2: answers to the review of revision 1

| objection | answer | where |
|---|---|---|
| A1 the edge unit is out of date | Re-pinned to `708fb8cd`. Swamped determinant for sign and culls; swamp rule replaces 2^132; dx / dy swamp in the start's products and step saturated; E cap 129, d 22..26, `zsh` widened to 4 bits; big-edge walk with fine units, wrap, push, end; 40-bit lane datapath shared by both units; row-31 shift with big flags known before `jf`; H7a is `fp_swamp`; `p2_hw_pkg` gains blockMax, walkExp. (Revised at `4f3efe15`, §0.1b: one 2^102 grid, 34-bit lanes, the row-31 shift for every polygon, `cutUnitBits`.) | §0.1, §0.1b, §2.4, §3.4.4 steps 1-5, §3.4.5, §3.11; PLAN M2 |
| A2 a culled / bad closer loses its summary | It is handed over as a `kill` descriptor and applies the summary | §3.4.4 step 8, §3.4.7; PLAN M6 mutant |
| A3 dropped offset planes miss the det 0 path | The rule per branch, decided on the scaled values; M9 directed class | §3.7.3; PLAN M9 |
| A4 one `rflag` per PT_MV run | Per-pixel `pmask` (`rendered`) in PT passes and PT_MV | §2.3, §3.4.8, §3.7.7 |
| A5 29-bit tags | 32-bit tags everywhere; TAG_BELOW is 0xFFFFFFFF; no below flag | §2.2, §3.4.6 |
| A6 the lazy summary's rules | The lazy summary is replaced by a fold into the closer's row writes; no pending state exists, so the four rules have nothing to govern | §3.4.7 |
| A7 signed chunk threshold | Signed 12-bit compare; sizes 0, 1, 2 in M7 | §3.4.10; PLAN M7 |
| A8 write visibility | Grant-time visibility in the VRAM model, hazard detector, VRAM-race class; tex_cache coherence GAP; rule 5 and §8 | §0.2, §3.2.1, §3.8, §8; PLAN §1.6 |
| B1 sorter barrier vs ispq | Barrier removed; epoch in the key; emit condition | §3.6 |
| B2 accounting | Formula with every queue; markers as flags; MT2 fit target, numbers given | §3.5, §2.3; PLAN MT2 |
| B3 ISP buffer ports | Per-field storage, one write port, two read copies of depthA / tagA, flops for narrow fields, no-conflict argument | §3.4.7; PLAN MQ |
| B4 setup programs as cost tables | Generated from refsw3's operation graph by a scheduler; graph proved against refsw3; lengths are checks; PT 58 GAP, not padded | §3.4.4, §3.7.3; PLAN M4, M9, MT1, MT4 |
| B5 the ISP cache | `p2_isp_pcache`: TR replay is [I] from the 52-clk layer; PT replay [G]; SB_ISTERR counter, D11 | §3.4.11, §1.2; PLAN D11, T13 |
| B6 1.01 clk/px and B = 1035 | The pass drain `D_PP`, fitted on B and checked on the TR layer | §3.7.7, §5, §6; PLAN MT6 |
| B7 PT chunk carry | Candidates K1 and K2 with their predictions; the default's consequence stated (T20) | §3.4.1 |
| B8 write-out line FIFO | `WO_FIFO` added | §3.10, §6 |
| B9 pre-sorted TR-mod glitch | Owner `p2_isp_ctl_tg`; probe T21 | §1.4, §3.4.1, §8; PLAN §3 |
| B10 DstSelect reads buffer 2 | Port description extended; SrcSelect && DstSelect wait is GAP, default waits | §3.9, §3.7.7 |
| B11 misused tags | [A] now means "no clock depends on it"; ctl transition, store across entries and others re-tagged [G] and listed in §6; MT2 / MT7 gate lists fixed | §0, §6; PLAN MT2, MT7 |
| C1-C5 | PLAN | PLAN §1, §2 |
