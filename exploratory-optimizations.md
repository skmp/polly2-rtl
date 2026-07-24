# polly2 exploratory optimizations

Running log of the performance campaign on `polly2-core` (frontendtsplp, RASLANES=8).
Primary benchmark: **shenmue_intro2** (deep PT + TL peeling, worst case we have).
Verification: bit-exact BMP sha256 for non-PT-semantic changes; PT semantic changes
verified visually once, then hash-locked.

Measurement loop: `+occlog=<file>` per-clock unit-occupancy trace → `tools/occview/`
(interactive) or the offline joint-occupancy analyzer (per-unit state histograms,
ISP×TSP joint-busy cross-tab, per-phase unit breakdowns, RS_RAS sweep cycles split
by pass kind/number). Identify the biggest serialization bucket → fix → re-measure.

## Cycle trajectory (shenmue_intro2)

| # | change | cycles | Δ | kept |
|---|---|---|---|---|
| 0 | baseline (start of campaign) | 5,659,735 | | |
| 1 | sort$ pre-fetch skip + swap-overlap | 4,717,158 | −942k | ✅ |
| 2 | PT forward resolve v1 (serialized) | 5,350,292 | +633k | ✅ (regression fixed by 3-4) |
| 3 | + PT sort$ filtering (mirrored forward demotes) | 4,311,198 | −1,039k | ✅ |
| 4 | + pipelined PT passes (depth-1 throttle) | 3,853,791 | −457k | ✅ |
| 5 | + alpha-fail bounding box raster clip | 3,731,192 | −123k | ✅ |
| 6 | + separate tex-prefetch DDR client | 3,422,527 | −309k | ✅ |
| 7 | + 4-deep spanner fetch→setup FIFO | 3,421,909 | −0.6k | ⚠️ revert candidate |
| 8 | + spanner staged-row scan clip | 3,387,318 | −35k | ✅ |
| 9 | + peel survivor-bbox raster clip | 3,380,471 | −7k | ✅ (cheap) |
| 10 | + PT speculation throttle depth 2 | 3,341,986 | −38k | ✅ |
| 11 | + OL replay ring | 3,320,507 | −21k | ✅ |
| 12 | + OL ring entry drops (entskip feedback) | 3,249,207 | −71k | ✅ |
| 13 | + PT fail-row / peel survivor-row sweep masks | 3,198,385 | −51k | ✅ |
| 14 | + back-to-back triangle chaining | 2,981,810 | −217k | ✅ |
| 15 | + coverage cache (cov$: exact per-triangle covered-row masks) | 2,909,579 | −72k | ✅ |
| 16 | + cross-pass plane reuse (sliding window) + streamed spanner→reader handoff | **2,717,013** | −193k | ✅ |

Total: **−52%** (5.66M → 2.72M).

## Final numbers per scene (all bit-exact vs golden hashes)

| scene | cycles (final) | chaining Δ | cov$ Δ | plane-reuse+streaming Δ |
|---|---|---|---|---|
| shenmue_intro2 | 2,717,013 | −216,575 | −72,231 | −192,566 |
| sonic | 2,588,800 | −148,682 | −32,666 | −84,258 |
| hotd2_car_fire | 1,655,021 | −14,959 | −3,121 | −23,048 |
| shenmue_menu | 1,409,105 | −10,710 | +209 | −44,490 |
| hotd2_gargoyle | 1,317,390 | −8,022 | −1,418 | −16,337 |
| daytona_intro | 1,267,801 | −13,964 | −84 | −16,085 |
| menu2 | 945,729 | −69,417 | −9,771 | −49,094 |
| hotd2_selfie | 981,101 | −1,039 | −103 | −1,393 |

## What was tried — detail

### Kept

