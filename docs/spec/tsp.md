# TSP specification: from a visible tag to the framebuffer word

polly2-rtl, unit spec "TSP" (texture and shading processor, the tile colour buffers and the write-out).
Written 2026-11-20 from refsw3 (nulldc3 branch `skmp/refsw3`, commit 2d08a440, `refsw3/refcore`) and the console
tests of dreamcast-tests (commit f7cb4e5); checked against refsw3 `708fb8cd` the same day: `pvr_tsp_plane.h` changed
only by taking its 1/3 from `pvrfp::OneThird()`, the constant the ISP's depth mean shares (4.4, 20), so no TSP rule
moved. Sections 4.4, 20 and 22 item 2 now also say how the ISP's depth adds treat a zero. refsw3 is the functional truth: it is the console, bit for bit, on every
regression test and on all 786 polly2-data dumps with a console frame. Everything below is what refsw3 does; each
rule names the console test that pins it. Where refsw3 does something no test has measured, it is marked **GAP**.

Files this spec transcribes (all under `nulldc3/refsw3/refcore/`):

| file | what of the TSP is in it |
|---|---|
| `pvr_softfp.h` | the number type `Fp`, `Mul`, `Add`, `Recip`, `cut`, `FromSingle`, `Perpendicular` |
| `pvr_tsp_plane.h` | plane setup (`PlaneT::Setup`), plane value (`Value`), the divider (`RecipTable`, `DenominatorSeen`, `Divide`), `ColorRounded`, the mipmap level (`MipSelect`) |
| `refsw_tile.h` | `PlaneStepper3` (plane at a pixel, the run start), `IPs3` (which planes a primitive has, two volumes, intensity shadow) |
| `refsw_tile.cpp` | spans (`SpanGen`, `SpanSort`, `RenderParamTags`), the parameter fetch (`GetFpuEntry`, `decode_pvr_vertex`), texture address and fetch (`TexOffsetGen`, `TextureFetch`, `VQIndexAddress`, `DecodeTextel`), `TexCoordFixed`, `TextureFilter`, `ColorCombiner`, `BumpMapper`, `InterpolateBase/Offs`, `FogUnit`, `LookupFogTable`, `BlendingUnit`, `PixelFlush_tsp`, `offsKept`, `tspAlphaStuck`, the two tile buffers |
| `refsw_lists.cpp` | per region array entry: pass order, keep Z, the write-out (`put`: pack, dither, clip, strip buffer), the scaler stream |
| `TexUtils.h` | texel expansion macros, `YUV422`, `twop` (twiddle) |
| `gentable.h`, `gentable.py` | **no numeric tables**: only the dispatch of C++ template instances (which TSP/TCW bits select which code path; section 2.4). The numeric tables are listed in section 20. |
| `nulldc3/libswirl/rend/TexCache.cpp` | `twiddle_slow` / `detwiddle` (the twiddle order, section 9.2) |

Other documents this one leans on: `dreamcast-tests/README.md` (one section per test, cited by test name),
`dreamcast-tests/pvr-tests/PIPELINE_SHAPE.md` (the measured pipeline shape and timing, tags [M]/[I]/[G]),
`dreamcast-tests/pvr-tests/timemeas/REPORT.md` (the timing tables), `dreamcast-tests/TODO.md` (open items). The ISP
(edges, depth, the peeling passes that decide which tag is visible) is the ISP spec's; this document starts where
the ISP hands a tag buffer to the TSP and repeats only what the TSP needs of it.


## 0. Conventions

