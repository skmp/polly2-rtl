# What polly2-rtl takes from the sister projects, and what it does not

This document goes with [conventions.md](conventions.md). It says, project by project, what to copy or adapt into
polly2-rtl and what to leave behind, and why. For polly2-rtl-lite (the old r6b core) it also lists, per unit, where
the old RTL departs from refsw3 and which console test shows the difference.

Checked on 2026-11-20 against:

| tree | state |
|---|---|
| shrike4-rtl | working tree |
| caique-rtl | working tree |
| wren7-rtl | working tree |
| polly2-rtl-lite | `fdfe77c`; its RTL is identical to dreamster `polly2-rtl` at r6b `51a615d` (`diff -rq polly2-core/rtl`: only two `.bak` files differ) |
| nulldc3 | `skmp/refsw3` `2d08a440` |
| dreamcast-tests | `f7cb4e5` |

Everything listed here is read only. "Take" means copy the file or its pattern into polly2-rtl and adapt it there.
Nothing is edited in the source repository.

## 0. Summary

| source | take | adapt | do not take |
|---|---|---|---|
| shrike4-rtl | Makefile + `tb/mk/*.mk` fragments; PGO / clang build logic; unit-testbench shape and `Fails`; the mutant harness; `verify_all.sh`; HANDOVER / OPEN_ITEMS / README / ARCH document roles; `quartus/timing` `mkproj.sh` + `lint.sh`; `quartus/testing` harness; per-file `.vlt` waivers | the "timing from structure" rule and the timing-proxy idea | Python arithmetic in vector generators; host-FPU references; the SH4 / board / KOS infrastructure; `fpu_vec` |
| caique-rtl | `gate_cycle.sh` shape; `aica_ram` RAM rules; `quartus-lint` from the qip; INTEGRATION-style ownership; "Known approximations" section; swarm-agent rules | RAM_LAT-style latency builds, used for the VRAM timing GAP | AICA specifics |
| wren7-rtl | lockstep testbench shape (`tb/core_tb.cpp`: model drives, RTL follows, state compared at every boundary; chaos mode); `make v1` / `v1-full` split; `agents/rtl_v1/mutate.sh` | | ARM specifics |
| polly2-rtl-lite | debug tooling (`+occlog` + `tools/occview`, `+fbdump`, the plusarg conventions); the Quartus per-stage harness generator; the register-struct generator; a few RTL seeds (section 4.2) | region and object-list field decoding; the translucent / punch-through key walk; the z_keep depth restore; texture address and texel decode; packmode layouts | every arithmetic unit (`fp/*`, setups, raster, interpolation, mip, filter, fog, blend, dither); the peeling architecture; every FPGA-fit structure (DDR arbiter, caches, lane counts, handoff buffers, sort cache, front cull); `golden.txt` as a reference |
| dreamcast-tests / nulldc3 | used in place, never copied: refcore headers (L1), refcore sources through the glue (L2), refsw3-offline's sources for `p2-offline`, the archives, run2.sh / compare2.py / archive_check.sh / framepng.py | | |

---

## 1. shrike4-rtl

### 1.1 Take

