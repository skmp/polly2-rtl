# polly2-rtl plan: build order, gates, testbenches, console probes

Role: architect. Revision 2, 2026-11-20, revised in answer to the review of revision 1 (Appendix A). The companion
of [ARCHITECTURE.md](ARCHITECTURE.md), which defines the units this plan builds. The repository rules are
[conventions.md](conventions.md). Unit names, formats, free parameters and the D1-D11 decisions are the
architecture's.

Pins: refsw3 = nulldc3 `skmp/refsw3` @ `708fb8cd` (refcore clean); dreamcast-tests @ `b54c934`. The specs lag refsw3
on the edge and depth units (ARCHITECTURE §0.1); where they disagree, refsw3 is the reference for every gate.

## 0. Rules for every milestone

1. **One implementation round each.** A milestone delivers:
   - its RTL files;
   - its testbench (a new one: a new feature gets its own testbench and make target, conv §6.1);
   - its gate;
   - its mutants (conv §7.7).
2. **The gate is a script.** It ends with `<gate>: PASS` or `<gate>: FAIL`, the exit code matching. It writes
   `build/gate/<gate>/summary.txt` with the revision header of conv §2: nulldc3 HEAD, refsw3 dirty hash,
   dreamcast-tests revision, and the runtime-switch check (§1.1). "Done" means the script says PASS. Prose does not
   count.
3. **Quick and full.** The quick gate runs in under a minute and is what agents iterate on. The full gate (`-full`)
   runs once at the end of the milestone (conv §7.8). Sharded with `--shard k/N`, `NJOBS=8`. A gate that takes
   minutes runs under `flock /tmp/polly2-rtl-gate.lock`.
4. **Pass criteria.**
   - **0 mismatches** against refsw3 in every compared field.
   - Archived console sets: equal to the console wherever refsw3 is. **`refsw3-known` is computed at gate time**
     (§1.4), never kept by hand: a region where the recorded refsw3 differs from the console fails only if the RTL
     also differs from refsw3 there.
   - **VRAM-race renders** (ARCHITECTURE §3.2.1) are compared and reported in their own class, never counted as a
     pass or a fail.
5. **Mutants.** The control run must pass and every listed mutant must fail (`make <unit>-mutants`). A milestone
   without mutants is not done.
6. **Nothing is gated on an unmeasured timing rule.** A parameter that is still GAP (ARCHITECTURE §6) is reported,
   not gated, until its probe comes back. A parameter **fitted** on a number does not gate that number. Each fit
   happens once, in the milestone named in ARCHITECTURE §6, and is recorded in `docs/timing.md`.
7. **refsw3 moves.** When a nulldc3 commit touches refcore, the next gate run re-runs `make fp`, the M2 / M3 quick
   gates and `check_ref_copies`, and updates ARCHITECTURE §0.1 if a spec falls behind.

## 1. Testbench architecture

### 1.1 Linking refsw3 (conv §7.3)

| level | how | used by |
|---|---|---|
| **L1** headers | `-std=c++17 -I$(REFCORE)`: `pvr_softfp.h`, `pvr_bits.h`, `pvr_isp_edge.h`, `pvr_isp_depth.h`, `pvr_tsp_plane.h` | M1-M4, M9, M10 |
| **L2** glue | `tb/ref/refcore_glue.cpp` `#include`s `refsw_lists.cpp` and `refsw_tile.cpp`, compiled once into `build/ref/refcore_glue.o` with refsw3-offline's FLAGS / INC / DEF (parsed from `$(NULLDC3)/refsw3-offline/build.sh`, drift-checked) plus `-DRenderCORE=RenderCORE_sw`; linked with `pvr_mem.cpp`, `TexCache.cpp`, `threading.cpp`, `-lpthread -lz`; environment in `tb/ref/refcore_env.cpp` | M5-M12 |
| **L3** process | `refsw3-offline` on the same command stream | M2, M3 (triangle extraction), M12, M13, refsw3-known |
| copies | rules that are local lambdas, statics or template bodies no wrapper reaches, copied **verbatim** into `tb/ref/ref_copies.h` between anchor markers. `tools/check_ref_copies.sh` re-extracts and diffs them on every gate run, and fails on drift (num §7.1) | M1-M12 |

**The copies** (each with its anchor, its source function and the milestone that first needs it):

| copy | source | milestone |
|---|---|---|
| the setup part of `RasterizeTriangle`: Winding / EdgeWinding / cull, the four `EdgeTile::Setup`, RowRange, **the row-31 shift**, `SetFirstRow` | tile.cpp | M2 |
| `CulledBySize`, `CulledByFacing` (static) | tile.cpp | M2 |
| the background key block of `RenderCORE` (`bgZ`) | lists.cpp | M1 |
| `PtChunkTake` and the PT loop of `RenderCORE` | lists.cpp | M7 |
| the `RenderParamTags` loop | tile.cpp | M5 |
| MipSelect's K part | plane.h | M9 |
| the `PixelFlush_tsp` lambdas `bumpLight`, `shade`, `mipChoose`, `fade`, and the SupSample block | tile.cpp | M10, M11 |
| the `put` / scaler lambdas of `RenderCORE` | lists.cpp | M5, M12 |

**Runtime switches are pinned** (`tools/check_ref_switches.sh`, run by every gate, result in the summary):
- the environment has `MIP_K` and `MIP_ARITH` unset or `0` (plane.h reads both with `getenv`);
- the glue and refsw3-offline are compiled without `-DFOG_VARIANT`, or with `0` (tile.cpp);
- the `*HW` structs are the ones `p2_hw_pkg` was generated from (`hw-pkg-check`).

**The p2ref API.** These are non-static wrappers in the glue's translation unit. Because that translation unit
includes the two `.cpp` files, every static is in scope.

```
namespace p2ref {
  // environment and render
  void     load_state(const char* dir);            // vram.bin (32-bit-area order, mapped through pvr_map32) + pvr_regs.bin
  void     begin_render();                         // what RenderCORE does before its loop (perpVal, rendlog)
  uint32_t read_entry(uint32_t base, RegionArrayEntry* e);
  // ISP phases: the calls RenderCORE makes, one by one
  void clear_buffers(uint32_t bgtag, ZType bgkey);   void clear_status();
  void walk(RenderMode rm, uint32_t list_addr, int left, int top);      // RenderObjectList
  bool list_has_prim(uint32_t list_addr);  void set_opinpt(bool);
  void pt_begin(int chunk_size); void pt_chunk_start(int chunk); void pt_pass_start(int pass); int pt_chunks();
  void pt_initial(); void pt_next_chunk(); void pt_final();
  void save_depth(); void restore_depth(); void peel(ZType k);
  bool more(); void clear_more();
  // SHADE
  int  span_gen(RenderMode rm, Span* out);                 int span_sort(const Span*, int n, uint16_t* order);
  void render_param_tags(RenderMode rm, int left, int top);
  uint32_t tile_pixels_shaded();
  // state taps (depths as StoredDepth: the RTL compares .k; tags as all 32 bits)
  IspPix   isp_pixel(int idx);         // depthA/B/C, tagA/B, stencil, valid, rendered, opTag, refTagC, resPass, resTag, resDepth, everRendered, savedDepth
  uint32_t color(int buffer, int idx); Color offs_kept(); bool alpha_stuck();
  // TSP pieces (non-static already, or wrapped)
  const FpuEntry& fpu_entry(int left, int top, RenderMode rm, uint32_t tag);   // GetFpuEntry
  bool pixel_flush_tsp(bool atest, const FpuEntry&, PixPos, int idx, const Fp& invW, bool inVol, uint32_t tag);
  Color texture_filter(TSP, TCW, const Fp& u, const Fp& v, int level);         // through the dispatch tables
  Color combiner(...); Color bump(Color t, Color o); Color fog(...); bool blend(...);
  void next_tile_buffers();
}
```

**The glue self-test** (`make refglue-selftest`, M5) proves that the glue is refsw3:
- `tb/ref/phase_driver.cpp` walks a render through the p2ref calls, in RenderCORE's order.
- It runs the write-out through the `put` / scaler copies in `ref_copies.h`.
- Its video memory after each render must equal refsw3-offline's on the frames subset, every word. Every tile-level
  testbench below relies on this.

### 1.2 Unit testbenches (conv §7.2)

- `tb/<unit>/<unit>_tb_top.sv` is a flat-port wrapper.
- `tb/<unit>/<unit>_tb.cpp` drives one clock at a time and compares every valid output with the reference fed the
  same input, at the unit's declared latency.
