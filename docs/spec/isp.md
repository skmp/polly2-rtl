# ISP specification: from the region array to the visible-polygon decision

The ISP side of the CLX2 core, as refsw3 implements it. This document is meant to be enough to build the RTL from.
It covers the region array walk, object list parsing, the setup unit's arithmetic (edges, determinant, culling,
depth plane), the inside test, the depth compare and the per-pixel buffer updates of every list type (opaque,
modifier volume, punch-through, translucent pre-sorted and sorted per pixel), and the hand-off to the TSP (which
pixels get shaded, in which runs, under which volume state). The TSP's shading and the write-out / scaler are
covered by other specs (docs/spec/tsp.md, the write-out spec). This document refers to them only where the ISP
depends on them: the alpha test result and the end-of-entry buffer swap.

## 0. Sources, notation, status

**Functional truth**: refsw3, nulldc3 branch `skmp/refsw3`, folder `refsw3/refcore`. The edge unit (sections 6.1,
6.3's note on the edge unit, 7.1-7.2, 8, the edge rows of 15-17) is at **`4f3efe15`** (spec sync 2026-11-20: `1040c4aa`
"the big-edge walk in units of 2^102; end against ZERO; row 31 for every polygon"; `0de9776b`'s zero rule in the
coordinates and edges checked against the edge unit: it is the depth unit's only, 6.3). The depth unit (sections 6.3,
9, 10.3's note on garbage depths, the depth rows of 15-17) is at **`4f3efe15`** too (depth spec sync 2026-11-20:
`0de9776b` "depth at the tile's corner without HALF_OFFSET; the zero rule in coordinates and edges" and the depth
part of `4f3efe15` "a determinant of 2^126 or more has a reciprocal of zero"). Everything else is at `708fb8cd` ("the
depth unit below zero, past 2^128 and at its range's ends", after `6784ea3d` "the edge unit past 2^124: wrap, push
and end of the edge"): transcribed at `2d08a440`; sections 4.2, 6.3, 7.1-7.2, 8.2-8.6, 9, 10.1, 13, 15-17
re-transcribed at `708fb8cd` (2026-11-20, spec refresh), with notes in 6.2, 10.2, 10.3, 11.2 and 11.6. **Not yet
transcribed** (TSP sync, ARCHITECTURE §0.1b): `2bee80f2` (TSP only) and the TSP part of `4f3efe15` (the planes'
coefficients zero for a determinant of 2^126 or more); neither touches this document's rules. Line numbers (`L123`)
of `edge.h` and `depth.h`, and of `refsw_tile.cpp` in sections 7, 8 and 9, refer to `4f3efe15`, the others to
`708fb8cd`; `edge.h`, `depth.h` are `pvr_isp_edge.h`, `pvr_isp_depth.h`. Evidence: dreamcast-tests at `a932980`
(edge2_*, depth2_*, tsp2_*, trsort_* added there; `b54c934` before).

| file | what this spec takes from it |
|---|---|
| `refsw_lists.cpp` | region array walk, per-entry phase order, background depth, object list walk, primitive assembly, PT chunking, end-of-entry |
| `refsw_lists.h`, `refsw_lists_regtypes.h`, `core_structs.h` | the memory formats (region array, list pointers, object list entries, ISP/TSP word, tag) |
| `pvr_softfp.h` | the setup units' soft float (`Fp`, `Mul`, `Add`, `Recip`, `perpVal`, `Perpendicular`) |
| `pvr_isp_edge.h` | determinant/winding, edge setup per tile, the inside test, the row range |
| `pvr_isp_depth.h` | depth plane setup per tile, the regimes, stepping, the stored depth format, the compare order |
| `refsw_tile.cpp` (ISP parts) | buffers, `PixelFlush_isp`, `KeyAbove`, culling, `RasterizeTriangle`, PT/TR peeling buffers, modifier volume summaries, `SpanGen`, `SpanSort`, `RenderParamTags` (the ISP side) |

**Console evidence**: `dreamcast-tests` (README.md sections named below, `pvr-tests/<test>`). A rule is written with
the test(s) that pin it as **[T: test — what it showed]**. **GAP** marks what no console test has measured (refsw3
then encodes a guess or an implementation choice, which is stated). **[R]** marks a refsw3 implementation detail
that is not hardware behaviour, such as a software early-out that gives the same results. **[I]** marks structure
inferred from timing (dreamcast-tests `pvr-tests/PIPELINE_SHAPE.md`, `pvr-tests/timemeas/REPORT.md`).

Overall standing (dreamcast-tests README "optcull..." and "zexfil"): refsw3 gives the console's picture on all 786
polly2-data dumps, and the console's depth buffer word for word on all 64 dumps read out with `zexfil` (64 x
307,200 depths). The regression's known misses on the ISP side are listed in section 15.

**Number notation** (`pvr_softfp.h`):

- A setup value `v` is `(-1)^neg * mant * 2^exp`, `mant` an unsigned integer, plus a `bad` flag (it came from an
  infinity or a NaN). `mant == 0` is zero; a zero keeps a sign but the ISP never looks at it.
- `top(v)` = `exp + bitlength(mant)`: `v` is in `[2^(top-1), 2^top)`; frexp's exponent. For a normal IEEE single
  with exponent field `f`, `top = f - 126`. `top(0)` = NoExp (minus infinity).
- `cut_n(v)`: keep the `n` most significant bits of `mant`, **truncating the magnitude (toward zero)**.
- `cutBelow_k(v)`: clear every bit worth less than `2^k`, truncating the magnitude (toward zero).
- `floor` rounds toward minus infinity; "truncate" always means toward zero.
- `|v| >= 2^k` is `top(v) > k`.
- "half units of 2^u" means an integer `t` whose value is `t * 2^(u-1)`.

**Pixel and tile coordinates**: a tile is 32 x 32 pixels. `left = tilex * 32`, `top = tiley * 32`. Inside the tile,
column `i` (0..31, left to right) and row `j` (0..31, top to bottom); pixel index `j * 32 + i`.

## 1. The order of processing

refsw3 is sequential. The RTL pipelines, but where the order is observable in the picture or the depth buffer it
must give the same result as this order.

```
frame (STARTRENDER):
  perpVal = FPU_PERP_VAL                                           (section 7.3)
  for each region array entry, in memory order, until and including the one with last_region:
    read the entry (5 or 6 words)                                  (section 3.1)
    [TSP] clear the setup cache and the stuck-alpha flag
    if !z_keep:  Z clear: depthA[*] = BG(ISP_BACKGND_D), tagA[*] = ISP_BACKGND_T, stencil[*] = 0,
                 valid[*] = 1, rendered[*] = 0                     (section 4.2)
    else:        valid[*] = rendered[*] = 0; depthA, tagA, stencil stay as the previous entry left them
    if OP pointer:      walk OP list (RM_OPAQUE)
                        if OP_MOD pointer: walk OP_MOD list (RM_MODIFIER)
    OpInPt = PT pointer && the PT list holds a primitive           (section 11.3)
    SHADE pass RM_OPAQUE                                           (the background and the opaque polygons)
    if PT pointer:      PT chunks x passes, PT final               (section 11.4)
                        if OP_MOD pointer: walk OP_MOD list again (RM_MODIFIER); SHADE pass RM_PUNCHTHROUGH_MV
    if TR pointer:
       pre_sort:        tagStatus cleared; walk TR list (RM_TRANSLUCENT_PRESORT), SHADE after every primitive
       else (autosort): save depth; repeat { peel buffers; walk TR list; if TR_MOD: walk TR_MOD list;
                        SHADE pass } while a fragment was deferred; restore depth
    end of entry: write-out decision, buffer swap                  (section 4.4)

walk a list:  object list entries in memory order, following links, until end_of_list
  strip entry:          triangles 0..5 whose mask bit is set, in that order
  triangle/quad array:  primitives 0..prims, in that order
  each primitive:       [PT only] chunk check; setup (winding, bad corners, cull, edges, depth: per tile);
                        rows j = 0..31 (row range; rows no edge can reach skipped), columns i = 0..31:
                        if inside: PixelFlush_isp(pixel)
                        [modifier] after a triangle whose VolumeMode is 1 or 2: summarize the stencil
                        [pre-sort] after the primitive: SHADE its pixels

SHADE pass (ISP side): cut the tile into runs in raster order (rows 0..31, left to right), order them with the span
  sorter, hand them to the TSP pixel by pixel; for PT and sorted TR passes, update the ISP buffers with the TSP's
  answer (alpha test) pixel by pixel                               (section 12)
```

What of this order shows in a picture or a depth buffer (the RTL must keep it):

1. **Per pixel, the fragments of a pass arrive in list order** (entry order, strip triangle order, array order).
   Every compare (opaque `DepthMode` with depth write, `KeyAbove` ties, the stencil parity) depends on the order of
   the fragments at the same pixel and on nothing else. Pixels are independent within a pass, so one tile line a
   clock (the hardware's rate [I], PIPELINE_SHAPE [2]) is fine as long as a pixel never sees fragment k+1 before
   fragment k.
2. **A modifier volume closes after its last triangle.** The summary (OR / AND into bit 0) happens when the
   triangle with VolumeMode 1 or 2 has been rasterized, before the next volume's first triangle.
3. **Pre-sorted translucent: each primitive is shaded before the next one is rasterized.** Its depth compare sees
   the depth written by the primitives before it; the TSP blends in list order.
4. **The phases of an entry are strictly ordered**: the opaque depth must be final before the OP_MOD list is
   tested against it, the opaque runs are cut only once `OpInPt` is known (it changes where opaque runs end), the
   PT passes start from the final opaque depth, the sorted translucent passes from the final PT depth.
5. **The PT passes and the translucent passes iterate.** The next pass depends on the previous pass's TSP results
   (alpha test) or deferrals. A pass's ISP walk must finish before its SHADE, and the SHADE before the next walk.
6. **Run order** (which run the TSP shades when) does not change the ISP's buffers, but it changes the TSP's carried
   state (stuck alpha, the kept offset colour). It belongs to SpanGen / SpanSort (section 12).
7. **State carries over between entries regardless of their tile coordinates.** depthA, tagA and the stencil are
   whatever the previous entry left; a keep-Z entry for tile (0,0) after an entry for tile (10,7) sees tile (10,7)'s
   depths [T: zexfil — the depth buffer read-out relies on exactly this, 32,768 of 32,768 depths and every depth of
   64 dumps].

Where the clock matters (refsw3 has none): section 14.

## 2. Registers the ISP reads

| register | address | bits used | meaning here |
|---|---|---|---|
| `PARAM_BASE` | 0x020 | 23:20 (ISP side: `PARAM_BASE & 0xF00000`) | base of the parameter blocks (1 MB granule) |
| `REGION_BASE` | 0x02C | 23:2 | first region array entry (32-bit area address) |
| `SPAN_SORT_CFG` | 0x030 | 0, 8 (16 no effect) | span sorter on; offset sort (section 12.2) |
| `FPU_SHAD_SCALE` | 0x074 | 8 (intensity mode), 7:0 | intensity mode decides the two-volume vertex layout (3.4); scale is the TSP's |
| `FPU_CULL_VAL` | 0x078 | 30:0 (sign ignored) | cull-by-size threshold (7.2) |
| `FPU_PARAM_CFG` | 0x07C | 21 (`region_header_type`) | 0: 5-word region entries, 1: 6-word |
| `HALF_OFFSET` | 0x080 | 0 (`fpu_pixel_half_offset`) | 1: the ISP samples pixel centres, 0: pixel corners |
| `FPU_PERP_VAL` | 0x084 | 30:0 (sign ignored) | "perpendicular" threshold (7.3) |
| `ISP_BACKGND_D` | 0x088 | 31:0 | background depth (4.2) |
| `ISP_BACKGND_T` | 0x08C | 28:0 | background tag (4.2, tag format 3.5) |
| `ISP_FEED_CFG` | 0x098 | 0 (pre-sort for 5-word entries), 13:4 (PT chunk size) | 23:14 (TR cache size) and 3 (discard) not modelled (section 15) |
| `PT_ALPHA_REF` | 0x11C | 7:0 | the TSP's alpha test reference; the ISP only sees pass / fail |

Reset value: refsw2's history says FPU_CULL_VAL is 1.0 "what a console has when a program starts" (README "What
changed in refsw2"); whether that is the core's reset value or the boot ROM's write is not stated.

## 3. Memory formats

All addresses below are 32-bit-area addresses ("32 bit view" of video memory; refsw3's `vri()` maps them onto the
64-bit interleaved banks, `pvr_mem.cpp: pvr_map32`). Words are little endian 32 bit.

### 3.1 Region array entry

Word 0, control (`RegionArrayEntryControl`):

| bits | field |
|---|---|
| 1:0 | reserved |
| 7:2 | `tilex` (6 bits) |
| 13:8 | `tiley` (6 bits) |
| 27:14 | reserved |
| 28 | `no_writeout` |
| 29 | `pre_sort` (6-word entries only) |
| 30 | `z_keep` |
| 31 | `last_region` |

Words 1..5, list pointers (`ListPointer`), in this order: **opaque, opaque modifier volume, translucent, translucent
modifier volume, punch-through**:

| bits | field |
|---|---|
| 1:0 | 0 |
| 23:2 | `ptr_in_words`: the list's address is `ptr_in_words * 4` (bits 23:2 of a byte address) |
| 30:24 | ignored |
| 31 | `empty`: no list |

`FPU_PARAM_CFG` bit 21 = 0 (refsw3 "fmt_v1"): the entry is **5 words** (no punch-through pointer: treated as
empty), and `pre_sort` comes from `ISP_FEED_CFG` bit 0 for every entry (the entry's bit 29 is overwritten). Bit 21 =
1: 6 words, word 5 is the punch-through pointer, `pre_sort` is the entry's bit 29. The next entry follows at +20 or
+24 bytes. The walk ends after the entry with `last_region` set (do-while: the last entry is processed).

### 3.2 Object list entries

One 32-bit word each, walked from the list pointer upward in steps of 4 bytes.

Bit 31 = 0: **triangle strip** (`ObjectListTstrip`):

| bits | field |
|---|---|
| 20:0 | `param_offs_in_words` (21 bits) |
| 23:21 | `skip` (3 bits) |
| 24 | `shadow` |
| 30:25 | `mask` (6 bits): bit (5 - i) set = triangle i of the strip is in this tile |
| 31 | 0 |

Bit 31 = 1, bits 31:29 = type:

| type | entry | bits |
|---|---|---|
| 100 | triangle array | 20:0 param offset, 23:21 skip, 24 shadow, 28:25 `prims` (count - 1) |
| 101 | quad array | same layout as the triangle array |
| 111 | link | 23:2 `next_block_ptr_in_words` (next entry at `ptr * 4`), 28 `end_of_list` (stop) |
| other (110) | none | refsw3 prints "Not handled object type" and goes on to the next word. **GAP** |

A link with `end_of_list` = 0 jumps; with 1 the list ends. There is no other terminator.

### 3.3 Parameter blocks and the ISP/TSP instruction word

Address of a block: `(PARAM_BASE & 0xF00000) + param_offs_in_words * 4`. A block is:

```
word 0   ISP/TSP instruction word
word 1   TSP word (volume 0)
word 2   TCW (volume 0)
[word 3  TSP word (volume 1)    only with two volumes
 word 4  TCW (volume 1)]
vertices, each (3 + skip * (1 + twoVolumes)) words
```

`twoVolumes = shadow && !FPU_SHAD_SCALE[8]`: the entry's shadow bit, unless intensity mode is on (then a polygon sent
with two volumes is read with the single-volume layout [T: faredge / modvol — modvol's last 5 cells were exactly
that]). The ISP reads only words 0, 1, 2 of each vertex (x, y, z as IEEE single bits); the rest of the vertex is the
TSP's (`decode_pvr_vertex`: u, v or the packed 16-bit uv, base colour, offset colour, then the second volume's).

ISP/TSP instruction word (`ISP_TSP`), the fields the ISP uses:

| bits | field | ISP use |
|---|---|---|
| 19:0 | reserved | |
| 20 | `DCalcCtrl` | TSP |
| 21 | `CacheBypass` | copied into the tag, bit 28 |
| 22 | `UV_16b` | vertex layout (TSP) |
| 23 | `Gouraud` | TSP |
| 24 | `Offset` | vertex layout (TSP) |
| 25 | `Texture` | vertex layout (TSP) |
| 26 | `ZWriteDis` | opaque and pre-sorted translucent depth write (11.1, 11.5) |
| 28:27 | `CullMode` | 0 none, 1 small, 2 small + negative determinant, 3 small + positive determinant (7.2) |
| 31:29 | `DepthMode` | 0 never, 1 less, 2 equal, 3 less-or-equal, 4 greater, 5 not-equal, 6 greater-or-equal, 7 always (10.2) |

For modifier volume triangles the same word is read as: bits 28:27 `CullMode`, bits 31:29 `VolumeMode` (0 a normal
triangle of the volume, 1 the last triangle of an "inside" volume, 2 the last triangle of an "outside" volume; 3..7
treated as 0 by refsw3: **GAP**).

**Parameter base inconsistency [R]**: the ISP side uses `PARAM_BASE & 0xF00000`, while refsw3's TSP side
(`GetFpuEntry`) adds the unmasked `PARAM_BASE`. They agree whenever `PARAM_BASE` is 1 MB aligned, which every game
and test does. **GAP** otherwise. Also not modelled: a console draws nothing from parameters below `PARAM_BASE`'s
page / offsets past 8 MB, where refsw3 wraps the address [T: zexfil — probes at 0x180000 with PARAM_BASE 0x400000
draw nothing on a console].

### 3.4 Primitive assembly (`RenderTriangleStrip`, `RenderTriangleArray`, `RenderQuadArray`)

- **Strip entry**: one parameter block (header + up to 8 vertices v0..v7; refsw3 reads all 8). For `i` = 0..5 with
  `mask` bit (5 - i) set, triangle `i` goes to the rasterizer with corners
  - `i` even: (v[i], v[i+1], v[i+2]),
  - `i` odd: (v[i+1], v[i], v[i+2]) (first two swapped),
  and tag offset `i`. These corner orders are "rasterizer order": every setup sum order below refers to it
  [T: zmeas — exactly one vertex / sum order of 384 fits; perpmean_strip — odd triangles of strips, Strip_Len 1, 2,
  6, 8,192 words].
- **Triangle array**: `prims + 1` triangles, each a complete parameter block (its own header and 3 vertices),
  stored back to back. Tag offset 0, tag parameter offset = the block's own offset.
- **Quad array**: `prims + 1` quads, each a block with 4 vertices (v0, v1, v2, v3). One primitive with four edges
  (section 8.1); the determinant, culling, depth plane use (v0, v1, v2) only.

### 3.5 The parameter tag (`ISP_BACKGND_T` format)

What the tag buffer stores per pixel; also the background's register.