| file in shrike4-rtl | what to take | where it goes |
|---|---|---|
| `Makefile` | the top level: `VERILATOR`, `NJOBS`, `BUILD`, `CWD`, `VFLAGS`, `-include tb/mk/*.mk`, and the rule "do not edit the top Makefile" (from `rtl/v1/ARCH.md`) | `Makefile` |
| `tb/mk/v1.mk` | `V1_TB_VERILATE` (one build recipe called with object directory, extra flags and RTL list), the clang `-MAKEFLAGS OPT_FAST=-O3 ... CXX=clang++` switch, the train-once PGO rule (`$(V1_TB_PROF)`), the `v1-pgo` retrain target, `V1_RUN_SHARDS` (sharded runs, merged report) and the subsample split (`v1` vs `v1-full`) | `tb/mk/frame.mk`, and any slow testbench's fragment |
| `tb/v1_rtc_tb.sv` + `tb/v1_rtc_tb.cpp` | the unit testbench shape: a flat-port SV wrapper; a C++ driver that compares every clock against a C++ model fed the same inputs; directed console facts compared verbatim; then random traffic | `tb/<unit>/` |
| `tb/v1_clk_tbutil.h` `struct Fails` | counting checks, showing the first 25 failures per section, the `<unit>: PASS / FAIL` last line, exit code | `tb/common/p2tb.h` |
| `tb/v1_mutants.py` | planted bugs: a fragment must occur exactly once, the control run passes first, each mutant names its probe and what it breaks, the run fails if any mutant survives | `tools/gate/mutants.py` |
| `tb/v1_soc_lint.vlt` | reasoned per-file `lint_off` waivers; lint targets where every warning fails | `rtl/v1/p2_lint.vlt` |
| `model/verify_all.sh` | one script that re-measures every headline number in the docs and ends `verify_all: OK` / `SOMETHING FAILED` | `tools/gate/verify_all.sh` |
| `model/HANDOVER.md` | entry document: status table with numbers, ground rules, environment, work packages each with an acceptance test, retractions marked in place, "never trust prose over a number you can re-run" | `model/HANDOVER.md` |
| `OPEN_ITEMS.md` | open questions with [P] / [M] tags, "what would close it", and console / risky markers | `OPEN_ITEMS.md` |
| `rtl/v1/README.md`, `rtl/v1/ARCH.md` | the split: README explains how each measured cost arises from the pipeline; ARCH lists files, owners, conventions and leaf-unit contracts with signatures | `rtl/v1/README.md`, `rtl/v1/ARCH.md` |
| `quartus/timing/mkproj.sh`, `quartus/timing/lint.sh` | per-unit synthesis projects (Cyclone V 5CSEBA6U23I7, Quartus 17.0, `SYNTHESIS=1`, 10 ns clock), linted as Quartus reads them | `quartus/timing/` |
| `quartus/testing/shrike4-rtl/` | the whole-chip harness: input register bank -> DUT -> raw capture -> XOR `digest` pin | `quartus/testing/polly2-rtl/` |
| `agents/reports/verilator-perf.md` (summarised in conventions.md 6.2) | the measured speed facts: clang + PGO 2.2x; threads do not help | conventions.md 6.2 |

### 1.2 Adapt

- **Timing from mechanisms (`rtl/v1/ARCH.md` intro).** Every latency follows from producer stage, consumer stage,
  bypass and occupancy. A comment next to each comparator names the measured number. For polly2-rtl the mechanisms
  are queues, stage hand-overs and per-tile costs, not register bypasses. The rule itself is unchanged
  (conventions.md 4.7).
- **`rtl/timing-proxy`.** shrike4 has a validated table-driven model that reproduces every measured loop and gives a
  per-cycle issue trace, which v1 is compared against. It is not a template, and no RTL file includes it. polly2-rtl's
  `model/timing` plays the same role (conventions.md 7.6.3). There is one difference: shrike4's proxy was RTL, while
  ours is C++, because its inputs are the timemeas tables.
- **`tools/hw/hwrun.sh`.** It shows the pattern (flock, upload retries, timeout, console address from the environment
  or an untracked conf). polly2-rtl does not run the console itself. dreamcast-tests' `run2.sh` already does all of
  this for PVR tests, with its own lock (`/tmp/pvr_tests/console.lock`), and is the only console path
  (conventions.md 9).

### 1.3 Do not take

- **Vector generators that compute hardware values in Python.** `tb/v1_alu_tb.py` runs `model/timings2/isa.py`. For
  the PVR the owner's rule is the opposite: hardware arithmetic only in C++ on the refcore headers, with no
  Python-to-C++ bridge. shrike4's data-joining Python (`tb/v1_vectors.py`, which reads measured records) is fine as a
  pattern.
- **Host floating point as a reference.** `tb/v1_fp_tb.cpp` uses `-frounding-math`, `-mfma` and the host FPU. That
  works only because the SH4 is IEEE. The PVR's arithmetic is not IEEE (truncation, limited adder reach, 2^127 / 2^128
  limits, `bad` values), so testbenches compare against refcore bit for bit (conventions.md 7.2).
- **The SH4 infrastructure**: `tb/sh4_iss.h`, `tb/dc_board`, the KOS boot, `soc_tb`, the sweep vectors. None of it
  applies here. Neither does `rtl/fpu_vec`: its Booth arrays and aligners are SH4 FIPR / FSCA / FSRRA facts, not
  PVR ones.
