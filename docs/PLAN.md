# polly2-rtl plan: build order, gates, testbenches, console probes

Role: architect. Revision 2, 2026-11-20, revised in answer to the review of revision 1 (Appendix A). The companion
of [ARCHITECTURE.md](ARCHITECTURE.md), which defines the units this plan builds. The repository rules are
[conventions.md](conventions.md). Unit names, formats, free parameters and the D1-D11 decisions are the
architecture's.

Pins: refsw3 = nulldc3 `skmp/refsw3` @ `4f3efe15` (refcore clean); dreamcast-tests @ `a932980`. M0 and M1 were
built and gated at `708fb8cd`; M1's range wrappers (H10: `p2_fp_rng_add`'s TSP zero rule and MIP flavour,
`p2_fp_rng_recip`'s determinant of 2^126 or more and zero determinant) and `tb/fp/ref_copies.h` were brought to
`4f3efe15` with M2 (`make fp`, `make scaffold` pass there). The specs' edge and depth sections are at `4f3efe15`,
num §4 / H10 too, and since M9 the TSP sections (ARCHITECTURE §0.1b); where they disagree, refsw3 is the reference for
every gate.

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
   runs once at the end of the milestone (conv §7.8). Its work runs on one queue (rule 8). A gate that takes
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
8. **Gates keep the cores busy** (2026-11-21; M7's quick gate had used ~4.5 of 32 cores: 12 static slices, one of them
   holding ispcache). Every gate, quick, full and mutants, and the captures:
   1. **One shared work queue**, not static slices: a free worker takes the next item (`tools/gate/pq.py`, through
      `lib.sh`'s `gate_queue` / `gate_item`; `mutants.py` and `capture_prerender.sh` have their own queue). The
      merged-verdict contract stays: a failing item never stops the others, the merged report decides, PASS iff every
      item passes. An item whose result could depend on the load must fail rather than shrink: every stage's exit
      status is checked (the captures: a test's PC build gives up a readback after 20 s, and a capture whose stream
      program exits non-zero fails, is tried once more alone, and never counts as complete).
   2. **Longest first**, by the cost recorded in the gate's last run (`build/gate/<gate>/cost.txt`: wall and CPU
      seconds per item; `build/pre/<case>/secs` for the captures), else a static estimate.
   3. **Heavy work is split** so that no single item sets the wall time: a case per item, a free-running case per run
      of whole segments when its cost asks for it (`tools/gate/tile_items.py`, §1.3), a lockstep unit testbench per slice
      (`--shard k/N`). A testbench may gain a selector for that (`--renders`); its comparison does not change. An
      item's result must not depend on what ran before it in the process or on J: generators are seeded per case (and
      segment), never per shard or process; where an item boundary may fall is fixed by the testbench (a segment), not
      by the cost or J, so the stimulus a case gets does not depend on the cut. Where a testbench's counts depend on the slicing (a lockstep's idle clocks
      drawn from one generator per process, the checks of the vector files each process loads), the gate keeps the
      recorded slicing for the quick run or reports the slicing-independent number beside the raw one.
   4. **One job budget**: J = `P2_J`, default nproc - 4 but no more than the physical cores (`tools/gate/jobs.sh`: on
      the 16-core, 32-thread box N copies of one testbench item past 16 at once run slower in total, 22 s each at 24 against
      6-8 s at 12-16), for the test items; a mutant build of `make -jB` holds B
      slots of the same J, its probe runs one slot each. The gates' own variables (`FP_J`, `ISP_EDGE_J`,
      `ISP_TILE_J`, `REFGLUE_J`, `*_SHARDS`, `*_FULL_SHARDS`, `*_MUT_NJOBS`) override; each script's header lists its
      own. No Verilator `--threads` (useless at this size, shrike4). **Poles**: where the wall time is set by one
      item that cannot be cut (the quick isp-tile gate's ispcache: 715 s free-running alone, 1294 s beside 15 others;
      its phase-halt run 196 s alone, 814 s beside 15), more workers beside it only slow it; the queue then holds slots
      back so that the other work ends about when the pole does (`tools/gate/pqlib.py`; `P2_POLE=0` turns it off).
      The utilisation of such a gate is low by design; its wall is near the pole's own time.
   5. **Every summary reports its time line**: wall, the summed CPU time, the utilisation CPU / wall / J and the
      slowest item (`lib.sh` `gate_end`), so an imbalance shows.

   A new milestone's gate follows this; a change to the gate infrastructure gives identical counts and verdicts on
   every gate before and after (agents/gates/, 2026-11-21).
9. **The HOLLY die shot** informs unit grouping, module boundaries and RAM sizes, as a tie-breaker: where the console's
   measurements and refsw3 leave a choice, the design takes the one the die's blocks and RAM macros suggest, and says
   so. Console measurements and refsw3 win over it. ARCHITECTURE §3.12 records where the units built so far agree with
   the die and where they depart from it.