| bits | field |
|---|---|
| 2:0 | `tag_offset`: the triangle's index in its strip (0 for arrays and the background) |
| 23:3 | `param_offs_in_words` (21 bits) |
| 26:24 | `skip` |
| 27 | `shadow` |
| 28 | `cache_bypass` (the ISP word's bit 21) |
| 31:29 | 0 |

The **sort key** of a tag is bits 23:0 (`PARAMETER_TAG_SORT_MASK = 0x00FFFFFF`): parameter offset and strip index.
Parameters are written in list order by the TA, so the key grows with the order the polygons were sent. 32 bits of
all ones (`TAG_BELOW`, 0xFFFFFFFF) is never a real tag; refsw3 uses it as "no reference" in the PT passes.

## 4. The tile sequencer

### 4.1 Per entry

See section 1. Notes:

- The opaque modifier list is walked in the opaque phase **only if the opaque pointer is present**. With an empty
  opaque list and a punch-through list, it is still walked in the PT_MOD phase. With an empty opaque list and no PT
  list it is never walked (the stencil stays 0). **GAP**: that last case is refsw3's reading, not measured.
- The punch-through modifier pass needs the PT pointer. The translucent modifier list is walked only in sorted
  (autosort) entries, once per peeling pass. In a pre-sorted entry it is ignored [T: timemeas tr_modvol
  (REPORT.md "Modifier volumes") — ignored in a pre-sorted tile, working in a sorted one; uvrun kind 9].
- The background polygon is not rasterized. It is only the tag and depth written by the Z clear. The TSP shades it
  wherever it is still the visible tag after the opaque phase [T: timemeas — the background polygon is shaded in
  every entry without keep Z, even one that is not written out: 1035 clocks].

### 4.2 Z clear and the background depth (`ClearBuffers`, refsw_lists.cpp L603-653)

Without `z_keep`, every pixel: `depthA = BG`, `tagA = ISP_BACKGND_T`, `stencil = 0`, `valid = 1`, `rendered = 0`.
With `z_keep`, only `valid = rendered = 0`. The depth, tag and stencil are kept. The stencil not being cleared
by keep Z is refsw3's reading: **GAP**.

`BG` is a stored depth (the order key of 9.7) made from `ISP_BACKGND_D` (`bg`, 32 bits; `field = bg[30:23]`):

```
if bg[31] == 0:                                  # zero or above
    cut = max(5, 130 - field)                    # fraction bits dropped
    w   = (cut > 23) ? 0 : bg & ~((1 << cut) - 1)
    if field == 255: w -= 1 << 23                # exponent field 255 becomes 254, the fraction kept
    BG  = Bits(w)
else:                                            # below zero: a flat plane of that depth whose block exponent is >= 6
    f   = (field == 255) ? 254 : field
    E   = max(f - 126, 6)                        # the block exponent (9.7 Neg)
    m   = (0x800000 | bg[22:0]) >> 4             # its 20 bits (a start's): the depth is -m 2^(f - 146)
    t   = (f < 107) ? 0 : m 2^(f - 120 - E)      # on the block's grid 2^(E - 26), toward zero (0 once shifted 64 or more)
    BG  = (t == 0) ? key 0 : Neg(E, -ceil(t / 2^10))      # M on 2^(E - 16), the value rounded down (the size up)
```

What this means. Above zero: a float with 19 significant bits whose smallest exponent is that of 0.25 (field 125);
below field 125 it is a denormal of that exponent, so the smallest step is 2^-20 (the grid 2^(E - 26) of a block
exponent of at least 6), and anything below 2^-20 is 0. +-infinity is +-2^127, which ties with an overflowing
polygon (`Saturated`, 9.7). Positive NaNs stay above it. Below zero the background is stored as the depth unit
stores a flat plane of that depth whose block exponent E is at least 6: its 20 bits on the block's grid 2^(E - 26),
toward zero, then M on 2^(E - 16), rounded down (the size up):
- from 32 on (field 132 and up): E is its own exponent, `f - 126`. The background is itself, its low 4 fraction bits
  cut, then its size rounded up to a multiple of 0x100 in the word; one that would round up to the next power of two
  stays at the fraction 0x7FFFE0 (the window of 9.7, no carry). -infinity and -NaN are field 254 with their fraction.
- from 2^-20 to under 32 (fields 107 .. 131): E is 6. Its 20 bits go onto the grid 2^-20 toward zero (`t` above),
  then `M = -ceil(t / 2^10)` on 2^-10 (so 2^-10 + 2^-21 is M = -1). That lies above the window of E 6: between field
  132's top word and field 133's lowest, ordered by M.
- under 2^-20 (field 106 and below): nothing is left on the 2^-20 grid: 0.

[T: bgdepth — 32 background depths 2^-20 .. 1e6 against 300 probes each; bgtie — a polygon at 0.5 ties with a
background of 0.5 + 2^-20 (a float, not fixed point); dumprules pages 2-7 / xtreme_intro — below 2^-20 it is 0,
nothing is behind it; trtie pages 12-15 / rez_ingame; bgspec (2560 regions; -2^-21, -2^-149, -0 as 0), bgbig (2^127
ties, 1.5 * 2^126 below, 1.5 * 2^127 and the largest float above), bgneg, bgneg2 (from 64 on itself);
depthgaps_bglow, depthgaps_bglow2 (backgrounds W + L, L = 0 .. 31, against flat polygons at W: L 0 .. 15 tie with
W, 16 .. 31 are below it, for W = -64, -100, -2^20, -2^100, -2^127; with W of fraction 0x7FFFE0 all 32 tie),
depthgaps_bglow3 (16 .. 31 tie with W + 0x20, which a flat polygon stores as W + 0x100; -inf + L and -NaN
0xFFFFFFE0 + L as field 254 with that fraction); depthgaps_bgpin (a ramp of E 6 stepping by 2^-10 across -1 and
across 0, Greater, Equal, Less: -1 and -1 - 2^-23 tie with the ramp's -1 (M -1024), -2^-20 with its -2^-10 (M -1:
rounded up, not to 0), -0.5 between its -1009 2^-10 and -16 2^-10, -31.99998, -32, -63.75, -63.99999 below its
-1040 2^-10); depthgaps_ties (-1 against ramps of E 6 and 7)]. Before `708fb8cd` refsw3 had every background from
-2^-20 to -63.75 as one word, 0xC2FFFFFF: bgneg's probes (-64 .. -100.75) are above all of them either way.

### 4.3 Several entries for one tile (accumulation)

Games send a tile more than once. Common patterns are a first entry with lists that is not written out, then a
keep-Z entry with nothing in it; or keep-Z chains with one entry per list group (thps2: three entries a tile). The
ISP state that carries from one entry to the next is `depthA`, `tagA` and `stencil` (section 1, item 7). After a
sorted translucent phase, `depthA` holds the nearest drawn layer's depth (11.6) and `tagA` that layer's tag. After a
pre-sorted phase, `depthA` holds the depth written by translucent polygons without `ZWriteDis`. After a PT phase,
`depthA`/`tagA` hold the resolved PT key or the opaque one. Colour accumulates across entries only through the TSP's
tile buffers, which change places at every written-out entry (4.4, tsp.md) [T: timemeas keepz — "a second entry of
a tile with keep Z keeps the depth, shades only what it draws, and adds to the first entry's picture only if the
first was not written out"; keepz page 3 — the depth after a sorted entry].

### 4.4 End of an entry (refsw_lists.cpp, after "PIXELS")

`tilePixelsShaded` counts every pixel of every run handed to the TSP in this entry (the background included).

```
emptyKeepZ        = z_keep && tilePixelsShaded == 0 &&  prevWrittenOut
emptyAfterNoWrite = z_keep && tilePixelsShaded == 0 && !prevWrittenOut && havePrev
(writeX, writeY)  = emptyAfterNoWrite ? (prev tilex, prev tiley) : (tilex, tiley)
prevWrittenOut    = !no_writeout && !emptyKeepZ
if !no_writeout && emptyKeepZ:  swap the two tile buffers, write nothing
elif !no_writeout:              write the tile buffer out at (writeX, writeY), then swap
(no_writeout: no write, no swap)
prev tile = this entry's tile; havePrev = true
```

[T: keepz pages 0-2 — an empty keep-Z entry after a not-written-out entry writes the buffer out at the earlier
entry's place, 49 of 49 regions, the five game frames (logo, mem, menu2, menu3, thps2_menu) exact; accbuf — an empty
keep-Z entry after a written one swaps but is not written, 299 of 375 cells with the other 76 timing races]. The
pack, dither, scaler and clip are the write-out spec's.

## 5. Object list walk (`RenderObjectList`)

```
addr = list pointer * 4
loop:
  w = word at addr; addr += 4
  if w[31] == 0:                  strip entry: its triangles (3.4)
  elif w[31:29] == 111:           if w[28]: end; else addr = w[23:2] * 4
  elif w[31:29] == 100:           triangle array
  elif w[31:29] == 101:           quad array
  else:                           ignored (GAP)
```

Every pass of a list (each PT pass, each translucent peeling pass, the OP_MOD list twice) walks the whole list again
from its pointer. refsw3 re-reads memory each time. Whether the hardware caches what it read is a timing question
(section 14).

**"The list holds a primitive"** (`ObjectListHasPrimitive`, used for `OpInPt`): walk as above, true at the first
strip entry with `mask != 0` or the first triangle/quad array entry; false at `end_of_list`.

## 6. The setup soft float (`pvr_softfp.h`)

Every arithmetic rule of the edge and depth units is one of these operations with a stated width. The hardware's
widths are template constants in `EdgeHW` and `DepthHW`. All of them have been measured, see the tables in 8.2 and 9.1.

### 6.1 Inputs

- **Edge unit** (`Fp::FromBits`): exponent field 255 (infinity, NaN) is `bad` (sign cleared). Field 0 is a
  **denormal**, `fraction * 2^-149` (zero if the fraction is 0). Otherwise `(fraction | 2^23) * 2^(field - 150)`.
- **Depth unit** (`Fp::FromSingle(u, ranged = 1)`): field 255 is `bad` **with its sign**; field 0 is +-0 whatever
  the fraction; otherwise as above.
- **GAP**: the edge unit takes a denormal coordinate as a denormal, the depth unit as zero. Coordinates below
  2^-126 have not been measured on the edge unit (the ranged rule is measured for the TSP's setup [T: uvmeas wexp,
  whuge, wtiny, wspec] and inferred for the depth unit [T: huge — 250 of 250 regions with it, 228 without]).
- Tile coordinates are exact: `FromHalves(k) = k / 2`.

### 6.2 Operations

| operation | definition |
|---|---|
| `Mul(a, b, n)` | exact product of the two mantissas (each at most 32 bits, at most 24 here), sign = xor, then `cut_n`. `bad` if either is bad. Zero if either is zero. |
| `Add(a, b, n, reach)` (guard -1) | both zero: zero, negative only if both are. One zero: the other, `cut_n`. If `top(a) - top(b) >= reach`, the result is `cut_n(a)` and `b` is **dropped entirely** (and the same the other way round). Otherwise the **exact** sum, then `cut_n` (truncation of the magnitude). An exact cancellation is +0. `bad` if either is bad. |
| `Sub(a, b, n, reach)` | `Add(a, -b, n, reach)` |
| `Recip(v, n)` | `floor(2^(L + n + 2) / mant)` with `L = bitlength(mant)`, sign of `v`, then `cut_n`. Equal to **1/v truncated to n significant bits** (a floor of a floor). |
| `cut_n`, `cutBelow_k`, `top` | section 0 |
| `FloorScaled(v, s)` | `floor(v * 2^s)` as an integer, clamped to `[-2^40, 2^40]` |