- Sections, in this order:
  1. **Directed console facts.** The cases the pinning tests measured, with the console's values as literals,
     independent of refsw3.
  2. **Archived console sets**, read in place from dreamcast-tests by C++ readers (`tools/gate/npz.h`: zlib + the
     `.npy` header; the `.cases.json` with a small JSON reader). Counts are enumerated at gate time and written to
     the summary; the numbers below are those at `b54c934`:

     | set | count | used by |
     |---|---|---|
     | `fit/covmeas_data/*.npz` + `.cases.json` | **115** (96 of them also as `.cov`; 19 only as npz / json, e.g. clattice34modvol, clean34modvol, csliver35zprobe, the `*32strip`, `*33sprite`, caxis31) | M2 (coverage), M3 (the `zprobe` sets) |
     | `fit/zmeas_data/*` | 13 | M3 |
     | `fit/uvmeas_data/*` | 36 | M10 |
     | `fit/mipmeas_data/*` | 10 | M9 (K), M10 (level) |
     | `fit/mipk_data/*.observed.txt` | 4 | M9 |
     | `fit/wmeas_data`, `cmeas_data`, `uvspan_data`, `uvrun_data` | 4, 3, 4, 1 | M10 |
  3. **Random and edge vectors against the reference.** The vector classes of num §7.2.
  4. **A random stream with random gaps and back-pressure.** No value may change.
- Values are compared as tuples: `neg`, `bad`, `mant`, and `exp` when `mant != 0` (num §1.3). Never as `double`.
  Depths are compared as the 64-bit key.
- The arguments every unit testbench takes: `--seed`, `--n`, `--shard`, `--only`, `--vec`, `--set`, `--trace`.
- **Triangles from console pages.** Many edge and depth tests (faredge_*, hugepos_*, depthgaps_*, zovf_*, nantr_*,
  perpmean_*, zword) are whole pages. `tools/gate/tria_extract.sh <test>` runs refsw3-offline with its render log on
  the test's PC stream. It turns every `TRIA` line (the corners exactly, `%a`) with its `TILE` into a unit vector
  file, `build/vec/<test>.tri`, so M2 / M3 test the edge and depth units on exactly the console's primitives. The
  comparison with the console's pictures happens at frame level (M13).

### 1.3 Tile-level lockstep testbenches (M5-M11)

These sit between unit and frame. They are the main bring-up tool for the ISP and the TSP.

**Inputs.**
- **Pre-render captures.** `tools/gate/capture_prerender.sh <case>` writes `build/pre/<case>/r<k>/{vram.bin,
  pvr_regs.bin}` for each render k. Sources:
  - a dreamcast-tests page: its PC stream, with `save` inserted *before* each render trigger;
  - a polly2-data dump: `pvrdmp <file>; save <dir>`, or for legacy dumps `regs ...; vram ...; save`.
- **Generated scenes.** `tb/gen/scenegen.cpp` is C++ on the refcore headers. It writes region arrays, object lists and
  parameter blocks straight into `emu_vram`, with seeded mixes of:
  - strips with masks, triangle and quad arrays, links;
  - modifier volumes (inside, outside, chains, **culled and bad-corner closing triangles**);
  - PT lists at chunk sizes **0, 1, 2**, 0x20-0x40 and 0x3FF, with culled primitives;
  - **the same parameter block in the OP and the PT list, and ISP_BACKGND_T pointing at a PT block** (PT_MV runs
    with mixed `rendered`);
  - **ISP_BACKGND_T with bits 31:29 set, and 0xFFFFFFFF**;
  - pre-sorted and autosorted translucent lists with ties, and autosort lists longer than the translucent cache;
  - keep-Z chains, no-writeout entries, empty keep-Z entries spaced far apart;
  - edge-case corners: ±0, denormals, 2^127, ±inf, NaN, slivers, points, far corners (steps of 2^123 and more, first
    row 28..31, 32·sx near 2^131 and 2^132: the gen3 class of agents/nulldc3/hunt/faredge).
- **Subsets** (conv §7.8), in `tb/tile/subset_*.txt`: about 30 dumps across games and features, one or two pages per
  dreamcast-tests class, and 200 scenegen seeds. The full set is every dump, every page, and 5000 seeds.

**Liveness masks** (`tb/common/isp_live.h`). A field of `IspPix` is compared only where refsw3's value is live, so
the RTL's storage sharing and its per-phase rules are not reported as differences:

| field | live |
|---|---|
| depthA, tagA, stencil, valid | always |
| depthB, tagB | PT phases (PT_INIT to PT_FINAL) and TR autosort (from the first PEEL) |
| depthC, refTagC, opTag, everRendered, `resPass` (as `rcur` / `rlp`) | PT phases |
| rendered | from PT_INIT to the entry's end |
| resTag, resDepth | PT phases, pixels with `rendered` only |
| savedDepth | TR autosort, from SAVE to RESTORE |

**ISP tile testbench** (`tb/isp_tile`, M6-M7). The DUT is the ISP. It has two modes.
- **Phase-halt mode.** `p2_isp_ctl` has a simulation-only phase halt: it stops at each phase boundary and the
  testbench resumes it. The testbench walks the region array itself and feeds entries.
  - For every entry it runs the p2ref phase on the reference, then lets the RTL run the same phase. At every phase
    boundary it compares the live fields of all 1024 pixels through the debug read port.
  - SHADE passes: the RTL's cut runs must equal `p2ref::span_gen(rm)` run for run, including `vmask` and `pmask`
    (from the state), `rm`, the epoch, `eop` and `eoe`.
  - PT feedback: the testbench calls `p2ref::render_param_tags(PT)`, derives each pixel's outcome (run-only / fail /
    pass) from the reference state before and after, and feeds `p2_fb_t` messages to the RTL in the RTL's run order,
    then PASS_DONE.
  - `shaded_any` must equal `tile_pixels_shaded() != 0`.
- **Free-running mode** (no halt). Entries run back to back, as in `p2_core`. The testbench pops the run stream with
  random back-pressure (stall probability and burst length per seed), and answers PT passes from the reference
  outcomes after a random delay. Compared:
  - every run item in order, against the reference's `span_gen` of the same pass. The cutter reads each row only once,
    and a barrier error makes it read a row the next epoch has overwritten, so a barrier bug shows here;
  - the entry records in `p2_entq`;
  - the live fields of all pixels at the render's end.

  This is the mode that exercises the row barrier, the cutter running beside the next epoch's raster and sweeps, and
  pcache's replays.

**TSP tile testbench** (`tb/tsp_tile`, M9-M11).
- The DUT is the TSP side: store, pfetch, setup, ALU, run start, pixel queue, pixel pipe, texture, and the tile
  buffers. The write-out is excluded.
- For each SHADE pass of each entry the testbench takes the reference's runs, `span_gen` + `span_sort`, converted to
  `p2_rs_t` with flags. It feeds them to the RTL.
- The reference shades the same pass pixel by pixel through the verbatim copy of `RenderParamTags`'s loop, which
  calls `p2ref::pixel_flush_tsp` (`ref_copies.h`, drift-checked).
- Compared:
  - every tile-buffer word after every pass (debug mode: after every pixel, the word at `idx`);
  - the PT outcome per pixel;
  - `offsKept` and `alpha_stuck` at each pass end.

### 1.4 Frame testbench: `p2-offline` (conv §7.4)

- refsw3-offline's sources, minus `refsw_lists.cpp` and `refsw_tile.cpp`, plus `tb/frame/p2_rendercore.cpp` and the
  Verilated `p2_core`.
- One persistent core per process: tile buffers and `offsKept` carry across renders.
- The VRAM model serves the core from `emu_vram` (§1.6).
- Timing line on stderr: `p2: render <n> isp <clk> tsp <clk> video <clk> vramrace <words>`.
- Hung render: `p2: render <n> did not end` after `P2_CLK_LIMIT`.
- dreamcast-tests' scripts run unchanged:
  `NULLDC3=<polly2-rtl>/tools OFFLINE_TOOL=p2-offline OFFLINE=<polly2-rtl>/build/p2-offline PVR_TESTS=<polly2-rtl>/build/pvr_tests`
  (conv §7.4.1).
- **Dual mode** (`make p2-offline-dual`) also links the L2 glue. It renders on a copy with `RenderCORE_sw` first, and
  reports the first differing word with its tile and pixel.
- **refsw3-known, computed** (`tools/gate/refsw3_known.sh`, run when the recorded nulldc3 revision changes). It runs
  refsw3-offline at the recorded revision over every console archive the hw gate reads, with `compare2.py <test> ref
  off`, `archive_check.sh` and the frame comparisons. The result is `build/gate/refsw3_known.txt`: per test, page and
  region, where refsw3 differs from the console, stamped with the revision. The hw gate refuses a stale file.
  (faredge was 1,330 / 1,340 before `6784ea3d` and is exact now; a hand-kept list would have been wrong the same
  day.)
