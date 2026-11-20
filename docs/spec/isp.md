# ISP specification: from the region array to the visible-polygon decision

The ISP side of the CLX2 core, as refsw3 implements it. This document is meant to be enough to build the RTL from.
It covers the region array walk, object list parsing, the setup unit's arithmetic (edges, determinant, culling,
depth plane), the inside test, the depth compare and the per-pixel buffer updates of every list type (opaque,
modifier volume, punch-through, translucent pre-sorted and sorted per pixel), and the hand-off to the TSP (which
pixels get shaded, in which runs, under which volume state). The TSP's shading and the write-out / scaler are
covered by other specs (docs/spec/tsp.md, the write-out spec). This document refers to them only where the ISP
depends on them: the alpha test result and the end-of-entry buffer swap.

## 0. Sources, notation, status

**Functional truth**: refsw3, nulldc3 branch `skmp/refsw3`, HEAD `2d08a440` ("the perpendicular mean to the last
bit"), folder `refsw3/refcore`:

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

### 4.2 Z clear and the background depth (`ClearBuffers`, refsw_lists.cpp)

Without `z_keep`, every pixel: `depthA = BG`, `tagA = ISP_BACKGND_T`, `stencil = 0`, `valid = 1`, `rendered = 0`.
With `z_keep`, only `valid = rendered = 0`. The depth, tag and stencil are kept. The stencil not being cleared
by keep Z is refsw3's reading: **GAP**.

`BG` is a stored-depth word (section 9.7) made from `ISP_BACKGND_D` (`bg`, 32 bits; `field = bg[30:23]`):

```
if bg[31] == 0:                                  # zero or above
    cut   = max(5, 130 - field)                  # fraction bits dropped
    BG    = (cut > 23) ? 0 : bg & ~((1 << cut) - 1)
else:                                            # below zero
    q     = ((bg & 0x7FFFF0) + 0xFF) >> 8        # low 4 fraction bits cut, then the size rounded UP to 15 fraction bits
    BG    = field < 107 ? 0
          : field < 133 ? 0xC2FFFFFF             # one fixed word: the lowest depth of the binade of 64
          : (bg & 0xFF800000) | (q >= 0x8000 ? 0x7FFFE0 : q << 8)
if field == 255: BG -= 1 << 23                   # exponent field 255 becomes 254, the fraction kept
```

What this means: above zero, a float with 19 significant bits whose smallest exponent is that of 0.25 (field 125).
Below field 125 it is a denormal of that exponent, so the smallest step is 2^-20, and anything below 2^-20 is 0.
+-infinity is +-2^127, which ties with an overflowing polygon (`Saturated`, 9.7). Positive NaNs stay above it. Below
zero: under 2^-20 in size 0; from 2^-20 to under 64 the single word 0xC2FFFFFF (not cut); from 64 up its own value
on the negative polygon grid (16 bits, rounded up in size, no carry into the exponent).

[T: bgdepth — 32 background depths 2^-20 .. 1e6 against 300 probes each; bgtie — a polygon at 0.5 ties with a
background of 0.5 + 2^-20 (a float, not fixed point); dumprules pages 2-7 / xtreme_intro — below 2^-20 it is 0,
nothing is behind it; trtie pages 12-15 / rez_ingame; bgspec (2560 regions), bgbig (2^127 ties, 1.5 * 2^126 below,
1.5 * 2^127 and the largest float above), bgneg, bgneg2 (the 0xC2FFFFFF word); depthgaps_bglow (300 regions),
_bglow2 (27), _bglow3 (51) — the 16-bit round-up and the 0x7FFFE0 case below zero.] **GAP**: whether a negative
background of 64 and more loses its low 5 fraction bits as a positive one does (bgspec "Left").

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

Exponents are not limited in the edge unit (c reaches 2^245 [T: hugepos]). With inputs between 2^-149 and 2^128, an
internal exponent of about 10 bits with sign covers both units (products 2^-298 .. 2^256).

### 6.3 Range rules (depth unit only; `DepthHW::range = 1`)

Applied after every `Mul` and `Add` of the depth unit's plane setup (the lambdas `mul`, `add`, `limit` in
`DepthTileT::Setup`):

- a result with `|r| >= 2^128` becomes infinity (`bad`, sign of r);
- a result with `|r| < 2^-126` becomes zero (+0 for a sum, sign of r for a product);
- `bad * x`: zero if x is a non-bad zero (sign xor), otherwise infinity (sign xor);
- `bad + bad` of opposite signs: +0; `bad + finite` or `bad + bad` of the same sign: infinity with the bad
  operand's sign.

[T: huge — 250 of 250 regions with these rules (228 without), including the quads at 2^127 / infinity / NaN of which
a console draws one triangle only; zspec, zovf, nantr_* (section 9.5)]. **Note [R]**: refsw3 applies these rules to
`a`, `b`, `c`, `det` and to the tile start used for the overflow decision (`first0`). The main path (9.3) recomputes
the start and the slopes `A`, `B` with the **unranged** operations and afterwards only flushes `|v| < 2^-126` to
zero. The two differ only for intermediate values below 2^-126, or for a slope `a * inv` of 2^128 or more with finite
`a`, `b`, `c` and start. The RTL must follow refsw3 there. **GAP**: no test isolates either case.