The edge unit has no range rules: its products reach 2^256 before the swamp (8.3) replaces everything from 2^128 by
+-2^200. It has **no zero rule** either: `Winding`, `EdgeWinding` and `EdgeTile::Setup` use `pvrfp::Add` / `Sub`
(6.2) at `4f3efe15`. The zero rule that `0de9776b` extended to the coordinate differences, the edges `x_j y_k - x_k
y_j` and the determinant is the **depth** setup's own (`DepthHW::zeroRuleCoords`, `zeroRuleEdges`, depth.h `subC`,
`addE`): the depth unit computes those values itself (9.2), and the edge unit's `c`, `dx`, `dy` and determinant are
not changed by it (6.3, 9.2 transcribe the depth side). No console test isolates a zero rule in the edge unit; with
none there, every region of depth2_zcoord and depth2_zedge (triangles near the origin with signed-zero and +-(1 ..
1.5) 2^-126 coordinates) and of the whole regression is exact (dreamcast-tests README "r8 round 1"). The RTL keeps
the edge flavour (num §4.2) free of it. With inputs between 2^-149 and 2^128, an internal exponent of about 10 bits with sign covers both units
(products 2^-298 .. 2^256; the depth unit's unranged slopes `a * inv` up to 2^254).

### 6.3 Range rules and the zero rule (depth unit only; `DepthHW::range = 1`)

The depth setup's own operations, the lambdas `limit`, `mul`, `addRule` and its three users `add`, `subC`, `addE` of
`DepthTileT::Setup` (depth.h L356-414). They make every product and sum of the plane (9.2), the tile's start (9.3)
and the mean (9.4b):

```
limit(r, sum):  r == 0:            r
                |r| >= 2^128:      an infinity (bad) with r's sign
                |r| <  2^-126:     a zero: +0 for a sum, r's sign for a product
mul(p, q):      p or q bad:        a zero (sign xor) if the other one is a zero that is not bad, else an infinity (sign xor)
                else:              limit(Mul(p, q, 24), product)
add(p, q):      p or q bad:        both bad with opposite signs: +0; else an infinity of the bad one's sign (p's if both)
                one of p, q a zero (z), the other (v) not, 2^-126 <= |v| < 1.5 * 2^-126, sign(v) != sign(z):  +0
                else:              r = limit(Add(p, q, 24, 25), sum); a zero r is +0
subC(p, q) = add(p, -q)           the coordinate differences (y1 - y2 .., x2 - x1 ..)          zeroRuleCoords = 1
addE(p, q) = add(p, q)            the edges x_j y_k - x_k y_j (as addE(p, -q)) and det's sums  zeroRuleEdges = 1
```

refsw3 writes the three as one `addRule(p, q, rule)`; with `rule` false the second line (the zero rule) is skipped.
In the hardware configuration every addition of the depth setup has the rule: `subC` and `addE` are `add`
(`DepthHW::zeroRuleCoords = zeroRuleEdges = 1`, 9.1). The switches exist for the generators of the tests that
measured them (0 is not the hardware's).

What this gives, with its tests:
- **2^128 is checked at every product and every sum where it is made**, after the 24-bit truncation. The adder's
  reach does not decide it: a reach of 40 changes no zovf test. [T: zovf_lim — a term of the constant at 2^128 -
  2^104, 2^128, 2^128 + 2^105 .. 1.5 * 2^128, as a product with the others beyond the adder's reach, as a sum of two
  products below 2^128, a product past 2^128 whose sum comes back below it: 4984 of 4984 regions; zovf_c (the constant
  alone at +-(1 + 2^-22 .. 1 + 2^-2) 2^128, 352 regions); zovf_ps (it is zovf_ps that pins the check of a product at
  exactly 2^128: 2^128 - 2^104 is not one); zovf (the six cells with the constant exactly 2^128); zovf_sum (the
  start's last sum and last product alone; the last sum's order); zovf_far; zovf_ab (13 x 13 slope values from 0 to
  2^132 of both signs); huge — 250 of 250 regions (228 without the range), including the quads at 2^127 / infinity /
  NaN of which a console draws one triangle only]
- **Infinities**: infinity - infinity is +0, infinity times 0 is 0. In a product a NaN is an infinity of its sign,
  its fraction does not count [T: depthgaps_nanprod — NaNs and infinities whose terms of a slope have opposite
  signs, every pixel read: the words of +inf +inf 1 where the terms cancel to +0, 16 of 16 regions; zword — a TL
  corner bad, (-inf - inf) + inf, starts at 0].
- **The zero rule.** A zero (an input of exponent field 0, a product below 2^-126 with its sign, or a sum) added to a
  number of 2^-126 .. 1.5 * 2^-126 in size whose sign is not the zero's gives +0. Added to any other number it gives
  that number, to the bit. Every zero sum is +0, -0 + -0 too. [T: depthgaps_zadd — 32 slivers read out to the bit,
  nothing else near 2^-126: the slope's last addition +0 + t3 with t3 = -2^-126, -1.25 * 2^-126, -(1.5 - 2^-22) *
  2^-126 gives a slope of 0, with -1.5, -1.75, -(2 - 2^-22) and +1 .. +1.75 (2^-126) the numbers themselves
  exactly; -0 + -0 is +0; the first addition: -0 + 1.25 * 2^-126 is +0, +0 + 1.25 and -0 + 1.75 are kept; the tile's
  start +0 + c with c = -(1 .. 1.5 - 2^-10) 2^-126 starts at 0, with -(1.5 .. 2 - 2^-9) and +1 .. +1.75 at c / det
  exactly: 109 of 109 regions (a zero as a zero 84; the TSP planes' rule, tsp §4.1, 76; -0 + -0 = -0 108);
  depthgaps_field1 — 1000 of zexfil's flat probes at depths of exponent fields 0 .. 5: 2000 of 2000 orders (a zero as
  a zero 1642, the TSP's last-addition rule 1944, -0 + -0 = -0 1972, without the rule in the first additions
  1996)]. The rule reads the values and the zero's sign only. An input zero's fraction bits are gone at `FromSingle`,
  unlike in the TSP's mean (tsp §4.4). **The rule is in every addition of the depth setup**, the coordinate
  differences, the edges and the determinant included (`0de9776b`): [T: depth2_zcoord — 16 triangles near the
  origin, one coordinate of two corners among +-0 and +-(1 .. 1.5) 2^-126, so that such a difference multiplies a
  depth of 2^126 and more or an infinity: the product a zero, or an infinity times zero 0, with the rule; refsw3
  without it there (`zeroRuleCoords` 0) stores other words at all 2,599 pixels; 5 background probes each: 80 of 80
  regions with it, 4,558 probe pixels on 49 pages that tell the two apart; depth2_zedge — 13 triangles near the
  origin, tiny and signed-zero coordinates, an infinite corner: an edge of +0 against one of +-(1 .. 1.5) 2^-126 makes
  the infinite depth's term of the constant 0 or an infinity; without the rule there (`zeroRuleEdges` 0) other words
  at all 160 pixels; 65 of 65 regions with it, 110 probe pixels on 29 pages that tell the two apart]. It is the
  depth unit's own: the edge unit's `c`, `dx`, `dy` and determinant have no zero rule (6.2). **[R]** refsw3
  tests `|v| < 1.5 * 2^-126` as "the bit under the leading one is 0", which is a shift by -1 for a one-bit mantissa
  (`v = 2^-126` as `{mant 1, exp -126}`, a sum can be that). The value rule is what is meant (num §8 D2).
- **Underflow** [T: zspec pages 3-6 — a plane from 2^-124 to -2^-124 over a cell is its start everywhere, one from
  2^-126 to -2^-126 is 0; detinf 480 of 480].

Ranged: every operation of 9.2, the tile's start `first0` (9.3), and the mean (9.4b). Since `708fb8cd`, `first0`
is also the start the block form steps from [T: depthgaps_tinyramp — a ramp with a corner at the tile's start a
denormal, read as zero, slopes of about 2^-126: 16 pixels along the zero crossing are below zero on the console,
above it with the start taken in plain arithmetic and only then cut to the range; 14 regions pixel for pixel].
**The reciprocal's range** (`4f3efe15`, depth.h L463): a determinant of 2^126 or more, 2^126 itself included, has a
reciprocal of zero, and every product with it is zero: the depth is 0 at every pixel (9.3 step 1b), as with an
infinite determinant. refsw3 tests the determinant's exponent, `top(det) - 1 >= 126`, before `Recip`, so the
reciprocal of exactly 2^126 (2^-126 as a number) is zero too. Below 2^126 `Recip(det, 24)` itself is plain (6.2): a
ranged `det` is then in [2^-126, 2^126), so `inv` is in (2^-126, 2^126] and never needs a limit of its own.
[T: trsort_recip — one triangle over the screen of determinant exactly f 2^126 under 10 flat probes from +0 to 2,
DepthMode Greater: f = 0.5, 0.75, 1 - 2^-24 an ordinary depth of 1; f = 1, 1 + 2^-23, 1.25, 1.5, 2, 3, 4 - 2^-22 (and
4, an infinite determinant) a depth of 0, every probe from 2^-100 up drawn, +0 and 2^-126 not (page 3 for f = 1); f =
1 and 1 + 2^-23 with the other winding, and with corners of 1, 0.5, 0.25, the same; with the reciprocal of 2^126
kept as 2^-126, 24 regions of 160 wrong; page 10, a determinant of 2^128 from corners of 2^116, as at f = 1; trsort_recipovf — f = 1 and 1 - 2^-24 with corner depths inf 1 1, 1 2^127 1, 2^120
x3, -inf 1 1 under 10 probes from -2^127 to 1.5 2^127: at f = 1 a depth of 0 with each, the products' overflow does
not matter, 80 of 80 regions (2^126 kept: 52; no limit: 52); trsort_auto — hugepos's three triangles, every corner at
depth 1, in the translucent list sorted per pixel: b, determinant +2^127.7 at M = 2^116, is not drawn at all over a
background of 0.0001 (pages 5 and 10: none of its 248,789 pixels; with the reciprocal kept, a depth of 1, all of
them), and over a background of -1 ties with a and c (infinite determinants, depth 0) and is drawn in the tags'
order (page 15; with the reciprocal kept 144,629 pixels wrong); 240 of 240 regions, 202 before; trsort_single,
trsort_garb: 10.3].

Unranged (the plain arithmetic of 6.2): `Recip(det, 24)` below that limit; the slopes `A = Mul(a, inv, 24)`, `B =
Mul(b, inv, 24)` (9.4a); the register steps `Mul(a or b, inv, 24)` (9.5). After the slopes, values below 2^-126
become zero with their sign kept (`under`, depth.h L673-674). A slope after the division can reach 2^254 and steps as a number
[T: depthgaps_edges — a top right corner of (2 - 2^-23) 2^124 with legs 8: `a` just under 2^128, 2^122 a pixel;
legs 12 at 2^118 a pixel: they step from a start of 0]. **GAP**: no test isolates a slope of 2^128 or more after
the division (a determinant below 1 with finite `a`, `b`). (The reciprocal's limit above is at the other end: a
determinant of 2^126 or more.)

## 7. Triangle setup: determinant, bad corners, culling, perpendicular

Per primitive, before any tile work (`RasterizeTriangle`, `TriangleCulled`).

### 7.1 Determinant and winding (`pvrisp::EdgeWinding`; bad corners from `pvrisp::Winding`)

Corners 1, 2, 3 in rasterizer order (3.4); for quads the first three. `EdgeHW` arithmetic (24-bit products, 24-bit
sums, reach 25), unranged, `FromBits` inputs. refsw3 computes two determinants (refsw_tile.cpp L782-783; L756-759
for the chunk counter's `TriangleCulled`):

```
plain (Winding, edge.h L86):        e(j,k) = Sub(Mul(xj, yk), Mul(xk, yj))
                                    det_p  = Add(Add(e1, e2), e3)           e1 = e(2,3), e2 = e(3,1), e3 = e(1,2)
                                    bad    = det_p.bad: an x or y of corners 1-3 is an infinity or a NaN
swamped (EdgeWinding, edge.h L113): sw(v)  = |v| >= 2^128 ? +-2^200 (v's sign) : v            # the swamp (8.3)
                                    e(j,k) = sw(Sub(sw(Mul(xj, yk)), sw(Mul(xk, yj))))
                                    det    = sw(Add(sw(Add(e1, e2)), e3))
winding: sgn = +1 if det < 0 (nonzero), else -1 (det >= 0, a zero counts as positive)
```

The winding and both culls (7.2) use the swamped `det`. The plain one only reports bad corners. The two are equal
while every product and sum stays below 2^128. +-2^200 is beyond every adder's reach of a finite operand (top 201
against at most 128), so a swamped term drops every finite one. A swamped term less one of the same sign (or plus
one of the other sign) is exactly +0, and the sum of two of one sign is swamped again.

[T: faredge_m131 pages 6-15 — 1,878 slivers whose two long edges run to a corner at y +-2^127 .. +-2^127 (1 + 3/32):
with the plain determinant 296 tiles of the test are wrong, with the swamped one 0; they are triangles whose plain
and swamped determinants differ in sign, drawn as the swamped one turns them; held out: faredge_ecap pages 6-15
(1,957 such slivers: plain 1,007 tiles wrong, swamped 0), faredge_walk (647 against 0), faredge_far32 (408 against
0); covmeas rule 2 and 9 — the console follows the setup's determinant, not the exact area: 1,041 sliver triangles
with the opposite sign, ~5,500 with det exactly 0 taking the positive winding; hugepos b — exact area 0 in double
from 2^62, the setup's det draws what the console draws; precision / zmeas — the (e1 + e2) + e3 order]

**Bad corners**: if any x or y of the 3 corners (4 for a quad: the fourth is checked on its own) is infinity or NaN,
the primitive draws nothing. It is not "culled" (that matters for PT chunk counting, 11.4) [T: huge — infinity or
NaN in one coordinate: nothing drawn].

### 7.2 Culling (`CulledBySize`, `CulledByFacing`, refsw_tile.cpp L726, L738)

Only with `CullMode != 0`, and only when no corner is bad. `det` is the swamped determinant of 7.1:

```
culled = CulledBySize(det) || CulledByFacing(CullMode, det)
CulledBySize(det):
    if det is bad: false
    S = FPU_CULL_VAL & 0x7FFFFFFF
    if S >= 0x7F800000: true                              # +-infinity or any NaN: every triangle
    return |det| <= FromBits(S)                           # exact compare, equal culls; S = 0 culls det == 0
CulledByFacing(mode, det):
    if mode < 2 or det is bad or det == 0: false          # -0 is not negative
    mode 2: det < 0;  mode 3: det > 0
```

So a swamped determinant (+-2^200) is never culled by size, and one whose swamped products cancel to +0 always is.
[T: faredge_cull — 300 triangles, the same on four pages with CullMode none, small, negative, positive; in 240 the
plain and the swamped determinants have opposite signs: every one is culled by the swamped determinant's facing (12
negative by the negative mode, 14 positive by the positive mode), and the 214 whose swamped products cancel to 0 by
size, in modes 1-3 alike; the 60 controls as before; with the plain determinant 484 of the test's 1,200 regions are
wrong; cullval — 16 pages, FPU_CULL_VAL 1, -1, 2, -2, 0.5, -0.5, +0, -0, +-inf, NaN, -NaN, sNaN, +-2^-149, 1e30:
only the size counts, every NaN culls like +inf, 2^-149 culls nothing, 4800 of 4800 regions; raster page 4 — legs of
1 pixel at 1.0: equal is culled; covmeas degen — with any culling mode degenerate triangles draw nothing]. A culled
primitive costs the ISP 15 clocks (section 14).

### 7.3 FPU_PERP_VAL (`pvrfp::Perpendicular`)

`perpVal = FromBits(FPU_PERP_VAL & 0x7FFFFFFF)`, set once per render (the sign does not count; any value
`>= 0x7F800000` is +infinity, NaNs included). It is used by the **depth unit** on **its own** (ranged) determinant
(9.2), not by the edge unit:

```
Perpendicular(det):
    det == 0 (not bad): false (already zero)
    det bad:            perpVal is infinite
    else:               perpVal (infinite or nonzero) && |det| <= perpVal       # equal counts
```

A perpendicular triangle gets the depth of a determinant-zero triangle (the mean, 9.4); its coverage is unchanged
(the edge unit does not look at it). [T: perpval — 0, 1/128, 1.0, 2^20, -1, +inf on 16 sets, every pixel the console
changes (3,933 / 10,915 / 136,764); perpeq — 15 pages, a determinant equal to the value counts, 1800 of 1800; detinf
and perpval at 7fc00000, ffc00000, ff800000, 7f800001 byte for byte the +inf pages; 22 polly2-data dumps set 1/128]

## 8. The edge unit (`pvr_isp_edge.h`)

### 8.1 Edges of a primitive

Triangle (corners 1, 2, 3): E12 = 1->2, E23 = 2->3, E31 = 3->1. Quad (corners 1, 2, 3, 4): E12, E23, E34 (the
"third edge" ends at corner 4), E41. Every edge is set up per tile with the primitive's winding `sgn` (7.1, from
corners 1-3 for a quad as well) [T: covmeas sprite14, sprite15 — "four edges, winding from the first three corners",
0 misses].

### 8.2 The unit's numbers (`EdgeHW`, edge.h L42)

| constant | value | meaning |
|---|---|---|
| `productBits` | 24 | every product `x*y`, `dx*y0`, `dy*x0` cut to 24 significant bits (truncate) |
| `sumBits` | 24 | every sum cut to 24 bits (truncate) |
| `reach` | 25 | an adder operand whose top is 25 or more below the other's is dropped |
| `guard` | -1 | the tile start's adds are exact before the cut (no guard limit) |
| `startBits` | 20 | the tile start kept as a 20-bit float (truncate) |
| `slopeBits` | 20 | the steps kept as 20-bit floats (truncate) |
| `pairBits` | 21 | both steps cut to 21 bits under the larger one's exponent |
| `blockAdd` | 6 | E = top(larger step) + 6 ... |
| `startAdd` | 1 | ... or top(start) + 1 if that is more |
| `zeroShift` | 21 | "zero": `\|v\| <= 2^(E - 21)` |
| `tieShift` | 21 | the column step counts as zero for a row starting at zero when `\|sx\| <= 2^(E - 21)` |
| `overflowExp` | 128 | a product or a sum of the start (and of the winding's determinant, 7.1) that reaches 2^128 swamps every other operand (8.3) |
| `saturateExp` | 127 | the start then saturates to +-2^127; a coordinate difference of 2^128 or more steps as +-2^127 |
| `lastColumnByStep` | true | a zero pixel in column 31 is inside iff the column step is positive |
| `blockMax` | 129 | E is at most 129; an edge whose E was cut is "big" and is walked down the tile (8.4b) |
| `cutUnitBits` | 27 | an edge whose E was cut keeps its start and steps in units of 2^(E - 27) = 2^102, cut toward zero (8.3) |
| `walkExp` | 131 | the walk holds R and R + 16 sx in [-2^131, 2^131) (blockMax + 2), and 32 sx below 2^131 |

[T: covmeas — 98 archived sets, 55 M pixels, 0 differences; every single change of a parameter is worse (tie
threshold 63: 30 pixels, 32: 375, 128: 246; reach 24: 3, 26: 34; zero zone 63: 1122, 65: 32); hugepos;
precision page 5 / raster 1040 of 1040; faredge 1,340 of 1,340 and faredge_cmax, _k132, _m131, _ecap, _walk, _cull,
_far32 for the last five rows (8.3, 8.4b); edge2_walk pages 3-5 for `cutUnitBits` (8.3)]

### 8.3 Edge setup per tile (`EdgeTile::Setup`, edge.h L156)

Inputs: corners `a = (xa, ya)`, `b = (xb, yb)` (FromBits), `sgn` (7.1, the swamped determinant's), and the tile's
first sample point `x0 = left + h/2`, `y0 = top + h/2`, `h = HALF_OFFSET[0]` (1: pixel centres, 0: pixel corners).

```
if xa, ya, xb or yb is bad: CONSTANT, nothing inside   # unreachable: a bad corner ends the primitive first (7.1)
sw(v)  = |v| >= 2^128 ? +-2^200 (v's sign) : v          # the swamp: {mant 1, exp 200}, beyond every adder's reach
sat(v) = |v| >= 2^128 ? +-2^127 (v's sign) : v
c     = sw(Sub(sw(Mul(xb, ya)), sw(Mul(xa, yb))))      # 24/24, reach 25
dx    = Sub(xa, xb);  dy = Sub(ya, yb)                 # 24, reach 25; |dx|, |dy| < 2^129
first = sw(Add(sw(Mul(sw(dx), y0)), -sw(Mul(sw(dy), x0))))   # products 24; sum exact, cut 24; reach 25
start = sat(Add(first, c))                             # exact, cut 24, reach 25
dx, dy = sat(dx), sat(dy)                              # the steps: a difference past 2^128 steps by +-2^127
sy = cut20(dx)                                         # row step
sx = cut20(-dy)                                        # column step
ep = max(top(dx), top(dy));  es = top(start)           # ep <= 128, es <= 128
if ep == NoExp and es == NoExp: CONSTANT, INSIDE       # a -> b is a point: zero everywhere counts as inside
s20 = cut20(start)
if sgn < 0: s20, sx, sy = -s20, -sx, -sy               # turn the edge so that inside is positive
if ep == NoExp: CONSTANT, inside = (s20 >= 0)          # (unreachable in practice: dx = dy = 0 forces c = 0)
E    = max(ep + 6, es + 1)        (es + 1 only if start != 0)
big  = E > 129;  if big: E = 129                       # big <=> ep >= 124: a step of 2^123 or more
unit = big ? E - 27 : ep - 21                          # exponent of the steps' last kept bit; 2^102 for a big edge
if E - unit > 56: CONSTANT, inside = (s20 >= 0)        # [R] refsw3's cap; never for a big edge (E - unit = 27)
sx = cutBelow_unit(sx);  sy = cutBelow_unit(sy)        # toward zero
t0    = big ? 2 * trunc(s20 / 2^unit)                                           # a big edge: cut toward zero, no half unit
            : 2 * floor(s20 / 2^unit) + (s20 not a whole multiple of 2^unit ? 1 : 0)   # half units of 2^unit
tx    = 2 * sx / 2^unit;   ty = 2 * sy / 2^unit                                 # exact, even
zero2 = 2^(E - 20 - unit)                                                       # half units; = 2^(E - 21) in value
tie2  = zero2                                                                   # tieShift == zeroShift
if big:                                                # the walk's values (8.4b) are these: one grid, 2^102
    f0, fx, fy = t0, tx, ty
    H    = 2^30                                        # = 2^131 in value (walkExp): 2 << (131 - 102)
    Z    = zero2 = 2^7                                 # = 2^108 in value (ZERO at E = 129)
    walk the tile from row 0 (8.4b); the row range sets the first row and the walk is redone (8.6)
```

The edge function is `F(x, y) = c + dx*y - dy*x` (zero on the line through a and b, `F` stepping `-dy` per column,
`dx` per row). The values above are `F` at the tile's first sample point and its two steps, in block form, turned so
that the triangle's inside is positive. `t0`'s lowest bit marks "the start has bits below the grid" (it then lies
strictly between two grid values; never for a big edge, whose start is cut toward zero onto the grid). `big` and
"E was cut" are the same thing: `es + 1 <= 129` always, so only `ep + 6`
can pass 129; refsw3's `big = cut && ep >= 124` (L285) is the cut. (edge.h's prose says "a step of 2^124 or more";
its test, `E > blockMax`, is `top(step) >= 124`, a step of 2^123 or more.) Before `1040c4aa` a big edge kept two
grids: `2^(ep - 21)` for the ordinary rows and a finer `2^(ep - 27)` for the walk, with the start floored; both are
gone.

Rules and their tests:
- the constant `c` from absolute coordinates, `c = T(xb ya) - T(xa yb)` [T: covmeas rule 1 — forms from coordinate
  differences are far off, 77 %];
- the start at the tile's first sample point, kept as a 20-bit float; the first sum drops an operand 25 exponents
  below the other (first tile column / row, where x0 or y0 is 0.5) [T: covmeas rule 3];
- the steps as 20-bit floats sharing the larger one's 21-bit grid [T: covmeas rule 4];
- **the swamp, per product**: a product of the start (`xb ya`, `xa yb`, `dx y0`, `dy x0`), or the sum `c` or `first`,
  that reaches 2^128 swamps every other operand, so that the start saturates to +-2^127 with its sign. It is the
  product that counts, not `c` or the start [T: faredge_cmax — 16 pages, one edge per tile, 4,800 of 4,800 tiles;
  group A, 4,446 tiles, among them 755 where one product is exactly 2^128 and the other takes 2^105 from `c`: `c`
  and the start below 2^128, saturated all the same; faredge page 4's first-column strip (`xa yb` = 2^128.23, the
  start 2^127.68: saturated, the strip not drawn) and page 1's control strip (`xb ya` = 2^128.12, the start
  2^125.62: 2^127, the edge 18 pixels into the tile); hugepos]. Two swamped values of one sign cancel exactly
  [T: faredge_cmax page 11 (`c`'s products 2^128.5 and 2^128.0 of one sign: the start is `first` alone, its sign
  changing with the row at y = 181 as `first`'s does), pages 14 and 15 (`c` = -2^139.7 and `dx y0` = +2^128.05 in the
  tile's first row: 0, the row decided by the column step); faredge_k132's RV tiles (4,560: near-vertical edges with
  |far y| past 2^127, `c`'s product and `dy x0` past 2^128 with opposite signs: the start 0, the rows j dx)]. So
  `first` past 2^128 gives the start its sign, `c` past 2^128 its own (as hugepos had it).
- **saturation at 2^127** [T: hugepos a — the console's pixels exactly at 2^118 .. 2^124: 15,019, 705, 15, 2];
- **a coordinate difference of 2^128 or more** swamps in the start's products but steps by +-2^127 [T: hugepos_v4,
  _v5, _v6 (as an infinite step 68,397 / 67,565 pixels of v5 / v6 wrong), hugepos_cov pages 6-9 and 26-29,
  hugepos_sw2 pages 7-10, 18-21 and 29-32, hugepos_rules page 8 (|dx| or |dy| of 2^128 .. 1.75 * 2^128; hugepos's
  triangles a and c are not drawn, a at 2^125 with dx = -2^128 exactly has its 4 pixels in row 0 only)];
- **E at most 129** [T: faredge_m131 pages 0-5, columns 1-19 — edges with the column step -(2^127 + d 2^108) and a
  start of 0, rows R = j dx: R from 2^112 up is not ZERO, pixel 0 is drawn (E = 134 made rows up to 2^113 ZERO:
  1,165 of the 1,800 tiles wrong, 0 with the cut); faredge_k132's RV tiles (2^108 exactly is ZERO, 2^108 + 2^104
  not); faredge_ecap pages 0-5 (1,440 edges with |far y| in [2^123, 2^127), E 130 .. 133 before the cut, the rows
  R = j dx crossing 2^107 .. 2^112 in row 4, 8 or 16): 129 gives every tile, 130 has 1,424 wrong, 131, 132 or no
  cut 1,440; hugepos_rules pages 0-3 (1,200 tiles of the H family: with a row step of 2^124 or more and a small
  column step it is the walk that shows it)].
- **a big edge's grid is 2^(E - 27) = 2^102**, the steps and the start cut toward zero onto it, for the ordinary rows
  as for the walk (edge.h L233-243, L273-277) [T: edge2_walk pages 3-5 — 900 tiles, one triangle per tile, a
  near-horizontal edge to a far corner at x 2^124 .. 2^128, its column step with bits below 2^104 and near zero in a
  row of the tile, kept where the alternatives differ: 2^(E - 27) every tile; 2^(E - 26) 240 wrong, 2^(E - 28) 428,
  2^(ep - 25) 435, 2^(ep - 26) 478, 2^(ep - 27) 557, the steps floored 135, `708fb8cd`'s 2^(ep - 21) for the rows and
  2^(ep - 27) for the walk 339; faredge_m131 alone allows 2^101 .. 2^103, and the hugepos_* and faredge_* sets are
  exact with it. hugepos_rules page 11 (10 tiles, refsw3's residual at `708fb8cd`) was this: its slivers' column step
  629,145 2^106 (0.3 2^127) lost its last bit on 2^(ep - 21) = 2^107, and pixel 7 of row 2 came out +2^109, inside;
  it is +2^106, in the ZERO band, a tie the next pixel (negative) makes outside]. The start toward zero, no half
  unit [T: edge2_walk pages 3-5 — 5 tiles with a start just below zero, -120.x units, whose pixel at -64.x units,
  just outside ZERO when floored, is drawn: in the band as -64; floored, with or without the half unit, 5 tiles
  wrong, cut toward zero 0].

### 8.4 The inside decision (`EdgeTile::Inside`, edge.h L440)

`Inside(i, j)` is the constant answer for a CONSTANT edge, row j's mask bit i for a big edge (8.4b), and the
ordinary decision (8.4a) otherwise.

#### 8.4a Ordinary edges (`InsideOrdinary`, L306)

For pixel (i, j) of the tile:

```
r = t0 + ty * j                                  # the row's value at the tile's FIRST column
if |r| <= zero2:                                 # the row starts at zero: the whole row of this tile gets one answer
    return (|tx| <= tie2) ? (ty > 0) : (tx > 0)
v = r + tx * i
if v >  zero2: return true
if v < -zero2: return false
if i == 31:    return tx > 0                     # the last column has no next pixel (lastColumnByStep)
return v + tx >= -zero2                          # a zero pixel is inside if the next pixel to its right is not negative
```

A pixel is inside the primitive when it is inside all 3 (4) edges **and** its row is in the row range (8.6; not for
modifier volume triangles).

What this gives [T: covmeas rules 5-8, all its runs 0 differences, including strips, sprites, modifier volume
triangles, the translucent and PT lists, HALF_OFFSET 6 and 1, corners 29,212 pixels off screen]:
- "zero" is a zone of +-2^(E-21) (64 grid units of 2^(E-27)): a pixel centre up to ~2^-14 pixel from the edge is on
  it;
- the top-left rule for edges through pixel centres: a zero pixel on a left edge (next pixel positive) is in, on a
  right edge out; a nearly horizontal edge whose row starts at zero is in or out along the whole tile row (top edge
  in, bottom edge out), whatever its own lean;
- on an edge that leans by less than a zone per pixel, tie pixels are inside whichever way it leans, up to the last
  one before the values go negative, so two triangles sharing such an edge can both draw those pixels;
- an edge between two equal corners is inside everywhere: three equal corners fill the full 32-pixel width of their
  tile's rows within the row range [T: covmeas degen40 — 234 of 234 point triangles, 11,456 pixels]; a repeated
  corner or three collinear corners draw nothing (two real edges disagree on every tie) [T: degen40, degen41].

`EdgeTile::RowOutside(j)` (`r < -zero2 && r + 31 tx < -zero2`, or the row-zero rule giving false; for a big edge
"row j's mask is 0") skips rows that no pixel can be inside. It is exact (the values are linear in i) and only saves
time **[R]**.

#### 8.4b Big edges: the walk down the tile (`EdgeTile::Walk` L397, `RowMask` L322, `SetFirstRow` L297)

Each row j of a big edge gets a 32-bit mask, computed down the tile from the polygon's first row `s` in it (8.6;
`s = 0` until the row range sets it, and for modifier volume triangles). Every value is in half units of 2^102, the
edge's own grid (8.3), so `f0 = t0`, `fx = tx`, `fy = ty`, `Z = zero2`:

```
wrap(v)  = v mod 2H, taken in [-H, H)                       # R held in [-2^131, 2^131): mod 2^132
far32    = fx > 0 ?                    (32 fx) mod H         # 32 sx, its bits from 2^131 up lost
         : fx < 0 and (32 fx) mod H == 0 ? H                 # a column step below zero, a multiple of 2^126: 2^131
         : 0
rowmask(r):                                                 # the ordinary rule without the tie step
    if |r| <= Z: all 32 pixels if fx > 0, else none
    per column i: v = r + fx i;  v > Z: in;  v < -Z: out;  i == 31: in iff fx > 0;  else in iff v + fx >= -Z
dead = false;  wasAbove = false
for j = 0 .. 31:
    ord = row j by the ordinary rule (8.4a: t0, tx, ty, zero2, tie2)
    if j < s:   mask[j] = ord;  continue                     # above the first row (the row range removes them)
    if dead:    mask[j] = 0;    continue
    R  = f0 + fy j;  Rw = wrap(R)                            # the row's value at column 0
    above    = Rw + far32 > Z                                # the row's far value is above ZERO
    endsHere = j > s and wasAbove and not above;   wasAbove = above
    if |Rw| <= Z:
        mask[j] = (Rw == R) ? ord : (fx > 0 ? all : fx == 0 ? (fy > 0 ? all : none) : none)
    elif fx == 0 or (Rw > 0) == (fx > 0):                    # R and the column step of one sign
        mask[j] = (Rw == R) ? ord : (Rw > 0 ? all : none)
    else:
        M = Rw + 16 fx                                       # the row's value at pixel 16
        if M >= H or M < -H:  mask[j] = rowmask(Rw + (Rw > 0 ? 2H : -2H))     # the push: R + sign(R) 2^132
        else:                 mask[j] = (Rw == R) ? ord : rowmask(Rw)
    if endsHere: dead = true                                 # this row as decided; every later row outside
```

What it means, with its tests (faredge_walk: 16 pages, 3,537 tiles, one triangle per tile, generated where the
alternatives differ; with edge2_walk, edge2_end and edge2_mult the 43,612 tiles of the sets of one triangle per tile
all exact, and every faredge_* / hugepos_* set exact in the regression, hugepos_rules 3,600 of 3,600 and hugepos_v5
2,400 of 2,400 included; edge.h L344-396):
- **R wraps by 2^132** into [-2^131, 2^131) [T: hugepos_rules pages 0-3 — the H family's long edges, a column step
  of 0 and rows R = start + j dx of -2^131 .. -2^132 inside, as R + 2^132; faredge_m131 page 11 tile (1, 9) — rows
  with R past +-2^132 drawn as R -+ 2^132; faredge_walk pages 8-11 — a polygon whose first row in the tile has R past
  2^131 is wrapped like any other]. Unwrapped (`Rw == R`) the row is decided by the ordinary rule.
- **R and the column step of one sign** (or a zero step): a wrapped row is all on R's side [T: faredge's K 127: the
  far edge, R = 2^127 and the step of one sign, stays inside].
- **The push**: otherwise the row's value at pixel 16 is held in [-2^131, 2^131) too; a row where it is out of range
  is evaluated as R + sign(R) 2^132 [T: faredge_k132 group K — 240 tiles, the switch row where |R + 16 sx| reaches
  2^131; faredge_m131 pages 0-5 — 1,800 tiles: -2^131 exactly is not pushed, +2^131 is; faredge's K 127 vertical
  triangles; modvol's garbage polygon]. Since R is wrapped first, only a column step past 2^127 takes R + 16 sx out
  of range.
- **The end**: the edge ends when its far value falls from above ZERO to ZERO or below. The far value is
  R + (32 sx mod 2^131) with a column step above zero (the row's value at pixel 32, 32 sx held below 2^131),
  R + 2^131 with a column step below zero that is a multiple of 2^126, else R. For an ordinary edge (32 sx < 2^131)
  that is only the row going outside to its end, which a later row cannot undo; with a column step of 2^126 or more
  it ends the edge early [T: faredge_m131 pages 6-15 — 32 sx = 2^132 + rho, the far value R + rho, at most 0 there:
  the rows after it dark, 9,694 of 9,708 rows, the 14 others in slivers that start inside the tile, which count from
  their own first row; hugepos_rules page 11 and hugepos_v3 page 6 — slivers whose line ends after the row whose
  value at pixel 32 is at most 2^131 (32 sx = 2^131 + rho); faredge_walk pages 4-7 (32 sx past 3 * 2^131);
  hugepos_sw3 pages 36 and 37 — two edges wrapped past 2^131 that keep a one-pixel line between them when rho is
  just above the size of the wrapped R, against pages 0 and 9 (32 sx of 2^132 and 3 * 2^131, rho 0); hugepos_rules
  page 0 tile (0, 0) — R falls from +2^127 to 0: outside after it, not wrapped back past -2^131].
  - **Against ZERO, not 0** [T: edge2_walk pages 3-5 — 12 tiles, an edge with a start of 0 and a column step of one
    unit, R + 32 sx = 2^107 in its first row: it does not end in the next row; with "above 0" the 12 are wrong].
  - **sx < 0: R alone** [T: 482 tiles of these sets need the end there; R + sx (pixel 1) 54 of them wrong, R + 32 sx
    623; edge2_end page 3 — 66 tiles with -2^127 (1 +- 2^-19 .. 2^-8): R alone (R + 2^131 within 2^117 of -2^127: 66
    wrong); page 4 — 66 where +2^127 ends with R alone (R + 2^131 with +2^127 too: 66 wrong)].
  - **sx < 0 a multiple of 2^126** (32 sx = 0 mod 2^131: -2^126, -2^127, -1.5 2^127, a saturated difference or
    not): **R + 2^131**, so the edge ends only where R falls to -2^131 + ZERO or below [T: edge2_walk pages 0-1 —
    600 tiles, two far corners on opposite sides in y, |dy| from 2^128, a saturated column step of -2^127 — and page
    2 — 61 tiles, a far corner at y = +-2^127 exactly: every one goes on after the row where R falls from +15.x 2^127
    to -15.x 2^127 (R alone: all 661 wrong; hugepos_v5 page 0 tile (0, 7), 79 pixels, refsw3's residual at
    `708fb8cd`, was one); faredge_ecap pages 7 and 9 tiles (0, 4) and (0, 9), where R reaches -2^131 exactly, do end
    (no end at all: 2 tiles wrong); edge2_end — 280 tiles, all as modelled: page 0, 56 with -2^127 (R alone: 56
    wrong); page 1, 37 whose R reaches -2^131 exactly or nearly (no end at all: 37 wrong; R alone 4); page 2, 55
    with -2^126 and -1.5 2^127 (R + 2^131 for -2^127 alone: 55 wrong)]. **Odd multiples of 2^125 and 2^124 end with R
    alone** [T: edge2_mult — 58 tiles, -2^125, -3, -5, -7 2^125 and -1 .. -15 2^124: R + 2^131 for every multiple
    of 2^125 29 wrong, of 2^124 58].
  - A reading of the mechanism (edge.h L389-394, not a rule of its own: the same function of sx, so no test can
    separate the two): 32 sx reaches the far value's adder as a sign and its bits below 2^131; a negative one is made
    two's complement by invert + 1 on those bits, which the sign then gates off, while the carry out of the + 1
    (there exactly when the bits are all zero) is not gated and lands at 2^131.
- **From the polygon's first row**, not from row 0 [T: counted from row 0, 1,462 tiles of all sets wrong
  (faredge_walk 1,351)].
- Alternatives the sets reject: 32 sx kept whole (no mod 2^131) 15,863 tiles wrong; 0 counting as above 7,869.
- The walk's units are the edge's own (8.3: edge2_walk pages 3-5). `708fb8cd`'s GAPs here (the fine units
  2^(unit - 6), the end rule with sx < 0, the residuals hugepos_rules page 11 and hugepos_v5) are closed.

### 8.5 Widths for the RTL (derived, checked against refsw3 `4f3efe15`)

Let `d = E - unit`.

Ordinary edges (not big): d is 27..56.
- If **d >= 30**, the whole tile has the start's sign: `inside = (s20 >= 0)` for every pixel. (Then `E = es + 1`,
  `|t0| >= 2^29`, while 62 steps add less than 2^28 half units.)