| optimization | benefit (intro2) | mechanism | cost / risk |
|---|---|---|---|
| **Sort$ pre-fetch skip** | part of −942k (with swap overlap) | Iterator builds record tags from the OL entry alone and checks the sort cache *before* the DDR burst; fully-done records skip the fetch, partial strips carry filtered masks. 1/cyc pipelined check port. | small; conservative by construction (any mismatch → render) |
| **Swap-overlap** | part of −942k | OL walk / param fetch / ISP setup for the next pass run during the PeelBuffers swap walk; only the raster consumer is fenced (RS_IDLE gate). | control-only |
| **PT forward resolve** | net ≈ −0.9M vs peeled-PT baseline (steps 2-4 combined) | PT lists resolve front-to-back with blend alpha feedback before TL peel; pass count = max consecutive-fail depth, not depth complexity (19 peel passes → ~3 PT passes/entry). Zero new comparators in the ×8 lane path (plane-role remap: zb=working best, zb2=forward boundary, tag2=Zceil). pt_res mask + Zres RAM; invW rides the shade-pipe id (IDW 11→43). | big feature; PT semantics intentionally changed (visually verified, then hash-locked) |
| **PT sort$ filtering** | −1,039k | Mirrored forward demotes let the pre-fetch skip work on PT passes ≥2 (v1 re-walked/re-rastered everything every pass). | small |
| **Pipelined PT passes** | −457k | Raster of pass k+1 overlaps shade of pass k; speculation throttled to N outstanding shade passes. | speculative passes are wasted at convergence (throttle bounds this) |
| **Alpha-fail bbox clip** | −123k | Only failed pixels can stage the next PT pass; the fail set shrinks monotonically, so the last *completed* pass's fail bbox conservatively clips every later pass's sweep (valid even 2 passes behind). Empty intersect → skip triangle whole; missing demotes correctly retire it from sort$. | ~40 FF |
| **Tex-prefetch DDR client** | −309k | Arbiter client 6 (lowest priority); tex cache gets an independent single-outstanding prefetch receiver, so prefetch fills pipeline behind demand fills instead of serializing on one client. TEX_STALL 1066k→442k at landing. | arbiter 6→7 clients; dup-guard vs frozen groups |
| **Spanner scan clip** | −35k | Raster stage B tracks staged min/max rows per pass; valid-gated shades hand the range to SPANGEN, which walks only those rows (256-group scan collapses). | ~20 FF |
| **Peel survivor-bbox clip** | −7k | Same monotone argument as the fail bbox, for TL peel staged pixels (pass ≥2). Weak on shenmue (survivors scattered wide) but free. | ~30 FF |
| **PT throttle depth 2** | −38k intro2, +1.7k shenmue_menu | One more speculative pass in flight (reader idle during pt_phase 931k→859k). | +215 wasted passes |
| **OL replay ring** | −21k | Each peel/PT pass re-walked the same object list from DDR. 512-entry ring captures the eq-entry stream (key {list ptr, kind}; invalidated at render start; overflow abandons) and replays at 1 entry/clk with the walker start-gated off. Also frees DDR client 4 during replays. | 2 M10K |
| **OL ring entry drops** | −71k | Iterator reports entries that retired with *every* record pre-skipped (entry_oidx tag through eq, entskip pulse back); the ring drops them from all later replays. Sound: sort$ "fully rendered" is a permanent predicate within a peel sequence, regardless of later cache eviction. intro2: 16.7k entries dropped pre-eq. | 512×1 bits + 10b eq tag |
| **Row-mask sweep clips** | −51k | Fail/survivor sets tracked as 32-bit row masks; the sweep's row-advance jumps to the next set row (ctz32). Bbox y-window folded into the same row set → clipped and unclipped walks share one exit test. Less than the 900k PT-sweep bucket suggested: shenmue's fail rows are dense. | 4×32b masks + 2 encoders |
| **Triangle chaining** | −217k intro2, −149k sonic | RS_DRAIN between same-pass triangles (full u_line flush, 10-15 cy/tri, 336k total) replaced by direct chaining: sweep-end / probe-abort / clip-skip pop the next pq entry immediately. Safe because (a) pq only ever holds same-pass triangles, (b) the stage-A/B RAW window is ±1 exit cycle and POP+CORNER guarantee a 2-cycle gap, (c) triangle identity rides u_line as a 2-bit slot index (qi/out_qi) into a 4-slot sideband. Per-site kill switches: `+nochain`, `+nc_pop`, `+nc_abort`, `+nc_row`. | the subtlest change of the campaign — see bug patterns below |
| **Coverage cache (cov$)** | −72k intro2, −33k sonic, −10k menu2 | A triangle's sampled coverage in a tile is **pass-invariant** (same planes, same fill rule). The stage-A exit stream aggregates each rastered triangle's covered-row mask (32b) into a 1024×{tag,mask} M10K; from pass ≥2 of a peel/PT sequence, RS_CORNER ANDs a tag-matching mask into the sweep's row set. Exact by construction: skips leading/trailing sub-pixel fringe rows AND gappy sliver interiors; zero-coverage triangles skip whole and demote-starve out of the sort$. Freshness mirrors the sort$ argument (anything popping in pass p≥2 was rastered — or exactly cov-skipped — in pass p-1 of the same tile; aliases mismatch the stored tag → no clip). Rows excluded by other clips in the recording pass can never stage again (monotone shrink, grounded at the unclipped pass 1), so the under-approximation is sound. | 8 M10K (1024×64) + a 32b AND/ctz at RS_CORNER |

