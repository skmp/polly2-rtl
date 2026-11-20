# polly2-rtl conventions: layout, naming, build, testbenches, gates

How this repository is built, tested and organised. Engineers should be able to start a unit, its testbench and its
gate from this document alone. The conventions come from what worked in the sister projects: shrike4-rtl (SH7091),
caique-rtl (AICA), wren7-rtl (ARM7DI) and polly2-rtl-lite (the old r6b core). What to take from those projects, and
what not to take, is in [reuse.md](reuse.md). The per-unit specifications are in `docs/spec/`.

State: written 2026-11-20 against nulldc3 `skmp/refsw3` at `2d08a440` (refsw3 clean) and dreamcast-tests at `f7cb4e5`.
Statements marked **[verified]** were checked on those trees. Statements marked **GAP** are not known yet and are
collected in section 13.

---

## 1. Sources of truth and who owns what

| what | where | owner | polly2-rtl's use |
|---|---|---|---|
| Functional rules (every bit of every value) | nulldc3 `refsw3/refcore` (refsw3-core: ISP, TSP, write-out) and `refsw3/refta` (refsw3-ta) | nulldc3 | linked or included **unchanged** into testbenches (section 7.3). Read only. |
| The pinning console tests and their archived console outputs | dreamcast-tests: `pvr-tests/<test>`, `ta-tests/<test>`, `fit/hw/<test>`, `fit/<test>_data`, `fit/*_logs` | dreamcast-tests | inputs and expected outputs of the frame and timing gates (sections 7.4-7.6). Read only. |
| Game frames | polly2-data in the dreamster checkout: `dreamster/polly2-rtl/polly2-data/dumps` (`<scene>.pvrdmp` + `<scene>.hw.png`; older `pvr_regs_<scene>.bin` + `vram_<scene>.bin` + `vram_out_<scene>.bin`; `rendertimes.txt`) | dreamster | frame and timing gate inputs. Read only. |
| Timing | console timing probes (dreamcast-tests `timemeas`, `accbuf`, `*_races`, `ptchunk*`, `spansortcfg`; polly2-data `rendertimes.txt`) and the structure that explains them (dreamcast-tests `pvr-tests/PIPELINE_SHAPE.md`, `pvr-tests/timemeas/REPORT.md`) | dreamcast-tests | cycle gate (section 7.6). refsw3 has no clock. |
| The RTL, its testbenches, gates, timing model and these docs | polly2-rtl | polly2-rtl | everything in this repo |

Rules that follow from this table:

- **The RTL never contains a functional rule that refsw3 does not have.** Suppose the RTL and refsw3 disagree, and the
  RTL is right against an archived console output. Then the finding is a refsw3 gap. It goes to the nulldc3 /
  dreamcast-tests owners as a request: a console test in dreamcast-tests first, then the refsw3 change. Record it in
  `OPEN_ITEMS.md` (section 11). Do not code around it in polly2-rtl, and do not edit nulldc3 or dreamcast-tests from
  here.
- **Timing is the exception.** refsw3 has no clock, so timing rules come from the console timing probes. The RTL must
  produce them through its structure: stage latches, comparators, occupancy, queue depths, hand-overs. Latency
  tables are not allowed (section 4.7).
- A console test belongs in dreamcast-tests, where it can run on a console and in refsw3-offline. polly2-rtl keeps no
  console programs of its own (section 9).

---

## 2. Checkout layout and path variables

The projects are siblings in one folder. dreamcast-tests' scripts already assume this (`run2.sh`: `NULLDC3=${NULLDC3:-$HERE/../nulldc3}`).

```
<root>/polly2-rtl         this repository
<root>/nulldc3            branch skmp/refsw3: refsw3/refcore, refsw3/refta, refsw3-offline, libswirl
<root>/dreamcast-tests    console tests, archives, run2.sh / regress.sh / compare2.py ...
<root>/dreamster          polly2-rtl/polly2-data/dumps (the game frames)
<root>/shrike4-rtl        (only for its dc-tool-ip build, which run2.sh uses for console runs)
```

The top Makefile defines each path once. Scripts derive the same paths from their own location
(`HERE=$(cd "$(dirname "$0")" && pwd)`). Each path can be overridden from the environment:

```make
CWD         := $(shell pwd)
NULLDC3     ?= $(abspath $(CWD)/../nulldc3)
REFCORE     ?= $(NULLDC3)/refsw3/refcore          # pvr_softfp.h, pvr_isp_edge.h, pvr_isp_depth.h, pvr_tsp_plane.h, ...
REFTA       ?= $(NULLDC3)/refsw3/refta
DCTESTS     ?= $(abspath $(CWD)/../dreamcast-tests)
POLLY2_DUMPS ?= $(abspath $(CWD)/../dreamster/polly2-rtl/polly2-data/dumps)
```

No file in this repository may contain an absolute home path, a host name, or a console IP address. That includes
scripts, docs, logs and reports that are meant to be committed. The console address is always given by the caller
(`hw=<ip>`). Before a commit, grep the staged files for `/home/`, the user name, `192.168.` and `claude-`. This is the
rule shrike4-rtl was cleaned to on 2026-10-05.

**Record the reference's revision with every gate result.** refsw3 changes often, and frequently in an uncommitted
working tree. Every gate summary therefore starts with:

```
nulldc3 <git -C $NULLDC3 rev-parse --short HEAD> refsw3-dirty <git -C $NULLDC3 status --porcelain refsw3 refsw3-offline | md5sum | cut -c1-8 or "clean">
dreamcast-tests <rev> ; polly2-rtl <rev or "untracked">
```

---

## 3. Repository layout

