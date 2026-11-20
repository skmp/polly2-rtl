# Numerics: the setup units' arithmetic and the RTL's primitives

polly2-rtl specification, role spec-numerics, 2026-11-20; re-transcribed for refsw3 `708fb8cd` the same day (role
spec refresh). Basis of the first RTL milestone: the arithmetic primitives, each verified in lockstep against the
refsw3 function it implements.

**Reference (functional truth).** nulldc3 branch `skmp/refsw3` at `708fb8cd` (clean tree), folder
`refsw3/refcore/`: `pvr_softfp.h`, `pvr_bits.h` and their users `pvr_isp_edge.h`, `pvr_isp_depth.h`,
`pvr_tsp_plane.h`, `refsw_tile.h`, `refsw_tile.cpp`, `refsw_lists.cpp`. Every line number in this document refers
to that commit. The first transcription was at `2d08a440`. Two commits changed the arithmetic since: `6784ea3d` (the
edge unit at 2^128: the swamp, the walk of a big edge) and `708fb8cd` (the depth unit: the 64-bit stored-depth key,
the zero rule, the limit at every operation, the mean's infinities, `pvrfp::OneThird`). They rewrote sections 0,
1.2-1.4, 2.6, 2.12, 3, 4, 5.1, 5.2, 5.5, H7a, H9-H12, H14, 7 and 8; elsewhere only line numbers moved
(`pvr_softfp.h` +11 from L326, `pvr_tsp_plane.h` -2 from L249, `refsw_tile.cpp` +22 from L836, `refsw_lists.cpp` +8
from L615). **Evidence:** dreamcast-tests at `b54c934`, `README.md` (the section is named with each rule; the edge
and depth rules of `708fb8cd` are in "refsw3 without float: the number formats at their edges") and `TODO.md`.

**Scope.** This document covers every number format and arithmetic operation of the CORE's setup and evaluation
units as bit-level rules: what the RTL primitives must compute, at which widths, with which operand order and
special values. The unit algorithms are in the sibling specifications: `docs/spec/isp.md` (sections 6 to 9: edge,
depth, stored depth) and `docs/spec/tsp.md` (sections 4 to 8 and 15: planes, evaluator, divider, colour, mip, fog).
This document covers them only as far as they fix an operation's widths (section 5). Latency and pipelining belong to
the timing specification.

**Notation.**

- `BL(m)`: the bit length of an unsigned integer, 0 for 0 (`pvrfp::BitLength`).
- `top(x) = x.exp + BL(x.mant)`, so `|x|` is in `[2^(top-1), 2^top)`: frexp's exponent. The IEEE unbiased exponent
  is `top - 1`. A normal single with exponent field `f` has `top = f - 126`.
- `cut_N`: keep the N most significant bits of a magnitude and drop the rest, toward zero (`Fp::cut`).
- floor: toward minus infinity. trunc: toward zero. RNE: to nearest, ties to even.
- Sizes are magnitudes: "≥ 2^128" means `|value| >= 2^128`.
- **GAP**: nothing measured on a console. **ARTIFACT**: the reference does this because of how it is written, not
  because a measurement showed it. The RTL reproduces it so that lockstep holds, and section 8 lists it for the
  owner. **DEFECT**: the reference is undefined there.
- **HW configuration**: `EdgeHW`, `DepthHW`, `PlaneHW` as committed, with the environment variables `MIP_K` and
  `MIP_ARITH` unset (the experiments they select are not hardware).

---

## 0. The short version

1. A number is `{neg, bad, exp, mant}` and means `(-1)^neg * mant * 2^exp`. `mant` is an unsigned integer and is
   **not normalized**. `exp` is the exponent of bit 0 of `mant`. A zero (`mant == 0`) keeps a sign. `bad` flags
   an infinity or a NaN. A bad number's `mant` is 0, so outside the range wrappers it acts as a zero of its sign
   that carries a flag.
2. Every operation computes the exact result and then truncates it toward zero to N significant bits. A result
   that already has N bits or fewer is left as it is, not normalized. HW widths: **24** in every setup operation,
   **20** for the edge and depth starts and slopes, **16** for the TSP coefficients and the plane value, **19**
   for a stored depth, **8** in the mip level, **17** for the TSP quotient.
3. The adder aligns both operands to the smaller LSB exponent and adds exactly. An operand whose `top` is `R` or
   more below the other's is **dropped**, so it causes no borrow. HW reach: **25** in the ISP and TSP setup;
   **53** at one TSP mip site (GAP G1). The "wide" calls (`N = 62`, `R = 200/400`) are **not** exact: they drop the
   operand whose LSB exponent is more than **90** below the other's, and they truncate the sum to 62 bits
   (ARTIFACT A1). This depends on the representation, so the RTL carries the reference's tuple exactly.
4. The setup reciprocal is the exact `1/x` truncated to 24 bits.
5. Range rules apply in the ISP depth setup and the TSP setup, **not** in the edge unit: a result of 2^128 or more
   is an infinity; one below 2^-126 is a zero; input field 0 is zero and field 255 is infinity; `inf * 0 = 0`;
   `inf - inf = +0`; a sum below the range is `+0`; the TSP's last addition has a rule for zero operands, and every
   addition of the depth setup has its own (a zero added to [2^-126, 1.5 * 2^-126) of the other sign is `+0`, every
   zero sum is `+0`). The edge unit instead **swamps**: a product or sum of 2^128 or more becomes ±2^200, which drops
   every finite operand of the adds, and the start and the steps saturate to ±2^127.
6. The TSP divider is a 16-bit table reciprocal (512 entries of `(t, n)` and a 6-bit linear step), times the
   numerator, floored at 17 fractional bits. A negative denominator is read with its 15 bits under the leading one
   negated.
7. The minimal hardware set is H1 to H15 (section 6). The tests are in section 7, and the GAPs, artifacts and the
   two defects are in section 8 (D1: refsw3 divides by zero in `MipSelect` on a determinant-zero triangle; D2: the
   depth zero rule's shift by -1 at a one-bit mantissa).
8. A stored depth is not a float word: it is a 64-bit order key, the word's order 32 bits finer, with places for
   negative depths outside their block's top binade and for positive ones from 2^128 (H14).

---

## 1. The number

### 1.1 Fields

| field | C++ | meaning | RTL |
|---|---|---|---|
| `neg` | `bool` | sign; a zero has one too | 1 bit |
| `bad` | `bool` | the value came from an infinity or a NaN (the caller decides what that means) | 1 bit |
| `exp` | `int32_t` | exponent of bit 0 of `mant` | 10-bit two's complement (section 1.4) |
| `mant` | `uint64_t` | magnitude, unnormalized | per site: 24 (setup), 16 or 17 (TSP plane value, numerator), 18 (TSP quotient), 19 or 20 (depth), 8 (mip), 62 or 64 at the wide sites |

`value = (neg ? -1 : 1) * mant * 2^exp`. The number is zero when `mant == 0`. A zero's `exp` is never read by any
operation, and the testbenches do not compare it. `top` of a zero is `NoExp = -1000000`, which counts as minus
infinity in every max().

`bad` is produced by:

- `FromBits` and `FromSingle` (exponent field 255);
- the range wrappers' `inf()` (overflow, or an infinity operand);
- the OR of the operands in `Mul`, `Add` and `Recip`.

Wherever a bad value is produced, its `mant` is 0. `FromBits` sets 0, `FromSingle` and `inf()` leave the default
0, and a product with a 0 mantissa is 0. In the unranged `Add`, a bad operand is therefore treated as a zero: the
result is the other operand's value with `bad` set. Example: `Winding`'s `det` of a triangle with a NaN corner is
the sum of the finite parts, flagged. So a bad result **can** have a nonzero `mant`, and the testbenches compare
`mant` and `exp` of bad results too.

The sign of a bad value depends on its source. `FromBits` clears it (unsigned infinity). `FromSingle` and the
range wrappers keep it.

The comment on `Fp::mant` ("at most 32 bits after any operation here", `pvr_softfp.h` L112) is out of date. It holds
for `N <= 32`; the 62-bit calls return up to 62 bits.

### 1.2 Zeros and their signs

| operation | sign of a zero result |
|---|---|
| `Mul` | `a.neg xor b.neg`, always (also for `0 * x`) |
| `Add`: both operands zero | negative only if both are: `a.neg and b.neg` |
| `Add`: one operand zero | the other operand, unchanged |
| `Add`: exact cancellation | `+0` |
| `Sub(a, b) = Add(a, -b)` | `(+0) - (+0) = +0`, `(-0) - (+0) = -0`, `x - x = +0` |
| `cutBelow` to nothing | the sign is kept: `-0` |
| `cut` | never produces a zero from a nonzero |
| `Recip` | the operand's sign (and it is never zero) |
| `FromBits` / `FromSingle` | the sign bit |
| range wrappers | a product below 2^-126 keeps `xor`; a **sum** below 2^-126 becomes **+0**; in the depth setup **every** zero sum is +0 (also `-0 + -0`) |
| TSP `Value` (k = 0), `Divide` (numerator 0) | `+0` |

**Who looks at the sign of a zero.**

- The TSP evaluator, in two ways. `FloorUnits(-0) = -1`, one grid unit below zero (uvmeas point 5: on a triangle
  with a negative determinant a flat plane steps one unit down per pixel; this is the 60 % of flat triangles that
  read one fog level low in wmeas). `seen(+-0) = +-2^-127`.
- The ISP depth setup's adder: its zero rule (section 4.1) compares the zero's sign with the other operand's, and a
  product below 2^-126 keeps its sign for that.
- Otherwise the ISP edge and depth units do not: `unitsAt()` and `FloorScaled` return 0 for either zero, and a
  stored depth of -0 has key 0.

That makes three zero conventions among the float-to-integer converters (H11).

### 1.3 The representation contract

The value does not determine the tuple. For example, 2^64 can be `{mant 1, exp 64}` or `{mant 0x800000, exp 41}`.
The operations keep whatever representation falls out of them. Nothing left-normalizes; only `cut` shortens a
mantissa, and only when it has more than N bits.

Almost every operation depends only on the value. One does not: the window rule of the wide `Add` (section 2.8,
case W). It compares the LSB exponents. A scratch run against the refcore headers
(`polly2-rtl/agents/spec-numerics/probe.cpp`) gives:

    Add(2^132, -{mant 1, exp 64}, 62, 400).cut(20)         = 0xFFFFF * 2^112      (exact 2^132 - 2^64, cut)
    Add(2^132, -{mant 0x800000, exp 41}, 62, 400).cut(20)  = 1 * 2^132            (2^64 dropped)

**Contract.** Each RTL primitive returns exactly the reference's tuple `(neg, bad, exp, mant)`. `exp` is compared
only when `mant != 0`. This costs nothing beyond what a truncating datapath does anyway, because the reference's
output exponent is always

    out.exp = max(L, top(result) - N)          out.mant = |result| / 2^out.exp   (exact, by construction)

where `L` is the operation's natural LSB exponent:

| source | `L` |
|---|---|
| `Mul` | `x.exp + y.exp` |
| `Add` | `min(x.exp, y.exp)` |
| `FromBits` / `FromSingle` | `field - 150`, or -149 for a denormal |
| `FromHalves` | -1 |
| `Pow2(e)` | `e` |

A datapath that normalizes internally must recompute `out.exp` with this formula. The contract matters at two
sites (TSP L368, mip L642; see H7; the third, the edge start's wide add, went with `6784ea3d`). It is imposed
everywhere so that every primitive's output can feed those sites.

### 1.4 Ranges and RTL field widths

The bounds below are derived from the code, not measured (GAP G11). The testbenches assert that every reference
`exp` fits before packing it.

| where | LSB `exp` range | `top` range | why |
|---|---|---|---|
| edge unit (unranged, `FromBits`) | ≥ -298 | ≤ 259 | denormal × denormal = 2^-298; `x y` products ≤ 2^256 before the swamp (H7a), which leaves ≤ 2^201 in `c`, `first`, the start's sum and `EdgeWinding`'s det (the swamp value 2^200, two of them added); `Winding`'s plain det (only its bad flag is used) ≤ 2^259; `dx` ≤ 2^129 before `sat`; `Mul(swamp(dx), y0)` ≤ 2^213; the start ≤ 2^127 after `sat` |
| depth setup (ranged) | ≥ -150 after range | ≤ 128 | numbers in [2^-126, 2^128) |
| depth `Recip`, `A`, `B` and the REG steps (unranged) | ≥ -278 | ≤ 255 | `inv` in (2^-128, 2^126]; `a * inv` up to 2^255; `under()` only zeroes small values; the start `first0` is ranged (since `708fb8cd`), `C` feeds nothing |
| depth block `tu`, REG `r` (integers) | | | `tu` ≤ 54 bits in half units of 2^unit, `t` < 2^29 in half-G units (H12b); `r` 30 bits |
| TSP setup (ranged) | ≥ -150 | ≤ 128 | as depth |
| TSP `Value` | ≥ -149 | ≤ 142 | `e` ≤ 139 (a coefficient below 2^128 times a coordinate below 2^12), `unit = e - 22` ≥ -149; the normalizer's -128 floor and -2^-143 |
| TSP `Divide` | -300 .. 253 | ≤ 271 | `en + 1 - ed - 17` with `en` in [-142, 142] and `ed` in [-127, 142]; the README's largest observed quotient is about 2^243 (texfar_quot) |
| mip | within the above | | K, w, w·w have explicit clamps (H10, `tsp.md` 8) |

**Exponent field: 10 bits, two's complement (-512 .. 511).** Every reachable value lies in -300 .. 259.

**Mantissa widths.** At every HW-path input of a 24-bit operation the mantissa has **24 bits or fewer**. The
inputs are `FromBits` / `FromSingle` (24), outputs of 24-bit operations, `FromHalves` (≤ 13 bits for screen
coordinates up to 2^12), `Pow2` and the 24-bit constants. So the `cut_32` that `Mul` and `Add` apply to their
inputs (L345, L368) never does anything in the HW configuration. The RTL does not implement it, and the
testbenches assert it.

---

## 2. `pvr_bits.h` and `pvr_softfp.h`, operation by operation

### 2.1 `BitLength`, `TrailingZeros` (`pvr_bits.h` L13, L31)

- `BitLength(v)` = `64 - clz(v)`, 0 for 0. In hardware this is a priority encoder (H1) of the width of the
  operand: 16, 17, 24, 25, 34, 50, 64, 108 or 128 bits at the sites below.
- `TrailingZeros(v)` (v ≠ 0) = `ctz(v)`. It is used only by `FromDouble` (host only) and by `TextureFilter`'s
  `log2` of a texture size, which is a power of two (`refsw_tile.cpp` L1339: a decoder of `TexU` / `TexV`, not
  arithmetic). It also appears in refta, which is outside refcore. **No HW primitive.**

### 2.2 `operator-` (L122)

Flips `neg`, also for a zero and for a bad value.

### 2.3 `cut(N)` (L125)

```
n = BL(mant)
if n > N:  mant >>= (n - N);  exp += (n - N)       // truncation of the magnitude
// neg, bad unchanged; a zero is unchanged; never produces a zero
```

### 2.4 `cutBelow(e)` (L138)

```
if mant != 0 and exp < e:
    s = e - exp
    mant = (s >= 64) ? 0 : mant >> s                // truncation of the magnitude
    exp  = e
// neg is kept: a negative value cut to nothing is -0
```

### 2.5 Inputs and constants

**`FromBits(u)`** (L178): `f = u[30:23]`, `m = u[22:0]`.

- `f == 255`: `{neg 0, bad 1, mant 0}`. An infinity or NaN, **unsigned**.
- `f == 0`: `{neg u[31], mant m, exp -149}`. A denormal kept as it is, unnormalized; `m = 0` gives +-0.
- otherwise: `{neg u[31], mant 0x800000 | m, exp f - 150}`.

It is used for:

- the edge unit's vertex `x`, `y` (`refsw_tile.cpp` L748-749 for culling, L771-772 for drawing);
- `FPU_CULL_VAL & 0x7fffffff` (0x078, L730);
- `FPU_PERP_VAL & 0x7fffffff` (0x084, `refsw_lists.cpp` L378).

**`FromSingle(u, ranged)`** (L161): with `ranged = 0` it is `FromBits`. With `ranged = 1` (every HW use):

- `neg = u[31]`.
- `f == 255`: `bad`, `mant 0`, **sign kept**.
- `f == 0`: +-0, the fraction ignored.
- otherwise: as `FromBits`.

It is used for:

- the depth setup's `x, y, z` (`pvr_isp_depth.h` L323);
- the TSP setup's `x, y, z` and attributes (`pvr_tsp_plane.h` L149);
- `MipSelect` with DCalcCtrl 1: `u1, v1, z1, x1, y1` (L698).

[uvmeas wexp, whuge, wtiny, wspec: "field 0 is zero, 255 infinity, whatever the mantissa says"]

**`FromHalves(k)`** (L198): `{neg k < 0, mant |k|, exp -1}`, which is `k / 2`, exact, with trailing zeros kept.
The `k` at the HW sites:

- `2·left + HALF_OFFSET[0]` and `2·top + HALF_OFFSET[0]` (edge);
- `2·left + 1` and `2·top + 1` (depth, always the centres);
- `2·(left + i) + c` (depth float form, unreachable: A3);
- `2·(left + SpanStart) + h` and `2·(top + y) + h` (TSP);
- `2·(tile + 16)` (TSP grid);
- `2·biasQuarters`, `2` (one), `1` (one half).

**`Pow2(e, neg)`** (L227): `{mant 1, exp e}`.

**`SingleBits(v, e)`** (L274): the bits of the IEEE single `v · 2^e`, for an integer `v` in [0, 2^24) and a
normal result.

```
v == 0: 0x00000000
n = BL(v); return (e + n - 1 + 127) << 23 | ((v << (24 - n)) & 0x7fffff)
```

The HW site is the colours: `v` = an 8-bit channel, `e = -8` (`refsw_tile.h` L90, `ColorExp`). The setup then reads
the word back with `FromSingle(., 1)`, so a colour `c` enters the planes as exactly `c · 2^-8`.
[cmeas cwext1: 2,333,331 of 2,340,000 with 2^-8 against 1,688,587 with 2^-7 and 2,124,860 with 2^-9 (all of
them once the last-addition rule was in)]

**Host only, no HW:** `FromFloat`, `FromDouble`, `toDouble`, the `i128` / `u128` structs.

### 2.6 `atLeastPow2(e)` (L247)

`mant != 0 && top > e`, that is `|v| >= 2^e`. It is used by the edge unit's swamp and saturation, every one at
`>= 2^128` (H7a: edge L113 in `EdgeWinding`; L181, L190-191, L196 in `EdgeTile::Setup`). `2d08a440`'s `|dy| >=
2^127` test is gone.

### 2.7 `Mul(a, b, N)` (L341)

```
bad = a.bad | b.bad;   neg = a.neg ^ b.neg
x = cut_32(a);  y = cut_32(b)                    // no-op at every HW site (<= 24-bit operands)
mant = x.mant * y.mant                           // exact, <= 64 bits
exp  = x.exp + y.exp
return cut_N(that)                               // = trunc_N(a*b), out.exp = max(x.exp+y.exp, top - N)
```

`Mul` is commutative and has no range rules. A zero product is signed (xor).

### 2.8 `Add(a, b, N, R, G = -1)` (L358) and `Sub(a, b, N, R) = Add(a, -b, N, R)` (L402)

The cases are evaluated in this order:

```
bad = a.bad | b.bad                                   // carried by every return except case W
1. a.mant == 0 and b.mant == 0:  return {neg: a.neg & b.neg, mant 0, exp 0, bad}
2. b.mant == 0:                  return cut_N(a), bad          // also: b bad (mant 0) -> a's value, flagged
3. a.mant == 0:                  return cut_N(b), bad
4. ta = top(a), tb = top(b)
   ta - tb >= R:                 return cut_N(a), bad          // b DROPPED: no carry, no borrow
   tb - ta >= R:                 return cut_N(b), bad          // a DROPPED
5. x = cut_32(a), y = cut_32(b)                                // no-op at every HW site
6. (G >= 0 only: guard bits; no HW instance, see below)
7. e = min(x.exp, y.exp);  sx = x.exp - e;  sy = y.exp - e
W. if sx > 90 or sy > 90:        return cut_N(ta > tb ? a : b) with bad = that operand's bad only
8. S = (x.neg ? -1 : 1)(x.mant << sx) + (y.neg ? -1 : 1)(y.mant << sy)     // exact, two's complement
   neg = S < 0;  M = |S|
   if BL(M) > 64:  M >>= BL(M) - 64;  e += BL(M) - 64           // truncation to 64 significant bits
   if M == 0:      return {neg 0, mant 0, exp e, bad}          // exact cancellation: +0
   return cut_N({neg, M, e}), bad
```

What the cases mean in hardware:

- **Reach (case 4).** With 24-bit operands and `R = 25`, a dropped operand lies wholly below the larger operand's
  last kept bit. A drop is therefore invisible for operands of the same sign. For operands of opposite sign it
  suppresses the borrow: the result is the larger operand itself, where exact-then-cut would give the larger minus
  one unit of its 24th bit (or 0xFFFFFF one exponent lower, when the larger is a power of two). This is the
  measured effect: covmeas point 3 (the first tile column and row, where `x0` or `y0` is 0.5 and its product tiny)
  and uvmeas reach1.
- **The exact window (case 8).** For `|ta - tb| < R` the sum spans at most `(R - 1) + 24 + 1` bits: **49 bits**
  for `R = 25` and 77 for `R = 53`. The 64-bit truncation is reachable for `R >= 41`. At the `R = 53` site the
  result is cut to 24 bits immediately, and successive truncations toward zero compose
  (`cut_24(cut_64(S)) = cut_24(S)`), so there it changes nothing.
- **Window rule (case W), ARTIFACT A1.** `|sx - sy| = |(ta - tb) - (BL(x) - BL(y))| <= (R - 1) + 31`, so case W is
  reachable only for `R >= 61`. That means only the wide calls with `R` of 200 or 400: TSP L368 and mip L642 (the edge
  unit's L137 of `2d08a440` is gone). Case W depends on the representation (section 1.3). When `ta == tb` it returns
  `b`, but that tie is unreachable because equal tops put the exponents within 31 of each other.
- **Guard `G` (step 6):** `if G >= 0`, the smaller operand is first `cutBelow(top(larger) - N - G)`. No HW
  instance uses it: `EdgeHW::guard = C<-1>` (the README covmeas point 3 says "otherwise the sum is exact before the
  cut, as with a sticky bit"), and every other call takes the default -1. **Do not implement it.**
- **Commutativity.** `Add` is commutative at every HW site; the only asymmetry is case W's unreachable tie. The
  **order of a three-term sum is not free** (24-bit truncation and the reach make it observable). Section 5 gives
  the order for every sum.

### 2.9 `Recip(v, N)` (L406)

```
d = cut_32(v);  nb = BL(d.mant);  sh = nb + N + 2          // sh <= 58
mant = floor(2^sh / d.mant)                                // N + 2 or N + 3 bits
exp  = -sh - d.exp;  neg = v.neg;  bad = v.bad
return cut_N(that)
```

The equivalent for hardware with `N = 24`, the only HW width:

```
dn = d.mant << (24 - nb)          // [2^23, 2^24)
ev = d.exp - (24 - nb)
dn == 2^23:  {mant 2^23,              exp -46 - ev}         // 1/v exact (a power of two)
otherwise:   {mant floor(2^47 / dn),  exp -47 - ev}         // 24 significant bits, bit 23 set
```

So `Recip(v, 24)` is `trunc_24(1/v)`, a floor of a floor. The result always has exactly 24 significant bits. The
value is independent of the representation (the trailing zeros cancel in the division). **Undefined for
`v == 0`** (an integer division by zero): see DEFECT D1.

### 2.10 `FloorScaled(v, shift)` (L251)

```
v == 0 (either sign):     0
top(v) + shift > 40:      v.neg ? -2^40 : 2^40
otherwise:                floor(v * 2^shift)     // exact; a negative with a fraction goes one further from zero
```

`v` must be finite; the caller has already returned on a bad corner (`refsw_tile.cpp` L781). The only site is
`RowRange` (edge L131): `floor(y)` and `(floor(2y) + 1) >> 1 = floor(y + 1/2)` with an arithmetic shift.
[covmeas mix sliver: the console cuts a sliver's rows to floor(ymin) .. floor(ymax + 1/2)]

### 2.11 `AbsAtMost(a, b)`, `AtMost(a, b)` (L283, L295)

```
AbsAtMost(a, b):                   // |a| <= |b|; a finite
  b.bad or a.mant == 0:  true      // a bad a (mant 0) counts as a zero
  b.mant == 0:           false
  top(a) != top(b):      top(a) < top(b)
  otherwise:             left-justified mantissas, a <= b
AtMost(a, b):                      // a <= b, both finite, a zero of either sign is zero
  an = a.neg and a != 0;  bn = b.neg and b != 0
  an != bn:              an
  an:                    AbsAtMost(b, a)
  otherwise:             AbsAtMost(a, b)
```

Both are exact and independent of the representation.

### 2.12 `perpVal`, `Perpendicular` (L311, L319); `CulledBySize`, `CulledByFacing` (`refsw_tile.cpp` L722, L734)

```
perpVal = FromBits(FPU_PERP_VAL & 0x7fffffff)                  // once per render (refsw_lists.cpp L377-378)
Perpendicular(det):            // det = the ranged setup's determinant (depth L382, TSP L214)
  det == 0 and not bad:  false                         // a zero is one already
  det.bad:               perpVal.bad                   // an infinite FPU_PERP_VAL takes an infinite det
  otherwise:             (perpVal.bad or perpVal != 0) and AbsAtMost(det, perpVal)
```

[perpval: 136,764 pixels the console changes at 2^20, all exact; perpeq: a determinant equal to the register counts,
1800 of 1800; detinf, perpval with 0x7fc00000, 0xffc00000, 0xff800000, 0x7f800001: every NaN and -infinity acts as
+infinity]

```
CulledBySize(det):             // det = the edge unit's EdgeWinding determinant: unranged, swamped (H7a)
  det.bad:                         false
  size = FPU_CULL_VAL & 0x7fffffff
  size >= 0x7f800000:              true                // infinity or any NaN culls every triangle
  otherwise:                       AbsAtMost(det, FromBits(size))   // equal is culled; a denormal register is kept
CulledByFacing(mode, det):
  mode < 2 or det.bad or det == 0: false
  otherwise:                       (mode & 1) ? !det.neg : det.neg
```

[cullval: only the register's size counts, every NaN culls like +infinity, 2^-149 culls nothing, 4800 of 4800
regions; raster page 4: equal is culled; faredge_cull: the swamped determinant's size and sign, 1,200 of 1,200
regions (the plain one: 484 wrong). A swamped determinant (±2^200) is never culled by size, one whose swamped
products cancel to +0 always is]

---

## 3. The configurations

All three are `struct`s of `pvrfp::C<N>` (`std::integral_constant<int, N>`) in the HW form. The `...Config`
twins are plain `int`s for the probes and have the same defaults; the code is templated on either. The evidence
column gives the test and what it showed. Where the dreamcast-tests probes scanned a parameter one step either
way, the numbers are pixels or readings wrong: with the measured value they are 0.

### 3.1 `EdgeHW` (`pvr_isp_edge.h` L41)

Evidence: covmeas (98 archived sets, 0 differences), hugepos, and for the last four rows faredge (1,340 of 1,340)
with its sets faredge_cmax, _k132, _m131, _ecap, _walk, _cull, _far32. The scan is `model/covprobe --scan` summed over
30 runs, from the README section "model: one implementation in soft floating point".

| constant | value | use | evidence |
|---|---|---|---|
| `productBits` | 24 | every product: `x y`, `dx y0`, `dy x0` | 23: 142,797, 25: 110,672 |
| `sumBits` | 24 | every add | 23: 28,770, 25: 13,698 |
| `reach` | 25 | adder alignment reach | 23: 1023, 24: 92, 26: 160, 27: 314 |
| `guard` | -1 | none: exact before the cut | covmeas point 3 |
| `startBits` | 20 | start kept per tile | 19: 16,830, 21: 7035 |
| `slopeBits` | 20 | steps | covmeas point 4 |
| `pairBits` | 21 | both steps on a grid 21 bits under the larger | 20: 3729, 22: 875 |
| `blockAdd` | 6 | `E = top(larger step) + 6` | 5: 37,105, 7: 70,706 |
| `startAdd` | 1 | ... or `top(start) + 1` if larger | covmeas point 4 |
| `zeroShift` | 21 | ZERO: `abs(v) <= 2^(E - 21)` | 20: 67,669, 22: 51,964 |
| `tieShift` | 21 | column step counts as zero for a row starting at zero | 20: 2730, 22: 3137 |
| `overflowExp` | 128 | a product or sum of the start (and of `EdgeWinding`'s determinant) that reaches 2^128 swamps: ±2^200 (H7a) | faredge_cmax 4,800 of 4,800 tiles (755 with a product of exactly 2^128), faredge_k132, faredge_m131 / _cull for the determinant |
| `saturateExp` | 127 | the start then saturates to ±2^127; a coordinate difference of 2^128 or more steps as ±2^127 | hugepos (triangle a at 2^118 .. 2^124, the console's pixels exactly); hugepos_v4, _v5, _v6 (as an infinite step: 68,397 / 67,565 pixels wrong) |
| `lastColumnByStep` | true | a zero pixel in column 31 goes by the column step's sign | 0: 246 |
| `blockMax` | 129 | E at most 129; an edge whose E was cut (`ep >= 124`, a step of 2^123 or more) is walked (`isp.md` 8.4b) | faredge_ecap: 129 all of 1,440 edges, 130: 1,424 wrong, 131, 132 or none: 1,440; faredge_m131 (134: 1,165 of 1,800 tiles wrong) |
| `walkExp` | 131 | the walk holds R and R + 16 sx in [-2^131, 2^131) (mod 2^132), and 32 sx below 2^131 | faredge_walk 3,537 tiles; faredge_m131 pages 0-5 (-2^131 not pushed, +2^131 pushed); faredge_k132 group K; hugepos_rules pages 0-3 (the wrap) |

### 3.2 `DepthHW` (`pvr_isp_depth.h` L41)

Evidence: zmeas (13 sets, 89,801 brackets, 0 missed), zstart, covmeas zprobe, perpmean_*. The scan is
`model/depthprobe`, one step off each way.

| constant | value | use | evidence |
|---|---|---|---|
| `productBits` | 24 | `z * diff`, `z * e`, `a x0`, `b y0` | 23 / 25: 4330 / 3734 |
| `sumBits` | 24 | | 23 / 25: 3480 / 2460 |
| `reach` | 25 | taken from the edge unit | reach ≥ 24 changes nothing on the depth data (20: 673); not measured on the depth unit itself |
| `recipBits` | 24 | `1 / det` | 23 / 25: 206 / 78 |
| `coefBits` | 24 | `a*inv`, `b*inv` (and `c*inv`, which feeds nothing); the REG steps' `a*inv`, `b*inv` | not visible through the block path or the REG steps (each value is cut to 20 next, and cuts compose); the mean's product with 1/3 is `mul` at `productBits` (perpmean_word: the mean cut to 24 then 20) |
| `startBits` | 20 | tile start; the REG start; a negative flat depth's (mean, background) first cut | 19 / 21: 1137 / 594; depthgaps_detneg, depthgaps_rcut |
| `slopeBits` | 20 | `A`, `B` steps; the REG steps | zmeas 3; zovf_creg (the 20 bits of a REG step) |
| `pairBits` | 21 | the steps' shared grid | 20 / 22: 187 / 41 |
| `tileBits` | 26 | grid 26 bits under the start's exponent | 25 / 27: 472 / 232 |
| `storedBits` | 19 | stored depth above zero (and `Big`'s grid, GAP G6) | zmeas, zblock, precision |
| `startOnSlopes` | 1 | the start is cut to the slopes' grid too | zstart 49,152 of 49,152 (0 is the old model; 2 keeps only negative starts cut) |
| `range` | 1 | range rules and the zero rule (section 4) | zovf_lim 4,984 of 4,984, zovf_c, zovf_ps, zovf_sum, zovf_far, zovf_ab; huge 250 of 250 regions (228 without); zspec 1040 of 1040; depthgaps_zadd 109 of 109, depthgaps_field1 2,000 of 2,000; GAP G7 |

`2d08a440`'s `storedNegBits` (16) is gone: a depth below zero is stored by H14 `neg`, whose window holds the 16 bits.

### 3.3 `PlaneHW` (`pvr_tsp_plane.h` L39)

Evidence: uvmeas (31 sets, 23,640,053 readings), wmeas (2,320,996), cmeas (3 sets), all reproduced.

| constant | value | use | evidence |
|---|---|---|---|
| `productBits`, `sumBits` | 24, 24 | setup | wmeas: flat full-cell quads read the 16-bit truncation of the 24-bit setup's constant, 1600 of 1600; ops second run: the console sides with the model on every case of 167 alternatives |
| `reach` | 25 | setup adders | uvmeas reach1 (`model/reachgen`, 1760 triangles, 95,453 readings): 24 misses 554, 26 misses 785; gundam_ingame |
| `recipBits` | 24 | `1 / det` | ops second run; mipk5 / mipdump pin the 24-bit reciprocal for the mip numerators |
| `coefBits` | 16 | `A, B, C` | uvmeas point 1 (a flat U of 24 bits reads as its 16-bit truncation at every size 1 .. 2^22); ops first run (16 against 14, 15, 17, 18) |
| `gridBits` | 22 | the evaluator's grid under `E` | uvspan rule 2 (every uvmeas, wmeas, cmeas set exact) |
| `valueBits` | 16 | the plane value | uvmeas point 3 |
| `range`, `expLow`, `expHigh` | 1, -126, 127 | range rules | uvmeas wexp, whuge, wtiny, wspec, wneg (780,000 each), wzero1, wzero2; cmeas cwext1 |
| `zeroReach` | 2 | last-addition zero rule: operand top-1 < -125 | wtiny1 5 cells, cwext1 21 cells, cwsum1 2,340,000 of 2,340,000 (2,318,225 without it); 2 or 3 not told apart: GAP G2 |

These `PlaneHW` constants select experiments; the HW value is 0 and the experiments are not to be implemented:

| constant | what the HW value 0 means | the alternatives (readings wrong on the uvmeas sets) |
|---|---|---|
| `valueFixed` | 16 bits are taken from the value's leading one | dropping 1 .. 8 fixed low bits: 30,852 .. 13,321,784 |
| `tileLocal` | screen coordinates | 15,801 / 1,277,606 / 111,580 |
| `macOrder` | each term is floored on its own | 3,445 / 32,716 / 512,221 |
| `sumA`, `sumW` | `(t0 + t1) + t2` | uvmeas point 6: 2400 of 2400 against 2377; `sumA = 2` misses 22,582 of ugen5 |

`MipSelect`'s environment switches are not hardware either: `MIP_K` (1, 98, 99) and `MIP_ARITH` (1, 2, 4, 5, 6).

### 3.4 Literal widths at call sites (plain `int`, the same semantics)

| literal | where | meaning |
|---|---|---|
| `N = 62, R = 400` | TSP L265, L368 (L331, L341: experiments) | "wide": window 90, truncation to 62 bits (A1) |
| `N = 62, R = 200` | mip L642, L653, L676, L734 | the same; L653 and L734 are dead in the HW config (section 5.3), L676 is MIP_K 1 |
| `N = 62, R = 25` | mip L686, L687, followed by `.cut(24)` | identical to `Add(., 24, 25)` (checked: 4,000,000 random pairs, 0 differences) |
| `N = 24, R = 53` | mip L726 (`radd`, DCalcCtrl 1) | the TSP reach before reach1; GAP G1 |
| `Mul(., ., 62)` | TSP L326, L363; mip L646, L674, L686, L759 | exact for these operand widths (≤ 48 bits) |
| `Mul(., ., 24)`, `Recip(., 24)` | mip L610, L619, L623, L641, L706, L745 | literal 24 = `PlaneHW` widths |
| `Mul(., ., 8)`, `.cut(8)` | mip L762, L773, L779, L782 | 8-bit mip arithmetic |
| `Pow2(OE + 72)`, `Pow2(saturateExp)` | edge L113, L181; L190-191, L197 | the swamp value 2^200 and the saturation 2^127 (H7a) |
| `.cut(slopeBits).cutBelow(102)`, `cut(startBits)` onto 2^102 | depth L436, L479-482 | the REG steps and start (H11) |

### 3.5 Constants

| constant | value | site | evidence |
|---|---|---|---|
| 1/3, rounded up | `0xAAAAAB * 2^-25` (`0x3EAAAAAB`) | `pvrfp::OneThird()` (softfp L331): depth mean L569, TSP flat L246 | perpmean_word 16,384 of 16,384 (0xAAAAAA: 1,618 wrong); slivers_detzero 9,600 of 9,600 (0xAAAAAA: 8,143); perpmean_uv 8,192 |
| 2 - sqrt(2), less 8 units | `0x95F612 * 2^-24` (`0x3F15F612`) | mip L684 | mipk4 / mipk3 lenfit 3,920 cells, mipk2 2,401 of 2,401 |
| edge swamp value | `±2^200` (`{mant 1, exp 200}`) | edge L113, L181 | faredge_cmax, faredge_k132 (any value beyond every adder's reach of a finite operand does the same) |
| saturated edge start and steps | `±2^127` | edge L190-191, L196-197 | hugepos, hugepos_v4-v6 |
| evaluator zero / infinity | `+-2^-127`, `+-2^-128` | TSP L312-313 | uvmeas wexp, whuge: 4875 of 4875 |
| value of -1 unit | `-2^-143` | TSP L381 | wzero1 (below 2^-130); GAP G8 |
| divider: -1 unit | `0xFFFF * 2^-143` | TSP L455 | texfar_m1 166 of 166, texfar_m1q |
| divider: zero denominator | `2^-128` | TSP L480 | wzero2 32,784 readings |
| stored overflow (`Saturated`) | `0x7F000000` with the sign bit | depth L235 | bgbig, bgspec, zsign page 15 |
| forced start | `±2^127` (`FromSingle(0x7F000000 or 0xFF000000, 0)`) | depth L510 | depthgaps_infstart, zovf (six cells), depthgaps_edges N |
| REG step and sign | 2^25 units of 2^102 (2^127); sign at 2^29 units (2^131) | depth L477, L702 | zword, zovf |
| the lowest word | `0x807FFFFF` | depth L718 | zword (m = 16) |
| TR peel reset | `Bits(0x7F7FFFFF)` | lists L763 | sort |
| NegWord fallback | `0x80000000 \| (E + 126) << 23` | depth L667 | [R] A5 |
| `27146 / 65536` | | mip L674, MIP_K 1 only | not HW |

---

## 4. The range rules (ranged arithmetic)

### 4.1 The rules as measured

These were measured for the TSP setup [README "The TSP's numbers at their limits"; uvmeas wexp, whuge, wtiny,
wspec, wneg, wzero1, wzero2; cmeas cwext1, cwsum1; mipmeas mwext1, mwextd1]. At `708fb8cd` the ISP depth's are
measured on the depth unit itself [README "refsw3 without float", depthgaps / zovf: zovf_lim, _c, _ps, _sum, _far,
_ab; depthgaps_zadd, _field1, _nanprod, _tinyramp; huge, zspec], with its own zero rule (last bullet).

- **Input**: exponent field 0 is a **zero** whatever the mantissa says, so a denormal is zero. Field 255 is an
  **infinity** with its sign, so a NaN is one too.
- **Product**: zero times anything is zero, also times an infinity. Infinity times anything else is infinity. A
  result of 2^128 or more is infinity; one below 2^-126 is zero. The sign is the product's in every case.
- **Sum**: infinity plus a number is that infinity, and two infinities of the same sign stay infinite. Infinities
  of opposite sign give **+0**. A result of 2^128 or more is infinity; a result below 2^-126 is **+0**, as an
  exact cancellation is.
- **The last addition of `(t1 + t2) + t3`** (TSP only, `zeroReach = 2`): when one of the two operands is zero and
  the other is in [2^-126, 2^-125), the zero is added as **2^-127 with its own sign**. In `t1 + t2` a zero is a
  zero.
- **Every addition of the ISP depth setup** (`708fb8cd`): when one operand is zero and the other is in
  [2^-126, 1.5 * 2^-126) with the other sign, the sum is **+0**; otherwise a zero adds nothing, exactly. Every zero
  sum is +0, `-0 + -0` too. 2^128 is checked at every product and every sum where it is made, after the truncation.
  [depthgaps_zadd 109 of 109 (the TSP's last-addition rule there: 76); depthgaps_field1 2,000 of 2,000; zovf_lim
  4,984 of 4,984]

### 4.2 The four flavours side by side

| | edge unit | ISP depth setup (`DepthTileT::Setup` L321-371) | TSP setup (`PlaneT::Setup` L144-184) | TSP mip (`MipSelect` L602-612, L699-730) |
|---|---|---|---|---|
| input | `FromBits` | `FromSingle(., 1)` | `FromSingle(., 1)` | the planes' sums; DCalcCtrl 1: `FromSingle(., 1)` |
| product | `Mul 24`, no range; ≥ 2^128 swamps (H7a) | `mul` | `mul` | `kind`, `rmul` |
| sum | `Add 24/25`, no range; ≥ 2^128 swamps | `add_d`: `limit(., true)`, the zero rule, every zero `+0` | `addTerm(., ., false)` | `radd`: **reach 53** |
| `sum3` | `(e1 + e2) + e3` | `add_d(add_d(p, q), r)`; the mean: `addInf` | `addTerm(addTerm(p, q, false), r, true)` | none |
| reciprocal | none | `Recip 24`, **unranged** | `det.bad ? zero(det.neg) : Recip 24`, then below 2^-126 → `zero(sign)` | `det.bad ? +0 : Recip 24`, then below → `+0` |
| coefficients | | `A`, `B`: `Mul(., inv, 24)`, **unranged**, then `under()`: below 2^-126 → mant 0, **sign kept**; the start: the ranged `first0` | `mul(., inv)` ranged, then `cut_16` | `Mul(best, inv2, 24)`, then range |

The wrappers, exactly:

```
inf(s)  = {bad 1, neg s, mant 0}          zero(s) = {neg s, mant 0}
above(r) = r != 0 and top(r) - 1 > 127    // |r| >= 2^128
below(r) = r != 0 and top(r) - 1 < -126   // |r| <  2^-126

mul(p, q):                                    // depth L330, TSP L150, mip rmul L699 (the same rule)
  if p.bad or q.bad:
     other = p.bad ? q : p
     return (not other.bad and other == 0) ? zero(p.neg ^ q.neg) : inf(p.neg ^ q.neg)
  r = Mul(p, q, 24)
  above(r): inf(r.neg);  below(r): zero(r.neg);  else r       // r.neg = p.neg ^ q.neg

add(p, q) = addTerm(p, q, third = false)     // the TSP's; the depth setup has add_d (below)
addTerm(p0, q0, third):                       // TSP L163
  if p0.bad or q0.bad:
     if p0.bad and q0.bad and p0.neg != q0.neg: return +0
     return inf(p0.bad ? p0.neg : q0.neg)
  p = p0; q = q0
  if third:                                   // zeroReach 2: "smallest" = top - 1 < -125
     if q0 == 0 and p0 != 0 and top(p0) - 1 < -125:  q = {neg q0.neg, mant 1, exp -127}
     if p0 == 0 and q0 != 0 and top(q0) - 1 < -125:  p = {neg p0.neg, mant 1, exp -127}
  r = Add(p, q, 24, 25)
  above(r): inf(r.neg);  below(r): +0;  else r

radd(x, y):                                    // mip L720: as add, but Add(x, y, 24, 53)
kind(x, y):                                    // mip L606: the class of the product x*y
  x.bad or y.bad: ((not x.bad and x == 0) or (not y.bad and y == 0)) ? ZERO : INF
  x == 0 or y == 0: ZERO
  m = Mul(x, y, 24): above(m) ? INF : below(m) ? ZERO : NUMBER

add_d(p, q):                                  // depth L354 (708fb8cd)
  if p.bad or q.bad:
     if p.bad and q.bad and p.neg != q.neg: return +0
     return inf(p.bad ? p.neg : q.neg)
  if exactly one of p, q is 0 (call it z) and the other (v) has top(v) - 1 == -126, v.neg != z.neg
     and |v| < 1.5 * 2^-126:                  // refsw3: v's bit under the leading one is 0 (D2)
     return +0                                // the zero rule
  r = Add(p, q, 24, 25)
  above(r): inf(r.neg);  below(r) or r == 0: +0;  else r
addInf(p, fp, q, fq):                         // depth L571 (the det-zero mean); fp, fq: the corner's raw fraction
  if p.bad and q.bad and p.neg != q.neg and fp != fq:      //   when its exponent field is 255, else 0 (a sum: 0)
     return inf(fp > fq ? p.neg : q.neg)
  return add_d(p, q)
```

The **flat (determinant-zero) mean's first addition** in the TSP (`withZero`, L256-274; slivers_dzspec,
slivers_dzzero 9,600 of 9,600):

```
fieldZero(k) = z[k][30:23] == 0                     // the raw input word
first = fieldZero(0) and not fieldZero(1) ? withZero(Z1, z[0])
      : fieldZero(1) and not fieldZero(0) ? withZero(Z0, z[1])
      : addTerm(Z0, Z1, false)
withZero(p, zbits):
  zneg = zbits[31]
  if p == 0 or p.bad or top(p) - 1 != -126 or p.neg == zneg: return p
  zv = {neg zneg, mant 0x800000 | zbits[22:0], exp -150}     // (1 + m 2^-23) 2^-127, hidden bit kept
  r = Add(p, zv, 62, 400)                                    // exact here: both 24-bit, exponents 1 apart
  return (r == 0 or top(r) - 1 < -126) ? +0 : p
```

### 4.3 Where a ranged unit uses unranged operations

These sites are listed in `isp.md` 6.3 and repeated here for the primitive choice:

- **Depth.**
  - `inv0`, `invS` and `inv` = `Recip(det, 24)` (L396, L432, L581) have no range rule, but `det` is in
    [2^-126, 2^128), so `inv` is in (2^-128, 2^126].
  - `first0` (L398) is the **ranged** evaluation of `((a x0 + b y0) + c) * inv0`. It decides the regimes, and since
    `708fb8cd` it is also the start the block steps from (L591; depthgaps_tinyramp). refsw3's unranged evaluation of
    the same expression (the third choice at L591) is never taken with `range = 1`.
  - `A`, `B` (L582-583) and the REG steps (L436) are the **unranged** `Mul(., inv, 24)`; `A` and `B` are then
    `under()`ed (L596-597). `C` (L584) feeds only the float form, which is unreachable (A3).
- **Edge.** The edge unit's `det` (unranged, `FromBits`, swamped: H7a) and the depth unit's or TSP's `det`
  (ranged, `FromSingle`) are the same arithmetic on normal finite inputs whose intermediate values stay within
  [2^-126, 2^128), except where the depth zero rule acts (a zero coordinate difference or product against one of
  [2^-126, 1.5 * 2^-126) of the other sign). They differ for denormal, infinite or NaN corners and for products or
  sums outside the range (corners from about 2^64 on, where the edge unit swamps and the depth unit makes an
  infinity). One datapath with a mode bit can serve both. A datapath that computes the
  unranged chain and derives the ranged one from range flags **cannot**, because a ranged infinity or zero changes
  every later operation.

---

## 5. Every call site

How the list was made (and how to make it again after a reference change):

```
cd nulldc3/refsw3/refcore && grep -n -E '(\b(Add|Sub|Mul|Recip|FloorScaled|FloorUnits|SingleBits|AbsAtMost|AtMost|Perpendicular|Divide|ColorRounded|DenominatorSeen|TexCoordFixed)\s*\()|\.cut\(|cutBelow\(|FromSingle\(|FromBits\(|FromHalves\(|Pow2\(|atLeastPow2\(' *.h *.cpp
```

The `op` column names the primitive of section 6. `N/R` gives the width and the reach.

### 5.1 `pvr_isp_edge.h` (`EdgeHW`; inputs `FromBits`; no range; the swamp)

`Winding` and `EdgeWinding` run once per triangle (`refsw_tile.cpp` L752-755 for the chunk counter's
`TriangleCulled`, L778-779 for drawing). `EdgeTile::Setup` runs per edge per tile (L797-800); `c`, `dx` and `dy` do
not depend on the tile. `SetFirstRow` walks a big edge again once the row range is known (L830-834). Algorithm:
`isp.md` 7.1, 8.3-8.6.

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 85-89 | `Winding`: `e(j,k) = Sub(Mul(x_j, y_k, 24), Mul(x_k, y_j, 24), 24, 25)`; `det = Add(Add(e1, e2), e3)` | H5, H6 | 24; 24/25 | only `det.bad` is used: a bad corner |
| 113 | `swamp(v) = v.atLeastPow2(128) ? Pow2(200, v.neg) : v` | H7a | | in `EdgeWinding` |
| 114-118 | `EdgeWinding`: `e(j,k) = sw(Sub(sw(Mul(x_j, y_k, 24)), sw(Mul(x_k, y_j, 24)), 24, 25))`; `det = sw(Add(sw(Add(e1, e2)), e3))` | H5, H6, H7a | 24; 24/25 | `e1 = e(1,2)`, `e2 = e(2,0)`, `e3 = e(0,1)`; `x_j y_k` is the minuend; **order `(e1 + e2) + e3`**; winding = `+1` iff `det < 0` and `det != 0`; also feeds `CulledBySize` and `CulledByFacing` |
| 131 | `FloorScaled(y_k, 0)`, `(FloorScaled(y_k, 1) + 1) >> 1` | H11 | clamp 2^40 | row range `floor(ymin) .. floor(ymax + 1/2)`; not for modifier volumes |
| 181-182 | `c = sw(Sub(sw(Mul(xb, ya, 24)), sw(Mul(xa, yb, 24)), 24, 25))` | H5, H6, H7a | 24; 24/25 | edge a→b; `xb ya` is the minuend |
| 188 | `dx = Sub(xa, xb)`, `dy = Sub(ya, yb)` | H6 | 24/25 | `top <= 129` |
| 189 | `dxP = sw(dx)`, `dyP = sw(dy)` | H7a | | for the start's products |
| 190-191 | `dx, dy >= 2^128` → `Pow2(127, neg)` | H7a | | for the steps; hugepos_v4-v6 |
| 192 | `x0 = FromHalves(2 left + HALF_OFFSET[0])`, likewise `y0` | H4 | | the tile's first sample point |
| 194 | `first = sw(Add(sw(Mul(dxP, y0, 24)), -sw(Mul(dyP, x0, 24)), 24, 25, -1))` | H5, H6, H7a | 24; 24/25 | a dropped operand here is what covmeas point 3 saw; `Mul(±2^200, 0)` is a zero |
| 195 | `start = Add(first, c, 24, 25, -1)` | H6 | 24/25 | |
| 196-197 | `start >= 2^128` → `Pow2(127, start.neg)` | H7a | | `es <= 128` after it |
| 198 | `sy = dx.cut(20)`, `sx = (-dy).cut(20)` | H2 | 20 | |
| 199-200 | `ep = max(top dx, top dy)`, `es = top(start)` | H1 | | |
| 208 | `s20 = start.cut(20)` | H2 | 20 | |
| 216-230 | `E = max(ep + 6, es + 1)`; `E > 129` → `E = 129` (cut); `unit = ep - 21` | int | | the cut happens iff `ep >= 124`; `big = cut && ep >= 124` (L268) is the cut |
| 231-235 | `E - unit > 56` → constant tile | int | | never for a big edge (`E - unit = 150 - ep`) |
| 237-238 | `sx, sy .cutBelow(unit)` | H3 | | the walk keeps `sx`, `sy` before this cut (L236) |
| 239-264 | `unitsAt`: `t0 = 2 floor(s20 / 2^unit) + frac`; `tx = 2 floor(sx / 2^unit)`; `ty` likewise; `zero2 = 2 << (E - 21 - unit)`; `tie2` likewise | H11 (`unitsAt`) | | `unitsAt(+-0) = 0`; `frac` = any bit of `s20` below `unit`; `isp.md` 8.5: 31-bit accumulator |
| 268-277 | big: `fine = unit - 6`; `f0 = 2 floor(s20 / 2^fine) + frac`; `fx = 2 unitsAt(sx.cutBelow(fine))`, `fy` likewise; `h = 2 << (131 - fine)`; `z = 2 << (E - 21 - fine)`; `Walk()` | H3, H11 | | `isp.md` 8.4b, 8.5: 36-bit walk accumulator |
| 282-289 | `SetFirstRow(row)`: clamp to 0 .. 31, walk again if it changed | int | | |
| 291-304, 307-327, 362-401 | `InsideOrdinary`, `RowMask`, `Walk` | int | | integer compares and adds only |

### 5.2 `pvr_isp_depth.h` (`DepthHW`; inputs `FromSingle(., 1)`; ranged)

`DepthTileT::Setup` runs per triangle per tile in refsw3 (`refsw_tile.cpp` L807) and starts from a clean object
(L308). In the HW, `a`, `b`, `c` and `det` are per triangle and the start is per tile. Algorithm: `isp.md` 9.

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 311 | `first_z = Bits(z[0])` | | | every CONST path overwrites it in the HW configuration: never stored |
| 323 | `load = FromSingle(u, 1)` | H4 | | `x, y, z` of the three corners in rasterizer order |
| 324-329 | `limit(r, sum)`: `>= 2^128` → inf; `< 2^-126` → zero (`+0` for a sum, sign kept for a product) | H10 | | |
| 330-336 | `mul(p, q)` | H5 + H10 | 24 | `bad × 0 = 0`, `bad × x = inf`, sign xor |
| 354-370 | `add(p, q)`: the bad rules; the zero rule (L359-365); `limit`; a zero sum `+0` (L367-368) | H6 + H10 | 24/25 | section 4.2 `add_d`; D2 at L363 |
| 371, 375-376 | `sub(p, q) = add(p, -q)`; `edge(j,k) = sub(mul(X_j, Y_k), mul(X_k, Y_j))` | H5+H10, H6+H10 | 24; 24/25 | ranged |
| 378 | `a = sum3(mul(Z0, sub(Y1,Y2)), mul(Z1, sub(Y2,Y0)), mul(Z2, sub(Y0,Y1)))` | H5, H6, H10 | 24; 24/25 | **`(t0 + t1) + t2`** |
| 379 | `b = sum3(mul(Z0, sub(X2,X1)), mul(Z1, sub(X0,X2)), mul(Z2, sub(X1,X0)))` | as above | | `(t0 + t1) + t2` |
| 380 | `c = sum3(mul(Z0, e1), mul(Z2, e3), mul(Z1, e2))` | as above | | **`(t0 + t2) + t1`** [zmeas 1: one of 384 combinations of vertex order and sum orders fits] |
| 381 | `det = sum3(e1, e2, e3)` | H6, H10 | | `(e1 + e2) + e3` |
| 382-383 | `Perpendicular(det)` → `det = +0` | H9 | | |
| 384-393 | `det.bad` → key 0 everywhere | | | GAP G5 |
| 396 | `inv0 = Recip(det, 24)` | H8 | 24 | unranged |
| 397-399 | `first0 = mul(add(add(mul(a, x00), mul(b, y00)), c), inv0)`, `x00 = FromHalves(2 left + 1)` | H5, H6, H10 | 24; 24/25 | **always the pixel centre**; `(a x0 + b y0) + c`; the regimes' test and the block's start (L591) |
| 405-413 | `a` or `b` bad → REG; `sa`, `sb` from the signs of `a`, `b`, `det` | | | |
| 432-446 | `invS = Recip(det, 24)`; `rstep(v) = Mul(v, invS, 24).cut(20).cutBelow(102)`, the magnitude mod 2^30 in units of 2^102, then the sign | H8, H5, H2, H3 | 24; 20 | unranged `Mul`; `fa`, `fb` |
| 476-483 | REG `r0 = first0.bad ? ±2^25 : trunc(first0.cut(20) / 2^102)` | H2, H11 | 20 | sign-magnitude, toward zero |
| 486-511 | `first0` or `c` bad: `a = b = 0` → `Saturated(first0.neg)`; else the forced start: `±2^127` (`FromSingle(0x7F000000 / 0xFF000000, 0)`) or `first0` | H14 | | |
| 568-578 | `mean = mul(addBad(addBad(Z0, frac0, Z1, frac1), 0, Z2, frac2), OneThird())`; `Flat(mean, 20, 19)` | H6+H10, H5+H10, H14 | 24 | `(z1 + z2) + z3`, the third corner sent added last; `addBad` L571-575 |
| 581-584 | `inv = Recip(det, 24)`; `A, B, C = Mul(a, b or c, inv, 24)` | H8, H5 | 24 | **unranged**; `C` feeds only the float form |
| 591 | `first = forced ? forcedFirst : rangedFirst` | | | the unranged third choice is never taken with `range = 1` |
| 596-597 | `under(A, B, C, first)`: below 2^-126 → `mant 0`, sign kept | H10 | | zspec pages 3-6 |
| 599 | `pair = max(top A, top B)` | H1 | | |
| 600-606 | `first == 0` and `pair == NoExp` → key 0 | | | |
| 616-618 | `start = first.cut(20).cutBelow(pair - 21)` | H2, H3 | 20 | zstart |
| 619-620 | `e = (first == 0 or start == 0) ? pair + 5 : top(first)`; `unit = e - 26` | | | zmeas mix reach; depthgaps_flt |
| 621-629 | `step(v) = v.cut(20).cutBelow(pair - 21).cutBelow(unit)` | H2, H3 | 20 | |
| 630-631 | `pair - 21 + 24 - unit > 100` → float form | | | unreachable (A3) |
| 632-635 | `d0 = 2 start / 2^unit`, `dx`, `dy` exact | H11 | | at most 54 bits a pixel (H12b) |
| 636-656 | `E = max(e, pair + 5)`, then at least -122 and at most 128 | int | | depthgaps_neggrid, _tinymean; _bigslope, _bigpair |
| 663-669 | `NegWord(t)`: `sh = E - 15 - unit`; `0 <= sh <= 120` ? `Neg(E, t >> sh)` : the fallback word | H14 | | A5 |
| 700-721 | `RegDepth(r)` | H14 | | `isp.md` 9.5 |
| 723-752 | `At`: REG; CONST; `tu = d0 + (2i + h) dx + (2j + h) dy`; `tu < 0` → `NegWord`; else to `Fp` (64-bit truncation, never acts), `cut(19)`, `Big` from 2^128, else `FromFp` | H12b, H14 | 19 | `h = 0` at centres, -1 at corners (HALF_OFFSET[0]); the float form at L742-747 is unreachable |
| 110-279 | `StoredDepth`: `Key32` (L116), `Bits` (L122), `Between` (L124), `Neg` (L160), `Flat` (L180), `Big` (L224), `Saturated` (L235), `FromFp` (L239) | H14 | | |

### 5.3 `pvr_tsp_plane.h` (`PlaneHW`; inputs `FromSingle(., 1)`; ranged)

Indices 0, 1, 2 are the corners in rasterizer order, `j = k + 1`, `l = k + 2` (mod 3). Algorithm: `tsp.md` 4-8.

**Setup** (per plane per triangle). The planes are 1/w, U, V (twice with two volumes) and 4 + 4 colour channels
(twice).

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 149 | `load = FromSingle(u, 1)` | H4 | | colours come in through `SingleBits(c, -8)` |
| 193-194 | `e[k] = sub(mul(X_j, Y_l), mul(X_l, Y_j))` (`e0 = edge(1,2)` ...) | H5, H6, H10 | 24; 24/25 | |
| 198 | `ta[k] = mul(Z_k, sub(Y_j, Y_l))` | H5, H6, H10 | | |
| 199 | `tb[k] = mul(Z_k, sub(X_l, X_j))` | | | |
| 200 | `tc[k] = mul(Z_k, e[k])` | | | |
| 202-204 | attribute plane: `ta[k] = mul(AT_k, ta[k])`, likewise `tb`, `tc` | H5, H10 | 24 | `a_i * (w_i * d)`, cut twice (uvmeas point 9, wflat 600 of 600) |
| 209-210 | `a = sum3(ta0, ta1, ta2)`, `b = sum3(tb0, tb1, tb2)` | H6, H10 | 24/25 | `(t0 + t1) + t2`; the third-addition rule on the outer add |
| 211 | `c = attr ? sum3(tc0, tc1, tc2) : sum3(tc0, tc2, tc1)` | | | attribute `(t0 + t1) + t2`; **1/w `(t0 + t2) + t1`** (uvmeas point 6) |
| 212 | `det = sum3(e0, e1, e2)` | | | `Sa, Sb, Sc, Sdet` are kept for the mip (L213) |
| 214 | `Perpendicular(det)` → 0 | H9 | | |
| 245-279 | flat: `first` (`withZero` / `addTerm`); `mean = mul(addTerm(first, Z2, true), OneThird())` (0xAAAAAB 2^-25, softfp L331); `C = attr ? mul(AT2, mean).cut(16) : mean.cut(16)`; `A = B = +0` | H6, H10, H5, H2 | 24; 16 | section 4.2; `withZero` `Add(., ., 62, 400)` is exact there |
| 285-287 | `inv = det.bad ? zero(det.neg) : Recip(det, 24)`; below → `zero(inv.neg)` | H8, H10 | 24 | hugepos (a determinant above 2^126 gives zero coefficients) |
| 288-291 | `A0, B0, C0 = mul(a, b or c, inv)`; `A, B, C = .cut(16)` | H5, H10, H2 | 24; 16 | `A0, B0, C0` only feed dead mip paths (below), so effectively `Mul(., ., 16)` |

**Evaluator `Value`** (per run start and per pixel; L302-398):

| line | expression | op | notes |
|---|---|---|---|
| 311-316 | `seen(v)`: `bad` → `Pow2(-128, v.neg)`; zero → `Pow2(-127, v.neg)` | H4 | the exponent field read as a signed 8-bit number |
| 319 | `ex = BL(tileLeft + 16)`, `ey = BL(tileTop + 16)` | H1 | |
| 320-325 | `e = max(top c_, top a_ + ex - 1, top b_ + ey - 1)`; `unit = e - 22` | H1 | `range = 1`: a zero coefficient counts through `seen` |
| 326 | `ax = Mul(a_, FromHalves(x0h), 62)`, `by = Mul(b_, FromHalves(yh), 62)` | H5 | exact 16 × ≤13 bits; L327-328 give a zero product `a_`'s sign, which `Mul`'s xor already gives |
| 329 | `k = FU(c_) + FU(ax) + FU(by) + n FU(a_)` | H11 (`FloorUnits`) | each term floored on its own; integer sum |
| 362-366 | SupSample: `ah = Mul(a_, 1/2, 62)`; `k += -n FU(a_) + (2n + hx) FU(ah)` | H5, H11 | exact half |
| 367-368 | `hy`: `k += FU(Add(c_, bh, 62, 400)) - FU(c_)` | H7b | ARTIFACT A1 |
| 377-397 | normalizer: `k` → 16 bits toward minus infinity, exponent floor -128, `k = -1` → `-2^-143`, `k = 0` → `+0` | H12a | |

**Divider and colour:**

| line | function | op | notes |
|---|---|---|---|
| 90-105 | `FloorUnits(v, unit)` | H11 | `-0` → -1; the `s >= 62` clamp is unreachable (ARTIFACT A4) |
| 406-433 | `RecipTable` | H13 | |
| 449-467 | `DenominatorSeen` | H13 | |
| 475-509 | `Divide` | H13 | |
| 519-540 | `ColorRounded(q, -8, 255 or 65535, fallback)` | H15 | |

**`MipSelect`** (L584-833; HW: `MIP_K = 0`, `MIP_ARITH = 0`; `tsp.md` 8):

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 606-612 | `kind(x, y)`: class of `Mul(x, y, 24)` | H5, H10 | 24 | shares the product of L641 |
| 618-621 | `inv = det.bad ? +0 : Recip(Sdet, 24)`; below → `+0` | H8, H10 | 24 | **DEFECT D1**: `Sdet == 0` divides by zero |
| 622 | `undivided = !det.zero && !inv.zero` | | | |
| 623-630 | `inv2 = Mul(inv, inv, 24)`; below → `+0` | H5, H10 | 24 | mipdump, mipdet (a determinant above 2^63 gives the largest map) |
| 641 | `q1 = Mul(sa1, sb2, 24)`, `q2 = Mul(sb1, sa2, 24)` (or `+0` by kind / bad) | H5 | 24 | the undivided sums `Sa, Sb, Sc` |
| 642 | `n = abs(Sub(q1, q2, 62, 200).cut(24))`, `bad` cleared | H7c | wide → 24 | ARTIFACT A1 |
| 646-648 | `nq = Mul(n, inv2, 62)`: below → 0, above → inf | H5, H10 | exact | only `top` is used |
| 652-660 | `!undivided`: `Mul(., ., 62)`, `Sub(., ., 62, 200)` | | | **dead in the HW config**: `!undivided` means `det == 0` or `inv == 0`, so `A0 = B0 = 0` and both products are 0 (or the kind decides infinity) |
| 668 | `AtMost(q, p)` (longer / shorter) | H9 | | |
| 684-687 | `sum = Add(hi, lo, 62, 25).cut(24)`; `less = Mul(lo, 0x95F612 2^-24, 62).cut(24)`; `Sub(sum, less, 62, 25).cut(24)` | H6, H5 | ≡ 24/25; ≡ 24 | mipk4 |
| 698-714 | DCalcCtrl 1: `pu = rmul(u1, z1)` ... | H4, H5, H10 | 24 | `pu, pv, pw` are dead in the HW config (only read in `!undivided`) |
| 719-732 | `at1 = radd(radd(rmul(Sa, x1), rmul(Sb, y1)), Sc)` | H5, H6, H10 | 24; **24/53** | GAP G1 |
| 734 | `val1` (`Mul 62`, `Add 62/200`) | | | dead in the HW config |
| 743 | `best = lx.bad or (!ly.bad and AtMost(ly, lx)) ? lx : ly` | H9 | | |
| 745-747 | `best = Mul(best, inv2, 24)`; range | H5, H10 | 24 | |
| 750-762 | `k8 = bad ? 2^(-128+size) : zero ? 2^(-127+size) : cut_8(best * biasQuarters * 2^(size-2))` | H5, H2 | 8 | `Mul(best, FromHalves(2 bq), 62)` is exact, then the exponent is adjusted, then cut |
| 770-774 | `wFull = abs(Divide(1, q))`; `w8 = wFull.cut(8)` | H13, H2 | 8 | |
| 779-781 | `ww = Mul(w8, w8, 8)`; `top - 1 > 127` → exponent clamped to 127, mantissa kept | H5 | 8 | mipmeas wext |
| 782-785 | `d = Mul(k8, ww, 8)`; `L = top(d) - 1`, `M` = top 8 bits | H5, H1 | 8 | |

### 5.4 `refsw_tile.h`, `refsw_tile.cpp`, `refsw_lists.cpp`

| file:line | expression | op | notes |
|---|---|---|---|
| tile.h 90 | `SingleBits(c, -8)` for each colour channel | H4 | |
| tile.h 101-116 | `Val(p)` (L103-105: `n = x - SpanStart`, `x0h = 2 (left + SpanStart) + half`, `yh = 2 (top + y) + half`); `Quot = Divide(Val(p), W)` | H12a, H13 | `half` = HALF_OFFSET[1] |
| tile.h 128-131 | `ColorRounded(Quot, -8, max, fallback)` | H15 | max 65535 for the base colour (intensity scaled before the clamp), 255 for offset |
| tile.cpp 722-740 | `CulledBySize`, `CulledByFacing` | H9 | |
| tile.cpp 748-749, 771-772 | `FromBits(v.x)`, `FromBits(v.y)` | H4 | the fourth corner of a sprite too |
| tile.cpp 752-755, 778-779 | `Winding` (bad corners), `EdgeWinding` (sgn and the culls' det) | H5, H6, H7a | `isp.md` 7.1 |
| tile.cpp 811-835 | `RowRange`; the row-31 shift with a big edge; `SetFirstRow` | H11 | `isp.md` 8.6 |
| tile.cpp 1264-1318 | `CoordKeep`, `TexCoordFixed(u, shift)` | H11 | `tsp.md` 9.1 |
| tile.cpp 1728-1770 | `LookupFogTable`: `M = FOG_DENSITY[15:8] * W.mant` (8 × 16 bits, exact), `E = W.exp + FOG_DENSITY[7:0] (signed) - 7`, normalize to 24 bits, clamp to [1, 256 - 2^-16], index and blend from the float bits | H1, H5 (8×16 integer) | `tsp.md` 15.2; `W < 0`, zero or bad → 1.0 |
| lists.cpp 374-379 | `perpVal = FromBits(FPU_PERP_VAL & 0x7fffffff)` | H4 | |
| lists.cpp 637-653 | background key from ISP_BACKGND_D (0x088): above zero `bits`, below zero `neg` with E at least 6 | H14 h | `isp.md` 4.2 |
| lists.cpp 763 | `PeelBuffers(Bits(0x7F7FFFFF))`: the TR sort's reset | H14 a | `isp.md` 11.6 |

### 5.5 Instances by primitive

| primitive instance | sites (in the HW config) |
|---|---|
| H5 `Mul` 24×24 → cut 24 | edge 86, 115, 182, 194 (`Winding`, `EdgeWinding`, `c`, `first`); depth 335 (every ranged product: `mul`), 436 (REG steps), 582-583 (`A`, `B`); TSP 152/158 (edges, terms, attribute products, coefficients, mean); mip 610, 623, 641, 686, 706, 745 |
| H5 `Mul` exact 16 × ≤13 (integer coordinate) and × 1/2 | TSP 326, 363 |
| H5 `Mul` exact 24×24, range class only | mip 646 |
| H5 `Mul` 24 × ≤5 bits → cut 8; 8×8 → cut 8 | mip 759-762; 779, 782 |
| H5 constant multiplies | `OneThird()` = `0xAAAAAB 2^-25` (depth 576 through `mul`, TSP 275); `0x95F612 2^-24` (mip 686) |
| H6 `Add` 24/25 | edge 86, 89, 115, 118, 182, 188, 194, 195; depth 366 (every ranged sum: `add`); TSP 165/177; mip 686, 687 |
| H6 `Add` 24/53 | mip 726 |
| H7a swamp and saturation (2^128 comparators) | edge 113, 181 (swamp), 189 (`dxP`, `dyP`), 190-191 (`dx`, `dy`), 196-197 (start) |
| H7b, H7c wide `Add` (62, R ≥ 200, window 90) | TSP 368 (H7b); mip 642 (H7c). TSP 265 is the same call but exact on its operands |
| H8 `Recip` 24 | depth 396, 432, 581; TSP 285; mip 619 |
| H2 `cut` | 20: edge 198, 208; depth 188 (`Flat`), 436, 479, 616, 624; lists 642 (the background's `>> 4`); 16: TSP 276, 289-291; 19: depth 187 (`Flat`), 488, 710, 748; 8: mip 762, 773 |
| H3 `cutBelow` | edge 237-238, 273-274; depth 436 (2^102), 618, 624 (twice) |
| H11 converters | edge 131 (`FloorScaled`), 239-264, 272-274 (`unitsAt`); depth 441-443, 479-482 (REG), 632-635 (block), 195-202 (`Flat`'s M), 668 (`NegWord`'s M); lists 643-645 (the background's M) |
| H14 stored-depth key | depth 110-279 (`StoredDepth`), 663-669 (`NegWord`), 700-721 (`RegDepth`), 748-751 (`At`'s store); lists 637-653 (`bgkey`), 763 (the TR peel's `Bits(0x7F7FFFFF)`) |

---

## 6. The hardware primitives (the minimal set)

General RTL conventions:

- Each primitive takes and returns the reference tuple as **flat ports**: `neg`, `bad`, `exp` (10-bit signed),
  `mant[MW-1:0]`. Use plain packed vectors and no parameterized struct types, so that the later Quartus 17
  testing project accepts them.
- Each primitive is parameterized by its widths, so that it can be verified exhaustively at small widths against
  the same templated reference function (section 7.1).
- This document gives behaviour only. Combinational or pipelined is the timing specification's choice. The
  testbenches compare at the declared latency.

### H1 `fp_lzc #(W)`: bit length

`BL(v)` of a `W`-bit vector (0 for 0), as a priority encoder. Instances: 16 and 17 (TSP value and numerator), 24 and
25, 34 (divider product), 50 (24/25 adder), 64 and 108 (wide add), 128 (depth block). `TrailingZeros`: none.

### H2 `fp_cut #(IW, N)`: truncating normalizer

```
n = BL(mant);  if n > N: mant_o = mant >> (n - N); exp_o = exp + (n - N)  else unchanged
```

N in {8, 16, 19, 20, 24}. `neg` and `bad` pass through. Implemented as an LZC and a right shifter. The output has
at most N bits and is not left-justified.

### H3 `fp_cut_below`: drop the bits under a grid

```
if mant != 0 and exp < e: s = e - exp; mant_o = s >= 64 ? 0 : mant >> s; exp_o = e
```

The sign is kept, so the result can be `-0`. Inputs are at most 24 bits; `e` is the unit's grid exponent (edge
`unit`, depth `pair - 21` and `unit`).

### H4 `fp_in`: the inputs

- `from_bits(u)` and `from_single(u, ranged)`: section 2.5, exactly. Note the denormal (`FromBits`: mant = fraction,
  exp -149) and the sign of `bad` (cleared by `FromBits`, kept by `FromSingle`).
- `from_halves(k)`: `{k < 0, |k|, -1}`.
- `seen(v)` (TSP evaluator): `bad` → `{v.neg, 1, -128}`, zero → `{v.neg, 1, -127}`.
- `single_bits(c)` for 8-bit colours at `e = -8`: `c == 0` → 0; otherwise `(BL(c) + 118) << 23 | (c << (24 - BL(c))) & 0x7fffff`.

### H5 `fp_mul #(AW, BW, N)`: truncating multiplier

```
neg_o = a.neg ^ b.neg;  bad_o = a.bad | b.bad
P = a.mant * b.mant                 // exact AW + BW bits
{mant_o, exp_o} = cut_N(P at exp a.exp + b.exp)      // out.exp = max(a.exp + b.exp, top(P) - N)
```

Special values: a zero operand gives a zero with the xor sign. A bad operand has mant 0, so it gives 0 flagged bad.
The range is not this primitive's job; H10 wraps it.

Instances (section 5.5):

| instance | widths |
|---|---|
| setup | 24×24 → 24 |
| constant multiplies | 24 × the 24-bit constant → 24 |
| mip numerator range class | exact 48 bits, `top` only |
| TSP run start | 16 × 13 exact (29 bits) |
| SupSample half | 16 × 1 (an exponent decrement) |
| mip bias | 24 × 5 → 8 |
| mip | 8×8 → 8 |
| fog | 8 × 16 integer → 24, exact |

**The constant multiplies are exhaustively checkable.** `Mul(s, 0xAAAAAB 2^-25, 24)` for every 24-bit `s`
(2^23 normalized mantissas). The README used the same sweep to show that this product, cut to 20 then 19 bits,
equals an exact division by 3.

### H6 `fp_add #(W = 24, R)`: aligning adder with the drop rule

The behaviour is section 2.8, cases 1 to 4 and 8, for operands of at most W bits (case W cannot occur for
R ≤ 60, and cases 5 and 6 are no-ops or unused). Exactly:

```
bad_o = a.bad | b.bad
both zero:      {a.neg & b.neg, 0}
one zero:       the other operand, unchanged (it has <= W bits)
|ta - tb| >= R: the larger-top operand, unchanged
otherwise:      S = exact signed sum aligned at L = min(a.exp, b.exp)    // <= (R - 1) + W + 1 bits
                S == 0: +0;  else cut_W(|S| at L), neg = sign(S)         // out.exp = max(L, top(S) - W)
```

**Implementation (R = 25).** One exact 50-bit two's complement adder (49-bit magnitude + sign), an LZC over 49 bits
and a right shift into 24 bits. That is the simplest way to be exact.

A classic near/far split also works, with the operands left-justified to 24 bits and the LSB exponents remembered
for `out.exp`:

- **far** (`|ta - tb| >= 2`): the smaller operand aligned under the larger with 2 extra bits and a sticky. The
  sticky supplies the borrow of a truncated difference.
- **near** (`|ta - tb| <= 1`): an exact 26-bit subtract and an LZC.
- **drop**: `|ta - tb| >= R`.

**R = 53** (mip `radd`): the same adder, plus a far path for `25 <= gap < 53`. There the smaller operand lies
wholly below the larger's last kept bit, so:

- same effective sign: the result is the larger operand `L`;
- opposite: `cut_24(L - ε)`, that is, mantissa `L·2^(24 - top') - 1` at `top' = top(L)`, or `top(L) - 1` when `L`
  is a power of two (0xFFFFFF).

At `gap >= 53` the smaller operand is dropped.

### H7 The edge unit's swamp (H7a) and the two wide adds (H7b, H7c: `N = 62`, `R = 200/400`, window 90)

The wide adds' generic reference behaviour (H7b, H7c) is section 2.8 with case W:

```
|a.exp - b.exp| > 90:  the operand with the larger top
otherwise:             exact sum, truncated to 64 then 62 significant bits
```

The truncations compose with whatever cut follows, except at H7b where a floor follows. Each site takes few
operands, so it gets its own small circuit.

**H7a `fp_swamp`: the edge unit at 2^128** (edge L113, L181, L189-191, L196-197; refsw3 `6784ea3d`). It replaces
`2d08a440`'s `edge_start_sat` (the `±2^132 - first` wide add, which is gone). Two comparators on `|v| >= 2^128`
(`top(v) > 128`) that replace the tuple:

```
swamp(v) = top(v) > 128 ? {neg v.neg, bad 0, exp 200, mant 1} : v        // ±2^200: drops every finite operand
sat(v)   = top(v) > 128 ? {neg v.neg, bad 0, exp 127, mant 1} : v        // ±2^127
```

Where (`isp.md` 7.1, 8.3):
- `swamp` on every product of `EdgeWinding` and of the start (`xb ya`, `xa yb`, `swamp(dx) y0`, `swamp(dy) x0`), on
  each `e`, on `e1 + e2` and `det`, on `c` and `first`, and on `dx`, `dy` where they enter the start's products;
- `sat` on `dx`, `dy` for the steps, and on the start.

The adders need nothing new. A finite operand has top ≤ 128 (24-bit operands below 2^128), the swamp value top 201,
so H6's reach of 25 drops the finite one. Two swamp values add exactly: `2^200 + 2^200 = {mant 2, exp 200}`, which
is swamped again, and `2^200 - 2^200 = +0` (an exact cancellation). `Mul(±2^200, y0)` with `y0 = 0` (the first tile
row or column with `HALF_OFFSET[0] = 0`) is a zero, not swamped. After `sat`, `es = top(start) <= 128`.
[faredge_cmax 4,800 of 4,800 tiles; faredge_k132; faredge_m131 and faredge_cull for the determinant; hugepos a for
the start's 2^127; hugepos_v4, _v5, _v6 for `sat` on the steps]

**H7b `tsp_half_line`** (TSP L367-368, SupSample points half a line down, `hy = 1`). `c_ = seen(C)` and
`bh = seen(B) / 2` (`Mul(b_, FromHalves(1), 62)`: same mantissa, `exp - 1`). Neither is zero or bad.

```
|c_.exp - bh.exp| > 90:   T = top(c_) > top(bh) ? c_ : bh
otherwise:                T = cut_62(c_ + bh)       // exact sum (<= 16 + 90 + 1 bits), then the 62 MSBs, toward zero
Δk = floor(T / 2^unit) - floor(c_ / 2^unit)         // FloorUnits; T == 0 gives 0
```

Unlike the other two sites, the 62-bit truncation **is** observable here. A floor follows, and a negative `T` that
lost bits below the 62nd floors one unit higher.

The common case is a plane that is flat in y on a triangle of negative determinant. It has `B = -0`, seen as
`-2^-127`, so `bh = -2^-128` (1 bit). With `C` on the grid, the exact sum always floors one unit down
(`Δk = -1`). The reference gives (`agents/spec-numerics/probe2.cpp`, `C = 0xC000 2^(C.exp)`, gap = `C.exp + 128`):

| `C` | gap ≤ 46 | 47 .. 90 | > 90 |
|---|---|---|---|
| `C > 0` | -1 | -1 | **0** (window) |
| `C < 0` | -1 | **0** (`abs(C) + 2^-128` truncated to 62 bits is `abs(C)`) | **0** |

For a 16-bit `C`, gap > 90 means `|C| >= 2^-22`. That covers nearly every positive `C` there is.

Implementation: an exact adder over the window (up to 108 bits with sign), an LZC, a mask of the bits below
`top - 62`, then a floor to `unit` (with a sticky for "any kept bit below `unit`, negative").

**H7c `mip_minor_sub`** (mip L642). `q1`, `q2` are ≤ 24-bit products (H5). `n` is the magnitude:

```
q1 == 0 or q2 == 0:            the other one
|q1.exp - q2.exp| > 90:        the operand with the larger top (its own 24 bits)
otherwise:                     cut_24(q1 - q2)      // H6 behaviour without the reach: 25 <= gap uses the far path
n.neg = 0;  n.bad = 0
```

That is, an H6-style adder without a reach. The far path's borrow (`L - ε`) is enabled only while the LSB exponents
are within 90.

### H8 `fp_recip24`: setup reciprocal

Section 2.9:

```
dn = mant left-justified to 24 bits;  ev = exp - (24 - BL(mant))
dn == 2^23:  {neg, bad, 2^23, -46 - ev}
else:        {neg, bad, floor(2^47 / dn), -47 - ev}
```

The result is exactly truncated, never rounded. Any divider structure is fine as long as the result is the exact
floor: restoring or non-restoring radix 2 or 4 over 24 quotient bits, or a table seed with Newton-Raphson and a
**final exact correction step** (one remainder check). `v == 0` is undefined in the reference (D1). The RTL defines
a value for it at the mip site only (section 8).

### H9 `fp_cmp`: comparators and thresholds

- `abs_le(a, b)` = `AbsAtMost` (section 2.11): the zero and bad shortcuts, then `top`, then the left-justified
  mantissas.
- `le(a, b)` = `AtMost`.
- `at_least_pow2(v, e)`.
- `perpendicular(det)`, `culled_by_size(det)`, `culled_by_facing(mode, det)` (section 2.12); the two culls take
  `EdgeWinding`'s swamped determinant (H7a). The register
  operands are decoded with `from_bits(reg & 0x7fffffff)`. `size >= 0x7f800000` means "cull every triangle", and
  a `perpVal` that is NaN or infinity is `bad`.

### H10 `fp_range`: the range and special-value wrappers

Three flavours, exactly as in section 4.2:

- `rng_mul`: depth, TSP and mip `rmul`.
- `rng_add #(R, third, zrule)`: depth `add_d` (`zrule`: the zero rule, every zero sum +0); TSP `addTerm` with
  `third` 0 or 1; mip `radd` with R = 53.
- `rng_add_inf`: the depth mean's `addInf` (two infinities of opposite signs: the larger raw fraction's sign).
- `rng_kind`: the mip product class.

They are combinational wrappers around H5 and H6:

- **pre-checks**: bad operands; for `third`, the zero-substitution, which needs H1 on the nonzero operand; for
  `zrule`, `top(v) - 1 == -126` and the bit under `v`'s leading one (a one-bit mantissa reads as 0: D2);
- **post-checks**: `top(r) - 1 > 127` or `< -126`.

Also here:

- `under` (depth: below 2^-126 → mant 0, sign kept);
- the TSP and mip `Recip` wrappers (`det.bad` → `zero(det.neg)` in the TSP, `+0` in the mip; below → zero);
- the TSP flat `withZero` (section 4.2).

### H11 `fp_floor`: float to integer converters

The variants differ in their zero convention and clamping. Each is a variable shift with a sticky ("bits lost") and
`+1` for a negative magnitude, or the equivalent two's complement floor.

| variant | zero | rule | clamp | sites |
|---|---|---|---|---|
| `FloorScaled(v, s)` | 0 | `floor(v 2^s)` | `top + s > 40` → `+-2^40` | edge row range |
| `FloorUnits(v, unit)` | `+0` → 0, **`-0` → -1** | `floor(v / 2^unit)` | `s >= 62` → `INT64_MAX/4` (unreachable, A4) | TSP `Value`: `c_`, `ax`, `by`, `a_`, `ah`, H7b |
| edge `unitsAt(v, u)` | 0 | `floor(v / 2^u)`, plus `frac` = any bit below `u` | none (`E - unit <= 56`) | edge `t0`, `tx`, `ty` (`u = unit`); a big edge's `f0`, `fx`, `fy` (`u = unit - 6`, the steps first `cutBelow(u)`) |
| depth grid | | exact left shift: values are on the grid by construction (`m.exp >= unit`) | none | depth `d0`, `dx`, `dy` |
| depth REG `r0`, `fa`, `fb` | | `r0`: `cut_20`, trunc toward zero onto 2^102 (sign-magnitude); `fa`, `fb`: `cut_20(Mul(v, inv, 24))`, trunc onto 2^102, the magnitude mod 2^30, then the sign | `r0`'s shift clamps unreachable (A4) | depth L436-443, L479-482 |
| depth `M` | | `flat`: `-ceil(\|s\| / 2^(E - 16))`; `bgkey`: `-ceil(t / 2^10)`; `NegWord`: `floor(tu / 2^sh)` (arithmetic shift) | `NegWord`'s `sh < 0`: the fallback word (A5) | depth L195-202, L668; lists L643-645 |
| `TexCoordFixed(u, shift)` | 0 | two's complement `floor(u 2^shift)` while `top + shift <= 31`; beyond, `2^30 + low 26 bits` (`CoordKeep`) | none (texfar: never overflows) | `tsp.md` 9.1 |

TSP `Value` integer widths: `|k| < 2^25` (`|C|` and the products are below 2^e or 2^(e+1), with the grid 22 bits
down; `n * |A| < 2^23`). A 27-bit signed accumulator is enough (assert in the testbench).

### H12 Integer to float normalizers

**H12a `tsp_value_norm`** (`Value` L379-399), with `range = 1`:

```
k == 0:   +0
k == -1:  {neg 1, mant 1, exp -143}                    // "every bit set, no leading one"
neg = k < 0;  m = |k|;  drop = max(BL(m) - 16, 0)
if drop: lost = m mod 2^drop;  m >>= drop;  if lost and neg: m += 1      // toward minus infinity; m may become 2^16
exp = unit + drop
if top - 1 < -128: exp += -128 - (top - 1)             // exponent floor at -128, mantissa kept (value changes)
```

[uvmeas point 3, valueFixed table: 16 bits from the leading one, wherever it is; wtiny 37 readings for the -128
floor; wzero1 for -1]

**H12b `depth_block_to_fp`** (`At` L733-751; below zero `NegWord` L663-669):

```
tu = d0 + (2i + h) dx + (2j + h) dy     // signed fixed point in half units of 2^unit; at most 54 bits
tu < 0:   sh = E - 15 - unit
          0 <= sh <= 120:  neg(E, floor(tu / 2^sh))                   // H14 e; an arithmetic shift
          otherwise:       bits(0x80000000 | (E + 126) << 23)         // the fallback word (A5)
tu >= 0:  v = {0, 0, unit - 1, tu}      // refsw3 truncates to 64 significant bits first, which never acts
          s = cut_19(v);  top(s) - 1 >= 128 ? big(s) : from_fp(s)
```

`tu` has at most 54 bits: `|t| < 2^29` half-G units (`isp.md` 9.4a) times `2^(gexp - unit) <= 2^25`; the run of
`isp.md` 9.4a saw 50. In the G form the accumulator is the 30-bit `t` and `M = floor(t / 2^nsh)`, `nsh = E - 15 -
gexp`, a left shift when `nsh < 0` (`isp.md` 9.6). A negative pixel never becomes a float (A2 is closed).

### H13 `tsp_div`: the TSP divider

**`recip_mant(D)`**, for `D` in [32768, 65535] (`RecipTable::Mantissa`; uvmeas recipscan, all 32768 values):

```
i = D[14:6]  (= (D >> 6) - 512),  f = D[5:0]
t[i] = ceil(2^26 / (512 + i))            i = 0..512   (t[0..511] in 65601..131072; t[512] = 65536)
n[i] = t[i] - t[i+1] + c[i]              (65..256), c[i] in {0, 1, 2}: digit i of the 512-character string at
                                         pvr_tsp_plane.h L412-419 (102 zeros, 403 ones, 7 twos; no formula found)
r = (64 t[i] - 1 - n[i] f) >> 7          (r in 32768..65535)
```

The ROM is 512 × (18-bit `t`, or 17-bit `t - 65536`; 9-bit `n`). The arithmetic is a 9×6 multiplier, a 24-bit
subtract and a shift. **Generate the ROM from the header** (a tool reads the string and the formula), never by
hand.

**`denominator_seen(den)`** (L449; uvmeas wneg, 780,000 of 780,000):

```
not den.neg:          den (a zero never arrives here: Divide maps it first)
top(den) < -127:      {0, 0xFFFF, -143}                      // only -2^-143 (H12a) is below 2^-128
else: d = |den| normalized to exactly 16 bits (shift right if more, truncating; left if fewer)
      d.mant = 32768 + ((65536 - d.mant) & 32767)            // the 15 bits under the leading one negated
```

**`divide(num, den)`** (L475; uvmeas reciprow / reciprown 1,560,000 of 1,560,000; hugepos c; wzero2):

```
num == 0:   +0
den = den == 0 ? {0, 1, -128} : denominator_seen(den)
md = the top 16 bits of den.mant (exact: den has <= 16 bits);  ed = top(den)
r = recip_mant(md)
bn = BL(num.mant);  en = top(num)                            // num <= 17 bits
p = num.mant * r * 2                                         // <= 34 bits
q = p >> bn;  if num.neg and (p mod 2^bn) != 0: q += 1      // floor of the product at 17 fractional bits
return {num.neg, q, en + 1 - ed - 17}                        // q in [2^15, 2^17]; 18-bit field
```

### H14 `p2_zword_pkg`: the stored depth (depth.h `StoredDepth` L110-279, `RegDepth` L700; lists.cpp L637-653)

A stored depth is a **64-bit signed order key** (`StoredDepth::k`): the IEEE word's order, 32 bits finer. Every
depth compare of the ISP (`DepthMode`, `KeyAbove`, the modifier volumes' "greater") compares keys (`isp.md` 9.7).
refsw3's 32-bit `bits` is for logs and probes only. The functions, each a combinational function of its inputs:

**a. `key32(w)`, `bits(w)`, `between(w, o)`** (L116-130; zsign, bgspec, bgneg, bgneg2):

```
key32(w)      = w == 0x80000000 ? 0 : int32(w ^ (w[31] ? 0x007FFFFF : 0))
bits(w)       = key32(w) << 32
between(w, o) = (key32(w) << 32) + o,  1 <= o <= 2^32 - 1         // after w, before the next word
```

**b. `from_fp(v)`** (`FromFp` L239). It takes an `Fp` (≤ 19 bits here) to the key of its IEEE single word: RNE on
the denormal grid, saturating.

```
v.bad:           saturated(v.neg)
v == 0:          bits(sign)                                         // +-0: key 0 either way
keep = max(top - 24, -149)
if v.exp < keep: d = keep - v.exp; d > 63 ? m = 0 : RNE(m >> d); e = keep
m == 0:          bits(sign)
t2 = e + BL(m);  t2 > 128: saturated;  t2 <= -126: bits(sign | (m << (e + 149)))     // denormal word
else:            bits(sign | (t2 + 126) << 23 | (top 24 bits of m)[22:0])
```

With ≤ 19-bit inputs the rounding acts only below 2^-125 (a depth there has at most 19 bits on 2^-145 or coarser:
it never rounds; GAP G6: the denormals' order among each other).

**c. `saturated(neg)`** (L235) = `bits((neg ? 0x80000000 : 0) | 0x7F000000)`, ±2^127 (bgbig, bgspec, zsign page 15).

**d. `big(v)`** (L224; depthgaps_bigpos, _bigord): `v >= 2^128`, at most 19 bits. `f = top(v) + 126` (255 and up),
`frac` = the 23 bits under v's leading one; `between(0x7F800000, ((f - 255) << 23 | frac) + 1)`: above every float
word. `f - 255` stays below 2^9 (`v < 2^157`).

**e. `neg(E, M)`** (L160; the depthgaps hunt, `isp.md` 9.7): `M < 0`, the value `M 2^(E - 16)`, E in -122 .. 128.

```
-2^16 <= M <= -2^15:   bits(0x80000000 | (E + 126) << 23 | (M == -2^16 ? 0x7FFFE0 : (-M - 2^15) << 8))   // the window
M > -2^15:             between(0x80000000 | (E + 126) << 23, M + 2^15)                                 // above it
M < -2^16:             between(0x80000000 | (E + 125) << 23, 2^31 + max(M + 2^30, 0))                  // below it
```

M's range at the callers: from the block store (H12b) below 2^43 in size (`tu < 2^54`, `sh >= 11` when `nsh < 0`;
2^34.1 in `isp.md` 9.6's run, and at most 2^23 at every covered pixel there); from `regdepth` below 2^18; from `flat`
and `bgkey` at most 2^16. From M = -2^30 down the key no longer moves.

**f. `flat(v)`** (L180; perpmean_*, depthgaps_detneg, _tinymean): a flat plane's or a mean's key.

```
v.bad:  saturated(v.neg);   v == 0: key 0;   v > 0: from_fp(cut_19(v))
v < 0:  s = cut_20(v);  E = clamp(top(s), -122, 128);  neg(E, -ceil(|s| / 2^(E - 16)))
```

**g. `regdepth(r)`** (L700; zword, depthgaps_mm, nantr_*), `r` the 30-bit register in units of 2^102:

```
r = ((r + 2^29) mod 2^30) - 2^29
r == 0:   key 0
r > 0:    r >= 2^26: big(cut_19({0, 0, 102, r}));  else bits((p + 229) << 23 | (r << (23 - p) or >> (p - 23)) & 0x7FFFE0), p = BL(r) - 1
r < 0:    u = r + 2^29;  u == 0: bits(0x807FFFFF);  else p = BL(u) - 1;  neg(p + 100, floor((u << (28 - p) - 2^29) / 2^10))
```

**h. `bgkey(bg)`** (lists.cpp L637-653; bgdepth, bgspec, bgbig, bgneg, bgneg2, depthgaps_bglow*, _bgpin), from
ISP_BACKGND_D, `f = bg[30:23]`:

```
bg[31] == 0:  cut = max(5, 130 - f);  w = cut > 23 ? 0 : bg & ~((1 << cut) - 1);  f == 255: w -= 1 << 23;  bits(w)
bg[31] == 1:  f' = f == 255 ? 254 : f;  E = max(f' - 126, 6);  m = (0x800000 | bg[22:0]) >> 4
              t = f' < 107 ? 0 : (f' - 120 - E >= 0 ? m << (f' - 120 - E) : m >> (E + 120 - f'))   // 0 if shifted 64+
              t == 0 ? key 0 : neg(E, -((t + 1023) >> 10))
```

**i. The block store** (H12b) and the TR peel's reset `bits(0x7F7FFFFF)` (lists.cpp L763) use the functions above.

### H15 `color_round`: colour from the quotient

`ColorRounded(q, -8, max, fallback)` (L519; cmeas 2,340,000 of 2,340,000; shade 80,256 of 80,256; huge):

```
q.bad: fallback;   q.neg or q == 0: 0
top(q) + 8 > 30: max
twice = floor(q * 2^9)          // exact shift; q >= 0
v = (twice + 1) >> 1            // floor(q 2^8 + 1/2): to nearest, half up
twice > 2 max: max;  else min(v, max)
```

`max` is 255, or 65535 for a base colour that the intensity shadow scales before clamping. A quotient from `divide`
is never bad, so `fallback` is reachable only from a caller with a bad quotient.

---

## 7. Test plan

### 7.1 The harness

- **Layout.** RTL goes in `rtl/v1/fp/` (one file per primitive, plus a package of width constants). Testbenches
  go in `tb/fp/<prim>_tb.cpp`, with a `<prim>_tb_top.sv` where needed. There is one Makefile target per primitive,
  `make fp-<prim>` (dedicated testbenches, not one shared tb), and two aggregates: `make fp` (quick: every tb in
  quick mode, under a minute in total) and `make fp-full` (the exhaustive sweeps, run once at the end of a change).
- **Reference.** The tb C++ includes the refcore headers **read-only** from
  `REFCORE ?= ../nulldc3/refsw3/refcore` (relative to polly2-rtl): `pvr_softfp.h`, `pvr_isp_edge.h`,
  `pvr_isp_depth.h`, `pvr_tsp_plane.h`. They are header-only and compile standalone (C++17, `__int128`). The tb
  prints the nulldc3 commit it was built against (`git -C $(REFCORE) rev-parse HEAD`), so that a reference change
  shows in the log. Verilator flags: `-CFLAGS -std=c++17 -CFLAGS -I$(REFCORE)`.
- **Reference calls.**
  - Use the HW instance types where the site uses them: `pvrfp::Mul(a, b, pvrfp::C<24>{})`,
    `pvrfp::Add(a, b, pvrfp::C<24>{}, pvrfp::C<25>{})`, `Recip(v, C<24>{})`.
  - Use the literal `int` where the site does: `Add(a, b, 62, 400)`, `Add(x, y, 24, 53)`.
  - For the exhaustive small-width structure checks, call the same templates with plain `int`s (W = 8, R = 9 and
    so on). The reference is generic, so a parameterized RTL can be proven exhaustively at small widths and then
    sampled at full width.
- **Comparison.** Every output field: `neg`, `bad`, `mant`, and `exp` when `mant != 0`. For integer outputs, the
  value. Before packing a reference value, assert that `exp` fits in 10 bits and that `mant` fits in the port.
- **Lockstep.** One vector per clock. The tb keeps a queue of the expected results and compares at the
  primitive's latency. Report the first 20 mismatches with every operand as a hex tuple and the case class. The
  pass criterion is **0 mismatches**.
- **Environment hygiene.** Unset `MIP_K` and `MIP_ARITH` (`MipSelect` reads them). Set `pvrfp::perpVal`
  explicitly in every tb that calls `Perpendicular`.
- **Copied reference code.** Some reference rules are local lambdas or static functions in `.cpp` files and
  cannot be called:
  - the depth `limit`, `mul`, `add`, `sub` (`pvr_isp_depth.h` L324-371), the mean's `addBad` (L571-575) and the
    REG's `rstep` (L433-444);
  - the TSP `mul`, `addTerm`, `sum3`, `withZero` (`pvr_tsp_plane.h` L145-184, L256-267);
  - the mip `kind`, `rmul`, `radd` (L602-612, L699-730);
  - the edge `swamp` (L113, L181) and `unitsAt` (L239-257);
  - the `Value` normalizer (L377-397);
  - `TexCoordFixed` / `CoordKeep` (`refsw_tile.cpp` L1264-1318);
  - the fog arithmetic (L1728-1755);
  - the background key (`refsw_lists.cpp` L637-653).

  Copy them **verbatim** into `tb/fp/ref_copies.h`, each between markers that name the file and the anchor text.
  `tools/check_ref_copies.sh` re-extracts the anchored blocks from `$(REFCORE)` and diffs them; `make fp` runs it
  first and fails on any drift.

  Where a public entry point exists, the tbs also exercise the rule in place:
  - `PlaneT::Value`: set `A`, `B`, `C`, `cfg` directly;
  - `DepthTileT::At`: set `d0`, `dx`, `dy`, `unit`, `E`, `valid`, `block` (or `ovf`, `r0`, `sa`, `sb`, `fa`, `fb`, or
    `first_z`) directly on an object (`Setup` resets them all);
  - `StoredDepth::{Key32, Bits, Between, FromFp, Saturated, Big, Neg, Flat}` and `DepthTileT::RegDepth`, `NegWord`
    (public);
  - `EdgeWinding`; `EdgeTile::Setup`, `SetFirstRow`, `Inside`, `InsideOrdinary`, `RowMask`.
- **Speed.** Expect roughly 2 to 10 million vectors a second for a small combinational DUT, with one reference call
  per vector. Quick mode stays under about 10 s per tb. Full sweeps of 2^32 (minutes) run only in `make fp-full`.

### 7.2 Vector classes (shared generator, `tb/fp/vecgen.h`, xorshift with a printed seed)

- **mantissas**
  - `N24`: normalized 24-bit (bit 23 set);
  - `U`: unnormalized (BL uniform 1..24, random below the leading one);
  - `P2`: powers of two;
  - `ONES`: `2^b - 1`;
  - `NEAR`: `2^b ± 1`;
  - the constants of section 3.5;
  - from inputs: every `FromBits` / `FromSingle` form (denormals, fields 0, 1, 254, 255).
- **exponents**: uniform over the unit's range (section 1.4), plus edges. In tops: -148, -125 .. -127, 0, 127 .. 129,
  132, 133, 256 .. 259. In range terms: values exactly at 2^-126, 2^-125, 2^128 and one unit either side.
- **signs**: all four combinations; zeros ±0 (5 %); bad ± (2 %), with mant 0 and, for adds, also flagged values
  with a mantissa.
- **pairs for adders**: the top gap `g` drawn from {-30..30} ∪ {±(R-1), ±R, ±(R+1)} ∪ uniform up to ±300.
  Cancellation pairs: `b = -a + δ`, with `δ` a few units of `a`'s last bit or 2^-k of it. Same and opposite sign in
  equal shares.
- **products crossing a boundary**: `mx * my` just under and over `2^(BL(x) + BL(y) - 1)`. Products at
  2^128 - ε, 2^128, 2^-126 - ε, 2^-126.

### 7.3 Per primitive

| prim | reference | exhaustive | random and boundary | quick / full |
|---|---|---|---|---|
| H1 lzc | `BitLength` | 24-bit: all 2^24 | 64/108/128-bit: every leading position × 4096 random tails | 2 s |
| H2 cut | `Fp::cut` | N in {8, 16, 19, 20, 24}: all 2^24 24-bit mantissas (+ exp extremes, both signs, bad) | 62/64-bit inputs: every BL × 4096 | 5 s |
| H3 cutBelow | `Fp::cutBelow` | 16-bit mantissas × `e - exp` in -4..70 × sign | 24-bit random; shifts ≥ 64 | 2 s |
| H4 inputs | `FromBits`, `FromSingle(u, 0/1)`, `FromHalves`, `SingleBits` | all 256 fields × 128 mantissa patterns × sign; `SingleBits` all 256 colours; `FromHalves` all `k` in ±2^14; `seen` on all classes | full: all 2^32 words for `FromBits` / `FromSingle` | 1 s / ~2 min |
| H5 mul | `Mul(a, b, C<N>)` | AW = BW = 10, N = 10: all mantissa pairs × 3 exp offsets (~3M); 8×8 → 8: all 2^16; constants `0xAAAAAB` and `0x95F612` × all 2^23 normalized mantissas | 24×24 → 24: 20M from section 7.2 (quick 2M); TSP 16 × 13: every coordinate 0..2^13 × 512 coefficients; fog 8 × 16 all 2^24 | 10 s / 2 min |
| H6 add 24/25, 24/53 | `Add(a, b, C<24>, C<25>)`, `Add(a, b, 24, 53)` | W = 8 with R = 9 and R = 12: all pairs of 1..8-bit mantissas × top gaps -14..14 × 4 sign combinations (~9M); the far-path formula for R = 53 at W = 8 | 30M (quick 3M) from section 7.2; zeros (all four sign combinations), `x + (-x)`, bad operands with and without mantissa | 15 s / 3 min |
| H7a swamp | the copied `swamp`; in place through `EdgeWinding` and `EdgeTile::Setup` (`t0`, `f0`, `big`) | every top 120 .. 140 × mantissas {1, 0x800000, 0xFFFFFF, U} × both signs; products at exactly 2^128 and one unit below; two swamped operands of either signs | the far class of PLAN M2 (steps of 2^123 and more, products at exactly 2^128, both signs, `x0 = 0` and `y0 = 0`) | 2 s |
| H7b half line | `PlaneT::Value(..., super = true, hx, hy = 1)` and the bare `Add(c_, bh, 62, 400)` + `FloorUnits` | `C` exponent -60..-10 × `B` in {±0, ±bad, tiny ±, ordinary} × grid offsets; exp gaps 40..100 | random coefficients and positions | 3 s |
| H7c mip minor | `Sub(q1, q2, 62, 200).cut(24)` | gaps 0..120 × LSB offsets × signs, with `q2` mantissas {1, 0x800000, U} | random 24-bit pairs | 2 s |
| H8 recip | `Recip(v, C<24>)` | all 2^23 normalized mantissas × 3 exponents × 2 signs; every unnormalized form 1..23 bits of 4096 values | the dividers' corner cases: `dn = 2^23`, `2^23 + 1`, `2^24 - 1` | 5 s |
| H9 cmp | `AbsAtMost`, `AtMost`, `atLeastPow2`, `Perpendicular`, `CulledBySize` / `Facing` (copy) | registers: every exponent field × {0, 1, 0x400000, 0x7FFFFF} × sign bit | `det` at the threshold in three representations, ±1 unit, both signs, ±0, bad | 2 s |
| H10 range | copies + in place via `PlaneT::Setup`, `DepthTileT::Setup` | class pairs {±0, ±bad, [2^-126, 2^-125), [2^-125, 2^-124), ordinary, [2^127, 2^128)} for both operands, 1000 members a pair, each flavour; `withZero`: every `z` in [2^-126, 2^-125) (2^23 × 2 signs) against zeros of every fraction; `add_d`'s zero rule: every `v` in [2^-126, 2^-125) × 2 signs against ±0, one-bit mantissas (D2), `-0 + -0`; `addInf`: field-255 pairs with equal, larger and smaller fractions, both signs | random sums and products that land at 2^128 and 2^-126 exactly | 3 s |
| H11 floor | `FloorScaled`, `FloorUnits`, copies of `units` and `TexCoordFixed` | 17-bit mantissas × shift -70..45 × sign + ±0 (~30M, quick: 16-bit) | the clamps (2^40, 2^30) ±1 | 5 s / 30 s |
| H12a value norm | copy of the normalizer; `PlaneT::Value` in place | `k` in [-2^20, 2^20] × `unit` in {-170..-100, 0} | random 27-bit `k` | 5 s |
| H12b depth block | `DepthTileT::At` with the block form set | | random `d0`, `dx`, `dy` within `isp.md` 9.4a's bounds (`\|S\| < 2^27`, `\|DX\|, \|DY\| < 2^21`, `gexp - unit` 0 .. 25), `i, j` 0..31, both `h`, `E` at both clamps (`nsh` -15 .. 14, the fallback word) | 3 s |
| H13 divider | `RecipTable::Mantissa`, `DenominatorSeen`, `Divide` | `recip_mant`: all 32768; `denominator_seen`: all 16-bit mantissas × both signs × tops around -127, plus the 17-bit `2^16`; `divide`: all 2^16 + 1 numerators × 64 denominators and all 32768 denominators × 64 numerators, both signs; `den` ±0, `-2^-143`, `0xFFFF 2^-143`; `num` 0 | random tuples | 5 s |
| H14 depth key | `StoredDepth::{Key32, Bits, Between, FromFp, Saturated, Big, Neg, Flat}`, `DepthTileT::RegDepth`, copy of the background key | `key32`, `bgkey`: all 2^32 words (full); `regdepth`: all 2^30 registers (full) and every whole step; `neg(E, M)`: E -122 .. 128 × M in [-2^23, 0) (full; quick: M around -2^15, -2^16, -2^30 and ±2^k); `from_fp`, `big`: every 19-bit mantissa at every exponent (full; quick: 17-bit); `flat`: every 20-bit negative mantissa × 8 exponents including both clamps | `key32`: 2^24 random + every boundary word (±0, NaNs, ±inf, denormals); M ≤ -2^30 | 10 s / 5 min |
| H15 colour | `ColorRounded` | all 2^17 mantissas × exponent -40..20 × sign × max {255, 65535} (~32M; quick: 2^14) | bad, zero | 5 s / 30 s |

### 7.4 After the primitives

The unit-level lockstep (the next milestones) replays the archived console data through the same units in RTL:

- `EdgeTile` / `Winding` against covmeas (`dreamcast-tests/model/covprobe`, 96 sets);
- `DepthTileT` against zmeas (`depthprobe`, 13 sets, 89,801 brackets);
- `PlaneT` and `Divide` against uvmeas, wmeas and cmeas (`tspprobe`, 31 sets);
- `MipSelect` against mipmeas and mipk.

The probes' exporters (`model/export_cov.py`, `export_z.py`, `export_uv.py`) produce the input files. The
operation counts and their sharing per triangle, tile, run and pixel belong to the architecture and timing
specifications.

---

## 8. GAPs, artifacts and defects

### Artifacts (the RTL reproduces them; the owner decides whether to measure them)

- **A1 Wide adds: a 90-exponent window, then truncation to 62 bits.** `Add(., ., 62, R >= 200)` is not exact. It
  drops the operand whose LSB exponent is more than 90 below the other's, which depends on the representation
  (section 1.3), and it truncates the sum to 62 bits. Shown with `agents/spec-numerics/probe.cpp`:
  - (The edge start's wide add, `2d08a440` L137, went with `6784ea3d`: H7a.)
  - **TSP L368** (SupSample, `hy`): a `B/2` more than 90 exponents below `C` adds nothing. For a negative `C` the
    limit is 46 exponents, because of the 62-bit truncation (table in H7b). With `B = -0` this means: no unit down
    for a positive 16-bit `C >= 2^-22` and for a negative `C` of `|C| >= 2^-66`, where exact arithmetic gives -1
    when `C` is on the grid. This is consistent with every pixel of supsample, supsample2, ssrare and sshalf, but
    it is not known whether those pages contain such planes. Probe suggestion: an ssrare-like page with planes flat
    in y on negative-determinant triangles (`B = -0`), both signs of `C`, `C` from 2^-80 to 2^10.
  - **mip L642**: a `q2` more than 90 exponents below `q1` takes no borrow.

  `tsp.md`'s conventions call `N = 62` / `R = 200/400` "exact". That holds at L265 and for the experiments, not at
  L368 or L642.
- **A2 (closed at `708fb8cd`).** A negative block pixel no longer becomes a float: `NegWord` takes the exact `tu`
  (H12b). A positive `tu` has at most 54 bits, so `At`'s truncation to 64 significant bits (L736-740) never acts.
  The tbs assert it.
- **A3 (closed).** The float form (L630-631, L742-747) is unreachable with `startOnSlopes = 1` (`isp.md` 9.4a: the
  proof, and 0 of 300,000 random planes). `coefBits` stays invisible. The RTL has no float form; the tbs assert that
  refsw3 never takes it.
- **A4 Unreachable clamps.** `FloorUnits`' `s >= 62` (L97), the depth REG `r0`'s `sh < 40` (L481), `Add`'s step 5
  `cut_32`, and `Mul`'s input `cut_32`. The RTL omits them and the tbs assert that they never act.
- **A5 `NegWord`'s fallback word** (L666-667). With `sh = E - 15 - unit < 0` refsw3 stores `0x80000000 | (E + 126)
  << 23` (0xFF000000: E is 128 there) and calls it "not reached". `At` does reach it, for planes whose start was cut
  to zero with slopes of 2^134 and more (`nsh < 0`, `isp.md` 9.6), at pixels the triangle does not cover: 26,404
  pixels of 300,000 random planes, none covered (`agents/spec-refresh/widths708.cpp`). The RTL reproduces it, so that
  a lockstep that compares every lane holds.

### Defect

- **D1 `MipSelect` divides by zero** (L619: `Recip(det = w.Sdet, 24)` with `Sdet == 0`). A mipmapped triangle whose
  TSP determinant is exactly zero crashes refsw3 with SIGFPE. Examples: three equal corners, or collinear corners
  whose sum cancels exactly. Such triangles are drawn when not culled (covmeas mix degen). Reproduced in the
  scratch run: three equal corners give `Sdet = +0`, then SIGFPE. The console's value is unknown.

  Proposal for the RTL until a console test settles it: treat the reciprocal as `+0`, as for a bad determinant.
  Then `undivided` is false, both numerators are 0, the length is zero, `K = 2^(-127 + size)`, and the level
  follows from the pixel's `w`.

  Console probe: covmeas degen triangles with a mipmapped texture whose levels are flat colours (mipdump's method).
- **D2 The depth zero rule shifts by -1** (depth L363: `(v.mant >> (n - 2)) & 1` with `n = BL(v.mant)`). For a
  one-bit mantissa (`{mant 1, exp -126}` = 2^-126, which a sum whose operands' exponents are -126 or more can produce)
  the shift is -1, undefined in C++ (UBSan: "shift exponent -1 is negative"). GCC on x86-64 computes 0 at -O0 and
  -O2, so the rule applies and the sum is +0. That is the value rule, `|v| < 1.5 * 2^-126`
  (`agents/spec-refresh/zrule_n1.cpp`). The RTL implements the value rule; a tb that meets the one-bit case expects
  +0.

### GAPs (unmeasured)

- **G1** `MipSelect`'s DCalcCtrl-1 sums (`radd`, L726) use **reach 53**, the TSP's value before uvmeas reach1
  established 25 for the setup adders. mipmeas mwextd1 (4,147,200 of 4,147,200) does not tell 53 and 25 apart. The
  RTL implements 53, to match the reference.
- **G2** `zeroReach` 2 or 3: whether the TSP's last-addition zero rule reaches 2^-125 or 2^-124. Probably not
  observable (README).
- **G3** (closed by `6784ea3d`: the swamp per product; faredge 1,340 of 1,340, the 2^132 rule is gone.)
- **G4** (closed by `708fb8cd`: 2^128 is checked at every product and sum; zovf 1,080 of 1,080.)
- **G5** Depth overflow: an infinite determinant gives depth 0 (a guess; detinf is consistent with it). The REG
  words between fields among other planes' depths, a REG slope of 2^128 or more after the division, an off-grid
  REG slope below zero of 2^102 or more, and REG with HALF_OFFSET[0] = 0 are unmeasured (`isp.md` 9.5). (ovf 1's
  word, kWrap / WrapWord's open bits and the negative REG start are gone: the forced start, `RegDepth` and
  depthgaps_rstart measure them.)
- **G6** Stored depth: the order of positive denormal depths among each other (only "above 0, below 2^-126" is
  measured); `big`'s grid (any cut of about 13 to 23 bits fits depthgaps_bigord, 19 is taken). (Negative depths
  outside the window and below 2^-122, and positive ones from 2^128, are measured since `708fb8cd`: H14.)
- **G7** The ISP depth's range rules: measured on the depth unit since `708fb8cd` (section 4.1). Open: the zero
  rule's reach into the depth setup's coordinate differences and determinant (one shared adder in refsw3; only the
  depth products' sums were measured).
- **G8** The TSP value of -1 unit is `-2^-143`. Measured only as "below 2^-130"; the divider's reading of it is
  pinned by texfar_m1.
- **G9** The mean: a division by 3 or a multiplication by `0xAAAAAB 2^-25` give the same 19 bits for every 24-bit
  sum (checked by the README over all 2^23 mantissas). This is not observable, and the RTL may use either. The
  ISP's adds have their own zero rule (section 4.1), the TSP's mean its own (`tsp.md` 4.4).
- **G10** (closed by `6784ea3d`: a coordinate difference of 2^128 or more swamps in the start's products and steps
  by ±2^127; hugepos_v4-v6, hugepos a's 4 pixels in row 0.)
- **G11** The exponent field bounds (section 1.4) are derived, not measured. Since the reference has 32-bit
  exponents, the tbs assert the bounds.
- **G12** (closed by `708fb8cd`: the mean with infinite or NaN corners, depthgaps_dzinf.)
- **G13** The edge walk's fine units 2^(unit - 6) (`isp.md` 8.4b): only the decisions are measured. The RTL keeps
  refsw3's.
