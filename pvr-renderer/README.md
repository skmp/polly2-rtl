# pvr-renderer - replay the polly2-data dumps on a real Dreamcast

A KallistiOS app that takes the same VRAM + register snapshots the verilator
harness and `driver/polly2_dumpload.c` (DE10-Nano) use, renders each one on
real PowerVR2 silicon, times the render, and writes the resulting VRAM back to
the host. Same inputs, three renderers, directly comparable outputs.

For every `vram_<scene>.bin` / `pvr_regs_<scene>.bin` pair in the dump
directory it:

1. streams the 8 MB VRAM image into the console's VRAM,
2. programs the captured PVR register file,
3. fires `STARTRENDER` and times it from the write to the last end-of-render
   interrupt,
4. reads all 8 MB of VRAM back out to `vram_out_<scene>.bin`,
5. appends one line to `rendertimes.txt`.

Everything is read and written over dcload (`/pc/...`), so the results land in
`polly2-data/dumps` next to the inputs. Nothing is stored on the console.

## Build and run

```sh
source /opt/toolchains/dc/kos/environ.sh
make
./run.sh                 # all scenes
./run.sh daytona,jgr     # only scenes whose name contains one of these
```

`run.sh` builds, then retries the dcload upload until the console takes it (the
first few attempts are often ignored) and streams the console output to
`dctool.log`.

Knobs (all `make VAR=value`, `run.sh` forwards `SCENE` and `PASSES`):

| knob | default | meaning |
|---|---|---|
| `DC_IP` | `192.168.178.95` | console address for dcload-ip |
| `DUMPDIR` | `../polly2-data/dumps` | host directory with the dumps |
| `SCENE` | *(all)* | comma separated substrings; render only these |
| `SKIP` | *(none)* | comma separated substrings; never render these |
| `PASSES` | `1` | renders per scene; the fastest pass is reported |
| `DCFAST` | off | `-f` on dc-tool: much faster transfers, lossier |

A full sweep is 64 scenes x 16 MB of dcload traffic, about 15 minutes.

**A filtered run truncates `rendertimes.txt`** - it only ever contains the
scenes of the last run.

## Output

`rendertimes.txt`, one line per scene:

```
# scene render_us isp_us tsp_us video_us status
daytona_intro 12486.960 12318.320 12486.960 12485.840 ok
```

To put those numbers next to the RTL's, `make sim-vs-hw` in `polly2-core`
renders every scene in the verilator sim and tabulates its cycle counts as
times at 100/112/125 MHz against the hardware column of this file.

`render_us` is `STARTRENDER` to the last of the three end-of-render interrupts;
the three stage columns are each stage's own time from `STARTRENDER`. In
practice the order is ISP, then video, then TSP, with ISP landing ~150 us
before the end. A `0` column means that stage never reported (status
`partial_no_isp` and friends). The file ends with a `# total` line.

## What gets programmed

The whole captured register file goes in - all 8 KB of it, 0x000-0x1ffc,
including `FOG_TABLE` and `PALETTE_RAM` - except two words:

* `SOFTRESET` (0x008), which is not state;
* `STARTRENDER` (0x014), the trigger we fire ourselves once the registers have
  settled.

It is written twice with a short pause in between (`REG_SETTLE_MS`, default
2 ms each): the first pass brings the file up from whatever the soft reset left
behind, the pause lets it take, and the second pass puts back anything the
first pass's own side effects disturbed.

Two consequences worth knowing:

* the scan-out and sync generator go in too, so the console's video mode
  becomes the captured game's for the rest of the run;
* `TA_LIST_CONT` (0x160) is a trigger, and four dumps have it armed at
  `0x80000000`: `thps2_ingame`, `thps2_ingame2`, `thps2_ingame3`,
  `thps2_menu`. Replaying it kicks the TA to continue a list. The loader
  prints `[TA_LIST_CONT armed: ...]` for those scenes so it is visible in the
  log. `TA_LIST_INIT` (0x144), `TEST_SELECT` (0x018) and `STARTRENDER` are zero
  in every dump.

The dumps come in three sizes - 8 KB exactly, 8 KB zero-padded to 32 KB, and
one 4 KB truncation (`pvr_regs_menu.bin`, which stops before `PALETTE_RAM`).
All three load; the short one just renders with a zero palette.

## VRAM addressing

`vram_<scene>.bin` is the **32-bit view** of VRAM (minicast's `do_vram_dump()`
writes word `q` from `vram_phys[pvr_map32(q*4)]`). On the Dreamcast that view
*is* the 32-bit access area at `0xa5000000`, so the file loads and stores
linearly with no unswizzling - unlike the DE10 driver, which has to invert
`pvr_map32` for the FPGA's interleaved banks.

## Wedged renders

Some dumps do not render on real hardware: unterminated OPBs and stale bgpoly
in the capture (see the dump-capture pathologies note) leave the core chewing
forever. The app gives each render 5 s, then soft-resets the TA and pipeline
(`SOFTRESET` bits 1:0 - never bit 2, the SDRAM interface) and moves on.

Every render is preceded by a full register upload (the per-scene order is
reset, then load, then `upload_regs()`, then `STARTRENDER`), so the render
always runs on freshly programmed registers whether or not `SOFTRESET` clears
the register file. The registers we deliberately *never* replay from a dump -
`SDRAM_REFRESH`/`ARB_CFG`/`CFG` and the console's own scan-out and sync setup -
are the ones that would stay lost, so they are snapshotted at startup and
written back after every reset. A zeroed `SDRAM_REFRESH` would stop VRAM being
refreshed, which is its own way to lose the machine. The first reset of a run
prints whether any of those registers actually changed across the `SOFTRESET`,
so the question gets answered by the hardware rather than assumed.

The reset is also done **before** the 8 MB upload and **before** the 8 MB
readback of every scene, not just after a failure. This matters: a render that
is still touching VRAM starves the SH4's accesses to it, and an 8 MB transfer
fought over that way hangs the console hard enough to need a power cycle. An
early version that only reset on timeout deadlocked the machine mid-readback.

Known bad as of 2026-09-20: `mipmap` and `mvsc2_ingame` time out and cannot be
rendered; use `make SKIP=mipmap,mvsc2_ingame` to leave them out of a sweep.

## Results, 2026-09-20 (64 scenes, KOS 2.1, dcload-ip)

57 scenes rendered, 675 ms of render time in total. Range: `rez_intro` 3.6 ms,
`logo` 4.1 ms, typical in-game 8-14 ms, `jgr_tree_shadows2` 22.6 ms,
`xtreme_intro` 24.6 ms, `shenmue_intro2` 25.8 ms (the slowest).