- **The flat `tb/` with more than 100 files.** polly2-rtl uses `tb/<unit>/` folders (conventions.md 3).
- **The `v1_` module prefix.** It would collide with shrike4 in a combined project; polly2-rtl uses `p2_`.

---

## 2. caique-rtl and wren7-rtl

### 2.1 caique-rtl: take

| file | what | polly2-rtl use |
|---|---|---|
| `rtl/v1/tb/gate_cycle.sh` | runs every case (or the ones named) in parallel (`-j N`); one line per case into a summary; exit 0 iff every line is clean; `CAIQUE_SEED=n` adds random access delays so accesses land at every phase | the shape of every `tools/gate/*.sh`, and of `gate_cycle.sh` against `model/timing` |
| `rtl/v1/aica_ram.sv` | the one RAM primitive: registered read, each write lane its own RAM, data stored XOR INIT. Quartus 17 then maps every buffer to M10K with zero power-up contents | `rtl/v1/lib/p2_ram.sv` |
| `rtl/v1/Makefile` `quartus-lint` | lint the qip fileset from the project directory with `+define+SYNTHESIS=1` | `make quartus-lint` |
| `rtl/v1/tb/arb_tb.cpp` + Makefile `WREN7 :=` | another repository's model linked **unchanged** by a relative path variable (`../../../wren7-rtl/model/src`) | the same for `$(NULLDC3)` / `$(REFCORE)` (conventions.md 7.3) |
| `INTEGRATION.md` | an ownership table, where findings are recorded, which repository holds combined tests | conventions.md section 1 |
| `rtl/v1/README.md` "Known approximations" | every place the RTL knowingly does less than the reference, listed with the reason | `rtl/v1/README.md` |
| `model/HANDOVER.md` "Rules for swarm agents" | main tree read-only except your report; work in a private copy; CONFIRMED / REFUTED / INCONCLUSIVE per claim; independent re-derivation is worth more than re-running the same tools | `model/HANDOVER.md` |

### 2.2 caique-rtl: adapt

- **`RAM_LAT` and `tb/ramport_all.sh`.** caique builds the RTL at wave-RAM read latencies 1-4 and runs every gate at
  each. The polly2-rtl counterpart: until the VRAM timing is measured (conventions.md GAP G1), the frame testbench's
  VRAM model takes a latency parameter. A sweep over it shows which results depend on the unknown, and the timing
  gate states which value it assumed.
- **Replay parameters (`'P'` records).** caique loads a console run's counter state into the RTL so a co-simulation
  starts where the console was. The polly2-rtl counterpart is the tile-buffer content that carries across renders
  (accbuf, keepz): a frame testbench starts with the buffers the previous render left, never with cleared ones,
  unless the console clears them (conventions.md 4.4, GAP G8).

### 2.3 wren7-rtl: take

| file | what |
|---|---|
| `tb/core_tb.cpp` | lockstep: the model runs and every bus cycle it makes is replayed on the RTL in the same clock. The RTL's request must equal the model's; the RTL gets the model's answer; architectural state is compared at every instruction boundary. Modes: vendor suite, kept random batches, console job suites, `chaos N` (random waits, aborts, interrupts, resets, `ce = 0` clocks). For polly2-rtl units the boundary is the unit's output event (a tile line, a run, a pixel, a written word) and the chaos knobs are back-pressure, gaps and VRAM latency |
| `Makefile` `v1` / `v1-full` | the quick gate (about 45 s) against everything (3392 jobs + 2000 chaos seeds) in parallel, `MISMATCH` lines collected |
| `agents/rtl_v1/mutate.sh` | 23 mutants of the RTL, each caught by the quick gate. Lesson recorded there: a random soup looked thorough by count and still missed mechanisms; check coverage with mutants |
| `rtl/v1/README.md` | interface contracts stated as rules ("the bus outputs come from registers only, so a bus may answer combinationally") |

---

## 3. dreamcast-tests and nulldc3 (used in place)