## 7. Triangle setup: determinant, bad corners, culling, perpendicular

Per primitive, before any tile work (`RasterizeTriangle`, `TriangleCulled`).

### 7.1 Determinant and winding (`pvrisp::Winding`, edge unit arithmetic)

Corners 1, 2, 3 in rasterizer order (3.4); for quads the first three. With `EdgeHW` (24-bit products, 24-bit sums,
reach 25), unranged, `FromBits` inputs:

```
e1  = Sub(Mul(x2, y3), Mul(x3, y2))
e2  = Sub(Mul(x3, y1), Mul(x1, y3))
e3  = Sub(Mul(x1, y2), Mul(x2, y1))
det = Add(Add(e1, e2), e3)                       # (e1 + e2) + e3
winding: sgn = +1 if det < 0 (nonzero), else -1 (det >= 0, a zero counts as positive)
```

[T: covmeas rule 2 and 9 — the console follows the setup's determinant, not the exact area: 1,041 sliver triangles
with the opposite sign, ~5,500 with det exactly 0 taking the positive winding; hugepos b — exact area 0 in double
from 2^62, the setup's det draws what the console draws; precision / zmeas — the (e1 + e2) + e3 order]

**Bad corners**: if any x or y of the 3 corners (4 for a quad) is infinity or NaN, the primitive draws nothing. It
is not "culled" (that matters for PT chunk counting, 11.4) [T: huge — infinity or NaN in one coordinate: nothing
drawn].

### 7.2 Culling (`CulledBySize`, `CulledByFacing`)

Only with `CullMode != 0`, and only when no corner is bad:

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

[T: cullval — 16 pages, FPU_CULL_VAL 1, -1, 2, -2, 0.5, -0.5, +0, -0, +-inf, NaN, -NaN, sNaN, +-2^-149, 1e30: only the
size counts, every NaN culls like +inf, 2^-149 culls nothing, 4800 of 4800 regions; raster page 4 — legs of 1 pixel
at 1.0: equal is culled; covmeas degen — with any culling mode degenerate triangles draw nothing]. A culled
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

### 8.2 The unit's numbers (`EdgeHW`)

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
| `overflowExp` | 128 | the start saturates when the first sum or the start reaches 2^128 ... |
| `saturateExp` | 127 | ... to +-2^127 |
| `lastColumnByStep` | true | a zero pixel in column 31 is inside iff the column step is positive |

[T: covmeas — 98 archived sets, 55 M pixels, 0 differences; every single change of a parameter is worse (tie
threshold 63: 30 pixels, 32: 375, 128: 246; reach 24: 3, 26: 34; zero zone 63: 1122, 65: 32); hugepos;
precision page 5 / raster 1040 of 1040]

### 8.3 Edge setup per tile (`EdgeTile::Setup`)

Inputs: corners `a = (xa, ya)`, `b = (xb, yb)` (FromBits), `sgn`, and the tile's first sample point
`x0 = left + h/2`, `y0 = top + h/2`, `h = HALF_OFFSET[0]` (1: pixel centres, 0: pixel corners).

```
c     = Sub(Mul(xb, ya), Mul(xa, yb))                   # 24/24, reach 25
dx    = Sub(xa, xb);   dy = Sub(ya, yb)                 # 24, reach 25
first = Add(Mul(dx, y0), -Mul(dy, x0))                  # products 24; sum exact, cut 24; reach 25
if |first| >= 2^128:
    start = +-2^127 (sign of first)
else:
    start = Add(first, c)                               # exact, cut 24, reach 25
    if |start| >= 2^128:
        if |dy| >= 2^127: start = (+-2^132) - first     # sign of start; 62-bit sum (effectively exact)
        else:             start = +-2^127               # sign of start
sy = cut20(dx)                                          # row step
sx = cut20(-dy)                                         # column step
ep = max(top(dx), top(dy));  es = top(start)
if ep == NoExp and es == NoExp: CONSTANT, INSIDE        # a -> b is a point: zero everywhere counts as inside
s20 = cut20(start)
if sgn < 0: s20, sx, sy = -s20, -sx, -sy                # turn the edge so that inside is positive
if ep == NoExp: CONSTANT, inside = (s20 >= 0)           # (unreachable in practice: dx = dy = 0 forces c = 0)
E    = max(ep + 6, es + 1)        (es + 1 only if start != 0)
unit = ep - 21                                           # exponent of the steps' last kept bit
if E - unit > 56: CONSTANT, inside = (s20 >= 0)          # [R] refsw3's cap; see 8.5 for the hardware-sized one
sx = cutBelow_unit(sx);  sy = cutBelow_unit(sy)
t0    = 2 * floor(s20 / 2^unit) + (s20 not a whole multiple of 2^unit ? 1 : 0)   # half units of 2^unit
tx    = 2 * sx / 2^unit;   ty = 2 * sy / 2^unit                                 # exact, even
zero2 = 2^(E - 21 - unit + 1)                                                    # half units; = 2^(E-21) in value
tie2  = zero2                                                                    # tieShift == zeroShift
```

The edge function is `F(x, y) = c + dx*y - dy*x` (zero on the line through a and b, `F` stepping `-dy` per column,
`dx` per row). The values above are `F` at the tile's first sample point and its two steps, in block form, turned so
that the triangle's inside is positive. `t0`'s lowest bit marks "the start has bits below the grid" (it then lies
strictly between two grid values).

Rules and their tests:
- the constant `c` from absolute coordinates, `c = T(xb ya) - T(xa yb)` [T: covmeas rule 1 — forms from coordinate
  differences are far off, 77 %];
- the start at the tile's first sample point, kept as a 20-bit float; the first sum drops an operand 25 exponents
  below the other (first tile column / row, where x0 or y0 is 0.5) [T: covmeas rule 3];
- the steps as 20-bit floats sharing the larger one's 21-bit grid [T: covmeas rule 4];
- saturation at 2^127 [T: hugepos a — the console's pixels exactly at 2^118 .. 2^124: 15,019, 705, 15, 2]; the
  +-2^132 - first rule for a column step of 2^127 or more [T: faredge pages 12-35 — K 127 vertical triangles' crossings
  19 to 24 pixels into the tile; modvol — the garbage polygon's edge, 192 of 192 cells]. **GAP**: faredge page 4's
  first-column strip (far corner up, the first product the one past 2^128) keeps 2^127 on the console, and page 1's
  control strip (K 122, dy x0 at 2^128) draws 9 pixels wider. faredge 1330 of 1340: which rule the hardware takes
  when is not known.

### 8.4 The inside decision (`EdgeTile::Inside`)

For pixel (i, j) of the tile:

```
if CONSTANT: return constantInside
r = t0 + ty * j                                  # the row's value at the tile's FIRST column
if |r| <= zero2:                                 # the row starts at zero: the whole row of this tile gets one answer
    return (|tx| <= tie2) ? (ty > 0) : (tx > 0)
v = r + tx * i
if v >  zero2: return true
if v < -zero2: return false
if i == 31:    return tx > 0                     # the last column has no next pixel
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

`EdgeTile::RowOutside(j)` (`r < -zero2 && r + 31 tx < -zero2`, or the row-zero rule giving false) skips rows that
no pixel can be inside. It is exact (the values are linear in i) and only saves time **[R]**.

### 8.5 Widths for the RTL (derived, checked against refsw3)

Let `d = E - unit` (27..56 in refsw3).
- If **d >= 30**, the whole tile has the start's sign: `inside = (s20 >= 0)` for every pixel. (`|t0| >= 2^29`,
  while 62 steps add less than 2^28 half units.)
- If d <= 29, every value the decision looks at (`r`, `v`, `v + tx`) fits a **31-bit signed** integer in half
  units of 2^unit: `|t0| < 2^29`, `|tx|, |ty| < 2^22`.

Checked with refsw3's own `EdgeTile` on 400,000 random edges (wide exponent mix, pixel-grid and ulp-perturbed
corners, both windings and sample offsets): 0 mismatches of the d >= 30 rule, largest magnitude below d = 30 is
2^29.52 (`polly2-rtl/agents/spec-isp/widths.cpp`, 0.5 s). So the edge per tile is: a 20-bit float start, two
20-bit float steps on a shared 21-bit grid, E, and a 31-bit accumulator per edge (or per edge and pixel column when
a line is done at once).

### 8.6 Row range (`pvrisp::RowRange`)

For every primitive that is not a modifier volume triangle:

```
rowFirst = min over corners of floor(y)
rowLast  = max over corners of floor(y + 1/2)          # = (floor(2y) + 1) >> 1 (arithmetic shift); FloorScaled, clamp 2^40
a row Y (screen row, top + j) is rasterized only if rowFirst <= Y <= rowLast
```

Over all corners (4 for a quad), the same in row numbers whatever HALF_OFFSET is; no limit on columns. [T: covmeas
rule 10 / sliver mixes — 0 of 635 accepted pixels above the top corner's row are drawn, 0 of 483 two rows below, the
row after the bottom corner's exactly when frac(ymax) >= 0.5 (72 of 72 / 0 of 70); sliver35 with HALF_OFFSET 6;
zprobe — outside the range the depth is not written either; sliver36 — modifier volume triangles have no range]

## 9. The depth unit (`pvr_isp_depth.h`)

### 9.1 The unit's numbers (`DepthHW`)

| constant | value | meaning |
|---|---|---|
| `productBits` | 24 | every product (z * difference, z * e, a * x0, b * y0) truncated to 24 bits |
| `sumBits` | 24 | every sum truncated to 24 bits |
| `reach` | 25 | adder alignment reach (measured on the edge unit) |
| `recipBits` | 24 | 1 / det truncated to 24 bits |
| `coefBits` | 24 | `a*inv`, `b*inv`, `c*inv`, `start*inv`, the mean's `sum * 1/3` truncated to 24 bits |
| `startBits` | 20 | the tile's start kept as a 20-bit float (truncate) |
| `slopeBits` | 20 | the slopes as 20-bit floats (truncate) |
| `pairBits` | 21 | both slopes cut to 21 bits under the larger one's exponent |
| `tileBits` | 26 | the stepping grid: 26 bits under the block exponent |
| `storedBits` | 19 | a depth is stored with 19 significant bits (truncate) |
| `storedNegBits` | 16 | a depth below zero in the block's top binade: 16 bits, size rounded up |
| `startOnSlopes` | 1 | the start is cut to the slopes' 21-bit grid too, whatever its sign |
| `range` | 1 | the range rules of 6.3 |

[T: zmeas — 13 sets, 89,801 brackets, 0 missed (with zstart's rule), every one-bit change of a width breaks 50 to
1,800; zblock 59,220 / 59,220 (a 19-bit stored mantissa on the pixel's own exponent, not the tile's); ztile 11,280 /
11,280 (the start and its exponent are taken again at every tile); zstart 49,152 / 49,152 (any start is cut to the
slopes' grid); zexfil — 64 dumps x 307,200 depths read out, all the console's]

### 9.2 Plane setup (per primitive)

Corners 1, 2, 3 in rasterizer order, `FromSingle` (ranged) inputs, every operation `mul` / `add` with 24 bits, reach
25 and the range rules (6.3):

```
e1  = x2*y3 - x3*y2;  e2 = x3*y1 - x1*y3;  e3 = x1*y2 - x2*y1        # each: (product) - (product)
a   = ( z1*(y2 - y3) + z2*(y3 - y1) ) + z3*(y1 - y2)                 # (t1 + t2) + t3
b   = ( z1*(x3 - x2) + z2*(x1 - x3) ) + z3*(x2 - x1)                 # (t1 + t2) + t3
c   = ( z1*e1 + z3*e3 ) + z2*e2                                      # (t1 + t3) + t2
det = ( e1 + e2 ) + e3
if Perpendicular(det): det = 0                                       # 7.3
```

The plane is in determinant form: the depth is `(a x + b y + c) / det`. [T: precision / "The setup unit's
arithmetic" (59,220 of 59,220); zmeas item 1 — the sum orders, 5,417 -> 7,043 of 7,091 from the order alone, exactly
one of 384 combinations fits]

### 9.3 Per tile: the regimes

`(x0, y0) = (left + 1/2, top + 1/2)`: **always the first pixel's centre**, whatever HALF_OFFSET (9.4 handles the
corner sampling). In this order:

1. **det infinite** (`det` bad): every pixel stores 0. **GAP** [R]: not measured (huge cannot tell; modvol's one
   pixel is behind 0.75).
2. **det nonzero, finite**: `inv0 = Recip(det, 24)`; `first0 = ((a*x0 + b*y0) + c) * inv0` (ranged). If `first0`,
   `a`, `b` or `c` is infinite, the plane **overflows** (9.5). Otherwise continue with 4.
3. **det zero** (or perpendicular): if all three z are finite, **the mean** (9.4b). If a z is infinite or NaN, every
   pixel stores **z1's bits as given** (the first corner's word, not even cut). **GAP**: detinf's flat probe quads at
   +infinity cannot tell this from +-2^127.
4. **The ordinary plane** (9.4a).

### 9.4a The ordinary plane: block floating point per tile

```
inv   = Recip(det, 24)
A     = Mul(a, inv, 24);  B = Mul(b, inv, 24)                         # unranged (6.3 note)
first = Mul( Add( Add(Mul(a, x0, 24), Mul(b, y0, 24), 24, 25), c, 24, 25 ), inv, 24 )    # ((a x0 + b y0) + c) * inv
A, B, first: |v| < 2^-126 -> 0
pair  = max(top(A), top(B))                                           # NoExp if both zero
if first == 0 and pair == NoExp: every pixel stores 0
e     = (first == 0) ? pair + 5 : top(first)
start = cut20(first)
if pair != NoExp: start = cutBelow_(pair - 21)(start)                 # onto the slopes' grid, toward zero, either sign
negE  = max(e, pair + 5)                                              # the block exponent
G     = 2^(negE - 26)                                                 # the stepping grid
step(V) = cutBelow_G( cutBelow_(pair - 21)( cut20(V) ) )              # for V = A, B
S, DX, DY = start / G, step(A) / G, step(B) / G                       # integers, exact
```

refsw3 keeps these in units of `2^unit`, `unit = e - 26`, which is G or finer. The values are always multiples of G,
so an RTL can use G directly. [Derived. Checked with refsw3's `DepthTileT` on 300,000 random triangles: d0, dx, dy
were multiples of G in every block plane (`agents/spec-isp/widths.cpp`).]

Per pixel (i, j), with `h = 0` when the ISP samples centres (`HALF_OFFSET[0] = 1`) and `h = -1` when it samples
corners:

```
t = 2*S + (2i + h)*DX + (2j + h)*DY             # half units of G: value = t * 2^(negE - 27)
```

`|t| < 2^29` always (`|S| < 2^26`, `|DX|, |DY| < 2^21`), so the stepping is a **30-bit signed** accumulator in half-G
units (checked: largest 2^28.52 over 300,000 triangles). The value is exact (fixed point, no rounding while
stepping) and is then stored (9.6). [T: zmeas items 2-3 — the start is `((a x0 + b y0) + c) * inv`, the plane before
its division, evaluated at the first pixel centre (14,289 of 14,291); the two slopes share the larger one's 21-bit
grid and are cut to the tile's grid (28,686 of 28,686); "Mix reach" — the stepping holds at least 29 powers of two
above the start, a start of exactly zero is stepped on the slopes' grid (30 of 30, 22 before); zstart — the start
cut to the slopes' grid, any sign (pages 0-2, 49,152 of 49,152; positive-only or negative-only cuts miss 117 and 4);
zblock / ztile — the exponent is the polygon's own and is taken again at every tile, even where the polygon does
not cover the tile's first pixel]

**GAP [R]**: refsw3 abandons the block form when `pair - 21 + 24 - unit > 100` (slopes over ~2^71 times the start)
and evaluates `(A*X + B*Y) + C` in 24-bit floating point per pixel (`C = Mul(c, inv, 24)`, X, Y the sample point),
stored `cut19`. This is a refsw3 implementation limit (its i128). In the G form above the block form never
overflows. No console test covers it. Testbenches should flag such planes.

**GAP**: the depth sample point with `HALF_OFFSET[0] = 0` (the start computed at the centre and stepped back half a
pixel, `h = -1`) is refsw3's model. halfofs's sloped-depth cells are built so that a half-pixel shift does not
change them. Coverage at corners is measured (covmeas half20-23); the depth's sample point there is not. Every game
dump but one ("mipmap") samples centres.

### 9.4b The determinant-zero (perpendicular) mean

```
sum  = add(add(z1, z2), z3)                     # ranged; z3 = the third corner in rasterizer order, added last
mean = Mul(sum, 0xAAAAAB * 2^-25, 24)           # 1/3 rounded UP to 24 bits, product truncated to 24
if 0 < |mean| < 2^-126: mean = 0
if mean is infinite: every pixel stores Saturated(sign)          # a sum of 2^128 or more: +-2^127
elif mean == 0:      every pixel stores 0
else:                a flat block plane: S = cut20(mean) on G = 2^(top(mean) - 26), DX = DY = 0, negE = top(mean)
```

So above zero the stored word is `cut19(cut20(mean))`, and below zero the 16-bit round-up of `cut20(mean)` (9.6).
[T: covmeas degen / tiny / sliver with zprobe — every pixel of a det-0 triangle at the mean of the corners (11,456 +
1,344 + 53 pixels); perpmean_word — 16,384 stored words of 16,384 (other sum orders, a rounding adder, no reach, or
0xAAAAAA miss 1,618); perpmean_neg (11,258 means below zero), perpmean_bg (136 words; 3 x 2^127 -> 2^127),
perpmean_strip (8,192 words: the third corner sent is added last, strips, odd strip triangles, sprites),
perpmean_tiny (336 regions around 2^-126)]. **GAP**: dividing by 3 and multiplying by 0xAAAAAB give the same 19 bits
for every 24-bit sum, so which one the hardware does is not visible. The TSP's 1/w mean has a rule for a zero
depth against an opposite-sign depth in [2^-126, 2^-125) (README covmeas "Its color..."). Whether the ISP's mean
has the same rule is not measured (refsw3: no).

### 9.5 Overflowing planes (regimes ovf 1 and ovf 2)

Entered from 9.3 step 2 (`first0`, `a`, `b` or `c` infinite):

```
if a or b is infinite:    ovf 2, the wrapping register:
    sa = a bad ? (a.neg != det.neg ? -1 : +1) : 0;   sb likewise from b
    r0 = first0 infinite ? +-2^25 (sign of first0)
       : first0 == 0     ? 0
       : trunc(cut20(first0) / 2^102)                # in units of 2^102, toward zero (GAP for a negative start)
    pixel (i, j): r = r0 + (sa*i + sb*j) * 2^25       # units of 2^102; 2^25 units = 2^127 = one step; no half-pixel offset
                  word = (r mod 2^25 != 0) ? WrapWord(r) : kWrap[(r >> 25) & 31]
elif a or b is nonzero:   ovf 1, only the constant overflowed:
    invS = Recip(det, 24); As = Mul(a, invS, 24); Bs = Mul(b, invS, 24)
    eS   = max(top(As), top(Bs)) + 5
    pixel (0, 0): 0;  every other pixel: (As < 0 or (As == 0 and Bs < 0) ? 0x80000000 : 0) | (eS + 127) << 23 | 0x7FFFFF
else (a == b == 0, c or the start infinite):
    every pixel stores Saturated(sign of first0) if first0 is infinite, else FromFp(cut19(first0))
```

`kWrap[32]` (the word at a whole number of steps, m = (r / 2^127) mod 32):

```
m  0- 7: 00000000 7f000000 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff
m  8-15: 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff 7fffffff
m 16-23: 807fffff fdffffff fe7fffff fe7fffff feffffff feffffff feffffff feffffe0
m 24-31: ff7fffff ff7fffff ff7fffff ff7fffff ff7fffff ff7fffff ff7fffe0 ff000000
```

`WrapWord(r)` (r in units of 2^102, a two's complement register with its sign at 2^131, wrapping every 32 steps):

```
r = ((r + 2^29) mod 2^30) - 2^29                     # 30-bit wrap
if r == 0: 0
if r > 0:  if r >= 2^26: 0x7FFFFFFF
           p = bitlength(r) - 1; m = r normalised so its leading one is bit 23
           return (p + 229) << 23 | (m & 0x7FFFE0)   # r itself, cut to 19 bits
u = r + 2^29                                          # the bits under the sign
if u == 0: 0x807FFFFF
p = bitlength(u) - 1; if p > 18: clear the low (p - 18) bits of u   # u cut to 19 bits
v = ((u << 26) >> p) - 7 * 2^24 - 1;  e = p + 226
v < -1:      0x80000000 | e << 23 | 0x7FFFFF
v == -1:     0x80000000 | e << 23 | 0x7FFFE0
v >= 2^23:   0x80000000 | (e + 1) << 23 | 0x7FFFFF
else:        0x80000000 | e << 23 | (~v & 0x7FFFFF)
```

[T: zovf — the three regimes and their sign maps; zword — the words at whole steps by binary search (kWrap), the
same for +inf, NaN and 2^127 corners and mirrored; nantr_pos — 300 cells, every corner bad in turn, six NaN payloads,
+-inf, +-max, 2^127, 2^123, 2700 of 2700 regions (70 start at +-1 step); nantr_word, nantr_fin, nantr_fin2,
nantr_wreg — the words between steps (WrapWord); zbad 4080 / 4080, zbadbg 3480 / 3480, zbadk; zspec 1040 / 1040;
bgbig — an overflowing polygon ties with a background of 2^127]. **GAPs** (from the code comments): ovf 1's sign
(measured only below zero with slopes below zero) and its low 5 bits; kWrap entries where zword's probes leave the
low 5 bits open (m 17..22, 24..29: taken as ones), m 2..15 beyond the largest float (taken as 0x7FFFFFFF), m 16
(the lowest word); WrapWord between -1 step and 0 (exponent field 255); a negative finite start's rounding onto the
2^102 grid; zovf's six cells where the constant is exactly 2^128 (refsw3 overflows, a console does not: its switch
is where `a x0 + b y0` reaches 2^128).

Underflow: the range rule makes `A`, `B`, `first` zero below 2^-126. A plane from 2^-124 to -2^-124 over a cell is
its start everywhere; one from 2^-126 to -2^-126 is 0 [T: zspec pages 3-6; detinf 480 of 480].

### 9.6 Storing a depth (`DepthTileT::At`, `StoredDepth::Store`, `StoredDepth::FromFp`)

For a block-form pixel value `v = t * 2^(negE - 27)` (exact):

```
if v >= 0 (or zero):                word = FromFp(cut19(v))
elif top(v) == negE:                word = Store(v): 16 bits, size rounded up        # below zero, the block's top binade
else:                               word = FromFp(cut19(v))                          # below zero elsewhere: GAP
```

`Store` below zero: `n = bitlength(mant)`. If `n > 16`, shift right by `n - 16`; if any bit was lost, add 1 to the
mantissa. If that carries to 2^16, the mantissa becomes the binade's largest on the **19-bit** grid instead
(`2^19 - 1` at 3 positions lower: fraction `0x7FFFE0`, no carry into the exponent). Then `FromFp`.

`FromFp(v)`: `bad` -> `Saturated`; zero -> the sign bit alone (0 or 0x80000000); round to nearest, ties to even, to 24
bits or, below 2^-126, to the denormal grid 2^-149 (after a 19-bit cut only the denormal case rounds); `>= 2^128`
after rounding -> `Saturated`; then the IEEE single encoding (denormal for `top <= -126`).
`Saturated(neg) = (neg ? 0x80000000 : 0) | 0x7F000000` (+-2^127).

So a stored depth is an IEEE-single-format word with **19 significant bits** above zero (low 5 fraction bits zero),
and 16 significant bits rounded up in size (low 8 fraction bits zero, or the 0x7FFFE0 case) for a negative depth in
its block's top binade. The flat cases (a flat plane, the mean, a flat 2x2 quad) are always in the top binade.

[T: zblock, precision — 19 bits on the pixel's own exponent; perpmean_bg page 3 (24 flat quads below zero),
perpmean_negstore page 0 (64 flat quads: 0xc2ffffe0 ties), perpmean_negedge pages 0, 2, perpmean_neg (zexfil's own
negative probes), depthgaps_negpp (360 of 360 regions: flat polygons below zero tie in groups of 0x100)]. **GAPs**: a
negative depth outside the top binade is neither this nor the 19-bit cut (perpmean_negslope, perpmean_negstore pages
1-3, perpmean_negedge page 1, depthgaps_negladder, _negramp, _uwmat, _ties: the depthgaps hunt); sizes below about
2^-122 (perpmean_tiny's first version: a mean of -2^-125 is below a flat quad at -2^-126 on the console, refsw3 puts
it above); a positive depth of 2^128 or more (taken as Saturated); the denormal range as the depth buffer's own.

**Pending, not in refsw3 HEAD**: the depthgaps hunt (`fpgadc/agents/nulldc3/hunt/depthgaps`, uncommitted
`patch_round2_final.diff`) proposes that a negative depth from the depth unit's steps is stored as its block
exponent with a fixed-point value, ordered 32 bits finer than the word (`StoredDepth::Neg`, `k`), and that positive
depths below 2^-126 are stored and ordered as denormals (depthgaps_edges, _tiny). If it lands in refsw3, the depth
buffer entry for negative depths is wider than a 32-bit word. Keep the stored-depth format behind one module
boundary until that settles.

### 9.7 The depth order (`StoredDepth::key`)

The ISP compares stored words, not floats:

```
key(w) = (w == 0x80000000) ? 0 : (int32)(w ^ (w[31] ? 0x007FFFFF : 0))       # compare as signed 32-bit integers
```

So positive depths order as floats (bigger = nearer, depth is 1/w), every negative depth is below zero, of two
negative depths **the one with the larger exponent is larger** (-2 > -1 > -1.5 > -0.5 > -0.75), within one exponent
the float order holds, a NaN is an ordinary number (positive NaNs above +infinity), and -0 equals +0. [T: zsign —
every pair of 20 depths from -2^100 to 2^100, Greater and Less; bgspec, bgneg, bgneg2; zneg 1200 of 1200 (blind below
zero, hence zsign)]. Depths below zero are drawn like any other [T: uvmeas wneg — 780,000 texels read off such
polygons; README "The TSP's numbers at their limits"].

## 10. Depth compare and the per-pixel update (`PixelFlush_isp`)

### 10.1 Buffers (refsw3's per-tile state)

| buffer | width (refsw3) | content |
|---|---|---|
| `depthA` | 32-bit stored word | opaque: the depth; PT passes: this pass's best, then what each pixel resolved to; TR sort: this pass's best |
| `depthB` | 32-bit stored word | the reference: PT boundary (last key shaded), TR sort (layer drawn last) |
| `depthC` | 32-bit stored word | PT: the opaque depth, or what an earlier chunk resolved |
| `tagA` | 29-bit tag | the visible primitive (opaque, background, PT best / resolved, TR best) |
| `tagB` | 32 bits (29-bit tag or TAG_BELOW) | the reference's tag |
| `stencil` | 3 bits | bit 0: in a volume (summary); bit 1: parity of the current volume; bit 2: touched since the last summary |
| `valid` | 1 bit | the pixel has a fragment to shade in this pass |
| `rendered` | 1 bit | PT: resolved (passed the alpha test) |
| PT extra | opTag (29), refTagC (29), resTag (29), resDepth (32), resolved-last-pass (1), everRendered (1) | 11.4 |
| TR extra | savedDepth (32) | 11.6 |

All 32 x 32. This is refsw3's state. The hardware's storage is not known beyond "depth about 28 bits (8-bit
exponent, 19-bit mantissa), tag + stencil bits" [I] (PIPELINE_SHAPE "Storage"). The RTL may store less where the
values allow it (e.g. resolved-last-pass instead of refsw3's `resPass` integer), but every compare below must give
the same answer.

### 10.2 The compare (`DepthMode`)

`new` = the fragment's stored word (9.6), `old = depthA`; compares in key order (9.7); the fragment **passes** when:

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

The sorted walks (PT passes, TR sort) order fragments by one key: the stored depth word (key order), then the tag's
sort bits (bits 23:0, i.e. list order). No two fragments are ever equal (the tag differs), so nothing is "coplanar".
A larger key is nearer, or as near and later in the list.

```
KeyAbove(aW, aTag, bW, bTag):          # is key a above key b?
    if aW != bW:            return aW > bW                         # key order (9.7)
    if bTag == TAG_BELOW:   return aTag != TAG_BELOW
    return aTag != TAG_BELOW && (aTag & 0xFFFFFF) > (bTag & 0xFFFFFF)
```

The first reference of both walks is the key of **what is there**: the opaque polygon's (or the background's, or a
resolved PT layer's) depth **and tag**. A fragment at exactly that depth is drawn only if its tag is above it
[T: trtie — 16 pages, translucent / PT quads with exactly the corners of an opaque / PT quad, lists in either order,
flat and sloped, and at exactly the background's depth (pages 9-15); shenmue_intro2 (522,170); dumprules page 0
cells 80-87, page 1 cells 0-6; sort — 56 of 56]. (The opaque compare of 10.2 does not use tags.)

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
| TR sorted, every peeling pass | TR_MOD | this pass's best `depthA` (pixels with nothing this pass hold 0x7F7FFFFF, so nothing is in front of them) | 0 (cleared at every peel) |
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
    per pixel: depthB, tagB = depthA, tagA; depthA = 0x7F7FFFFF; valid = 0; rendered = 0; stencil = 0     # PeelBuffers
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
| per primitive | det, sgn, cull result; depth plane a, b, c, det, inv, A, B (tile independent); vertex x, y, z |
| per primitive per tile | per edge: s20, sx, sy, E, unit (or the constant answer); depth: regime, S, DX, DY, negE (or the overflow register r0, sa, sb, the ovf 1 word, or a constant word) |
| per pixel (persists across entries) | depthA, tagA, stencil |
| per pixel (per entry / pass) | valid, rendered, depthB, tagB, depthC, refTagC, opTag, resTag, resDepth, resolved-last-pass, everRendered, savedDepth |
| between entries | prevWrittenOut, havePrev, previous tile (4.4) |

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

| # | what | refsw3 does | evidence / status |
|---|---|---|---|
| 1 | edge start past 2^128: 2^127 or +-2^132 - first | +-2^132 - first iff \|dy\| >= 2^127 | faredge 1330 / 1340; page 4 strip, page 1 control strip open |
| 2 | depth constant exactly 2^128 | overflows | zovf: six cells, the console's switch is `a x0 + b y0` reaching 2^128 |
| 3 | negative depth outside its block's top binade | cut19 | depthgaps hunt open; uncommitted patch changes the stored format (9.6) |
| 4 | negative stored sizes below ~2^-122 | as any | perpmean_tiny first version, 335 / 336 |
| 5 | positive depth >= 2^128; the denormal range of the buffer | Saturated; float denormals | not measured (patch: denormals measured) |
| 6 | ovf 1 sign and low bits; kWrap / WrapWord unpinned low bits, m 2..16, field 255; negative finite start onto 2^102 | as 9.5 | zword / nantr leave them open |
| 7 | infinite determinant | depth 0 | not measured |
| 8 | det 0 / perpendicular with an infinite or NaN corner depth | z1's word | detinf cannot tell |
| 9 | the ISP's mean: x 0xAAAAAB or / 3; the TSP's zero rule | x 0xAAAAAB; no zero rule | invisible / not measured |
| 10 | slopes > ~2^71 x the start | float form per pixel | refsw3 limit; the block form in G units is the likely hardware |
| 11 | unranged main path (intermediates < 2^-126, a*inv >= 2^128) | as 6.3 note | not isolated |
| 12 | denormal x, y in the edge unit | exact denormals | not measured |
| 13 | depth sample point with HALF_OFFSET[0] = 0 | centre start, stepped back half a pixel | halfofs not sensitive |
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

## 16. Test index (dreamcast-tests pvr-tests/)

| test | ISP rule(s) it pins |
|---|---|
| covmeas (98 sets) | edge arithmetic, zero zone, row rule, tie rule, last column, winding from det, det 0 positive, row range, degenerate rows, strips / sprites / modvol coverage, HALF_OFFSET coverage |
| hugepos | winding from det, start saturation at 2^127 |
| faredge | the +-2^132 rule |
| raster, precision | coverage, shared edges, small-polygon cull, edge resolution |
| cullval | cull by size: register size only, NaN = +inf, equal culls |
| perpval, perpeq, perpmean_* | FPU_PERP_VAL, the mean's arithmetic and storage |
| zmeas (13 sets), zblock, ztile, zstart | the depth plane, block stepping, 19-bit storage, start cut |
| zexfil | the whole depth buffer read out (calibration, 64 dumps) |
| zsign, zneg, bgspec, bgneg, bgneg2, bgbig | the depth order, negative and huge depths, saturation |
| zspec, zbad, zbadbg, zbadk, zovf, zword, nantr_* | underflow, the overflow regimes, kWrap / WrapWord |
| detinf, huge | infinite determinants, range rules, bad corners |
| bgdepth, bgtie, dumprules p2-7, depthgaps_bglow* | the background depth word |
| depth | DepthMode per list, depth write, PT ignores the mode |
| dumprules, zsource | modvol strictly greater, PT/TR plane order, ZWriteDis per list, PT leaves its ISP depth |
| trtie, sort | the key order, first reference = what is there, ties with the background |
| modvol, volrun, uvrun, optrun, optcull | volume inclusion / exclusion, run breaks, OpInPt |
| ptchunk, ptchunkq, ptchunkm, ptchunkcost, ptchunklag | PT chunk assignment |
| ptlayers, ptruns | PT pass membership, run-only pixels, re-shading only where a later pass draws |
| keepz, accbuf, timemeas | keep Z, end-of-entry, background shading, timing |
| uvspan, spansortcfg, timemeas order | runs and their order |
| perpmean_negstore / _negedge / _neg / _bg, depthgaps_negpp | the negative 16-bit store |

## 17. Lockstep points in refsw3

For per-unit testbenches (polly2-rtl `tb/`), these functions take plain inputs and are header-only: `pvrisp::Winding`,
`pvrisp::EdgeTile::Setup / Inside`, `pvrisp::RowRange`, `pvrisp::DepthTileT<DepthHW>::Setup / At`,
`pvrisp::StoredDepth::{key, FromFp, Store, Saturated}`, `pvrfp::{Mul, Add, Recip, Perpendicular}` (include
`refsw3/refcore/pvr_isp_edge.h`, `pvr_isp_depth.h`; no other dependency; `widths.cpp` in agents/spec-isp is an
example). `KeyAbove`, `PixelFlush_isp`, `CulledBySize`, `CulledByFacing` are file-static in `refsw_tile.cpp`;
whole-frame comparisons go through refsw3-offline, whose `log <file> [x,y ...]` command writes the per-tile trace
(`TILE`, `OBJECT`, `TRIA`/`TRIC`, `ISP`, `ZFAIL*`, `RENDERED`, `STENCIL`, `CULLED`, `PASS`, `SPAN`, `TSP`, ...).