- **Comparisons.**

  | gate | how |
  |---|---|
  | `gate_frames_off.sh` | `save` after every render; all 8 MB of video memory, word by word, against refsw3-offline (conv §7.4.2); VRAM-race renders reported separately |
  | `gate_frames_hw.sh` | `compare2.py <test> ref off`, `archive_check.sh`, `framepng.py raw` against `<scene>.hw.png`, `vram_out_<scene>.bin`, and `fit/zdump_data` through a depth tap (the key converted to refsw3's `bits` by `tb/common/zkey.h`) (conv §7.4.3). **Every directory of `fit/hw` is enumerated at gate time** (219 at `b54c934`, `*_races` excluded) |
  | `tools/gate/rendlog_diff.py` | aligns `+rendlog` against refcore's `log` on TILE / PASS / SPAN / PIXELS (conv §7.4.4) |

### 1.5 Cycle testbench (MT0-MT9)

- **The timing gate** (conv §7.6.2), for a timed scene:
  `0 <= console_least_counts / 2 - (rtl_tsp + K) <= 14`.
  - `K` is fitted **once**, on the empty one-tile scene (2695 clk at 16 bpp, 3005 at 0888), and recorded in
    `docs/timing.md`.
  - Slopes (N = 64..256 objects) within 0.1 clk an object. Single differences within 5 clk.
- **Timed scenes.** The timemeas scenes exist only in the console build (GAP conv G2). Option (a): ask the
  dreamcast-tests owner for a PC emission (D7). Option (b), the fallback: `tools/timing/tm_emit.cpp`, our own emitter
  against `common/pvrtest2.h`, kept small and checked scene by scene against `pvr-tests/timemeas/main.c`.
- **Timed register writes** (conv G11), for TM_ORDER (the palette clock). `P2_TIMED_WRITES=<file>` holds
  clock / register / value lines, which p2-offline applies while it clocks the render.
- **Races: two lists, kept apart.**
  - `tb/timing/races_variable.txt`: cells that vary **from run to run** on the console, built by
    `tools/timing/races_var.py` from multi-run logs (`fit/accbuf_logs` runs 1-6, and the multi-run logs requested in
    §4). These cells are never compared.
  - `tb/timing/races_expected.txt`: **deterministic** cells the RTL is expected to miss **because a mechanism is not
    yet fitted**, each line keyed by its probe, e.g. `T12 ptchunkcarry_races page* kind k=0..5 all`,
    `T12 ptchunkcarry_races kind k=6,7 first-row and after-empty cells`, `T11 accbuf_races ...`. `docs/probes.txt`
    records each probe's status. The gate fails if a probe is marked landed and its lines are still there, or if a
    listed cell starts to pass (the list is stale).
  - Every other cell of a `*_races` test must equal the console page (`compare2.py <test>_races ref off`).
- **The blendpos statistic** (MT8, scriptable). For every tile of `fit/hw/blendpos_races` that the console damaged,
  `d_t` = the first pixel (row-major index 0..1023) that differs from refsw3's picture. That gives the console sample
  C (one archived run; more runs if §4's request is met). The RTL sample R is the same over three runs with
  `+vramvary` seeds 1, 2, 3. PASS iff:
  - the median of R is within 64 px of the median of C;
  - every `d_t` of R lies in `[min C - 64, max C + 64]`;
  - the fraction of damaged tiles in R is within 10 points of C's.
- **`+occlog`** per-unit occupancy traces (conv §7.5) localize a timing mismatch.
- **`model/timing`** (optional, MT0): a C++ clocked model of ARCHITECTURE §5, validated against REPORT.md. It is a
  debugging reference for `gate_cycle.sh` and never decides an RTL mechanism (conv §4.7).

### 1.6 The VRAM model (ARCHITECTURE §3.2.1)

- Two halves, latency `VR_LAT`, row cost `VR_ROW`, optional refresh and display stalls.
- Requests take effect at grant: writes commit, reads sample.
- **The hazard detector** marks a render VRAM-race when a word written by C5 is also read by C0-C4 in the same
  render. The `p2:` line reports it. Every gate puts such renders in their own class.
- `+vramvary=<seed>` (random latency) is run on every functional gate. It must give identical values on every render
  not marked VRAM-race; only the clocks may differ.
- `VR_LAT` sweeps (1, 4, 8, 16) on the frames subset from M12 on, with the same rule.

## 2. Milestones

| id | title | depends | gate (quick) |
|---|---|---|---|
| M0 | scaffolding | — | `make scaffold` |
| M1 | numerics primitives (M1a / M1b / M1c) | M0 | `make fp` |
| M2 | ISP edge path (with the swamp and the big-edge walk) | M1 | `make isp-edge` |
| M3 | ISP depth path (`708fb8cd`) | M1 | `make isp-depth` |
| M4 | ISP setup sequencer (generated programs) and row stepper | M2, M3 | `make isp-setup` |
| M5 | tile-harness infrastructure (glue, copies, captures, scenegen, refsw3-known) | M0 | `make refglue-selftest` |
| M6 | ISP tile: list walk, fetch, opaque, modifier volumes | M4, M5 | `make isp-tile-op` |
| M7 | ISP tile: OpInPt, punch-through, translucent, cutter, primitive cache | M6 | `make isp-tile` |
| M8 | run queue and span sorter | M7 | `make sort` |
| M9 | TSP fetch, set-up store, plane setup, mip K | M1, M5 | `make tsp-setup` |
| M10 | run start and pixel values (planes, divide, colour, mip level) | M9 | `make tsp-run` |
| M11 | pixel pipe: texture, shading, fog, SupSample, blend | M10 | `make tsp-tile` |
| M12 | tile buffers, write-out, sequencer, `p2_core`, `p2-offline`; frames subset | M7, M8, M11 | `make frames` |
| M13 | all frames, console archives | M12 | `make frames-hw` |
| MT0 | timing harness | M12 | `make timing-harness` |
| MT1 | ISP timing | MT0 | `make timing T=isp` |
| MT2 | cutter, run queue, ISP lead | MT1 | `make timing T=ispq` |
| MT3 | sorter order | MT2 | `make timing T=order` |
| MT4 | TSP setup and store | MT2 | `make timing T=setup` |
| MT5 | run start, shared ALU, pixel queue | MT4 | `make timing T=span` |
| MT6 | pixel pipe and texture | MT5 | `make timing T=pixel` |
| MT7 | tile buffers, write-out, tile overlap | MT6 | `make timing T=tile` |
| MT8 | races | MT7 | `make timing T=races` |
| MT9 | whole frames and hangs | MT8 | `make timing-full` |
| MQ | synthesis testing projects (after M12, beside the timing work) | M12 | `make quartus-lint` |

### M0. Scaffolding

**Deliverables.**
- The top `Makefile` with `tb/mk/*.mk` fragments, path variables (conv §2) and VFLAGS (conv §6.1).
- `tools/gen/gen_hw_pkg.cpp`: C++ on the refcore `*HW` structs, printing `rtl/v1/pkg/p2_hw_pkg.sv`, including
  EdgeHW `blockMax` and `walkExp`.
  - Also: elaboration checks that fail if a mode switch (`range`, `startOnSlopes`, `macOrder`, ...) leaves its
    hardware value.
- `tools/gen/gen_regs.py`, giving `p2_regs_pkg.sv` (from polly2-rtl-lite's `gen_pvr_regs.py`, reuse §4.2).
- `p2_pkg.sv` with the types of ARCHITECTURE §2 (32-bit tags, `p2_zkey_t`, `p2_rs_t` with flags).
- `p2_zword_pkg.sv` with its function signatures only.
- `tb/common/p2tb.h` (`Fails`, arguments, shards), `tb/common/zkey.h` (key to refsw3 `bits`).
- `tools/check_ref_copies.sh`, `tools/check_ref_switches.sh`.
- `make lint` on an empty `p2_core` shell.

**Gate.** `make scaffold` runs:
- `hw-pkg-check` (regenerate and `cmp`);
- `regs-pkg-check`;
- `lint` (`-Wall`, 0 warnings);
- `check_ref_copies` (an empty list is fine), `check_ref_switches`.

It prints `scaffold: PASS`.

**Mutants.** None. M0 holds no mechanism.

### M1. Numerics primitives

The whole of num §6 and §7, in three rounds, with H7a and H14 taken from refsw3 `708fb8cd` (ARCHITECTURE §0.1,
§3.11). RTL is in `rtl/v1/lib/fp/`, one module per primitive (num §7.1), tested against L1 and verbatim copies.

| round | primitives | gate |
|---|---|---|
| M1a | H1 lzc, H2 cut, H3 cut_below, H4 inputs, H5 mul, H6 add (24/25, 24/53), H8 recip24, H9 cmp, H10 range wrappers (edge, **depth at `708fb8cd`** with the zero rule and the per-operation limits, TSP, mip) | `make fp-a` |
| M1b | **H7a `fp_swamp`**, H7b tsp_half_line, H7c mip_minor_sub, H11 floors, H12a value norm, H12b depth block, **H14 `p2_zword_pkg`**: `key32`, `bits`, `between`, `from_fp`, `big`, `neg`, `flat`, `saturated`, `regdepth`, `bgkey` | `make fp-b` |
| M1c | H13 divider (ROM generated from the header string and the formula by `tools/gen/gen_recip_rom.cpp`), H15 colour round; ROMs: SIN / COS (tsp App. B), dither | `make fp-c` |

**Gate.**
- `make fp`: every primitive in quick mode, 0 mismatches, under 60 s in total.
- `make fp-full` once per round: the exhaustive sweeps of num §7.3, and for the new pieces:
  - `key32` and `bgkey` over all 2^32 words;
  - `regdepth` over all 2^30 register values;
  - `neg(E, M)` over E in -122..128 and M in [-2^23, 0);
  - `from_fp` / `big` on every 19-bit mantissa at every exponent;
  - recip over 2^23 x 3 x 2; `recip_mant` over all 32768; `from_bits` / `from_single` over 2^32.
- Every reference `exp` must be asserted to fit 10 bits (G11). Every unreachable clamp is asserted never to act (A4).
- The representation contract (num §1.3) is checked on every output tuple.

**Mutants (at least one a case class).**

| primitive | mutants |
|---|---|
| H6 | reach 25 to 24; drop with borrow; cancellation to -0; both-zero sign OR |
| H7a | swamp at `>= 2^127`; the swamp value finite (2^128, so it no longer drops a finite operand); saturation to 2^128 |
| H7b | the 62-bit truncation off |
| H8 | a rounding reciprocal |
| H10 depth | the zero rule off; the zero rule at 1.5 x 2^-126 inclusive; a zero sum keeping -0 |
| H12a | the -128 floor off; truncation toward zero |
| H13 | one `c` digit flipped; the 17-bit floor to 16 |
| H14 | `neg` rounding toward zero instead of down; the window's bottom with a carry (no 0x7fffe0); `between` offsets swapped above / below the window; `big` as `saturated`; `regdepth` without the wrap; `bgkey`'s E floor of 6 removed |
| H15 | half-up to truncate |

### M2. ISP edge path

**Deliverables.** The edge datapath of `p2_isp_setup` as a fixed-latency unit (the sequencer comes in M4), at refsw3
`6784ea3d` semantics:
- bad corners; the swamped determinant (`EdgeWinding`); CulledBySize / CulledByFacing on it;
- per edge per tile `c`, `dx`, `dy`, `dxP`, `dyP`, `first`, `start` with the swamp and the 2^127 saturation, `s20`,
  `sx`, `sy`, `ep`, `es`, E with the cap at 129, `unit`, `d`; blocking to `p2_edge_t` with the big-edge walk fields;
- RowRange with the row-31 shift;
- the 32-lane, 40-bit edge evaluator of `p2_isp_raster` with the per-edge row stage and the walk (inside mask per
  row).

**Gate** `make isp-edge`.
1. **Directed facts**: the covmeas rules; hugepos (2^118..2^124 pixel counts); the faredge_* and hugepos_* rules as
   edge.h cites them (cmax's 2^128 products, k132's cancelling RV tiles, m131's -2^131 not pushed and +2^131 pushed,
   ecap's cap at 129, walk's row-31 shift).
2. **All 115 covmeas sets**: per-pixel coverage equal to the console's record.
3. **The console pages' own triangles** (§1.2 `tria_extract`): every primitive of `fit/hw/faredge*` and
   `fit/hw/hugepos*` (8 + 19 tests), per tile, against the copied setup and `EdgeTile::Inside`. 0 differences from
   refsw3; refsw3's own console residuals (hugepos_rules, hugepos_v5) are refsw3-known at M13, computed.
4. **Random**: 2M edges quick, 400M full, against the copies and edge.h. Classes: pixel-grid corners, ulp-perturbed,
   huge, denormal, slivers, points, both windings, both HALF_OFFSET values, and **the far class**: steps of 2^123 and
   more, first row 28..31, `32 sx` within a few units of 2^131 and 2^132, both signs, products at exactly 2^128.
5. **The width claims**, asserted: the `d >= 30` constant rule; the 31-bit ordinary accumulator; the 40-bit lanes;
   the walk's 36-bit row accumulator and `|f0| < 2^32 + 1`, `|fx|, |fy| < 2^28`. Any value outside fails.

**Mutants.**
- zeroShift 21 to 20 or 22; the tie threshold;
- the next-pixel tie rule to self;
- column 31 by the pixel's own sign;
- the row-zero rule off;
- reach 25 to 24;
- `d >= 30` to `d >= 31`;
- the row range without `+1/2`;
- cull equal not culled;
- **the plain determinant in the cull**; the plain determinant for the edge sign;
- the swamp off in the start's products (the old saturation after the sum);
- blockMax 129 to 130;
- **no wrap**; **no push**; **32·sx kept whole** (no `mod 2^131`); **0 counted as above**; **the walk counted from
  row 0** (not `jf`); **no row-31 shift**; the row-31 shift without a big edge;
- dx / dy at 2^128 stepping as the swamp value instead of 2^127.

### M3. ISP depth path

**Deliverables.** The depth datapath at refsw3 `708fb8cd`:
- ranged plane setup (`a`, `b`, `c`, `det`, Perpendicular) with the depth flavour of H10;
- per tile: `inv0`, `first0`, the regimes CONST / REG / BLOCK (ARCHITECTURE §2.4), the forced start, the mean with
  the infinite-corner rule, `under()`, `pair`, `gexp`, `E`, `S`, `DX`, `DY`, `nsh`;
- the 32 depth lanes of `p2_isp_raster`: the 30-bit `t`, `from_fp` / `big` / `neg`, REG `regdepth`.

**Gate** `make isp-depth`.
1. **Directed**: zword's 32 register words and depthgaps_mm's order; nantr_* starts; zovf_* (lim, c, ps, creg, wrap,
   ab, sum, far, slope, sat*, neg*); depthgaps_* (zadd, field1, negconv, neggrid, bigpos, bigord, bigslope, bigpair,
   dzinf, detneg, rstart, rcut, infstart, edges, tinyramp, flt); perpmean_word (16,384 words) and perpmean_neg*;
   the literals as depth.h cites them.
2. **All 13 zmeas sets** (89,801 brackets, 0 missed) and the covmeas `zprobe` sets.
3. **The console pages' own triangles** (§1.2 `tria_extract`) of every depthgaps_*, zovf_*, nantr_*, perpmean_*,
   zword, zbad*, zspec, zsign, bg* test: every pixel's key against `DepthTileT::At` and `StoredDepth`.
4. **Random**: 1M planes quick, 100M full, against `DepthTileT::Setup` / `At` and `StoredDepth`, every regime
   represented, with the classes of depthgaps (negative starts, starts of exactly 0, slopes 2^50 and more times the
   start, products at 2^128, operands near 2^-126).
5. **Assertions on every pixel**: `|t| < 2^29`; refsw3 never takes the float form (`block == false` with a valid
   plane); A2: the RTL's exact value equals refsw3's 64-bit truncation; the key round-trips through `zkey.h`.

**Mutants.**
- tileBits 26 to 25;
- startOnSlopes off;
- pairBits 21 to 20;
- `OneThird` as 0xAAAAAA;
- the `h = -1` corner step off;
- the ranged and unranged chains swapped at `first`;
- E not clamped at 128; E not clamped at -122;
- the forced start not stepped (revision 1's ovf 1: 0 at the first pixel, a word elsewhere);
- REG without the finite slope's steps (`fa = fb = 0`);
- REG's negative start rounded down instead of toward zero; `r0` without the cut to 20 bits;
- the mean's infinite corners as z1's word (revision 1).

### M4. ISP setup sequencer and row stepper

**Deliverables.**
- `tools/gen/gen_setup_prog.cpp`: the operation graphs (TRI, QUAD, MODIFIER TRI), the graph check, the list scheduler,
  the generated microprogram package (ARCHITECTURE §3.4.4).
- `p2_isp_setup` as the microprogrammed unit on `p2_isp_alu`, the 1-deep hand-off, `kill` descriptors.
- `p2_isp_raster` stepping rows `jf..jl` (0..31 for MODIFIER and `kill`) one a clock.
- Input is the `asm` stream; output is per-row `(in_mask, zk[32])`.

**Gate** `make isp-setup`.
1. **The graph check**: each graph, evaluated with pvr_softfp, equals the M2 / M3 references on 1M random and all
   directed primitives.
2. **Function**: every `p2_rdesc_t` field, and every row's mask and keys, equal to the composition of the M2 / M3
   references, on 500k random primitives quick (5M full), in random tiles.
3. **Program consistency**: the RTL's issue trace equals the generated schedule, op for op.
4. **Cycle, unit level** [M tim §3.2]:
   - with the parameters in ARCHITECTURE §6, the scheduler gives TRI 16 and QUAD 19; a culled or bad primitive
     skips the hand-off (15);
   - back-to-back primitives cost `max(len, rows)` each, by the testbench's clock counter;
   - MODIFIER triangles and `kill` descriptors cost 32.

   The strip alternation (19 / 15) is GAP T2: reported, not gated.

**Mutants.**
- hand-off depth 2;
- a culled triangle handed over;
- a culled closing triangle **not** handed over;
- the row counter from 0 instead of `jf`;
- a MODIFIER triangle given the row range;
- the shared product used for the depth unit (ranged) path;
- one graph edge removed (the graph check must fail).

### M5. Tile-harness infrastructure

**Deliverables.**
- `tb/ref/refcore_glue.cpp`, `refcore_env.cpp`, the p2ref API (§1.1).
- `tb/ref/phase_driver.cpp`.
- `ref_copies.h` with every copy of §1.1's table.
- `tools/gate/capture_prerender.sh`, `tools/gate/tria_extract.sh`, `tools/gate/refsw3_known.sh`.
- `tb/gen/scenegen.cpp` with the classes of §1.3.
- `tb/tile/subset_*.txt`, `tb/common/isp_live.h`.

This closes conv G10 (the glue compiled for the first time).

**Gate** `make refglue-selftest`:
- the phase driver's video memory equals refsw3-offline's `save` after every render, on the frames subset, every
  word;
- scenegen's 200 seeds render through both without a mismatch;
- `check_ref_copies` and `check_ref_switches` are clean;
- `refsw3_known.sh` reproduces the dreamcast-tests README's per-test scores at the recorded revision (faredge
  1,340 / 1,340; hugepos_rules 3,590 / 3,600; hugepos_v5 2,399 / 2,400).

**Mutants.** Phase-driver order swaps (OP_MOD before OP; PT final before PT_MOD) must be caught by the self-test.

### M6. ISP tile: list walk, fetch, opaque, modifier volumes

**Deliverables.**
- `p2_isp_olw`, `p2_isp_pfetch`, `p2_isp_buf` (storage and ports of ARCHITECTURE §3.4.7), `p2_isp_pix` (OPAQUE,
  MODIFIER rules, the folded summary).
- `p2_isp_ctl` phases Z (CLEAR / CLRSTATUS, `bgkey`), OP, OP_MOD.
- `p2_mem` clients C1 and C2, with the VRAM model.

**Gate** `make isp-tile-op` (§1.3, phase-halt mode):
- After Z, OP and OP_MOD of every entry of the tile subset: depthA, tagA, stencil and valid of all 1024 pixels equal
  the reference.
- Also run with `+vramvary`.
- Inputs: the subset dumps, pages from covmeas, depth, modvol, volrun, keepz, bgspec / bgneg, depthgaps_bg*, huge,
  zovf / nantr, and scenegen (including culled and bad closers, and the 32-bit background tags).

**Mutants.**
- the odd-strip swap off;
- `twoVol` ignoring intensity;
- `PARAM_BASE` unmasked on the ISP side;
- link `end_of_list` ignored;
- DepthMode 3 as 1;
- modvol `>=`;
- SUMMARY OR / AND swapped;
- the summary applied to untouched pixels;
- **the summary only for rasterized closers** (A2);
- the summary applied before the closer's own parity update;
- the row-bypass off (a fragment-order error on back-to-back same-row primitives: scenegen has a class for it);
- tags compared on 29 bits;
- TAG_BELOW kept as a separate flag (a 0xFFFFFFFF background tag then ties differently).

### M7. ISP tile: OpInPt, punch-through, translucent, cutter, primitive cache

**Deliverables.**
- `p2_isp_ctl` complete (with `p2_isp_ctl_tg` as a pass-through, `P2_PTCARRY = 0`).
- `p2_isp_ptc` (signed threshold), `p2_isp_pcache`.
- `p2_isp_pix` PT / PRESORT / AUTOSORT rules.
- `p2_isp_buf` sweeps (PT_INIT, PT_CHUNK, PASS_START, PT_FINAL, PEEL, SAVE, RESTORE) and the row barrier.
- `p2_isp_fb`.
- `p2_isp_cut` (runs, `vmask`, `pmask`, epoch, flags, `null` items, entry records, side effects, `shaded_any`).

**Gate** `make isp-tile`, per §1.3:
1. Phase-halt mode: the live ISP state at every phase boundary; every SHADE's runs against `span_gen`, with `vmask`,
   `pmask`, epoch and flags; `shaded_any`; the PT pass and chunk counts against the reference's.
2. **Free-running mode**: the run stream, the entry records and the final state, under random back-pressure, on
   the tile subset and 200 scenegen seeds (quick), 5000 (full).
3. Inputs add ptchunk, ptchunkq, ptchunkm, ptchunkcost, ptchunklag, ptlayers, ptruns, optrun, optcull, uvrun, trtie,
   sort, keepz, ispcache, dumprules pages, the dumps with PT and translucent lists (shenmue_intro*, jgr_*, f1wgp_*,
   thps2_*), scenegen with chunk sizes **0, 1, 2** and 0x3FF, and PT_MV runs with mixed `rendered`.

**Mutants.**
- the quad lag off;
- the culled lag off;
- `chunk size - 2` to `- 1`;
- **the threshold compared unsigned** (fails on chunk sizes 0 and 1);
- `rlp` never cleared (a pixel resolved in pass p also in p+2);
- PT_FINAL taking depthC for resolved pixels;
- AUTOSORT `more` not set on a displaced best;
- `savedDepth` not written;
- OpInPt from "draws" instead of "holds";
- the run break on volume edges in PRESORT;
- `pmask` off in PT passes; **`pmask` as one bit per run in PT_MV** (revision 1's `rflag`);
- **the row barrier off** (fails in free-running mode);
- the barrier per tile instead of per row (must still pass the function: it is a timing choice. The mutant checks
  that the testbench sees no difference, so that T4 alone can decide it);
- pcache replaying in reverse order; pcache not resetting at the next chunk; a TR replay after an overflow (instead
  of a walk) that drops the overflowed primitives.

### M8. Run queue and span sorter

**Deliverables.** `p2_runq`, `p2_sort` (epoch key, emit condition, flag re-attachment, bypass), `p2_entq`.

**Gate** `make sort`:
- The sorter's output order equals `span_sort` **per pass**, on:
  - every entry of the tile subset (M7's captured run streams, passes back to back with no barrier);
  - 100k random run streams (random tag pools sized 1..200, runs per row 1..32, 1..20 passes per stream, empty
    passes, `null` items);
  - with SPAN_SORT_CFG 0x101, 0x001 and 0x000.
- With random back-pressure on both sides, and a slow-cutter class (the input starves the window).
- `eop` / `eoe` on exactly the last item of each pass and entry to leave; no item of pass e+1 before the last of
  pass e.

**Mutants.**
- window 95 and 97 (both must fail on the subset; tim §3.6 shows 129-276 runs out of order);
- a circular FIFO instead of compaction;
- the youngest-first drain;
- the key without `& ~7` under bit 8;
- **the epoch left out of the key** (passes mix);
- **emitting without the emit condition** (fails in the slow-cutter class);
- `eop` left on the item that came in last.

### M9. TSP fetch, set-up store, plane setup, mip K

**Deliverables.**
- `p2_tsp_pfetch` (C3).
- `p2_tsp_setup`: planes for `(tag, vsel)`, the mean, intensity, dropped offset planes (the branch table of
  ARCHITECTURE §3.7.3), mip K; the generated programs.
- `p2_tsp_alu`.
- `p2_tsp_store` (keys on 32-bit tags, look-ahead, pins).

**Gate** `make tsp-setup`:
1. The graph check for every TSP class (as M4).
2. Every store entry field against `p2ref::fpu_entry` (IPs3 planes of the selected volume: the `soft` A, B, C,
   fallbacks, words). K8 against the copy of MipSelect's K part.
3. Directed: slivers_detzero, slivers_dzzero (the `withZero` rule), perpmean_uv, perpmean_ovf, modvol intensity
   (0x80 halves, 0xFF one level).
4. **The dropped-offset class** (A3): all-zero offsets x {det 0, perpendicular, det infinite, `|det| > 2^126`,
   ordinary} x {1/w terms of every sign, zero, infinite} x {Gouraud, flat} x {intensity off, on, with non-zero
   colours that scale to 0}. Every coefficient's sign equals refsw3's, and the RTL's no-multiply path equals the
   full computation.
5. **Console K sets**: `fit/mipk_data` (4) and `fit/mipmeas_data` (10), the K-dependent readings.
6. Random 1M primitives quick: every input class, flat and Gouraud, two volumes, intensity, DCalcCtrl 0 / 1.
7. Mipmapped primitives with `Sdet == 0` are counted and skipped until D4 is decided.

**Mutants.**
- the 1/w constant sum order `(t0 + t1) + t2`;
- the attribute product `(a_i w_i) d`;
- zeroReach 2 to 3 (this must fail on cmeas cwsum1-style vectors);
- 0x95F612 changed by one;
- bias 0 not read as 4;
- dropped offset planes stored as +0;
- **the flat branch's C sign from the AND rule** (instead of the mean's sign);
- the drop predicate on the sent colours instead of the scaled ones.

### M10. Run start and pixel values

**Deliverables.**
- `p2_tsp_rstart` (`seen`, grid, the base / step / `hyd` integers).
- `p2_pxq` (run entries and pixel credits).
- `p2_pp_issue` (`pmask` decode), `p2_pp_plane`, `p2_pp_div`, `p2_pp_col`, `p2_pp_mip`.

**Gate** `make tsp-run`:
- Per pixel: W, every attribute value, quotient, colour, level and `k` against `PlaneT::Value`, `Divide`,
  `ColorRounded`, `MipSelect` (L1) and the `mipChoose` copy. On:
  - random runs (2M pixels quick);
  - all 36 uvmeas sets and the wmeas, cmeas, uvspan and uvrun sets: every reading equal to the console's (23.6M
    uvmeas readings in the full run);
  - the 10 mipmeas sets: every level reading;
  - SupSample points (supsample-style vectors, H7b classes).

**Mutants.**
- gridBits 22 to 21;
- F(-0) = 0;
- a fixed-drop normalizer;
- the -1-unit value as 0;
- the negative-denominator rule off;
- 2^-128 for a zero denominator to 2^-127;
- the mip `ww` clamp off;
- SupSample not one level finer;
- mipChoose's pass-B +1 off.

### M11. Pixel pipe: texture, shading, fog, SupSample, blend

**Deliverables.**
- `p2_tex_coord`, `p2_tex_addr`, `p2_tex_cache` (C4; placeholder organisation, ARCHITECTURE §6), `p2_tex_decode`,
  `p2_tex_filter`.
- `p2_pp_shade` (with `offsKept`), `p2_pp_fog`, `p2_pp_ss`, `p2_pp_blend` (stuck alpha, alpha test, blend, forward,
  feedback, the pass drain).
- The tile-buffer RAMs of `p2_tbuf` and the secondary port (not yet the controller).

**Gate** `make tsp-tile` (§1.3):
- Every tile-buffer word after every pass of the tile subset.
- The PT outcomes; `offsKept` and stuck alpha at each pass end.
- Inputs add texfmt, sample, mip, mipbil, texctl*, texfar*, coordfix, yuvbil, bump*, env, alphatest, fog, tspw,
  supsample*, ss*, trimin, trifade, blend, blendsel*, offspersist and the dumps.
- Unit sections for `p2_tex_filter` and `p2_pp_shade` against `p2ref::texture_filter` / `combiner` / `bump` / `fog`
  / `blend` and the `bumpLight`, `shade`, `fade` and SupSample copies, on random inputs.

**Mutants.**
- bilinear as one sum of four;
- YUV paired by memory order;
- the VQ bank XOR after the +2048;
- byte swap applied to index bytes;
- the 1x1 YUV level not as 565;
- the blend 255 not counted as 256;
- stuck alpha never set;
- `offsKept` loaded at setup time instead of at P7;
- the fog index without `+1`;
- fade before fog;
- SupSample sum >> 2;
- the run-only write not suppressed;
- **the P10 forward off** (fails on TR_PRESORT back-to-back same-pixel primitives);
- DstSelect's `dst` read from buffer 1;
- PT_MV alpha-testing every pixel of a run.

### M12. Tile buffers, write-out, sequencer, `p2_core`, `p2-offline`

**Deliverables.**
- The `p2_tbuf` controller: actions on `eoe`, the shared secondary port, the DstSelect interlock, `p2_tbuf_hs`
  (refsw3-equivalent until T11).
- `p2_wout` (line FIFO, scaler, clip, strip buffer, pack, dither, C5).
- `p2_seq`, `p2_regs`, the rest of `p2_mem`.
- `p2_core`, `tb/frame/p2_rendercore.cpp`, `tools/p2-offline/build.sh`, the dual mode.
- The VRAM model's hazard detector.

**Gate.**
- `make wout`: the write-out against the `put` / scaler copies. Random tile streams, every packmode, dither, clip,
  strip sizes, scaler factors 0x400 / 0x401 / 0x800 / 0x6532, Y_COEFF values, hscale, render to texture.
- `make frames` = `gate_frames_off.sh --subset`: every word of video memory after every render equal to
  refsw3-offline's, on `tb/frames/subset_tests.txt` and `subset_dumps.txt`, VRAM-race renders in their own class.
  Also run under `+vramvary` and at `VR_LAT` 1 and 16.

**Mutants.**
- a dither entry changed;
- the scaler row counter at 11 bits;
- the stuck row off;
- strip parity swapped;
- emptyAfterNoWrite writing at its own tile;
- a swap after a no-writeout entry;
- the background not shaded with keep Z off;
- the hazard detector off (a texctl_bank-style scene with a VQ index in the framebuffer must then fail under
  `+vramvary`, which shows that the race class is real).

### M13. All frames, console archives

**Gate.**
- `make frames-hw` (subset), then once at the end:
  - `make frames-full`: every pvrtest2 page and all 786 dumps against refsw3-offline;
  - `make frames-hw-full`: every `fit/hw` test enumerated at gate time (219 at `b54c934`, `*_races` excluded), the
    archived sets, 786 `hw.png`, 63 `vram_out`, `zdump_data` through the depth tap.
- Pass: refsw3-equal everywhere refsw3 is console-equal, by the computed `refsw3_known.txt`; refsw3-known regions
  not worse.
- The `*_races` tests are left to MT8.

**Mutants.** Re-run the M6-M12 mutant lists through `frames` (the subset), to show the frame gate catches them too.

### MT0. Timing harness

**Deliverables.**
- The timed-scene source (D7: the owner's PC emission, or `tm_emit.cpp`).
- The `p2:` timing lines.
- `gate_timing.sh` with the formula of §1.5, and the K fit.
- `races_variable.txt`, `races_expected.txt`, `docs/probes.txt`.
- `P2_TIMED_WRITES`.
- `+occlog` on every unit.
- Optionally `model/timing`.

**Gate** `make timing-harness`:
- `K` fitted on the empty 0888 tile (3005).
- The empty 16-bit tile (2695) and the 888 tile (2755) checked against the same `K` within 0-14. That checks the
  write-out's format dependence (tim §3.1).
- A planted mutant (+1 clk a run in the cutter) must make the gate fail on the `cut` scenes.

### MT1-MT9. Cycle agreement, stage by stage

Each milestone gates the REPORT.md / `tables.txt` numbers of its stage with the §1.5 tolerances. Where a number is
used to fit a parameter, it is listed under "fits" and not gated. Where the mechanism is GAP, the number is
"reported" until its probe returns.

| id | fits (once) | gated | reported until a probe | probes |
|---|---|---|---|---|
| MT1 | `ISP_NM`, `ISP_NA`, `L_*` (checked to give 16 / 19 already at M4); `MV_GAP` on the 2-triangle volume 65 | ISP per object: 16, 15.05-15.1 culled, 19 sprite, 32 sprite 32x32, 34 quad (strip of 2), the quad-by-height table, modifier volume 65 for each further volume once `MV_GAP` is fitted on the first; list pointer 20-31 | strips 16 / 34 / 53 / 68 / 87 / 102 (T2); thin triangles (T2); first objects 72..4010 (T1); FPU_PERP_VAL and big-edge costs (T2) | T2, T1 |
| MT2 | `RUNQ_N`, `PXQ_PIX`, `PXQ_RUNS` on the four ispq points 436 / 443 / 462 / 476 (ARCHITECTURE §3.5) | cut 1 clk a run (cut tables); the ispq rows **not** used in the fit: background 565 (437 runs left, lead 15250), one sprite (435, 19916), 2 and 4 sprite rows (434, 19894 / 19874), each with its pace; the ISP bit of seen polygons (+30, +209, +5104, +23753); spanahead bursts 45-70 runs, 180-290 clk | **the 32x1-rows case** (lead 2882, pace 1736: T3); the cut overlap table (58 of 128, 11 of 256: T4) | T3, T4 |
| MT3 | — | order.py on the 23 TM_ORDER scenes: out-of-order counts 6 / 20 at window 96 (runs 38 / 39) once the early drains are understood | the early drains; sort-off orders (T5) | T5, T1 |
| MT4 | `ALU_NM`, `ALU_NA`, `L_*` (TSP) if the scheduler needs a choice | setup 39 / 48 / 64 / 49 / +5.00; the sprite table (h x w); look-ahead 11.2; the dcalcs burst stalls | **PT 58** (no structural cause, GAP); sort-off 44 / +19 / 12 and the crowded-lines table (T6) | T6 |
| MT5 | — | run start 3.9 / 4.2 / 6.3; 4.7 / 6 / 8; share 13.7 / 22.8 | lineshare (T7); mixed-`vmask` runs (T19) | T7, T19 |
| MT6 | **`D_PP` on B = 1035** | the per-pixel table (1.01 .. 4.28); align2 parities; first-tile extras; 2.14 memory bound; the small translucent layer 52 / 61 (1x1), from `D_PP` and pcache replays | 8x8 / 32x1 layers 100 / 114-119 (T13); cache organisation (T8) | T8, T13 |
| MT7 | `WO_FIFO` only if T10 / T15 have returned | write-out 1045 / 1105 / 1357, clip; per-tile overlap 1042 / 1096 / 1358 and 1363 / 1041.5; SEC WRITE +1025; keep-Z costs 17 / 32 / 2981 | **Z clear 142, empty tile 335, the 55-90 of a tile with polygons** (T1, T13); ~370 clk not overlapped at 16 bpp (T9) | T1, T9, T10, T13 |
| MT8 | — | deterministic cells of accbuf_races, keepz_races, ptchunkrun_races, ptchunkcarry_races outside `races_expected.txt`; the blendpos statistic (§1.5); accbuf T end / T stall / T flush thresholds (n = 36 / 32, 56, 96 / 64) within the test's step | the cells in `races_expected.txt` (T11, T12) | T10, T11, T12, T20 |
| MT9 | — | T17's display-off frames once T17 exists; hangs (behind D6): bumphang's stop tile and carry-over, two empty keep-Z tiles, the SCALER_CTL change | rendertimes.txt (display on; tolerance after G4) | T15, T17, T18 |

### MQ. Synthesis testing projects (the user runs Quartus)

Per-unit `quartus/timing/<unit>/` harnesses (lib/fp, the ISP lanes, the ISP buffer, the sorter, the pixel pipe stages)
and the whole-core `quartus/testing/polly2-rtl/`. Gate: `make quartus-lint` clean. The user's fit reports are read
for RAM inference (conv §10). In particular, `p2_isp_buf`'s RAMs must come out with exactly the ports of
ARCHITECTURE §3.4.7 (one write port, the stated read copies). A field inferred into logic, or with more ports than
the simulation model, is a defect. These reports are not a functional gate.

## 3. Console probes to design

All of them follow the dreamcast-tests rules (conv §9; tim §9 for the method), and are requested from the
dreamcast-tests owner through `OPEN_ITEMS.md`. Never run from here. Ordered by what they unblock.

### 3.1 Timing probes (tim §9, with what each fixes in ARCHITECTURE §6)

| probe | question | unblocks |
|---|---|---|
| **T1** `TM_STAMP` absolute palette clock | every hidden latency: STARTRENDER to the first pixel, list and parameter fetch latency, tile k's last pixel to k+1's first, the 335 / 142 / 55-90 split, setup latency | `VR_LAT`, `SEQ_AHEAD`, `OLW_AHEAD`; MT1-MT7 |
| **T2** `TM_ISPRAST` | the setup program per kind (strips 19 / 15, perpendicular, modifier triangles of every size, two-volume), the rows rule for thin triangles, hand-off depth; **big edges** (steps of 2^123 and more: any cost?); **a culled closing triangle** (32 or 15?); **the 65th clock of a volume** | `ISP_*`, the row-skip rule, `MV_GAP`; MT1 |
| **T3** `TM_ISPQ2` | whether cut runs, flags and tile boundaries take entries (the fit says no); `ENT_N`; the 32-rows-of-32x1 pace | MT2 |
| **T4** `TM_CUT2` | how cutting overlaps the next tile's ISP work (58 of 128 vs 11 of 256) | the row barrier form; MT2 |
| **T5** `TM_ORDER` + stamps | sorter emit / fill rates; the emit condition; early drains; the sort-off order | sorter rates and condition; MT3 |
| **T6** `TM_SETUPK2` (sort off: 0x000 only, never 0x100 / 0x10001) | store size, pinning, replacement, `STORE_KEEP` across entries, fetch cost, crowded lines; PT's 58 | `STORE_N`, replacement; MT4 |
| **T7** `TM_SPAN2` | ALU products a clock and arbitration; pixel queue depth, unit and position; lineshare | `ALU_NM`, `PXQ_*`; MT5 |
| **T8** `TM_TEXC` | texture cache line, ways, size, miss latency, flush at STARTRENDER; whether a texture read sees a framebuffer word written earlier in the render (coherence) | cache; MT6 |
| **T9** `TM_WO` | write-out per-line overhead against bursts, stride, half; why ~370 clk are not overlapped; contention with parameter and texture reads | `VR_ROW`, half contention; MT7 |
| **T10** `accbuf_wo_races` | the write-out's start latency, rate and **the reader's lead over the writer** (`WO_FIFO`), through the secondary-read collision; whether a SrcSelect && DstSelect pixel waits | `WO_FIFO`, the shared-port mechanism; MT7, MT8 |
| **T11** accbuf T flush refined + stamps | the lost event behind empty keep-Z | `p2_tbuf_hs`; MT8 |
| **T12** `ptchunkcarry2_races` + stamps | which of K1 (early chunk exit) and K2 (the chunk sweep keeps the last pass's resolves) the carry is. Scene: A and k fillers in chunk c, B in chunk c+1, with 0..N heavy or empty tiles before the cell to set the ISP's lead. Stamp A's last-pass pixels and B's first run with the palette clock (T1). K1 predicts carry iff B's run starts before A's feedback, so more carry the further the TSP lags; K2 predicts a dependence on the sweep's trigger. ptchunkcarry_races' k = 6, 7 cells (carry in the first tile row and after empty tiles) are the first discriminator | `P2_PTCARRY`; MT8 |
| **T13** `TM_PASS` | per-pass costs (an empty PT pass ~300, sweeps); **the primitive cache in time**: TR replay against re-walk (layers of 1x1 / 8x8 / 32x1, 4..64 layers, against the translucent cache size, including overflow), PT chunk passes ≥ 1 (descriptor replay, vertex replay with setup, or re-walk), TR_MOD per pass | sweep costs, `PCACHE_N`, what pcache stores; MT1, MT6, MT7 |
| **T14** `TM_VRAM` | display / TA / refresh / SDRAM_ARB_CFG contention (careful: bulk CPU access hangs) | arbiter priority; MT9 |
| **T15** end-of-render bits | video vs ISP vs TSP bit order and timing; `ev_vid` against the write-out reader | `ev_vid`, `WO_FIFO`; MT9 |
| **T16** untimed features | SupSample (4 clk a pixel?), trilinear, bump in OP / PT, two-volume PT, 16-bit UV, perpendicular triangles | SupSample points a clock; MT6 |
| **T17** pvr-renderer over 786 dumps, display off | whole-frame acceptance | MT9 |
| **T18** bumphang counter | what leaks, and whether it slows first | bumphang structure; MT9 |
| **T19** mixed-volume runs | a pre-sorted (or OpInPt opaque) textured polygon with the shadow bit, crossing an opaque volume edge inside one run: one setup or two, and the run-start cost | the store key and the mixed-`vmask` run start (ARCHITECTURE §3.7.1, §3.7.5); MT4, MT5 |
| **T20** PT pass turnaround | stamp clock (T1) on a PT pass that fails on one pixel: time from the pass's last shaded pixel to the next pass's first run, against the number of tiles queued ahead (0..14 background tiles before). The default predicts the ISP waits for the whole run stream to drain at every PT pass | the PASS_DONE wait (ARCHITECTURE §3.4.1); MT8 with T12 |
| **T21** (new) pre-sorted TR-modifier background skip | renders in sequence, varying the previous render's content and whether the previous tile or render had a translucent modifier list; a pre-sorted tile with an empty OP list and a TR_MOD list; readout: is the background shaded (picture, and ~1000 clk of time) | `p2_isp_ctl_tg`; tim §3.12 |

### 3.2 Functional probes (GAPs the RTL reproduces from refsw3's choice; any of them may change refsw3 first)

| probe | GAP (spec / refsw3) | scene sketch |
|---|---|---|
| F1 | num D1: mipmapped triangle with `Sdet == 0` (refsw3 SIGFPE) | covmeas degen triangles with a mipmapped texture whose levels are flat colours (mipdump's method) |
| F2 | num A1 / H7b: SupSample half-line with `B = -0` | ssrare-like page: planes flat in y on negative-determinant triangles, both signs of C, C from 2^-80 to 2^10 |
| F3 | num G1: mip DCalcCtrl 1 adder reach 53 vs 25 | first-vertex sums with operands 25-52 binades apart |
| ~~F4~~ | closed: faredge's open regions, resolved by refsw3 `6784ea3d` (1,340 / 1,340) | — |
| ~~F5~~ | closed: zovf's 2^128 cells, resolved by `708fb8cd` (zovf 1,080 / 1,080) | — |
| ~~F6~~ | closed: negative depths outside the top binade, tiny sizes, denormals: the depthgaps patch landed as `708fb8cd` | — |
| F7 | isp §15 #17: keep Z keeps the stencil | a volume in entry 1, keep Z entry 2 with a shadowed polygon and no volume |
| F8 | isp §15 #18: OP_MOD with neither OP nor PT list | an entry with only OP_MOD and TR |
| F9 | isp §15 #16: VolumeMode 3..7; "outside" summary on untouched pixels | modvol variants |
| F10 | isp §15 #19: a quad at a chunk boundary (4 or 3), a culled quad right after a drawn quad, a bad-corner primitive in the count | ptchunkq / ptchunklag variants |
| F11 | conv G8: SOFTRESET and power-on contents of the tile buffers and the buffer select | render, SOFTRESET, keep-Z tile that shows the buffer |
| F12 | tsp §22 #9: `offsKept` with an all-zero setter (planes dropped) | offspersist variant |
| F13 | isp §15 #14, tsp §22 #1: PARAM_BASE not 1 MB aligned | a PARAM_BASE with bit 19 set |
| F14 | isp §15 #7: an infinite determinant (refsw3: depth 0). Det 0 with an infinite corner depth is closed (depthgaps_dzinf) | corners at 2^64 and beyond, flat polygons in front and behind |
| F15 | tsp §22 #11: stuck alpha with textures, autosort, other clearing events (TODO C8) | blendsel variants |
| F16 | tsp §22 #12-14: SupSample in PT_MV, translucent modifier volumes, two-volume textured, render to texture 1555 / 4444 (TODO C6, C7, C10) | as TODO |
| F17 (new) | edge.h's open points: an **ordinary** sliver with its top corner in row 31 (does it start at row 30 too?); the walk's unit (2^(unit-6)); the end rule with `sx < 0`; the hugepos_rules page 11 (10 tiles) and hugepos_v5 (1 tile) residuals | faredge_walk-style slivers without a big edge; gen3 cases where the unit size or the `sx < 0` rule changes a pixel |
| F18 (new) | depth.h's open points: the order of REG words (m = 2..15, 17..22, 24..29) and Big keys among **other** planes' depths; the zero rule in the coordinate differences and the determinant; an off-grid negative REG slope of 2^102 or more; a slope of 2^128 or more after the division | depthgaps_mm-style ramps crossed with ordinary slivers in the same intervals; zovf_creg variants |

## 4. Requests to other owners (record in `OPEN_ITEMS.md`)

| to | request | needed by |
|---|---|---|
| dreamcast-tests | PC emission of the timemeas timed scenes, preceded by `echo T <scene>` (conv §7.6.2 option a) | MT0 |
| dreamcast-tests | multi-run race logs for every `*_races` test as data, at least 3 runs (blendpos_races has 1) | MT8 |
| dreamcast-tests | T1-T21, F1-F3, F7-F18 above | MT1-MT9, refsw3 GAPs |
| polly2-rtl spec readers | re-transcribe isp §7-9, §15, num §3 (EdgeHW), H7a, H14, §4 (depth flavour), §8 (A1 edge site, A3, G3-G6, G12) to refsw3 `708fb8cd` (ARCHITECTURE §0.1) | M2, M3 (the gates use refsw3 directly meanwhile) |
| nulldc3 | a hex depth field (the key, or the word and offset) in the render log (conv G6) | M13 depth diffs |
| nulldc3 | a defined value for MipSelect with `Sdet == 0` (D4), once F1 answers | M9 |
| nulldc3 | SB_ISTERR bit 0 in refsw3, if D11 says the RTL models it | MT9 |

## 5. Decisions only the owner can make

| id | decision | proposal |
|---|---|---|
| D1 | Is the TA in scope (conv G7)? p2-offline keeps refsw3-ta in C++, so TA input during a render is never exercised | out of scope for rtl/v1 |
| D2 | Display and SPG stalls in scope (conv G9)? | VRAM-model option only, off for timemeas, on for rendertimes |
| D3 | ~~The FLOAT depth regime~~ | **closed**: unreachable in refsw3 `708fb8cd` (startOnSlopes 1); the RTL has no float regime and asserts it |
| D4 | num §8 DEFECT D1: MipSelect divides by zero for `Sdet == 0` | refsw3 adopts `inv = +0` (K = 2^(-127 + size)) until F1 measures it; the RTL follows |
| D5 | Races policy: gate only the deterministic cells? Model run-to-run sources (refresh)? | deterministic cells only, with `races_expected.txt` keyed by probe; refresh as a VRAM-model option |
| D6 | Hangs: reproduce bumphang, the SPAN_SORT_CFG 0x100 / 0x10001 hangs, two empty keep-Z tiles, the SCALER_CTL stall? | yes where a mechanism is stated (bumphang counter, `p2_tbuf_hs`, scaler stall), behind `P2_HANGS=1`; not the 0x100 / 0x10001 hangs (no mechanism, each try costs a power cycle) |
| D7 | timemeas scenes: the owner's PC emission, or our own emitter | the owner's emission |
| D8 | Render log hex depth field (conv G6) | yes |
| D9 | ~~When the depthgaps patch lands~~ | **closed**: landed as `708fb8cd`; the stored depth is the 64-bit key behind `p2_zword_pkg` |
| D10 | Module prefix `p2_`, unit folder names, frame subsets | as conventions.md and ARCHITECTURE §1.1 |
| D11 (new) | SB_ISTERR bit 0 ("ISP out of cache"): a CPU-visible register bit with a measured rule [M ispcache], which refsw3 does not model | model it in `p2_isp_pcache` behind `P2_ISTERR=1`, and ask nulldc3 to add it to refsw3 so that rule 1 (no rule refsw3 lacks) holds; off by default meanwhile |

## 6. Risks

| risk | mitigation |
|---|---|
| refsw3 changes under the gates (it changed twice in the hours this plan was revised) | every summary records the nulldc3 HEAD and dirty hash (conv §2). `check_ref_copies` catches drift in the copies. `p2_hw_pkg` regenerates. §0 rule 7. refsw3-known is computed, never kept by hand |
| the L2 glue does not build or link as nm suggested (conv G10) | M5 is first in the tile track, its self-test proves it, and M1-M4 do not depend on it |
| tile-level lockstep hides an order bug that only frames show (stuck alpha, `offsKept` across tiles) | M12's frame gate and dual mode. `offsKept` is compared at every pass end in M11. The free-running ISP mode (M7) covers the barrier |
| a race mechanism guessed wrong shifts deterministic cells | every race mechanism is one sub-block with a switch to refsw3's behaviour; MT8 gates only after its probe; `races_expected.txt` keeps the misses visible |
| a timing fit with too many free parameters | parameters are fixed in pipeline order (MT1 to MT9). Each is fitted once, on the data that isolates it, and never re-tuned per scene. The ispq fit has 3 parameters for 4 points, checked on the 4 other ispq rows and on spanahead |
| the primitive cache's content is guessed wrong (descriptors against vertices) | functionally invisible; one module; T13 decides; replays can be switched to walks |
| simulation speed of whole frames (32-lane ISP, 1 px/clk TSP, ~10-40 M clocks a frame) | clang -O3 -march=native, then PGO trained once (conv §6.2); shard frames across processes; subsets while iterating |
| the 64-bit depth key and the replicated ISP RAMs are large for synthesis | correctness first; MQ reports the RAM count; ARCHITECTURE §8 item 12 |

## Appendix A. Revision 2: answers to the plan part of the review (C1-C5; A and B in ARCHITECTURE Appendix A)

| objection | answer | where |
|---|---|---|
| A1 (plan part) | faredge's 2^132 and the refsw3-known faredge strips dropped; F4 closed; the faredge_* / hugepos_* sets through `tria_extract`; the far random class; the seven mutants | M2, §1.2, §3.2 |
| C1 115 covmeas sets | npz / json readers; all 115 gated | §1.2, M2 |
| C2 mipmeas / mipk unread; unreachable lambdas; runtime switches | mipk_data in M9, mipmeas_data in M9 and M10; `bumpLight`, `shade`, `mipChoose`, `fade`, the SupSample block in `ref_copies.h`; `check_ref_switches.sh` pins MIP_K, MIP_ARITH and FOG_VARIANT | §1.1, M9, M10, M11 |
| C3 the barrier untested before frames; missing mutants | free-running mode with back-pressure; barrier-off and summary mutants; P10 forward off | §1.3, M6, M7, M11 |
| C4 IspPix comparisons against shared storage | per-field liveness masks | §1.3 |
| C5 bookkeeping | `races_variable.txt` and `races_expected.txt` (keyed by probe, must empty); refsw3-known computed at gate time; `fit/hw` enumerated at gate time; the blendpos statistic defined | §1.4, §1.5, M13, MT8 |
| B11 (plan part) | MT2's 32x1 rows and MT7's 142 / 335 / 55-90 moved to "reported until a probe"; probes attributed as ARCHITECTURE does (T3; T1, T13) | MT2, MT7 |