- **refcore L1 headers** (`pvr_softfp.h`, `pvr_isp_edge.h`, `pvr_isp_depth.h`, `pvr_tsp_plane.h`, `pvr_bits.h`) and
  dreamcast-tests' probes. `model/covprobe.cpp`, `depthprobe.cpp` and `tspprobe.cpp` are working examples of calling
  refcore classes from a standalone C++ program: copy their style, not their code. They also consume the console
  sets exported as flat binaries:
  - `fit/covmeas_data/*.cov` (96 files, "PVRCOV2");
  - `fit/uvmeas_data/*.uvm` (36, "PVRUVM1");
  - `fit/zmeas_data/*.zme` (13, "PVRZME1").

  Their layouts are in `model/export_cov.py`, `export_uv.py` and `export_z.py`. Unit testbenches read the same files
  in place (conventions.md 7.2).
- **`model/gen_common.h`** places cases with the model (`gen::Covered`, `IspDepth`, `SpanStart`, `TspPlane`,
  `TspAttr`, `TspColor`). Include it from `$(DCTESTS)/model` for C++ generators. Its helpers return `double`, so they
  are not a bit-exact reference.
- **refsw3-offline's sources** become `p2-offline` with `RenderCORE()` replaced (conventions.md 7.4). The other
  refcore sources are used through the L2 glue. The symbol boundaries were checked with `nm`.
- **Scripts**:
  - `run2.sh`, `regress.sh`, `archive_check.sh`, `compare2.py` and `compare_archive.py` are driven through
    `NULLDC3` / `OFFLINE_TOOL` / `OFFLINE` / `PVR_TESTS`;
  - `framepng.py` (`raw`, `regs_of`) and the comparison logic of `polly2dumps.py` and of `<root>/agents/nulldc3/rescore/rescore.py` serve the dump gates;
  - `pvr-tests/timemeas/analyze.py` serves the timing gate.

  None are copied. The gate scripts call them, or reimplement only their few comparison lines where they hard-code
  `/tmp/pvr_tests` folders.
- **`pvr-tests/PIPELINE_SHAPE.md` and `pvr-tests/timemeas/REPORT.md`** describe the structure and the measured costs.
  They are the starting point of `docs/timing.md` and `model/timing`. Their [M] / [I] / [G] tags carry over.

---

## 4. polly2-rtl-lite (r6b)

### 4.1 What it is

The cut-down FPGA core for the DE10-nano, "largely based on / ported from refsw2", released as r6b. It is fitted to
an FPGA with:
- RAS_LANES = 8 raster lanes;
- one 64-bit DDR3 read channel behind a 6-client arbiter;
- texture and VQ caches;
- layer-peeling passes for the translucent and punch-through lists;
- several performance filters.

Its refsw2 reference predates every dreamcast-tests finding from 2026-11-15 on. Its value to polly2-rtl is:
- its tooling;
- a handful of decode and address blocks whose rules are hardware facts that refsw3 still has;
- a record of which structures were tried.

Its arithmetic is not refsw3's anywhere it was measured.

Its module headers are unusually good documentation, but several are provably stale. The body wins. Known stale
headers:
- `peel_core.sv` "record prefetcher" (none exists);
- `tex_unit.sv` DDR port count (three, not two) and "untextured pixels bypass the fetch" (they do not);
- `triangle_setups.sv` instance count;
- `sort_cache.sv` sizes;
- `tsp_shade_v2_pp.sv` INTERPLAT 9 (it is 10);
- `fp_rcp_faster.sv` product widths;
- `isp_raster_line.sv` LAT.

### 4.2 Unit by unit

Verdict: **seed** = start the new unit from this file's structure and decoding and re-check every rule against
refsw3. **structure** = read it for the shape of the problem, write the unit new. **no** = do not use.