```
polly2-rtl/
  Makefile                top level: tool and path variables, VFLAGS, `-include tb/mk/*.mk`. Unit owners do not edit it.
  OPEN_ITEMS.md           open questions with tags, and what would close each one (section 11)
  rtl/v1/
    README.md             the pipeline, and how each measured cost comes out of it (shrike4 rtl/v1/README.md style)
    ARCH.md               files, owners, conventions, the contract (ports, latency, handshakes) of every unit
    p2_core.sv            the top: the CORE (region array to framebuffer) on one VRAM port and one register port
    pkg/                  p2_pkg.sv (shared types), p2_hw_pkg.sv (GENERATED: widths from refcore), p2_regs_pkg.sv (GENERATED: registers, parameter words)
    lib/                  p2_ram.sv (the one RAM primitive), p2_fifo.sv, p2_sfp_pkg.sv (the pvr_softfp.h operations), small shared blocks
    regs/                 register file, FOG_TABLE, PALETTE_RAM
    mem/                  the core's VRAM port: 64-bit word interface, client arbitration
    seq/                  [1] tile sequencer: region array entries, the background polygon
    isp/                  [2] object list walker, parameter fetch, ISP setup, rasterizer, depth / tag buffers, passes, modifier volumes, run cutting
    sort/                 [2b] span sorter (the 96-run window)
    tsp/                  [3] TSP setup, [4] run start, [5] the pixel pipe (plane values, divide, colour, fog, blend)
    tex/                  texture address, fetch, decode (twiddle, VQ, palette, YUV), filter, mip level
    tbuf/                 [6] the two tile (accumulation) buffers
    wout/                 [7] write-out: pack, dither, clip, scaler
  tb/
    mk/<unit>.mk          one make fragment per unit / gate
    common/               p2tb.h (Fails, --shard, --seed, binary vector I/O), vram_model.h (the VRAM image and port model)
    ref/                  refcore_env.cpp, refcore_glue.cpp (section 7.3)
    <unit>/               <unit>_tb_top.sv (flat-port wrapper), <unit>_tb.cpp (driver + lockstep), gen_<unit>.cpp (C++ vectors on refcore), mutants.txt
    frame/                p2_rendercore.cpp (RenderCORE() for p2-offline), p2_frame_top.sv
  tools/
    p2-offline/build.sh   builds the frame-level testbench as a drop-in for refsw3-offline (section 7.4)
    gate/                 the gate scripts (section 8) and verify_all.sh
    gen/                  gen_hw_pkg.cpp, gen_regs.py, their up-to-date checks
    hw/                   README only: console runs go through dreamcast-tests (section 9)
    occview/              the occupancy trace viewer (adapted from polly2-rtl-lite)
  model/
    HANDOVER.md           entry point for a new agent: status, rules, environment, work packages with acceptance tests
    timing/               the clocked C++ timing model / proxy (section 7.6.3)
  quartus/testing/polly2-rtl/   whole-core synthesis harness (section 10)
  quartus/timing/<unit>/        per-unit synthesis / Fmax harnesses (mkproj.sh, lint.sh)
  vivado/testing/polly2-rtl/    when wanted (create_project.tcl, parses the qip fileset)
  docs/                   spec/<unit>.md (the bit-level specification), conventions.md, reuse.md, timing.md
  agents/<role>/          agents' scratch and reports; never build outputs
  build/                  every build output, host executables included (git-ignored)
```

Where things go:

- `build/` holds build outputs only. That includes every compiled host program: put it at
  `build/<same path as its source>`, never next to its source and never in `agents/`.
- `agents/<role>/` holds reports, scratch, converted manuals, verification scratch and workflow results. Never
  `/tmp`: it is wiped on reboot, and prompts that pointed there were lost. A lock file in `/tmp` is fine.
- Generated SystemVerilog that synthesis needs (`p2_hw_pkg.sv`, `p2_regs_pkg.sv`) is checked in, carries a
  `GENERATED: do not edit` header, and has an up-to-date check (section 5).
- `.gitignore` should cover: `build/`, `obj_dir/`, `*.o`, `*.vcd`, `*.fst`, `__pycache__/`, `agents/*/scratch/`,
  the Quartus outputs (`db/ incremental_db/ output_files/ *.qws *.rpt`) and the generated Vivado project files.
  These are the shrike4 and caique lists.

---

## 4. RTL conventions

### 4.1 Language subset

The RTL must pass three tools: Verilator 5.014 (installed), the owner's Quartus 17.0 Standard, and Vivado (the
K26 testing projects). Write:

- SystemVerilog with `logic`, packages for types, constants and pure functions, `always_ff` / `always_comb`, and
  packed structs for words that have fields. One module per file; the file name is the module name (Verilator
  `DECLFILENAME`; polly2-rtl-lite needed an `RTL_EXTRA` list for files that broke this).
- **No default port values.** Every port is connected (Verilator 5.014).
- **Declare a name before its first use, including in port lists.** Vivado makes a name used before its declaration
  into an implicit 1-bit net, silently inside a generate block. polly2-rtl-lite had about 25 of these.
- Simulation-only code (traces, plusargs, `$error` checks, `final` statistics) goes inside `` `ifndef SYNTHESIS ``.
  The Quartus projects define `SYNTHESIS=1`.
- No `$bitstoreal` / `$realtobits` / `real` in the RTL. The RTL is real logic. Testbenches may use host floating point
  only to *print* values, never to compute an expected value: the hardware is not IEEE (section 7.3).

### 4.2 Constructs Quartus 17.0 rejects, and the rewrites

These were met in caique and shrike4 on 2026-11-01. Verilator lint passes all of them, so check new RTL for them
before handing over a Quartus project.

| construct Quartus 17.0 rejects | error | write instead |
|---|---|---|
| `wire my_t x = e;` (typed wire with initialiser) | 10149 / 10170 (parses the type name as the net name) | `my_t x; assign x = e;` |
| unary minus before a cast, `-int'(x)` | 10170 "expecting (" | `0 - int'(x)` (plain `int'(x)` and binary operators before casts are fine) |
| `for (genvar g = 0; ...)` without `generate` | 10170 near `for` | `genvar g; generate for (g = 0; g < N; g = g + 1) begin : name ... end endgenerate` |
| elaboration `$error` inside a generate `if` | elaboration error | wrap the check in `` `ifndef SYNTHESIS `` |
| assignment pattern whose member key names a variable in scope, `'{s16: s16}` | 10734 "s16 is not a constant" | set the fields on a block-local temporary |
| struct-typed parameter passed into a flat `logic [W-1:0]` parameter | 10828 (counts members, not bits) | declare the localparam as `logic [$bits(t)-1:0]`; cast back with `t'(P)` where the struct is needed |

RAM inference fails silently in Quartus 17.0. The failure shows up only as area: check the map report's RAM summary.

- **Lane writes are not inferred.** `if (we[l]) mem[a][l*W +: W] <= d;` with 8- or 16-bit lanes becomes flip-flops
  (caique u_creg alone was 32.8 K registers). Use one array per lane, each with its own write enable.
- **`initial for (...) mem[i] = INIT;` contents are not loaded into M10K.** Bits with INIT = 1 move to flip-flops.
  Store `data ^ INIT`, so that the RAM's power-up zeros read back as INIT (caique `aica_ram`).
- Proven fine in Quartus 17: importing a package in the module header, named patterns, `int'()` and `typedef_t'()`
  casts, `function automatic void` with inout arguments, block-local declarations inside `always` blocks,
  `$bits(type)` widths.

### 4.3 Verilator traps

- **`?:` with an unsigned operand makes the whole expression unsigned.** An arithmetic shift `>>>` inside it then
  silently becomes a logical shift. Use `if`/`else`, or cast every operand with `$signed()`. (shrike4 fpu_vec.)
- **Widths wrap silently.** An example from shrike4: a 23-bit `m + 2^18` wrapped at the last FSRRA half-node. Size
  every sum explicitly, one bit wider than its widest operand. Do not rely on context-determined widths.
  `-Wno-WIDTH` is allowed only in a unit's `.vlt` waiver file, with the reason written there.
- Verilator 5.014 cannot elaborate a pattern under a cast (`t'('{...})`). Use a typed localparam.
- **`$test$plusargs` matches prefixes.** `+nochain` also matches a test for `"nochain_x"`. No plusarg name may be a
  prefix of another (polly2-rtl-lite `peel_core.sv`).
- Testbench C++ never reaches into `dut->rootp->...__DOT__...`. Those names change with every Verilator version and
  every refactor. Taps are explicit testbench ports (under `ifndef SYNTHESIS` when they are not real outputs) or DPI-C
  calls.

### 4.4 Clock, reset, X

- **One clock**, `clk`: the CORE clock, 100 MHz on the console (10 ns; dreamcast-tests `timemeas`, REPORT.md: "clocks
  of the core (100 MHz, 10 ns)"). Anything slower is a clock enable, not a clock. This is the shrike4 rule (Bclk and
  Pclk are enables of Iclk).
- `rst` is synchronous and active high.
- **State that the console keeps across renders is not cleared by the start of a render.** The tile buffers keep
  their pictures across tiles and across renders. In accbuf, keep-Z tiles show the stripes of the tiles two, four and
  six before them, and page 4's cell 6 shows page 3's cell 6. Only what
  the console clears may be cleared: at power-on, at SOFTRESET (which bits clear what is a GAP), and at the points
  `docs/spec` names.
- **X policy.** Every register that can reach an output is reset, or is written before it is read, and the spec says
  which. Normal runs use `--x-assign fast --x-initial fast`. A periodic check rebuilds with
  `--x-assign unique --x-initial unique` and runs with `+verilator+rand+reset+2 +verilator+seed+<n>` over a few seeds.
  Its results must be identical to the normal run. caique found a registered-read RAM that had no data in the first
  frame after power-up this way.

### 4.5 Naming

- **Prefix every module and package with `p2_`** (`p2_isp_setup`, `p2_sfp_pkg`). shrike4's modules are `v1_*`, caique's
  `aica_*`, wren7's `wren7_*`, polly2-rtl-lite's are unprefixed. A whole-Dreamcast Quartus project will contain
  several of these cores, so names must not collide.
- **Name a unit after its stage in PIPELINE_SHAPE.md** ([1] tile sequencer ... [7] write-out). `docs/spec/` is
  authoritative for unit boundaries.
- **Pipeline registers carry their stage**: `s<n>_<what>`, or the stage's name, e.g. `rs_tag`.
- **Handshakes** are `<if>_v` / `<if>_rdy`. A fixed-latency strobe interface states its latency in ARCH.md.
- **Hardware number formats are named by their widths from `p2_hw_pkg`.** Write `logic [P2_ISP_EDGE_SUM_BITS-1:0]`,
  never a bare `[23:0]`.