**Numbers.** `Fp` = (sign, integer mantissa `m`, exponent `e` of the mantissa's last bit): value = ±m 2^e. A zero
keeps a sign. `top(x)` = the exponent as `frexp` gives it: |x| in [2^(top-1), 2^top). `bad` = an infinity (from an
input field 255 or an overflow).

| term | meaning |
|---|---|
| `cutN(x)` | keep the N most significant bits of the mantissa, **toward zero** (truncate the magnitude), sign kept. `Fp::cut` |
| `floor(x)` | toward minus infinity (two's complement truncation) |
| `mulN(a, b)` | exact product, then `cutN` (`Mul(a, b, N)`; operands first cut to 32 bits, a no-op here) |
| `addN,R(a, b)` | align to the larger; if top(larger) - top(smaller) >= R the smaller is **dropped**; else the exact sum; then `cutN` (`Add(a, b, N, R)`). An exact cancellation is +0. N = 62 or R = 200/400 mean "exact" in refsw3 |
| `recipN(x)` | 1/x, truncated to N significant bits (`Recip`) |
| [M test] | measured on a console by that dreamcast-tests test; [I] inferred; [G] guess (PIPELINE_SHAPE.md tags) |
| **GAP** | refsw3 does something here that no console test has pinned |

**Colours.** A colour is four bytes, index 0..3 = **B, G, R, A** (refsw3 `Color.bgra[]`). A vertex colour word in
parameter memory is ARGB8888 (A bits 31..24, R 23..16, G 15..8, B 7..0).

**Coordinates.** Screen pixels; a tile is 32x32, its first pixel (left, top) = (tilex*32, tiley*32). In the plane
arithmetic positions are in **half pixels** (`FromHalves(k)` = k/2).

**Field names.** Words and bits as refsw3's `core_structs.h` / nulldc3 `pvr_regs.h`:

ISP/TSP instruction word (parameter word 0): DepthMode 31..29, CullMode 28..27, ZWriteDis 26, **Texture 25, Offset
24, Gouraud 23, UV_16b 22**, CacheBypass 21, **DCalcCtrl 20**. (The TA writes Offset only together with Texture:
refta `h.offs = tex && offsBit`.)

TSP instruction word (parameter word 1; word 3 for volume 2): SrcInstr 31..29, DstInstr 28..26, SrcSelect 25,
DstSelect 24, FogCtrl 23..22, ColorClamp 21, UseAlpha 20, IgnoreTexA 19, FlipU 18, FlipV 17, ClampU 16, ClampV 15,
FilterMode 14..13, SupSample 12, MipMapD 11..8, ShadInstr 7..6, TexU 5..3, TexV 2..0.
Encodings: FilterMode 0 point, 1 bilinear, 2 trilinear pass A, 3 trilinear pass B. ShadInstr 0 decal, 1 modulate,
2 decal alpha, 3 modulate alpha. FogCtrl 00 table ("look-up mode 1"), 01 per vertex, 10 none, 11 table mode 2.
Src/DstInstr 0 ZERO, 1 ONE, 2 OTHER_COLOR, 3 INV_OTHER_COLOR, 4 SRC_ALPHA, 5 INV_SRC_ALPHA, 6 DST_ALPHA,
7 INV_DST_ALPHA. Texture size U = 8 << TexU, V = 8 << TexV (8 .. 1024).

Texture control word TCW (parameter word 2; word 4 for volume 2): MipMapped 31, VQ_Comp 30, PixelFmt 29..27,
ScanOrder 26, StrideSel 25, TexAddr 20..0 (in 8-byte units); for palette formats PalSelect = bits 26..21.
PixelFmt 0 ARGB1555, 1 RGB565, 2 ARGB4444, 3 YUV422, 4 bump map, 5 palette 4 bpp, 6 palette 8 bpp, 7 reserved.

Tag (the ISP's tag buffer word and ISP_BACKGND_T, 0x08C): tag_offset 2..0 (triangle index in a strip),
param_offs_in_words 23..3, skip 26..24, shadow 27, cache_bypass 28. The ISP's sort key uses bits 23..0
(`PARAMETER_TAG_SORT_MASK`).

Registers the TSP side reads (address, bits used):

| register | addr | used for |
|---|---|---|
| SPAN_SORT_CFG | 0x030 | bit 0 span sort on, bit 8 offset sort (section 3.2); bit 16 TSP cache bypass: no functional effect seen |
| FB_R_CTRL | 0x044 | bit 22 strip buffer enable, bits 21..16 strip size (section 17.2) |
| FB_W_CTRL | 0x048 | packmode 2..0, dither 3, kval 15..8, alpha_threshold 23..16 |
| FB_W_LINESTRIDE | 0x04C | stride 8..0, in 8-byte units |
| FB_W_SOF1 / SOF2 | 0x060 / 0x064 | framebuffer start (SOF1 bit 24: render to texture, 64-bit view) |
| FB_X_CLIP / FB_Y_CLIP | 0x068 / 0x06C | x min 10..0, max 26..16; y min 9..0, max 25..16; inclusive |
| FPU_SHAD_SCALE | 0x074 | scale_factor 7..0, intensity_shadow 8 |
| HALF_OFFSET | 0x080 | bit 1 TSP pixel half offset, bit 2 texel half offset (bit 0 is the ISP's) |
| FPU_PERP_VAL | 0x084 | abs(det) <= this: flat planes (section 4.4); sign ignored, NaN/±inf = +inf |
| ISP_BACKGND_T | 0x08C | the background polygon's tag |
| FOG_COL_RAM, FOG_COL_VERT | 0x0B0, 0x0B4 | fog colours (RGB used) |
| FOG_DENSITY | 0x0B8 | bits 15..8 mantissa (1.7), bits 7..0 signed exponent |
| FOG_CLAMP_MAX, FOG_CLAMP_MIN | 0x0BC, 0x0C0 | colour clamp, all four channels |
| TEXT_CONTROL | 0x0E4 | stride 4..0 (x32 texels), bank 12..8, index swap 16, byte swap 17 |
| SCALER_CTL | 0x0F4 | vscalefactor 15..0, hscale 16, interlace 17, fieldselect 18 |
| PAL_RAM_CTRL | 0x108 | bits 1..0 palette entry format: 0 1555, 1 565, 2 4444, 3 8888 |
| Y_COEFF | 0x118 | c1 bits 15..8, c0 bits 7..0 (vertical filter) |
| PT_ALPHA_REF | 0x11C | alpha test reference |
| FOG_TABLE | 0x200..0x3FC | 128 words, bits 15..8 and 7..0 used |
| PALETTE_RAM | 0x1000..0x1FFC | 1024 words |
| PARAM_BASE | 0x020 | parameter fetch base |


## 1. Overview

```
 ISP tag buffer (per pass)  --SpanGen-->  spans (runs) in raster order  --SpanSort (window 96)-->  shading order
        |                                                                           |
        | tag -> GetFpuEntry: fetch ISP/TSP/TCW words + 3 vertices; setup of the planes (sec. 4), mip K (sec. 8.1)
        v                                                                           v
 per pixel (PixelFlush_tsp):
   W = 1/w plane at the pixel (sec. 5) ---------------------------------+---------------------------+
   base ARGB = Col planes / W, rounded (sec. 6, 7)                       |                           |
   U, V = U/w, V/w planes / W (sec. 6) -> coordinate (sec. 9.1)          | mip level, k (sec. 8)     |
        -> address (9.2-9.6) -> texel fetch -> decode (10) -> filter (11) -> [bump: 12]              |
   offset ARGB = Ofs planes / W (or the kept offset colour, sec. 14)                                 |
   shade (13: decal / modulate / decal alpha / modulate alpha, + offset)                             |
   colour clamp, fog (15, with W) -> trilinear fade (16) -> [SupSample: 4 points, averaged, 18]      |
   stuck alpha (19.3) -> alpha test (19.1) -> blend with the tile buffers (19.2) -> tile buffer       |
 after the entry: write-out of the tile buffer: scaler, pack, dither, clip, strip buffer (sec. 17)
```

Per region array entry (`RenderCORE`), the TSP shades, in this order (each a call of `RenderParamTags<pass>`):

1. **Opaque pass** (`RM_OPAQUE`), always, also with an empty opaque list: the tag buffer was cleared to the
   background tag (unless keep Z), so the background polygon is shaded where nothing else is [M timemeas: the
   background is shaded in every entry, 1035 clocks, also an entry that is not written out].
2. **Punch-through passes** (`RM_PUNCHTHROUGH_PASS0` for every pass), per chunk, until no pixel fails the alpha
   test; then, if the opaque modifier list is not empty, the **punch-through volume pass** (`RM_PUNCHTHROUGH_MV`).
3. **Translucent**: pre-sorted tiles shade **after every triangle** (`RM_TRANSLUCENT_PRESORT`, list order);
   per-pixel-sorted tiles shade once per peeled layer (`RM_TRANSLUCENT_AUTOSORT`), back to front.
4. Write-out of the entry's tile buffer (unless not written out), then the buffers change places (section 17.1).

State that lives across pixels (and makes the order observable, section 3.4): the two tile colour buffers, the
kept offset colour `offsKept` (across tiles and renders), `tspAlphaStuck` (per region array entry), the
scaler's stream state (per frame), the strip counter (per frame).


## 2. Input: tags, parameter fetch, vertex decode

### 2.1 What the ISP hands over

Per pixel of the tile, per pass: the tag (`tagBuffer[A]`), a valid bit (`tagStatus.valid`: written in this pass),
a resolved bit (`tagStatus.rendered`, punch-through), the summarized modifier-volume bit (`stencil bit 0`,
"inside"). Which pixels are valid in which pass, and which tag, is the ISP spec's. The TSP does not use the ISP's
depth: it evaluates 1/w itself from its own plane at its own sample point [M halfofs: the perspective cells follow
HALF_OFFSET's TSP bit, not the ISP bit; tspw: the fog reads the TSP's 1/w].

### 2.2 Parameter fetch (`GetFpuEntry`, `decode_pvr_vertices`)

From the tag: `addr = PARAM_BASE + param_offs_in_words * 4`, read through the **32-bit view** of video memory
(`vri` = `pvr_map32`: the two 4 MB banks interleaved every 32 bits). `two_volumes = shadow && !FPU_SHAD_SCALE.intensity_shadow`.

    word 0: ISP/TSP word;  word 1: TSP[0];  word 2: TCW[0];  if two_volumes: word 3: TSP[1], word 4: TCW[1]
    then vertices, each (3 + skip * (1 + two_volumes)) words long; skip tag_offset of them, read 3

(The ISP's strip walker uses `PARAM_BASE & 0xF00000` as base; the TSP's fetch the full PARAM_BASE. They agree for
every PARAM_BASE games use, 1 MB aligned. **GAP**: a PARAM_BASE with bits below 20 set.)

Vertex layout (`decode_pvr_vertex`), the presence of each field taken from the ISP/TSP word's bits, not from skip:

    x, y, z (1/w)                         3 words, IEEE single bits
    if Texture: UV_16b ? (u = word & 0xFFFF0000, v = word << 16) : (u, v: 2 words)
    base colour (ARGB8888)                1 word
    if Offset: offset colour (ARGB8888)   1 word
    if two_volumes: [u1, v1 as above if Texture], base colour 1, [offset colour 1 if Offset]

**Odd strip triangles**: if `tag_offset & 1`, vertices 0 and 1 are swapped (the same order the ISP rasterizes
them in); the setup arithmetic depends on the order. A quad (sprite) gives the TSP its first three vertices. The
"third vertex" (v3) below is vertex index 2 after the swap.

The background polygon is the tag ISP_BACKGND_T, fetched the same way (3 vertices, its skip, shadow, tag_offset).

refsw3 caches 32 set-up primitives per region array entry (`fpuCache`, indexed by `param_offs & 31`, full tag
compared; cleared at every entry). This is functionally transparent (setup is a pure function of the parameters).
The console keeps about 12-16 primitives set up [M timemeas ahead, spansortcfg]; that is timing only.

### 2.3 Planes a primitive has (`IPs3::Setup`) [M planes, uvmeas]

Every one of these is a perspective plane (attribute / w, divided per pixel by the 1/w plane):

| plane | corner values | when |
|---|---|---|
| `invW` | z (1/w) of v1, v2, v3 | always |
| `U[0]`, `V[0]` | u, v | always set up (used when textured) |
| `Col[0][c]`, c = B, G, R, A | Gouraud ? vertex colours : v3's colour at all three corners | always |
| `Ofs[0][c]` | the same for the offset colour | always (read only when Offset) |
| `U[1]`, `V[1]`, `Col[1]`, `Ofs[1]` | volume-2 values | two volumes |
| `Col[1]`, `Ofs[1]` | intensity-scaled colours (section 4.6) | shadow bit and intensity mode |

A flat-shaded polygon has its colour as a plane of three equal corners, still divided by 1/w: exact at ordinary
depths, not at the limits [M planes: pages 1, 3, 5; detinf's black flat probes come out grey only that way].
Colours enter the planes as **c x 2^-8** (`SingleBits(c, -8)`: c = 0 is a zero) [M cmeas wext: 2,333,331 of
2,340,000 with 2^-8 against 1,688,587 with 2^-7].

Per pixel the TSP uses volume 1 (`Col[1]`, `Ofs[1]`) when `InVolume = inside && tag.shadow` (forced false in the
punch-through passes 0/N), and the second TSP/TCW/U/V only when also `!intensity_shadow`
(`two_voume_index = InVolume && !intensity`).

### 2.4 The code paths (`gentable.h`)

`gentable.h` (generated by `gentable.py`) holds five tables of function pointers to C++ template instances. They are
the decode of which word bits choose which datapath, nothing else:

| table | indexed by |
|---|---|
| `PixelFlush_tsp_table[2][2][2][2][4][2]` | TSP.UseAlpha, ISP.Texture, ISP.Offset, TSP.ColorClamp, TSP.FogCtrl, FPU_SHAD_SCALE.intensity |
| `TextureFilter_table[2][2][2][2][2][4]` | IgnoreTexA, ClampU, ClampV, FlipU, FlipV, FilterMode (forced 0 when FilterMode >= 2 and !MipMapped, section 11.1) |
| `ColorCombiner_table[2][2][4]` | ISP.Texture, ISP.Offset, ShadInstr |
| `BlendingUnit_table[2][2][8][8][2]` | SrcSelect, DstSelect, SrcInstr, DstInstr, alpha test |
| `TextureFetch_table[2][2][2][2][8]` | VQ_Comp && !raster, MipMapped && !raster, ScanOrder, StrideSel, PixelFmt |


## 3. Spans and the shading order

### 3.1 Span generation (`SpanGen<pass>`) [M uvspan, uvrun, volrun, optrun, ptlayers]

A span (run) is a maximal stretch of pixels on one line of the tile, left to right, in raster order of their first
pixel, with: the same tag, all valid in this pass, and the same "volume state" `vol`:

    valid(pixel) = tagStatus.valid                                   (every pass but PT_MV)
                 = inside && (tagStatus.rendered || OpInPt)          (PT_MV)
    vol(pixel)   = false   in TR_PRESORT, PT_PASS0/N, and OPAQUE when OpInPt
                 = inside  otherwise (OPAQUE without OpInPt, TR_AUTOSORT, PT_MV)
    a span ends where valid is false, the tag changes, or vol changes; never at a fixed column (up to 32 pixels)

`OpInPt` = the entry's punch-through list holds a primitive (a strip entry with a nonzero mask, a triangle or quad
array), drawn or not [M optcull: a culled triangle is enough; polly2-data ff2_fight].

What each rule rests on:

- A run starts at the first **visible** pixel of the triangle on the line in the pass (opaque: a nearer polygon
  ends it; translucent pre-sorted: each polygon shaded whole in its own pass) [M uvspan: 411,287 and 407,063 of
  as many readings].
- A run ends at a modifier volume's edge **whatever the polygon's shadow bit**, also with equal volume parameters
  and with cheap shadow, in opaque (no punch-through primitive in the tile), sorted translucent and the PT volume
  pass; **not** in pre-sorted translucent [M uvrun kinds 1-11: 195,000 readings each; volrun: edges made by the
  depth test too].
- In a tile with a punch-through primitive opaque runs do not end at volume edges, and opaque pixels inside a volume
  are shaded again in the PT volume pass [M optrun kinds 9, 10; polly2-data jgr_car, jgr_tree_shadows*].
- Punch-through pixels in front of an opaque polygon do not end its runs [M optrun kinds 1-8].
- A punch-through pass takes in the pixels resolved in the pass before it (they are valid again for this one
  pass, as run members only, section 19.4) [M ptlayers 18 of 18 pages].

### 3.2 Span sort (`SpanSort`) [M timemeas order, spansortcfg]

    if !(SPAN_SORT_CFG & 1): order = raster order of the spans
    key(span) = (SPAN_SORT_CFG & 0x100) ? tag & ~7 : tag        // offset sort: a strip's triangles are one primitive
    window = up to 96 spans, oldest first, filled in raster order whenever there is room
    while window not empty:
        prim = key(window[0])
        repeat: take the OLDEST span in the window whose key == prim; shade it; remove it; refill the window
                until no span of prim is in the window
    each RenderParamTags call (each tile and each pass) on its own

[M timemeas order: 23 scenes, about 17,000 runs; windows of 95 or 97 put 129 to 276 runs out of order, 96 none
but glitch pixels and "early drains"]. A run takes one place whatever its length. A drained place is reused at once
(not a circular FIFO). Offset sort compares the parameter offset only [M spansortcfg TM_SORTOFF scenes 39, 40].

Not modelled (refsw3 neither): the **early drains** (some whole drains are shaded before 2 to 9 drains in front
of them, always the same ones) [M, not understood]; with bit 0 off the console's order is near raster order with
timing-dependent early runs [M spansortcfg]. SPAN_SORT_CFG 0x100 and 0x10001 hang the core [M]. Every dump and
test uses 0x101.

**No picture depends on the sort except through `offsKept` and `tspAlphaStuck`** [M spansortcfg: 218 pages of 15
run-sensitive tests and timemeas identical with 0x000, 0x001, 0x101; runs and their first pixels are made before
the sorter].

### 3.3 Pixel order within a span

Left to right, one pixel after the other (`PixelFlush_tsp` per pixel). The plane value of pixel n of the span is
the span start's value plus n steps (section 5).

### 3.4 Where the order is observable

| what | depends on | modelled |
|---|---|---|
| `offsKept` (section 14) | the last textured primitive with the offset bit shaded, in TSP order, across tiles/renders | yes: span sort order |
| `tspAlphaStuck` (section 19.3) | a setter shaded before the polygon, in the tile | yes |
| palette and fog table entries | read at the clock the pixel is shaded: timemeas `TM_ORDER` reads the shading order from a palette entry the CPU rewrites during the render | refsw3 reads registers at shading time; the clock is the RTL's |
| a VQ index (or texel) read that lands in the framebuffer of the render in progress | whether that tile has been written out yet [M texctl_bank earlier version: 376-864 pixels differ] | **GAP** (write-out timing) |
| secondary buffer read during the write-out | the write-out's progress [M accbuf, blendpos: different every console run] | no (section 17.1) |
| punch-through chunk carry of resolved pixels | where the ISP is against the TSP [M ptchunkcarry_races, ptchunkrun_races] | no (refsw3 does not carry) |
| SPAN_SORT_CFG bit 0 off | the pipeline's clock | no (raster order) |


## 4. Plane setup (`PlaneT<PlaneHW>::Setup`) [M uvmeas 31 sets 23,640,053 readings; wmeas 2,320,996; cmeas 3 sets]

Per primitive (per tile in refsw3, per sorter drain on the console: same numbers). Inputs: x, y, z of the three
corners and, for an attribute plane, the attribute a at each corner, all as IEEE single bits. Outputs per plane:
`A, B, C` (16-bit coefficients, value = A x + B y + C in screen pixels), `A0, B0, C0` (the same before the 16-bit
cut, 24 bits: the mipmap's input), `Sa, Sb, Sc, Sdet` (the undivided sums: the mipmap's input).

### 4.1 The setup's number format and its limits (`range = 1`) [M uvmeas wexp, whuge, wtiny, wspec, wneg, wzero; cmeas cwext, cwsum]

Sign, 8-bit exponent field, 24-bit mantissa (hidden bit included). Field 0 is **zero** whatever the mantissa (a
denormal is zero, sign kept); field 255 is **infinity** (a NaN is one, sign kept).

| op | rule (all cuts toward zero) |
|---|---|
| load | `FromSingle(bits, ranged=1)`: field 0 -> ±0, 255 -> ±inf, else mant = 1.frac (24 bits), exp = field - 150 |
| product `mul` | 24x24 exact, cut to 24 bits. 0 x anything (also x inf) = 0; inf x non-zero = inf. Result >= 2^128: inf; < 2^-126: zero. Sign = xor of the signs in every case |
| sum `add` | align, drop an operand whose top is **25 or more** below the other's (`reach 25`), exact sum, cut to 24 bits. inf + x = inf; inf + (-inf) = +0. Result >= 2^128: inf (sign of the sum); < 2^-126: **+0** |
| last addition of a three-term sum `(t1 + t2) + t3` | as `add`, but if one operand is zero and the other has top - 1 < -125 (i.e. 2^-126 <= abs(x) < 2^-125), the zero counts as **2^-127 with its own sign** (`zeroReach = 2`). In `t1 + t2` a zero is a zero |
| `Recip(det, 24)` | 1/det truncated to 24 bits, sign of det |

Pins: reach 25 [M uvmeas reach1: 95,453 readings, 25 all, 24 misses 554, 26 misses 785; polly2-data gundam_ingame,
daytona_*, sa2_ingame2]; zero-as-2^-127 in the last addition [M cmeas cwsum1: 2,340,000 of 2,340,000 against
2,335,162 with the rule in both additions, 2,318,225 without; uvmeas wtiny1 5 cells, cwext1 21]. **GAP**: whether
the limit is 2^-125 or 2^-124 (zeroReach 2 or 3), probably not observable.

### 4.2 The sums (indices 0, 1, 2 = v1, v2, v3 after the odd-strip swap; j = k+1, l = k+2 mod 3)

    X[k], Y[k], Z[k], AT[k] = load(x[k]), load(y[k]), load(z[k]), load(attr[k])
    e[k]  = sub( mul(X[j], Y[l]), mul(X[l], Y[j]) )         // e0 = x1 y2 - x2 y1 (0-based), each product cut 24
    ta[k] = mul(Z[k], sub(Y[j], Y[l]))
    tb[k] = mul(Z[k], sub(X[l], X[j]))
    tc[k] = mul(Z[k], e[k])
    attribute plane only:  ta[k] = mul(AT[k], ta[k]);  tb[k] = mul(AT[k], tb[k]);  tc[k] = mul(AT[k], tc[k])
    Sa   = (ta0 + ta1) + ta2          // sum3: the second + is the "last addition"
    Sb   = (tb0 + tb1) + tb2
    Sc   = attribute ? (tc0 + tc1) + tc2  :  (tc0 + tc2) + tc1
    Sdet = (e0 + e1) + e2

Pins: coefficients are the setup's 24-bit truncating arithmetic [M uvmeas, wmeas]; an attribute plane multiplies
each product of the 1/w plane by the corner's attribute and cuts again, `a_i * cut(w_i * d)` [M uvmeas wflat: 600
of 600 against 591 exact and 581 for a 24-bit `(a_i w_i) d`]; the attribute constant summed (t1 + t2) + t3 and the
1/w constant (t1 + t3) + t2 [M uvmeas: 2400 of 2400 against 2377; fog of flat quads 1600 of 1600 against 1597]. The
sum orders of Sa/Sb are (t0 + t1) + t2 for both [M; the alternatives sumA/sumW 1, 2 are experiments, default 0].

### 4.3 Division by the determinant (ordinary case)

    det = Sdet; if Perpendicular(det): det = 0      (section 4.4)
    if det is zero (and not inf): flat planes, section 4.4
    inv = det is inf ? zero(sign of det) : recip24(det);  if inv < 2^-126: inv = zero(sign of inv)
    A0 = mul(Sa, inv);  B0 = mul(Sb, inv);  C0 = mul(Sc, inv)        // 24 bits, with the range rules
    A = cut16(A0);  B = cut16(B0);  C = cut16(C0)                    // a zero keeps its sign

[M uvmeas: coefficients are 16-bit floats, a flat U with 24 significant bits reads as its 16-bit truncation at
every size 1 .. 2^22; a zero keeps its sign: a slope that cancels exactly, over a negative determinant, is -0 and
floors one grid unit low: wmeas's 60 % of flat triangles one fog level low]. The reciprocal's range: a determinant
above 2^126 gives coefficients that are zeros with the sign of sum x det [M hugepos triangle c 16 of 16 pages,
triangle b exact].

### 4.4 Determinant zero, and FPU_PERP_VAL [M slivers_tsp, slivers_detzero, slivers_dzzero, slivers_dzspec, slivers_perp, perpmean_fogw, perpmean_uv, perpmean_ovf, perpval, perpeq, detinf]

`Perpendicular(det)` (refsw3 `pvr_softfp.h`): `perpVal = FromBits(FPU_PERP_VAL & 0x7fffffff)` per render (field
255, i.e. ±inf or any NaN, = +infinity). A finite non-zero det is perpendicular if `perpVal` is inf, or non-zero
and |det| <= |perpVal| (**equal counts** [M perpeq 1800 of 1800]); an infinite det only if perpVal is infinite.

Then every plane of the primitive is flat:

    A = B = +0
    third = OneThird() = 0xAAAAAB x 2^-25     // the single nearest 1/3, a hair above (24 bits); pvr_softfp.h
    first = Z0 + Z1 (an ordinary add), except the zero rule below
    mean  = mul( lastadd(first, Z2), third )  // (z1 + z2) + z3, the last addition with its zero-as-2^-127 rule
    1/w plane:       C = cut16(mean)
    attribute plane: C = cut16( mul(AT[2], mean) )      // the third corner's attribute times the mean
    A0 = A, B0 = B, C0 = C

Zero rule of the first addition: when exactly one of z0, z1 has exponent field 0 (a zero, mantissa bits m), and the
other, p, has top - 1 == -126 (2^-126 <= |p| < 2^-125) **and the opposite sign**: the zero is taken as
(1 + m 2^-23) 2^-127 with its sign; if p + that is below 2^-126 (or 0) the sum is +0, otherwise the sum is p
unchanged. Otherwise a zero is nothing. [M slivers_dzzero 9,600 of 9,600 (831 exactly on the boundary keep the
depth; the alternatives 6,711 .. 7,564)]. **GAP**: the same question in the last addition (beyond the planes' rule).

The ISP's depth mean (isp §9.4b) uses the same `OneThird()` and the same sum order, but its additions are the depth
setup's (isp §6.3): in **every** addition a zero added to a number of 2^-126 .. 1.5 * 2^-126 of the other sign gives
+0 and to any other number that number exactly, and every zero sum is +0. Its zero has no fraction (field 0 is a
zero at `FromSingle`), so its threshold is 1.5 * 2^-126 where this rule's is (1.5 + m 2^-24) 2^-126, and it never
adds a zero as ±2^-127 as the planes' last addition does (4.1) [depthgaps_zadd: 109 of 109 regions with the ISP's
rule, 76 with the planes' last-addition rule; depthgaps_field1]. The two units do not share the rule.

Pins: the mean, not the third corner's depth [M slivers_tsp 3600 cells: 42 differ with z3; slivers_detzero 9,600
of 9,600, against 8,143 with 0xAAAAAA, 9,474 with 25-bit sums, 9,413 / 9,379 other orders, 9,373 exact;
perpmean_uv 8,192 of 8,192 to the 16th bit; perpmean_fogw 16,384]; the colour is the third corner's [M covmeas
degen --vcol]. An overflowing sum makes the 1/w plane infinite, read by the evaluator as 2^-128, and a colour comes
out white [M perpmean_ovf 240 of 240; detinf].

### 4.5 Colour planes

Corner values `SingleBits(c, -8)`: the 8-bit channel c as the IEEE single c x 2^-8 (exact; c = 0 a zero). Flat
shading: v3's value at all three corners. The per-channel `fallback` = v3's channel as sent (only the bump light
uses it, section 14; for the colour quotient it is unreachable with the ranged arithmetic: `Divide` never returns
an infinity).

### 4.6 Intensity shadow (FPU_SHAD_SCALE bit 8) [M modvol, dumprules page 0 cells 20-23; polly2-data sc_ingame2, jgr_tree_shadows2]

For a polygon with the shadow bit, volume-1 planes `Col[1]`, `Ofs[1]` are set up from the **vertex** colours scaled
before interpolation: `c' = (c * scale_factor) >> 8` for B, G, R (not A), per vertex; Gouraud from the three scaled
vertices, flat from scaled v3. Fallbacks = scaled v3. TSP/TCW/U/V stay volume 0's. 0x80 halves exactly, 0xFF
darkens by one level [M modvol: 0x4080c0 -> 0x204060 at 0x80; 0x3f7fbf at 0xff]. Scaling the interpolated colour
instead is one level off [polly2-data sc_ingame, sc_ingame2]. The scaled colour is clamped only after interpolation
(a colour far above 255 stays white at 0x80 and 0xff) [M modvol pages 0-2].


## 5. Plane value at a pixel (`PlaneT::Value`, `PlaneStepper3::Val`) [M uvmeas, uvspan, wmeas, cmeas: every reading]

### 5.1 How the evaluator reads a coefficient

The evaluator has no zero and no infinity: it reads the exponent field as a **signed 8-bit number**:

    seen(x) = x is inf  ? 2^-128 with x's sign        (field 255 = +128 wraps to -128)
            : x is zero ? 2^-127 with x's sign        (field 0)
            : x

[M uvmeas wexp, whuge: with every product of the setup overflowing, both constants are -2^-128 and both slopes
-2^-127 on 4875 of 4875 readings]. RTL equivalent [I]: keep a coefficient as (sign, field8, frac15) and read the
exponent as signed8(field - 127) with the hidden one always set.

### 5.2 The tile's grid

Per primitive per tile:

    ex = top(tileLeft + 16), ey = top(tileTop + 16)          // tileLeft/Top: the tile's first pixel; 16 has top 5
    e  = max( top(seen(C)), top(seen(A)) + ex - 1, top(seen(B)) + ey - 1 )
    unit = e - 22                                            // the grid: 22 bits under E

[M uvspan: the grid is 22 bits under E, the exponent a product **can** have in this tile, X and Y any coordinate of
the tile's far half (tile + 16 .. tile + 32); takes every uvmeas, wmeas and cmeas set to 100 %].

### 5.3 The run start and the steps

The sample point: pixel (x, y) of the tile plus half a pixel on both axes when HALF_OFFSET bit 1 is set
[M halfofs, halfofs2: all 8 values]. In half pixels: `x0h = 2 (tileLeft + spanStart) + half`, `yh = 2 (tileTop + y)
+ half`; n = x - spanStart (whole pixels from the span's first pixel).

    F(v) = floor(v / 2^unit)  as an integer; F of a NEGATIVE zero is -1, of +0 is 0
    ax = A' x (x0h / 2) exactly (sign of A' if the product is 0, i.e. x0h = 0);  by = B' (yh / 2) likewise
    k  = F(C') + F(ax) + F(by) + n F(A')                     // A', B', C' = seen(A), seen(B), seen(C)

Each term is cut to the grid **on its own** (a truncating multiplier, then an integer adder; the steps accumulate
F(A') per pixel) [M tspprobe on 29 uvmeas sets, 23,640,053 readings: this 0 wrong; F(C + B y) + F(A x) 3,445;
F(C + A x) + F(B y) 32,716; one rounding 512,221; tile-local coordinates 15,801 .. 1,277,606]. A run is not cut at
fixed columns [M split=16: 63,619 wrong]. Screen coordinates, not tile-local.

Integer width, in grid units (x < tileLeft + 32 < 2^(ex+1), so abs(A' x) < 2^(top(A') + ex + 1) <= 2^(e + 2)):
abs(F(C')) <= 2^22, abs(F(A' x)) < 2^24, abs(F(B' y)) < 2^24, abs(n F(A')) <= 31 x 2^18 < 2^23 (ex, ey >= 5), so
abs(k) < 11 x 2^22 < 2^26: a **27-bit two's complement** accumulator (the SupSample half steps of section 5.4 stay
within the same bound; 200,000 random planes on a 2048x1024 screen reach 2^23.8: agents/spec-tsp/kbound.cpp).

### 5.4 SupSample points (TSP bit 12) [M supsample, supsample2, ssvol, ssrare, sshalf]

For point (hx, hy) in {0,1}^2 (half a pixel right, half a line down), same grid `unit`:

    k = F(C') + F(ax) + F(by) + (2n + hx) F(A'/2)                 // half steps along the run, the centre's too
    if hy: replace F(C') by F(C' + B'/2)                          // C and B/2 added EXACTLY, then floored

[M supsample: whole steps plus a half step miss 798, the plane at the points themselves 870 / 21,091, lines in half
steps 2,119; ssrare: F(C) + F(B/2) is one unit low on 24 of 6.1 million pixels, exactly where the fractions
carry; sshalf: the console has F(C + B/2) on all 728 pixels where the two differ].

### 5.5 Back to a float: the value format [M uvmeas wfixed=/valueFixed=, wtiny, wzero1]

    k == 0:  +0 (an exact zero; the divider gives 0 for it)
    k == -1: -2^-143          // every bit set, no leading bit to find: smallest exponent, mantissa -1 in the last place
    else:    sign = k < 0; m = |k|; keep the 16 bits from the leading one, the rest dropped TOWARD MINUS INFINITY
             (a negative value with lost bits: m += 1; may carry to 2^16, renormalize);  exp = unit + dropped
             if the leading bit's exponent < -128: raise the exponent to -128 keeping the mantissa (not value-preserving)

The value is normalized before it is cut, whatever the size of k [M: dropping a fixed number n of low bits instead:
30,852 wrong at n = 1 .. 13,321,784 at n = 8]. So: a leading-one count and shift over the whole 27-bit integer, then
16 bits. The -1 case [M wzero1: 4 readings; texfar_m1]. Exponent clamp at -128 [M wtiny: 37 readings].

Value format for the RTL: sign, 16-bit mantissa (leading one at bit 15), exponent >= -128 (as the mantissa's
leading bit), plus the zero flag and the -1-unit special. refsw3 has **no upper clamp**: with coefficients < 2^128
and screen coordinates below 2^12 the value stays below about 2^142, so carry at least a 9-bit signed exponent.


## 6. The divider (`RecipTable`, `DenominatorSeen`, `Divide`) [M uvmeas recipscan, reciprow, reciprown: 1,560,000 of 1,560,000; wneg 780,000; wzero2; texfar_m1, texfar_m1q; hugepos c]

An attribute = (attribute plane value) / (1/w plane value), both from section 5 at the same point.

### 6.1 The reciprocal table [M uvmeas recipscan: all 32768 16-bit mantissas]

For a 16-bit denominator mantissa D (32768 .. 65535, i.e. D / 65536 in [0.5, 1)):

    t[i] = ceil(2^32 / (64 (512 + i))),  i = 0 .. 512           // 131072 .. 65536, 18 bits
    n[i] = t[i] - t[i+1] + c[i],          i = 0 .. 511           // 65 .. 256, 9 bits; c[i] in {0, 1, 2}: appendix A
    r(D) = (64 t[i] - 1 - n[i] (D & 63)) >> 7,   i = (D >> 6) - 512        // 16 bits, 32768 .. 65535

r(D) / 65536 is about 32768 / D. r is floor(2^31 / D) for 28,487 values of D, one less for 1,110, one more for
3,171 [checked by agents/spec-tsp/tabcheck.cpp]. r(32768) = 65535: **1 / 1.0 = 0.FFFF**, which is why an attribute
over 1/w = 1 arrives one unit of its 16th bit low and a coordinate on a texel boundary shows the texel before it
[M uvmeas, sample]. Table: 512 entries x (t 18 bits, n 9 bits), or t and c (2 bits). No formula is known for c
(102 zeros, 403 ones, 7 twos).

### 6.2 A denominator below zero (`DenominatorSeen`) [M uvmeas wneg: 780,000 of 780,000]

The leading bit stays and the 15 bits under it are negated; the sign is dropped (the quotient has the numerator's
sign):

    den positive (or zero): unchanged
    den = -2^-143 (the -1-unit value, the only one below 2^-128): read as 0xFFFF x 2^-143, positive  [M texfar_m1: 166 of 166]
    den negative otherwise: m = its mantissa normalized to 16 bits (32768..65535);
                            m' = 32768 + ((65536 - m) & 32767);  positive
    so -v between two powers of two reads as 3 2^p - v (-1.25 as 1.75, -1.75 as 1.25), a power of two as itself

### 6.3 The quotient (`Divide(num, den)`)

    num == 0                      -> +0 whatever den is            [M hugepos c: the pixel where both planes are 0 is black]
    den == 0                      -> den = 2^-128                  [M uvmeas wzero2: 32,784 readings; 2^-127, 2^-129 each 23,000 fewer]
    den = DenominatorSeen(den)
    md = top 16 bits of den's mantissa (32768..65535); ed = top(den)
    bn = bits(num.mant) (16, or 17 for the carried 2^16); en = top(num)
    r  = r(md)
    q  = floor( num.mant * r * 2 / 2^bn )      (toward minus infinity: a negative num with lost bits rounds its magnitude UP)
    quotient = ±q x 2^(en + 1 - ed - 17)       // sign of num

i.e. the product of the two mantissas (as fractions in [0.5, 1)) is **floored at 17 fractional bits** before it is
normalized: a product >= 1/2 keeps 17 significant bits, a smaller one 16 [M uvmeas point 8: 1,560,000 of 1,560,000].
q is 16 or 17 bits (32768 .. 131068, never 0) [agents/spec-tsp/tabcheck.cpp]. The quotient is never an infinity or a
NaN; refsw3 bounds it at about 2^243 [texfar_quot]. Its exponent can be far outside a single's (tiny numerators over
large denominators), so carry about 10 signed exponent bits into section 7 and section 9.1, which only saturate it.
A quotient below zero stays below zero however small [M uvmeas whuge: its texel is the one before 0].

Hardware per pixel [I PIPELINE_SHAPE [5]]: one reciprocal lookup (the table + one 9x6 multiply-subtract) and one
16x17 multiplier per divided attribute: U, V, B, G, R, A, and the offset's B, G, R, A when the offset is read.


## 7. Colour rounding (`ColorRounded`) [M cmeas: 2,340,000 of 2,340,000; shade 80,256 of 80,256]

For a colour channel: q = Divide(colour plane value, W), v = q x 2^8 (the colour's own scale):

    q negative or zero -> 0
    otherwise          -> min( floor(v + 1/2), 255 )     (to nearest, half way up; computed exactly on q's 17 bits)

Base colour: `InterpolateBase`: the four channels so; if TSP.UseAlpha = 0, A = 255. Offset colour:
`InterpolateOffs`: the four channels so. A pixel whose depth is below zero is drawn like any other; its colours are
negative quotients, so 0 [M uvmeas wneg, huge].


## 8. The mipmap level (`MipSelect`, `mipChoose`) [M mipmeas 8 sets 20.7M colour values, mipk..mipk5, mipdump, mipdet, mip, mipbil, trimin, ssmip]

D (the manual's) = K w^2: K per polygon, w^2 per pixel, all in 8-bit floats at the end.

### 8.1 K, per polygon (setup)

Inputs: the U/w, V/w and 1/w planes of the volume in use (their undivided sums Sa, Sb, Sc and Sdet of the 1/w
plane, section 4.2; their 24-bit coefficients A0, B0, C0), the texture size `size = 3 + TexU` (log2), the bias
`MipMapD` in quarters (**0 is taken as 4** [M mipmeas --bias0: 4,147,200 of 4,147,200; polly2-data berserk_*]).

Arithmetic: the setup's 24-bit truncating numbers with the range rules of section 4.1.

    inv  = Sdet is inf ? 0 : recip24(Sdet);  if inv < 2^-126: inv = 0
    undivided = (Sdet != 0) && (inv != 0)            // the normal case
    inv2 = mul24(inv, inv);  if inv2 < 2^-126: inv2 = 0          [M mipdump, mipdet: a determinant above 2^63 -> largest map]

    where the numerators are taken (DCalcCtrl):
      DCalcCtrl 0: su, sv, sw = Sc of the U, V, 1/w planes (the planes at the screen's origin)
      DCalcCtrl 1: with (u1, v1, z1, x1, y1) = vertex index 0 of the triangle (after the odd-strip swap; volume 2: u1, v1 of volume 2):
                   s_p = add53( add53( mul24(Sa_p, x1), mul24(Sb_p, y1) ), Sc_p )   for each plane p, range rules, adder reach 53
                   [M mipmeas dcalc page 6 300 of 300, mwextd1 4,147,200 of 4,147,200]

    numerator(direction, a = U or V), undivided (the normal case):
      along x: n = cut24( cut24(s_a * Sa_w) - cut24(Sa_a * s_w) )     // |Sc_a Sa_w - Sa_a Sc_w|
      along y: n = cut24( cut24(Sb_a * s_w) - cut24(s_a * Sb_w) )     // |Sb_a Sc_w - Sc_a Sb_w|
      magnitude taken. Each product: a zero factor (also times inf) gives 0; an inf factor times a non-zero gives inf;
        else the 24-bit product, >= 2^128 -> inf, < 2^-126 -> 0.
        inf - inf of the same sign (the two products' signs): 0; any other inf: n = inf
      limits judged on the quotient: if n x inv2 < 2^-126: n = 0; if >= 2^128: n = inf; else n stays UNdivided

    length(p, q) = p or q inf: inf;  hi = larger, lo = smaller;  lo == 0: hi
                   sum  = cut24( add_reach25(hi, lo) )
                   less = cut24( lo x 0x95F612 x 2^-24 )          // 0x3F15F612 = 0.585785985, 8 ulps under 2 - sqrt(2)
                   L    = cut24( sub_reach25(sum, less) )         // about hi + (sqrt(2) - 1) lo, a sawtooth
    Lx = length(n_x(U), n_x(V));  Ly = length(n_y(U), n_y(V))
    best = Lx if Lx is inf or Ly <= Lx, else Ly
    if undivided and best finite non-zero: best = mul24(best, inv2); >= 2^128 -> inf; < 2^-126 -> 0
    K8 = best inf  ? 2^(-128 + size)                                // field 255 + size, wrapped
       : best zero ? 2^(-127 + size)                                // field 0 + size
       : cut8( best x MipMapD x 2^(size - 2) )                     // bias/4 x size, then 8 bits toward zero

Not undivided (Sdet zero, or its reciprocal zero): the same with the divided 24-bit coefficients, exact products
(`MIP_K=1`'s path): x: |C0_a A0_w - A0_a C0_w|, y: |B0_a C0_w - C0_a B0_w| (DCalcCtrl 1: the planes evaluated at
the first vertex exactly, (A0 x1 + B0 y1) + C0, or u1 z1, v1 z1, z1 in the 24-bit ranged product when x1 or y1 is
an infinity), limits judged on n itself; the zero / infinity decision for each product is still taken from the
undivided sums as above, and no 1/det^2 product follows. For a determinant of exactly 0 the A0, B0 are 0, so
K8 = 2^(-127 + size).

Pins: the undivided numerators, products and difference cut to 24 bits, the length rule with 0x95F612 (no other
value at 2^-28), once times 1/det^2 [M mipk4 3,920 cells of mipk3 and mipk4; mipk5 1991 of 1991; mipk 2,401
cells; mipk2 2,401 of 2,401; r2r_ring]; the limits [M mipmeas mwext1 4,147,200 of 4,147,200: a flat 1/w = z on a
32x32 quad overflows from z = 2^57, is zero below z = 2^-60; K's exponent field + size wraps]; the dependence on
position with DCalcCtrl 0 [M mipmeas mpos1].

**GAP**: the adder reach of the DCalcCtrl 1 evaluation (refsw3: 53, not the setup's 25); which vertex is "first"
for an odd strip triangle (refsw3: vertex 0 after the swap); K on an FPU_PERP_VAL triangle (refsw3 uses the
original Sdet and sums, as if not perpendicular); K at a pixel whose 1/w is -1 unit.

### 8.2 Per pixel

    w   = Divide(1.0, W)                 // W = the pixel's 1/w (section 5): the divider's own reciprocal, DenominatorSeen included;
                                         // 1 / 1.0 = 0.FFFF; the sign of w is dropped
    w8  = cut8(|w|)
    ww  = cut8(w8 x w8);  if top(ww) - 1 > 127: lower the exponent to 127 keeping the mantissa   [M mipmeas wext]
    d   = cut8(K8 x ww)
    L   = floor(log2 d);  M = d's top 8 bits (128 .. 255)
    L < 0:  level 0, k = 0 (no blend below level 0)
    else:   level = L, f = M - 128 (of 128), k = (f == 127) ? 256 : 2 f        // k of 256: the next level's share

[M mipmeas: the cut of w x w to 8 bits is the fingerprint, not a log domain: MIP_ARITH 1..6 alternatives each miss
10,212 .. 2,286,280 values; with 1/w exactly 1.0, w = 0.FF, w^2 = 0.FE: a level change at 2 + 1/32 texels a
pixel for power-of-two determinants, at 2 for any other]. Hardware [I]: two 8x8 multiplies and a leading-one search.

### 8.3 Choosing the level (`mipChoose`), only when TCW.MipMapped

    choice = MipSelect(...)                            // level L, k
    SupSample point (section 18): if L == 0: k = 0, else L = L - 1        // one level finer
    last  = 3 + TexU                                   // the 1x1 level (a mipmapped texture is square)
    level = L + (FilterMode == 3 ? 1 : 0)             // trilinear pass B reads the next smaller level
    level = min(level, last);  dTri = k
    raster texture (ScanOrder set, not palette): level = 0 (no levels), dTri still k (fades, section 16)

[M trimin 180 of 180: no level past 1x1, pass B at 1x1 reads 1x1, the fraction still fades; the three texels in front
of the 1x1 level are never read; ssmip 14 pages; supsample2]. Without TCW.MipMapped: level 0, k = 0.


## 9. Texture coordinates and addresses

### 9.1 From quotient to texel and weight (`TexCoordFixed`, `CoordKeep`, `TextureFilter`) [M coordfix 1568 + 4128 regions, sample, texfar*, mipbil, bumpclamp, bumpiso]

U, V = Divide(U/w value, W), Divide(V/w value, W) of the volume in use (section 6). For a coordinate q and a size
2^s texels:

    TexCoordFixed(q, s + 8) = floor(q x 2^(s+8))   in 1/256 texel, two's complement, toward minus infinity (also below 0)
      kept as CoordKeep: |F| < 2^30 exactly; F >= 2^30: 2^30 + (F mod 2^26); F < -2^30: -2^30 + (F mod 2^26)
      (the sign and the low 26 bits: all that wrap, flip and clamp look at; it never overflows to texel 0)
    q = 0 -> 0

[M coordfix: toward zero gets 437 of 1568 regions wrong, magnitude weights 489; texfar, texfar_edge, texfar_quot,
texfar_bits: up to quotients of 2^243, F to 2^261, all exact; clamped positive = last texel, negative = texel 0;
wrap/flip read the real low bits]. RTL: a 32-bit signed register with CoordKeep's saturation suffices.

    half = (HALF_OFFSET bit 2 && filter != point) ? -128 : 0     // the texel half offset: bilinear only [M sample, halfofs]
    filter = point when FilterMode == 0, or FilterMode >= 2 and !TCW.MipMapped (section 11.1)

Not mipmapped (or raster, `TcwRaster`): sizeU = 8 << TexU, sizeV = 8 << TexV,

    ui = TexCoordFixed(U, log2 sizeU + 8) + half;   vi = TexCoordFixed(V, log2 sizeV + 8) + half

Mipmapped (and not raster), level L (after the clamp L <= 3 + TexU): the texture is square at the U size,
sizeU = sizeV = (8 << TexU) >> L, and the coordinate is made at the full size, the half texel taken off there,
then shifted (arithmetic) by L [M mipbil 1120 of 1120; polly2-data sa_slow1-3: the level's own half texel gets
74,673 of 921,600 pixels wrong]:

    ui = (TexCoordFixed(U, 3 + TexU + 8) + half) >> L
    d  = TexU - TexV                                    // declared V size other than U
    d > 0:  v0 = CoordKeep( TexCoordFixed(V, 3 + TexU + 8) + half x 2^d )    // V at the full height, the declared half texel
    d <= 0: v0 = (TexCoordFixed(V, 3 + TexV + 8) + half) >> (-d)
    vi = v0 >> L

[M sample "declared": declared 16x8 sits a whole row higher than 16x16; texfar_decl 300 of 300 (scaling the
declared coordinate up instead: 122 wrong, every one with d >= 4 + level); texfar_mip, texfar_mipv]. **GAP**: a
mipmapped texture declared taller than wide at large -d, with fraction bits.

Clamp below zero first, then texel and weight:

    if ClampU and ui < 0: ui = 0;  if ClampV and vi < 0: vi = 0          [M bumpclamp 1792 of 1792, bumpiso: texel 0 and 1 with weight 0]
    tu = ui >> 8 (arithmetic), tv = vi >> 8;  the four texels (tu, tv), (tu+1, tv), (tu, tv+1), (tu+1, tv+1)
    ublend = (ui & 255) >> 3,  vblend = (vi & 255) >> 3                   // 5-bit weights [M sample page 2, alphafilt]

Each texel coordinate through `ClampFlip(c, size)`:

    clamp: c < 0 -> 0, c >= size -> size - 1          (also the second texel: no wrap past the end [M bumpclamp])
    flip:  c &= 2 size - 1; if (c & size): c ^= 2 size - 1
    wrap:  c &= size - 1
    clamp wins over flip. A strided texture (StrideSel and ScanOrder, not palette) ignores the flip bits [M sample "stride 32"]

[M env: all 16 flip/clamp combinations].

### 9.2 Texel index (`TexOffsetGen`): twiddled, raster, strided, mipmapped

`raster` (`TcwRaster`) = ScanOrder && format not palette. With raster, the MipMapped and VQ bits **do nothing to
where a texel is fetched** (row by row, one level, uncompressed) [M mip page 17: every word names its own place, all
16 settings of the four bits]. Palette formats have no ScanOrder/StrideSel (those bits are PalSelect): always
twiddled. Without ScanOrder, StrideSel does nothing.

Texel index T (in texels from the texture's start, before VQ):

    raster:        T = tu + stride x tv
                   stride = (StrideSel) ? (TEXT_CONTROL & 31) x 32 : 8 << TexU        [M sample, texfmt stride variants]
    twiddled:      T = twiddle(tu, tv, log2 U, log2 V)
    mipmapped:     T = MipPoint[s] + twiddle(tu, tv, s, s),   s = 3 + TexU - L  (level size 2^s)

    twiddle(u, v, lu, lv): with m = min(lu, lv): bit 2k = v_k, bit 2k+1 = u_k for k < m;
                           the remaining bits of the longer coordinate above, in order (bit 2m + j = (longer)_{m+j})
    MipPoint[s] = 3 + (4^s - 1) / 3   texels: 3, 4, 8, 24, 88, 344, 1368, 5464, 21848, 87384, 349528 (s = 0 .. 10)

(refsw3 `twop` = `detwiddle[0][lv][u] + detwiddle[1][lu][v]` from nulldc3 `TexCache.cpp` `twiddle_slow`; the closed
form above equals it for every u < 2^lu, v < 2^lv, lu, lv = 0..10 [checked by agents/spec-tsp/twcheck.cpp]. MipPoint
equals refsw3's table.) **GAP**: stride 0 (TEXT_CONTROL[4:0] = 0) gives stride 0 in refsw3.

### 9.3 Bits per texel and the memory word

Texture memory is read through the **64-bit view** (`emu_vram[addr]` directly, 8-byte words). `start = TexAddr << 3`.

| format | bits/texel (not VQ) | texels per 64-bit word | texel within the word |
|---|---|---|---|
| 1555, 565, 4444, YUV422, bump, reserved | 16 | 4 | 16-bit lane T & 3 |
| palette 8 bpp | 8 | 8 | byte T & 7 |
| palette 4 bpp | 4 | 16 | nibble T & 15 (bits 4n+3..4n) |

Not VQ: word address = `(start + T x bpp / 8) & (VRAM_MASK - 7)` (8 MB, 8-byte aligned; T x bpp / 8 rounds down).

### 9.4 VQ (`VQIndexAddress`, `VQLookup`) [M texctl, texctl_bank, texctl_bankbase, texctl_bankmip, texctl_addr; sample "palette VQ"]

Code book: 256 entries of 64 bits at `start` (2048 bytes). Indices follow it. One index byte covers one code book
entry = one 64-bit word of texels in twiddled order:

| format | texels per index | index byte offset `o` | texel within the entry |
|---|---|---|---|
| 16-bit (incl. YUV, bump) | 4 (2x2) | T / 4 | 16-bit lane T & 3 |
| palette 8 bpp | 8 (2 wide, 4 tall) | T / 8 | byte T & 7 |
| palette 4 bpp | 16 (4x4) | T / 16 | nibble T & 15 |

    index address = ((start + o) XOR (bank << 19)) + 2048,  bank = TEXT_CONTROL[12:8];  then XOR 1 if TEXT_CONTROL bit 16
    index  = byte at (index address & VRAM_MASK)
    entry  = 64-bit word at (start & (VRAM_MASK - 7)) + index x 8

Only the index read moves with the bank bits; the code book and every non-VQ texture are read where they are
[M texctl_addr: 1,441,792 of 1,441,792 words; with the bank bits applied to them too 144 of 233 regions wrong].
XOR before the 2 KB is added [M texctl_bankbase: XOR after the 2 KB 6,098 wrong, the start alone 21,330;
texctl_bankmip: 2,716 of 2,716, alternatives 205 .. 1,214 wrong]. Bit 16 swaps index bytes in pairs (byte address
^ 1) [M texctl page 1, texctl_addr]. **GAP**: bank bit 4 (b >= 16) taken as address bit 23; with it, or a sum past 8 MB,
the console reads run-to-run different data; refsw3 wraps at 8 MB. **GAP**: a code book within 2 KB of the 8 MB end.

### 9.5 TEXT_CONTROL bit 17: byte swap [M texctl pages 2, 3, 11; texctl_addr pages 2, 3, 7, 20, 21; texctl_bankmip 17, 18]

After the 64-bit word (or the code book entry) is read and before decode: the two bytes of every 16-bit unit are
swapped (`((w & 0x00ff..) << 8) | ((w >> 8) & 0x00ff..)`): 16-bit texels, palette indices (8 bpp: byte ^ 1, 4 bpp:
nibble ^ 2), code book entries, YUV422, bump. Not VQ index bytes, no address changes.

### 9.6 Palette (`DecodeTextel` Pal4 / Pal8) [M texfmt palette pages, timemeas]

    4 bpp: idx = PalSelect x 16 + nibble        (PalSelect = TCW[26:21], 64 banks of 16)
    8 bpp: idx = (PalSelect >> 4) x 256 + byte  (TCW[26:25], 4 banks of 256)
    entry = PALETTE_RAM[idx] (32 bits), expanded by PAL_RAM_CTRL[1:0] (section 10)

Read at shading time (timemeas `TM_ORDER` rewrites entry 0 during the render to read the order of shading).


## 10. Texel decode and expansion (`DecodeTextel`, `ExpandToARGB8888`, `TexUtils.h`) [M texfmt 46 pages 3864 regions, yuvbil, sample, texctl]

Channel widening by **bit replication** (full scale 255) [M texfmt]:

    EXPAND5(v) = v << 3 | v >> 2;  EXPAND6(v) = v << 2 | v >> 4;  EXPAND4(v) = v x 17
    1555: A = bit15 ? 255 : 0, R = EXPAND5(14..10), G = EXPAND5(9..5), B = EXPAND5(4..0)
    565:  A = 255, R = EXPAND5(15..11), G = EXPAND6(10..5), B = EXPAND5(4..0)
    4444: A = EXPAND4(15..12), R = EXPAND4(11..8), G = EXPAND4(7..4), B = EXPAND4(3..0)
    8888 (palette only): as is

Format -> expansion: 16-bit formats by PixelFmt (0 1555, 1 565, 2 4444); palette by PAL_RAM_CTRL[1:0]; YUV422 and
bump pass the decoder's 32-bit result through.

**Reserved format 7**: read as a 16-bit texel and passed through raw (B = low byte, G = high byte, R = A = 0). **GAP**.

**YUV422** [M texfmt pages 1-2, yuvbil 164 of 164]: a texel is Y (high byte of its 16-bit word) and one chroma byte
(low byte); the texel at an even x carries U, its neighbour at x + 1 in the same row V; both share U and V. Within
the 64-bit word / code book entry (lane `self = T & 3`): twiddled (also VQ, mipmapped): U from lane `self & 1`, V
from lane `self | 2` (x is bit 1 of the lane); raster: U from lane `self & 2`, V from `self | 1`. Pairing by x also
in twiddled textures, not by memory order [M yuvbil]. Conversion (refsw3 `YUV422`, fitted to the console):

    U' = U - 128, V' = V - 128 (signed);  Tu = U' + (U' >> 2) + (U' >> 3);  Tv = V' + (V' >> 2) + (V' >> 3)   (arithmetic shifts)
    R = Y + Tv;  G = Y - (Tu >> 2) - (Tv >> 1);  B = Y + Tu + (Tu >> 2);  each clamped to 0..255;  A = 255

Each of the four bilinear texels is converted (and clamped) before filtering [M yuvbil: 14 pairs of colours]. The
1x1 level of a mipmapped YUV422 texture is read as **RGB565** (`TextureFetch`: level == TexU + 3) [M mip "YUV422
mipmapped", whose 1x1 level holds a YUV word; mip 1083 of 1083].

**Bump map**: the 16-bit texel passes raw: B (byte 0) = **R** (the angle, low byte), G (byte 1) = **S** (the
elevation, high byte). Section 12.

**Strided textures, bilinear**: 565, 1555, 4444 texels widened by **shift only** (low bits zero; 4444 alpha too;
1555's alpha stays 0 or 255): after the replication, mask B, R with 0xF8 (4444: 0xF0), G with 0xFC (565) / 0xF8
(1555) / 0xF0 (4444), 4444's A with 0xF0. Not YUV, not bump; point-sampled strided textures replicate as usual
[M texfmt "stride 32, bilinear", sample].


## 11. Filtering (`TextureFilter`) [M sample 50 pages 7815 regions, mip, bumpbil, alphafilt]

### 11.1 Filter choice

    FilterMode 0: point;  1: bilinear;  2, 3 with TCW.MipMapped: bilinear at the chosen level (passes A and B, section 8.3, 16)
    FilterMode 2, 3 without TCW.MipMapped: POINT, at full strength, no fade
                [M dumprules page 0 cells 60-67, polly2-data shenmue_intro: a 4444 texture's alpha one texel's]

(refsw3's comment inside `TextureFilter` still says "bilinearly" for this case; the dispatch in `PixelFlush_tsp`
sends it to the point filter, and that is what is measured.)

### 11.2 Point: the texel (tu, tv). Bilinear: two truncated 5-bit steps, per channel B, G, R, A [M sample page 1: 52,224 of 52,224; one sum of four: 38,523]

    row0 = (t(tu, tv) (32 - ub) + t(tu+1, tv) ub) >> 5
    row1 = (t(tu, tv+1) (32 - ub) + t(tu+1, tv+1) ub) >> 5
    out  = (row0 (32 - vb) + row1 vb) >> 5

A 0 -> 255 step over 32 pixels reads 0, 7, 15, 23 .. [M sample page 2]; fraction 8/256 of a transparent texel gives
0xF7 [M alphafilt 112 of 112].

### 11.3 Bump map R channel (byte 0) round the circle [M bumpbil 1792 regions]

The same two steps, but each step is:

    circular(first, second, w): hi = max, lo = min, apart = hi - lo
        start    = apart < 128 ? lo : hi;  distance = apart < 128 ? apart : 256 - apart
        weight   = (start == first) ? w : 31 - w           // never 32
        return (start + ((distance x weight) >> 5)) & 255
    row0 = circular(t(tu,tv).R, t(tu+1,tv).R, ub); row1 = circular(t(tu,tv+1).R, t(tu+1,tv+1).R, ub); R = circular(row0, row1, vb)

S (byte 1) is filtered as a colour channel. Halfway from 210 to 0 is 233; 0 -> 64 over 32 pixels reads 0, 2 .. 62;
64 -> 0 reads 62, 60 .. 0 [M bumpbil].

### 11.4 IgnoreTexA: after filtering, texel A = 255.

**Not modelled**: a bump map that is not twiddled, filtered bilinearly, stops the render at the 16th such quad shaded
(8th in the opaque and punch-through lists), the count carrying across renders until a core reset [M bumphang].


## 12. Bump mapping (`BumpMapper`) [M bumpfn 952 regions: every S and R under fourteen lights; bump; bumplight]

Light = the offset colour: K1 = A, K2 = R, K3 = G, Q = B (section 14 says which offset colour). Texel: R (angle) =
byte 0, S = byte 1.

    a = |R - Q|                         (the magnitude, not the low 8 bits of the difference)
    quad = a >> 6,  x = a & 63
    across = COS[4 x] for quad 0, 2;  COS[4 (63 - x)] for quad 1, 3
    t3 = (((K3 x COS[S]) >> 8) x across) >> 8
    I  = K1 + ((K2 x SIN[S]) >> 8) + (quad == 1 || quad == 2 ? -t3 : t3),  clamped to 0 .. 255
    result texel = (B, G, R, A) = (255, 255, 255, I)

SIN, COS: two measured 256-byte tables (appendix B); each is a line per 8 entries, not a sine. Every product drops
its 8 low bits before the next step (K3 = 255 at S = 0, R = Q gives 253). The bump result takes the texel's place in
the shading instruction (section 13) with **no offset added** [M bump: modulate multiplies the base colour by I].


## 13. Shading instruction (`ColorCombiner`) [M env 208 regions, alphatest, sprite, supsample2, trifade]

b = base colour (section 7), t = texel (sections 10-12), o = offset colour (section 14). Not textured (ISP
Texture = 0): out = b, no offset. Textured:

    0 decal:          rgb = t.rgb;                                 a = t.a
    1 modulate:       rgb = (t.rgb x b.rgb) >> 8;                  a = t.a          // 255 x 255 = 254 [M env]
    2 decal alpha:    ta = t.a + (t.a == 255);  rgb = ((t.rgb x ta) >> 8) + ((b.rgb x (256 - ta)) >> 8);  a = b.a
    3 modulate alpha: rgb = (t.rgb x b.rgb) >> 8;  a = min( ((t.a + (t.a == 255)) x (b.a + (b.a == 255))) >> 8, 255 )
                                                                                     // 0x80 x 255 = 0x80 either way [M env page 1]
    then, if ISP Offset (and not a bump map): rgb = min(rgb + o.rgb, 255) per channel; alpha untouched

Bump map: the texel is BumpMapper's (255, 255, 255, I), the combiner is the same instruction without the offset.


## 14. The offset colour and the kept offset colour (`offsKept`) [M offspersist 13 pages; bumplight 12 pages; supsample2 pages 28-32]

Per pixel (`PixelFlush_tsp`):

    offs = offsKept
    if Texture && Offset:
        offs     = bump ? light : InterpolateOffs(Ofs[vol])        // light = v3's offset colour AS SENT (Ofs[vol] fallbacks)
        offsKept = light
    (a pixel with Offset and without Texture keeps offs = offsKept: see GAP below)

- A bump map's light is **the last vertex's offset colour as sent**: not interpolated on a Gouraud polygon, not
  through the 1/w planes on a flat one [M supsample2 page 30: interpolated misses 123,578 pixels; bumplight];
  with an intensity shadow inside the volume it is the scaled v3 offset colour.
- `offsKept` = that colour of the **last textured primitive with the offset bit the TSP shaded**, in the TSP's
  order (section 3.2), across tiles, renders and core soft resets; **0 after power on**. A bump map without the
  Offset bit is lit by it [M offspersist: a reader shaded before its tile's setter reads the tile before's; one
  listed first but shaded after reads its own tile's]. Decal, modulate and vertex fog without the offset bit do
  not read it [M offspersist page 10].
- The RTL needs one 32-bit register that survives renders and SOFTRESET, reset only at power on.

**GAP**: a setter whose offset colours are all zero (the console drops the offset planes then [M timemeas
vol2off]: does the register still load?); how long it lasts powered off; a polygon with Offset and without
Texture (the TA never makes one): refsw3's vertex fog then uses `offsKept.a`.


## 15. Colour clamp and fog (`FogUnit`, `LookupFogTable`) [M fog, tspw 1920, wmeas, dumprules page 0 cells 40-43, slivers_dzspec, supsample2, trifade]

### 15.1 Colour clamp (TSP ColorClamp), first: each of B, G, R, A: `c = max(min(c, FOG_CLAMP_MAX.c), FOG_CLAMP_MIN.c)`.

### 15.2 The fog table's alpha, from the TSP's own 1/w W (section 5; a SupSample point's own)

    dm = FOG_DENSITY[15:8] (mantissa 1.7), de = FOG_DENSITY[7:0] (signed exponent)
    if W is negative, zero, or dm == 0:  fogW = 1.0
    else: m = dm x W.mant (exact: 8 x 16 bits <= 24 bits); fogW = m x 2^(W.exp + de - 7)
          fogW < 1 -> 1.0;  fogW >= 256 -> 256 - 2^-16 (mantissa all ones, exponent 7)
    as an IEEE single: exponent field E (127 .. 134), 23-bit fraction F
    index = (((E + 1) & 7) << 4) | (F >> 19)                // 128 entries: 16 per binade 1..256
    bf    = (F >> 11) & 255                                  // blend factor
    entry = FOG_TABLE[index];  hi = entry[15:8], lo = entry[7:0]
    fog_alpha = (lo x bf + hi x (256 - bf)) >> 8

[M tspw: 8 bits of W's mantissa read through the table; fog 640 of 640; slivers_dzspec: a 1/w below zero gets no fog
(1,501 rows), as one below 1]. The product needs no rounding mode because W has 16 bits (refsw3 static_asserts it).

### 15.3 By FogCtrl

    00 table:       rgb = (rgb x (256 - fa) + FOG_COL_RAM.rgb x fa) >> 8,  fa = fog_alpha;  alpha unchanged
    11 table mode 2: rgb = FOG_COL_RAM.rgb;  a = fog_alpha
    01 per vertex:  only if ISP Offset: rgb = (rgb x (256 - a) + FOG_COL_VERT.rgb x a) >> 8, a = offs.a  (0 for a bump map)
                    [M dumprules: 12,242 of 12,242 pixels of polly2-data sc_ingame; the blend unit's weights 5,201]
    10 none

A bump map gets no vertex fog (its offset alpha is K1, not a fog) [M bumplight page 5]; table fog applies to it.


## 16. Trilinear fade [M trifade 22 pages, supsample2 pages 21-26, 31, 32]

If Texture, FilterMode >= 2 and TCW.MipMapped (the raw bit, so also a raster texture with the bit [M trifade]):

    w = (FilterMode == 2) ? 256 - k : k;       k = min(max(dTri, 0), 256)
    each of B, G, R, A: c = (c x w) >> 8

Of the **finished** colour: after the shading instruction, the offset, the colour clamp and the fog (mode 2's fog
alpha too, an IgnoreTexA alpha too, bump maps too) [M supsample2 page 21: fading the texel misses 149,148 of
153,600]. Not faded: a texture without mipmaps [M mip "565 without mipmaps"]. The two passes are added by the blend
unit (games draw A then B, ONE/ONE).


## 17. Tile buffers and write-out

### 17.1 The two tile buffers [M accbuf 9 pages, blendpos, blendsel, keepz]

Exactly two 32x32x32-bit colour buffers. The tile is shaded into `buffer1`; `buffer2` is the **secondary
accumulation buffer** of the blend select bits and holds the finished picture of the tile before. They **change
places** (no copy) after every entry that is written out, and after an empty keep Z entry that follows a written
one (it is not itself written). An entry with the no-writeout bit leaves them where they are. The buffers'
contents persist across renders (from the last tile of one frame to the first of the next) and are what the
background overwrites; a keep Z entry finds the content from two tiles before [M accbuf page 2].

Region entry write-out logic (`RenderCORE`):

    shaded       = number of PixelFlush_tsp calls in this entry (every pass, background included)
    emptyKeepZ   = z_keep && shaded == 0 && prevWrittenOut
    emptyAfterNW = z_keep && shaded == 0 && !prevWrittenOut && there was an entry before
    tile written = emptyAfterNW ? the PREVIOUS entry's tile : this entry's tile     [M keepz page 2]
    if !no_writeout && emptyKeepZ: swap, nothing written        [M accbuf pages 0, 3]
    elif !no_writeout:             write buffer1 out at `tile written`; swap
    prevWrittenOut = !no_writeout && !emptyKeepZ

Some games draw a tile as two entries, first not written out, then keep Z with no lists, both with the same tile:
that writes the first entry's picture [M keepz page 0; polly2-data logo, mem, menu2, menu3, thps2_menu].

Not modelled (timing, refsw3 has no clock): a polygon that reads buffer 2 while the tile before is written out
damages 3-5 of its first lines, different every run [M accbuf page 7, blendpos]; a polygon that **writes** buffer 2
waits for the write-out (~1025 clocks a tile) [M accbuf pages 6, 8]; two empty keep Z tiles in a row hang the render;
one costs ~2390 clocks and the tile two before gets the next tile's picture [M accbuf, keepz_races]. The buffers
swap when the TSP **starts** the next tile, which is when the write-out of this one starts [M accbuf page 7].

### 17.2 Pixel clip, address, strip buffer (`put(X, Y, b, g, r, a)`) [M scalermeas, sof2probe, sof2field, sof2sweep]

    if X < FB_X_CLIP.min or X > max or Y < FB_Y_CLIP.min or Y > max: nothing      (framebuffer coordinates after the scaler, inclusive)
    base = FB_W_SOF1, line = Y                                                    (never SOF2 otherwise, whatever interlace/field)
    strip buffer (FB_R_CTRL bit 22): L = 16 x FB_R_CTRL[21:16]; L == 0: nothing written
        strip only grows: while Y >= (strip + 1) L: strip++;  line = Y - strip L; line < 0: nothing
        base = strip odd ? FB_W_SOF2 : FB_W_SOF1
    dst = base + line x FB_W_LINESTRIDE.stride x 8 + X x bpp       (bpp 2: packmode 0..3, 3: 4, 4: 5, 6)
    FB_W_SOF1 bit 24 (render to texture): write the 64-bit view at dst & VRAM_MASK; else the 32-bit view (pvr_map32)

Strip buffer: 10 of sof2sweep's 11 strip pages exact but for one pixel each [M]. **GAP / not modelled**: the one pixel
of a strip's first line that lands in the other buffer, half-tile strips with the tiles column by column (the
console swaps the buffers for the later columns), strips with the scaler (scrambled), where lines before a buffer go.

### 17.3 Pack and dither (FB_W_CTRL) [M fbpack 5,222,400 of 5,222,400; fb555, fb565]

    add = dither ? DITHER[Y & 3][X & 3] : 0                       // DITHER below, rows are y
    cut(v, n) = min( (v + (add >> (n - 4))) >> (8 - n), 2^n - 1 )  // 4 bits: the table; 5: half; 6: a quarter

    0  0555 KRGB: cut(b,5) | cut(g,5) << 5 | cut(r,5) << 10 | (kval & 0x80) << 8
    1  565:       cut(b,5) | cut(g,6) << 5 | cut(r,5) << 11
    2  4444:      cut(b,4) | cut(g,4) << 4 | cut(r,4) << 8 | cut(a,4) << 12     (alpha dithered too)
    3  1555:      cut(b,5) | cut(g,5) << 5 | cut(r,5) << 10 | (a >= fb_alpha_threshold) << 15   (not dithered)
    4  888:       bytes b, g, r at dst, dst+1, dst+2 (each through the view), no dither
    5  0888:      b | g << 8 | r << 16 | kval << 24
    6  8888:      b | g << 8 | r << 16 | a << 24
    7  invalid (refsw3 asserts). **GAP**

    DITHER = {  5, 13,  7, 15 }
             {  9,  1, 11,  3 }
             {  6, 14,  4, 12 }
             { 10,  2,  8,  0 }

Without dither: a plain truncation [M fb565/fb555]. Every dither entry pinned (lower bound = upper bound) [M fbpack].
**GAP**: render to texture in 1555 / 4444 (dreamcast-tests "Still not covered", TODO C7).

### 17.4 The scaler (SCALER_CTL) [M scalermeas 43, scalertile 34, sof2probe 12; ycoeff 18 pages; polly2-data underdefeat_*]

The scaler is not a pass over the picture: the written tiles go through it one after the other in region array
order; its state does not know where a tile is vertically.

    factor = SCALER_CTL[15:0];  filter = factor > 0x400;  halve = SCALER_CTL bit 16
    factor 0x400: each tile's 32 lines to its own place: row y of tile (X0, Y0) -> putRow(X0, Y0 + y)
    factor 0:     nothing written (**GAP**: not measured)
    otherwise, a stream (state per frame: ring[8] lines of 32 pixels, lines, rows, start, streamX = -1):
      per written tile (X0, tileY):
        if tileY == 0: endStream(stuck = false); lines = rows = 0; start = (filter && interlace && fieldselect) ? 1024 : 0
        for each of its 32 lines: ring[lines & 7] = line; lines++; emitRows(X0, end = false, stuck = false)
        streamX = X0
      at the end of the frame: endStream(stuck = true)
    endStream(stuck): if streamX < 0 or lines == 0: return
                      if filter: ring[lines & 7] = ring[(lines - 1) & 7]; lines++      // the last line once more as the one below it
                      emitRows(streamX, end = true, stuck)
    emitRows(X, end, stuck): last = (end && filter ? lines - 1 : lines) - 1
      loop: pos = rows x factor + start;  k = pos >> 10;  f = (pos >> 6) & 15
            end:     continue only if k + 1 <= last, or k == last and (pos & 1023) == 0
            not end: continue only if k + (filter ? 2 : 1) <= lines - 1
            for x, channel: a = Fl(k, x');  if f: a = (a (16 - f) + Fl(k + 1, x'') f) >> 4
                            (x' = 0 when stuck && filter && k == last, else x; likewise x'' for k + 1)
            putRow(X, rows & 1023, row); rows++
    Fl(i, x) = filter ? ((((c0 a) >> 4) + ((c1 v) >> 4) + ((c0 b) >> 4)) >> 4) & 0xFF : v
               v = ring[i & 7][x], a = ring[(i > 0 ? i - 1 : 0) & 7][x] (the first line repeated above), b = ring[(i + 1) & 7][x]
               c1 = Y_COEFF[15:8], c0 = Y_COEFF[7:0]; per channel; weights above 256 wrap; 0x8040 = 1-2-1
    putRow(X, Y, row): halve ? put(X/2 + x, Y, (row[2x] + row[2x+1]) >> 1 per channel) for x < 16 : put(X + x, Y, row[x])

Pins: 0x401 writes 479 lines, 0x801 240; the 10-bit row counter (0x100: lines 1024.. land on 0..); the hardware bug
"stuck": with the filter the last row of the last tile shows pixel 0's value on pixels 1..31 [M scalertile]; Y_COEFF
arithmetic [M ycoeff, underdefeat_*: whole products >> 8 or cuts by 3 or 5 bits miss 2,000-5,000 pixels a frame].
Changing SCALER_CTL between renders stalls the next render unless the core is reset [M scalermeas]. **GAP**: a stream
that began before the frame's first tile with y = 0 and the field offset (refsw3 starts each frame from nothing).


## 18. SupSample (TSP bit 12) [M supsample 19 pages, supsample2 33, sscolor 16, ssvol 17, ssmip 14, ssrare 20, sshalf 16, halfofs2]

The pixel is made at four points p = 0..3, hx = p & 1, hy = p >> 1 (centre, half a pixel right, half a line down,
both). Each point has everything of its own:

    ws = 1/w plane at the point (section 5.4)
    U, V = Divide(U/w, ws), Divide(V/w, ws) at the point (if textured)
    base = InterpolateBase at the point over ws;  offset = InterpolateOffs at the point over ws (textured, Offset, not bump), else offs (section 14)
    level, kp = mipChoose(ws), one level finer (section 8.3);  texel = filter(U, V, level)
    c[p] = fade( fog( shade(base, texel, offset), ws, bump ? 0 : offset.a ), kp )     // colour clamp inside fog, section 15
    out  = (((c0 + c1) >> 1) + ((c2 + c3) >> 1)) >> 1      per channel: each row's two, then the rows

Works without a texture too (Gouraud and fog at four points) [M supsample2 page 27]. The offset colour for
`offsKept` and the bump light are per pixel, not per point. The alpha test and blend take the average [M sscolor:
punch-through]. Pins: the variants that fail [M supsample: the texels averaged before shading 56,421 pixels; the sum
>> 2 instead of pairs 4,334; supsample2: the centre's colours miss 112k .. 148k a Gouraud page; fog of the average
every fog page; the centre's 1/w for all four 6,934; the level not finer every minified cell]. **GAP** (TODO C10):
SupSample in the PT volume pass, translucent modifier volumes, sprites, 16-bit UVs, palette and YUV textures, render
to texture, DCalcCtrl with perspective.


## 19. Alpha test, blending, stuck alpha, per-pass handling

### 19.1 Alpha test (punch-through) [M alphatest, fbpack, dumprules cell 22]

Applied in the PT passes, and in the PT volume pass to pixels a PT pass resolved (not to the opaque pixels OpInPt
brings into that pass):

    if col.a < PT_ALPHA_REF: col.a = 0, failed;  else col.a = 255, passed

The blend still runs with that alpha: a failing pixel drawn with ONE/ZERO writes alpha 0 [M fbpack]; with
SRC_ALPHA/INV_SRC_ALPHA it leaves the pixel [M dumprules]. Re-shaded inside a volume, its colour replaces the pixel's
[M dumprules cell 22]. Threshold identical for every alpha 0..255 at references 0, 1, 127, 128, 255 [M alphatest].
**GAP**: PT_ALPHA_REF bits above 7 (refsw3 compares the whole 32-bit register).

### 19.2 Blend unit (`BlendingUnit`) [M blend 4096 of 4096, blendsel 3072, blendsel2 480]

    src = SrcSelect ? buffer2[pixel] : col;   dst = DstSelect ? buffer2[pixel] : buffer1[pixel]
    factor(instr, other):  instr >> 1:  0 -> 0;  1 -> other (all four channels);  2 -> src.a;  3 -> dst.a
                           other = dst for the source factor, src for the destination factor
    K(x, inv) = x' = x + (x == 255);  inv ? 256 - x' : x'               // 255 counts as 256; a factor and its inverse add to 256
    per channel B, G, R, A:  out = min( ((src x K(fs, SrcInstr & 1)) >> 8) + ((dst x K(fd, DstInstr & 1)) >> 8), 255 )
    if !(SrcSelect && DstSelect): (DstSelect ? buffer2 : buffer1)[pixel] = out        // both set: nothing written, ever

Each product shifted on its own, then added and saturated (3072 of 3072 colour squares; adding first: 1136) [M
blend]; alpha the same arithmetic [M blend alpha.py]. Two 8x9-bit multipliers a channel [I]. Opaque polygons go
through the same blend (accbuf: the select bits work in the opaque list as in the translucent one, page 1).

### 19.3 Stuck alpha (`tspAlphaStuck`, a hardware bug) [M blendsel, blendsel2: 8 x 8 kinds]

    after a pixel of a polygon with SrcSelect && DstSelect && DstInstr == 0 && (SrcInstr == 1 || SrcInstr == 4) is shaded:
        stuck = true                         (until the next region array entry)
    every later pixel in the entry, before the alpha test and blend:  col.a = (col.a == 255) ? 255 : 0

Alpha from buffer 2 (SrcSelect) is not affected (it is not col); polygons in between do not clear it; the next tile
starts clean. **GAP** (TODO C8): textured polygons (refsw3 replaces the alpha after the texture), what else clears it,
the per-pixel sort.

### 19.4 What each pass does with a shaded pixel (`RenderParamTags`)

| pass | alpha test | InVolume | after shading |
|---|---|---|---|
| OPAQUE | no | inside && shadow | - |
| PT_PASS0/N | yes | false | failed: next pass looks below this fragment (ISP); passed: resolved. A pixel resolved in the previous pass that is valid again is shaded **for the run only**: its two buffer words are restored after shading (colour, tag and depth kept) [M ptlayers] |
| PT_MV | resolved PT pixels only | inside && shadow | - (opaque OpInPt pixels inside a volume are shaded a second time here) [M uvrun kind 7, optrun] |
| TR_PRESORT | no | inside && shadow | after **every triangle** (list order) |
| TR_AUTOSORT | no | inside && shadow | per peeled layer; the layer's ISP depth kept for a following keep Z entry [M keepz page 3] |

A run-only pixel still has the side effects of shading: it counts for `offsKept` and `tspAlphaStuck` and in
`shaded` (17.1). Which pixels are in which pass is the ISP spec's.


## 20. Tables (sizes and where their contents come from)

| table | size | contents | origin |
|---|---|---|---|
| reciprocal | 512 x (t 18 bits, n 9 bits) or t + c 2 bits | t formula, c digits appendix A | measured [uvmeas recipscan] |
| bump SIN, COS | 2 x 256 x 8 bits | appendix B | measured [bumpfn] |
| dither | 16 x 4 bits | section 17.3 | measured [fbpack] |
| MipPoint | 11 x 19 bits | 3 + (4^s - 1)/3 | layout (measured through mip/mipbil/trimin) |
| twiddle | logic | bit interleave, section 9.2 | layout |
| fog table | 128 x 16 bits | FOG_TABLE registers | software |
| palette | 1024 x 32 bits | PALETTE_RAM registers | software |
| 1/3 | 24 bits | 0xAAAAAB x 2^-25 (`pvrfp::OneThird()`, shared with the ISP's depth mean) | measured [slivers_detzero, perpmean_*] |
| length constant | 24 bits | 0x95F612 x 2^-24 | measured [mipk4] |

`gentable.h` / `gentable.py`: dispatch only (section 2.4).

Widths at a glance (what each stage carries; all derived from the sections cited):

| stage | number | width |
|---|---|---|
| setup (4) | sign, 8-bit field (zero / inf), mantissa | 24 bits, every op cut toward zero |
| coefficients A, B, C (4.3) | sign, field8, mantissa | 16 bits; evaluator reads field - 127 as signed 8 (5.1) |
| mip inputs A0, B0, C0, Sa, Sb, Sc, Sdet (4) | as setup | 24 bits |
| grid accumulator k (5.3) | two's complement integer | 27 bits |
| plane value (5.5) | sign, mantissa, exponent >= -128 | 16 (17 on a carry) bits, exponent >= 9 bits signed |
| reciprocal r (6.1) | fraction of 65536 | 16 bits |
| quotient (6.3) | sign, mantissa, exponent | 16-17 bits, exponent about 10 bits signed |
| colour channel (7) | unsigned | 8 bits |
| texture coordinate F (9.1) | two's complement, 1/256 texel, CoordKeep saturation | 32 bits (31 used) |
| bilinear weights (11.2) | unsigned | 5 bits (0 .. 31), complements 32 - w |
| K8, w8, w x w, d (8) | mantissa + exponent | 8 bits each |
| fog W (15.2) | mantissa + exponent | 24-bit product of 8 x 16 |
| blend factor (19.2) | 0 .. 256 | 9 bits; products 8 x 9 bits, each >> 8 |

State the TSP side keeps (beyond a pixel):

| state | size | lifetime |
|---|---|---|
| two tile colour buffers + which is buffer 1 | 2 x 1024 x 32 bits + 1 bit | across renders (never cleared) |
| `offsKept` | 32 bits | across tiles, renders, SOFTRESET; 0 at power on |
| `tspAlphaStuck` | 1 bit | cleared at every region array entry |
| shaded-pixel count of the entry (keep Z logic) | 1 bit suffices (zero / non-zero) | per entry |
| previous entry written out, previous entry's tile | 1 bit + 12 bits | per render |
| scaler stream: 8 lines x 32 pixels x 32 bits, line count, row count (10 bits used), start (0 / 1024), last tile x | ~1 KB | per frame |
| strip counter | a few bits | per render |
| set-up primitives (planes, mip K, words) | ~12-16 primitives on the console [M] | per sorter drain (refsw3: 32-entry cache per entry) |


## 21. Timing facts the RTL must reproduce (measured; refsw3 has no clock)

From PIPELINE_SHAPE.md and timemeas/REPORT.md, core clocks of 10 ns. These are what the console shows from outside;
the structure is inferred. They belong to the timing spec, listed here so that the TSP's datapath is shaped for them.

| what | clocks | tag |
|---|---|---|
| pixel, untextured or point-sampled formats, Gouraud, offset, fog | 1.01 | [M] |
| twiddled 16-bit bilinear / mipmapped bilinear (trilinear A) | 1.11 / 1.37 | [M] |
| palette with ARGB8888 entries (point or bilinear); YUV422 bilinear; bilinear not twiddled | 2.00; 2.00 (3.14 at an odd x sharing nothing); 2.07 | [M] |
| texels far apart / 4 texels a pixel (memory bound) | +2.25 / 2.14 | [M] |
| TSP setup per seen triangle: untextured / textured / +offset / bump / PT / translucent | 39 / 48 / 64 / 49 / 58 / 39 | [M] |
| DCalcCtrl 1 | +5 per seen triangle | [M] |
| run start sustained: untextured / textured / offset (flat = Gouraud) | 3.9 / 4.2 / 6.3; runs of different triangles >= 4.7 / 6 / 8 | [M] |
| a new triangle's setup takes ~2 clocks a plane out of the run starts (shared unit) | 13.7 for 7 planes, 22.8 for 11 | [M]/[I] |
| offset planes all zero: dropped (cost nothing) | | [M vol2off, offs3] |
| background polygon per entry; Z clear and setup; empty tile | 1035; 142; 335 + write-out | [M] |
| write-out a tile: 16 / 24 / 32 bpp (also fully clipped) | 1045 / 1105 / 1357 | [M] |
| write to buffer 2 waits for the previous write-out | ~1025 a tile | [M accbuf] |
| look-ahead: setup ~12 primitives; queue after run start ~150-200 pixels; ISP run queue ~512 runs | | [M]/[I] |
| span sorter window | 96 runs | [M] |
| sorter off: a run whose primitive is not among the ~16 set up costs a setup (44, +19 first time) | up to 4.6x | [M spansortcfg] |
| crowded lines (> ~12 triangles a line, opaque pass only) | runs up to 2x | [M], cause [G] |
| texture fetch: four 16-bit words a clock; words fetched for the pixel before do not count again | | [I] |
| first tile of a render with textures | +35 .. +455 once | [M], cache organisation unknown |

Datapath shape implied [I]: one pixel a clock through divider, address, fetch, decode, filter, shade, fog, blend;
per divided attribute a table reciprocal and a 16x17 multiplier; setup and run start share one multiply-add unit
(~4 products a clock); a 16-bit path per filter tap (a 32-bit texel in two steps).


## 22. GAP list (refsw3 behaviour no console test pins)

1. PARAM_BASE with bits below 20 set (TSP fetch base vs the ISP's).
2. Last-addition zero rule's upper limit 2^-125 vs 2^-124; the determinant-zero mean's zero rule in the last addition
   (the ISP's depth mean has its own rule in both additions, measured: isp §6.3, 4.4).
3. Mip K: DCalcCtrl 1 adder reach 53; "first vertex" of an odd strip triangle; perpendicular triangles; the -1-unit 1/w pixel.
4. Mipmapped texture declared taller than wide at large d with fraction bits.
5. TEXT_CONTROL stride 0; bank bit 4 / reads past 8 MB; a code book within 2 KB of 8 MB.
6. Index (or texel) reads into the framebuffer being written out (write-out timing).
7. Pixel format 7 (reserved); framebuffer packmode 7.
8. Untextured polygon with the ISP Offset bit (vertex fog would read `offsKept.a`).
9. `offsKept` with an all-zero setter; its power-off lifetime.
10. PT_ALPHA_REF bits above 7.
11. `tspAlphaStuck` with textures, autosort, other clearing events.
12. SupSample in the PT volume pass, translucent modvols, sprites, 16-bit UV, palette/YUV, RTT, DCalcCtrl with perspective.
13. Translucent modifier volumes and two-volume textured polygons in general ("Still not covered").
14. Render to texture formats 1555 / 4444.
15. Scaler factor 0; a stream begun before the first y = 0 tile with the field offset; strip buffer: one pixel, half-tile strips column order, strips with the scaler.
16. Not modelled at all (timing / clock): span sorter early drains and sort-off order, chunk carry races, secondary-buffer read races, empty keep Z collisions, the non-twiddled bilinear bump-map hang.


## 23. Test index (what each pins for the TSP)

| test | pins |
|---|---|
| uvmeas (31 sets, 23.6M), wmeas, cmeas, uvspan | plane setup, 16-bit coefficients, grid, run start, value format, reciprocal table, quotient cut, colour rounding, limits (wexp/whuge/wtiny/wneg/wspec/wzero), reach 25 (reach1, dump_*) |
| uvrun, volrun, optrun, optcull, ptruns, ptlayers | where runs start and end per pass; OpInPt; PT re-shading |
| planes | which values are perspective planes |
| halfofs, halfofs2, tspw | sample points; the TSP's own 1/w |
| slivers_*, perpmean_*, perpval, perpeq, detinf, hugepos | determinant zero / perpendicular / overflowing planes |
| shade | colour rounding |
| texfmt, sample, mip, mipbil, coordfix, texfar*, yuvbil, texctl* | texel formats, coordinates, addresses, filters |
| mipmeas, mipk..mipk5, mipdump, mipdet, trimin, ssmip | the mipmap level |
| env, alphatest, sprite, bump, bumpfn, bumpbil, bumpclamp, bumpiso, bumplight | shading instructions, bump mapping |
| fog, tspw, dumprules (vertex fog) | fog |
| supsample, supsample2, sscolor, ssvol, ssrare, sshalf, trifade | SupSample and the trilinear fade |
| offspersist | the kept offset colour |
| blend, blendsel, blendsel2, blendpos, accbuf, keepz | blend unit, tile buffers, stuck alpha, write-out per entry |
| fbpack, fb555, fb565, scalermeas, scalertile, sof2*, ycoeff | write-out formats, dither, scaler, clip, strip buffer |
| timemeas, spansortcfg | order and timing |
| polly2-data dumps (786 with a console frame, via polly2dumps.py) | everything together: all of video memory the console's |


## Appendix A: the reciprocal table's c digits (`RecipTable`, i = 0 .. 511, 64 a line)

    0111111111111111111111111011011111111111111110111101100100111111
    1110011111110011101011111111101111111110110111111111121010111111
    1011111111001111111111111101111101110101111111001111111111001101
    0111111111111111111210111110100101111111111001110001111111001111
    1111111111111011011110111001111210001111001111111122100011111111
    0110010110100011110100011111011110111111110100011111111121110001
    0111111111011111111111011111111111111211001110100110100111111111
    1011101101111111111110111010111110111111001100111111111111111110


## Appendix B: the bump map tables (`BM_HW_SIN`, `BM_HW_COS`, index 0 .. 255, 16 a line)

SIN:

      0,  2,  4,  6,  8, 10, 12, 14, 15, 17, 19, 21, 23, 25, 27, 29,
     29, 31, 33, 35, 37, 39, 41, 42, 43, 45, 47, 49, 50, 52, 54, 56,
     56, 58, 60, 62, 63, 65, 67, 69, 69, 71, 73, 74, 76, 78, 79, 81,
     81, 83, 85, 86, 88, 90, 91, 93, 93, 95, 96, 98, 99,101,102,104,
    104,106,107,109,110,112,113,115,115,117,118,120,121,122,124,125,
    125,127,128,130,131,132,134,135,135,137,138,139,140,142,143,144,
    144,146,147,148,149,151,152,153,153,154,156,157,158,159,160,161,
    161,163,164,165,166,167,168,169,169,170,171,172,173,174,175,176,
    177,178,179,180,181,182,183,184,186,187,188,189,190,191,192,193,
    194,195,196,197,198,199,200,200,202,203,204,205,205,206,207,208,
    209,210,211,212,212,213,214,215,216,217,218,218,219,220,220,221,
    222,223,224,224,225,226,226,227,228,229,229,230,230,231,231,232,
    233,234,234,235,235,236,236,237,238,239,239,240,240,240,241,241,
    242,243,243,244,244,244,245,245,246,247,247,247,247,248,248,248,
    249,250,250,250,250,251,251,251,252,252,253,253,253,253,253,253,
    254,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,

COS:

    255,255,255,255,255,255,255,255,254,254,254,254,254,254,254,254,
    252,252,252,252,252,252,252,251,250,250,250,250,249,249,249,249,
    247,247,247,247,246,246,246,246,244,244,244,243,243,243,242,242,
    240,240,240,239,239,239,238,238,236,236,235,235,234,234,233,233,
    231,231,230,230,229,229,228,228,226,226,225,225,224,223,223,222,
    220,220,219,219,218,217,217,216,214,214,213,212,211,211,210,209,
    207,207,206,205,204,204,203,202,200,199,199,198,197,196,195,194,
    192,192,191,190,189,188,187,186,184,183,182,181,180,179,178,177,
    176,175,174,173,172,171,170,169,169,168,167,166,165,164,163,162,
    161,160,159,158,157,156,155,153,153,152,151,150,148,147,146,145,
    144,143,142,141,139,138,137,136,135,134,133,131,130,129,127,126,
    125,124,123,121,120,119,117,116,115,114,112,111,109,108,106,105,
    104,103,101,100, 98, 97, 95, 94, 93, 92, 90, 89, 87, 85, 84, 82,
     81, 80, 78, 77, 75, 73, 72, 70, 69, 68, 66, 64, 62, 61, 59, 57,
     56, 55, 53, 51, 49, 48, 46, 44, 43, 41, 40, 38, 36, 34, 32, 30,
     29, 28, 26, 24, 22, 20, 18, 16, 15, 13, 11,  9,  7,  5,  3,  1,

SIN[0] may be 0 or 1 and COS[255] 0, 1 or 2: no light can show which [bumpfn].