| lite file(s) | role | new unit | verdict | why |
|---|---|---|---|---|
| `lists/region_array_parser.sv` | region array walk, states clear -> op -> pt -> tr -> flush | `seq` | **seed** (field decode) | Its entry layout (control bits tilex[7:2], tiley[13:8], no_writeout 28, pre_sort 29, z_keep 30, last_region 31; ListPointer ptr[23:2], empty 31; 20- or 24-byte entries) is the hardware's, the same as refcore `RegionArrayEntryControl` / `ListPointer`. Replace the rest: the FPGA DDR 8-word window reader; the 16384-tile runaway guard; **skipping the opaque_mod / trans_mod lists**; the state sequence, which must follow refsw3 `RenderCORE` (keep-Z chains: an empty keep-Z entry after a not-written entry writes out at the place of the entry before, keepz; PT chunks; `TR_AS_N`; the background polygon in every entry, also one that draws nothing, timemeas) |
| `lists/object_list_parser.sv` | object list walker | `isp` (list walker) | **seed** (field decode) | The Tstrip / Tarray / Qarray / Link encodings equal refcore `ObjectList*`. Replace its memory reader. Add refsw3's rules (`ObjectListHasPrimitive`; the cost of 20-31 clocks per list pointer, timemeas) |
| `isp/isp_primitive_iterator_pf.sv`, `spanner/record_fetcher.sv` | parameter fetch, vertex decode | `isp`, `tsp` | structure | The vertex decode must be refsw3's `decode_pvr_vertex` / `decode_pvr_vertices` (two volumes, `TcwRaster`, skip, shadow). The prefetch and the sort-cache skip are FPGA performance features |
| `setup/isp_setup_streamed.sv` | ISP setup (edges, 1/w plane, cull) | `isp` (setup) | **no** (arithmetic), structure (schedule) | Lite anchors each constant at the smaller-magnitude endpoint, uses full 1.23 mantissas and its own Newton reciprocal, and culls any triangle with an inf / NaN coordinate (`NFIN`). refsw3 / console: 24-bit truncating products and sums, adder reach 25, sums `(v1 + v2) + v3` for slopes and determinant and `(v1 + v3) + v2` for the constant; depth at the tile's first pixel `((a x0 + b y0) + c) * inv`, start and slopes as 20-bit floats, 21-bit pair, 26-bit tile grid, 19-bit stored mantissa (`DepthHW`; zmeas, zstart, covmeas); inf / NaN corners drawn by exact rules (hugepos, faredge, nantr_*, zovf, zspec). Lite's II = 15 schedule on one shared set of units is close to the console's 16 clocks per triangle (timemeas) and is worth reading |
| `setup/tsp_setup_stream.sv` | TSP setup (10 planes) | `tsp` (setup) | **no** | Its header says it is "MORE accurate" (full mantissa, no truncation). The console keeps the coefficients as 16-bit floats cut toward zero; an attribute plane is `a_i * (w_i * d)` from the 1/w plane's products; the constant of an attribute plane is summed `(v1 + v2) + v3` and that of the 1/w plane `(v1 + v3) + v2` (`PlaneHW`; uvmeas, wmeas). The console sets up about one primitive per 39-64 clocks (timemeas), lite about 35 |
| `isp/isp_raster_line.sv`, `isp/coord_f32.sv` | coverage + 1/w per pixel | `isp` (raster) | **no** | Lite evaluates edges as floats at absolute coordinates (16-bit significand products) with a `next_down` top-left trick, RAS_LANES pixels a clock. The console uses per-tile edge functions on `EdgeHW` (start / slope widths, block exponent `blockAdd 6`, `zeroShift`, `tieShift`, 2^128 saturating to 2^127, the row range; covmeas, hugepos, faredge) and rasterises **one tile line (32 pixels) a clock** (PIPELINE_SHAPE [2]) |
| `isp/isp_depth_cmp_lp.sv` | ordered walk compare for TR autosort and PT | `isp` (passes) | **seed** (the walk) | The composite key `{depth, tag sort bits}` and its two walks, smallest key above the reference (TR, far to near) and largest below the boundary (PT, near to far), are exactly refcore `KeyAbove` (refsw_tile.cpp; sort, dumprules pages 0-1, trtie). refsw3 took it from lite. **Replace the depth half of the key**: lite stores 31-bit sign-stripped depths compared unsigned. The console compares the stored word as a signed 32-bit integer with a negative depth's fraction bits inverted; negative depths exist; a NaN is an ordinary number; -0 = +0 (zsign, bgspec, bgneg) |
| `isp/isp_depth_cmp.sv` | opaque depth compare | `isp` | structure | The eight depth modes must follow refcore `PixelFlush_isp` on the integer compare key above |
| `buffers/peel_tile_buffer.sv`, `isp/tile_ram.sv` | depth / tag tile buffers, z_keep restore | `isp` (buffers) | **seed** (the z_keep rule) | The restore of the sorted translucent layer's depth for a following keep-Z entry is refcore `SaveDepthAt` (keepz page 3; refsw3 cites lite). The 150-bit lane packing, LANES banks and 31-bit depths are FPGA-shaped and must be redone at the console's widths and line-a-clock access |
| `buffers/sort_cache.sv` | "fully rendered" triangle filter | — | **no** | A lite performance filter. The console's **translucent sort cache** is a different, measured structure: ISP_FEED_CFG size bits 23..14; out-of-cache error from L = size / 8 full-tile layers (ispcache) |
| `buffers/taginvw_tile_buffer.sv`, `dense_span_buffer.sv`, `span_buffer_v2.sv`, `triangle_setups.sv`, `spanner/spanner_v2.sv` | ISP -> TSP hand-off, span generation, setup ring | `sort`, `tsp` | **no** | Lite cuts 4 aligned pixels a clock, deduplicates tags through a direct-mapped map and bump-allocates a ring of setups (window 512, TI_COPIES tile images). The console cuts **one run a clock whatever its length**, queues about 512 runs, and its span sorter is a **96-run window** in which the oldest run's primitive drains all its runs, one primitive at a time per tile. The TSP keeps about 12-16 primitives set up (timemeas order and cut scenes; spansortcfg; PIPELINE_SHAPE [2b]) |
| `tsp/tsp_shade_v2_pp.sv`, `tsp/stage_interp.sv` | per-pixel shading pipe | `tsp` | structure (stage list only) | Lite evaluates every plane per pixel, `(ddx x + ddy y + c) * W` with `W = 1/invW` from a Newton reciprocal. The console evaluates a plane per **run**: `C + floor(A x0) + floor(B y)` at the run's first pixel, then `+A` per pixel, on a 22-bit grid under the tile's exponent E, the value cut to 16 bits. It divides by a 16-bit reciprocal of W's mantissa (cut down) with the product cut at 17 fractional bits (`PlaneHW`; uvspan 411,287 of 411,287, uvmeas, wmeas). Colours are fractions times 2^-8 (cmeas) |
| `tsp/tex/tsp_miplevel.sv` | mip level | `tex` | **no** | An exponent-domain approximation of refsw2's mip calculation. refsw3 has the measured rules: mipmeas, mipk (the precision of K), DCalcCtrl, trimin (nothing past the 1x1 level), trifade, mipbil |
| `tsp/tex/tex_addr*.sv`, `tex_base_addr.sv`, `tex_add_mip.sv`, `tex_addroffsgen_ib.sv` | texel address | `tex` | **seed** | The same `TexAddressGen` / `TexOffsetGen` / `twop` / `MipPoint` / stride math as refcore. Re-check: TEXT_CONTROL's bank and endian bits (texctl, texctl_bank*, texctl_addr); the stride select at TCW bit 25 (the old mip test set bit 21); the VQ codebook offset; the 64-bit area mapping; V of a mipmapped texture declared shorter than wide (texfar_decl); coordinates that never overflow (texfar*) |
| `tsp/tex/tex_decode.sv` | texel decode (1555 / 565 / 4444 / YUV422 / bump / palette 4 / 8 / VQ) | `tex` | **seed** | Follows refsw `DecodeTextel`, including the YUV422 byte-lane contract fixed in both on 2026-07-23 and the 8888 palette pass-through fix. Re-check against refsw3 `DecodeTextel` / `TextureFetch` and yuvbil |
| `tsp/tex/tex_filter.sv` | point / bilinear | `tex` | **no** (arithmetic) | Lite uses a delta-form lerp with raw 8-bit weights, "<= ~1 LSB short of exact". refsw3 `TextureFilter`: coordfix (texel and weight from the coordinate), alphafilt, bumpclamp, mipbil, SupSample's four points (supsample, ss*) |
| `tsp/tex/tex_cache*.sv`, `tex_fetch4*.sv`, `tex_mem.sv`, `tex_unit.sv` | texture caches over DDR3 | — | **no** | FPGA memory-system artefacts. The console's texture path and its timing are unmeasured (conventions.md GAP G1) |
| `tsp/color_combiner.sv` | shading instruction (texenv) + offset | `tsp` | structure | The four `ShadInstr` cases and the saturating offset add have the right shape. The `u8_256` rescale and the rounding must follow refsw3 `ColorCombiner`. **No bump mapper** ("No bump"; refsw3 `BumpMapper`: bumpfn, bumpbil, bumplight, bumpiso) |
| `tsp/fog_lut.sv`, `tsp/fog_blend.sv`, fog part of `buffers/reg_file.sv` | fog | `tsp` | **no** | Lite multiplies FOG_DENSITY as an f32 by the full-float 1/w and blends table entries with raw 8-bit weights, "~1 LSB low" by its own "house convention". refsw3 `LookupFogTable`: FOG_DENSITY is an 8-bit mantissa with a signed 8-bit exponent, times the **TSP's own 16-bit 1/w** (exact in 24 bits), clamped to 1 .. 256 - 2^-16; the index is the exponent's low 3 bits plus 1 and 4 fraction bits, the blend the next 8 bits (fog, tspw); `FogUnit` per-vertex fog `(c (256 - a) + f a) >> 8` (sc_ingame) |
| `tsp/tsp_blend.sv` | alpha blend | `tsp` | **no** (arithmetic) | Lite uses "imperfect *255/256 rounding" and does not model SrcSelect / DstSelect ("secondary accumulation buffer ... NOT modelled"). refsw3 `BlendMul`: 255 counts as 256, an inverted factor is `256 - k`, so a factor and its inverse sum to 256 (blend 4096 / 4096). The stuck alpha and buffer-2 source come from blendsel, blendsel2 and blendpos (settings 193 / 196 are a console blend-unit bug). The two accumulation buffers swap after every written tile (accbuf) |
| `vo.sv` | write-out: pack, dither, hscale | `wout` | **seed** (packmode layouts only) | Its layouts agree with fbpack: 0555 bit 15 = `fb_kval[7]`; 0888 top byte = `fb_kval`; 1555 A = alpha >= `fb_alpha_threshold`; 4444 alpha quantised like the colours. **Replace dithering**: lite computes `q = (c * max + T) / 255` with a Bayer*16+8 table. The console *adds* one 4x4 table before dropping the low bits, saturating: the table for 4 bits, half of it (rounded down) for 5 bits, a quarter for 6. Rows y = 0..3 indexed by x & 3: `5 13 7 15 / 9 1 11 3 / 6 14 4 12 / 10 2 8 0` (fbpack, 5,222,400 of 5,222,400 pixels). Re-check hscale against scalermeas / scalertile. The vertical filter (Y_COEFF, ycoeff) is missing. Write-out costs (1045 / 1105 / 1357 clocks a tile, "also when the clip removes every pixel", timemeas) are not modelled |
| `fp/*.sv` | non-IEEE float32 units | `lib` (softfp) | **no** | Lite's units are float32-format, denormals-are-zero, with no inf / NaN, exponent overflow saturating to 0xFE, and unlimited alignment; `fp_mul16` truncates multiplicands to 16 bits; `fp_rcp_*` are Newton reciprocals. refsw3 `pvr_softfp.h`: explicit widths per operation (24-bit products and sums), adder reach 25 (the smaller operand is dropped beyond it), infinities and NaNs carried as `bad` with defined sums and products, 2^128 and above an infinity in the setup's numbers, the edge start saturating at 2^127, the TSP's reciprocal table. Only the truncation direction (toward zero) is shared. `p2_sfp_pkg` mirrors `pvr_softfp.h` operation by operation instead (conventions.md 3) |
| `buffers/bram_sdp.sv`, `bram_tdp.sv`, `delay_ram.sv` | RAM primitives | `lib` | structure | Superseded by `p2_ram` with caique's rules (lane arrays, data XOR INIT) |
| `buffers/reg_file.sv`, `gen/pvr_regs_gen.svh`, `gen/tsp_pkg.sv`, `tools/gen_pvr_regs.py` | registers and parameter-word types | `regs`, `pkg` | **take the generator** | `gen_pvr_regs.py` (C bitfield unions -> SV packed structs MSB first, `OFF_<NAME>` offsets, tables excluded) is retargeted from minicast's `pvr_regs.h` to nulldc3's `libswirl/hw/pvr/pvr_regs.h` plus refcore `core_structs.h` / `refsw_lists_regtypes.h` (conventions.md 5). Lite's register file is not taken (fog precompute, FPGA tables) |
| `peel_core.sv` | the top: peeling FSM, DDR arbiter, caches, chaining, front cull, two-layer peel | — | **no** (architecture), **take the debug taps** | The console has its own pass structure (OP, then PT passes in chunks, then TR presort or per-pixel sort with `TR_AS_N` passes; modifier volume passes with stencil summarise OR / AND), run-based hand-off and per-tile stage overlap. The taps worth keeping are `+occlog`, `+fbdump`, `+shadedump` and `+ptx`; their prefix-naming rule is in conventions.md 4.3 |