| **Cross-pass plane reuse + streamed handoff** | −193k intro2, −84k sonic, −49k menu2; SETUP_WAIT 646k→46k, TSP busy 47%→64% | Two coupled changes. (1) **Sliding-window plane reuse**: setup ids become the low bits of a free-running 13-bit alloc sequence; the dedup generation persists across passes of the same tile, so a later pass's dedup hit reuses the earlier pass's triangle_setups entry — no re-fetch, no re-setup (intro2: 2070/2370 passes retained, 7,628 setups total). Only the last WINDOW=512 allocs are referencable (older hits realloc); every span stores its alloc watermark; the reader feeds back the watermark of the last fully-consumed span, and a plane frees once consumption passes its seq+WINDOW — provably no unconsumed reference (any such span's watermark would already be consumed). Ring capacity = alloc may run RING_N−WINDOW=512 ahead of consumption. (2) **Streamed spanner→reader handoff**: md descriptors push at spanner *start* (finalized at busy-fall); the reader paces off the live span head and each span's setup watermark, consuming while the pass is still being spanned — required for the window to be deadlock-free, and it overlaps setup with shade. A sim scoreboard asserts no plane is overwritten while referenced. `+noretain` / `+nostream` kill switches. | dedup entry +3b, span buffer +13b/slot, seq counters; deletes the per-pass plane-free machinery |

### Neutral / rejected

| experiment | result | verdict / lesson |
|---|---|---|
| 4-deep spanner fetch→setup FIFO (pd_*) | ≈0 on every scene | The spanner is request-starved / scan-dominated, not skid-limited. Still in tree; revert saves ~3k FFs. |
| Unthrottled PT speculation | avg 8 passes/entry, +2.3% shenmue_menu | Speculation must be bounded by verdict depth, not queue capacity. |
| PT throttle depth 3 | 3,250,539 (worse than depth 2), 1681 passes | Wasted passes outweigh overlap even with cheap replayed walks. |
| Row-mask clips as a "PT sweep killer" | only −51k of a 900k bucket | Spatial clips die on spatially-dense fail sets; the remaining PT sweep cost is triangle count × area, not wasted rows. |
| Naive "fully-empty row ends the triangle" early-out | measured, not built | Geometrically true (convex ⇒ contiguous row coverage) but false at pixel sampling: the bbox is vertex-tight, so empty rows are sub-pixel fringe, and slivers cover rows sporadically. Measured on intro2: 14% of swept rows are post-coverage tail (the prize), but 1350/29,358 triangles resume coverage after an empty row — naive abort would drop their pixels. Led directly to cov$, which captures the entire prize exactly. |

## Bug patterns worth remembering (found by the chaining work)

1. **Pipe-input consumption stages.** `isp_raster_line` consumed the `tl` input at
   stage 3 — 3 cycles after issue. Re-latching shared coefficient regs (POP) while
   the pipe is live flipped the top-left rule on edge-exact pixels of the previous
   triangle's last chunks (11-px diff on shenmue_menu). Audit *every* input's
   consumption stage before allowing overlapped re-latch; everything else in that
   pipe samples at issue/s1. Fixed by piping `tl` (tl_1/tl_2).
2. **Barrier opened with a live pipe.** The clip-skip fallback went RS_POP→RS_IDLE
   with earlier chunks still in u_line; `consumer_idle` checks `rs_st`/`b_valid`
   but not `ras_inflight`, so the pass barrier opened and a tile-buffer walk's
   read collided with a late stage-A read (peel_tile_buffer "multiple READ
   clients" assert on daytona_intro; silent 3-px corruption on intro2). Every exit
   from an active sweep to RS_IDLE must route through RS_DRAIN.
3. **`$test$plusargs` prefix-matches** — `+nochainrow` matched `"nochain"` and
   silently disabled everything during the bisect. Debug plusarg names must not
   prefix each other.
4. **Bisect switches pay for themselves.** The per-site `+nc_*` gates localized
   the corruption to the sweep-end chain in two sim runs; `+nostream`/`+noretain`
   did the same for the streaming work.
5. **Same-cycle done-vs-accept races at pipeline drains.** The streamed reader's
   walk-done fired on the same cycle the final span was bypass-accepted into the
   expand stage; the drain check read the OLD (empty) stage flags and dropped the
   span's pixels silently (counters balanced because the pixel was never counted).
   An intermediate era-based free design also hid a latent 10-bit truncation of
   the setups write address (`ts_id`) that only mattered at ring sizes > 1024.
   Drain/termination decisions must use state registered BEFORE the cycle's
   consume, while read-side stop conditions must include it — they are different
   predicates.

## Current profile at 2.98M (intro2) and parked ideas

Occupancy: ISP-busy∧TSP-idle ≈ 0.95M (DRAIN-phase raster sweep with TSP starved),
ISP-idle∧TSP-busy ≈ 0.82M (PT_NEXT: shade/tex side of PT passes), both-idle 0.12M.
RS_RAS sweep split: **PT passes ≈ 900k**, OP 418k, peel 397k. TSP-side PT
breakdown: texstall 365k (80% of all tex stalls happen inside pt_phase — sparse
fail pixels → tiny TEXQ rows → poor lookup batching; lookup rescans themselves are
only ~29k), spanner busy 600k (SETUP_WAIT ≈ 646k whole-scene: per-pass re-fetch +
re-setup of the same planes).

| parked idea | attacks | est. benefit | cost / blocker |
|---|---|---|---|
| Tex throughput for sparse pixels | PT texstall 365k | 100-250k | TEXQ rows are mostly size 1-2 during PT; needs cross-span row coalescing in tex_fetch4_q |
| Per-pass z-cull of PT triangles (corner invW vs fail-set ceiling) | PT sweep 900k | modest | 4 FP mult/adds at RS_POP; overlaps what sort$ demotes already catch |
| VQ cache prefetch | vq cold fills (17.8k fills, 0 prefetched) | small | mirror of the tc prefetch path |
| More color halves | VO-bound scenes (daytona pattern) | scene-specific | M10K |
| PT_SWAP walk row-clip | 147k fenced swap walks | small (dense rows again) | safe by the same monotone argument; un-failed pixels' zb/zb2/valid are never consumed again before PT_FIX |

## Debt

- Dedicated testbenches owed (house rule): `ptfwd` (forward-resolve compares +
  PT walks), triangle chaining (directed same-chunk-across-boundary RAW test),
  OL replay ring, row-mask clips. Coverage today is the 8-scene bit-exact matrix
  + itskip / raster-topleft selftests.
- spannerv2 / regfile TB tops stale vs evolved modules (unbuildable).
- Quartus fitter/STA re-check for this round: OL ring (2 M10K + 512 skip bits),
  4-slot identity sideband + stage-A mux, ctz32 encoders in the sweep-control
  loop, 7-client arbiter. polly2 timing is fragile — check slack before blaming
  RTL.
- `+pxwatch=<id>` blend-event pixel watch left in peel_core (sim-only, handy).