- If d <= 29, every value the decision looks at (`r`, `v`, `v + tx`) fits a **31-bit signed** integer in half
  units of 2^unit: `|t0| < 2^29`, `|tx|, |ty| < 2^22`.

Big edges: `d = 27` (unit 2^102, never CONSTANT), `zero2 = Z = 2^7`, `H = 2^30` half units, all fixed. `|t0| =
|f0| < 2^27` (the start below 2^128), `|tx|, |ty| < 2^27` (the steps below 2^128). Every value is below 2^32.4 in
size:
- the walk: `|R| <= |f0| + 31 |fy| < 2^32`; `|Rw| <= 2^30`; `R + 16 sx` (opposite signs) below 2^31; a pushed value
  below 3 * 2^30; the rowmask values below 3 * 2^30 + 32 |fx| < 2^31.6; `Rw + far32` below 2^31; `far32` in
  [0, 2^30];
- the ordinary rule on the rows the walk takes it for (`Rw == R`, so `|r| <= 2^30`): `r + tx i`, `r + tx (i + 1)`
  below 2^30 + 32 * 2^27 < 2^32.4. (Rows the walk does not take it for, above the first row or wrapped, are never
  used; refsw3's `InsideOrdinary` computes them, up to 2^33.)

A **34-bit signed** row accumulator and lane holds every value used. In half units of 2^102, `wrap` is the low 31 bits
of R read as two's complement; the push is "`Rw + 16 fx` overflows 31 bits"; `far32` is `(fx mod 2^25) << 5` for
`fx > 0`, `2^30` for `fx < 0` with `fx mod 2^25 = 0`, else 0.

Checked with refsw3's own `EdgeTile` (`polly2-rtl/agents/spec-sync-edge/widths4f3.cpp`, 3 s): 299,962 random edges
(pixel-grid and ulp-perturbed corners, a wide exponent mix, one in three of the far class: one corner near the tile,
the other with a coordinate of 2^118 .. 2^127; both windings, both sample offsets), 102,632 of them big. `big`
exactly when `ep >= 124`, with `t0 = f0`, `tx = fx`, `ty = fy`, `zero2 = z = 2^7`, `h = 2^30` on every big edge;
ordinary d 27..56; 91,018 tiles with d >= 30, every pixel of the start's sign; the largest ordinary value below
d = 30 2^29.48; big d 27, `|f0|` 2^26.998, `|fx|, |fy|` below 2^27; R 2^31.98, wrapped R 2^30, R + 16 sx 2^31.00, a
pushed row and the rowmask values 2^31.58, the far value 2^30.99, the ordinary rule on unwrapped rows 2^32.31; and
the walk as 8.4b writes it against `EdgeTile::Inside` at every pixel for first rows 0 .. 31: 0 differences.

### 8.6 Row range (`pvrisp::RowRange`, edge.h L130; refsw_tile.cpp L815-847)

For every primitive that is not a modifier volume triangle:

```
rowFirst = min over corners of floor(y)
rowLast  = max over corners of floor(y + 1/2)          # = (floor(2y) + 1) >> 1 (arithmetic shift); FloorScaled, clamp 2^40
if rowFirst == top + 31:  rowFirst -= 1                                         # row 31: a row earlier, every polygon
every big edge: SetFirstRow(clamp(rowFirst - top, 0, 31))                        # the walk starts there (8.4b)
a row Y (screen row, top + j) is rasterized only if rowFirst <= Y <= rowLast
```

Over all corners (4 for a quad), the same in row numbers whatever HALF_OFFSET is; no limit on columns. [T: covmeas
rule 10 / sliver mixes — 0 of 635 accepted pixels above the top corner's row are drawn, 0 of 483 two rows below, the
row after the bottom corner's exactly when frac(ymax) >= 0.5 (72 of 72 / 0 of 70); sliver35 with HALF_OFFSET 6;
zprobe — outside the range the depth is not written either; sliver36 — modifier volume triangles have no range]

**Row 31**: a polygon whose first row is the tile's last starts a row earlier in that tile, the walk of its big
edges as well; **every polygon**, with or without a big edge (since `1040c4aa`; `6784ea3d` had it only with a big
edge) [T: faredge_walk pages 0-3 — slivers to a far corner whose top corner is in row 28 .. 31 of the tile; their
pushed edges draw in the row above the top corner when the row range lets them: with the plain range 366 of the
test's 3,537 tiles wrong, with this 0; rows 30 and 31 both a row earlier 272, a top corner in the last quarter of its
row 892; held out, faredge_far32: 390, 0, 36, 440; faredge_m131 page 6 tile (17, 8), page 11 tile (2, 10),
faredge_ecap page 9 tile (7, 7): row 30 drawn; edge2_walk page 6 — points (three equal corners, whose edges are
inside everywhere) and triangles of corners 1/1024 apart at y = row + 0, 1/4, 1/2, 3/4, 1023/1024 of rows 28 .. 31
of their tile: with the top corner in row 31 rows 30 and 31 are filled (25 points, 18 tiny triangles: 43 tiles wrong
with the rule for big edges only, 0 with it for every polygon); in rows 28 .. 30 none starts earlier (225 tiles);
edge2_row31 — 300 of 300 tiles, the same probes with no user tile clip, with the clip of their own tile and with
one of the 3x3 tiles around it: in each, the 13 points with the top corner in row 31 fill rows 30 and 31, and 9, 9,
10 of the 12 tiny triangles there draw in row 30; none of the 75 in rows 28 .. 30 starts earlier: the user tile clip
has no part in it]. A tiny triangle draws in row 30 only where its edge functions accept a pixel there (the 12
triangles: 9 or 10 do). **GAP**: why row 31 (not known; refsw_tile.cpp L838).

Modifier volume triangles have neither the range nor the row-31 rule; their big edges are walked from row 0.

## 9. The depth unit (`pvr_isp_depth.h`)

### 9.1 The unit's numbers (`DepthHW`, depth.h L41)

| constant | value | meaning |
|---|---|---|
| `productBits` | 24 | every product (z * difference, z * e, a * x0, b * y0) truncated to 24 bits |
| `sumBits` | 24 | every sum truncated to 24 bits |
| `reach` | 25 | adder alignment reach (measured on the edge unit) |
| `recipBits` | 24 | 1 / det truncated to 24 bits |
| `coefBits` | 24 | `a*inv`, `b*inv`, `c*inv`, the register steps' `a*inv`, `b*inv` truncated to 24 bits |
| `startBits` | 20 | the tile's start kept as a 20-bit float (truncate); also a negative flat depth's first cut (9.7) |
| `slopeBits` | 20 | the slopes as 20-bit floats (truncate) |
| `pairBits` | 21 | both slopes cut to 21 bits under the larger one's exponent |
| `tileBits` | 26 | the stepping grid: 26 bits under the block exponent |
| `storedBits` | 19 | a depth above zero is stored with 19 significant bits (truncate) |
| `startOnSlopes` | 1 | the start is cut to the slopes' 21-bit grid too, whatever its sign |
| `range` | 1 | the range rules and the zero rule of 6.3 |
| `zeroRuleCoords` | 1 | the zero rule in the coordinate differences too (`subC`, 6.3; `0de9776b`, depth2_zcoord) |
| `zeroRuleEdges` | 1 | the zero rule in the edges and the determinant's sums too (`addE`, 6.3; `0de9776b`, depth2_zedge) |

(`2d08a440`'s `storedNegBits` is gone: a depth below zero is stored by `StoredDepth::Neg`, 9.7.)

[T: zmeas — 13 sets, 89,801 brackets, 0 missed (with zstart's rule), every one-bit change of a width breaks 50 to
1,800; zblock 59,220 / 59,220 (a 19-bit stored mantissa on the pixel's own exponent, not the tile's); ztile 11,280 /
11,280 (the start and its exponent are taken again at every tile); zstart 49,152 / 49,152 (any start is cut to the
slopes' grid); zexfil — 64 dumps x 307,200 depths read out, all the console's; the range: 6.3]

### 9.2 Plane setup (per primitive; depth.h L415-426)

Corners 1, 2, 3 in rasterizer order, `FromSingle(., 1)` inputs, every operation the ranged `mul`, `add`, `subC`,
`addE` of 6.3 (24 bits, reach 25, the 2^128 limit at each, the zero rule in every addition):

```
e1  = addE(mul(x2, y3), -mul(x3, y2));  e2 = addE(mul(x3, y1), -mul(x1, y3));  e3 = addE(mul(x1, y2), -mul(x2, y1))
a   = add(add(mul(z1, subC(y2, y3)), mul(z2, subC(y3, y1))), mul(z3, subC(y1, y2)))   # (t1 + t2) + t3
b   = add(add(mul(z1, subC(x3, x2)), mul(z2, subC(x1, x3))), mul(z3, subC(x2, x1)))   # (t1 + t2) + t3
c   = add(add(mul(z1, e1), mul(z3, e3)), mul(z2, e2))                                  # (t1 + t3) + t2
det = addE(addE(e1, e2), e3)
if Perpendicular(det): det = +0                                                        # 7.3
```

In the hardware configuration `subC` and `addE` are `add` (6.3). The edges and `det` here are the depth unit's own:
the edge unit's determinant (`EdgeWinding`, 7.1) is swamped and has no zero rule, so the two differ where a product
reaches 2^128, where a corner is infinite, a NaN or a denormal, and where the zero rule acts (a zero against
+-(1 .. 1.5) 2^-126 of the other sign: depth2_zedge's triangles).

The plane is in determinant form: the depth is `(a x + b y + c) / det`. [T: precision / "The setup unit's
arithmetic" (59,220 of 59,220); zmeas item 1 — the sum orders, 5,417 -> 7,043 of 7,091 from the order alone, exactly
one of 384 combinations fits; zovf_sum — the start's last sum's order; the limits and the zero rule: 6.3,
depth2_zcoord, depth2_zedge]

### 9.3 Per tile: the regimes (`DepthTileT::Setup`, depth.h L322)

`(x0, y0)` is **the tile's first sample point** (`0de9776b`; refsw_tile.cpp passes `HALF_OFFSET.fpu_pixel_half_offset`
as Setup's `centers`, L809-813): `(left + 1/2, top + 1/2)`, the first pixel's centre, with `HALF_OFFSET[0] = 1`;
`(left, top)`, its top left corner, with `HALF_OFFSET[0] = 0` (`FromHalves(2 left + h)`, `h` = HALF_OFFSET[0]). The
start (`first0`, and the block's start, 9.4a) is evaluated there, and every pixel is a whole number of steps from it
(9.4a, 9.5, 9.6). Each primitive and tile starts from a clean state (`*this = DepthTileT{}`: nothing of a previous
triangle's register or block). In this order:

```
1.  det infinite:                    CONST, key 0
1b. |det| >= 2^126 (top(det) - 1 >= 126):   CONST, key 0                             # the reciprocal is zero (6.3)
2.  det nonzero (finite):            inv0   = Recip(det, 24)
                                     first0 = mul(add(add(mul(a, x0), mul(b, y0)), c), inv0)       # ranged (6.3)
    a. a or b infinite:              REG (9.5)
    b. else first0 or c infinite:
         a == 0 and b == 0:          CONST, Saturated(sign of first0)        # first0 is always infinite here
         else:                       BLOCK from a forced start: first = first0 infinite ? +-2^127 (its sign) : first0
    c. else:                         BLOCK from first = first0
3.  det zero (or perpendicular):     CONST, flat(mean) (9.4b)
```

The names CONST, REG and BLOCK are this document's; refsw3 has `valid = false`, `ovf = 2` and `block = true`.

- **Step 1, det infinite** (corners from about 2^64; depth.h L427-445): every pixel stores 0, as the reciprocal is
  zero and zero times anything is zero [T: trsort_recip page 10 — a determinant of 2^128 from corners of 2^116,
  under flat probes, DepthMode Greater: every probe from 2^-100 up drawn, +0 and 2^-126 not, as at f = 1 (page 3);
  trsort_auto — hugepos's a, infinite from 2^62, ties with the depth-0 layers in the sort (page 15). huge cannot tell
  (its triangles of that size are drawn whatever their depth); modvol's one pixel, a garbage polygon deciding whether
  it is in a volume, has it behind 0.75].
- **Step 1b, |det| >= 2^126** (`4f3efe15`, depth.h L463-467): the same, key 0 at every pixel, before any regime and
  whatever `a`, `b`, `c` are (infinite ones included). The test is on the exponent, `top(det) - 1 >= 126`, so exactly
  2^126 is in [T: trsort_recip, trsort_recipovf, trsort_auto: 6.3]. Which triangles: a determinant is twice the area,
  so legs of about 2^63 (corners from 2^62 on, hugepos b at M = 2^116 with corners near the screen and one far away:
  +2^127.7).
- **The sample point** [T: depth2_halfc — HALF_OFFSET 7 and 6, background probes 0 Greater / Less, 2^127, -2^127
  Equal, 2^120, the largest float, -2^126 Greater: in tile (0, 0), where x0 = y0 = 0 at the corner makes an infinite
  slope's term 0 (bad x 0 = 0), zword's TL +inf triangle starts at +1 step (c = +inf alone: m = 1 - (i + j)) and
  zovf_creg's C0 at -1 step (c = -2^128), at every pixel of the 14 regions (7 probes each) that differ from a start
  at the centre; nantr_fin2's (c / det finite either way), the same triangles in tiles (2, 0) .. (8, 0) (x0 > 0: the
  same infinities) and two ordinary ramps the same as at the centre (280 regions: no half steps of the register);
  depth2_halfo — 8 random ordinary triangles over tile (0, 0), HALF_OFFSET 6, the words of 5 pixels each read by
  background probes, where the start at the corner and the start at the centre with half steps back (refsw3
  `708fb8cd`) store other words, mostly 1 unit of the 19 bits: the corner's at all 40, 16 of 16 regions; in random
  triangles the two differ at 39 % of the pixels]. So the depth's sample point follows HALF_OFFSET[0] as the
  coverage's does (covmeas half20-23).
- **Step 2b, the constant overflowed** (it holds the corners' x y: from about z = 2^114 .. 2^117 on the screen) but
  the slopes did not: the slopes step as in any other plane (9.4a), from the start these numbers give at the tile's
  first sample point:
  - 0 where `a x0 + b y0` overflows with the other sign and cancels the constant (then `first0 = 0`) [T: zword — the
    tile's first pixel 0, every other one below the block's window; depthgaps_infstart — 8 triangles with a corner
    from 2^118 to 2^120 of either sign, against backgrounds of +-2^127, 2^126, 0 on 10 pages: 0 at the first pixel,
    at the others below the window (6, slopes below zero) or above 0 (2); depthgaps_regb — planes whose constant
    overflows, read out: a start of +0 stepping normally];
  - +2^127 where the start is +infinity [T: depthgaps_infstart's 2 such triangles; zovf's six cells where `c` is
    exactly 2^128 at the left of the screen: the first pixel exactly 2^127, the others stepped down from it, between
    2^126 and 2^127; zovf_sat, zovf_word, zovf_satw, zovf_satw2 — the words of a start saturated to +-2^127 stepped
    toward zero, up to and past zero];
  - -2^127 where it is -infinity [T: depthgaps_edges N — corners of -2^118 and -2^116 at the left edge, 7 pages:
    the first pixel equal to a background of -2^127, the others above it and below 0, stored as a block of E 128
    above its window; depthgaps_bigpos — stepping up from -2^127 by 2^123 .. 2^126 a pixel past 0 and 2^128 (Big,
    9.7); from +2^127 down past -2^128, a block of E 128 below its window];
  - the same where `a x0 + b y0` overflows alone [T: depthgaps_final X — corners (0, 160) 0.5, (640, 160) +-2^112,
    (0, 800) 0.5, `c` finite: from x = 128 on +2^127 at every pixel (steps of 2^102.7 under its last bit), -2^127 at
    each tile's first pixel and below it at the others; ordinary to the left; 6 pages, 20 tiles each].

  A plane of zero slopes with an infinite start stores +-2^127 at every pixel [T: bgbig]. This replaces
  `2d08a440`'s "ovf 1" (the first pixel 0, every other a fixed word).
- **Step 3, det zero**: the mean, whatever the corners' depths, infinite or NaN ones included (`2d08a440` stored the
  first corner's word as given there).

### 9.4a BLOCK: block fixed point per tile (depth.h L658-735)

```
inv   = Recip(det, 24)
A     = Mul(a, inv, 24);  B = Mul(b, inv, 24)                # unranged (6.3); C = Mul(c, inv, 24) feeds nothing (below)
A, B: |v| < 2^-126 -> mant 0 (sign kept)                     # under(); first (9.3) is already in range
pair  = max(top(A), top(B))                                  # NoExp if both zero
if first == 0 and pair == NoExp: CONST, key 0
start = cut20(first)
if pair != NoExp: start = cutBelow_(pair - 21)(start)        # onto the slopes' grid, toward zero, either sign
e     = (first == 0 or start == 0) ? pair + 5 : top(first)
unit  = e - 26
step(V) = V == 0 ? 0 : cutBelow_unit( cutBelow_(pair - 21)( cut20(V) ) )        # V = A, B
d0 = 2 * start / 2^unit;  dx = step(A) / 2^unit;  dy = step(B) / 2^unit         # integers, exact
E  = clamp(max(e, pair + 5), -122, 128)                      # the block exponent of a depth below zero (9.6)
```

Per pixel (i, j), refsw3 forms `tu = d0 + (2i + h) dx + (2j + h) dy`, half units of 2^unit. `h` is the half steps from
the sample point the start was evaluated at (Setup's `centers`, 9.3) to the one asked for (At's `centers`): `h =
centers - startCenters` (depth.h L830). The ISP asks at the point it set up at, so **`h = 0` in the hardware**: `tu =
d0 + 2i dx + 2j dy`, at centres and at corners alike. (`h = -1` was `708fb8cd`'s corner sampling, a start at the
centre stepped back half a pixel; At still takes another `centers` for dreamcast-tests' model probes, which set up at
the centre.) The value is exact (fixed point, no rounding while stepping) and is then stored (9.6).

**The G form.** Let `gexp = max(e, pair + 5) - 26` (E before the clamp, less 26) and `G = 2^gexp`. The start and
both steps are multiples of G: when `top(first) >= pair + 5`, `G = 2^unit`; otherwise the start was cut onto
`2^(pair - 21) = G` (or to zero, and then `unit = pair - 21` too) and the steps lie on that grid. In half units of G:

```
S = d0 / 2^(gexp - unit);  DX = dx / 2^(gexp - unit);  DY = dy / 2^(gexp - unit)    # |S| < 2^27; |DX|, |DY| < 2^21
t = S + 2i DX + 2j DY                                                               # value t * 2^(gexp - 1); |t| < 2^29
```

So the stepping is a **30-bit signed** accumulator in half-G units (`|S| + 62 * 2 * 2^21 < 2^27 + 2^28`), the same at
centres and at corners: only the start differs. [Checked with refsw3's own `DepthTileT` at `4f3efe15`
(`polly2-rtl/agents/spec-sync-depth/widths4f3d.cpp`, 300,000 random planes: ordinary, below zero, crossing zero,
around 2^-126 and 2^100 .. 2^127, determinants near 2^126, any word as a corner, a zero determinant now and then,
FPU_PERP_VAL 1/128 one time in ten, HALF_OFFSET[0] 0 or 1 at random (150,151 at the corner); 170,837 in the block
form): every one on the G grid; the largest `|t|` 2^28.45 half-G units over every pixel; and the G form stored as
9.6 writes it against `DepthTileT::At(i, j, centers)`'s key at every pixel: 0 differences. `708fb8cd`'s run,
`agents/spec-refresh/widths708.cpp`, had 2^28.51 over both `h`.]

refsw3's **float form** (`block == false` with a valid plane: `pair - 21 + 24 - unit > 100`, every pixel evaluated in
24-bit floating point) is **unreachable** with `startOnSlopes = 1`: a nonzero start cut onto the slopes' grid has
`top(first) >= pair - 20`, which makes the left side at most 49, and a zero one has `unit = pair - 21`, which makes it
3 [run: 0 of 300,000, at `708fb8cd` and at `4f3efe15`]. `C = Mul(c, inv, 24)` feeds only the float form. In
refsw3's units `tu` has at most 54 bits (`|t| < 2^29` times `2^(gexp - unit) <= 2^25`; 49 in the `4f3efe15` run,
`gexp - unit` at most 22 there), so `At`'s truncation to 64 bits never acts.

[T: zmeas items 2-3 — the start is `((a x0 + b y0) + c) * inv`, the plane before its division, evaluated at the first
pixel centre (14,289 of 14,291); the two slopes share the larger one's 21-bit grid and are cut to the tile's grid
(28,686 of 28,686); "Mix reach" — the stepping holds at least 29 powers of two above the start, a start of exactly
zero is stepped on the slopes' grid (30 of 30, 22 before); zstart — the start cut to the slopes' grid, any sign
(pages 0-2, 49,152 of 49,152; positive-only or negative-only cuts miss 117 and 4); depthgaps_flt — a start that the
cut to the slopes' grid makes zero is stepped from the slopes' grid too (planes z = C + A (x - y) whose start at tile
(0, 0) is C exactly, C from 2^-100 to 2^-60, slopes 2^-10 .. 2, every pixel of the tile read out: the depths below
zero stored as a block from the slopes; 9 planes, 1024 pixels each; refsw3 had the float form there);
depthgaps_tinyramp — the start in the setup's range (6.3); depthgaps_edges — a large slope after the division steps
as a number; zblock / ztile — the exponent is the polygon's own and is taken again at every tile, even where the
polygon does not cover the tile's first pixel; E's limits: depthgaps_neggrid (flat polygons at negative depths of
field 2, E -124, tie in groups of 0x400 of the word: the grid 2^-138 of a block of E -122, 0x12340 with every one
from 0x121C0 to 0x12400, not 0x12420; field 5, E -121, in groups of 0x100 as everywhere above), depthgaps_tinymean
(-122); depthgaps_bigslope (14 small triangles at the origin, corners 0 and +-2^123 .. 1.9375 * 2^126, every pixel
inside read by a binary search with the background, 67 depths: those below zero between -2^127 and 0 as a block of
128 above its window has them, and a start of -2^127 stepping by -2^123 a pixel exactly -2^127, -(2^127 + 2^123),
-(2^127 + 2^124): the window of 128), depthgaps_bigpair (slopes giving 129, 130, 131 and a block of 128, three to
ten pixels over each other: ordered as their values only as blocks of 128) (128)]

The depth sample point with `HALF_OFFSET[0] = 0` is measured since `0de9776b` (9.3: depth2_halfc, depth2_halfo):
the start at the corner, whole steps from there; `708fb8cd`'s start at the centre stepped back half a pixel (`h =
-1`) stores other words at 39 % of the pixels of random triangles. Every game dump but one ("mipmap") samples
centres.

### 9.4b The determinant-zero (perpendicular) mean (depth.h L645-655)

```
frac(k) = (z_k[30:23] == 255) ? z_k[22:0] : 0                 # the corner's raw word
addInf(p, fp, q, fq) = (p, q infinite, opposite signs, fp != fq) ? the infinity of the larger fraction's sign
                     : add(p, q)                              # 6.3
sum  = addInf(addInf(z1, frac(1), z2, frac(2)), 0, z3, frac(3))   # z3 the third corner sent; a sum's fraction is 0
mean = mul(sum, OneThird)                                     # OneThird = 0xAAAAAB * 2^-25 (pvr_softfp.h L331), ranged
key  = flat(mean)                                              # 9.7
```

So: `(z1 + z2) + z3` in the setup's adder (24 bits, toward zero, reach 25, the zero rule), times 1/3 rounded up to 24
bits, the product cut to 24 bits and below 2^-126 zero. Above zero the stored word is `cut19(mean)`. Below zero the
mean is cut to the start's 20 bits, then stored on the block of its own exponent (at least -122): 16 bits, the
size rounded up. An infinity or a NaN among the corners' depths makes the sum an infinity and the mean +-2^127
(`Saturated`). A corner of exponent field 255 adds as an infinity of its sign. Two of opposite signs give the
larger 23-bit fraction's infinity, and +0 when the fractions are equal (+infinity and -infinity, a NaN against a NaN
of the same fraction). A sum is an infinity of fraction 0, so a NaN does not go on.

[T: covmeas degen / tiny / sliver with zprobe — every pixel of a det-0 triangle at the mean of the corners (11,456 +
1,344 + 53 pixels); perpmean_word — 16,384 stored words of 16,384 (other sum orders, a wider or rounding adder, no
reach, or 0xAAAAAA miss: 1,618 words wrong); perpmean_neg — 11,258 means below zero (the adds toward minus
infinity: 242 wrong; without the 20-bit cut before the 16-bit round-up: 557); perpmean_bg — 136 words; 3 x 2^127,
the largest float, 2^127 + 2^127 - 2^127, and the same below zero: +-2^127, 36 of 36; perpmean_strip — 8,192 words:
the third corner sent is added last, strips, odd strip triangles, sprites; perpmean_tiny — 336 regions around
2^-126, a quotient below 2^-126 is zero; depthgaps_detneg — 62 triangles, three corners at a point that draws a whole
row: 100, 1.5, 100 + 2^-12 as themselves; -(100 + 2^-12), -64 (1 + 2^-18) and the means of -1 -2 -4, -64 -64 -65,
-1000 500 100, -0.1 -0.2 -0.3, -300 -300 -300.5 rounded up in size onto the word's 0x100 grid; -100 - d ulp as -100
for d = 1 .. 15, as -100 - 0x100 ulp for d = 16 .. 0x10F (the 20-bit cut first); and with infinite corners
(-100.123 +inf +inf, 100.123 100 +inf above every probe; -64 (1 + 2^-23) -inf 0 between -2^118 and 0);
depthgaps_dzinf — 74 triples, each as three corners at one point and 31 as a perpendicular triangle at FPU_PERP_VAL
0.75, against backgrounds of +-2^127, 1.5 * 2^127, -1.5 * 2^126: 48 of 48 regions (with the fraction not counting,
a NaN against an infinity of the other sign +0: 29 of 48); depthgaps_tinymean — the mean -2^-125 below a flat quad
at -2^-126 (the block floor of -122), 336 of 336 regions]. **GAP**: dividing by 3 and multiplying by 0xAAAAAB give
the same 19 bits for every 24-bit sum, so which one the hardware does is not visible. The mean's adds have the
depth unit's zero rule (6.3); the TSP's mean has its own (tsp §4.4).

### 9.5 REG: a slope that overflowed (refsw3 `ovf = 2`; depth.h L479-561, `RegDepth` L799)

Entered from 9.3 step 2a (`a` or `b` infinite). The depth is a register in units of 2^102 (2^25 units = 2^127 = one
step), two's complement with its sign at 2^131, so it wraps every 32 steps:

```
sa = a infinite ? (sign(a) != sign(det) ? -1 : +1) : 0;   sb likewise from b
rstep(v) = (v infinite or v == 0) ? 0
         : q = cutBelow_102(cut20(Mul(v, inv0, 24)))            # unranged Mul; the slope's 20 bits, toward zero
           q == 0 ? 0 : sign(q) * ((|q| / 2^102) mod 2^30)
fa = rstep(a);  fb = rstep(b)                                   # the slope that did not overflow
r0 = first0 infinite ? +-2^25 (its sign)                        # one step; a NaN's payload does not count
   : first0 == 0     ? 0
   : sign(first0) * trunc(|cut20(first0)| / 2^102)              # its 20 bits, toward zero onto the grid 2^102
pixel (i, j), whole steps from the start at the tile's first sample point (9.3; first0 there), either HALF_OFFSET[0]:
    key = RegDepth(r0 + (sa i + sb j) 2^25 + i fa + j fb)
RegDepth(r):
    r = ((r + 2^29) mod 2^30) - 2^29                            # 30 bits: the sign at 2^131
    r == 0:   key 0
    r >  0:   r >= 2^26 (2^128 and up): Big(cut19(r 2^102))        # 9.7
              else: Bits(the word of cut19(r 2^102))  =  (p + 229) << 23 | (r normalised to bit 23) & 0x7FFFE0,  p = BL(r) - 1
    r <  0:   u = r + 2^29                                       # the bits under the sign
              u == 0 (r = -2^131): Bits(0x807FFFFF), the lowest word there is
              p = BL(u) - 1;  Neg(E = p + 100, M = floor((u 2^(28 - p) - 2^29) / 2^10))      # 9.7
```

Below zero, RegDepth is a negative depth's store (Neg) of the register shifted left past the zeros under its sign
bit, the bits that are left as a block of E 128 has them. At whole steps (m = r / 2^25 mod 32, a 5-bit two's
complement number) this gives: m = 0: 0; 1: 2^127 (0x7F000000); 2 .. 15: Big, above every float word; 16:
0x807FFFFF; 17: E 125, M = -8 * 2^15; 18, 19: E 126, M = -8, -4 (* 2^15); 20 .. 23: E 127, M = -8, -6, -4, -2 (23 is
the word 0xFEFFFFE0); 24 .. 31: E 128, M = (m - 32) * 2^15 (30 is 0xFF7FFFE0, 31 is 0xFF000000). Ordered -16 < -15
< .. < -1 < 0 < 1 < .. < 15, no two equal.

[T: zovf — the three regimes and their sign maps; zword — every word at whole steps to 19 bits (binary search with
the background as the probe), the same for +inf, NaN and 2^127 corners at every place tried, and the mirror, word for
word: 1 equal to 2^127, 2 .. 15 above every probe (the largest positive 0x7F7FFFE0), 16 below every probe, 23 and 30
equal to the bottoms of fields 253, 254, 31 -2^127, the others between the fields as Neg puts them; depthgaps_mm —
zword's triangle with legs 64 over its mirror, every pair of the 32 values at one pixel, Equal, Greater, Less, at
three places: strictly ordered; depthgaps_edges M — 16 below -2^-100 and -1.5 * 2^-126 too; nantr_pos — 300 cells,
every corner bad in turn, both orientations, NaNs 7FC00000 7FA00000 7F800001 7FFFFFFF FFC00000 FFFFFFFF, +-inf,
+-max, 2^127, 2^123; 2700 of 2700 regions, 70 cells start at +-1 step (the start (a x0 + b y0) + c with the
infinities' rules: TL bad, (-inf - inf) + inf, is 0; a TR / BL corner facing the diagonal starts at the sign of c);
depthgaps_phase — 105 triangles against three backgrounds, the start fitted per triangle: 33 with c finite start at
+-1 step, the one with c an infinity of the slopes' sign at -1, the 71 where the infinities cancel at 0; nantr_word,
nantr_fin (16 starts: 2^120 .. the largest float as themselves, 2^120 as 2^120 - 2^102, 0.5 and 2^100 as 0),
nantr_fin2, nantr_wreg — the words between whole steps (2^127 + 2^110 as itself, -(2^127 + 2^110) as 0xFF000100,
2^119 - 9 steps as 0xFEFF0000, 1/8 - 9 steps as 0xFEE00100, 1/8 - 2 steps as 0xFF700100; -8.125, -8.0625, -8.09375,
-12.125, -12.09375 steps not above -8 and -12; -2^119 and 2^119 - 1 step between -2^127 and 0.25); depthgaps_rstart
— a finite start below zero toward zero onto 2^102 (-2^101 .. -0.5 start at 0; -(2^119 + 2^100) one step down as
-(2^127 + 2^119), 0xFF008000, not 0xFF008100; 20 pages, 60 depths); depthgaps_rcut — cut to the start's 20 bits first
(32 of 32 regions); zovf_creg — the finite slope steps the register: 50 single pixels, registers at 0, +1 and -1
step, the other slope from 1.5 * 2^99 to 1.5 * 2^122 of either sign (j 2^116 as itself; 2^127 + 1.5 * 2^110 as
0x7F000060; a slope of 7 * 2^101 as 6 * 2^101; slopes of 1.5 * 2^101 and 1.5 * 2^100 as 0; with a determinant of 32
2^102 and 3 * 2^102 kept, not a pair grid of 2^103 (43 of 50 with it); 2^122 + 7 * 2^102 as 2^122 + 6 * 2^102, the
slope's 20 bits (48 of 50 without them); without these steps 9 of 50), zovf_ab (518 of 676 regions without them),
zovf_slope (154 of 252), zovf_wrap (104 of 128; W2: a slope below zero toward zero, the console keeps 0, 124 of 128
rounded down); depth2_cneg — an off-grid slope below zero of 2^102 or more, toward zero too: zovf_creg's C0 with F
= -(8192 + 1/2), -(8192 + 3/4), -(256 + 1/4), -(2^18 + 1/2) units of 2^102 a row, the words of the pixels (1, j) at
2^127 + j F above zero, read by background probes: toward zero at all 44 targets where down would store another 19
bit word, and the controls +(8192 + 1/2), -(127 + 1/2): 12 of 12 regions; zbad 4080 / 4080, zbadbg 3480 / 3480,
zbadk; zspec 1040 / 1040; bgbig — an overflowing polygon ties with a background of 2^127; depth2_halfc — the register
with `HALF_OFFSET[0] = 0`: whole steps from its start at the corner (9.3)].

**Among OTHER planes' depths** the register's words and the values between whole steps lie as this representation
(RegDepth = Neg / Big) has them [T: depth2_regmix — 1,188 pairs in one tile each, a register triangle (zword's TL
+-inf and C1, zovf_creg's C0 with a finite slope of +-2^100 .. 2^122 a row: between whole steps) against a block
from a start of 0 (depthgaps_ties' B(L, Z), E 122 .. 128 from its slopes: depths above its window) or another C0,
and in tile (0, 0) zword's TL +inf with legs 64 over 17 small triangles a set whose start is -2^127
(depthgaps_bigpos: depths of 2^128 and more, and a block of E 128 below its window); Greater, Equal, Less: 3,600 of
3,600 regions; 40,884 pixel pairs lie between the same two float words: a block's depths above the window of E below
the register's below the window of E + 1, between fields 250 / 251 .. 253 / 254 (m = 17 .. 29 and values between
steps: 36,314 pairs), above-window depths of one E ordered by M with the register's (C0, both orders, 132), Big
against m = 2 .. 15 (103, both orders), E 128 below its window against m = 24 .. 29 (45, both orders);
depth2_regbelow — against an ordinary block's depths below its window, E 125 .. 127: tiny triangles 2^-10 .. 2^-4
pixel around one pixel's centre near the origin, their start in the window of E, slopes below 2^(E - 5), against
zovf_creg's C0 with a finite F of -(2^108 .. 2^118) a row, off the block's grid, and in tile (0, 0) zword's TL +inf
with legs 64; Greater, Equal, Less: 2,442 pixel pairs, 666 of 666 regions as refsw3: the register below the window
of the same E ordered by M with the block, its value rounded down onto 2^(E - 16) as the block's (1,308 pairs; the
register keeping its fraction would differ at 351, the block's M rounded up at 613, the register's at 581, the
register above / below every block depth there at 754 / 929), and the register above the window of E - 1 (just
below m = 20, 18, 17) below the block below the window of E (1,134 pairs; by value it would be above: all 1,134
differ)]. The words m = 17, 18, 20, 21 lie beyond an ordinary block's reach (its M is -2^16 - (i + j) 2^11 or more,
i + j <= 62 in a tile): their order with one never shows.

**GAP**: a slope of 2^128 or more after the division (a determinant below 1), taken mod 2^132.

Underflow: the range rule makes `A`, `B` and the start zero below 2^-126. A plane from 2^-124 to -2^-124 over a cell
is its start everywhere; one from 2^-126 to -2^-126 is 0 [T: zspec pages 3-6; detinf 480 of 480].

### 9.6 Storing a depth (`DepthTileT::At` L822, `NegWord` L740)

```
REG:    RegDepth (9.5)
CONST:  the key of 9.3
BLOCK:  tu = d0 + 2i dx + 2j dy                              # half units of 2^unit (9.4a; h = 0 in the hardware)
        tu >= 0:  s = cut19(tu 2^(unit - 1));  top(s) - 1 >= 128 ? Big(s) : FromFp(s)        # 9.7
        tu <  0:  sh = E - 15 - unit                          # 2^(E - 16) in half units of 2^unit
                  0 <= sh <= 120:  Neg(E, floor(tu / 2^sh))   # M rounded down: the size up
                  otherwise:       Bits(0x80000000 | (E + 126) << 23)        # = 0xFF000000 (E is 128 there)
```

In the G form (9.4a), with `nsh = E - 15 - gexp`: `M = floor(t / 2^nsh)` for `nsh >= 0` and `M = t * 2^-nsh`, exact,
for `nsh < 0`. `nsh` is 11 unless E was clamped: 12 .. 14 at the -122 floor, below 11 at the 128 ceiling, and below
0 when `gexp > 113`. With `nsh < 0` and a start that is not zero, refsw3's `sh = 139 - top(first) >= 11`; with a start
cut to zero (`gexp == unit`) `sh = nsh < 0`, and that is the fallback word. `sh > 120` is unreachable (`nsh <= 14`).
**[R]** refsw3 marks the fallback "not reached (startOnSlopes 1)". `At` does return it, at pixels of planes with
slopes of 2^134 and more a pixel whose start was cut to zero, but at no covered pixel in the runs below. With a
start (not the fallback) `nsh = sh - (gexp - unit) >= 11 - 25 = -14`, since a start that survives the cut onto the
slopes' grid has `top(first) >= pair - 20`; so `nsh` is a 5-bit signed number beside a "fallback" flag (start cut
to zero and `E - 15 - gexp < 0`). [Runs: widths708.cpp at `708fb8cd`, `nsh` -15 .. 14 over the pixels below zero;
the fallback at 26,404 pixels, `nsh < 0` with a start at 25,924, `|M| > 2^23` at 126,894 (the largest 2^34.1);
widths4f3d.cpp at `4f3efe15`, both sample points: `nsh` -17 .. 14 with the fallback's pixels, -7 .. 14 without; the
fallback at 11,014 pixels, `nsh < 0` with a start at 13,092, `|M| > 2^23` at 57,581 (the largest 2^33.9); in both
none of them at a pixel the triangle covers (its own edges and row range, as RasterizeTriangle has them).]

So a stored depth is:
- above zero: the IEEE single of `cut19(v)`, **19 significant bits on the pixel's own exponent** (low 5 fraction bits
  zero); below 2^-126 a float denormal, ordered by value (a depth there has at most 19 bits on a grid of 2^-145 or
  coarser, so it never rounds); from 2^128 `Big` (9.7), cut to 19 bits as below 2^128;
- zero: key 0 (+0 and -0 alike);
- below zero: the block's exponent E and `M = floor(value / 2^(E - 16))`, the value rounded down (its size up),
  stored by `Neg` (9.7): the float's word inside the block's top binade, between two fields' words outside it.

[T: zblock, precision — 19 bits on the pixel's own exponent; depthgaps_edges — a ramp from 2^-124 in steps of -1.75
and +1 2^-126: 2^-128 and 2^-127 above 0 and below 2^-126 at every pixel, 0 where the plane is 0; depthgaps_tiny —
flat quads at +-2^-126, +-1.5 * 2^-126, +-2^-125: above / below 0; depthgaps_bigpos — triangles whose start is -2^127
stepping by 1.9375 * 2^123 .. 2^126 a pixel, every pixel read with the background as the probe: from 1.07 * 2^128 to
13 * 2^127 above every probe, 0x7F7FFFE0 included, those below 2^128 the floats, 20 of 20 regions (refsw3 had 2^127);
depthgaps_bigord — two such triangles over each other, Greater, Equal, Less: ordered by value from 1.02 * 2^128 to
12 * 2^127; slopes 2^112 apart (2^116.7 at the pixel) are, 2^100 apart (2^104.7) equal: a grid between those, taken
as 19 bits; above a flat triangle at the largest float or at +infinity; 33 of 33 regions; depth2_biggrid — Big's
19 bits cut: 10 sets of 26 pairs of such triangles in tile (0, 0), legs 4, the second's slopes 2^104 .. 2^110 off
the first's: 1,251 pixel pairs at 2^128 .. 1.7 * 2^129, Greater, Equal, Less, 30 of 30 regions; 18 bits cut differ at
129 pairs, 20 at 105, 13 / 23 at 679 / 269, 19 rounded at 216, a fixed grid of 2^110 at 22; depth2_denorm — the
denormal depths ordered by value: 70 pairs of planes over a tile each, slopes of 2^-126 .. 2^-125, a diagonal of
each tile between 0 and 2^-126, from about 2^-138 up, the second plane 0 .. a few hundred 2^-145 off the first,
Greater, Equal, Less: 2,137 pixel pairs with a depth there, on the start's grid of 2^-145; a store on a grid of
2^-144 would differ at 39 pairs, 2^-143 at 151, .. 2^-128 at 1,927, rounded to 2^-144 at 68, one word for all at
1,930; and 70 pairs whose second plane is the first moved by 2^-141 .. 2^-126, 1,976 pixel pairs in different
binades (2^-128 against 2^-127 against 1.5 * 2^-127 ..): a word of exponent field 0 with the normalized fraction
would differ at 463; 420 of 420 regions as refsw3; below zero: 9.7]. (`708fb8cd`'s two GAPs here, the denormals'
order among each other and Big's grid, are closed by these.)

### 9.7 The stored depth and its order (`StoredDepth`, depth.h L123)

The ISP compares **order keys**, not floats and not words. A stored depth is a 64-bit signed key `k`: the order of
the IEEE word, 32 bits finer, so that the depths the unit makes below zero outside a block's top binade, and above
zero from 2^128, have places between neighbouring words. (refsw3 keeps a 32-bit `bits` beside `k` for logs and the
probes only: for `Between` keys a stand-in word, the float of the value cut to 24 bits for `Neg`, 0x7FFFFFFF for
`Big`.)

```
key32(w)      = (w == 0x80000000) ? 0 : (int32)(w ^ (w[31] ? 0x007FFFFF : 0))      # the word's order
Bits(w):        k = key32(w) * 2^32
Between(w, o):  k = key32(w) * 2^32 + o,  1 <= o <= 2^32 - 1          # after w, before the next word in key32 order
Saturated(neg)= Bits((neg ? 0x80000000 : 0) | 0x7F000000)            # +-2^127
FromFp(v):      v infinite: Saturated(v's sign);  v == 0: Bits(sign bit alone)
                round to nearest, ties to even, to 24 bits or, below 2^-126, to the denormal grid 2^-149
                (after a 19-bit cut only the denormal case rounds); 2^128 or more after rounding: Saturated
                else: Bits(the IEEE single encoding, denormal for top <= -126)
Big(v):         v >= 2^128, at most 19 bits: f = top(v) + 126 (>= 255), frac = v's 23 bits under its leading one
                Between(0x7F800000, ((f - 255) << 23 | frac) + 1)
Neg(E, M):      M < 0, the value M * 2^(E - 16), E in -122 .. 128:
    -2^16 <= M <= -2^15:  Bits(0x80000000 | (E + 126) << 23 | (M == -2^16 ? 0x7FFFE0 : (-M - 2^15) << 8))
                          # the window, the block's top binade (sizes 2^(E-1) .. 2^E): 16 bits, its bottom 2^E with
                          # the fraction 0x7FFFE0 (no carry into the exponent)
    M > -2^15:            Between(0x80000000 | (E + 126) << 23, M + 2^15)        # above the window (nearer zero)
    M < -2^16:            Between(0x80000000 | (E + 125) << 23, 2^31 + max(M + 2^30, 0))   # below the window
flat(v):        v infinite: Saturated(v's sign);  v == 0: key 0;  v > 0: FromFp(cut19(v))
                v < 0:  s = cut20(v);  E = clamp(top(s), -122, 128);  Neg(E, -ceil(|s| / 2^(E - 16)))
```

What the order is:
- **Positive depths order as floats** (bigger = nearer, depth is 1/w). From 2^128 (`Big`) a depth is above every
  float word, ordered as a float of 19 bits whose exponent field goes on past 254. (Positive NaN words lie above it
  in key32's order, but no stored depth is one: the background turns field 255 into 254, 4.2.)
- **-0 equals +0**, every negative depth is below zero, of two negative words the one with the larger exponent field
  is larger, and within one field the float's own order holds (-2 > -1 > -1.5 > -0.5 > -0.75) [T: zsign — every pair
  of 20 depths from -2^100 to 2^100, Greater and Less; bgspec, bgneg, bgneg2; zneg 1200 of 1200 (blind below zero,
  hence zsign)].
- **Below zero, in the window**: the float word on the 16-bit grid, a multiple of 0x100 in the word, the binade's
  bottom with the fraction 0x7FFFE0 [T: perpmean_bg (the words of 136 means below zero and 24 flat 2x2 quads: every
  one on the 16-bit grid, one step above in size wherever the value had bits below it); perpmean_neg;
  perpmean_negstore page 0 (flat quads at -0x42FFFFFF and a start just over -2^14 tie with the backgrounds 0xC2FFFFE0
  and 0xC67FFFE0; a carry to the next power of two puts the probes out of order); perpmean_negedge pages 0, 2;
  depthgaps_negpp (360 of 360 regions: flat polygons below zero tie in groups of 0x100); depthgaps_neggrid (35 depths
  of fields 5 .. 227 tie in groups of 0x100, the top group with 0x7FFFE0; positive ones do not); zovf_neg, zovf_neg2].
- **Below zero, outside the window**: above the window, the depth lies after every word of field E + 126 and before
  field E + 127's lowest, ordered by M; below it, after every word of field E + 125 (and after the depths of block
  E - 1 above its window, which share that gap) and before field E + 126's lowest, ordered by M (every `M <= -2^30`
  at the same place) [T: depthgaps_negladder and depthgaps_search (a ramp from a start of exactly 0, A = -0.71,
  B = -0.05 a pixel, every pixel of tile (0, 0) read out: E = 5, the 326 pixels in [16, 32) stored rounded up, the 697
  below 16 above every probe of field 131 and below field 132's last); depthgaps_negconv (12 planes read out: starts
  of -100, -1000, -96, -64, -127, -3, +-10 with slopes from 2^-12 to 2; E from the start (7, 10) or from the slopes
  (6 for a start of -9.25 with slopes of 1; 2 for -0.04 with 0.075): the window, above and below it at every
  pixel); depthgaps_ties and depthgaps_uwmat (ramps against ramps: depths above the window of E 6 and below the
  window of E 7, both between fields 132 and 133, ordered by M in each, every one of E 6 below every one of E 7; 10
  pairs of ramps, every pair of 32 depths strictly ordered as their values); depthgaps_final G (a ramp 2^-10 above
  another, E 6, above its window, is above it at all 32 x 32 pixels, 2^-11 equal; E 7 below its window: 2^-9 above,
  2^-10 equal: 2^(E - 16) on both sides); depthgaps_negramp; perpmean_negslope, perpmean_negstore pages 1-3,
  perpmean_negedge page 1 (pixels of sloped planes below zero outside the start's binade: neither the 16-bit round-up
  nor the 19-bit cut of their own binades)].
- Depths below zero are drawn like any other [T: uvmeas wneg — 780,000 texels read off such polygons; README "The
  TSP's numbers at their limits"].

## 10. Depth compare and the per-pixel update (`PixelFlush_isp`)

### 10.1 Buffers (refsw3's per-tile state)

| buffer | width (refsw3) | content |
|---|---|---|
| `depthA` | stored depth (9.7: a 64-bit order key) | opaque: the depth; PT passes: this pass's best, then what each pixel resolved to; TR sort: this pass's best |
| `depthB` | stored depth | the reference: PT boundary (last key shaded), TR sort (layer drawn last) |
| `depthC` | stored depth | PT: the opaque depth, or what an earlier chunk resolved |
| `tagA` | 29-bit tag | the visible primitive (opaque, background, PT best / resolved, TR best) |
| `tagB` | 32 bits (29-bit tag or TAG_BELOW) | the reference's tag |
| `stencil` | 3 bits | bit 0: in a volume (summary); bit 1: parity of the current volume; bit 2: touched since the last summary |
| `valid` | 1 bit | the pixel has a fragment to shade in this pass |
| `rendered` | 1 bit | PT: resolved (passed the alpha test) |
| PT extra | opTag (29), refTagC (29), resTag (29), resDepth (stored depth), resolved-last-pass (1), everRendered (1) | 11.4 |
| TR extra | savedDepth (stored depth) | 11.6 |

All 32 x 32. This is refsw3's state. A stored depth is refsw3's `StoredDepth::k`, a 64-bit key (9.7): since
`708fb8cd` a depth below zero keeps its block exponent and a fixed-point M, and one above 2^128 has a place above
every word, so a 32-bit word no longer holds every depth. The hardware's storage is not known beyond "depth about 28
bits (8-bit exponent, 19-bit mantissa), tag + stencil bits" [I] (PIPELINE_SHAPE "Storage"). The RTL may store less
where the values allow it (e.g. resolved-last-pass instead of refsw3's `resPass` integer, or any encoding of the key
that keeps its order), but every compare below must give the same answer.

### 10.2 The compare (`DepthMode`)

`new` = the fragment's stored depth (9.6), `old = depthA`; compares of the keys (9.7); the fragment **passes** when:

| mode | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| name | never | less | equal | less or equal | greater | not equal | greater or equal | always |
| pass if | never | new < old | new == old | new <= old | new > old | new != old | new >= old | always |

Which mode applies depends on the pass:

| render mode | mode used | on pass |
|---|---|---|
| opaque | the polygon's `DepthMode` | `if !ZWriteDis: depthA = new`; `tagA = tag`; `valid = 1` |
| modifier volume | **4 (greater), whatever the word says** | `stencil ^= 2; stencil \|= 4` |
| PT (every pass) | none: the walk of 11.4 | 11.4 |
| TR pre-sorted | the polygon's `DepthMode` | `if !ZWriteDis: depthA = new`; `tagA = tag`; `valid = 1` |
| TR sorted (autosort) | none: the walk of 11.6 | 11.6 |

[T: depth page 0 — 8 modes x 3 depths x write on/off in the opaque, PT and pre-sorted TR lists, 336 of 336 (in the
PT list the mode does nothing: "the second polygon never replaces the first, whatever the compare mode, even always");
dumprules page 8 — ZWriteDis is honoured by opaque and pre-sorted translucent polygons, ignored by PT ones; dumprules
pages 0-1 / jgr_tree_shadows — a volume triangle at exactly the pixel's depth is not in front of it (strictly
greater); timemeas — failing, passing or writing all cost the same 16 clocks a triangle]

### 10.3 The fragment key and `KeyAbove`

The sorted walks (PT passes, TR sort) order fragments by one key: the stored depth (its key, 9.7), then the tag's
sort bits (bits 23:0, i.e. list order). No two fragments are ever equal (the tag differs), so nothing is "coplanar".
A larger key is nearer, or as near and later in the list.

```
KeyAbove(aW, aTag, bW, bTag):          # is key a above key b?
    if aW != bW:            return aW > bW                         # the stored depths' keys (9.7)
    if bTag == TAG_BELOW:   return aTag != TAG_BELOW
    return aTag != TAG_BELOW && (aTag & 0xFFFFFF) > (bTag & 0xFFFFFF)
```

The first reference of both walks is the key of **what is there**: the opaque polygon's (or the background's, or a
resolved PT layer's) depth **and tag**. A fragment at exactly that depth is drawn only if its tag is above it
[T: trtie — 16 pages, translucent / PT quads with exactly the corners of an opaque / PT quad, lists in either order,
flat and sloped, and at exactly the background's depth (pages 9-15); shenmue_intro2 (522,170); dumprules page 0
cells 80-87, page 1 cells 0-6; sort — 56 of 56]. (The opaque compare of 10.2 does not use tags.)

The depth is the stored key in its own order (9.7), garbage depths too: the depths of the overflow regimes, and the
0 of a determinant of 2^126 or more (9.3 step 1b), sort as the depth test orders them [T: trsort_garb — a triangle of
determinant (1 - 2^-24) 2^126 or 2^126 whose depths run through the overflow regimes, or are 0 from the zero
reciprocal, against 10 flat probes from -2^127 to 1.5 * 2^127, all in the sorted translucent list, nearest-layer and
added blending, both list orders, backgrounds 0.0001 and -2^127: 160 of 160 regions (the reciprocal of 2^126 kept, or
no limit: 130), the sort taking what the depth test of trsort_recipovf draws; trsort_auto 240 of 240 (6.3)]
(refsw_tile.cpp L568-575, `4f3efe15`). trsort_single (hugepos's triangles one a page, translucent in the order sent,
DepthMode Always: which colours a triangle's own shading makes) belongs to the same set but is a TSP page; refsw3's
depth code does not cite it.

## 11. The lists

### 11.1 Opaque (RM_OPAQUE)

One pass. Each fragment: the polygon's `DepthMode` compare against `depthA`; on pass, depth write unless
`ZWriteDis`, `tagA = tag`, `valid = 1`. The TSP shades the last polygon that passed at each pixel (the tag), which
with `ZWriteDis` is not necessarily the nearest. The opaque modifier list follows (11.2), then the opaque SHADE
pass (12) over every `valid` pixel: the background where nothing passed, unless `z_keep`.

### 11.2 Modifier volumes (RM_MODIFIER)

A volume is a run of triangles in a modifier list. Its last triangle carries `VolumeMode` 1 (inside) or 2 (outside).
Each triangle goes through the same setup, culling (its own `CullMode`), edges and depth plane as a polygon, but with
**no row range** (8.6). A triangle covers a pixel and is **strictly in front** of the stored depth (`new > depthA`,
key order) when it toggles parity:

```
per covered pixel with new > depthA:   stencil[1] ^= 1;  stencil[2] = 1
after a triangle with VolumeMode 1 (inside last),  per pixel with stencil[2]:  stencil = {0, 0, stencil[0] | stencil[1]}
after a triangle with VolumeMode 2 (outside last), per pixel with stencil[2]:  stencil = {0, 0, stencil[0] & stencil[1]}
```

(`{b2, b1, b0}`.) `stencil[0]` ("in a volume", `volHit`) accumulates over the volumes of the list, in list order.
Pixels no triangle of the volume touched (`stencil[2] = 0`) keep `stencil[0]` under either summary. Under "outside"
that keeps a pixel that is in no part of the volume. This is refsw3's reading. It agrees with modvol's arrangements
("exclusion volume" identical) but is not separately pinned: **GAP**.

Where the volume lists are walked, and against which depth:

| phase | list | depth tested against | stencil before |
|---|---|---|---|
| opaque | OP_MOD (only with an OP pointer) | the final opaque depth (`depthA` after the opaque list) | 0 (Z clear) or the previous entry's (keep Z) |
| PT_MOD (with a PT pointer) | OP_MOD again | the final PT depth: `depthA` after PT final (resolved PT depth, else opaque) | 0 (cleared at PT start) |
| TR sorted, every peeling pass | TR_MOD | this pass's best `depthA` (pixels with nothing this pass hold the key of 0x7F7FFFFF, the largest finite float, so only a depth of 2^128 or more, `Big` 9.7, is in front of them) | 0 (cleared at every peel) |
| TR pre-sorted | none (TR_MOD ignored) | | whatever the opaque or PT_MOD phase left |

[T: modvol (opaque, cheap shadow: one sheet in front, behind, two, three, front plus behind, two volumes, exclusion
volume: identical inside sets; 187 -> 192 of 192 cells with faredge's rules); covmeas modvol16, modvol17 (coverage of
volume triangles, 0 misses), sliver36 (no row range); dumprules pages 0-1 (strictly greater); volrun — 12 kinds, a run
ends where the volume state changes by the depth test, 24 of 24 pages; timemeas tr_modvol — translucent volumes work
in sorted tiles, ignored in pre-sorted ones]. **GAP**: translucent modifier volumes beyond timemeas and uvrun kind 9
(dreamcast-tests TODO C6), and the history-dependent background skip of a pre-sorted tile with an empty opaque list
and a translucent volume (timemeas).

How the volume state is used is in 12.1: span breaks and `InVolume` per pixel. The shadow bit selects the volume's
parameters in the TSP.

### 11.3 OpInPt: a punch-through list that holds a primitive

`OpInPt = PT pointer present && ObjectListHasPrimitive(PT list)` (5): a strip entry with any mask bit, or any
triangle / quad array entry, **whether it draws or not** (culled, behind, degenerate, between pixel centres). When
set: (a) the opaque pass's runs do not end at volume edges, and (b) the opaque pixels inside a volume are shaded
again in the PT_MOD pass (12.1). [T: optrun kinds 9, 10; optcull — 9 kinds of non-drawing PT lists act as drawing
ones, 18 of 18 pages; polly2-data ff2_fight tile (10,12), jgr_car, jgr_tree_shadows*; sa2_ingame / 18wheel_select:
lists with no primitive change nothing]. Ordering consequence: the opaque runs can only be cut after the PT list's
first entries have been read.

### 11.4 Punch-through (RM_PUNCHTHROUGH_PASS0 / _PASSN): chunks, passes, alpha test feedback

**Start** (`PeelBuffersPTInitial`), per pixel:
`depthC = depthA` (the opaque depth); `opTag = refTagC = tagA`; `tagB = TAG_BELOW`; `valid = rendered = 0`;
`stencil = 0`; `everRendered = 0`; resolved-last-pass = 0.

**Chunks.** `S = ISP_FEED_CFG[13:4]` (PT chunk size). The list is cut into chunks in list order. A chunk is peeled on
its own, in front of (or at the key of) what earlier chunks resolved. The assignment (`PtChunkTake`) is recomputed
identically in every pass:

```
per pass: fill = 0; chunkAt = 0; prevQuad = false; culled = 0
for each primitive in list order (strip triangles with their mask bit set only; masked-off ones count nothing):
    if bad corner: counted as below (not culled)
    if CullMode culls it (7.2):  culled = 3; skip it (takes no room; a culled quad also counts 3)
    else:
        nv = quad ? 4 : 3
        if fill > 0 and (fill - (prevQuad ? 1 : 0)) + culled + nv > S - 2: chunkAt++; fill = 0
        fill += nv; prevQuad = (nv == 4); culled = 0
        the primitive is rasterized in this pass only if chunkAt == the chunk being peeled
number of chunks = chunkAt + 1 (known after chunk 0's first pass)
```

So at S = 0x40 (every game) 20 triangles fit in a chunk, 21 do not; at 0x20 10; at 0x23 11. A quad's last vertex
is not counted until the next primitive is checked ("lag"). A culled primitive's 3 vertices count only in the next
primitive's check. [T: ptchunk — 22 kinds at 0x20-0x25 and 0x40, discard mode irrelevant, strips count 3 a triangle
and an entry can be cut between chunks; ptchunkq — 200 configurations, only the quad lag fits all; ptchunkm — 120
random mixes, all; ptchunkcost — culled triangles and masked-off strip triangles take no room, 40 of 40; ptchunklag —
the check right after a culled one, 48 of 48; polly2-data shenmue_intro*, jgr_tree_shadows2, f1wgp_driver,
f1wgp_race, vrally_rally4]. **GAPs**: whether a quad at the boundary counts 4 or 3; a culled quad right after a drawn
quad; a primitive with an infinite / NaN corner (counted as stored, not measured).

**Passes**, per chunk (pass = 0, 1, ...):

```
loop:
   MoreToDraw = false
   walk the PT list (the chunk's primitives), fragments through the PT ISP rule below
   if !MoreToDraw: break                                 # no fragment was accepted anywhere
   MoreToDraw = false
   SHADE (12) with the alpha test; per shaded pixel the update below
   if !MoreToDraw: break                                 # no pixel failed the alpha test
```

PT ISP rule, per fragment (key = (new, tag)):

```
if rendered and not resolved-last-pass:        reject                 # resolved in an earlier pass of this chunk
if !KeyAbove(new, tag, depthC, refTagC):        reject                 # at or behind the opaque / earlier-chunk key
if tagB != TAG_BELOW and !KeyAbove(depthB, tagB, new, tag): reject     # not strictly below the boundary
if valid and !KeyAbove(new, tag, depthA, tagA): reject                # not above this pass's best
MoreToDraw = true; depthA = new; tagA = tag; valid = 1                # the polygon's DepthMode and ZWriteDis are ignored
```

So each pass takes, per pixel, the **largest key below the boundary and above the opaque key**: near to far. In one
plane that is the last polygon in the list first, then the one before it where that one fails [T: dumprules page 0
cells 80-87, sc_ingame; depth page 0 PT cells; zsource — a PT polygon leaves the ISP's depth (its plane), not the
TSP's 1/w, 40 quads].

After the TSP has shaded a `valid` pixel (alpha test `alpha < PT_ALPHA_REF` fails, else passes; tsp.md):

```
if rendered (resolved in the pass before: a run-only pixel):
    colour kept as it was (the TSP's write is undone); depthB, tagB = depthA, tagA; valid = 0
elif failed:
    MoreToDraw = true; depthB, tagB = depthA, tagA; valid = 0          # the next pass looks below this fragment
else (passed):
    rendered = 1; valid = 0; resolved-in-pass = this pass
    resTag = tagA; resDepth = depthA; depthB, tagB = depthA, tagA
```

"Resolved-last-pass": a pixel resolved in pass p takes part in pass p+1 only. It goes on to its next fragment below,
is shaded as part of that pass's runs (so runs start further left), and keeps its colour. From pass p+2 on it is out.
A pixel that failed is shaded again only where a later pass finds a fragment for it. [T: ptlayers — 18 of 18 pages,
1440 regions (kind 4: a pixel resolved in the first pass does not take part in the third); ptruns — 8 of 8 pages
(with re-shading in every pass, 21,827 to 35,681 pixels a page wrong); uvrun kind "punch-through bands"; shenmue_intro*]

**Next chunk** (`PeelBuffersPTChunk`), per pixel: if `rendered`: `depthC = resDepth`, `refTagC = resTag`;
`everRendered |= rendered`; `valid = rendered = 0`; `tagB = TAG_BELOW`; resolved-last-pass = 0. (`depthA`, `stencil`
untouched.) A later chunk can draw over an earlier chunk's resolved pixels, in front of their key. [T: ptchunk]
**Timing-dependent (not in refsw3)**: with few primitives in the chunk before (k = 0..5 fillers), pixels resolved in
the previous chunk take part in the next chunk's first pass as run-only pixels on a console; with 8 or more fillers
they do not; at 6-7 it depends on how far the ISP is ahead of the TSP [T: ptchunkrun_races, ptchunkcarry_races —
races, section 14].

**PT final** (`PeelBuffersPTFinal`), per pixel: `rendered |= everRendered`; if `rendered`: `depthA = resDepth`,
`tagA = resTag`; else `depthA = depthC` (the opaque depth) and `tagA = opTag`. So a PT polygon always leaves its
depth, whatever `ZWriteDis` [T: dumprules page 8; zsource], and the translucent sort's first reference is this key
(10.3).

**PT_MOD** (if the OP_MOD pointer is present): walk the opaque modifier list again against this final depth (11.2),
then SHADE pass RM_PUNCHTHROUGH_MV over the pixels `stencil[0] && (rendered || OpInPt)`: the resolved PT pixels
inside a volume, alpha tested again (the second shading replaces the colour) with the volume's parameters if the
shadow bit is set and the polygon's own otherwise; and with OpInPt the opaque pixels inside a volume (not alpha
tested). [T: timemeas "Modifier volumes" — PT pixels in an opaque volume are shaded twice, 0x406080 + 0x202020;
dumprules page 0 cell 22 — the second shading is alpha tested; uvrun kind 7 — a PT polygon without the shadow bit is
shaded again with its own parameters in runs over the pixels inside; optrun kinds 9-10]

### 11.5 Translucent, pre-sorted (RM_TRANSLUCENT_PRESORT)

`valid = rendered = 0` for every pixel; then the TR list in order. Each primitive: fragments with the polygon's
`DepthMode` against `depthA`; on pass, depth write unless `ZWriteDis`, `tagA = tag`, `valid = 1`. Right after the
primitive (a triangle of a strip, a triangle, a quad), SHADE its valid pixels; each shaded pixel gets `valid = 0`.
The translucent modifier list is ignored. The stencil from the opaque / PT_MOD phase stays: a polygon with the
shadow bit takes the volume's parameters inside an opaque volume, but its runs do not end there. [T: uvspan —
translucent in submission order, a polygon is shaded whole in its own pass, 407,063 readings; uvrun kinds 10, 11 —
an opaque volume shadows pre-sorted polygons without cutting their runs; dumprules page 8 — ZWriteDis honoured; depth
page 0 TR cells]

### 11.6 Translucent, sorted per pixel (RM_TRANSLUCENT_AUTOSORT): layer peeling

```
savedDepth = depthA                                          # SaveDepth
do:
    MoreToDraw = false
    per pixel: depthB, tagB = depthA, tagA; depthA = Bits(0x7F7FFFFF); valid = 0; rendered = 0; stencil = 0     # PeelBuffers
    walk the TR list, fragments through the sort rule below
    if TR_MOD pointer: walk the TR_MOD list (11.2) against depthA
    SHADE pass (12); per shaded pixel: savedDepth = depthA   # the layer just drawn
while MoreToDraw
depthA = savedDepth                                          # RestoreDepth (tagA keeps the last layer's tags)
```

Sort rule, per fragment (key = (new, tag)):

```
if valid and KeyAbove(new, tag, depthA, tagA):  MoreToDraw = true; reject      # nearer than this pass's best: a later pass
if !KeyAbove(new, tag, depthB, tagB):           reject                         # at or behind the layer drawn last
if valid: MoreToDraw = true                                                    # the best it displaces waits for a later pass
depthA = new; tagA = tag; valid = 1                                            # DepthMode and ZWriteDis ignored
```

Each pass takes, per pixel, the **smallest key above the layer drawn last**. The first reference is the PT/opaque/
background key, so the layers come far to near, in one plane in list order, and every fragment whose key is above
that first reference is drawn exactly once. The number of passes is the deepest pixel's layer count (at least one). After the sort, `depthA` holds the nearest
drawn layer's depth (whether it writes depth or not), and the depth from before the sort where none was drawn. A
following keep-Z entry sees that [T: sort — 56 of 56 (six depth orders, ties, intersecting, depth write off,
compare GEQUAL and ALWAYS); dumprules page 1 cells 0-6 / shenmue_menu — polygons in one plane after one behind them
later in the list are all drawn; trtie; keepz page 3 / thps2_ingame*; uvrun — sorted per pixel, runs per pass;
hugepos `--tri all` — with garbage depths (from 2^62) the sort shows cross-talk, **not looked into: GAP**].
**GAP**: autosort with `DepthMode` other than GEQUAL / ALWAYS (refsw3 ignores the mode; no test uses another one).
**GAP**: the translucent sort cache (`ISP_FEED_CFG[23:14]`): from size/8 full-tile layers the core reports ISP out of
cache (SB_ISTERR bit 0) and the picture is still the sorted one down to size 64. Below 64 the picture is wrong
[T: ispcache]. Not modelled; every game uses 512.

## 12. The hand-off to the TSP (SHADE pass, ISP side: `SpanGen`, `SpanSort`, `RenderParamTags`)

### 12.1 Runs (`SpanGen<rm>`)

Per pass, rows j = 0..31, columns i = 0..31 left to right. A pixel takes part if:

| pass | pixel takes part |
|---|---|
| opaque, PT passes, TR pre-sorted, TR sorted | `valid` |
| PT_MOD (RM_PUNCHTHROUGH_MV) | `stencil[0] && (rendered \|\| OpInPt)` |

A run is a maximal stretch on one row of taking-part pixels with the same `tagA` (all 29 bits) and the same
**volume state** `vol`. `vol = stencil[0]`, except that it is forced to 0 (volume edges do not end runs) in: TR
pre-sorted, both PT passes, and the opaque pass when `OpInPt`. A run is `{tag, y, x, len}`; one run a clock is cut
from the tag buffer [I/T: timemeas cut — one clock a run whatever its length].

Per pixel the TSP also gets `InVolume = stencil[0] && tag.shadow`, forced to 0 in the PT passes. The PT passes
also get "alpha test on". In PT_MOD the alpha test is on for `rendered` pixels and off for the OpInPt opaque ones.

[T: uvspan — a run starts at the first pixel of the triangle visible in the pass (411,287 of 411,287 opaque
readings); uvrun kinds 1-11 — a run ends where the volume state changes, even with equal parameters, and not in
pre-sorted translucent; volrun — volume state changes made by the depth test end runs, only there; optrun kinds 1-8
— PT pixels in front of an opaque polygon do not end its runs]

### 12.2 Run order (`SpanSort`)

`SPAN_SORT_CFG[0] = 0`: the runs in raster order. `SPAN_SORT_CFG[0] = 1` (every game and test: 0x101): a window of
96 runs filled in raster order; the oldest run in the window chooses a primitive; all runs of that primitive in the
window are handed over oldest first, including runs that come in while it lasts (each run handed over frees a place,
refilled at once); then the next oldest run's primitive. The compare key is the whole tag, or with
`SPAN_SORT_CFG[8]` the tag without bits 2:0 (a strip's triangles are one primitive). Each tile, and in refsw3 each
pass, is sorted on its own. The run order does not change any ISP buffer. It changes only the TSP's carried state
(tsp.md: stuck alpha, the kept offset colour). [T: timemeas order (palette clock, 23 scenes, ~17,000 runs; window 95
or 97 put 129-276 runs out of order); spansortcfg — no picture changes with the sorter off, offset sort's strip
rule]. **Not modelled (timing)**: the "early drains", and the near-raster order with the sorter off (section 14).

### 12.3 Who updates the ISP buffers after shading

Only the PT passes (11.4) and the sorted TR passes (`savedDepth`, 11.6) take something back per pixel. The pre-sorted
pass clears `valid` per shaded pixel. `tilePixelsShaded` counts every pixel of every run (4.4).

## 13. State summary

| scope | state |
|---|---|
| per render | `perpVal` |
| per entry | `OpInPt`; PT: chunk count, current chunk, pass number, fill / prevQuad / culled counters; `MoreToDraw` |
| per primitive | the swamped det (7.1), sgn, cull result; depth plane a, b, c, det, inv, A, B (tile independent); vertex x, y, z |
| per primitive per tile | per edge: s20, sx, sy, E, unit (or the constant answer); a big edge also its 32 row masks from the first row (8.4b, 8.6; its walk values are t0, tx, ty, zero2 on the 2^102 grid, H fixed); depth: CONST (a key), REG (r0, sa, sb, fa, fb) or BLOCK (d0, dx, dy, unit, E; in the G form S, DX, DY, gexp, E and whether the start is zero) |
| per pixel (persists across entries) | depthA, tagA, stencil |
| per pixel (per entry / pass) | valid, rendered, depthB, tagB, depthC, refTagC, opTag, resTag, resDepth, resolved-last-pass, everRendered, savedDepth |
| between entries | prevWrittenOut, havePrev, previous tile (4.4) |

Every depth here (depthA, depthB, depthC, resDepth, savedDepth, the background) is a stored depth: refsw3's 64-bit
order key (9.7).

## 14. Timing anchors and races (for the cycle model)

refsw3 has no clock. The RTL's timing must come from these measurements (dreamcast-tests `pvr-tests/timemeas/REPORT.md`,
`PIPELINE_SHAPE.md`; core clock 100 MHz):

- ISP per primitive: **16 clocks a triangle** whatever its format, depth result or place; a strip after its first
  triangle alternately 19 and 15; a sprite (quad) 19; a culled triangle 15.2; +1 per line and triangle beyond 16 lines
  (a 32 x 32 quad 64, a 32 x 32 sprite 32). The first objects of a tile cost 70-100, then the slope. [I] One setup of
  ~16 clocks feeding a rasterizer of one tile line (32 pixels) a clock; the first 16 lines hide behind the next setup.
- 20-31 clocks per list pointer present; Z clear and background setup 142; an empty keep-Z entry 17 (899 without
  keep Z).
- Cutting into runs: one run a clock; a queue of ~512 runs between the ISP and the TSP. The ISP runs up to ~15
  background tiles ahead of the TSP, and its work on a tile is free while the TSP shades the entry before. Cutting
  overlaps the next tile's ISP work by a rule not known.
- Depth processing never shows in the time.

Behaviour that depends on the clock (refsw3 does not model it, the RTL will produce *something*, and the tests are
`*_races` in dreamcast-tests, excluded from regress.sh unless named):
- **PT chunk carry**: whether pixels resolved in one chunk take part in the next chunk's first pass as run-only
  pixels depends on how far the ISP is ahead of the TSP [T: ptchunkcarry_races (k = 6, 7 fillers: first tile row and
  the first tile after empty ones carry), ptchunkrun_races].
- **Empty keep-Z entries** collide with the write-out before them: two in a row never finish; one costs ~2390 clocks
  and gives the tile two before the next tile's picture [T: accbuf_races, keepz_races].
- **Span sorter**: early drains; near-raster order with the sorter off (early runs by timing) [T: timemeas order,
  spansortcfg]. SPAN_SORT_CFG 0x100 and 0x10001 hang the core.

## 15. Consolidated GAPs and refsw3-only choices

The row numbers are those of the `2d08a440` transcription, kept so that references stay valid. Rows that refsw3
`6784ea3d` / `708fb8cd` / `1040c4aa` / `0de9776b` / `4f3efe15` closed say so; the open questions they left are in
their row or from #24 on. The depth rows (#2-#11, #13, #26, #27) are at `4f3efe15` (depth spec sync, section 0).

| # | what | refsw3 does | evidence / status |
|---|---|---|---|
| 1 | the edge unit past 2^128 | the swamp, the walk (8.3, 8.4b) | **closed** by `6784ea3d` (faredge 1,340 of 1,340); its residuals, hugepos_rules page 11 (10 tiles) and hugepos_v5 (1 tile, 79 pixels), **closed** by `1040c4aa` (the units 2^102 and the sx < 0 end rule: hugepos_rules 3,600 of 3,600, hugepos_v5 2,400 of 2,400; the regression has no known miss left) |
| 2 | depth constant exactly 2^128 | the limit at every product and sum (6.3) | **closed** by `708fb8cd` (zovf 1,080 of 1,080) |
| 3 | negative depth outside its block's top binade | `Neg` (9.7) | **closed** by `708fb8cd` (the depthgaps hunt) |
| 4 | negative stored sizes below ~2^-122 | E at least -122 (9.4a) | **closed** by `708fb8cd` (depthgaps_tinymean 336 of 336) |
| 5 | positive depth >= 2^128; positive denormal depths | `Big`; float denormals | `Big` measured (depthgaps_bigpos, _bigord); its 19-bit cut and the denormals' order by value **closed** by `0de9776b` (depth2_biggrid 30 of 30, depth2_denorm 420 of 420; 9.6) |
| 6 | the overflow register's words | REG (9.5) | ovf 1, kWrap / WrapWord's open bits and a negative start are **closed** (the forced start, RegDepth, depthgaps_rstart); its words among other planes' depths, an off-grid slope below zero of 2^102 or more and REG with HALF_OFFSET[0] = 0 **closed** by `0de9776b` (depth2_regmix 3,600 of 3,600, depth2_regbelow 666 of 666, depth2_cneg 12 of 12, depth2_halfc). Left: a slope of 2^128 or more after the division (mod 2^132); m = 17, 18, 20, 21 against an ordinary block (never shows) |
| 7 | infinite determinant; a determinant of 2^126 or more | depth 0 (9.3 steps 1, 1b) | **closed** by `4f3efe15` (trsort_recip 160 of 160 with page 10, trsort_recipovf 80 of 80, trsort_auto 240 of 240, trsort_garb 160 of 160; 6.3, 10.3) |
| 8 | det 0 / perpendicular with an infinite or NaN corner depth | the mean with infinities (9.4b) | **closed** by `708fb8cd` (depthgaps_dzinf 48 of 48) |
| 9 | the ISP's mean: x 0xAAAAAB or / 3 | x `OneThird` | invisible (the same 19 bits for every 24-bit sum). The mean's zero rule is **closed** (6.3, depthgaps_zadd) |
| 10 | slopes > ~2^71 x the start | the block form | **closed**: refsw3's float form is unreachable (9.4a) |
| 11 | unranged slopes: `a * inv` of 2^128 or more with finite a, b (a determinant below 1) | stepped as numbers | not isolated (depthgaps_edges reaches 2^122 a pixel). The start is ranged since `708fb8cd` (depthgaps_tinyramp) |
| 12 | denormal x, y in the edge unit | exact denormals | not measured |
| 13 | depth sample point with HALF_OFFSET[0] = 0 | the start at the tile's corner, whole steps from it (9.3) | **closed** by `0de9776b` (depth2_halfc, depth2_halfo 16 of 16; `708fb8cd`'s centre start stepped back half a pixel differs at 39 % of random pixels) |
| 14 | PARAM_BASE not 1 MB aligned; parameters past 8 MB / below PARAM_BASE's page | mask on the ISP side, none on the TSP side; wraps | console draws nothing (zexfil) |
| 15 | object list type 110 | ignored | not measured |
| 16 | VolumeMode 3..7; "outside" summary on untouched pixels | as 0; bit 0 kept | modvol arrangements only |
| 17 | keep Z keeps the stencil | kept | not measured |
| 18 | OP_MOD with no OP list and no PT list | never walked | not measured |
| 19 | PT chunks: quad at the boundary 4 or 3; culled quad after a drawn quad; bad-corner primitive | 3 (lag); 3; counted | not measured |
| 20 | autosort DepthMode other than GEQUAL / ALWAYS | ignored | not measured |
| 21 | translucent cache size < 64, discard mode, SB_ISTERR | not modelled | ispcache |
| 22 | translucent modifier volumes in general; pre-sorted background skip | sorted only; ignored in pre-sort | TODO C6, timemeas |
| 23 | the races of section 14 | not modelled | *_races tests |
| 24 | the walk's fine units; its end rule with a column step below zero | 2^102 (one grid with the ordinary rows), cut toward zero; R alone, R + 2^131 for a multiple of 2^126; against ZERO | **closed** by `1040c4aa` (edge2_walk, edge2_end, edge2_mult; 8.3, 8.4b). Left: the mechanism of the 2^131 (a reading only, 8.4b) |
| 25 | row 31 a row earlier: why; an ordinary polygon (no big edge) with its top corner in row 31 | every polygon (`1040c4aa`) | the ordinary case **closed** (edge2_walk page 6, edge2_row31; 8.6). Left: why row 31 |
| 26 | the zero rule in the depth setup's coordinate differences, edges and determinant | applied (`subC`, `addE`: 6.3, 9.2) | **closed** by `0de9776b` (depth2_zcoord 80 of 80, depth2_zedge 65 of 65: `zeroRuleCoords`, `zeroRuleEdges` 1); not in the edge unit (6.2) |
| 27 | NegWord's fallback word (a start cut to zero, slopes of 2^134 and more) | 0x80000000 \| (E + 126) << 23 | [R] marked "not reached"; `At` returns it at uncovered pixels only (9.6) |

## 16. Test index (dreamcast-tests pvr-tests/)

| test | ISP rule(s) it pins |
|---|---|
| covmeas (98 sets) | edge arithmetic, zero zone, row rule, tie rule, last column, winding from det, det 0 positive, row range, degenerate rows, strips / sprites / modvol coverage, HALF_OFFSET coverage |
| hugepos; hugepos_a, _b, _all, _odd_*, _cov, _sw1-4, _val1, _v3-v6, _rules | winding from det, the swamp, the start's saturation at 2^127, a difference of 2^128 stepping by 2^127, E at most 129, the walk (wrap, end) |
| faredge; faredge_cmax, _k132 | the swamp per product, two of one sign cancelling, the push |
| faredge_m131, _ecap, _walk, _far32 | EdgeWinding, E at most 129, the walk (wrap, push, end, first row), row 31 |
| edge2_walk, _end, _mult | a big edge's grid 2^102 and its start toward zero; the end against ZERO; the far value with sx < 0 (R alone, R + 2^131 for a multiple of 2^126) |
| edge2_walk page 6, edge2_row31 | row 31 a row earlier for every polygon; the user tile clip has no part in it |
| faredge_cull | culling on the swamped determinant |
| raster, precision | coverage, shared edges, small-polygon cull, edge resolution |
| cullval | cull by size: register size only, NaN = +inf, equal culls |
| perpval, perpeq, perpmean_* | FPU_PERP_VAL, the mean's arithmetic and storage |
| zmeas (13 sets), zblock, ztile, zstart | the depth plane, block stepping, 19-bit storage, start cut |
| zexfil | the whole depth buffer read out (calibration, 64 dumps) |
| zsign, zneg, bgspec, bgneg, bgneg2, bgbig | the depth order, negative and huge depths, saturation |
| zspec, zbad, zbadbg, zbadk, zovf, zword, nantr_* | underflow, REG and its words |
| zovf_lim, _c, _ps, _sum, _far, _ab | the 2^128 limit at every product and sum |
| zovf_creg, _slope, _wrap | REG: the finite slope's steps |
| zovf_sat, _word, _satw, _satw2 | the forced start (a start infinite on one side) and its words |
| zovf_neg, _neg2 | negative depths in the block form (Neg's window) |
| depthgaps_zadd, _field1 | the zero rule; every zero sum +0 |
| depthgaps_negpp, _neggrid, _negladder, _search, _negconv, _negramp, _ties, _uwmat, _final, _tinymean | Neg: the window, the places between fields, E's floor of -122 |
| depthgaps_bigpos, _bigord, _bigslope, _bigpair | Big; E's ceiling of 128 |
| depthgaps_infstart, _edges, _regb, _final | the forced start; denormal depths; a large slope after the division |
| depthgaps_phase, _rstart, _rcut, _mm | REG: its start; the order of its 32 whole-step words |
| depthgaps_flt, _tinyramp | a start cut to zero stepped on the slopes' grid; the start in the setup's range |
| depthgaps_detneg, _dzinf, _nanprod | the mean's cuts and infinities; a NaN in a product |
| depthgaps_tiny | denormal depths |
| depth2_halfc, _halfo | the start at the tile's first sample point (the corner with HALF_OFFSET[0] = 0), REG included |
| depth2_zcoord, _zedge | the zero rule in the coordinate differences; in the edges and the determinant |
| depth2_cneg | REG: an off-grid finite slope below zero of 2^102 or more, toward zero |
| depth2_denorm, _biggrid | denormal depths ordered by value; Big's 19 bits cut |
| depth2_regmix, _regbelow | REG's words and values between steps among other planes' depths (above / below a block's window, Big) |
| trsort_recip, _recipovf, _auto | a determinant of 2^126 or more (exactly included) or infinite: depth 0 |
| trsort_garb, _auto | the translucent sort orders garbage and zero depths as the depth test (10.3) |
| detinf, huge | infinite determinants, range rules, bad corners |
| bgdepth, bgtie, dumprules p2-7, depthgaps_bglow, _bglow2, _bglow3, _bgpin | the background depth |
| depth | DepthMode per list, depth write, PT ignores the mode |
| dumprules, zsource | modvol strictly greater, PT/TR plane order, ZWriteDis per list, PT leaves its ISP depth |
| trtie, sort | the key order, first reference = what is there, ties with the background |
| modvol, volrun, uvrun, optrun, optcull | volume inclusion / exclusion, run breaks, OpInPt |
| ptchunk, ptchunkq, ptchunkm, ptchunkcost, ptchunklag | PT chunk assignment |
| ptlayers, ptruns | PT pass membership, run-only pixels, re-shading only where a later pass draws |
| keepz, accbuf, timemeas | keep Z, end-of-entry, background shading, timing |
| uvspan, spansortcfg, timemeas order | runs and their order |
| perpmean_negstore / _negedge / _neg / _bg / _negslope | the negative store (window and outside it) |

## 17. Lockstep points in refsw3

For per-unit testbenches (polly2-rtl `tb/`), these functions take plain inputs and are header-only (include
`refsw3/refcore/pvr_isp_edge.h`, `pvr_isp_depth.h`; no other dependency; `agents/spec-refresh/widths708.cpp` and
`agents/spec-sync-edge/widths4f3.cpp` are examples):
- `pvrisp::Winding` (bad corners), `pvrisp::EdgeWinding` (sgn and the culls' det), `pvrisp::RowRange`;
- `pvrisp::EdgeTile::Setup / SetFirstRow / Inside / InsideOrdinary / RowMask / Walk / RowOutside` (its fields
  `t0`, `tx`, `ty`, `zero2`, `tie2`, `big`, `f0`, `fx`, `fy`, `h`, `z`, `rowMask` are public; since `1040c4aa` `f0`,
  `fx`, `fy`, `z` equal `t0`, `tx`, `ty`, `zero2` on a big edge);
- `pvrisp::DepthTileT<DepthHW>::Setup / At / NegWord / RegDepth` (its state `valid`, `block`, `ovf`, `sa`, `sb`,
  `r0`, `fa`, `fb`, `first_z`, `d0`, `dx`, `dy`, `unit`, `E`, `A`, `B`, `startCenters` is public; `Setup` resets it).
  Since `0de9776b` `Setup(x, y, z, left, top, cfg, centers)` takes the sample point (HALF_OFFSET[0]) and `At(i, j,
  centers)` must be asked with the same value for the hardware's key (another one adds half steps, 9.4a);
  `DepthTileT<DepthConfig>` with `zeroRuleCoords` or `zeroRuleEdges` 0 is the reference for those mutants
  (`agents/spec-sync-depth/widths4f3d.cpp` is the example at `4f3efe15`);
- `pvrisp::StoredDepth::{Key32, Bits, Between, Neg, Flat, Big, FromFp, Saturated, key}`;
- `pvrfp::{Mul, Add, Recip, Perpendicular, OneThird}`.

The depth setup's `limit`, `mul`, `addRule` (`add`, `subC`, `addE`) and the mean's `addInf` (`addBad`) are lambdas inside
`DepthTileT::Setup`, and the background word is inside `RenderCORE` (refsw_lists.cpp): copy them (num §7.1).
`KeyAbove`, `PixelFlush_isp`, `CulledBySize`, `CulledByFacing` are file-static in `refsw_tile.cpp` (`TriangleCulled`
is not, but reads the registers). Whole-frame comparisons go through refsw3-offline, whose `log <file> [x,y ...]`
command writes the per-tile trace (`TILE`, `OBJECT`, `TRIA`/`TRIC`, `ISP`, `ZFAIL*`, `RENDERED`, `STENCIL`, `CULLED`,
`PASS`, `SPAN`, `TSP`, ...).