### 4.3 Features refsw3 has and lite does not

These must be specified from refsw3 and its tests; lite offers no starting point for them:
- modifier volumes of every kind: opaque, punch-through, translucent; cheap shadow; intensity shadow
  (`FPU_SHAD_SCALE`); two-volume polygons; stencil summarise OR / AND (modvol, volrun, optrun, uvrun);
- the secondary accumulation buffer, SrcSelect / DstSelect, and the buffer swap (accbuf);
- SupSample (supsample, supsample2, ssmip, sscolor, ssvol, ssrare);
- DCalcCtrl, the mip rules (mipmeas, mipk*, trimin), bump mapping (bumpfn, bumpbil, bumplight, bumpiso,
  bumpclamp);
- FPU_CULL_VAL and FPU_PERP_VAL (cullval, perpeq, perpval, perpmean_*);
- punch-through chunks (ptchunk*, ptlayers, ptruns);
- SPAN_SORT_CFG (spansortcfg), ISP_FEED_CFG's translucent cache (ispcache), TEXT_CONTROL (texctl*);
- the half pixel offsets (halfofs, halfofs2), the vertical scaler filter (ycoeff);
- every inf / NaN / overflow regime: zovf*, zspec, zbad*, nantr_*, bgspec, bgneg*, bgbig, texfar*, faredge*,
  hugepos*.