10. **Sampled full gates** (the owner, from M9 on). Every quick gate and every mutant gate runs in full each
   milestone. An exhaustive gate (`isp-tile-full`, `sort-full`, any other `-full`) runs as a seeded SAMPLE
   (`make <gate>-full SAMPLE=<seed>`, `tools/gate/sample_items.py` on the gate's own items through pqlib's queue): a
   fresh seed logged in the summary; every case at least once (all phase-halt items, in full; every run stream under
   one SPAN_SORT_CFG), a random subset of the rest (free-running segments, the other configurations, random blocks);
   every item exercising the milestone's own modules in full (`--whole`); the permanent always-run list
   `tools/gate/always_run.txt` (anything that ever failed; a line naming no item fails the sample, and a sort-full
   stream's line comes with the isp-tile-full item that writes the stream); a budget of about 1-1.5 h wall at J 16 over
   the sampled gates (`SAMPLE_BUDGET`, the queue's wall: isp-tile-full 4000 s, sort-full 900 s). The random draws are
   optional items: the queue starts one only while its predicted end is within the budget (`pq.py --deadline`), so a
   slow run drops some instead of overrunning; the mandatory items (whole, always-run, every case) always run, and a
   "sample: WARNING" line says when they alone are predicted over the budget (see D12). Predictions come from the
   gate's cost file, else the static estimates times `SAMPLE_EST_SCALE` (calibrated on every cost file kept, see
   sample_items.py). The coverage, planned and run (items and weight %, per group, the dropped draws counted), is in the
   summary. The exhaustive runs happen once, after the last milestone.

## 1. Testbench architecture

### 1.1 Linking refsw3 (conv §7.3)

| level | how | used by |
|---|---|---|
| **L1** headers | `-std=c++17 -I$(REFCORE)`: `pvr_softfp.h`, `pvr_bits.h`, `pvr_isp_edge.h`, `pvr_isp_depth.h`, `pvr_tsp_plane.h` | M1-M4, M9, M10 |
| **L2** glue | `tb/ref/refcore_glue.cpp` `#include`s `refsw_tile.cpp` and `tb/ref/refcore_glue_lists.cpp` `#include`s `refsw_lists.cpp` (two translation units, as in refsw3-offline: both `.cpp` files include refcore's `TexUtils.h`, which has no include guard; M5), compiled into `build/ref/lib/` with refsw3-offline's FLAGS / INC / DEF (parsed from `$(NULLDC3)/refsw3-offline/build.sh`) plus `-DRenderCORE=RenderCORE_sw`; linked with `pvr_mem.cpp`, `TexCache.cpp`, `threading.cpp`, `-lpthread -lz`; environment in `tb/ref/refcore_env.cpp`; the background key (tb/fp's copy `fp-bgkey`, which cannot see `pvr_regs.h`'s macros) in `tb/ref/refcore_bgkey.cpp`; the API in `tb/ref/p2ref.h` | M5-M12 |
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
| MipSelect's K part (as built: all of it, from the determinant to K8: `tsp-mip-num`, `tsp-mip-k` in the L1 header `tb/tsp_setup/ref_copies_tsp.h`, M9) | plane.h | M9 |
| the `PixelFlush_tsp` lambdas `bumpLight`, `shade`, `mipChoose`, `fade`, and the SupSample block | tile.cpp | M10, M11 |
| the `put` / scaler lambdas of `RenderCORE` | lists.cpp | M5, M12 |

As built (M5, `tb/ref/ref_copies.h`): `core-pt-take`, `core-pt-loop`, `core-rpt` (the whole RenderParamTags body),
`tsp-mip-k`, `tsp-lambdas` and `tsp-super` (with `tsp-head`, `tsp-texture`, `tsp-tail` and `tsp-dispatch`: the whole of
PixelFlush_tsp in pieces), `core-put` (with `core-prev`, `core-writeout`, `core-endframe`: RenderCORE's frame around
the entries) and `core-perp`; the M1 / M2 rows were already in `tb/fp/ref_copies.h` (`fp-bgkey`, `fp-cull`) and
`tb/isp_edge/ref_copies_edge.h`. The self-test runs every copy on every pixel it shades; M9 moved `tsp-mip-k` to
`tb/tsp_setup/ref_copies_tsp.h` beside `tsp-mip-num` (the K part from the determinant on), where M9's graph check and
testbench run them. M10's copy is `tsp-mip-choose` (PixelFlush_tsp's mipChoose lambda alone) in
`tb/tsp_run/ref_copies_run.h`: a lambda local to PixelFlush_tsp, it is included inside `p2ref::mip_choose` in the glue's
translation unit (TcwRaster, MipSelect in scope, PixelFlush_tsp's names bound as there), which the TSP run testbench calls
on every point. M11's copies are `tsp-bump-light`, `tsp-shade`, `tsp-fade` (PixelFlush_tsp's bumpLight, shade and fade
lambdas) and `tsp-super-avg` (the SupSample block's average loop) in `tb/tsp_tile/ref_copies_tile.h`, included the same
way inside `p2ref::bump_light_copy`, `shade_copy`, `fade_copy` and `super_avg_copy` (one P2REF_TILE_* macro each, on an
entry made of the volume's words), which the unit sections of make tsp-tile call on random inputs.

**Runtime switches are pinned** (`tools/check_ref_switches.sh`, run by every gate, result in the summary):
- the environment has `MIP_K` and `MIP_ARITH` unset or `0` (plane.h reads both with `getenv`);
- the glue and refsw3-offline are compiled without `-DFOG_VARIANT`, or with `0` (tile.cpp);
- the `*HW` structs are the ones `p2_hw_pkg` was generated from (`hw-pkg-check`).

**The p2ref API.** These are non-static wrappers in the glue's translation units. Because each includes its `.cpp`
file, every static is in scope. As built (M5; `tb/ref/p2ref.h` is the reference, the sketch below is the plan's): the
punch-through calls are refcore's own steps (`pt_initial`, `pt_begin(chunk size)`, `pt_chunks`, `pt_chunk_start(c)`,
`pt_pass_start(p)`, `pt_final`; `pt_phase_copy` runs the verbatim PT loop); `begin_entry` is RenderCORE's
`ClearFpuCache` and `tilePixelsShaded = 0`; `render_param_tags(rm)` shades through the verbatim copies of
RenderParamTags' body and PixelFlush_tsp (`render_param_tags_core` is refcore's), with a hook a TSP testbench replaces
(`set_pixel_hook`); spans are `SpanRec` (refcore's `Span` is a type local to refsw_tile.cpp); `reset_core` returns every
state that outlives a render to a new process's; `set_isp_pixel` writes a pixel's state (the liveness self-test).

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

As built in M10 (tb/ref/p2ref.h): `interpolate_base(entry, p, W, InVolume, useAlpha)` and `interpolate_offs(entry, p, W,
InVolume)` (refcore's InterpolateBase / InterpolateOffs with pp_CheapShadows from FPU_SHAD_SCALE, as the dispatch chooses
it), `mip_choose(entry, InVolume, q, finer, &level, &dTri)` (the copy above).

**The glue self-test** (`make refglue-selftest`, M5) proves that the glue is refsw3:
- `tb/ref/phase_driver.cpp` walks a render through the p2ref calls, in RenderCORE's order, with a hook at every phase
  boundary (`tb/common/isp_live.h`'s phases).
- It runs the write-out through the `put` / scaler copies in `ref_copies.h` (`p2ref::copy::RenderFrame`: RenderCORE's
  frame from verbatim copies, the entries' phases the driver's).
- Its video memory after each render must equal refsw3-offline's on the frames subset, every word. Every tile-level
  testbench below relies on this. The same comparison runs RenderCORE_sw (the build's control), the driver with the
  verbatim PT loop, and the driver with every dead field scrambled at every boundary (the liveness masks' proof).

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

     M10 reads them through `tb/tsp_run/tsp_sets.h` (npz.h, which gained the `<u4` dtype of the sets' `tzbits`):
     uvmeas 24,681,778 readings, wmeas 2,320,996, cmeas 2,340,000 (three sets of 780,000 pixels, a pixel's colour one reading), uvspan
     1,634,195, uvrun 1,170,000, mipmeas 12,504,237.
  3. **Random and edge vectors against the reference.** The vector classes of num §7.2.
  4. **A random stream with random gaps and back-pressure.** No value may change.
- Values are compared as tuples: `neg`, `bad`, `mant`, and `exp` when `mant != 0` (num §1.3). Never as `double`.
  Depths are compared as the 64-bit key.
- The arguments every unit testbench takes: `--seed`, `--n`, `--shard`, `--only`, `--vec`, `--set`, `--trace`.
- **Triangles from console pages.** Many edge and depth tests (faredge_*, hugepos_*, edge2_*, depthgaps_*, zovf_*, nantr_*,
  perpmean_*, zword, depth2_*, trsort_*) are whole pages. `tools/gate/tria_extract.sh <test>` runs refsw3-offline with its render log on
  the test's PC stream. It turns every `TRIA` line (the corners exactly, `%a`) with its `TILE` into a unit vector
  file, `build/vec/<test>.tri`, so M2 / M3 test the edge and depth units on exactly the console's primitives. The
  comparison with the console's pictures happens at frame level (M13).

### 1.3 Tile-level lockstep testbenches (M5-M11)

These sit between unit and frame. They are the main bring-up tool for the ISP and the TSP.

**Inputs.**
- **Pre-render captures.** `tools/gate/capture_prerender.sh <case>` writes `build/pre/<case>/r<k>/{vram.bin.gz,
  pvr_regs.bin}` for each render k, and refsw3-offline's video memory after it, `r<k>/post/vram.bin.gz` (gzipped: a
  game frame is 3 MB that way, not 16; `p2ref::load_state` reads both forms), the first `--max` renders; the max is
  recorded in `build/pre/<case>/max` and a case is captured again when another max would capture other renders (M8).
  Sources:
  - a dreamcast-tests page: its PC stream, with `save` inserted before and after each render trigger (readbacks
    answered by refsw3-offline, as in run2.sh `off`);
  - a polly2-data dump (`dump:<scene>`): `pvrdmp <file>`, or for legacy dumps `regs ...; vram ...`, then the render;
  - a scenegen seed (`gen:<seed>`).
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
    row 28..31, 32·sx near 2^131 and 2^132: the gen3 class of agents/nulldc3/hunt/faredge; column steps below zero
    at multiples of 2^124..2^127, the edge2 class), points and tiny triangles with the top corner in row 31.
- **Subsets** (conv §7.8), in `tb/tile/subset_*.txt`: about 30 dumps across games and features, one or two pages per
  dreamcast-tests class, and 200 scenegen seeds. The full set is every dump, every page, and 5000 seeds.

**Liveness masks** (`tb/common/isp_live.h`). A field of `IspPix` is compared only where refsw3's value is live, so
the RTL's storage sharing and its per-phase rules are not reported as differences. The table below is the plan's; the
masks as built (M5) are narrower for depthB / tagB in the translucent sort (live after PEEL only), `rendered` (to
PT_MOD) and wider for resTag / resDepth (pixels with `rendered` or `everRendered`: PT_FINAL takes the key an earlier
chunk resolved), and the self-test's scramble mode proves them sound (`tb/ref/mutants_live.txt` has this table's
resTag row as a mutant):

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

  **As built (M6, `tb/isp_tile`).** The phase-halt mode runs inside the M5 phase driver: `isp_tile_ref.cpp` (compiled
  with refsw3-offline's flags beside the L2 glue) wraps `p2drv::render` and `p2ref::isp_pixel`, so the Verilated side
  (`isp_tile_tb.cpp`) never includes libswirl. At the driver's Z hook the testbench feeds the entry the driver read to
  `p2_isp_ctl` and runs the RTL to its halt; at OP and OP_MOD to the next one; at each it compares the live fields
  through `p2_isp_buf`'s debug row port and checks that the RTL halted in the same phase; at OP_SHADE the RTL must end the
  entry. Phases M6 does not have run on the reference only; **resync**: before a keep-Z entry that follows an entry
  with such a phase (and before a case's first keep-Z entry), the testbench writes the reference's state at the end of
  the entry before into the RTL's buffers through the debug port (counted in the report). A CLEAR entry needs none: it
  writes every field M6 compares. Otherwise the state carries from entry to entry and render to render. A phase that
  takes more than `--phase-limit` clocks fails. `--vramvary S` (or `+vramvary=S`) varies the VRAM model.

  **As built (M7, the same testbench).** Every phase runs and is compared; there are no resyncs any more (the case's
  first render starts with the reference's whole state written into the RTL's buffers, every field, through the debug
  port). At each boundary the fields `tb/common/isp_live.h` calls live are compared (resPass as the RTL's `rcur` / `rlp`
  against `resPass == PtPass` / `PtPass - 1`). The testbench is the TSP: it pops the run stream with a random stall
  chance and burst length per case. The reference's runs are refsw3's `SpanGen` of the pass (`p2ref::span_gen`) with
  the masks from the state before the SHADE (the PT pass's from the PT_WALK boundary); **the pre-sorted passes**, which
  refsw3 shades inside its walk, come from refsw3's own render log (`rendlog` pointed at a memory stream from the
  boundary before TR_PS: RenderParamTags' PASS / SPAN lines, put back in raster order). **The PT outcome** of a pixel:
  run-only if it was `rendered` before the SHADE, pass if it is after, fail otherwise; the testbench sends them as
  `p2_fb_t` messages as the runs come, then PASS_DONE. The eoe is checked where ctl's rule puts it (the SHADE it knows
  to be the entry's last, else END's null item), the entry records as p2_entq gives them (popped when their eoe item
  has been), and at END the PT chunk, pass and SHADE and the sort pass counts against the hooks'. `--op-only` keeps
  M6's scope (Z, OP, OP_MOD compared): `make isp-tile-op` runs it so.

  **Free-running mode (`--mode free`).** The reference renders first (through the same phase driver, the hooks
  recording each entry's non-empty passes with their runs, masks and PT outcomes, its record and counts); then the RTL
  runs with no halt, the entries fed as fast as ctl takes them, and the stream is checked as it comes: each run against
  the next expected one, `eop` on each pass's last run, one eoe per entry (on its last pass's last run or as a null item
  after it), the epoch; the PT passes are answered from the recorded outcomes after a random delay. At the render's end
  the live fields of all pixels (depthA, tagA, stencil, valid) are compared.

  **As built (gates on one queue, PLAN 0 rule 8, 2026-11-21).** The gates run a case per work item (`--shard i/N`, N
  the list's cases), so the generators are seeded from the case's index in the list: phase-halt's back-pressure (as
  before) and now its VRAM model's variation too (it had run on from case to case in a shard); a reset also clears the
  TSP side's stall and feedback counters. In free-running mode a case runs in **segments of 8 renders**: within a
  segment the RTL carries its own state from render to render (as before); at a segment's first render (8, 16, ...)
  the RTL is reset, the reference's whole state written in (as for a case's first render), and the back-pressure's and
  the VRAM model's generators restart from the case and the segment (segment 0's are the case's, as before). A
  segment's numbers, clocks included, then do not depend on what ran before it in the process, and `--renders A-B` (A a
  segment's first render) runs a case's segments A .. B alone (the renders before on the reference only), so a costly
  case of the full gate is cut into several items wherever the cost asks, with identical results. Every case of the
  quick gates has at most 8 renders: one segment, its state carried throughout, as M7's testbench ran it.

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

**As built (M11, `tb/tsp_tile`; make tsp-tile).** The DUT is `p2_tsp_tile_tb_top`: M9's store, fetch, setup and ALU, M10's
run start and pixel queue, the pipe `p2_tsp_pp` (P0-P11) and `p2_tbuf`, p2_mem with the VRAM model. The reference
(`tsp_tile_ref.cpp`) renders each render of a capture through the M5 phase driver first, recording through two hooks the
glue gained (`p2ref::set_pass_hook` around every `render_param_tags`, and M5's pixel hook): every entry (its tile, which
store is buffer 1 at its start), every SHADE pass's runs in TSP order (`span_gen` + `span_sort` of the state before it,
vmask / pmask from that state), every pixel (index, run-only, the alpha test, the write: buffer and word, or none) and
after each pass offsKept, tspAlphaStuck and a hash of both buffers. **The pre-sorted passes** reach the hook because the
testbench links its own lists half of the glue, `tb/tsp_tile/refcore_glue_lists_rpt.cpp`, which routes refsw_lists.cpp's
RenderParamTags calls (the walk's, after every pre-sorted triangle) to `p2ref::render_param_tags`, i.e. through the
verbatim copies of the loop and PixelFlush_tsp that the frames self-test proves (§1.1). Then the RTL runs the render's
items: each pass's runs as `p2_rs_t` (eop on a pass's last run; eoe on the entry's last item or on a null item after it, at
random), the entries' records, the registers (PALETTE_RAM, FOG_TABLE through their write ports), random gaps, random
feedback back-pressure, random holds of the pipe, random secondary-port reads (each checked against the testbench's
model of buffer 2). Checked in the RTL's order: every pixel leaving P10 (index, run-only, the alpha test, its write or
none), every feedback message, after every pass every word of both buffers (the testbench's shadow of the RTL's buffers,
kept from the write tap, against the reference's hash), the stuck alpha (as the pass's eop point leaves P10), offsKept (as
it leaves P7), and at every render's end every word read back through p2_tbuf's debug port and offsKept. The buffers swap
where refsw3's do (between entries, with the pipe idle: M12's controller does it from then on). A case's first render
starts from the reference's buffers and offsKept (loaded through the debug ports); state carries from render to render;
the generators are seeded per case and render (so `--renders A-B` cuts a case anywhere, the renders before on the
reference alone). **VRAM-race**: a render whose C4 reads touch a 64-bit word its write-out changed (refsw3 texturing from
the framebuffer as written so far, the RTL from the render's start) has its differences counted in their own class.

### 1.4 Frame testbench: `p2-offline` (conv §7.4)

- refsw3-offline's sources, minus `refsw_lists.cpp` and `refsw_tile.cpp`, plus `tb/frame/p2_rendercore.cpp` and the
  Verilated `p2_core`.
- One persistent core per process: tile buffers and `offsKept` carry across renders.
- The VRAM model serves the core from `emu_vram` (§1.6).
- Timing line on stderr: `p2: render <n> isp <clk> tsp <clk> video <clk> vramrace <words>`; with `P2_TIMING=1` (MT0) a
  `p2: timing ...` line before it (the per-unit clocks and counts, p2_core's `+p2timing` tap).
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

  As built (M13): `gate_frames_hw.sh` enumerates 237 `fit/hw` directories at `a932980` (`*_races` excluded), 185
  archived sets (every set of a test with a reader; uvrun has none), 786 `hw.png`, 63 `vram_out` and the two zdumps;
  `archive_check.sh`'s steps are run, not the script (its `model/build.sh` builds inside dreamcast-tests), conventions
  7.4.3 As built. refsw3-known has the sections tests, sets and dumps; the hw gate runs `refsw3_known.sh` itself when the
  file is not of the current revisions (computed at gate time). A test that searches by readbacks (36 fit/hw tests)
  also has every readback's answer compared with refsw3-offline's (conventions 7.4.3 "Readbacks", M13 round 2): the
  stream after a readback is what the PC program computed from refsw3's answer, so its pages are the RTL's only where
  the RTL answers alike.

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
- **As built (MT0, 2026-11-26; timing.md §11).**
  - The timed scenes: dreamcast-tests timemeas `main.c` `TM_EMIT` (D7 (a)), `make -C pvr-tests/timemeas emit`: one PC
    program a variant (all, cut, order, setupk, sortoff, and the SPAN_SORT_CFG overrides); `tools/timing/tm_item.sh` runs
    renders of one through p2-offline (`P2_RENDERS` skips the others; items cut at scene boundaries by
    `tools/timing/tm_items.py`), `tm_log.py` writes the console's log format, `gate_timing.py` checks and tabulates.
  - The fits: the plan's 3005 / 2695 / 2755 are REPORT's rounding; the archived least is 2998.5 / 2686.5 / 2745.5. K = 319
    fitted on the 0888 tile; and, since the write-out's format dependence needs a per-line row cost (ARCHITECTURE §3.2.1
    had `VR_ROW` "fitted later"), `VR_ROW` = 10 fitted once on `clip 0 - clip 4` (the 0888 write-out's excess over its
    reader, 311 clk), before K. Both in `tb/timing/k.txt`; the timing runs only (`P2_VR_ROW`), the functional gates keep 2.
    The 16-bit and 888 tiles are then checks, not fits (residuals 11.5 and 9.5).
  - The gate also checks the cutter (one clock a run: the slope over 64 .. 384 runs and cut k 0 - 5's single
    differences), which is what the planted mutant fails; cut k 6, 7 are reported (MT2).
  - The race lists: `races_variable.txt` from fit/accbuf_logs (timing lines; no multi-run pictures are archived, so the
    picture cells are the ones the tests' descriptions call run-variable: accbuf_races, blendpos_races);
    `races_expected.txt` from the RTL's run (T11 7 cells, T12 1,683); `tools/timing/races_check.py` (static in
    timing-harness, against an RTL run in timing-report).
  - `P2_TIMED_WRITES` (tb/frame/p2_rendercore.cpp): `<clock> <register offset> <value>` lines, `@<render>` sections, one
    write a clock through the register port; the palette clock from `tools/timing/tm_order_writes.py` (one write every
    12.24 clk, the console's mean rate). `+occlog` (27 tracks: every module p2_core instantiates, the queues RUNQ / PXQ / TILEQ / ENTQ with `F` lines) and
    `+p2timing` in p2_core (conventions 7.5).
  - Not built: `model/timing` (optional).

### 1.6 The VRAM model (ARCHITECTURE §3.2.1)

- Two halves, latency `VR_LAT`, row cost `VR_ROW`, optional refresh and display stalls.
- Requests take effect at grant: writes commit, reads sample.
- **The hazard detector** marks a render VRAM-race when a word written by C5 is also read by C0-C4 in the same
  render. The `p2:` line reports it. Every gate puts such renders in their own class.
- `+vramvary=<seed>` (random latency) is run on every functional gate. It must give identical values on every render
  not marked VRAM-race; only the clocks may differ.
- `VR_LAT` sweeps (1, 4, 8, 16) on the frames subset from M12 on, with the same rule. (As built: M12 ran 8, 1 and 16; M13 added
  4: make frames' configurations are base (8), vary, lat1, lat4, lat16. frames-hw runs base and +vramvary: the sweep is
  make frames'.)

## 2. Milestones

| id | title | depends | gate (quick) |
|---|---|---|---|
| M0 | scaffolding | — | `make scaffold` |
| M1 | numerics primitives (M1a / M1b / M1c) | M0 | `make fp` |
| M2 | ISP edge path (with the swamp and the big-edge walk) | M1 | `make isp-edge` |
| M3 | ISP depth path (`4f3efe15`: the sample point, the zero rule everywhere, the 2^126 determinant) | M1 | `make isp-depth` |
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

**Status (2026-11-20): done.** `rtl/v1/isp/` (p2_isp_edge_setup, _det, _line, _cross, _block,
p2_isp_rowrange, p2_isp_edge_raster, _row and the p2_isp_fadd / fmul / fsw wrappers), `tb/isp_edge/` (lockstep with
refsw3 `4f3efe15`; directed literals including the console pages of faredge_*, hugepos_a, edge2_* compared pixel by
pixel), `tools/gate/gate_isp_edge.sh`, `tria_extract.sh`, `tria_conv.cpp`; `make isp-edge`, `isp-edge-full` and
`isp-edge-mutants` pass, as do `make scaffold` and `make fp` after the M1 range wrappers' move to `4f3efe15` (Pins).
Results in `agents/m2r2/`.

**Deliverables.** The edge datapath of `p2_isp_setup` as a fixed-latency unit (the sequencer comes in M4), at refsw3
`4f3efe15` semantics (isp §7-8, ARCHITECTURE §0.1b, §2.4, §3.4.4 steps 1-5, §3.4.5):
- bad corners; the swamped determinant (`EdgeWinding`, no zero rule: isp §6.2); CulledBySize / CulledByFacing on it;
- per edge per tile `c`, `dx`, `dy`, `dxP`, `dyP`, `first`, `start` with the swamp and the 2^127 saturation, `s20`,
  `sx`, `sy`, `ep`, `es`, E with the cap at 129, `unit` (`ep - 21`, or `E - 27 = 102` for a big edge), `d`; blocking
  to `p2_edge_t`: the steps cut toward zero onto 2^unit, `t0` floored with its half-unit bit or, for a big edge, cut
  toward zero; `far32` for a big edge;
- RowRange with the row-31 shift for every polygon (not MODIFIER);
- the 32-lane, 34-bit edge evaluator of `p2_isp_raster` with the per-edge row stage and the walk (one grid, `H = 2^30`
  and `Z = 2^7` half units; the end against ZERO; the far value), the inside mask per row;
- `p2_hw_pkg` at `4f3efe15`: `make hw-pkg-check` fails there today ("pvrisp::EdgeHW has member cutUnitBits, which
  this generator does not list"; the same for `DepthHW::zeroRuleCoords`, `zeroRuleEdges`). `tools/gen/gen_hw_pkg.cpp`
  lists `cutUnitBits` (WIDTH) and the two DepthHW members (MODE, each with its `p2_hw_check.sv` check: the RTL has
  only the value 1); the package regenerated; `make scaffold` passes again.

**Gate** `make isp-edge`.
1. **Directed facts**: the covmeas rules; hugepos (2^118..2^124 pixel counts); the faredge_*, hugepos_* and edge2_*
   rules as edge.h cites them: cmax's 2^128 products, k132's cancelling RV tiles, m131's -2^131 not pushed and
   +2^131 pushed, ecap's cap at 129 and its R = -2^131 ends (pages 7, 9); edge2_walk pages 3-5 (the 2^102 grid, the
   start toward zero, the end against ZERO), pages 0-2 and edge2_end pages 0-4 (the far value with sx < 0: R + 2^131
   for -2^126, -2^127, -1.5 2^127, R alone near -2^127 and for +2^127), edge2_mult (odd multiples of 2^125, 2^124:
   R alone); the row-31 shift of faredge_walk pages 0-3, edge2_walk page 6 and edge2_row31 (points and tiny
   triangles, no big edge).
2. **All 115 covmeas sets**: per-pixel coverage equal to the console's record.
3. **The console pages' own triangles** (§1.2 `tria_extract`): every primitive of `fit/hw/faredge*`,
   `fit/hw/hugepos*` and `fit/hw/edge2_*` (8 + 19 + 4 tests), per tile, against the copied setup and
   `EdgeTile::Inside`. 0 differences from refsw3; refsw3 has no console residual left on these sets at `4f3efe15`
   (hugepos_rules 3,600 / 3,600, hugepos_v5 2,400 / 2,400), and refsw3-known stays computed at M13.
4. **Random**: 2M edges quick, 400M full, against the copies and edge.h. Classes: pixel-grid corners, ulp-perturbed,
   huge, denormal, slivers, points, both windings, both HALF_OFFSET values, first row 28..31 for **every** class
   (tiny triangles and points included), and **the far class**: steps of 2^123 and more, `32 sx` within a few units
   of 2^131 and 2^132, both signs, products at exactly 2^128; column steps below zero at and near multiples of 2^126,
   2^125, 2^124 (saturated differences included); starts within a few units of 2^102 of zero, both signs (the cut
   toward zero); rows where R reaches -2^131 exactly and `R + far32` lands on ZERO.
5. **The width claims**, asserted: the `d >= 30` constant rule; the 31-bit ordinary accumulator; on every big edge
   `d = 27`, `unit = 102`, refsw3's `f0`, `fx`, `fy`, `z`, `h` equal to `t0`, `tx`, `ty`, `zero2`, 2^30;
   `|t0|, |tx|, |ty| < 2^27`; the 34-bit lanes and walk accumulator (every value the walk or the lanes use below
   2^33); `far32` in [0, 2^30]. Any value outside fails. (`agents/spec-sync-edge/widths4f3.cpp` is the model check:
   2^32.31 at most on 300,000 edges.)

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
- **a big edge's grid**: `cutUnitBits` 27 to 26 or 28; `708fb8cd`'s two grids (`ep - 21` for the rows, `ep - 27` for
  the walk); a big edge's start floored (with and without the half-unit bit);
- **no wrap**; **no push**; **32·sx kept whole** (no `mod 2^131`); **the end against 0** (not ZERO); **0 counted as
  above**; **the walk counted from row 0** (not `jf`);
- **the far value with sx < 0**: R alone for the multiples of 2^126 (`708fb8cd`); R + 2^131 for every multiple of
  2^125 (or 2^124); R + 32 sx; R + sx;
- **no row-31 shift**; **the row-31 shift only with a big edge** (`6784ea3d`);
- dx / dy at 2^128 stepping as the swamp value instead of 2^127.

### M3. ISP depth path

**Status (2026-11-20): done.** `rtl/v1/isp/` (p2_isp_depth_plane, _tile, _setup, _lane, _raster
and the p2_isp_zadd / zmul wrappers; `p2_pkg::p2_ztile_t` at its 4f3efe15 form, `nsh` signed, `fbw`), `tb/isp_depth/`
(lockstep with refsw3 `4f3efe15`, the plane through the verbatim copy `ref_copies_depth.h`), `tools/gate/gate_isp_depth.sh`;
`tria_conv` writes the depth records `build/vec/<test>.trz` beside the `.tri`, and `tria_extract` answers a test's
readbacks itself (zeros) and renders a repeated scene once (zword, zexfil's probes: thousands of renders otherwise).
Notes from the run: refsw3's REG start reaches `|r0| < 2^26` (a finite `first0` up to 2^128), not 2^25; the 13 `.zme`
files hold 89,765 brackets (export_z.py leaves out the 36 quad-diagonal pixels of the 89,801); NegWord's fallback word does
reach covered pixels of random planes (650 of 79.3M fallback pixels in the full run, none on the console pages),
unlike widths4f3d's 0: still equal to refsw3, reported, not gated. Results in `agents/m3/`.

**Deliverables.** The depth datapath at refsw3 **`4f3efe15`** semantics (isp §6.3, §9; num §4, §5.2, H10, H12b,
H14; ARCHITECTURE §0.1b, §2.4 `p2_ztile_t`, §3.4.4 steps 6-7, §3.4.5 depth lanes), as a fixed-latency unit (the
sequencer comes in M4):
- ranged plane setup (`a`, `b`, `c`, `det`, Perpendicular) with the depth flavour of H10, **the zero rule in every
  addition**: the coordinate differences (refsw3 `subC`), the edges `x_j y_k - x_k y_j` and the determinant's sums
  (`addE`) as well as `a`, `b`, `c`, the start and the mean (`add`); the depth unit's own `e` and `det`, not the
  edge unit's (isp §6.2, §9.2);
- per tile: the regimes CONST / REG / BLOCK in refsw3's order (isp §9.3), with **CONST key 0 for a determinant of
  2^126 or more** (`top(det) - 1 >= 126`, exactly 2^126 included; `4f3efe15`) as for an infinite one; `inv0`, and
  `first0` **at the tile's first sample point**, `(left, top) + HALF_OFFSET[0] / 2` (`0de9776b`); the forced start,
  the mean with the infinite-corner rule, `under()`, `pair`, `gexp`, `E`, `S`, `DX`, `DY`, `nsh` (5 signed) and `fbw`;
  REG's `r0`, `sa`, `sb`, `fa`, `fb` from that start;
- the 32 depth lanes of `p2_isp_raster`: the 30-bit `t = S + 2i DX + 2j DY` (no half step: the start is at the sample
  point), `from_fp` / `big` / `neg` (a left shift for `nsh < 0`) / the fallback word, REG `regdepth`;
- the console pages' primitives with their depths: `tools/gate/tria_conv.cpp` keeps each corner's `z` (the render
  log's TRIA line has x, y, z, u, v a corner, `%a`; refsw_lists.cpp L143) in a depth record beside M2's `TriRec`
  (a new magic or a version field; M2's `.tri` readers unchanged), with HALF_OFFSET as M2 already records it;
- `tb/isp_depth/` (lockstep with refsw3 `4f3efe15`: `DepthTileT<DepthHW>::Setup(x, y, z, left, top, hw, centers)`
  and `At(i, j, centers)` with the **same** `centers`, `StoredDepth`; `tb/fp/ref_copies.h`'s depth lambdas, already at
  `4f3efe15` since M2), `tools/gate/gate_isp_depth.sh`, `tb/mk/isp_depth.mk`: `make isp-depth`, `isp-depth-full`,
  `isp-depth-mutants`, as M2's. `p2_hw_pkg` needs no change: M2 added `DepthHW::zeroRuleCoords`, `zeroRuleEdges`
  (MODE, `p2_hw_check.sv`: the RTL implements 1).

**Gate** `make isp-depth`.
1. **Directed**: zword's 32 register words and depthgaps_mm's order; nantr_* starts; zovf_* (lim, c, ps, creg, wrap,
   ab, sum, far, slope, sat*, neg*); depthgaps_* (zadd, field1, negconv, neggrid, bigpos, bigord, bigslope, bigpair,
   dzinf, detneg, rstart, rcut, infstart, edges, tinyramp, flt); perpmean_word (16,384 words) and perpmean_neg*;
   and the `0de9776b` / `4f3efe15` facts as depth.h cites them:
   - depth2_halfc: in tile (0, 0) at the corner zword's TL +inf triangle starts at +1 step (`m = 1 - (i + j)`) and
     zovf_creg's C0 at -1 step; nantr_fin2's and tiles (2, 0) .. (8, 0) the same as at the centre; depth2_halfo's 8
     ordinary triangles at HALF_OFFSET 6 (the corner's words at all 40 probed pixels);
   - depth2_zcoord, depth2_zedge: products of a zero difference / edge with 2^126 and +-inf depths (0, not an
     infinity), the words at every pixel;
   - depth2_cneg: F = -(8192 + 1/2), -(8192 + 3/4), -(256 + 1/4), -(2^18 + 1/2) units of 2^102 a row toward zero at the
     44 targets, the controls +(8192 + 1/2), -(127 + 1/2);
   - depth2_denorm (denormal depths on the 2^-145 grid, ordered by value), depth2_biggrid (Big cut to 19 bits),
     depth2_regmix and depth2_regbelow (REG's words and values between steps against blocks above / below their
     window and Big: the key order of every pair);
   - trsort_recip: determinants of exactly f 2^126, f = 0.5, 0.75, 1 - 2^-24 an ordinary depth of 1; f = 1, 1 + 2^-23,
     1.25, 1.5, 2, 3, 4 - 2^-22, and 4 (infinite) key 0; both windings; corners of 1, 0.5, 0.25; page 10's 2^128 from
     corners of 2^116; trsort_recipovf's corner depths inf 1 1, 1 2^127 1, 2^120 x3, -inf 1 1 at f = 1 (key 0) and
     1 - 2^-24 (the overflow regimes).
2. **All 13 zmeas sets** (89,801 brackets, 0 missed) and the covmeas `zprobe` sets.
3. **The console pages' own triangles** (§1.2 `tria_extract`, with the depth record) of every depthgaps_*, zovf_*,
   nantr_*, perpmean_*, zword, zbad*, zspec, zsign, bg* test, and of `fit/hw/depth2_*` (9 tests: biggrid 30 pages,
   cneg 6, denorm 6, halfc 42, halfo 8, regbelow 12, regmix 12, zcoord 80, zedge 65) and `fit/hw/trsort_*` (5 tests:
   auto, garb, recip, single 16 pages each, recipovf 8; trsort_single is a TSP page, but its hugepos triangles reach
   determinants of 2^126 and more and infinite ones): every covered pixel's key against `DepthTileT::At` and
   `StoredDepth`, at each render's HALF_OFFSET[0] (depth2_halfc, _halfo and others render at the corner). refsw3 is
   exact on all of them at `4f3efe15` (dreamcast-tests README "r8 round 1"); refsw3-known stays computed at M13.
4. **Random**: 1M planes quick, 100M full, against `DepthTileT::Setup` / `At` and `StoredDepth`, every regime
   represented, HALF_OFFSET[0] 0 or 1 at random, with the classes of depthgaps (negative starts, starts of exactly 0,
   slopes 2^50 and more times the start, products at 2^128, operands near 2^-126) and three more:
   - **near 2^126**: right triangles of legs about 2^63 whose determinant is within a few units of 2^126, exactly
     2^126 included, both windings, any tile; infinite determinants (corners from 2^64);
   - **zcoord / zedge**: tile (0, 0), coordinates among +-0, +-(1 .. 1.5) 2^-126, +-1 and small integers, depths of
     2^126, 2^127, +-inf, 1, -2^127. The zero-rule mutants need it: in `agents/spec-sync-depth/widths4f3d.cpp`
     neither changes a key on ordinary random planes (0 of about 37,500), while in this class `zeroRuleCoords` 0
     changes 1,988 and `zeroRuleEdges` 0 1,115 of 30,000 planes;
   - **at the corner**: the classes above at HALF_OFFSET[0] = 0, REG included (the start where an infinite slope's
     term is `x0 = 0`).
5. **Assertions on every pixel**: `|t| < 2^29` (2^28.45 in widths4f3d, both sample points); `nsh` in -14..14 where
   there is a start, `fbw` only where the start was cut to zero (its pixels reported with whether they are covered:
   none in widths4f3d); refsw3 never takes the float form (`block == false` with a valid plane); A2: the RTL's exact
   value equals refsw3's 64-bit truncation; the key round-trips through `zkey.h`; the reference is always asked with
   `startCenters == centers` (refsw3's `h` is 0, as in RasterizeTriangle).

**Mutants.**
- tileBits 26 to 25;
- startOnSlopes off;
- pairBits 21 to 20;
- `OneThird` as 0xAAAAAA;
- **the sample point swapped**: the start at the centre with HALF_OFFSET[0] = 0 and at the corner with 1;
  **`708fb8cd`'s corner model**: the start at the centre stepped back half a pixel (`h = -1`). widths4f3d: the
  other sample point changes 18,495 of about 37,500 random planes;
- **the zero rule off in the coordinate differences** (`zeroRuleCoords` 0); **off in the edges and the
  determinant** (`zeroRuleEdges` 0); and, as before, off everywhere, at 1.5 x 2^-126 inclusive, a zero sum keeping
  -0. The expected values for the first two come from refsw3 itself,
  `DepthTileT<DepthConfig>` with the switch at 0;
- **the determinant limit**: a determinant of 2^126 or more keeps its reciprocal (`708fb8cd`; `Recip` taken, the
  plane stepped); exactly 2^126 kept (the limit at `> 2^126`, i.e. the reciprocal 2^-126 kept: trsort_recip's f = 1);
  the limit at 2^127; an infinite determinant not 0 (its first corner's word);
- the ranged and unranged chains swapped at `first`;
- E not clamped at 128; E not clamped at -122;
- the forced start not stepped (revision 1's ovf 1: 0 at the first pixel, a word elsewhere);
- REG without the finite slope's steps (`fa = fb = 0`);
- REG's negative start rounded down instead of toward zero; `r0` without the cut to 20 bits; a finite slope below
  zero rounded down (depth2_cneg);
- the mean's infinite corners as z1's word (revision 1);
- `big` cut to 18 or 20 bits (depth2_biggrid); denormal depths as one word (depth2_denorm).

### M4. ISP setup sequencer and row stepper

**Status (2026-11-20): done.** `tools/gen/gen_setup_prog.cpp` (graphs, graph check, list
scheduler, emitters) -> `rtl/v1/pkg/p2_isp_prog_pkg.sv` (GENERATED; `make isp-prog`, `isp-prog-check`, `isp-prog-sweep`);
`rtl/v1/isp/p2_isp_alu.sv`, `p2_isp_setup.sv`, `p2_isp_raster.sv`; `p2_pkg::p2_asm_t`; `tb/isp_setup/` (testbench,
`ref_copies_setup.h`, `mutants.txt`, `mutants_gen.txt`), `tools/gate/gate_isp_setup.sh`, `tb/mk/isp_setup.mk`. Results
in `agents/m4/`. How it differs from the text below (which predates M2 / M3's module split):
- M2 / M3's fixed-latency units stay (their gates and testbenches); the logic after the arithmetic was moved, verbatim,
  into modules M4 shares with them: `p2_isp_edge_steps` (from `p2_isp_edge_line`), `p2_isp_edge_fin` (from
  `p2_isp_edge_block`), `p2_isp_rowclip` (from `p2_isp_edge_setup`), `p2_isp_depth_fin` (from `p2_isp_depth_tile`).
  `tb/isp_edge/mutants.txt` and `tb/isp_depth/mutants.txt` point at the new files (row31-big-only reads the clip's
  `big_any` hook, corner-708fb8cd-h the depth fin's `half` hook); `make isp-edge-mutants`, `isp-depth-mutants` re-run.
- The graph's outputs are the values the hand-off step reads (ARCHITECTURE 3.4.4 "As built"); the graph check compares
  them with verbatim copies of refsw3's code (`tb/isp_setup/ref_copies_setup.h`, drift-checked) and EdgeWinding, not the
  descriptor (the descriptor is item 2's).
- **Item 4's TRI 16 / QUAD 19 cannot both come out of the scheduler with the real datapaths.** At `ISP_NM` 3, `ISP_NA` 3,
  `L_MUL` 1, `L_ADD` 2, `L_RCP` 2: TRI 16, culled 15, QUAD **18**, MODIFIER 16; no set of the sweep gives 16 / 19 (the
  nearest 16 / 18 and 16 / 17). Not padded; reported, not gated (the parameters are fitted on the triangle: rule 6); the
  sprite's third clock joins GAP T2. The gate checks the RTL's periods against the scheduler's lengths.
- The console pages' records (`build/vec`) hold no MODIFIER triangles and no quad corner 4: MODIFIER, kill and quads are
  covered by the directed and random sections only.

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

**Status (2026-11-21): done (72ad5e2).** `make refglue-selftest` (tools/gate/gate_refglue.sh,
`tb/mk/refglue.mk`); results and scratch in `agents/m5/`. As built, where the text below no longer matches the tree:
- **The glue is two translation units** (`tb/ref/refcore_glue.cpp` with refsw_tile.cpp, `refcore_glue_lists.cpp` with
  refsw_lists.cpp) plus the L1 `refcore_bgkey.cpp`: both `.cpp` files include refcore's `TexUtils.h`, which has no
  include guard, and tb/fp's `fp-bgkey` copy reads a name `pvr_regs.h` defines as a macro (§1.1, conv §7.3). The API is
  `tb/ref/p2ref.h` (§1.1 "As built").
- **The phase driver** (`tb/ref/phase_driver.cpp`) runs inside `p2ref::copy::RenderFrame`, RenderCORE's frame made of
  verbatim copies (the write-out's `put` / scaler, the region array walk, each entry's write-out); every SHADE pass goes
  through the copies of RenderParamTags' body and PixelFlush_tsp, so the self-test proves those copies too. A hook at
  every phase boundary (`tb/common/isp_live.h`'s 19 phases) is where M6+ compare, halt and feed.
- **The self-test has four modes**, each every word of video memory after every render against refsw3-offline's
  (`tb/ref/refglue_selftest.cpp`): `drv` (the driver), `core` (RenderCORE_sw: the build's control), `ptcopy` (the
  verbatim PT loop), `scramble` (every field `isp_live.h` calls dead randomized at every boundary: the liveness masks'
  proof; §1.3 "As built" lists where they differ from the table).
- **Captures** are gzipped and carry refsw3-offline's video memory after each render (`r<k>/post/`); dumps are
  `dump:<scene>`, seeds `gen:<seed>` (§1.3). `tria_extract.sh` takes the same `dump:` / `gen:` cases into
  `build/vec/frames/` (a folder of its own: the M2-M4 testbenches read every record of `build/vec`).
- **The tile subset** (`tb/tile/subset_tests.txt`, `subset_dumps.txt`, `subset_seeds.txt`): 69 tests at most 8 renders
  each, 33 dumps, 200 seeds; 695 renders. Generated translucent primitives keep their depth planes in range: a fragment
  whose stored depth is above the largest finite float is above the autosort's empty reference every other pass, and
  refsw3's sort then never ends (scenegen.cpp says how).
- **refsw3-known** (`tools/gate/refsw3_known.sh`) runs dreamcast-tests' run2.sh `off` and compare2.py unchanged on
  `build/refsw3-offline`; the README's scores are `tb/ref/readme_scores.txt`. archive_check.sh is not run (its readers
  build inside dreamcast-tests).
- **Mutants**: `tb/ref/mutants.txt` (the phase driver's order, "PT final before PT_MOD" read as the pair swapped:
  PT_MOD's walk before PT_FINAL) and `tb/ref/mutants_live.txt` (unsound masks, among them §1.3's own resTag row), all
  caught.

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
  1,340 / 1,340; hugepos_rules 3,600 / 3,600 and hugepos_v5 2,400 / 2,400 at `4f3efe15`, 3,590 and 2,399 at
  `708fb8cd`).

**Mutants.** Phase-driver order swaps (OP_MOD before OP; PT final before PT_MOD) must be caught by the self-test.
As built: those two (the second as PT_MOD's walk moved before PT_FINAL), OpInPt set after the opaque SHADE, the
translucent volumes after the SHADE, TR_PS without its status clear, no RESTORE; and six unsound liveness masks.

### M6. ISP tile: list walk, fetch, opaque, modifier volumes

**Status (2026-11-21): done.** `make isp-tile-op` (tools/gate/gate_isp_tile_op.sh,
`tb/mk/isp_tile.mk`); results and scratch in `agents/m6/`. RTL: `rtl/v1/isp/p2_isp_ctl.sv` (Z, OP, OP_MOD, the phase
halt), `p2_isp_olw.sv`, `p2_isp_pfetch.sv`, `p2_isp_buf.sv`, `p2_isp_pix.sv`, `rtl/v1/mem/p2_mem.sv`; `p2_pkg`'s
`p2_isp_obj_t`, `p2_sweep_t`; `idle` outputs on M4's `p2_isp_setup` and `p2_isp_raster`. Testbench `tb/isp_tile/`
(PLAN 1.3 "As built"), the VRAM model `tb/common/vram_model.h`, mutants `tb/isp_tile/mutants.txt` (24) and
`mutants_mem.txt` (3, p2_mem; the credit limit and the priority order left out as equivalent while C1 and C2 only
read). How it differs from the text below (ARCHITECTURE 3.2, 3.4.1-3.4.3, 3.4.6, 3.4.7 "As
built (M6)"):
- `p2_isp_buf` holds M6's fields only (depthA and tagA with both read copies, stencil, valid) and the CLEAR / CLRSTATUS
  sweeps; the other fields, sweeps and the row barrier come with M7.
- `p2_mem` has a response ready per client and keeps the clients' response buffers; olw's read-ahead waits there.
- The bypass has two sources (R2 and R3), because of the registered RAM read. scenegen's ROWS class got pairs that hit
  both (a tall primitive, then one starting on its last row or the row above; the R2 case needs corner sampling and an
  integer top). Without them the bypass mutants survived: in the dumps only 3 tiles reach it, all R3 cases at the row-31
  shift. MODVOL got a volume triangle on an opaque triangle's corners (`modvol-ge` survived without it). Both changes
  draw no extra random numbers for seeds without those classes. The M5 captures of the seeds were redone.
- p2_mem's per-client order (`order-by-arrival`) survived too. The pages and dumps read both halves, but a client
  almost never has reads outstanding on both at once. So scenegen puts every other object's parameter blocks in the other
  half (absolute 0x400100 .. 0x440000), and some list links go there as well (0x440000 ..). The VRAM model's
  `+vramvary` now also stalls a half for up to 63 clocks, one clock in 64 (as refresh or display reads would).
- scenegen's list links to the other half (above) had left `listNext` at the list's start, so the next tile's list
  overwrote the crossing list's first block and its link: tiles drew other tiles' lists and most cross-half links were
  never walked. `writeList` now moves `listNext` past the half-0 part (the link word and its gap); over seeds 1-200 no
  two lists share a word and 102 cross-half links are walked. The seeds' M5 captures were redone again.
- Three mechanisms had no input (the round-2 verifier's extra mutants). scenegen draws two more things from a second
  generator (`Rng::of(seed, 1)`, so that the first generator's scenes stay as they were): opaque primitives with depths
  below zero (all corners or some: planes across 0) at DepthMode 1 or 6, and, with STRIPS, type-110 list words (another
  object's word with bits 31:29 = 110, which refsw3 skips: isp 15 #15). Mutants `depthmode1-unsigned`,
  `depthmode6-unsigned` (`$unsigned` compares; `r1_zk[i] < dA[i]` alone is still signed, as an element of a packed
  array of the signed `p2_zkey_t`, IEEE 1800-2017 7.4.1, so the verifier's version was equivalent; bgneg catches the
  real one too) and `type110-as-quads`, all caught. The third, the stencil's bypass from R2, cannot be reached: only
  MODIFIER rows write the stencil, and a MODIFIER triangle steps all 32 rows, so two volume rows of one row number are
  at least 32 clocks apart. The bypass is gone from `p2_isp_pix`; the testbench's `t_mrow` tap fails a run where such
  rows come one clock apart (0 over every input). `modvol-own-rows` (a volume triangle on its own rows) is caught.
- The Makefile reads `tb/mk/refglue.mk` before the other fragments: `isp_tile.mk`'s prerequisites name
  `$(REFGLUE_OBJS)` and `$(REFGLUE_REFDEPS)`, which make expands as it reads the rule, so in name order they were
  empty (a clean build failed; the testbench objects were not rebuilt on a refcore change).
- TAG_BELOW and 29-bit tags have no compare in M6 (KeyAbove is M7's). Their mutants change the stored word (a 0xFFFFFFFF
  background tag kept as a flag; tagA in 29 bits) and are caught by scenegen BGTAG.
- Inputs: `tb/tile/subset_isp_op.txt` (39 pages: the classes above plus the edge and depth pages of the tile subset), the
  tile subset's 33 dumps, seeds 1-200; 520 renders, 88,513 entries, 189,194 phases compared. Not compared: phases M6
  does not have. Keep-Z entries after one are resynced (2,375).
- Clocks (reported, not gated; VR_LAT 8, VR_ROW 2): an entry with only its Z costs 35 clk (CLEAR / CLRSTATUS 32 + 3
  transitions). An empty opaque list adds 22, inside the measured 20-31 (tim 3.1). Over the subset: mean 249 clk an
  entry, max 42,245 (xtreme_intro), the dumps' mean 877. With `--vramvary 7` the mean is 838 (max 155,589) and the values are the same.
  No VRAM-race render: nothing writes in M6.

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

**Status (2026-11-21): done.** `make isp-tile` (tools/gate/gate_isp_tile.sh,
`tb/mk/isp_tile.mk`), `make isp-tile-mutants`, `make isp-tile-full`; results and scratch in `agents/m7/`. RTL in
`rtl/v1/isp/`: `p2_isp_ctl.sv` (every phase), `p2_isp_ctl_tg.sv`, `p2_isp_ptc.sv`, `p2_isp_pcache.sv`, `p2_isp_cut.sv`,
`p2_isp_fb.sv`, `p2_isp_entq.sv` (p2_entq), `p2_isp_lram.sv` (one wide field), `p2_isp_buf.sv` (every field and sweep,
the barrier at its sweeps), `p2_isp_pix.sv` (PT and AUTOSORT rules, `more`, the barrier at R0), `p2_isp_olw.sv`
(scan); `p2_isp_setup.sv` got `pc_desc`; `p2_pkg`'s `p2_sweep_t` has every sweep. ARCHITECTURE 3.4.1-3.4.11 "As built
(M7)" say how the tree differs from the text; in short:
- **PT chunks continue the walk**: ptc holds the next chunk's first descriptor in setup's hand-off (olw, pfetch, setup
  wait by back-pressure) and passes nothing between walks; pass 0 of the next chunk moves its current chunk. A chunk
  of more than `PCACHE_N` = 256 descriptors puts ptc in **full-walk mode** (every later walk from the list's start,
  the counter restarted, non-members dropped).
- **scenegen got three classes the M7 mechanisms needed**, drawn from a third generator (`Rng::of(seed, 2)`) after
  everything else is written, so that no other scene moves (checked when PTLONG was added: the 190 other seeds' 215
  renders were byte for byte the same video memory and registers; PTROW and TWINS draw only from the same generator,
  after it; the 35 seeds that drew one were captured again):
  - PTLONG (seeds 3, 67, 70, 87, 125, 127, 138, 146, 172, 184 of 1-200): 272-336 small PT triangles in tile (0, 0) at
    chunk size 0x3ff. Nothing in the pages or dumps reaches full-walk mode;
  - PTROW (16 seeds): PT triangles on rows 8-10 and 10-12 in turn with corner sampling, replayed one a clock: the
    `valid` bypass of p2_isp_pix from R2 (`valid-bypass-r2-off` survived without it: RowRange's last row has pixels
    only with corner sampling, so a replayed row of one row number one clock after the last one is rare);
  - TWINS (12 seeds): one translucent block listed twice, once with the shadow bit (intensity mode): equal keys, equal
    sort bits, tags that differ in bit 27, so a sort pass's choice depends on the replay's order (`pcache-reverse`
    survived without it: KeyAbove's order is total for distinct fragments, so a replay's order is invisible
    otherwise).
- **TR_PRESORT** shades one descriptor at a time (ctl blocks the hand-off until its rows are written and its SHADE is
  issued); a culled or bad primitive has no descriptor and no SHADE. **The epoch counts the passes that emitted a run.**
- **The entry's end**: `last` on the SHADE ctl knows to be the last (OP_SHADE with no PT / TR, PT_MV_SHADE with no TR,
  the sort pass with `more` = 0), else END's null eoe item.
- **Every phase halt waits for the cutter** (the phase's runs out). The sweeps have two stages: 33 clocks each (CLEAR
  and CLRSTATUS too; 32 in M6).
- **The testbench** (PLAN 1.3 "As built (M7)") compares every phase and every SHADE's runs; the pre-sorted passes come
  from refsw3's render log (it shades them inside its walk); the free-running mode replays a recorded reference render.
  M6's gate runs it with `--op-only`; M6's mutants file had three fragments the M7 text moved (same mutants).
- `tools/gate/mutants.py`: a probe written `!name` marks a mutant that must pass (PLAN M7's per-tile barrier).
- Inputs (quick): M6's pages, `tb/tile/subset_isp_tile.txt` (the M7 pages above), the tile subset's dumps and
  `tb/tile/subset_isp_tile_dumps.txt` (the PT / translucent dumps it lacked), seeds 1-200 (chunk sizes 0, 1, 2, 0x20-0x40,
  0x3ff; SHARED's PT_MV runs with mixed `rendered`; PTLONG). ptchunkcarry_races is not an input: its carrying cells are
  T12's (P2_PTCARRY = 0).
- **Gate** (quick, 12 shards; 625 renders: 52 pages at most 8 renders each, 40 dumps, seeds 1-200; 121,318 entries):
  phase-halt 1,185,869 phase boundaries compared (1024 pixels each), 184,598 SHADE passes and 8,100,965 runs checked,
  110,121 null eoe items, 11,273,547 feedback messages, 351,329 descriptors replayed by pcache, ptc full-walk 626,852 clk,
  holding the next chunk 5,059,093 clk; free-running (`--vramvary 7`, random back-pressure) the same stream, records,
  counts and the end-of-render state of every render, 254,215 raster rows held by the row barrier. 0 failures. 270 s
  and 848 s (ispcache's last render alone takes ~440 s free-running: 301 entries of up to 256 sorted layers walked again
  every pass after the cache overflows), so the quick gate takes ~19 minutes, not PLAN 0 rule 3's minute; the mutants
  are their own target (`make isp-tile-mutants`).
- **Clocks** (reported, not gated; VR_LAT 8, VR_ROW 2): phase-halt mean 1,246 clk an entry (accept to end, halts
  excluded), max 1,075,479 (ispcache); free-running with `--vramvary 7` 3,289 clk an entry over a render (entries
  overlap: the next entry's Z sweep starts behind the last SHADE, held only by the row barrier), the longest entry
  4,749,115 from its accept to its end.
- **Mutants** (`tb/isp_tile/mutants_m7.txt`, probes `tile` = phase-halt and `free` = free-running on
  `tb/isp_tile/mutant_cases_m7.txt`, stopping at the first failure): PLAN M7's 17, the 16 bugs caught and the
  per-tile barrier passing as it must (`!free`); and six of the structure (`valid-bypass-r2-off`, `ptc-gate-open-between-walks`,
  `cut-eop-from-flops`, `fb-anyfail-pass-done-only`, `sweep-barrier-off`, `raster-barrier-off`), caught. The row barrier
  mutants are caught only in free-running mode (phase-halt waits for the cutter at every halt).
  `make isp-tile-mutants`: 23 of 23 (904 s, 4 at a time).
- The other gates pass on this tree: `make scaffold`, `fp`, `isp-edge`, `isp-depth`, `isp-setup`, `refglue-selftest`
  and `isp-tile-op` (M6's 24 + 3 mutants caught on the M7 testbench, its probes now stopping at the first failure).
- **Full gate** (`make isp-tile-full`, once, 9,582 s): every fit/hw test (its first 256 renders; ta-probe and ta-tests
  never render and are no input), 855 dumps, seeds 1-5000: 15,501 renders, 2,331,437 entries. Phase-halt (3,277 s)
  20,467,351 phase boundaries, 3,311,895 SHADE passes, 131,848,921 runs, 33,575,803 feedback messages, 6,694,774 replayed
  descriptors; free-running with `--vramvary 7` (6,287 s) the same stream, 4,265,575 rows held by the barrier. 0
  failures. Clocks: phase-halt mean 774 an entry (max 1,072,009); free-running 1,738 an entry over a render (max
  4,741,905 one entry).
- **Full gate again (2026-11-23, M8's capture fix)**: that run had used the quick gates' 8-render captures of 48 fit/hw
  tests (capture_prerender.sh did not check `--max`; M8 status). With each test's first 256 renders: 18,386 renders,
  3,125,873 entries; phase-halt 27,137,146 phase boundaries, 4,343,983 SHADE passes, 165,883,262 runs, 2,931,313 null eoe
  items, 73,867,702 feedback messages, 7,189,837 replayed descriptors; free-running (`--vramvary 7`) the same stream,
  6,145,921 rows held by the barrier. 0 failures. Clocks: phase-halt mean 763 an entry (max 4,240,627); free-running
  1,756 an entry over a render (max 18,876,166 one entry). 30,783 s wall at J 16 (89 %), its pole ispcache's renders
  8-15 free-running (11,343 s: ispcache has 18 renders, not 8).

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

**Status (2026-11-22): done**. `make sort` (tools/gate/gate_sort.sh, `tb/mk/sort.mk`), `make
sort-mutants`, `make sort-full`; scratch in `agents/m8/`. RTL in `rtl/v1/sort/`: `p2_runq.sv` (one RAM of `RUNQ_N` 300,
its read register the output), `p2_sort.sv` (the 96-place compacting window, the epoch key, the emit condition, the
flags' re-attachment, null items, bypass); `p2_entq` is M7's `rtl/v1/isp/p2_isp_entq.sv`, hooked up in the testbench
top `tb/sort/p2_sort_tb_top.sv` as in p2_core (pushed with the eoe item into the run queue, popped when it leaves the
sorter). ARCHITECTURE 3.5 / 3.6 "As built (M8)" give the choices; 3.12 the die agreement. Where the tree differs from
the text below:
- **The subset's run streams** are M7's: the ISP tile testbench in free-running mode writes every item p2_isp_cut
  emitted, after checking it against refsw3, with each eoe item's entry record and each render's SPAN_SORT_CFG
  (`--dump-runs`, `tb/common/runstream.h`; build/sort/rs/<case>.r0-<n-1>.rs.gz). `make isp-tile` writes them, and `make
  sort` makes the ones older than the ISP tile testbench or their capture (a work item a case; ispcache alone ~1,200 s,
  the pole); `make isp-tile-full` writes the full set's into build/sort/rs-full for `make sort-full`.
- **The reference** is refsw3's SpanSort itself (`p2ref::span_sort` through `tb/sort/sort_ref.cpp`, SPAN_SORT_CFG written
  into the register block) on each pass of the stream (eop to eop); the expected stream is those passes in order with
  the null items where they came. Passes run back to back with no barrier; only where the ISP tile testbench had reset
  the RTL (a free-running segment's start, where p2_isp_cut's epoch restarts) the testbench waits for the sorter to empty.
- **SPAN_SORT_CFG** is the run's (0x101, 0x001, 0x000), not the render's register; each stream runs under all three.
- **Back-pressure** classes, per render (subset) or stream (random): none; random gaps on both sides; a slow cutter (the
  input offered one clock in three, held in bursts); a slow TSP (stalls of up to 24 clocks).
- **Random streams** as listed below, in blocks of 1,000 (a work item a block; epoch from a random start, carried and
  wrapping across the block's streams); runs per row and the rows' density are drawn towards small numbers (~370 items
  a stream) so that 100k fit the quick gate.
- **Gate** (quick, J 16: 1,601 s when every stream is made, the streams 1,207 s of it; 344 s when they are there): every
  check passes under each SPAN_SORT_CFG. Subset: 292 streams, 625 renders, 121,318 entries, 184,598 passes, 8,100,965
  runs and 110,121 null items (M7's counts, every one), 8,638,904 checks a configuration. Random: 100,000 streams,
  418,360 entries, 816,404 passes, 36,418,697 runs and 174,665 null items, 38,246,586 checks a configuration.
- **Clocks** (reported, not gated; T5): items a clock under back-pressure 5.72 / 6.18 / 5.77 (subset, 0x101 / 0x001 /
  0x000) and 5.44 / 5.53 / 5.24 (random); drains on the subset 356,982 (22.7 runs a drain) at 0x101, 447,275 (18.1) at
  0x001; the drains ending with a clock of no emit 172,384 and 262,677; the run queue full (300) in both classes.
- **Mutants** (`tb/sort/mutants.txt`, probes `subset` = 4 game dumps' streams, `random` = 4,000 random streams, both at
  0x101): PLAN M8's 8 (window 95 and 97 on the subset: of the 292 streams 59 fail at 95 and 58 at 97, all game dumps but
  depth2_denorm; the circular FIFO with holes; the youngest-first drain; the key without `& ~7`; the epoch out of the
  key; emitting without the emit condition, which fails in the slow-cutter class; eop / eoe left where they came in)
  and 2 of the structure (the closed state forgotten when the eop item leaves early; the run queue reading over its
  output register): `make sort-mutants` 10 of 10 (69 s).
- **new_drain** (the sorter's output to the TSP's look-ahead, ARCHITECTURE 3.6) was checked by nothing; since M9
  `tb/sort/sort_tb.cpp` checks it on every item with the sorter on (1 exactly on a pass's first item and where the key,
  the tag & ~7 with offset sort, differs from the item before it in the pass; 0 on a null item), and the mutant
  `new-drain-every-item` (new_drain on every item) is caught: `make sort-mutants` 11 of 11.
- **Full gate** (`make sort-full`, once, 1,801 s): the 7,401 run streams `make isp-tile-full` wrote (18,386 renders,
  3,125,873 entries, 4,343,983 passes, 165,883,262 runs, 2,931,313 null items; 179,425,106 checks a configuration) and
  1,000,000 random streams (8,142,709 passes, 363,720,964 runs; 381,944,185 checks a configuration), under 0x101, 0x001
  and 0x000: 0 failures. Items a clock 5.86 / 5.80 / 5.86 (streams), 5.48 / 5.58 / 5.24 (random).
- **The captures' --max** (owner's decision, 2026-11-22): capture_prerender.sh records the max a case was captured with
  (build/pre/<case>/max) and captures again unless that is the max asked for or the case's stream ended before both
  (captures from before: max = their renders when 8 or more). The full gates no longer reuse the quick gates' 8-render
  captures; the quick gates in turn capture again after a full one (their inputs stay their first 8 renders).

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

**Status (2026-11-23): done (not committed: the owner's).** `make tsp-setup` (tools/gate/gate_tsp_setup.sh,
`tb/mk/tsp_setup.mk`), `make tsp-setup-mutants`; scratch in `agents/m9/`. RTL in `rtl/v1/tsp/`: `p2_tsp_store.sv`,
`p2_tsp_pfetch.sv`, `p2_tsp_setup.sv`, `p2_tsp_alu.sv`; `rtl/v1/pkg/p2_tsp_pkg.sv` (the TSP's formats) and
`p2_tsp_prog_pkg.sv` (GENERATED by `tools/gen/gen_tsp_prog.cpp`: `make tsp-prog`, `tsp-prog-check`, `tsp-prog-sweep`,
`tsp-setup-graph`). The testbench `tb/tsp_setup/` (the DUT the store with fetch, setup and ALU behind it, p2_mem with the
VRAM model; the reference `tsp_setup_ref.cpp` on p2ref::fpu_entry; the cases `tsp_cases.h`, shared with the graph check;
the K copies `ref_copies_tsp.h`). ARCHITECTURE 3.7.1-3.7.4 "As built (M9)" give the choices, 3.12 the die agreement.
Where the tree differs from the text below:
- **Item 2 compares the live words**: a class sets up only the planes a pixel of the entry reads (untextured: the 1/w
  plane and the colours; U, V when textured; the offset planes when Texture && Offset && not a bump map); refsw3's
  others are made of words the fetch never decoded (decode_pvr_vertex leaves them) and no pixel reads them.
- **Item 4's table at `4f3efe15`**: since `2bee80f2` every sum that is zero is +0, so a dropped plane's A, B, C are
  zeros of the determinant's sign (flat: A = B = +0, C of the mean's sign); ARCHITECTURE 3.7.3's AND rule was the rule
  before tsp2_zadd. The A3 class, the graph check and the testbench prove the new table; the mutant "the flat branch's
  C sign from the AND rule" is caught.
- **Item 5**: the mipk sets' observations (fit/mipk_data) are read as the console's K8 against MIP_K 1's (kfit's base;
  mipk5's in its reached mode against cases.txt's steps); the RTL's K8 is the console's wherever refsw3's is, and
  refsw3's everywhere (PLAN 0 rule 4). mipmeas's 10 sets: K8 against refsw3, which is the console's on them
  (dreamcast-tests README); their pixel readings are M10's.
- **Item 7**: refsw3 defines MipSelect with Sdet 0 since `2bee80f2` (D4 closed): those primitives are counted and
  compared, not skipped.
- **The program lengths** at ARCHITECTURE 6's parameters (UNTEX 20, TEX 26, TEX_O 39, +5 for K, +1 for DCalcCtrl 1) do
  not reach the measured 39 / 48 / 64 / +5 with any parameter set of the sweep (nearest: 2 multipliers, 2 adders,
  37 / 50 / 76): reported, not gated (rule 6); MT4.
- **The setup class and the program length of every job** are checked (the program consistency check: the issue clocks
  against the generated length, the class against the one the cases give; the class is not checked where a block's
  vertices overlap, skip shorter than the fields).

**Gate** (quick, J 16; build/gate/tsp-setup/summary.txt): 22.1 s wall, CPU 249.7 s with the testbench built (the
queue 17.6 s, CPU 244.5 s; 2026-11-23, agents/m9/gates/q2); a run that builds it adds about 50 s wall (70.9 s / 982 s
CPU, and 141 s / 1,150 s with a 51.7 s build step and a 76 s queue on a busier box):
- graph check: 1,000,000 random jobs (seed 1), 2,800 of A3, 1,272 named, 59,400 console-set triangles: 1,063,472
  evaluations, 0 failures (every class: UNTEX 208,083 .. TEX_D_M1 25,594).
- named (item 3): 1,272 cases, 49,102 checks; a3 (item 4): 2,800 cases (4,008 TEX_D jobs, 494 TEX_O), 189,918 checks;
  console (item 5): cmeas c1 / cwext1 / cwsum1 7,200 triangles, mipk / mipk2 / mipk3 / mipk5 9,600 cells (9,191 observed:
  the RTL the console's on 9,028, refsw3's on the same 9,028; mipk 2,394 / 2,400, mipk2 2,400 / 2,400, mipk3 2,243 /
  2,400, mipk5 1,991 / 1,991), mipmeas 10 sets 42,600 triangles; 79,705 K checked; 2,457,555 checks; random (item 6):
  1,000,000 primitives, 1,457,463 setup jobs (every class), 848,261 K (166,002 with Sdet 0, item 7), 47,948,886 checks.
  0 failures. Clocks (reported): 47.8 a job, 39.0 from a job's accept to its last store write, at most 14 entries
  pinned.
- Mutants (`make tsp-setup-mutants`, 23.1 s wall, CPU 66.3 s; earlier runs 38.8 s and 28.7 s): PLAN M9's 8 (the 1/w constant's order and the attribute product on the
  graph check; zeroReach 3 on cmeas cwsum1; 0x95F612 + 1 on the mipk sets; bias 0 not 4; dropped planes as +0; the
  flat C sign from the AND rule; the drop predicate on the sent colours, by the class check) and 9 of the structure and
  the graphs (perpendicular not flat, the intensity entry's alpha scaled, the store key without the volume, the head
  before its entries are ready, replacement ignoring pins, no odd swap, the ISP's masked PARAM_BASE, the determinant
  without e2, a numerator's operands swapped): 17 of 17 caught.
- **Every earlier gate** (2026-11-23, J 16, agents/m9/gates/q2, m2, full2): scaffold, lint, fp, isp-edge, isp-depth,
  isp-setup, refglue-selftest, isp-tile-op, isp-tile, sort PASS; every mutant gate in full (fp 92, isp-edge 36,
  isp-depth 29, isp-setup 16, refglue 12, isp-tile-op 27, isp-tile 23, sort 11 of 11 with new_drain's, tsp-setup 17:
  every one caught) PASS. **Sampled full gates** (rule 10, seed 383029441, on a clean tree: no cost file, build/sort/
  rs-full empty; 66 min together, 3,366 s + 614 s): `isp-tile-full` every one of the 6,084 phase-halt items in full
  (18,386 renders, 66,820,640 checks, 0 failures; queue 3,255 s wall, 47,409 CPU s; the pole scalermeas 1,698 s) and the
  12 always-run free-running items (47 renders, 0 failures), 6,097 of 13,486 items, 24.0 % of the predicted weight;
  the mandatory items alone were predicted over `SAMPLE_BUDGET` (65,058 CPU s at the static estimates' 0.3 (now 0.25), measured
  48,922: phase-halt 0.22), so no random free-running segment was drawn (the sample's WARNING line; D12); `sort-full`
  on the 12 streams that run wrote (the 4 always-run window-95 / 97 streams among them: "4 matches of 4 lines"), each
  under at least one SPAN_SORT_CFG, and 450 of 3,000 random blocks: 468 of 3,037 items, 15.1 % of the weight, 0
  failures, 614 s wall (`SAMPLE_BUDGET` 900, predicted 765 s; no draw dropped at the deadline). With this run's cost
  file the next isp-tile-full sample draws about 119 free-running segments beside the mandatory items (seed 12345:
  6,216 items, predicted 3,400 s).

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

**Status (2026-11-23): done (not committed: the owner's).** `make tsp-run` (tools/gate/gate_tsp_run.sh, `tb/mk/tsp_run.mk`),
`make tsp-run-mutants`, `make tsp-run-full [SAMPLE=<seed>]`; scratch in `agents/m10/`. RTL in `rtl/v1/tsp/`:
`p2_tsp_rstart.sv`, `p2_pxq.sv`, `p2_pp_issue.sv`, `p2_pp_plane.sv`, `p2_pp_div.sv`, `p2_pp_col.sv`, `p2_pp_mip.sv`; the
formats in `p2_tsp_pkg` (`p2_tsp_pev_t`, `p2_tsp_rdesc_t`, `p2_pp_ctl_t`, the run-start product `p2_tsp_rsp_t`); M9's
units gained run start's ports (p2_tsp_alu / p2_tsp_setup: the products on the shared multipliers; p2_tsp_store: the row
read), with M9's gate and mutants unchanged. The testbench `tb/tsp_run/` (the DUT M9's store, fetch, setup and ALU with
p2_mem and the VRAM model, then run start, the pixel queue and P0-P3; the reference `tsp_run_ref.cpp` on p2ref; the
console sets `tsp_sets.h`; the mipChoose copy `ref_copies_run.h`). ARCHITECTURE 3.7.1 / 3.7.4-3.7.7 "As built (M10)" give
the choices, 3.12 the die agreement. Where the tree differs from the text below:
- **The pipe ends at P3 in M10**: the pins go and the pass drain ends when a point leaves P3 (P10 from M11). The tile of
  an entry comes to run start from the entries' records (`er_*`; p2_entq's in M12).
- **The console sets' readings** are compared through each reading's decoder applied to the TSP's numbers at the pixel
  (`tsp_sets.h`): uv the texel of uvmeas's 1024-wide number texture (dreamcast-tests model/tspprobe's `texel()`), w the
  green of wmeas's fog readout (refcore's FogUnit through p2ref::fog), c the colour, mip the level's colour times the
  trilinear pass's coefficient (mipmeas/main.c's texture, ExpandToARGB8888, PixelFlush_tsp's fade). A reading's run is
  the triangle's first covered pixel on the line in the tile (refsw3's edge setup), cut after uvspan's opaque bands and
  uvrun's band columns in kinds 1, 2, 4, 5 (README "uvspan"; uvrun/main.c); with these refsw3 itself is the console's on
  every reading of every set (agents/m10/score.cpp first, then every gate run: "refsw3 the console's on" all). The
  uvmeas sets hold **24,681,778** readings at 36 sets (the 23.6M of this plan were the 29 sets of tspprobe's count);
  mipmeas **12,504,237** (rgb 24 x 24, corner 6 x 6, tip 2 x 2 of every cell, the pixels a triangle covers).
- **The full gate is cheap** (all 24.7M uvmeas readings in ~41 s wall at J 16), so `tsp-run-full` runs every item; with
  SAMPLE=<seed> it goes through sample_items.py with every group `--whole` (all M10's own), the seed and the coverage in
  its summary; `tools/gate/always_run.txt` names its mutant-probe sets.

**Gate** (quick, J 16; build/gate/tsp-run/summary.txt; 2026-11-23, agents/m10/gates): see the numbers at the end of this
section.

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

**Gate results (2026-11-23, J 16, agents/m10/gates).** `make tsp-run` PASS, 24.7 s wall, CPU 326 s (queue 22.3 s, 90 %
utilisation; a build adds ~45 s): random 2,000,184 pixels (4,992,741 points, 3,990,076 SupSample; 2,657,056 mipmapped, 1,521,320
with the offset planes), 96,248,779 checks; super 500,305 SupSample pixels, 38,592,133 checks, the half lines by num H7b's
classes over both: 1,377,968 planes, 83,249 carrying, 257,051 beyond the 90 window, 47,481 truncated at 62 bits, 657,840
with C' < 0; console 463,795,124 checks: every reading of uvspan (1,634,195), uvrun (1,170,000), wmeas (2,320,996), cmeas
(2,340,000) and mipmeas (12,504,237), uvmeas every 8th run (3,085,384), each the console's, refsw3 the console's on every
one; 0 failures. `make tsp-run-full SAMPLE=2162423843`: every item (216), every uvmeas reading, 24,681,778 of 24,681,778
the console's; 37.3 s wall, CPU 529 s. Clocks (reported): run start 4.00 / 5.00 / 7.00 clk a
run within one triangle and 8.08 / 9.10 / 12.10 across two, against the measured 3.9 / 4.2 / 6.3 and ~4.7 / 6 / 8 (MT5,
ARCHITECTURE 3.7.5); 1.56 clk a pixel on the console sets with P3 held a third of the clocks.
`make tsp-run-mutants` PASS (53 s): the 9 of this list (five in rtl/v1/tsp; the normalizer's two and the divider's two in
tb/tsp_run/mutants_fp.txt) and 12 of the structure (the halves' 2^-1, step2 as step, hyd 0, the cache key without the
tile, ex from the tile's top, row 2 never read, B' times x0h, only the pixel's volume stepping, InVolume in the PT
passes, the SupSample points swapped, UseAlpha, dz) caught: 21 of 21; the pass drain off and the credits off pass, as
they must (timing mechanisms). **Every earlier gate** (agents/m10/gates/all.log): scaffold, lint, fp, isp-edge, isp-depth,
isp-setup, refglue-selftest, isp-tile-op, isp-tile, sort, tsp-setup PASS; every mutant gate in full PASS (fp 92, isp-edge 36,
isp-depth 29, isp-setup 16, refglue 12, isp-tile-op 27, isp-tile 23, sort 11, tsp-setup 17: every one caught). **Sampled
full gates** (rule 10, seed 820779215): `isp-tile-full` PASS, 3,159 s wall (CPU 42,776 s, 85 %): every one of the 6,084
phase-halt items (18,386 renders, 66,820,640 checks) and 654 of 7,401 free-running segments (12 always-run, 642 drawn;
1,579 renders), 6,739 of 13,486 items, 17.6 % of the weight, 0 failures, no draw dropped at the deadline; `sort-full`
PASS, 201 s wall: 1,452 of 5,317 items (every stream under one SPAN_SORT_CFG, the 4 always-run streams, random blocks),
16.3 % of the weight, 0 failures.

### M11. Pixel pipe: texture, shading, fog, SupSample, blend

**Status (2026-11-24): done (not committed: the owner's).** `make tsp-tile` (tools/gate/gate_tsp_tile.sh, `tb/mk/tsp_tile.mk`),
`make tsp-tile-mutants`, `make tsp-tile-full [SAMPLE=<seed>]`; scratch in `agents/m11/`. RTL: `rtl/v1/tex/` (`p2_tex_coord`,
`p2_tex_addr`, `p2_tex_cache`, `p2_tex_pal`, `p2_tex_decode`, `p2_tex_filter`), `rtl/v1/tsp/` (`p2_pp_shade`, `p2_pp_fog`,
`p2_pp_ss`, `p2_pp_blend`, and `p2_tsp_pp`: the whole pipe P0-P11), `rtl/v1/tbuf/p2_tbuf.sv`; the formats in `p2_tsp_pkg`
(`p2_pp_pt_t`, `p2_tex_req_t`, the PixelFmt and cache constants). M10's testbench top now has the whole pipe (its points
still read at P3: `o_take`; the pins and the drain at P10), with M10's gate and mutants unchanged (one fragment updated:
the drain's). Testbenches `tb/tsp_tile/`: the TSP tile testbench (`p2_tsp_tile_tb_top`, `tsp_tile_tb.cpp`, the reference
`tsp_tile_ref.cpp` with the glue's lists half `refcore_glue_lists_rpt.cpp`, §1.3 As built (M11)) and the unit sections
(`p2_tsp_unit_tb_top`, `tsp_unit_tb.cpp`, `tsp_unit_ref.cpp`); the copies `ref_copies_tile.h` (§1.1); the glue gained
`set_pass_hook`, `tile_buffer_sel`, `set_color`, `set_offs_kept` and the copies' wrappers. ARCHITECTURE 3.7.7, 3.8, 3.9
"As built (M11)" give the choices, 3.12 the die agreement. Where the tree differs from the text below:
- **The pass drain is not taken after a TR_PRESORT pass.** With a drain after every pass (P0 waits for the eop point to
  leave P10), pre-sorted primitives (a pass each) could never meet in the blend, and the P10 forward mutant could not
  fail anywhere; ARCHITECTURE 3.7.7's hazard ("TR_PRESORT puts primitive k's last pixel and k+1's first pixel at the same
  place, one clock apart") assumes they go back to back. So they do, the forward carrying the blended value; every other
  pass is drained at P10. Timing only (the drain-off mutant passes the values).
- **The P10 forward's case among the inputs**: no console page of M11's list and no dump of the tile subset has a
  pre-sorted primitive whose first pixel is the one before's last (agents/m11/mutscan: the mutant without the forward
  passes all of them); scenegen seed 180 has one, and the mutant's probe is that seed (always-run in tsp-tile-full). The
  unit section's repeated pixels catch it too.
- **The tile buffers swap** where refsw3's write-out swaps them (between entries), pulsed by the testbench with the pipe
  idle, until M12's controller.
- **offsKept is zero at power-on** (`rst`; refsw3's static starts at 0) and loaded by the testbench from a capture's state
  (`ok_we`); never cleared otherwise.
- **The texture path's choices** (placeholder organisation [G T8]): the cache gathers a point's taps into registers (four
  read ports, one fill at a time); TEXT_CONTROL[17]'s byte swap is applied at the cache's output (the VQ index bytes are
  read before it); the palette RAM has four asynchronous read ports. The bumphang counter (MT9, D6) is not built.

**Gate results (2026-11-24, J 16, agents/m11/gates).** `make tsp-tile` PASS, 590.6 s wall, CPU 8,482 s, 90 %
utilisation (the pole texctl_bankmip 457 s: VQ bank pages, scattered texels); inputs: the tile subset (tb/tile/subset_tests,
subset_dumps, subset_seeds) and M11's console pages (tb/tsp_tile/subset_tsp_tile.txt: texfmt, sample, mip, mipbil, texctl*,
texfar*, coordfix, yuvbil, bump*, env, alphatest, fog, tspw, supsample*, ss*, trimin, trifade, blend, blendsel*,
offspersist), at most 8 renders each: 93 pages, 33 dumps, 200 seeds, 326 cases, 822 renders.
- tile (--vramvary 7): 326 cases, 177,556 entries, 450,665 SHADE passes (229,509 pre-sorted), 14,797,090 items (89,905
  null), 258,771,056 pixels, 253,972,223 tile-buffer writes, 10,425,939 feedback messages, 174,664 swaps, 61,504,332
  secondary-port reads; 1,222,867,964 checks, 0 failures: every pixel's write, every feedback message, both buffers after
  every pass, the stuck alpha and offsKept at every pass end, every word at every render's end. VRAM-race renders: 0.
- unit-tex: 2,000,000 random texture points against p2ref::texture_filter, 0 failures; unit-shade: 1,000,000 random pixels
  (SupSample's four points among them), 8,636,154 checks (P7 against the shade / bumpLight copies, P8 fade(fog), P9 the
  average copy, P10 stuck, alpha test, BlendingUnit's write, the feedback), 0 failures; lint-tsp-tile PASS.
- Clocks (reported, not gated: MT6, T8): 632,307,985, 2.444 a pixel; texture stalls 237,185,627 clk (1,534,637 line fills:
  ~140 clk a fill under --vramvary's random latency, ~18 without), feedback block 5,196,880, the testbench's holds
  10,939,305, the pass drain 3,406,787. Untextured pages 1.03 clk a pixel (blend); SupSample and VQ-bank pages 4-10.
- `make tsp-tile-mutants` PASS (193.5 s): PLAN M11's list, all caught: the 10 of rtl/v1/tsp (the blend's 255, stuck alpha
  never set, offsKept loaded at P0 instead of P7, the fog index without +1, fade before fog, SupSample's sum >> 2, the
  run-only write, the P10 forward off (on seed 180's back-to-back pre-sorted primitives), DstSelect's dst from buffer 1,
  PT_MV alpha-testing every pixel) and the 5 of rtl/v1/tex (bilinear as one sum, YUV by memory order, the VQ bank XOR
  after +2048, the byte swap on index bytes, the 1x1 YUV level not as 565); of the structure 9 in tsp (bump light
  interpolated, offsKept by any texture, decal alpha, the bump quadrant, vertex fog without Offset, fog of a negative
  1/w, anyfail counting run-only pixels, stuck not cleared at eoe, PT_ALPHA_REF's low byte), 11 in tex (twiddle u / v,
  strided flip, the half texel at the level's size, clamp below 0, declared V, the cache tag's top bit, no flush,
  palette 8's bank, the strided widening, IgnoreTexA, the bump weight) and 4 in tbuf (the write-out's read into P10's
  register, the write-out winning the secondary port, no swap, writes not through sel): 39 caught of 39; the timing one
  (the pass drain off) passes, as it must.
- **tsp-run with the longer pipe** PASS (88.4 s): every M10 count unchanged (random 96,248,779 checks, super 38,592,133,
  console 463,795,124: every reading of every set the console's where refsw3's is), run start's pitch as in M10;
  `tsp-run-mutants` 21 caught, the 2 timing ones passing. `make tsp-run-full SAMPLE=3315927` PASS (162 s): every item,
  24,681,778 uvmeas readings of 24,681,778.
- **Every earlier gate** (agents/m11/gates/all.txt): scaffold, lint, fp, isp-edge, isp-depth, isp-setup, refglue-selftest,
  isp-tile-op, isp-tile, sort, tsp-setup PASS; every mutant gate in full PASS with M10's counts (fp 92, isp-edge 36,
  isp-depth 29, isp-setup 16, refglue 12, isp-tile-op 27, isp-tile 23 (its per-tile barrier one passing, as it must), sort 11, tsp-setup 17).
- **Sampled full gates** (rule 10): `isp-tile-full SAMPLE=2704611883` PASS, 5,730 s wall (CPU 83,958 s, 92 %; the pole
  ispcache 2,757 s): every one of the 6,084 phase-halt items (18,386 renders, 66,820,640 checks) and 20 free-running items
  (12 always-run; 92 drawn ones not started at the deadline), 0 failures; `sort-full SAMPLE=918274465` PASS, 498 s: 868
  of 3,940 items, 15.9 % of the weight, 0 failures. `tsp-tile-full SAMPLE=1559023471` PASS, 4,218 s wall (CPU 60,490 s, 90 %; the
  pole ssrare/r8-15 556 s; the captures at up to 256 renders first): every case once (one of its items at random: 231
  pages, 855 dumps, 5,000 seeds, 6,084 cases), the always-run items and the unit sections whole: 6,117 of 7,434 items,
  64.5 % of the predicted weight, 8,019 renders, 1,101,743,803 pixels, 7,121,268,683 checks, 0 failures; 4 VRAM-race
  renders (scenegen seeds 1156, 1295, 2013, 3079: texture reads of words their write-out changed), 0 differences there. The
  mandatory items alone were predicted over SAMPLE_BUDGET (no cost file: static estimates; the sample's WARNING line,
  D12), so no optional item was drawn; the next sample has this run's cost file. Clocks 4.03 a pixel.



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

**Status (2026-11-24): done (not committed: the owner's).** `make wout`, `make wout-mutants` (tools/gate/gate_wout.sh,
`tb/mk/wout.mk`), `make frames`, `make frames-mutants` (tools/gate/gate_frames_off.sh, `tb/mk/frames.mk`), `make p2-offline`,
`make p2-offline-dual`, `tools/p2-offline/build.sh`; scratch in `agents/m12/`. RTL: `rtl/v1/regs/p2_regs.sv`,
`rtl/v1/seq/p2_seq.sv`, `rtl/v1/tbuf/p2_tbuf_ctl.sv` and `p2_tbuf_hs.sv`, `rtl/v1/wout/p2_wout.sv` and `p2_wout_put.sv`,
`rtl/v1/p2_core.sv` (every unit; `tb/mk/core_units.mk` lists them); p2_pp_blend / p2_tsp_pp gained the P10 hold and the
buffer-2 interlock, p2_tbuf's debug port is simulation only. Testbenches: `tb/wout/` (`p2_wout_tb_top`, `wout_tb.cpp`,
the reference `wout_ref.cpp` on RenderCORE's frame from the copies core-put / core-prev / core-writeout / core-endframe),
`tb/frame/p2_rendercore.cpp` (p2-offline, the dual mode). ARCHITECTURE 1.3, 2.3, 3.1-3.3, 3.9, 3.10 "As built (M12)" give
the choices, 3.12 the die agreement. Where the tree differs from the text below:
- **The tile queue** (ARCHITECTURE 2.3 As built (M12)): run start needs an entry's tile before its first item, `p2_entq`'s
  record comes with the eoe item; a second queue of ENT_N tiles, pushed when the cutter takes the entry's first command.
- **The action's point**: the eoe point in P10 and the pending action hold P0 - P9 (a bubble in P10), so the next entry's
  first buffer read comes after the swap; every action waits for the write-out (`P2_HS` 0); one or two clocks a tile
  (MT7's to fit).
- **The TSP tile testbench** (make tsp-tile) has the controller and the write-out in place of its swaps (§1.3 As built
  (M11): the testbench now pushes each entry's record into p2_entq with its eoe item and mirrors the controller's swaps);
  it also checks every write-out read of buffer 2 and every word of video memory after each render against refsw3's.
- **The frame gate runs refsw3-offline's own stream** (conventions 7.4.2 As built): capture_prerender.sh keeps it
  (CAP_STREAM=1) and p2-offline replays it, because a test's PC build gives up a readback after 20 s.
- **The race class's input**: no console page of the subset and no seed has a VRAM-race render that differs; the gate's
  is `texctl_bank+0e4=900` (every TEXT_CONTROL write 0x900: bank 9 puts texture A's VQ index bytes in the framebuffer tile
  the region array wrote just before; capture_prerender.sh builds `<test>+<reg>=<value>` with REG_OVERRIDE as run2.sh
  does): its two renders differ from refsw3 in 64 and 48 words under every configuration, in their own class; the
  hazard-detector-off mutant's probe.
- **soft_rst** is decoded but wired to nothing (GAP F11); the register read-back is a RAM of all 2048 words [A].

**Gate results (2026-11-24, J 16, agents/m12/gates).**
- `make wout` PASS (34.5 s; CPU 382 s): 8,000 random frames under `--vramvary 7` and 2,000 without, every word of video
  memory after every frame, the buffers and the swaps at the end: 10,000 frames, 203,253 entries, 160,091 write-outs,
  80,498,705 VRAM writes, 20,971,550,000 checks, 0 failures; every pack mode (1,428-1,429 frames each), factor 0x400 1,404,
  a stream 7,911 (0x401, 0x800, 0x6532, 0x80, 0x3FF, 0x200, 0x1000, random), 0 685; hscale 3,378, render to texture 1,272,
  strips 1,688, clip 3,295, dither 4,960, unaligned bases 1,051; lint-wout PASS.
- `make wout-mutants` PASS (49 s): 16 of 16 in rtl/v1/wout (PLAN's a dither entry, the row counter at 11 bits, the stuck
  row off, strip parity swapped; hscale not halved, the field start without the filter, endStream's last-line row, the
  filter's lead, the line above the first, the filter's sum, the blend weights, the stuck pixel, the clip's max, the
  writer merging across halves, 888 by the physical order, the reader taking P10's word), 5 of 5 in rtl/v1/tbuf (PLAN's
  emptyAfterNoWrite at its own tile and a swap after a no-writeout entry; emptyKeepZ without prevWrittenOut,
  prevWrittenOut by an empty keep-Z, a WRITE not waiting for the write-out).
- `make frames` PASS, 2,713 s wall (CPU 41,722 s, 96 %; the pole ispcache under +vramvary 1,620 s): tb/frames/subset_tests.txt
  (99 pages, at most 8 renders each: the tile subset's tests, M11's TSP pages, scalermeas, sof2sweep, sof2field, fb555,
  scaler, texctl_bank+0e4=900), subset_dumps.txt (33), subset_seeds.txt (1-200 and M11's four race seeds): 336 cases, 865
  renders, each in four configurations (VR_LAT 8; +vramvary 7; VR_LAT 1; VR_LAT 16). In every configuration 850 renders
  equal to refsw3-offline's in every word of video memory, 0 differ; 15 VRAM-race renders (the four seeds, the race
  case's two, and others whose reads touch a word the write-out writes), 2 of them different (texctl_bank+0e4=900 r0, r1:
  64 and 48 words, in every configuration), in their own class; 1,814,036,480 words compared a configuration. lint-core and
  the dual mode (p2-offline-dual on f1wgp_driver: "p2-dual: render 0: equal") PASS. (`cliptest` dropped from the subset:
  KallistiOS only, no PC build.)
- `make frames-mutants` PASS (305 s): the hazard detector off (texctl_bank+0e4=900 under +vramvary), the background not
  shaded with keep Z off (rtl/v1/isp, keepz), emptyAfterNoWrite at its own tile (keepz), a swap after a no-writeout entry
  and the hold off (accbuf): 5 of 5 caught.
- **The earlier gates with the controller in** (agents/m12/gates/all.txt): `make tsp-tile` PASS, 798 s wall (CPU 12,221 s,
  96 %; the pole texctl_bankmip 324 s): 326 cases, 822 renders, 258,771,056 pixels, 174,664 swaps (the controller's), 178,759,680
  write-out reads, 5,114,688,467 checks (now with every word of video memory after every render), 0 failures, 0 VRAM-race
  renders; clocks 8.52 a pixel (the write-out's C5 traffic and the hold in; reported, not gated). `tsp-tile-mutants` 40 of 40
  caught (M11's tbuf ones on the real write-out's reads). tsp-run PASS with M10's counts, its mutants 23 caught, the timing
  ones passing; scaffold, lint (with lint-wout, lint-core on p2_core), fp, isp-edge, isp-depth, isp-setup, refglue-selftest,
  isp-tile-op, isp-tile, sort, tsp-setup PASS and every mutant gate in full PASS with M11's counts.
- **Sampled full gates** (rule 10; M12 has no -full gate of its own: frames-full is M13's): `tsp-run-full SAMPLE=2154751099`
  PASS (62 s: every item, 24,681,778 uvmeas readings of 24,681,778); `isp-tile-full SAMPLE=3446901960` PASS, 1,946 s wall
  (CPU 29,442 s, 95 %; the pole ispcache r0-7 free-running 962 s): every one of the 6,084 phase-halt items (18,386 renders,
  66,820,640 checks) and 169 of 7,401 free-running items (12 always-run, 157 drawn), 0 failures; `sort-full SAMPLE=1482503106`
  PASS, 220 s: 850 of 3,508 items, 20.5 % of the weight, 0 failures; `tsp-tile-full SAMPLE=759787260` PASS, 3,213 s wall
  (CPU 48,884 s, 95 %; the pole sscolor r0-15 361 s), now with the controller, the write-out and the video memory check:
  every case once (6,084 items), the always-run items and the unit sections whole, 6,117 of 7,410 items, 23.2 % of the
  weight, 8,188 renders, 1,169,308,902 pixels, 736,162 swaps, 23,317,969,442 checks, 0 failures; 4 VRAM-race renders (the
  seeds of M11), 0 differences there. The mandatory items alone were predicted over SAMPLE_BUDGET (1,800 s), so no
  optional item was drawn (the sample's WARNING line, D12, as in M11).
- Clocks (reported, not gated: MT7, MT9; ev_tsp from STARTRENDER at VR_LAT 8, no variation): the 865 renders 456,216,808
  clocks; the 33 dumps 0.41-4.66 M clocks a frame, median 1.40 M (4-47 ms at 100 MHz; ISP 1-3 % ahead of the TSP's end);
  a test page of 300 tiles about 0.4 M (1.4 k a tile: the write-out's 1,045-1,357 plus the hold). Under +vramvary the
  same renders take 5.7 times the clocks (2,624,731,378), at VR_LAT 1 / 16 0.97 / 1.06 times. Simulation: ~180 k clk/s
  for the whole core (clang -O3, no PGO).


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

**Status (2026-11-26): done; verified from a clean build (every gate above reproduced, the sampled -full gates on fresh seeds).** `make frames-hw` / `frames-hw-full`
(tools/gate/gate_frames_hw.sh, `tb/mk/frames_hw.mk`), `make frames-full` and `make frames-unit-mutants`
(tools/gate/gate_frames_off.sh `--full`, `--unit-mutants`), `make refsw3-known`, `make ztap-cmp`; scratch and gate logs in
`agents/m13/`. New: tools/gate/capture_hwstream.sh (a run's whole stream, refsw3-offline's pages beside it),
frames_hw_run.sh / frames_hw_cmp.py (one archive item and its verdict), ztap_cmp.cpp (the depth tap's keys in refsw3's
bits, tb/common/zkey.h), frames_mprobe.sh and frames_unit_mutants.py (the M6-M12 lists on one control), the subsets
`tb/frames_hw/subset_*.txt`, `tb/frames/mutants_seq.txt`, `unit_mutant_lists.txt`, `unit_mutant_reasons.txt`. RTL: the
simulation-only depth tap in `rtl/v1/p2_core.sv` (`+ztap`, conventions 7.5), p2_regs' ID / REVISION constants (M12's
open item, ARCHITECTURE 3.1 As built (M13)); the Makefile's `RTLV1` (every unit folder's default under it, so that one
copy of rtl/v1 is one mutant control). Where the tree differs from the text below:
- **refsw3-known has three sections** (tests, sets, dumps: §1.4 As built (M13)); at `4f3efe15` / `a932980` refsw3 is the
  console's in all of them (237 tests, 185 sets, 786 frames, 63 vram_out), so every comparison of this milestone is
  "equal to the console". A partial run (make refglue-selftest's README tests) writes `refsw3_known.partial.txt`: it had
  overwritten the gate's file once (the hw gate then recomputed it, 480 s).
- **The archived sets** are judged by archive_check.sh's steps, not the script (conventions 7.4.3 As built).
- **frames-hw's subset** is make frames' 77 console pages with a fit/hw archive whose whole stream refsw3-offline renders
  in 5 s or less, one set of each measuring test (8), make frames' dumps with a `hw.png` (11) or a `vram_out` (22), both
  zdumps; base and +vramvary (the VR_LAT sweep is make frames').
- **frames-full** takes every git-tracked pvrtest2 / pvrio test run2.sh accepts but dumprender (253; ta-perf, ta-probe,
  ta-tests and yuvconv render nothing), fit/hw's override variants, make frames' race case, and every dump (855: the
  .pvrdmp and the legacy ones), their first 256 renders (FRAMES_FULL_MAX).
- **The sampled -full gates' mandatory items exceed the budget here too** (D12): frames-full's every case once in base
  alone is 58,556 CPU s (13,008 renders), frames-hw-full's 224 tests, 185 sets, 849 dumps and 2 zdumps in base 68,140
  predicted (the cost file's); no optional configuration was drawn. The fit/hw tests whose base item alone is predicted
  over the budget (13 in the final sample: the readback searches, 1,100-6,600 renders at about 4 s a render) are listed
  in the summary and left to the exhaustive run (`FRAMES_HW_MAX_ITEM`). The first frames-hw-full sample's estimates (30
  times refsw3-offline's seconds) were too low for the readback searches (about 4 s a render: depth2_cneg's 2,096
  renders 7,200 s), so it ran ten of them and depth2_cneg hit the item timeout of 7,200 s (p2-offline killed, its pages
  incomplete: the one failing item, not a difference; every other item of that run passed). The estimate is now at
  least 4 s a render, the cost file holds the measured seconds, the item timeout is FRAMES_HW_TIMEOUT (86,400 s), and the
  sample was run again with a fresh seed (below): the items predicted over the budget alone, depth2_cneg among them,
  are left to the exhaustive run.
- **One folder per item**: frames_hw_run.sh gave a scene's vout and z items one run folder (`<root>/<scene>`); the first
  frames-hw run happened to run them apart, the second (ordered by the cost file) ran them together, the vout item cleared
  the folder the z item's tap was writing, and both z items failed (no `ztap.txt`). Tests keep `<root>/<run>`
  (compare2.py's PVR_TESTS layout), the other kinds use `<root>/<kind>/<name>`; frames-hw and frames-hw-full were run
  again.
- **The M6-M12 mutants through the frame subset** (make frames-unit-mutants): 141 of 165 caught; the 24 others only by
  their unit gates, each with its reason in `tb/frames/unit_mutant_reasons.txt` (9 change only state, order or timing
  that never reaches video memory; 15 change values only on inputs the subset lacks). Five are outside p2_core's build
  (tools/gen's four generator mutants, the frame testbench's hazard-detector mutant). The survivors' cost made the gate
  13,986 s (a survivor runs every case: 5,346 CPU s).

**Round 2 (2026-11-25, the verifier's second review; agents/m13/gates/r3).**
- **Readbacks were not compared (blocking).** 36 fit/hw tests search by reading video memory back (depth2_*,
  depthgaps_*, nantr_*, perpmean_*, zovf_*, zword, zstart, zexfil, probes_zs25z); the PC program computes the stream
  after each readback, and pages such as depth2_cneg rows 470 / 471 or depthgaps_zadd page 0, from the answer. The
  capture kept only the last answer and the replay deleted the RTL's answers unchecked, so those regions were refsw3's
  numbers whatever the RTL did. Now capture_hwstream.sh numbers every readback (`rb.<k>.bin`) and keeps refsw3-offline's
  answers' md5 (`readbacks.txt`), frames_hw_run.sh numbers the replay's, and frames_hw_cmp.py compares each (a check
  each, a failure each that differs, the race class after a VRAM-race render), reported per kind and configuration
  (conventions 7.4.3 "Readbacks"). make frames-hw's subset gains the two shortest searches (depthgaps_zadd 24
  readbacks, depthgaps_detneg 58), always_run.txt depthgaps_zadd under +vramvary. Checked by hand: a reference answer
  altered in the capture fails the item ("readback 5 ... differs", 1 failure). frames-full compares every word of video
  memory after each of the first 256 renders, so it covers a search's answers only that far: the readbacks of the 18
  searches left out of the sample (below) are checked only by frames-hw-full's exhaustive run.
- **ztap_cmp's mismatch counted as a tool failure**: frames_hw_cmp.py reads its last line first (a tampered tap: "22 of 34
  depths", 12 failures); a tool failure only without that line.
- **The left-out list was cut at 1,500 characters**: the summary now names every item, per kind.
- **Coverage**: make frames' subset gains fbpack with every page 565 + dither and 4444 + dither (REG_OVERRIDE of
  FB_W_CTRL and FB_W_LINESTRIDE: its dither pages 13-16 are past the 8-render cap); tb/frames/mutants_wout.txt (dither
  entry, dither off, rows as x) caught there. tools/gate/ztap_selftest.sh (make ztap-cmp-check, a step of both hw
  gates) taps a tile twice: the verifier's first-entry-wins mutant of ztap_cmp fails it.
- **The left-out tests depend on the cost file**: the sample leaves out the base items predicted over the budget alone,
  from build/gate/frames-hw-full/cost.txt where it has them, else from the static estimate (4 s a render, 30 times
  refsw3-offline's seconds). The round-2 sample left out 18 tests in base (not round 1's 13: the perpmean_* searches
  had no measured cost): depth2_cneg, depthgaps_bigpos / bigslope / nanprod / rstart, nantr_fin2 / word / wreg,
  perpmean_bg / negedge / negslope / negstore, zovf_creg / neg / neg2 / word, zstart, zword; on a clean tree the
  static estimate decides.
- Results: `make frames-hw` PASS, 2,911 s wall (CPU 42,153 s, 90 %; the pole depthgaps_detneg under +vramvary 2,348 s):
  79 tests (79,673 regions, all the console's), readbacks 82 of 82 refsw3-offline's in 2 tests, 8 sets, 11 hw.png, 22
  vram_out, 2 zdumps, base and +vramvary, 0 failures. `make frames-mutants` PASS (360 s): 11 of 11 caught (the three
  dither mutants new). `make frames` PASS, 3,346 s wall (CPU 48,454 s, 90 %; the pole ispcache under +vramvary 1,638 s):
  338 cases, 881 renders, in each of base / vary / VR_LAT 1 / 4 / 16 866 equal, 0 differ, 15 VRAM-race (texctl_bank+0e4=900
  r0 64 and r1 48 words, the rest 0). `make frames-hw-full SAMPLE=3744104271` PASS, 5,220 s wall (CPU 72,635 s, 87 %; the
  pole depthgaps_search under +vramvary 4,855 s, an always-run line since narrowed to depthgaps_zadd): in base 219 of
  237 tests (340,214 regions, all the console's; readbacks 9,212 of 9,212 refsw3-offline's in the 18 searches that
  fit), all 185 sets, 786 hw.png, 63 vram_out, both zdumps; under +vramvary accbuf, depthgaps_zadd, depthgaps_search
  (140 readbacks) and the zdumps; 0 failures, 0 race items. RTL unchanged since round 1, so the unit gates' round-1
  results below stand. make frames-unit-mutants was not run again in full (13,986 s): its 24 survivors were run on the
  two cases the subset gained (agents/m13/um3: tools/gate/mutants.py --only, the control passing): 0 of 24 caught, so
  the report (141 of 165 caught by frames, the 24 with their reasons) stands.

**Gate results (2026-11-24 / 25, J 16, agents/m13/gates).**
- `make frames` PASS, 3,214 s wall (CPU 47,688 s, 93 %; the pole ispcache under +vramvary 1,619 s): 336 cases, 865
  renders, each in five configurations (VR_LAT 8; +vramvary 7; VR_LAT 1, 4, 16): in every one 850 equal to
  refsw3-offline in every word of video memory, 0 differ; 15 VRAM-race renders, listed with their counts (gen_10,
  gen_85, gen_1156, gen_1295, gen_2013, gen_3079 r0, texctl r7, texctl_bank+0e4=900 r0-r7: 0 words differ but
  texctl_bank+0e4=900 r0 64 and r1 48, in every configuration); 1,814,036,480 words compared a configuration, now the
  queue's per-group check counts (M12 note 3).
- `make frames-mutants` PASS (286 s): 8 of 8 caught, M12's five and M13's three sequencer mutants (a 5-word entry read as
  6 on seed 18; pre_sort per entry for 5-word entries on seed 78; pre_sort from ISP_FEED_CFG for 6-word entries on seed
  28). A fourth (a 5-word entry's punch-through list from another word) reaches no seed of 1-200 and was dropped; the
  first probe tried for the first, seed 6, hid it in the race class (D13).
- `make frames-hw` PASS, 2,665 s wall (CPU 38,635 s, 91 %; the pole texfmt under +vramvary 1,977 s; the final run, after
  the folder fix and the per-group counts; the first, 3,139 s, had the same results): 77 fit/hw tests (79,562 regions,
  150,908,928 pixels a configuration, all the console's), 8 sets
  (15,214,681 readings), 11 hw.png frames (3,379,840 pixels), 22 vram_out (46,137,344 words), the 2 zdumps (36 depths:
  the depth tap equal to the console's read-out everywhere); 0 refsw3-known regions, 0 race pages, 0 input-stale; in
  base and +vramvary; the queue's per-group check counts are the real ones (as M12 note 3 for make frames).
- `make frames-unit-mutants` PASS (reported: 141 of 165 caught, above), 13,986 s.
- Every earlier quick gate and mutant gate in full PASS: scaffold, lint, refglue-selftest, refglue-mutants (12 of 12), fp,
  fp-mutants (92), isp-edge, isp-edge-mutants (36), isp-depth, isp-depth-mutants (29), isp-setup, isp-setup-mutants (16),
  isp-tile-op, isp-tile-op-mutants (27), isp-tile, isp-tile-mutants (23), sort, sort-mutants (11), tsp-setup,
  tsp-setup-mutants (17), tsp-run, tsp-run-mutants (23), tsp-tile, tsp-tile-mutants (40), wout, wout-mutants (21).
- Sampled full gates (rule 10, fresh seeds): `isp-tile-full SAMPLE=198813313` PASS, 2,800 s wall (CPU 40,369 s, 90 %):
  every one of the 6,084 phase-halt items (66,820,640 checks) and 1,017 of 7,401 free-running items (12 always-run,
  1,005 drawn), 25.2 % of the weight, 0 failures; `sort-full SAMPLE=3845980285` PASS, 203 s: 1,869 of 6,622 items, 15.8 %
  of the weight; `tsp-run-full SAMPLE=2096531798` PASS, 64 s: every item; `tsp-tile-full SAMPLE=4051064810` PASS, 3,180 s
  (the unit sections whole, every case once: 6,117 of 7,434 items, 36.8 % of the weight, 8,026 renders, 1,100,075,612
  pixels, 22,058,586,195 checks, 0 failures; 4 VRAM-race renders, 0 differences there; the mandatory items alone over its
  1,800 s budget: the D12 WARNING); `frames-full SAMPLE=417147093` PASS, 6,312 s wall (CPU 68,204 s, 68 %; the pole
  ispcache under +vramvary, all 18 renders, 4,880 s, an always-run line since dropped): every one of the 1,108 cases in
  base (13,008 renders: 12,994 equal, 0 differ, 14 VRAM-race of which 3 differ: texctl_bank+0e4=900 r0 64, r1 48, r13
  80 words; 27,279,753,216 words compared), the always-run items under +vramvary and VR_LAT 4;
  `frames-hw-full SAMPLE=1650643084` PASS, 4,669 s wall (CPU 67,707 s, 91 %; the pole depth2_halfo 3,775 s): in base 224
  of the 237 fit/hw tests (340,275 regions, 562,111,488 pixels, all the console's; 32,971 renders), all 185 archived sets
  (495,262,334 readings), all 786 hw.png frames (231,063,040 pixels), all 63 vram_out (132,120,576 words), both zdumps;
  the always-run items under +vramvary; 0 refsw3-known regions, 0 race pages, 0 input-stale. The 13 tests left out
  (predicted over the budget alone: depth2_cneg, depthgaps_bigpos / bigslope / nanprod / rstart, zovf_creg / neg / neg2,
  nantr_fin2 / word / wreg, zovf_word, zword) wait for the exhaustive run; the first sample (seed 2274194907, 7,830 s)
  ran seven of them to a pass (depthgaps_bigpos, bigslope, nanprod, rstart, zovf_creg, neg, neg2) and depth2_cneg to its
  item timeout (above). **Correction (round 2):** that run did not check any readback (below), so its 224 tests were
  console-compared only where no readback steered the stream; the round-2 sample replaces it.
- Clocks and frame times (reported, not gated: MT7, MT9; ev_tsp from STARTRENDER, VR_LAT 8): make frames' 865 renders
  456,216,808 clocks (VR_LAT 1 / 4 / 16: 0.97 / 0.98 / 1.06 times, +vramvary 5.75 times); frames-full's 855 dumps 1.34 G
  clocks, 0.06-36.0 M a frame (omikron_kayl2 the longest), median 1.28 M, mean 1.57 M: 13 ms a frame at 100 MHz (0.6-360
  ms); frames-full's 13,008 renders 5.37 G. Simulation: about 93 k clk/s a process with 16 at once (1.34 G dump clocks in
  14,318 process-seconds).

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

**As built (2026-11-26).** `make timing-harness` PASS (about 20 s), `make timing-harness-mutants` PASS (3 of 3),
`make timing-fit` (VR_ROW 10, K 319), `make timing-report` (the starting table, timing.md §11.3). The RTL changes beyond
the taps: p2_wout_put's 888 straddle in one clock and its 16-word write FIFO (ARCHITECTURE §3.10 As built (MT0); the die check in §3.12 "MT0"), which
the gate needs (the format dependence); the functional gates are bit-identical. §1.5 As built has the rest.
Round 4 (2026-11-27, the verifier's round 3): `races_var.py` keys a timing line by every number between its kind and
"W" (the 72 `T flush v fb n` lines were dropped before) and judges each line's least (end: min of t1 t2): 40 of the
128 lines vary (timing.md §11.4); `+occlog` gains PTC, IBUF, TILEQ, ENTQ, REGS (27 tracks, conventions 7.5); the
write FIFO's die check is in ARCHITECTURE §3.12 "MT0". The RTL change is simulation only (`` `ifndef SYNTHESIS ``):
lint, timing-harness (32.6 s), timing-harness-mutants (3 of 3, 80 s), timing-report (761 s, the same table) and
frames-mutants (3 of 3, 566 s) PASS; the round-3 runs of every other gate stand.

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
| MT7 | `WO_FIFO` only if T10 / T15 have returned (`VR_ROW` was fitted at MT0 on clip 0 - clip 4, so the 0888 write-out's 1357 is not gated again) | write-out 1045 / 1105, clip; per-tile overlap 1042 / 1096 / 1358 and 1363 / 1041.5; SEC WRITE +1025; keep-Z costs 17 / 32 / 2981 | **Z clear 142, empty tile 335, the 55-90 of a tile with polygons** (T1, T13); ~370 clk not overlapped at 16 bpp (T9) | T1, T9, T10, T13 |
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
| **T1** `TM_STAMP` absolute palette clock (**partially done 2026-11-20**: tim §3.1a; fog-RAM stamp; T1_SET 2 and b-e open, need a safer design: the probe wedged the console) | every hidden latency: STARTRENDER to the first pixel, list and parameter fetch latency, tile k's last pixel to k+1's first, the 335 / 142 / 55-90 split, setup latency | `VR_LAT`, `SEQ_AHEAD`, `OLW_AHEAD`; MT1-MT7 |
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
| ~~F14~~ | closed: isp §15 #7, an infinite determinant gives depth 0, and so does one of 2^126 or more (trsort_recip page 10, trsort_auto, trsort_recip, _recipovf; refsw3 `4f3efe15`). Det 0 with an infinite corner depth is closed (depthgaps_dzinf) | — |
| F15 | tsp §22 #11: stuck alpha with textures, autosort, other clearing events (TODO C8) | blendsel variants |
| F16 | tsp §22 #12-14: SupSample in PT_MV, translucent modifier volumes, two-volume textured, render to texture 1555 / 4444 (TODO C6, C7, C10) | as TODO |
| ~~F17~~ | closed: edge.h's open points (row 31 for an ordinary polygon, the walk's unit, the end rule with `sx < 0`, the hugepos_rules page 11 and hugepos_v5 residuals), measured by edge2_walk, _end, _mult, _row31 and resolved by refsw3 `1040c4aa`. Left: why row 31 (no probe designed) | — |
| ~~F18~~ | closed but for one point: `0de9776b` measured the REG / Big order among other planes' depths (depth2_regmix, _regbelow), the zero rule in the coordinate differences, edges and determinant (depth2_zcoord, _zedge) and the off-grid negative REG slope (depth2_cneg); isp §9.5, §15 #6, #26. Left: a slope of 2^128 or more after the division (isp §15 #6, #11) | a determinant below 1 with finite a, b: zovf_creg variants |

## 4. Requests to other owners (record in `OPEN_ITEMS.md`)

| to | request | needed by |
|---|---|---|
| ~~dreamcast-tests~~ | ~~PC emission of the timemeas timed scenes~~ done by MT0 (D7: timemeas `TM_EMIT`, dreamcast-tests `cab1e28`) | MT0 |
| dreamcast-tests | multi-run race logs for every `*_races` test as data, at least 3 runs (blendpos_races has 1) | MT8 |
| dreamcast-tests | T1-T21, F1-F3, F7-F18 above | MT1-MT9, refsw3 GAPs |
| polly2-rtl spec readers | re-transcribe isp §7-9, §15, num §3 (EdgeHW), H7a, H14, §4 (depth flavour), §8 (A1 edge site, A3, G3-G6, G12) to refsw3 `708fb8cd` (ARCHITECTURE §0.1): done; the edge sections to `4f3efe15` (§0.1b): done; the depth sections to `4f3efe15` (`0de9776b`, `4f3efe15`): done; the TSP sections to `4f3efe15` (`2bee80f2`, `4f3efe15`): done (M9, tsp header, §4.1, §4.3, §4.4, §8.1, §8.2, §9.1, §22) | M9 |
| nulldc3 | a hex depth field (the key, or the word and offset) in the render log (conv G6) | M13 depth diffs |
| nulldc3 | ~~a defined value for MipSelect with `Sdet == 0` (D4)~~: done by `2bee80f2` (dzForce, measured: tsp2_mipdz, tsp2_mipdz2) | M9 |
| nulldc3 | GetFpuEntry's cache (refsw_tile.cpp `fpuCache`) starts each region array entry with every tag 0 (ClearFpuCache's memset), so a tag of 0x00000000 right after it finds slot 0's zeroed entry and is never set up (an all-zero entry: no words, no planes). The console has no such cache; the RTL sets the tag up like any other. Unreachable in practice (skip is at least 1 in every TA list and in all 6,085 captured background tags), but a frame with such a tag would differ from refsw3: a valid bit or an impossible initial tag in the cache (found by M9's random class) | M12 |
| nulldc3 | SB_ISTERR bit 0 in refsw3, if D11 says the RTL models it | MT9 |

## 5. Decisions only the owner can make

| id | decision | proposal |
|---|---|---|
| D1 | Is the TA in scope (conv G7)? p2-offline keeps refsw3-ta in C++, so TA input during a render is never exercised | out of scope for rtl/v1 |
| D2 | Display and SPG stalls in scope (conv G9)? | VRAM-model option only, off for timemeas, on for rendertimes |
| D3 | ~~The FLOAT depth regime~~ | **closed**: unreachable in refsw3 `708fb8cd` (startOnSlopes 1); the RTL has no float regime and asserts it |
| D4 | ~~num §8 DEFECT D1: MipSelect divides by zero for `Sdet == 0`~~ | **closed** by refsw3 `2bee80f2`: measured (tsp2_mipdz, tsp2_mipdz2), a length of all ones and the last level (dzForce); the RTL follows (M9: K8 and dz compared on every such primitive) |
| D5 | Races policy: gate only the deterministic cells? Model run-to-run sources (refresh)? | deterministic cells only, with `races_expected.txt` keyed by probe; refresh as a VRAM-model option |
| D6 | Hangs: reproduce bumphang, the SPAN_SORT_CFG 0x100 / 0x10001 hangs, two empty keep-Z tiles, the SCALER_CTL stall? | yes where a mechanism is stated (bumphang counter, `p2_tbuf_hs`, scaler stall), behind `P2_HANGS=1`; not the 0x100 / 0x10001 hangs (no mechanism, each try costs a power cycle) |
| D7 | timemeas scenes: the owner's PC emission, or our own emitter | **decided** below: the PC emission, built by us in dreamcast-tests |
| D8 | Render log hex depth field (conv G6) | yes |
| D9 | ~~When the depthgaps patch lands~~ | **closed**: landed as `708fb8cd`; the stored depth is the 64-bit key behind `p2_zword_pkg` |
| D10 | Module prefix `p2_`, unit folder names, frame subsets | as conventions.md and ARCHITECTURE §1.1 |
| D11 (new) | SB_ISTERR bit 0 ("ISP out of cache"): a CPU-visible register bit with a measured rule [M ispcache], which refsw3 does not model | model it in `p2_isp_pcache` behind `P2_ISTERR=1`, and ask nulldc3 to add it to refsw3 so that rule 1 (no rule refsw3 lacks) holds; off by default meanwhile |
| D12 (new, M9) | Sampled full gates (rule 10): "all phase-halt items" and "1-1.5 h" do not leave room for the "random subset of free-running segments". The 6,084 phase-halt items in full cost 47,409 CPU s (3,255 s queue wall at J 16, 2026-11-23; 49,681 in M7's exhaustive run, 90,611 in M8's on a busier box), so a 4,000 s isp-tile-full budget draws about 119 of 7,401 free-running segments (1.9 % of their weight) beside the 12 always-run ones, and none on a clean tree | as built: every phase-halt item in full, the random draws whatever the budget leaves (the gates' default). Alternatives: (a) `SAMPLE_PH_RENDERS=8`, each phase-halt case's first 8 renders where it has more (130 cases; a third to a half of the phase-halt weight freed for free-running draws; phase-halt carries the RTL's state, so a case cannot be cut elsewhere); (b) a larger `SAMPLE_BUDGET` (each further hour at J 16 is about 55,000 CPU s; the free-running items in full cost 124,000 CPU s in M7's exhaustive run, 339,000 in M8's) |
| D13 (new, M13; M12's verifier) | The VRAM-race class (§0 rule 4, §1.6) lets a render the hazard detector flags differ by any amount without failing. M13's sequencer mutant "a 5-word entry read as 6" passes scenegen seed 6 that way (the misread region array reads 20 framebuffer words; 8,041 words differ, all in the race class) and fails seed 18. In the tree the gates now list every race render with its difference count per configuration (frames, frames-full, frames-hw); frames-hw's readback check (M13 round 2) puts a readback after a VRAM-race render in the same class, counted per item and per configuration | as built: the class is reported, never a pass or a fail (the rule unchanged). Options: (a) a pinned expected-race list (`tb/frames/races_expected.txt`: case, render, configuration, the difference count or "equal"), failing when a render enters or leaves the list or its count changes; (b) failing when the number of race renders or of differing race renders of a configuration changes from the last accepted run (cheaper, weaker: a mutant that only changes the amount passes) |

**Decided (2026-11-26, delegated by the owner on 2026-11-25: "decide as you see fit; the console is available").**
These answers replace the proposals in the table where they differ.
- **D1:** the TA is out of scope for the CORE milestones (M0-M13, MT0-MT9, MQ and the exhaustive run). The owner has
  made the TA **the follow-up track once the CORE is done**. Keep the CORE's interfaces clean for it: the TA list input,
  and p2-offline's refsw3-ta seam.
- **D2:** as proposed. Display and SPG stalls are a VRAM-model option, off for timemeas and on for rendertimes.
- **D5:** as proposed. Only deterministic cells are gated, through `tb/timing/races_expected.txt` keyed by probe. Refresh
  is a VRAM-model option.
- **D6:** as proposed. Hangs with a stated mechanism are reproduced behind `P2_HANGS=1`; the SPAN_SORT_CFG 0x100 /
  0x10001 hangs are not.
- **D7:** option (a), the PC emission, **built by this project in dreamcast-tests**. timemeas `main.c` is compiled for the
  PC, and each scene is preceded by `echo T <scene>`. Commit it in dreamcast-tests, which is ours (commit regularly,
  push only when asked). It replaces both the §4 request and the `tm_emit.cpp` fallback.
- **D8:** yes. **D10:** as conventions.md. **D12:** as built.
- **D11:** model SB_ISTERR bit 0 in `p2_isp_pcache` behind `P2_ISTERR=1`. Add the same rule to refsw3 on nulldc3 branch
  `skmp/refsw3`, so that rule 1 holds.
- **D13:** option (a). `tb/frames/races_expected.txt` is pinned, with case, render, configuration and the difference
  count or "equal". The gate fails when a render enters or leaves the list, or its count changes. As built (MT0):
  `tools/gate/races_expected.py`, a step of make frames / frames-full (gate `frames`) and frames-hw / frames-hw-full
  (gate `frames-hw`, an item's race renders and its race-class differences); only the cases that ran are checked; built
  with `--write` from the accepted runs; a selftest (a changed count, a dropped and an extra line must fail).
- **Console:** from MT0 on, the MT milestones may run their own console probes (T1-T21; §3 said "never run from here").
  - Use only dreamcast-tests `run2.sh hw=` (or `hwrun.sh`), under `/tmp/pvr_tests/console.lock`.
  - Never run two console jobs at once, and never use `dc-tool-ip -r`.
  - Archive every result in dreamcast-tests like the existing `fit/hw` tests.

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