- **Fields are named as refsw3 / nulldc3 name them**: `PCW`, `ISP_TSP`, `TSP`, `TCW`, `RegionArrayEntryControl`,
  `ListPointer`, `ObjectListEntry`, and register names as in `libswirl/hw/pvr/pvr_regs.h`. dreamcast-tests uses the
  same names, so a field can be searched across all three repositories.
- **Do not rename an existing net, even when its name has become wrong.** Correct the comment, and state that the
  name is historical. The owner tracks designs across bitstreams, waveforms and branches. Renames also inflate
  diffs that are supposed to be about timing only.

### 4.6 Every rule cites its sources

Every functional rule in the RTL has a comment that names two things: the refsw3 function or `*HW` constant it
implements, and the console test that pins it. Example:

```systemverilog
// a depth below zero is stored with 16 mantissa bits, rounded up in size (refcore pvr_isp_depth.h
// StoredDepth::Store, DepthHW::storedNegBits; dreamcast-tests pvr-tests/perpmean_bg)
```

### 4.7 Timing comes from structure, never from tables

This is the owner's rule for shrike4 rtl/v1, and it applies here because "cycle timing is part of the result".

- Every stall and every latency must follow from the structure:
  - where a value is produced, and where it is consumed;
  - queue depths (for example the span sorter's 96-run window, the run queue);
  - which unit is occupied, and for how long;
  - the hand-over points between stages (for example the tile-buffer swap, and the write-out start "when the TSP
    starts on the next tile").
- No per-primitive cost ROM, countdown table or "wait N clocks" constant may decide when something proceeds.
- Next to each such mechanism (comparator, queue, occupancy counter), a comment names the measured number it
  produces and the probe that measured it. Example: `// one run a clock whatever its length (timemeas cut: 0.95-1.02 a run)`.
- A table-driven timing proxy may exist as a *reference to compare against* (section 7.6.3), as shrike4's
  `rtl/timing-proxy` does. It is never the template, and no RTL file includes it.

### 4.8 Lint

- `make lint` runs `verilator --lint-only -Wall` on `p2_core` and every unit top. Every warning fails.
- Waivers are per file, each with its reason, in `rtl/v1/p2_lint.vlt` or `tb/<unit>/<unit>_lint.vlt`. Model them on
  shrike4 `tb/v1_soc_lint.vlt`.
- `make quartus-lint` lints the Quartus project's fileset, in qip order, with `+define+SYNTHESIS=1` (section 10).

---

## 5. Generated files

| file | generator | source | check |
|---|---|---|---|
| `rtl/v1/pkg/p2_hw_pkg.sv` | `tools/gen/gen_hw_pkg.cpp`: C++ that `#include`s the refcore headers and prints one localparam per member of `pvrisp::EdgeHW`, `pvrisp::DepthHW`, `pvrtsp::PlaneHW` and any further `*HW` struct. Example: `localparam int P2_ISP_DEPTH_STORED_BITS = 19;` | refcore `*HW` structs (`static constexpr pvrfp::C<N>`) | `make hw-pkg-check`: regenerate into `build/gen/` and `cmp` against the checked-in file |
| `rtl/v1/pkg/p2_regs_pkg.sv` | `tools/gen/gen_regs.py`: text munging, adapted from polly2-rtl-lite `tools/gen_pvr_regs.py`. C bitfields become SV packed structs, MSB first; register offsets become localparams | nulldc3 `libswirl/hw/pvr/pvr_regs.h`, refcore `core_structs.h`, `refsw_lists_regtypes.h` | `make regs-pkg-check` |
| `rtl/v1/lib/fp/p2_fp_recip_rom.sv` | `tools/gen/gen_recip_rom.cpp`: reads the 512 c digits from the text of `RecipTable`'s string, computes `t` and `n` by the formula, checks both against the compiled `pvrtsp::RecipTable`, prints a case ROM of `{t - 65536, n}` | refcore `pvr_tsp_plane.h` `RecipTable` (num H13) | `make roms-check` (the fp-c and fp gates run it) |
| `rtl/v1/lib/rom/p2_rom_bm_sin.sv`, `p2_rom_bm_cos.sv`, `p2_rom_dither.sv` | `tools/gen/gen_table_roms.cpp`: reads the brace list after each table's declaration (decimal entries only, the exact count) and prints a case ROM | refcore `refsw_tile.cpp` `BM_HW_SIN`, `BM_HW_COS`; `refsw_lists.cpp` `ditherAdd` (tsp 12, 17.3, appendix B) | `make roms-check` |

- The widths in `p2_hw_pkg.sv` are refsw3's measured precisions. The RTL takes widths from this package and nowhere
  else.
- Some `*HW` members are mode switches with more than one value (for example `DepthHW::range`, `startOnSlopes`,
  `PlaneHW::macOrder`). The RTL implements the hardware value only, with an elaboration check under
  `` `ifndef SYNTHESIS `` that fails if the value changes. A refsw3 change then breaks the RTL build instead of
  diverging silently.
- **Hardware arithmetic is never written in Python.** This is the owner's rule from the PVR work (2026-11-16: "write the
  model/probes also in C++"; no Python-to-C++ bridge). Generators and vector makers that need a value are C++ on the
  refcore headers. Python may slice text, emit tables and write reports.
- `tools/gate/verify_all.sh` runs both checks (section 8).

---

## 6. Build

### 6.1 The top Makefile and the fragments

This is shrike4's arrangement. The top Makefile holds only the shared variables and `-include tb/mk/*.mk`. Each
unit's targets live in its own fragment. Fragments may use `$(VERILATOR)`, `$(VFLAGS)`, `$(BUILD)`, `$(CWD)`,
`$(NJOBS)`, `$(NULLDC3)`, `$(REFCORE)`, `$(DCTESTS)` and `$(POLLY2_DUMPS)`. Do not edit the top Makefile to add a unit.

```make
VERILATOR ?= verilator
NJOBS     ?= $(shell nproc 2>/dev/null || echo 4)
BUILD      = build
VFLAGS     = -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -j $(NJOBS) --x-assign fast --x-initial fast
# simulation speed (shrike4 2026-09-26, agents/reports/verilator-perf.md): clang -O3 -march=native
P2_CC      = -MAKEFLAGS OPT_FAST=-O3 -MAKEFLAGS CXX=clang++ -MAKEFLAGS LINK=clang++ -CFLAGS "-O3 -march=native -std=c++17"
```

Target names. `<unit>` is the folder name, e.g. `isp-setup`, `sort`, `wout`:

| target | what |
|---|---|
| `make <unit>` | build and run the unit's quick gate. Under a minute. The last line is `<unit>: PASS` or `<unit>: FAIL`, with the exit code to match |
| `make <unit>-build` | the Verilator build only: `build/obj_<unit>/tb` |
| `make <unit>-full` | every vector and every archived console set (may be long, section 7.8) |
| `make <unit>-mutants` | every planted bug of the unit must be caught (section 7.7) |
| `make <unit>-vcd` | the traced build (`--trace-fst`), into `build/obj_<unit>_vcd` |
| `make units` / `make lint` / `make quartus-lint` / `make hw-pkg-check` / `make regs-pkg-check` | aggregates |
| `make p2-offline` | the frame-level testbench (section 7.4) |
| `make frames` / `frames-full` / `frames-hw` / `frames-hw-full` / `timing` / `timing-full` | the gates (section 8) |

**A new feature gets its own testbench and its own target.** Do not extend an existing testbench to cover it. This is
the owner's instruction, given while working on polly2.

### 6.2 Simulation speed: what is known

- **Compiler.** clang -O3 -march=native, plus PGO for the long-running testbenches. On shrike4 this gave 2.2x on the
  chip testbench and 1.8x on the core harness, with byte-identical results.
- **PGO.** Train the profile **once**, from the default RTL, into `build/pgo/<tb>.profdata`. Every later build reuses
  it: a stale profile only loses speed, never correctness. Retraining on every rebuild was tried on shrike4 and
  rejected (23 minutes). Provide `make <tb>-pgo` to retrain, which deletes the object directory: a new profile only
  reaches objects compiled after it. Switches: `<TB>_PGO=0`, `<TB>_CLANG=0`. Copy the `V1_TB_VERILATE` define and
  the `$(V1_TB_PROF)` rule from shrike4 `tb/mk/v1.mk`. Add PGO only once a testbench is slow; unit testbenches do
  not need it.
- **No `--threads`.** On shrike4, 4 threads were refused (UNOPTTHREADS) and 2-3 threads gave 1.33-1.38x for 2-3x the
  CPU. On polly2-rtl-lite threads were slower. Parallelise across processes instead: shards and cases with
  `xargs -P`.
- **Huge modules.** Use `--output-split 40000 --output-split-cfuncs 2000`, as polly2-rtl-lite did for `peel_core`.
- **Stack.** Verilated settle functions can have frames of several MB, which overflow the default 8 MB stack.
  Whether they do changes as RTL edits move the split boundaries. Every testbench `main()` raises `RLIMIT_STACK` to
  the hard limit first (polly2-rtl-lite 2026-08-19).
- **g++ trap.** At -O2 / -O3 with -march=native, g++ emitted aligned AVX loads (`vmovdqa`) on misaligned members of
  Verilated classes. The result was a SIGSEGV with `si_addr == 0`. If g++ is used, add `-fno-tree-vectorize
  -fno-tree-slp-vectorize`. A flag-only change does not rebuild existing `.o` files: delete the object directory.
- **Machine etiquette.** The box has 32 cores and 62 GB. One workflow runs at a time. Agents run `make NJOBS=8`, and at
  most about 8 simulator processes at once. A gate that blocks the machine for minutes is serialised with
  `flock /tmp/polly2-rtl-gate.lock make <gate>` (shrike4 used `/tmp/shrike4-makev1.lock`).

---

## 7. Testbench architecture

### 7.1 The four gates

| gate | the DUT | reference | inputs | compared |
|---|---|---|---|---|
| **unit lockstep** | one unit (flat-port wrapper) | refcore functions and classes, called from the C++ testbench in the same process. Where an archived console set exists, the console's own readings as well | C++ generators on refcore; dreamcast-tests' exported console sets (`fit/covmeas_data/*.cov`, `fit/uvmeas_data/*.uvm`, `fit/zmeas_data/*.zme`) | every output word, every valid cycle |
| **frame vs refsw3-offline** | `p2_core` inside `p2-offline` | `refsw3-offline` on the same command stream | dreamcast-tests tests (their PC builds' command streams); polly2-data dumps | all 8 MB of video memory after every render; the dumped pages |
| **frame vs console** | `p2_core` inside `p2-offline` | archived console outputs | as above | `fit/hw/<test>` pages (compare2.py `ref`), `fit/<test>_data` sets (archive_check.sh), `<scene>.hw.png`, `vram_out_<scene>.bin`, `fit/zdump_data` |
| **cycle vs console timing** | `p2_core` inside `p2-offline` | console timing probes | timemeas scenes (GAP: section 7.6), `*_races` tests, polly2-data `rendertimes.txt` | clocks from STARTRENDER to each end-of-render event; pictures of the races tests |

Two references are not gates but debugging aids: the clocked timing model (section 7.6.3) and the refcore render log
(section 7.4.4).

### 7.2 A unit testbench

This is the shape of shrike4 `tb/v1_rtc_tb.*` and wren7 `tb/core_tb.cpp`:

- **`tb/<unit>/<unit>_tb_top.sv`** is a flat-port wrapper around the unit. The C++ side drives plain ports; the wrapper
  packs them into the unit's structs. Hardware-shaped memories (VRAM, tile buffers) are answered over DPI-C or by
  explicit ports from a C++ model. Never use hierarchical `rootp` access.
- **`tb/<unit>/<unit>_tb.cpp`** drives the unit one clock at a time. Every clock in which the unit presents a result
  is compared with the reference fed the same input. The reference is refcore (section 7.3), wrapped by a small C++
  "unit model" that holds the unit's state where refcore's state is global. Failures are counted with a `Fails`
  helper, as in shrike4 `tb/v1_clk_tbutil.h`:
  - it shows the first 25 failures in a section;
  - it prints `<unit>: <n> checks, <m> failures` and then `<unit>: PASS` or `<unit>: FAIL`;
  - its exit code is 0 on PASS and 1 on FAIL.
- **Arguments common to every unit testbench:** `--seed S` (printed at start), `--n N`, `--shard k/N`, `--only
  <section>`, `--vec <file>`, `--set <console set file>`, `--trace` (per-clock lines for one case).
- **Sections, in order:**
  1. **Directed console facts.** These are the cases a pinning test measured, with the console's value written into
     the testbench as a literal, independently of refcore. They catch a reference and an RTL that agree on a wrong
     value.
  2. **Archived console sets**, read from dreamcast-tests in place.
  3. **Random and edge vectors against refcore.** Every input class: zeros of both signs, infinities, NaNs, the 2^127
     and 2^-126 limits, and slivers.
  4. **A random stream with random back-pressure and gaps.** The unit's handshakes under stalls must not change any
     value.
- **Values are compared bit for bit, never as `double`.** A refcore `pvrfp::Fp` is compared in a canonical form:
  `neg`, `bad`, the exponent of the leading one (`top()`), and the mantissa left-aligned to the format's width. The
  RTL's packed formats are defined in `docs/spec/numerics*.md`. dreamcast-tests' `model/gen_common.h` helpers
  (`gen::IspDepth`, `gen::TspAttr`, ...) return `double`s: use them for placing cases, not as the reference.

### 7.3 Linking refcore into a testbench

refcore is used unchanged, from `$(REFCORE)`, at one of three levels. The symbol lists below were checked with `nm` on
`nulldc3/refsw3-offline/obj/*.o` (built 2026-11-19 from the clean tree) **[verified]**.

**L1: header only.** `pvr_softfp.h`, `pvr_bits.h`, `pvr_isp_edge.h`, `pvr_isp_depth.h` and `pvr_tsp_plane.h` include
nothing but the standard library. dreamcast-tests' probes use them exactly like this: `g++ -O2 -std=c++17 -I
$REFSW`. A unit testbench adds `-CFLAGS "-std=c++17 -I$(REFCORE)"` and calls `pvrfp::Fp`, `pvrisp::EdgeTile`,
`pvrisp::DepthTile`, `pvrtsp::Plane`, `pvrtsp::Divide`, `pvrtsp::ColorRounded`, ... directly. This covers ISP
setup, edges, depth, TSP planes and the divide.

**L2: the glue translation unit.** Everything else in refcore is `static` / `ALWAYS_INLINE` inside `refsw_tile.cpp`
or `refsw_lists.cpp`, reads the globals `pvr_regs` / `emu_vram`, and needs libswirl headers. Examples:
`TextureFetch`, `DecodeTextel`, `TexOffsetGen`, `TextureFilter`, `ColorCombiner`, `BumpMapper`, `BlendingUnit`,
`BlendMul`, `LookupFogTable`, `FogUnit`, `SpanGen`, `SpanSort`, `KeyAbove`, `PixelFlush_isp`,
`ReadRegionArrayEntry`, `RenderObjectList`.

- `tb/ref/refcore_glue.cpp` `#include`s `refsw_lists.cpp` and `refsw_tile.cpp`. It adds non-static wrappers in
  `namespace p2ref` (for example `p2ref::TextureFilter(...)`) that call the static functions.
- It is compiled **once per build** into `build/ref/refcore_glue.o`, with refsw3-offline's own flags, so that the
  numbers are the same as refsw3-offline's:
  ```
  FLAGS = -fno-operator-names -fpermissive -fno-strict-aliasing -msse4 -O2 -g -DNDEBUG -std=c++20 -w
  INC   = -I$(NULLDC3) -I$(NULLDC3)/libswirl -I$(NULLDC3)/libswirl/deps -I$(NULLDC3)/libswirl/khronos -I$(NULLDC3)/refsw3
  DEF   = -DBUILD_COMPILER=0x30000002 -DCMAKE_BUILD -DDEF_CONSOLE -DFEAT_AREC=0x40000001 -DFEAT_SHREC=0x40000002
          -DHOST_CPU=0x20000004 -DHOST_OS=0x10000002 -DTARGET_NO_OPENMP -DTARGET_NO_WEBUI -DREFSW_OFFLINE
          -DRenderCORE=RenderCORE_sw
  ```
  Take these from `$(NULLDC3)/refsw3-offline/build.sh`. Either parse its `FLAGS=` / `INC=` / `DEF=` lines with `sed`
  at make time, or copy them with a check target that diffs them. They must not drift. `-DRenderCORE=RenderCORE_sw`
  renames refcore's entry point, so that the glue can share a binary with `p2-offline`'s `RenderCORE`.
- Link it together with the rest of refsw3-offline's object set, built with the same flags:
  `$(NULLDC3)/libswirl/hw/pvr/pvr_mem.cpp`, `libswirl/rend/TexCache.cpp` and `libswirl/oslib/posix/threading.cpp`,
  plus `-lpthread -lz`. Verilator 5.014 accepts `.o` / `.a` files on its command line and passes them to the link
  **[verified]**.
- The environment refcore needs from its host (in refsw3-offline these come from `main.cpp`) is provided by
  `tb/ref/refcore_env.cpp`:
  - `u8 pvr_regs[pvr_RegSize]` (the 8 KB register block);
  - `u8* refcore::emu_vram` (video memory in the 64-bit physical layout, below);
  - `f32 f16(u16)`;
  - `void refsw3_offline_read(unsigned)` (refsw3-offline uses it to flag fog-table and palette entries that were
    read but never written);
  - `int msgboxf(const wchar*, unsigned, ...)`;
  - `void os_DebugBreak()`.

  This list is complete for `refsw_lists.o` and `refsw_tile.o` against that object set, apart from libc / libstdc++
  **[verified]**.
- A unit testbench sets the registers it depends on in `pvr_regs` before each call (fog table, palette, TEXT_CONTROL,
  ...), exactly as the RTL unit sees them on its register inputs.
- GAP: the glue has not been compiled yet. Validate it when the first L2 testbench is brought up.

**L3: process level.** The frame gates run `refsw3-offline` as a separate program on the same command stream
(section 7.4). Nothing is linked.

**Video memory layout.** `refcore::emu_vram` and refsw3-offline's `vram` hold video memory in the **64-bit physical
order**: the two 4 MB banks are interleaved every 32 bits. A 32-bit-area address `a` lives at byte

```
pvr_map32(a) = (a & 3) | ((a & 0x3FFFFC) << 1) | (((a >> 22) & 1) << 2)        (8 MB: VRAM_MASK 0x7FFFFF)
```

(`libswirl/hw/pvr/pvr_mem.cpp`; the closed form was checked against the function for every address,
`agents/conventions/map32_check.cpp` **[verified]**). So the 64-bit word `w` at bytes `8w .. 8w+7` is
`{bank 1 word, bank 0 word}`. `tb/common/vram_model.h` aliases that buffer as `uint64_t[1 << 20]` and serves the
core's 64-bit port from it directly. The files `vram.bin`, `vram_<scene>.bin` and the first gzip member of a
`.pvrdmp` are in 32-bit-area order: map them with `pvr_map32` when loading. Better, let refsw3-offline's own loaders
do it (section 7.4).

### 7.4 The frame-level testbench: `p2-offline`

**What it is.** `p2-offline` is refsw3-offline with its `RenderCORE()` replaced by the RTL. It is built from
refsw3-offline's own sources, unchanged:

- `refsw3-offline/main.cpp`, `refsw3/refta/refta.cpp`, `libswirl/hw/pvr/pvr_mem.cpp`, `libswirl/rend/TexCache.cpp`,
  `libswirl/oslib/posix/threading.cpp`, compiled with refsw3-offline's flags (section 7.3);
- **minus** `refsw_lists.cpp` and `refsw_tile.cpp`;
- **plus** `tb/frame/p2_rendercore.cpp` and the Verilated `p2_core`.

The only symbols the rest of refsw3-offline takes from refcore are `refcore::RenderCORE()`, `refcore::rendlog` and
`refcore::rendlog_tiles` **[verified, nm]**. `p2_rendercore.cpp` defines those three.

As a result, `p2-offline` takes refsw3-offline's whole command language with refsw3-offline's own semantics:

- `reset`, `reg`, `w32` / `w64`, `fill32`, `ta` (through refsw3-ta, in C++: the TA is not RTL), `render`, `wait`,
  `dump32`, `regdump`, `tahash`, `tastate`, `scan32`, `png`, `log`, `regs`, `vram`, `pvrdmp`, `save`, `echo`;
- `--lax`, the unwritten-register check, and `--dump <folder | file.pvrdmp>`.

**`RenderCORE()` in `p2_rendercore.cpp`:**

1. **Keep one Verilated `p2_core` instance for the whole process.** Do not reset it between renders: the tile buffers'
   contents carry over on the console (section 4.4). Map refsw3-offline's `reset` and `SOFTRESET` onto the core's
   reset, in the form `docs/spec` gives.
2. **Load the registers.** Present all 8 KB of `pvr_regs` to the core's register port (FOG_TABLE 0x200 and PALETTE_RAM
   0x1000 included), in the order and form the register unit's contract says.
3. **Start the render** by writing STARTRENDER. Clock the core until all three end-of-render events have fired (bits
   0-2 of SB_ISTNRM: video, ISP, TSP), or until a clock limit is hit. The VRAM port is served from `emu_vram` by
   `tb/common/vram_model.h`. Its timing is a GAP (section 13).
4. **Print the timing line** to stderr. run2.sh keeps it in `off.log`:
   `p2: render <n> isp <clocks> tsp <clocks> video <clocks>`, each from STARTRENDER. It feeds the timing gate.
5. **Hung renders.** If the render never ends, print `p2: render <n> did not end` and return. refsw3-offline then
   sets the events as usual. On the console, `pvrio.h` resets the core after 2 s.
6. **Optional, P2_SAVE_EACH=<dir>:** write `<dir>/r<n>/vram.bin` and `pvr_regs.bin` after each render (the `save`
   format).

**Dual mode** (`make p2-offline-dual`) links the L2 glue as well. Each render then runs refcore's `RenderCORE_sw` on
a copy of video memory first, by pointing `refcore::emu_vram` at the copy, and the RTL second. The two are compared
in process, and the first differing word is reported with its tile and pixel. This is the fastest way to localise a
frame difference.

#### 7.4.1 Running dreamcast-tests' scripts on the RTL

These scripts are not modified; their environment variables are enough **[verified on the scripts' sources]**:

- `run2.sh` builds `bash $NULLDC3/$OFFLINE_TOOL/build.sh $OFFLINE` and pipes the test's PC build into
  `$OFFLINE/$OFFLINE_TOOL -`.
- `regress.sh`, `archive_check.sh`, `compare2.py` and `compare_archive.py` read `$PVR_TESTS`.
- `polly2dumps.py` reads `NULLDC3`, `OFFLINE_TOOL` and `OFFLINE`.

So `tools/p2-offline/build.sh <outdir>` builds `<outdir>/p2-offline` (through `make -C <polly2-rtl> p2-offline`). It
finds nulldc3 from its own location (`$(dirname "$0")/../../../nulldc3`), **not** from `$NULLDC3`, which points at
`polly2-rtl/tools` in these runs:

```sh
export NULLDC3=<polly2-rtl>/tools OFFLINE_TOOL=p2-offline OFFLINE=<polly2-rtl>/build/p2-offline \
       PVR_TESTS=<polly2-rtl>/build/pvr_tests JOBS=8
bash ../dreamcast-tests/run2.sh covmeas@lattice8 fbpack off      # -> build/pvr_tests/<test>/page<n>.off.raw
python3 ../dreamcast-tests/compare2.py fbpack ref off            # the RTL against the console's archive (fit/hw)
bash ../dreamcast-tests/archive_check.sh uvmeas <set>            # an archived measuring set, the RTL's readings
```

- `PVR_TESTS` must point into `polly2-rtl/build/`, so that RTL pages never mix with refsw3-offline's pages in
  `/tmp/pvr_tests`.
- `polly2dumps.py` writes to a fixed `/tmp/pvr_tests/polly2dumps`. It must not run at the same time as a refsw3 run
  of the same script.
- `dumprender.sh`, `hwdumps.sh` and `zdumps.sh` use fixed `/tmp/pvr_tests/dumprender` folders. Do not use them for the
  RTL; the gate scripts of section 8 do the same work in `build/`.
- `regress.sh` with no arguments runs every archived test and then `archive_check.sh all`. That is far too much for
  the RTL: the gates name their subsets (section 7.8).

#### 7.4.2 Frame vs refsw3-offline: the comparison

For a dreamcast-tests test, the gate script:

1. Builds the test's PC program once, exactly as run2.sh does:
   `gcc -O1 -Wall -Wno-unused-function -I$DCTESTS/common <defs> -o pc main.c`. It keeps one command stream per
   renderer: `pc <dir>/<tool> > <dir>/<tool>/stream.txt`. Run the program once per renderer, because the stream
   names its `dump32` files inside the folder it was given (`pvrio_folder`).
2. Inserts `save <dir>/<tool>/r<k>` after every render trigger: lines `render` and `reg STARTRENDER <v>`. (pvrio.h
   prints register writes by name.)
3. Feeds each stream to its renderer: `refsw3-offline -` and `p2-offline -`.
4. Compares `vram.bin` per render, all 8 MB, word by word.
5. Reports the first differing word as a 32-bit-area address. When it falls inside the render's framebuffer
   (`FB_W_SOF1`, `FB_W_LINESTRIDE`, `FB_X_CLIP` / `FB_Y_CLIP`, the pack mode's bytes per pixel), it also reports
   (x, y) and the tile. Then it compares the `page<n>.off.raw` dumps of the two runs.

For a polly2-data dump, both tools run `pvrdmp <file>; render; save <dir>`. Legacy dumps use
`regs pvr_regs_<s>.bin; vram vram_<s>.bin; render; save <dir>`.

**Pass criterion:** every word of video memory equal, for every render, in every case of the subset.

#### 7.4.3 Frame vs console archives

| archive | how many (2026-11-20) | comparison |
|---|---|---|
| `fit/hw/<test>/page<n>.hw.raw.gz` + `hw.crc` | 137 tests, plus 5 `*_races` | `compare2.py <test> ref off`, region by region over `labels.txt`. regress.sh additionally requires the run's `off.crc` to equal the archived `hw.crc`: the same register writes, memory and TA input |
| `fit/<test>_data/<set>.{npz,cases.json}` (zmeas: `.cases.json` + `.meas.json`) | covmeas 115 sets, uvmeas 36, zmeas 13, mipmeas 10, uvspan 4, wmeas 4, cmeas 3, uvrun 1 | `archive_check.sh <test> <set>` (the test's `read.py` / `read.cpp`, then `compare_archive.py`) |
| `<scene>.pvrdmp` + `<scene>.hw.png` | 786 frames, all **equal to refsw3-offline in every pixel** (`<root>/agents/nulldc3/rescore/scores.txt`, made by `rescore.py` there: 786 of 786 scenes with 0 pixels different) | `framepng.py raw <scene>.hw.png` gives the console's framebuffer bytes. Compare with `dump32 <FB_W_SOF1 & 0xfffffc> <stride*lines/4> <file>` after the render. The `rescore.py` logic |
| `vram_out_<scene>.bin` | 63 legacy scenes | all of video memory after the render (`polly2dumps.py` logic) |
| `fit/zdump_data/<scene>.zme` / `.txt` | sa2_ingame, shenmue_intro | the depth buffer read out on the console, per pixel (needs a depth tap: `p2-offline` writes the tile depth words at the ISP's last pass) |

Because refsw3 equals the console on all 786 frames, a frame that differs from refsw3-offline also differs from the
console. The console gate is still run on its own, for the archives that refsw3 does not reproduce. Those are listed
per test in the dreamcast-tests README (for example `modvol` 187/192 before 2026-11-19, the `faredge` strips,
`zovf`'s 2^128 cells, `detinf`). The gate prints them separately as `refsw3-known` and does not fail on them unless
the RTL is *worse* than refsw3 there.

#### 7.4.4 The render log: first-difference tokens

refcore's `log <file> [x,y ...]` writes a token stream:
- the frame: `BGTAG`; per tile, `TILE`, `ZCLEAR` / `ZKEEP`;
- the passes: `OPAQ`, `OPAQ_MOD`, `PT`, `PT_CHUNK`, `PT_N`, `TR_PS`, `TR_AS`, `TR_AS_N`, `PASS`;
- per span: `SPAN y x len tag rm`;
- per depth test: `ISP index rm mode depth tag`, `ZFAIL`, `RENDERED`;
- per primitive: `TRIA` / `TRIC` / `STRIP` / `TARR` / `QARR`, `OBJECT`;
- `PIXELS` (the tile's written words).

`p2_core` has a simulation-only tap that writes the same tokens with the same fields, behind `+rendlog=<file>`
(and the `log` command in `p2-offline`). `tools/gate/rendlog_diff.py` aligns the two streams on `TILE` / `PASS` /
`SPAN` / `PIXELS` and prints the first divergence. refcore prints depths with `%f` and corner values with `%a` / `%f`.
Compare those fields within the RTL's own exactness, or use the `PIXELS` and depth readouts. GAP: an exact hex depth
field would need a nulldc3 change, which is the owner's decision.

### 7.5 Debug taps

Taps are simulation only, inside `` `ifndef SYNTHESIS ``, and enabled by plusargs whose names are not prefixes of each
other:

- **`+occlog[=file]`** is the per-clock occupancy trace in polly2-rtl-lite's `POLLY2OCC 1` format:
  - one line `@<cycle> <hex> [v<i>=<n>...]` whenever any unit's 2-bit state (0 waiting for input, 1 busy, 2 blocked
    on output) or a value channel changes;
  - `T` / `X` interval-event tracks for episodes, which are written on the episode's closing edge, so the file is not
    in start order;
  - viewed with `tools/occview` (adapted from polly2-rtl-lite `polly2-core/tools/occview`).

  The occupancy trace is how a timing mismatch is located (section 7.6).
- **`+rendlog=file`** (section 7.4.4).
- **`+fbdump[=file]`**: every framebuffer write with its address, as in polly2-rtl-lite `peel_core.sv`.
- Per-unit taps named `+<unit>trace`.

### 7.6 Cycle level: the console timing probes

#### 7.6.1 What exists, and how it was measured

- **`pvr-tests/timemeas`.** REPORT.md and `tables.txt` hold the results; `fit/timemeas_logs/` holds 64 files (`timemeas_run*.log` and per-topic logs);
  `analyze.py` turns the logs into the tables.
  - Method: one tile in the region array, interrupts and display off, and the TSP's end-of-render bit timed from the
    STARTRENDER write with the CPU's cycle counter (5 ns, so 2 counts are one core clock).
  - A poll turn takes 140 ns, so a reading is late by 0 to 14 clocks. Each scene was rendered 11 times in each of
    three runs, and the least is taken.
  - Slopes over 64-256 objects repeat to 0.1 clock; single differences repeat to about 5 clocks.
  - **The timed scenes exist only in the console build** (`#ifdef _arch_dreamcast`; "A PC run draws the pages and
    measures nothing"). GAP: section 7.6.2.
- **`*_races` tests** (accbuf_races, blendpos_races, keepz_races, ptchunkrun_races, ptchunkcarry_races; archived in
  `fit/hw/<test>`). These are pictures that depend on when units run against each other. Some cells are the same in
  every console run; others differ from run to run.
- **`accbuf`** (lines `T end` / `T flush` / `T stall`, console only), **`ptchunkcost`**, **`ptchunklag`**,
  **`optcull`**, **`spansortcfg`**, **`ispcache`**, and timemeas `TM_ORDER` (the "palette clock": each pixel's
  shading time, read from the picture while the CPU rewrites palette entry 0).
- **polly2-data `rendertimes.txt`.** About 65 legacy scenes on a console: STARTRENDER to the last end-of-render
  interrupt, plus the ISP, TSP and video events, in µs. The values are multiples of 0.08 µs (8 clocks). The
  measurement conditions (display on or off, poll loop) are a GAP.

#### 7.6.2 The timing gate

- **Absolute time.** For a timed scene, `p2-offline`'s `tsp` clocks must satisfy
  `0 <= console_least_counts / 2 - (rtl_tsp_clocks + K) <= 14`.
  - `K` is the latency from the CPU's STARTRENDER write to the core's first clock, plus the time from the interrupt to
    the CPU. It is fitted **once**, on the empty one-tile scene (2695 clocks with a 16-bit framebuffer, 3005 with
    0888). Record its value with its derivation in `docs/timing.md`. It is never adjusted per scene.
- **Differences.** Slope scenes (N objects, N = 64..256) must match to within 0.1 clock per object. Single
  differences must match to within 5 clocks, the measurement's repeatability.
- **Races.** In every cell that is deterministic on the console, the RTL's picture equals the archived console
  page: `compare2.py <test>_races ref off`. Cells that vary from run to run are excluded through a per-test list in
  `tb/timing/races_variable.txt`. The list is built from the archived multi-run logs (for example
  `fit/accbuf_logs` runs 4-6). GAP: that list does not exist as data yet.
- **Game frames.** `rendertimes.txt`, with a tolerance to be fixed once its method is known (GAP).
- **How to obtain the timemeas scenes (GAP).** The scenes are console-only code, so the RTL cannot replay them
  unchanged. Two options:
  - **(a) preferred.** Ask the dreamcast-tests owner for a PC emission of the timed scenes. Each scene would be
    preceded by `echo T <scene>`, and `p2-offline` answers with `T <scene> <least> <middle>` lines in the console
    log's format, in counts (2 per clock, plus `2K`). `pvr-tests/timemeas/analyze.py` then runs unchanged on the RTL's
    log.
  - **(b)** polly2-rtl writes its own C++ emitter of the scenes against `common/pvrtest2.h`. This is a copy that can
    drift; use it only if (a) is refused.

#### 7.6.3 The clocked reference model

A clocked model gives the debugging reference that refsw3 cannot give. It is the counterpart of caique's
`model/cycle-model` (co-simulated clock by clock by `tb/gate_cycle.sh`) and of shrike4's `rtl/timing-proxy`.

- `model/timing/` holds a C++ model of PIPELINE_SHAPE.md's stages, with queue depths and per-stage costs taken from
  REPORT.md. It is validated against `fit/timemeas_logs` first. It prints per-unit events (tile start and end per
  stage, run and drain events of the span sorter, write-out start and end) with clock stamps, in the format the RTL's
  `+occlog` event tracks use.
- `tools/gate/gate_cycle.sh [-j N] [case ...]` runs model and RTL on the same cases and compares the event streams.
  Its output is caique's: one line per case, a summary in `build/gate/cycle.txt`, exit 0 if every case is clean.
- Once the RTL is validated, the RTL itself becomes the reference. The model never decides an RTL mechanism
  (section 4.7).

### 7.7 Every test must be able to fail: mutants

This is the shrike4, wren7 and caique rule: every mechanism has a planted bug that its test catches.

- `tb/<unit>/mutants.txt` lists the mutants, one per line, in the form
  `<id> | <file> | <exact original fragment> | <mutated fragment> | <probe args> | <what it breaks>`.
- `tools/gate/mutants.py` (after shrike4 `tb/v1_mutants.py`) works as follows:
  - it copies the unit's files into `build/mut/<unit>/<id>/`;
  - it refuses a fragment that does not occur **exactly once**, so a mutant can never silently be the original;
  - it rebuilds with the copy, by overriding the fragment's source-list variable, and runs the probe;
  - the unmodified build must pass every probe first (the control);
  - it exits 1 if the control fails or any mutant survives.
- Leave out equivalent mutants, with a note. Judge coverage by mutants, not by run counts. wren7's random-instruction
  soup looked thorough by count and still missed mechanisms until mutants showed it.

### 7.8 Run time, subsets, sharding, reports

- **The subsample rule** (the owner's, 2026-09-23, repeated for caique): any gate over about 5 minutes runs as a
  subset while iterating, and as the full run once, at the end of a deliverable.
  - Each gate has two targets: `<gate>` is the subset and `<gate>-full` is everything.
  - The subset is defined in a file under `tb/<gate>/subset_*.txt`, with every class represented. It is never "the
    first N".
  - Agents gate on the subset. They never run `-full` unless told to.
- Your own verification runs stay well under a minute. Say how long a run takes when it is more than a few seconds.
- **Sharding.** Every testbench that loops over cases takes `--shard k/N`. The make target runs N shards with
  `xargs -P $(NJOBS)`, each writing `build/<gate>/log_<k>.txt`. A merged report decides the result, so a failing
  shard may not stop make (shrike4 `V1_RUN_SHARDS`).
- **Reports.** Every gate writes `build/gate/<gate>/summary.txt`: the revision header of section 2, one line per case,
  and a last line `<gate>: PASS` or `<gate>: FAIL`. Its exit code matches.

---

## 8. The gate scripts to have

All gate scripts live in `tools/gate/`. They are `bash`, find the repository from `$(dirname "$0")`, take `-j N`
and case names, and write to `build/gate/`. Times are estimates, to be replaced by measured ones.

| script / target | runs | pass |
|---|---|---|
| `make units` -> `gate_units.sh [unit ...]` | every unit's quick lockstep (`make <unit>`), then `make lint`, `hw-pkg-check` and `regs-pkg-check`. A few minutes | every unit PASS, lint clean, generated packages up to date |
| `make units-mutants` | every `<unit>-mutants` | the control passes, no mutant survives |
| `make frames` -> `gate_frames_off.sh --subset` | frame vs refsw3-offline (7.4.2) on `tb/frames/subset_tests.txt` (one or two pages per test class) and `subset_dumps.txt` (about 30 polly2-data frames across games and features) | every word of video memory equal after every render |
| `make frames-full` | every pvrtest2.h test and every `.pvrdmp`. Hours | as above |
| `make frames-hw` -> `gate_frames_hw.sh --subset` | frame vs console archives (7.4.3) on the same subsets | every compared region / pixel / reading equal, except the listed `refsw3-known` ones |
| `make frames-hw-full` | all 137 `fit/hw` tests, all archived sets, all 786 frames, all `vram_out` scenes | as above |
| `make timing` -> `gate_timing.sh --subset` | the cycle gate (7.6.2) on the timemeas scenes that can be replayed, the deterministic cells of the `*_races` tests and a few `rendertimes.txt` scenes | as 7.6.2 |
| `make timing-full` | every timed scene and every races cell | as 7.6.2 |
| `gate_cycle.sh` | RTL against the clocked model (7.6.3) | identical event streams |
| `make xcheck` | `--x-initial unique` builds with 4 seeds on the unit subsets and `frames` | identical to the normal build |
| `tools/gate/verify_all.sh` | re-measures every headline number that `rtl/v1/README.md` and `model/HANDOVER.md` state: units, frames subset, frames-hw subset, timing subset, generated-file checks. Tens of minutes | prints each section's verdict and ends `verify_all: OK` or `SOMETHING FAILED` (shrike4 `model/verify_all.sh`) |

The rule from shrike4's HANDOVER applies to every document here: **never trust prose over a number you can re-run.**
A headline number in a doc names the command that produces it.

---

## 9. Console runs

- polly2-rtl does not run the console itself, and keeps no console runner of its own (`tools/hw/` holds a README
  only). Console runs are dreamcast-tests runs: `bash run2.sh <test> hw=<ip>`, then `archive_hw.sh <test>` by the
  dreamcast-tests owner. run2.sh takes `/tmp/pvr_tests/console.lock`, so no two runs ever overlap.
- A question that needs the console becomes an entry in `OPEN_ITEMS.md` (section 11) and a request to the
  dreamcast-tests owner. It says what is measured, which cells, what each outcome would mean for the RTL, and whether
  it is risky (may hang the console).
- Rules learned on the console. Whoever writes the console program must follow them:
  - every wait on the hardware is bounded;
  - a list type is sent only once per page;
  - `run2.sh <test> off` and `run2.sh <test> hw=...` are separate commands, each with its own timeout;
  - a console that stops starting programs needs a manual restart by the user, never a remote reset loop;
  - no two console runs at once.

---

## 10. Synthesis testing projects

The user runs Quartus. Agents prepare the projects and run `make quartus-lint` only. The goal is synthesizable
style plus area and Fmax information. Nothing here has to fit the DE10: polly2-rtl is not cut down to fit, which is
what polly2-rtl-lite is for.

- **Per-unit harnesses, `quartus/timing/<unit>/`.**
  - `mkproj.sh <unit> "<description>" <files...>` writes `<unit>.qpf`, `.qsf`, `.sdc` and `<unit>.files.qip`
    (packages first, then the files, then the hand-written `<unit>_timing.sv`). Copy it from shrike4
    `quartus/timing/mkproj.sh`.
  - Device: Cyclone V 5CSEBA6U23I7. Quartus 17.0.0 Standard. `VERILOG_MACRO "SYNTHESIS=1"`.
  - SDC: one `clk` at 10 ns. Read the real Fmax from the STA Fmax summary.
  - The harness pattern comes from polly2-rtl-lite `quartus/timming_tests` and shrike4:
    - an input register bank that the HPS writes (`wr_en`, `wr_addr`, `wr_data`) drives every input, so the fitter
      cannot fold logic away against constants;
    - every output is captured raw into registers, then XOR-folded into one `digest` pin one clock later, so the fold
      tree is never in a measured path.
  - `lint.sh <unit>...` lints each harness fileset in qip order with `SYNTHESIS` defined.
- **Whole-core harness, `quartus/testing/polly2-rtl/`.** `polly2_rtl_test.sv`, `.qpf` / `.qsf` / `.sdc` /
  `.files.qip`, after shrike4 `quartus/testing/shrike4-rtl` and caique `quartus/testing/caique-rtl`. `make
  quartus-lint` runs from the project directory, so the qip's relative paths resolve as Quartus resolves them:
  ```
  cd quartus/testing/polly2-rtl && verilator --lint-only -Wall ... +define+SYNTHESIS=1 --top-module polly2_rtl_test \
    $(sed -n 's/^set_global_assignment -name SYSTEMVERILOG_FILE //p' polly2-rtl.files.qip)
  ```
- **On the first fit, check RAM inference.** Every buffer must map to M10K / MLAB, not registers (section 4.2).
  caique's first fit had 61 K registers until `aica_ram` was rewritten.
- **Vivado (K26).** `vivado/testing/polly2-rtl/create_project.tcl` parses the same qip fileset, as caique and
  polly2-rtl-lite do. Before a Vivado hand-over, run a declare-before-use check (polly2-rtl-lite
  `agents/scratch/decl_order_check.py` is the existing tool).

---

## 11. Documents and records

| document | holds | style source |
|---|---|---|
| `docs/spec/<unit>.md` | the unit's bit-level rules: formats as widths, rounding direction, operand order, registers, the pinning test per rule, GAPs | written by the spec work |
| `rtl/v1/README.md` | the pipeline, and how each measured cost arises from it, with the measurement and the comparator side by side | shrike4 `rtl/v1/README.md` |
| `rtl/v1/ARCH.md` | files, owners, conventions, each unit's contract (ports, latency, handshake, what it guarantees) | shrike4 `rtl/v1/ARCH.md` |
| `docs/timing.md` | the timing model in numbers: `K`, stage costs, queue depths, each with its probe | timemeas REPORT.md |
| `model/HANDOVER.md` | entry point for a new agent: status table, the ground rules, the environment, work packages with acceptance tests, and how to re-measure (`verify_all.sh`) | shrike4 `model/HANDOVER.md`, caique `model/HANDOVER.md` |
| `OPEN_ITEMS.md` | each open question: what is open, what would close it (console / risky / not measurable), and its tag | shrike4 `OPEN_ITEMS.md` |
| `agents/<role>/` | reports with CONFIRMED / REFUTED / INCONCLUSIVE per claim (caique's swarm rule) | |

Every claim carries a tag. **[M]** measured: a console reading shows it, with the test named. **[I]** inferred: the
simplest structure that explains several measurements. **[G]** guess. **[P]** plausible, not measured. **GAP** not
known. These are PIPELINE_SHAPE.md's tags plus shrike4's.

When a result retracts an earlier statement, mark the old statement **in place** (`[RETRACTED <date>: ...]`). Two
contradictory confident claims must never both stand.

A module header comment must not be trusted over the module body. polly2-rtl-lite's headers were good but several
were provably stale. When a header is wrong, fix it in the same change.

---

## 12. Commits

- Commit only when the owner asks, on a branch named `skmp/<descriptive name>`, in small logical commits.
- Do not commit host details (section 2), built programs, dumps over 1 MB, other projects' sources, or
  `agents/*/scratch`.
- The polly2-data dumps and the dreamcast-tests archives stay where they are. polly2-rtl refers to them by path and
  copies nothing.

---

## 13. GAPs

| # | what is not known | what it blocks | what would close it |
|---|---|---|---|
| G1 | **VRAM timing**: the SDRAM's latency, banks, page and refresh behaviour, and contention with the TA, the CPU and the display reads, as the core sees it | cycle accuracy of texture fetch, parameter fetch and write-out (`vram_model.h` has no measured timing) | console probes (dreamcast-tests TODO D7 "SDRAM and burst settings"); shrike4 `tools/hw/vram-contention` measured the CPU side only |
| G2 | **timemeas scenes are console-only code**; the PC build emits none of the timed scenes | the absolute and difference timing gate (7.6.2) | a PC emission of the scenes in dreamcast-tests (7.6.2 option a) |
| G3 | **`K`**: the latency from the STARTRENDER write to the core, and from the event to the CPU, separately from the 0-14 clock poll latency | absolute timing comparisons | fit once on the empty one-tile scene; a console probe that varies the poll loop |
| G4 | **`rendertimes.txt` method**: display on or off, poll granularity, which tool (dreamster pvr-renderer; its source is not in this checkout) | the game-frame timing gate | the pvr-renderer source, or a re-measurement with timemeas's method |
| G5 | **run-to-run variability per cell** of the `*_races` tests, as data | the races gate | build `races_variable.txt` from the archived multi-run logs; more console runs where there is only one |
| G6 | refcore's render log prints depths as `%f` | exact depth diffs in `rendlog_diff.py` | a hex field in refcore (nulldc3 owner), or depth readouts |
| G7 | **TA in scope?** `p2-offline` keeps refsw3-ta in C++. TA input arriving during a render (multi-buffered frames) is not exercised: the offline render is synchronous | TA and core overlap timing | the owner's decision on a TA RTL; ta-tests (`compare_dumps.py`) would then be its gate |
| G8 | **What SOFTRESET clears** in the core (tile buffers, the accumulation-buffer swap state, the caches), and what the power-on contents are | the reset contract of 4.4 and the `reset` command mapping in `p2-offline` | a console probe: render, SOFTRESET, then a keep-Z tile that shows the buffer |
| G9 | Display / SPG stalls of the core (about 3 µs per line read; timemeas turns the display off) | timing of renders with the display on (the game frames) | out of the CORE's scope unless the owner says otherwise; then a probe with the display on |
| G10 | The L2 glue (7.3) and `p2-offline`'s link are checked at the symbol level only, not yet compiled | the first L2 testbench, and `p2-offline` | the bring-up of either |
| G11 | `TM_ORDER` (palette clock) needs CPU register writes timed against the render; `p2-offline` renders synchronously and has no timed-write command | the span sorter's order gate (2b) at the clock level | a `p2-offline` option of our own (env `P2_TIMED_WRITES=<file>`: clock / register / value lists); the console scenes as in G2 |