### 4.4 Lite tooling: take, adapt, leave

| item | verdict |
|---|---|
| `polly2-core/tools/occview/` + the `+occlog` tracer at the end of `peel_core.sv` (format `POLLY2OCC 1`: RLE `@<cycle> <hex> [v<i>=<n>]` lines, `R` / `D` render marks, `T` / `X` interval tracks written at the closing edge) | **take** the format and the viewer; write the tracer anew for the new units. Lessons from it: keep hot per-cycle values out of the value channels; prefer `T` / `X` tracks for anything with a duration and an identity; sample combinational levels, not their registered copies; cross-check each track against the unit's own `final` statistics; sort `X` lines before searching them |
| `quartus/timming_tests/gen_stage_harnesses.py` | **adapt** (it is the origin of shrike4's `mkproj.sh` pattern): one generated project per stage, input bank -> stage -> raw capture -> digest |
| `polly2-core/Makefile` `golden-check` (`xargs -P` per scene, a `polly2-data` symlink under `build/`, OK / FAIL per scene) | **adapt** the loop shape only. **Never** use `polly2-data/dumps/golden.txt` (md5s of lite's own renders) or the lite `.bmp` references as expected values: they record lite, not the console |
| `tb/frontend_tsp_lp_tb.cpp` | **no**. It reaches into `dut->rootp->...__DOT__vram`, loads only part of the register block, re-interleaves the 32-bit view by hand and writes BMPs. `p2-offline` replaces all of it (conventions.md 7.4) |
| `tb/sim_ddr_fb.sv` `+ddrvary` (random DDR latency) | **adapt** the idea as a robustness mode of `vram_model.h` (random extra latency must not change any value). It is never the timing reference |
| the tex unit testbenches (`tex-addr`, `tex-uv`, `tex-filter`, `tex-combiner`) | **no**: bit-rotted since lite's rtl reorganisation (wrong paths; 8/1536, 0/256, 0/1024 against current modules) |
| `tools/analyze_*.py`, `lod_analyze.py`, `scan_arrays.py` | **no**: lite-performance analyses |
| lite build flags (`--output-split 40000 --output-split-cfuncs 2000`; no `--threads`) | **take** (conventions.md 6.2) |
