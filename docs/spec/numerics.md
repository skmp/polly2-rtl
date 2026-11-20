# Numerics: the setup units' arithmetic and the RTL's primitives

polly2-rtl specification, role spec-numerics, 2026-11-20. Basis of the first RTL milestone: the arithmetic
primitives, each verified in lockstep against the refsw3 function it implements.

**Reference (functional truth).** nulldc3 branch `skmp/refsw3` at `2d08a440` (clean tree), folder
`refsw3/refcore/`: `pvr_softfp.h`, `pvr_bits.h` and their users `pvr_isp_edge.h`, `pvr_isp_depth.h`,
`pvr_tsp_plane.h`, `refsw_tile.h`, `refsw_tile.cpp`, `refsw_lists.cpp`. Every line number in this document refers
to that commit. **Evidence:** dreamcast-tests at `f7cb4e5`, `README.md` (the section is named with each rule) and
`TODO.md`.

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
   `inf - inf = +0`; a sum below the range is `+0`; the TSP's last addition has a rule for zero operands.
6. The TSP divider is a 16-bit table reciprocal (512 entries of `(t, n)` and a 6-bit linear step), times the
   numerator, floored at 17 fractional bits. A negative denominator is read with its 15 bits under the leading one
   negated.
7. The minimal hardware set is H1 to H15 (section 6). The tests are in section 7, and the GAPs, artifacts and the
   one defect are in section 8 (D1: refsw3 divides by zero in `MipSelect` on a determinant-zero triangle).

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
| range wrappers | a product below 2^-126 keeps `xor`; a **sum** below 2^-126 becomes **+0** |
| TSP `Value` (k = 0), `Divide` (numerator 0) | `+0` |

**Who looks at the sign of a zero.**

- The TSP evaluator, in two ways. `FloorUnits(-0) = -1`, one grid unit below zero (uvmeas point 5: on a triangle
  with a negative determinant a flat plane steps one unit down per pixel; this is the 60 % of flat triangles that
  read one fog level low in wmeas). `seen(+-0) = +-2^-127`.
- The ISP edge and depth units do not: `units()` and `FloorScaled` return 0 for either zero.

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

A datapath that normalizes internally must recompute `out.exp` with this formula. The contract matters at three
sites (edge L137, TSP L370, mip L644; see H7). It is imposed everywhere so that every primitive's output can feed
those sites.

### 1.4 Ranges and RTL field widths

The bounds below are derived from the code, not measured (GAP G11). The testbenches assert that every reference
`exp` fits before packing it.

| where | LSB `exp` range | `top` range | why |
|---|---|---|---|
| edge unit (unranged, `FromBits`) | ≥ -298 | ≤ 259 | denormal × denormal = 2^-298; `x y` products ≤ 2^256, `c` ≤ 2^257, `det` ≤ 2^259; `dx` ≤ 2^129; `Mul(dx, y0)` ≤ 2^142; the start saturates (≤ 2^133) |
| depth setup (ranged) | ≥ -150 after range | ≤ 128 | numbers in [2^-126, 2^128) |
| depth `Recip`, `A, B, C, first` (unranged) | ≥ -278 | ≤ 255 | `inv` in (2^-128, 2^126]; `a * inv` up to 2^255; `under()` only zeroes small values |
| TSP setup (ranged) | ≥ -150 | ≤ 128 | as depth |
| TSP `Value` | ≥ -149 | ≤ 142 | `e` ≤ 139 (a coefficient below 2^128 times a coordinate below 2^12), `unit = e - 22` ≥ -149; the normalizer's -128 floor and -2^-143 |
| TSP `Divide` | -300 .. 253 | ≤ 271 | `en + 1 - ed - 17` with `en` in [-142, 142] and `ed` in [-127, 142]; the README's largest observed quotient is about 2^243 (texfar_quot) |
| mip | within the above | | K, w, w·w have explicit clamps (H10, `tsp.md` 8) |

**Exponent field: 10 bits, two's complement (-512 .. 511).** Every reachable value lies in -300 .. 259.

**Mantissa widths.** At every HW-path input of a 24-bit operation the mantissa has **24 bits or fewer**. The
inputs are `FromBits` / `FromSingle` (24), outputs of 24-bit operations, `FromHalves` (≤ 13 bits for screen
coordinates up to 2^12), `Pow2` and the 24-bit constants. So the `cut_32` that `Mul` and `Add` apply to their
inputs (L334, L357) never does anything in the HW configuration. The RTL does not implement it, and the
testbenches assert it.

---

## 2. `pvr_bits.h` and `pvr_softfp.h`, operation by operation

### 2.1 `BitLength`, `TrailingZeros` (`pvr_bits.h` L13, L31)

- `BitLength(v)` = `64 - clz(v)`, 0 for 0. In hardware this is a priority encoder (H1) of the width of the
  operand: 16, 17, 24, 25, 34, 50, 64, 108 or 128 bits at the sites below.
- `TrailingZeros(v)` (v ≠ 0) = `ctz(v)`. It is used only by `FromDouble` (host only) and by `TextureFilter`'s
  `log2` of a texture size, which is a power of two (`refsw_tile.cpp` L1317: a decoder of `TexU` / `TexV`, not
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

- the edge unit's vertex `x`, `y` (`refsw_tile.cpp` L748-749 for culling, L770-771 for drawing);
- `FPU_CULL_VAL & 0x7fffffff` (0x078, L730);
- `FPU_PERP_VAL & 0x7fffffff` (0x084, `refsw_lists.cpp` L378).

**`FromSingle(u, ranged)`** (L161): with `ranged = 0` it is `FromBits`. With `ranged = 1` (every HW use):

- `neg = u[31]`.
- `f == 255`: `bad`, `mant 0`, **sign kept**.
- `f == 0`: +-0, the fraction ignored.
- otherwise: as `FromBits`.

It is used for:

- the depth setup's `x, y, z` (`pvr_isp_depth.h` L231);
- the TSP setup's `x, y, z` and attributes (`pvr_tsp_plane.h` L149);
- `MipSelect` with DCalcCtrl 1: `u1, v1, z1, x1, y1` (L700).

[uvmeas wexp, whuge, wtiny, wspec: "field 0 is zero, 255 infinity, whatever the mantissa says"]

**`FromHalves(k)`** (L198): `{neg k < 0, mant |k|, exp -1}`, which is `k / 2`, exact, with trailing zeros kept.
The `k` at the HW sites:

- `2·left + HALF_OFFSET[0]` and `2·top + HALF_OFFSET[0]` (edge);
- `2·left + 1` and `2·top + 1` (depth, always the centres);
- `2·(left + i) + c` (depth float form);
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

`mant != 0 && top > e`, that is `|v| >= 2^e`. It is used at edge L124 and L128 (`>= 2^128`) and L136
(`|dy| >= 2^127`).

### 2.7 `Mul(a, b, N)` (L330)

```
bad = a.bad | b.bad;   neg = a.neg ^ b.neg
x = cut_32(a);  y = cut_32(b)                    // no-op at every HW site (<= 24-bit operands)
mant = x.mant * y.mant                           // exact, <= 64 bits
exp  = x.exp + y.exp
return cut_N(that)                               // = trunc_N(a*b), out.exp = max(x.exp+y.exp, top - N)
```

`Mul` is commutative and has no range rules. A zero product is signed (xor).

### 2.8 `Add(a, b, N, R, G = -1)` (L347) and `Sub(a, b, N, R) = Add(a, -b, N, R)` (L391)

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
- **Window rule (case W), ARTIFACT A1.** `|sx - sy| = |(ta - tb) - (BL(x) - BL(y))| <= (R - 1) + 31`, so case W
  is reachable only for `R >= 61`. That means only the wide calls with `R` of 200 or 400: edge L137, TSP L370,
  mip L644. Case W depends on the representation (section 1.3). When `ta == tb` it returns `b`, but that tie is
  unreachable because equal tops put the exponents within 31 of each other.
- **Guard `G` (step 6):** `if G >= 0`, the smaller operand is first `cutBelow(top(larger) - N - G)`. No HW
  instance uses it: `EdgeHW::guard = C<-1>` (the README covmeas point 3 says "otherwise the sum is exact before the
  cut, as with a sticky bit"), and every other call takes the default -1. **Do not implement it.**
- **Commutativity.** `Add` is commutative at every HW site; the only asymmetry is case W's unreachable tie. The
  **order of a three-term sum is not free** (24-bit truncation and the reach make it observable). Section 5 gives
  the order for every sum.

### 2.9 `Recip(v, N)` (L395)

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

`v` must be finite; the caller has already returned on a bad corner (`refsw_tile.cpp` L777-778). The only site is
`RowRange` (edge L91): `floor(y)` and `(floor(2y) + 1) >> 1 = floor(y + 1/2)` with an arithmetic shift.
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
Perpendicular(det):            // det = the ranged setup's determinant (depth L263, TSP L214)
  det == 0 and not bad:  false                         // a zero is one already
  det.bad:               perpVal.bad                   // an infinite FPU_PERP_VAL takes an infinite det
  otherwise:             (perpVal.bad or perpVal != 0) and AbsAtMost(det, perpVal)
```

[perpval: 136,764 pixels the console changes at 2^20, all exact; perpeq: a determinant equal to the register counts,
1800 of 1800; detinf, perpval with 0x7fc00000, 0xffc00000, 0xff800000, 0x7f800001: every NaN and -infinity acts as
+infinity]

```
CulledBySize(det):             // det = the edge unit's UNRANGED Winding determinant
  det.bad:                         false
  size = FPU_CULL_VAL & 0x7fffffff
  size >= 0x7f800000:              true                // infinity or any NaN culls every triangle
  otherwise:                       AbsAtMost(det, FromBits(size))   // equal is culled; a denormal register is kept
CulledByFacing(mode, det):
  mode < 2 or det.bad or det == 0: false
  otherwise:                       (mode & 1) ? !det.neg : det.neg
```

[cullval: only the register's size counts, every NaN culls like +infinity, 2^-149 culls nothing, 4800 of 4800
regions; raster page 4: equal is culled]

---

## 3. The configurations

All three are `struct`s of `pvrfp::C<N>` (`std::integral_constant<int, N>`) in the HW form. The `...Config`
twins are plain `int`s for the probes and have the same defaults; the code is templated on either. The evidence
column gives the test and what it showed. Where the dreamcast-tests probes scanned a parameter one step either
way, the numbers are pixels or readings wrong: with the measured value they are 0.

### 3.1 `EdgeHW` (`pvr_isp_edge.h` L33)

Evidence: covmeas (98 archived sets, 0 differences) and hugepos. The scan is `model/covprobe --scan` summed over
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
| `overflowExp` | 128 | start saturates when `first` or the start reaches 2^128 ... | hugepos (triangle a at 2^118 .. 2^124, the console's pixels exactly) |
| `saturateExp` | 127 | ... to +-2^127; the `+5` at L137 is 2^132 | faredge pages 12-35, modvol 192 of 192; GAP G3 |
| `lastColumnByStep` | true | a zero pixel in column 31 goes by the column step's sign | 0: 246 |

### 3.2 `DepthHW` (`pvr_isp_depth.h` L41)

Evidence: zmeas (13 sets, 89,801 brackets, 0 missed), zstart, covmeas zprobe, perpmean_*. The scan is
`model/depthprobe`, one step off each way.

| constant | value | use | evidence |
|---|---|---|---|
| `productBits` | 24 | `z * diff`, `z * e`, `a x0`, `b y0` | 23 / 25: 4330 / 3734 |
| `sumBits` | 24 | | 23 / 25: 3480 / 2460 |
| `reach` | 25 | taken from the edge unit | reach ≥ 24 changes nothing on the depth data (20: 673); not measured on the depth unit itself |
| `recipBits` | 24 | `1 / det` | 23 / 25: 206 / 78 |
| `coefBits` | 24 | `a*inv`, `b*inv`, `c*inv`, `start*inv`, `mean * 1/3` | not visible through the block path (each value is cut to 20 next, and cuts compose); visible only in the float-form fallback (ARTIFACT A3). perpmean_word: the mean cut to 24 then 20 |
| `startBits` | 20 | tile start | 19 / 21: 1137 / 594 |
| `slopeBits` | 20 | `A`, `B` steps | zmeas 3 |
| `pairBits` | 21 | the steps' shared grid | 20 / 22: 187 / 41 |
| `tileBits` | 26 | grid 26 bits under the start's exponent | 25 / 27: 472 / 232 |
| `storedBits` | 19 | stored depth above zero | zmeas, zblock, precision |
| `storedNegBits` | 16 | stored depth below zero, size rounded up | perpmean_bg, perpmean_neg, perpmean_negstore, depthgaps_negpp 360 of 360 |
| `startOnSlopes` | 1 | the start is cut to the slopes' grid too | zstart 49,152 of 49,152 (0 is the old model; 2 keeps only negative starts cut) |
| `range` | 1 | range rules (section 4) | huge 250 of 250 regions (228 without); zspec 1040 of 1040; GAP G7 |

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
| `N = 62, R = 400` | edge L137; TSP L267, L370 (L333, L343: experiments) | "wide": window 90, truncation to 62 bits (A1) |
| `N = 62, R = 200` | mip L644, L655, L678, L736 | the same; L655 and L736 are dead in the HW config (section 5.3), L678 is MIP_K 1 |
| `N = 62, R = 25` | mip L688, L689, followed by `.cut(24)` | identical to `Add(., 24, 25)` (checked: 4,000,000 random pairs, 0 differences) |
| `N = 24, R = 53` | mip L728 (`radd`, DCalcCtrl 1) | the TSP reach before reach1; GAP G1 |
| `Mul(., ., 62)` | TSP L328, L365; mip L648, L676, L688, L761 | exact for these operand widths (≤ 48 bits) |
| `Mul(., ., 24)`, `Recip(., 24)` | mip L612, L621, L625, L643, L708, L747 | literal 24 = `PlaneHW` widths |
| `Mul(., ., 8)`, `.cut(8)` | mip L764, L775, L781, L784 | 8-bit mip arithmetic |

### 3.5 Constants

| constant | value | site | evidence |
|---|---|---|---|
| 1/3, rounded up | `0xAAAAAB * 2^-25` (`0x3EAAAAAB`) | depth mean L363; TSP flat L246 | perpmean_word 16,384 of 16,384 (0xAAAAAA: 1,618 wrong); slivers_detzero 9,600 of 9,600 (0xAAAAAA: 8,143); perpmean_uv 8,192 |
| 2 - sqrt(2), less 8 units | `0x95F612 * 2^-24` (`0x3F15F612`) | mip L686 | mipk4 / mipk3 lenfit 3,920 cells, mipk2 2,401 of 2,401 |
| saturated edge start | `+-2^127`, `+-2^132` | edge L125, L137, L139 | hugepos, faredge |
| evaluator zero / infinity | `+-2^-127`, `+-2^-128` | TSP L314-315 | uvmeas wexp, whuge: 4875 of 4875 |
| value of -1 unit | `-2^-143` | TSP L383 | wzero1 (below 2^-130); GAP G8 |
| divider: -1 unit | `0xFFFF * 2^-143` | TSP L457 | texfar_m1 166 of 166, texfar_m1q |
| divider: zero denominator | `2^-128` | TSP L482 | wzero2 32,784 readings |
| stored overflow | `0x7F000000` or the sign bit | depth L112 | bgbig, bgspec, zsign page 15 |
| `27146 / 65536` | | mip L676, MIP_K 1 only | not HW |

---

## 4. The range rules (ranged arithmetic)

### 4.1 The rules as measured

These are measured for the TSP setup and adopted for the ISP depth (GAP G7). [README "The TSP's numbers at their
limits"; uvmeas wexp, whuge, wtiny, wspec, wneg, wzero1, wzero2; cmeas cwext1, cwsum1; mipmeas mwext1, mwextd1]

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

### 4.2 The four flavours side by side

| | edge unit | ISP depth setup (`DepthTileT::Setup` L228-258) | TSP setup (`PlaneT::Setup` L144-184) | TSP mip (`MipSelect` L604-614, L701-732) |
|---|---|---|---|---|
| input | `FromBits` | `FromSingle(., 1)` | `FromSingle(., 1)` | the planes' sums; DCalcCtrl 1: `FromSingle(., 1)` |
| product | `Mul 24`, no range | `mul` | `mul` | `kind`, `rmul` |
| sum | `Add 24/25`, no range | `add` (`limit(., true)`) | `addTerm(., ., false)` | `radd`: **reach 53** |
| `sum3` | `(e1 + e2) + e3` | `add(add(p, q), r)` | `addTerm(addTerm(p, q, false), r, true)` | none |
| reciprocal | none | `Recip 24`, **unranged** | `det.bad ? zero(det.neg) : Recip 24`, then below 2^-126 → `zero(sign)` | `det.bad ? +0 : Recip 24`, then below → `+0` |
| coefficients | | `Mul(., inv, 24)`, **unranged**, then `under()`: below 2^-126 → mant 0, **sign kept** | `mul(., inv)` ranged, then `cut_16` | `Mul(best, inv2, 24)`, then range |

The wrappers, exactly:

```
inf(s)  = {bad 1, neg s, mant 0}          zero(s) = {neg s, mant 0}
above(r) = r != 0 and top(r) - 1 > 127    // |r| >= 2^128
below(r) = r != 0 and top(r) - 1 < -126   // |r| <  2^-126

mul(p, q):                                    // depth L238, TSP L150, mip rmul L701 (the same rule)
  if p.bad or q.bad:
     other = p.bad ? q : p
     return (not other.bad and other == 0) ? zero(p.neg ^ q.neg) : inf(p.neg ^ q.neg)
  r = Mul(p, q, 24)
  above(r): inf(r.neg);  below(r): zero(r.neg);  else r       // r.neg = p.neg ^ q.neg

add(p, q) = addTerm(p, q, third = false)     // depth L245 is this exactly (limit(., true))
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

radd(x, y):                                    // mip L722: as add, but Add(x, y, 24, 53)
kind(x, y):                                    // mip L608: the class of the product x*y
  x.bad or y.bad: ((not x.bad and x == 0) or (not y.bad and y == 0)) ? ZERO : INF
  x == 0 or y == 0: ZERO
  m = Mul(x, y, 24): above(m) ? INF : below(m) ? ZERO : NUMBER
```

The **flat (determinant-zero) mean's first addition** in the TSP (`withZero`, L258-276; slivers_dzspec,
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
  - `inv0` and `inv` = `Recip(det, 24)` (L277, L318, L384) have no range rule, but `det` is in [2^-126, 2^128),
    so `inv` is in (2^-128, 2^126].
  - `first0` (L279) is the **ranged** evaluation of `((a x0 + b y0) + c) * inv0` and decides the overflow regimes.
  - `first` (L389) and `A, B, C` (L385-387) are the **unranged** evaluation of the same expressions, followed by
    `under()` (L394-395). The two give the same value unless an intermediate value leaves the range.
- **Edge.** The edge unit's `det` (unranged, `FromBits`) and the depth unit's or TSP's `det` (ranged,
  `FromSingle`) are the same arithmetic on normal finite inputs whose intermediate values stay within
  [2^-126, 2^128). They differ for denormal, infinite or NaN corners and for products or sums outside the range
  (corners from about 2^64 on). One datapath with a mode bit can serve both. A datapath that computes the
  unranged chain and derives the ranged one from range flags **cannot**, because a ranged infinity or zero changes
  every later operation.

---

## 5. Every call site

How the list was made (and how to make it again after a reference change):

```
cd nulldc3/refsw3/refcore && grep -n -E '(\b(Add|Sub|Mul|Recip|FloorScaled|FloorUnits|SingleBits|AbsAtMost|AtMost|Perpendicular|Divide|ColorRounded|DenominatorSeen|TexCoordFixed)\s*\()|\.cut\(|cutBelow\(|FromSingle\(|FromBits\(|FromHalves\(|Pow2\(|atLeastPow2\(' *.h *.cpp
```

The `op` column names the primitive of section 6. `N/R` gives the width and the reach.

### 5.1 `pvr_isp_edge.h` (`EdgeHW`; inputs `FromBits`; no range)

`Winding` runs once per triangle (`refsw_tile.cpp` L752, L775). `EdgeTile::Setup` runs per edge per tile (L793-797);
`c`, `dx` and `dy` do not depend on the tile. Algorithm: `isp.md` 7.1, 8.3-8.6.

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 73 | `e(j,k) = Sub(Mul(x_j, y_k, 24), Mul(x_k, y_j, 24), 24, 25)` | 2 H5, H6 | 24; 24/25 | `e1 = e(1,2)`, `e2 = e(2,0)`, `e3 = e(0,1)`; `x_j y_k` is the minuend |
| 76 | `det = Add(Add(e1, e2), e3)` | 2 H6 | 24/25 | **order `(e1 + e2) + e3`**; winding = `+1` iff `det < 0` and `det != 0` (zero counts as positive); also feeds `CulledBySize` and `CulledByFacing` |
| 91 | `FloorScaled(y_k, 0)`, `(FloorScaled(y_k, 1) + 1) >> 1` | H11 | clamp 2^40 | row range `floor(ymin) .. floor(ymax + 1/2)`; not for modifier volumes |
| 118 | `c = Sub(Mul(xb, ya, 24), Mul(xa, yb, 24), 24, 25)` | 2 H5, H6 | 24; 24/25 | edge a→b; `xb ya` is the minuend |
| 119 | `dx = Sub(xa, xb)`, `dy = Sub(ya, yb)` | H6 | 24/25 | `top <= 129` |
| 120 | `x0 = FromHalves(2 left + HALF_OFFSET[0])`, likewise `y0` | H4 | | the tile's first sample point |
| 122 | `first = Add(Mul(dx, y0, 24), -Mul(dy, x0, 24), 24, 25, -1)` | 2 H5, H6 | 24; 24/25 | a dropped operand here is what covmeas point 3 saw |
| 124-125 | `first >= 2^128` → `start = Pow2(127, first.neg)` | H9 | | hugepos |
| 127 | `start = Add(first, c, 24, 25, -1)` | H6 | 24/25 | |
| 128-139 | `start >= 2^128`: `abs(dy) >= 2^127` ? `Add(Pow2(132, s), -first, 62, 400)` : `Pow2(127, s)` | H7a | wide | `s = start.neg`; faredge; GAP G3; ARTIFACT A1 |
| 142 | `sy = dx.cut(20)`, `sx = (-dy).cut(20)` | H2 | 20 | |
| 143-144 | `ep = max(top dx, top dy)`, `es = top(start)` | H1 | | |
| 152 | `s20 = start.cut(20)` | H2 | 20 | |
| 160-163 | `E = max(ep + 6, es + 1)`, `unit = ep - 21` | int | | `E - unit > 56`: constant tile (L164); `isp.md` 8.5: 31-bit accumulator |
| 169-170 | `sx, sy .cutBelow(unit)` | H3 | | |
| 171-196 | `t0 = 2 floor(s20 / 2^unit) + frac`; `tx = 2 floor(sx / 2^unit)`; `ty` likewise; `zero2 = 2 << (E - 21 - unit)`; `tie2` likewise | H11 (`units`) | | `units(+-0) = 0`; `frac` = any bit of `s20` below `unit` |

### 5.2 `pvr_isp_depth.h` (`DepthHW`; inputs `FromSingle(., 1)`; ranged)

`DepthTileT::Setup` runs per triangle per tile in refsw3 (`refsw_tile.cpp` L803). In the HW, `a`, `b`, `c` and
`det` are per triangle and the start is per tile. Algorithm: `isp.md` 9.

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 223 | `first_z = Bits(z[0])` | | | the first vertex's word, used when the plane is invalid |
| 231 | `load = FromSingle(u, 1)` | H4 | | `x, y, z` of the three corners in rasterizer order |
| 256 | `edge(j,k) = sub(mul(X_j, Y_k), mul(X_k, Y_j))` | H5+H10, H6+H10 | 24; 24/25 | ranged |
| 259 | `a = sum3(mul(Z0, sub(Y1,Y2)), mul(Z1, sub(Y2,Y0)), mul(Z2, sub(Y0,Y1)))` | H5, H6, H10 | 24; 24/25 | **`(t0 + t1) + t2`** |
| 260 | `b = sum3(mul(Z0, sub(X2,X1)), mul(Z1, sub(X0,X2)), mul(Z2, sub(X1,X0)))` | as above | | `(t0 + t1) + t2` |
| 261 | `c = sum3(mul(Z0, e1), mul(Z2, e3), mul(Z1, e2))` | as above | | **`(t0 + t2) + t1`** [zmeas 1: one of 384 combinations of vertex order and sum orders fits] |
| 262 | `det = sum3(e1, e2, e3)` | H6, H10 | | `(e1 + e2) + e3` |
| 263-264 | `Perpendicular(det)` → `det = +0` | H9 | | |
| 265-274 | `det.bad` → depth 0 everywhere | | | GAP G5 |
| 277 | `inv0 = Recip(det, 24)` | H8 | 24 | unranged |
| 278-279 | `first0 = mul(add(add(mul(a, x00), mul(b, y00)), c), inv0)`, `x00 = FromHalves(2 left + 1)` | H5, H6, H10 | 24; 24/25 | **always the pixel centre**; `(a x0 + b y0) + c` |
| 282 | `first0.bad ? Saturated : FromFp(first0.cut(19))` | H14 | 19 | |
| 309-316 | ovf 2: `r0 = +-2^25` if `first0.bad`, else `st = first0.cut(20)` truncated onto the 2^102 grid | H2, H11 | 20 | sign-magnitude, toward zero; GAP G5 |
| 318-325 | ovf 1: `invS = Recip(det, 24)`; `As, Bs = Mul(a or b, invS, 24)`; `eS = max top + 5` | H8, H5 | 24 | only the tops are used; the low 5 bits of the word are GAP |
| 363-364 | `mean = Mul(sum3(Z0, Z1, Z2), 0xAAAAAB 2^-25, 24)` | H6+H10, H5 | 24 | `(z1 + z2) + z3`, the third corner sent added last; plain `Mul` |
| 365-366 | `mean < 2^-126` → `+0` | H10 | | perpmean_tiny |
| 368 | `mean.bad` → `Saturated(sign)` | H14 | | perpmean_bg page 0 |
| 372-377 | `m = mean.cut(20)`; `unit = top - 26`; `d0 = 2 m / 2^unit`; no slopes | H2, H11 | 20 | stepped as a flat plane |
| 384-387 | `inv = Recip(det, 24)`; `A, B, C = Mul(a, b or c, inv, 24)` | H8, H5 | 24 | **unranged** |
| 388-389 | `first = Mul(Add(Add(Mul(a, x0, 24), Mul(b, y0, 24), 24, 25), c, 24, 25), inv, 24)` | H5, H6 | 24; 24/25 | unranged; the same expression as `first0` |
| 394-395 | `under(A, B, C, first)`: below 2^-126 → `mant 0`, sign kept | H10 | | zspec pages 3-6 |
| 397 | `pair = max(top A, top B)` | H1 | | |
| 408 | `e = first == 0 ? pair + 5 : top(first)` | | | zmeas mix reach: a start of exactly 0 |
| 409-411 | `start = first.cut(20).cutBelow(pair - 21)` | H2, H3 | 20 | zstart |
| 412 | `unit = e - 26` | | | |
| 416 | `step(v) = v.cut(20).cutBelow(pair - 21).cutBelow(unit)` | H2, H3 | 20 | |
| 422 | `pair - 21 + 24 - unit > 100` → float form | | | ARTIFACT A3 |
| 424-428 | `d0 = 2 start / 2^unit`, `dx`, `dy` exact; `negE = max(e, pair + 5)` | H11 | | 2^unit-unit fixed point, up to about 104 bits (`i128`) |
| 505-511 | At: `t = d0 + (2i + h) dx + (2j + h) dy`; to `Fp`, truncated to 64 significant bits | H12b | | `h = 0` at centres, -1 at corners (HALF_OFFSET[0]); ARTIFACT A2 |
| 516-518 | float form: `Add(Add(Mul(A, X, 24), Mul(B, Y, 24), 24, 25), C, 24, 25).cut(19)` | H5, H6, H2 | 24; 24/25; 19 | A3 |
| 529-531 | negative and not in the top binade `negE` → `FromFp(cut_19)`; else `Store(v, 19, 16)` | H14 | 19 / 16 | GAP G6 |
| 96-187 | `StoredDepth::key`, `Saturated`, `FromFp`, `Store` | H14 | | |
| 440-489 | `kWrap[32]`, `WrapWord(r)` | H14e | | zword, nantr_* |

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
| 245-281 | flat: `first` (`withZero` / `addTerm`); `mean = mul(addTerm(first, Z2, true), 0xAAAAAB 2^-25)`; `C = attr ? mul(AT2, mean).cut(16) : mean.cut(16)`; `A = B = +0` | H6, H10, H5, H2 | 24; 16 | section 4.2; `withZero` `Add(., ., 62, 400)` is exact there |
| 287-289 | `inv = det.bad ? zero(det.neg) : Recip(det, 24)`; below → `zero(inv.neg)` | H8, H10 | 24 | hugepos (a determinant above 2^126 gives zero coefficients) |
| 290-293 | `A0, B0, C0 = mul(a, b or c, inv)`; `A, B, C = .cut(16)` | H5, H10, H2 | 24; 16 | `A0, B0, C0` only feed dead mip paths (below), so effectively `Mul(., ., 16)` |

**Evaluator `Value`** (per run start and per pixel; L304-400):

| line | expression | op | notes |
|---|---|---|---|
| 313-318 | `seen(v)`: `bad` → `Pow2(-128, v.neg)`; zero → `Pow2(-127, v.neg)` | H4 | the exponent field read as a signed 8-bit number |
| 321 | `ex = BL(tileLeft + 16)`, `ey = BL(tileTop + 16)` | H1 | |
| 322-327 | `e = max(top c_, top a_ + ex - 1, top b_ + ey - 1)`; `unit = e - 22` | H1 | `range = 1`: a zero coefficient counts through `seen` |
| 328 | `ax = Mul(a_, FromHalves(x0h), 62)`, `by = Mul(b_, FromHalves(yh), 62)` | H5 | exact 16 × ≤13 bits; L329-330 give a zero product `a_`'s sign, which `Mul`'s xor already gives |
| 331 | `k = FU(c_) + FU(ax) + FU(by) + n FU(a_)` | H11 (`FloorUnits`) | each term floored on its own; integer sum |
| 364-368 | SupSample: `ah = Mul(a_, 1/2, 62)`; `k += -n FU(a_) + (2n + hx) FU(ah)` | H5, H11 | exact half |
| 369-370 | `hy`: `k += FU(Add(c_, bh, 62, 400)) - FU(c_)` | H7b | ARTIFACT A1 |
| 379-399 | normalizer: `k` → 16 bits toward minus infinity, exponent floor -128, `k = -1` → `-2^-143`, `k = 0` → `+0` | H12a | |

**Divider and colour:**

| line | function | op | notes |
|---|---|---|---|
| 90-105 | `FloorUnits(v, unit)` | H11 | `-0` → -1; the `s >= 62` clamp is unreachable (ARTIFACT A4) |
| 408-435 | `RecipTable` | H13 | |
| 451-469 | `DenominatorSeen` | H13 | |
| 477-511 | `Divide` | H13 | |
| 521-542 | `ColorRounded(q, -8, 255 or 65535, fallback)` | H15 | |

**`MipSelect`** (L586-835; HW: `MIP_K = 0`, `MIP_ARITH = 0`; `tsp.md` 8):

| line | expression | op | N/R | notes |
|---|---|---|---|---|
| 608-614 | `kind(x, y)`: class of `Mul(x, y, 24)` | H5, H10 | 24 | shares the product of L643 |
| 620-623 | `inv = det.bad ? +0 : Recip(Sdet, 24)`; below → `+0` | H8, H10 | 24 | **DEFECT D1**: `Sdet == 0` divides by zero |
| 624 | `undivided = !det.zero && !inv.zero` | | | |
| 625-632 | `inv2 = Mul(inv, inv, 24)`; below → `+0` | H5, H10 | 24 | mipdump, mipdet (a determinant above 2^63 gives the largest map) |
| 643 | `q1 = Mul(sa1, sb2, 24)`, `q2 = Mul(sb1, sa2, 24)` (or `+0` by kind / bad) | H5 | 24 | the undivided sums `Sa, Sb, Sc` |
| 644 | `n = abs(Sub(q1, q2, 62, 200).cut(24))`, `bad` cleared | H7c | wide → 24 | ARTIFACT A1 |
| 648-650 | `nq = Mul(n, inv2, 62)`: below → 0, above → inf | H5, H10 | exact | only `top` is used |
| 654-662 | `!undivided`: `Mul(., ., 62)`, `Sub(., ., 62, 200)` | | | **dead in the HW config**: `!undivided` means `det == 0` or `inv == 0`, so `A0 = B0 = 0` and both products are 0 (or the kind decides infinity) |
| 670 | `AtMost(q, p)` (longer / shorter) | H9 | | |
| 686-689 | `sum = Add(hi, lo, 62, 25).cut(24)`; `less = Mul(lo, 0x95F612 2^-24, 62).cut(24)`; `Sub(sum, less, 62, 25).cut(24)` | H6, H5 | ≡ 24/25; ≡ 24 | mipk4 |
| 700-716 | DCalcCtrl 1: `pu = rmul(u1, z1)` ... | H4, H5, H10 | 24 | `pu, pv, pw` are dead in the HW config (only read in `!undivided`) |
| 721-734 | `at1 = radd(radd(rmul(Sa, x1), rmul(Sb, y1)), Sc)` | H5, H6, H10 | 24; **24/53** | GAP G1 |
| 736 | `val1` (`Mul 62`, `Add 62/200`) | | | dead in the HW config |
| 745 | `best = lx.bad or (!ly.bad and AtMost(ly, lx)) ? lx : ly` | H9 | | |
| 747-749 | `best = Mul(best, inv2, 24)`; range | H5, H10 | 24 | |
| 752-764 | `k8 = bad ? 2^(-128+size) : zero ? 2^(-127+size) : cut_8(best * biasQuarters * 2^(size-2))` | H5, H2 | 8 | `Mul(best, FromHalves(2 bq), 62)` is exact, then the exponent is adjusted, then cut |
| 772-776 | `wFull = abs(Divide(1, q))`; `w8 = wFull.cut(8)` | H13, H2 | 8 | |
| 781-783 | `ww = Mul(w8, w8, 8)`; `top - 1 > 127` → exponent clamped to 127, mantissa kept | H5 | 8 | mipmeas wext |
| 784-787 | `d = Mul(k8, ww, 8)`; `L = top(d) - 1`, `M` = top 8 bits | H5, H1 | 8 | |

### 5.4 `refsw_tile.h`, `refsw_tile.cpp`, `refsw_lists.cpp`

| file:line | expression | op | notes |
|---|---|---|---|
| tile.h 90 | `SingleBits(c, -8)` for each colour channel | H4 | |
| tile.h 101-116 | `Val(p)` (L103-105: `n = x - SpanStart`, `x0h = 2 (left + SpanStart) + half`, `yh = 2 (top + y) + half`); `Quot = Divide(Val(p), W)` | H12a, H13 | `half` = HALF_OFFSET[1] |
| tile.h 128-131 | `ColorRounded(Quot, -8, max, fallback)` | H15 | max 65535 for the base colour (intensity scaled before the clamp), 255 for offset |
| tile.cpp 722-740 | `CulledBySize`, `CulledByFacing` | H9 | |
| tile.cpp 748-749, 770-771 | `FromBits(v.x)`, `FromBits(v.y)` | H4 | the fourth corner of a sprite too |
| tile.cpp 1242-1296 | `CoordKeep`, `TexCoordFixed(u, shift)` | H11 | `tsp.md` 9.1 |
| tile.cpp 1706-1748 | `LookupFogTable`: `M = FOG_DENSITY[15:8] * W.mant` (8 × 16 bits, exact), `E = W.exp + FOG_DENSITY[7:0] (signed) - 7`, normalize to 24 bits, clamp to [1, 256 - 2^-16], index and blend from the float bits | H1, H5 (8×16 integer) | `tsp.md` 15.2; `W < 0`, zero or bad → 1.0 |
| lists.cpp 374-379 | `perpVal = FromBits(FPU_PERP_VAL & 0x7fffffff)` | H4 | |
| lists.cpp 632-644 | background depth word from ISP_BACKGND_D (0x088) | H14d | `isp.md` 4.2 |

### 5.5 Instances by primitive

| primitive instance | sites (in the HW config) |
|---|---|
| H5 `Mul` 24×24 → cut 24 | edge 73, 118, 122; depth 243 (all ranged products), 319, 364, 385-389; TSP 152/158 (edges, terms, attribute products, coefficients, mean); mip 612, 625, 643, 688, 708, 747 |
| H5 `Mul` exact 16 × ≤13 (integer coordinate) and × 1/2 | TSP 328, 365 |
| H5 `Mul` exact 24×24, range class only | mip 648 |
| H5 `Mul` 24 × ≤5 bits → cut 8; 8×8 → cut 8 | mip 761-764; 781, 784 |
| H5 constant multiplies | `0xAAAAAB 2^-25` (depth 364, TSP 277); `0x95F612 2^-24` (mip 688) |
| H6 `Add` 24/25 | edge 73, 76, 118, 119, 122, 127; depth 250, 389, 517; TSP 165/177; mip 688, 689 |
| H6 `Add` 24/53 | mip 728 |
| H7 wide `Add` (62, R ≥ 200, window 90) | edge 137 (H7a); TSP 370 (H7b); mip 644 (H7c). TSP 267 is the same call but exact on its operands |
| H8 `Recip` 24 | depth 277, 318, 384; TSP 287; mip 621 |
| H2 `cut` | 20: edge 142, 152, depth 312, 372, 409, 416; 16: TSP 278, 291-293; 19: depth 173, 282, 518, 530; 8: mip 764, 775 |
| H3 `cutBelow` | edge 169-170; depth 411, 416 (twice) |

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

### H7 The three wide adds (`N = 62`, `R = 200/400`, window 90)

The generic reference behaviour is section 2.8 with case W:

```
|a.exp - b.exp| > 90:  the operand with the larger top
otherwise:             exact sum, truncated to 64 then 62 significant bits
```

The truncations compose with whatever cut follows, except at H7b where a floor follows. Each site takes few
operands, so it gets its own small circuit.

**H7a `edge_start_sat`** (edge L124-139 and L152). Inputs: `first` (≤ 24 bits, not bad), `c`, `|dy| >= 2^127`.

```
|first| >= 2^128:              start = {first.neg, 1, 127}
else start = Add(first, c, 24, 25)                       // H6
     if |start| >= 2^128:
        s = start.neg
        if |dy| < 2^127:       start = {s, 1, 127}
        elif first == 0 or first.exp < 42:               // window: 132 - first.exp > 90
                               start = {s, 1, 132}       // 2^132, first dropped
        else:                  start = (s ? -1 : 1) 2^132 - first   exactly (|first| < 2^128, sign s)
s20 = cut_20(start);  es = top(start)
```

In the exact case, let `F = |first|` and `σ = (first.neg == s)`:

- `σ` (magnitude `2^132 - F`): `s20 = {s, 2^20 - ceil(F / 2^112), 112}`, `es = 132`;
- otherwise (`2^132 + F`): `s20 = {s, 2^19 + floor(F / 2^113), 113}`, `es = 133`.

The window case gives `s20 = 2^132` (`es = 133`). When `first` has the start's sign (`σ`), the exact rule gives
`(2^20 - 1) 2^112` instead (`es = 132`). Otherwise the two agree (`F < 2^66` there). Deciding which case applies
needs `first.exp`, which is the representation contract (section 1.3).

**H7b `tsp_half_line`** (TSP L369-370, SupSample points half a line down, `hy = 1`). `c_ = seen(C)` and
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

**H7c `mip_minor_sub`** (mip L644). `q1`, `q2` are ≤ 24-bit products (H5). `n` is the magnitude:

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
- `perpendicular(det)`, `culled_by_size(det)`, `culled_by_facing(mode, det)` (section 2.12). The register
  operands are decoded with `from_bits(reg & 0x7fffffff)`. `size >= 0x7f800000` means "cull every triangle", and
  a `perpVal` that is NaN or infinity is `bad`.

### H10 `fp_range`: the range and special-value wrappers

Three flavours, exactly as in section 4.2:

- `rng_mul`: depth, TSP and mip `rmul`.
- `rng_add #(R, third)`: depth `add`; TSP `addTerm` with `third` 0 or 1; mip `radd` with R = 53.
- `rng_kind`: the mip product class.

They are combinational wrappers around H5 and H6:

- **pre-checks**: bad operands; for `third`, the zero-substitution, which needs H1 on the nonzero operand;
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
| edge `units(v)` | 0 | `floor(v / 2^unit)`, plus `frac` = any bit below `unit` | none (`E - unit <= 56`) | edge `t0`, `tx`, `ty` |
| depth grid | | exact left shift: values are on the grid by construction (`m.exp >= unit`) | none | depth `d0`, `dx`, `dy`, mean |
| depth ovf `r0` | | `cut_20`, then trunc toward zero onto 2^102 (sign-magnitude) | unreachable clamps | depth L313-315 |
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

**H12b `depth_block_to_fp`** (`At` L505-511):

```
t = d0 + (2i + h) dx + (2j + h) dy      // signed fixed point in units of 2^(unit - 1); up to about 108 bits
neg = t < 0;  m = |t|;  drop = max(BL(m) - 64, 0)
mant = m >> drop;  exp = unit - 1 + drop                // TRUNCATION to 64 significant bits (A2)
```

The result then goes to `cut_19` / `Store` (H14). The 64-bit truncation composes with `cut_19` but **not** with
`Store`'s round-up of negative sizes (A2).

### H13 `tsp_div`: the TSP divider

**`recip_mant(D)`**, for `D` in [32768, 65535] (`RecipTable::Mantissa`; uvmeas recipscan, all 32768 values):

```
i = D[14:6]  (= (D >> 6) - 512),  f = D[5:0]
t[i] = ceil(2^26 / (512 + i))            i = 0..512   (t[0..511] in 65601..131072; t[512] = 65536)
n[i] = t[i] - t[i+1] + c[i]              (65..256), c[i] in {0, 1, 2}: digit i of the 512-character string at
                                         pvr_tsp_plane.h L414-421 (102 zeros, 403 ones, 7 twos; no formula found)
r = (64 t[i] - 1 - n[i] f) >> 7          (r in 32768..65535)
```

The ROM is 512 × (18-bit `t`, or 17-bit `t - 65536`; 9-bit `n`). The arithmetic is a 9×6 multiplier, a 24-bit
subtract and a shift. **Generate the ROM from the header** (a tool reads the string and the formula), never by
hand.

**`denominator_seen(den)`** (L451; uvmeas wneg, 780,000 of 780,000):

```
not den.neg:          den (a zero never arrives here: Divide maps it first)
top(den) < -127:      {0, 0xFFFF, -143}                      // only -2^-143 (H12a) is below 2^-128
else: d = |den| normalized to exactly 16 bits (shift right if more, truncating; left if fewer)
      d.mant = 32768 + ((65536 - d.mant) & 32767)            // the 15 bits under the leading one negated
```

**`divide(num, den)`** (L477; uvmeas reciprow / reciprown 1,560,000 of 1,560,000; hugepos c; wzero2):

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

### H14 `depth_word`: the stored depth format

**a. `from_fp(v)`** (`StoredDepth::FromFp` L116). It takes an `Fp` (≤ 19 or ≤ 17 bits here) to IEEE single bits:
RNE on the denormal grid, saturating.

```
v.bad:           Saturated(v.neg) = sign | 0x7F000000                 // +-2^127
v == 0:          sign                                                 // +-0 word
keep = max(top - 24, -149)
if v.exp < keep: d = keep - v.exp; d > 63 ? m = 0 : RNE(m >> d); e = keep
m == 0:          sign
t2 = e + BL(m);  t2 > 128: Saturated;  t2 <= -126: sign | (m << (e + 149))     // denormal word
else:            sign | (t2 + 126) << 23 | (top 24 bits of m)[22:0]
```

With ≤ 19-bit inputs the rounding acts only below 2^-125 (GAP G6: the float's range, not measured as the depth
buffer's own).

**b. `store(v)`** (`Store(v, 19, 16)` L170; perpmean_bg, perpmean_neg, perpmean_negstore page 0):

```
v.bad or not v.neg or v == 0:   from_fp(cut_19(v))
n = BL(mant)
if n > 16: d = n - 16; rest = (mant mod 2^d) != 0; mant >>= d; exp += d
           if rest: mant += 1; if mant == 2^16: mant = 2^19 - 1; exp -= 3     // no carry into the exponent
from_fp(that)
```

`At` uses `store` only for a negative pixel whose `top == negE`, and `cut_19` for other negative pixels (GAP G6).

**c. `key(w)`** (L96; zsign, bgspec, bgneg, bgneg2): `w == 0x80000000 ? 0 : int32(w ^ (w[31] ? 0x007FFFFF : 0))`.
The words are compared as signed 32-bit integers.

**d. Background word** (`refsw_lists.cpp` L632-644; bgdepth, bgtie, bgneg, bgneg2, bgspec, bgbig,
depthgaps_bglow*), from ISP_BACKGND_D `bg`, `f = bg[30:23]`:

```
bg[31]: q = ((bg & 0x7FFFF0) + 0xFF) >> 8
        f < 107: 0;  f < 133: 0xC2FFFFFF;  else (bg & 0xFF800000) | (q >= 0x8000 ? 0x7FFFE0 : q << 8)
else:   cut = max(5, 130 - f);  cut > 23 ? 0 : bg & ~((1 << cut) - 1)
f == 255: subtract 1 << 23
```

**e. Overflow register words** (`kWrap[32]`, `WrapWord(r)` L440-489, `r` a 30-bit two's complement register in
units of 2^102). These are functions of the register alone; take them verbatim from the header (`isp.md` 9.5;
zword, nantr_*). The low 5 bits in some of the words are GAP.

### H15 `color_round`: colour from the quotient

`ColorRounded(q, -8, max, fallback)` (L521; cmeas 2,340,000 of 2,340,000; shade 80,256 of 80,256; huge):

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
  - the depth `limit`, `mul`, `add` (`pvr_isp_depth.h` L229-252);
  - the TSP `mul`, `addTerm`, `sum3`, `withZero` (`pvr_tsp_plane.h` L145-184, L258-269);
  - the mip `kind`, `rmul`, `radd` (L604-614, L701-732);
  - the edge `units` (L171-189);
  - the `Value` normalizer (L379-399);
  - `TexCoordFixed` / `CoordKeep` (`refsw_tile.cpp` L1242-1296);
  - the fog arithmetic (L1706-1733);
  - the background word (`refsw_lists.cpp` L632-644).

  Copy them **verbatim** into `tb/fp/ref_copies.h`, each between markers that name the file and the anchor text.
  `tools/check_ref_copies.sh` re-extracts the anchored blocks from `$(REFCORE)` and diffs them; `make fp` runs it
  first and fails on any drift.

  Where a public entry point exists, the tbs also exercise the rule in place:
  - `PlaneT::Value`: set `A`, `B`, `C`, `cfg` directly;
  - `DepthTileT::At`: set `d0`, `dx`, `dy`, `unit`, `negE`, `valid`, `block` directly;
  - `EdgeTile::Setup` and `Inside`.
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
| H7a edge start | `EdgeTile::Setup` (`s20`, `t0` via `E`) and `Add(Pow2(132), -first, 62, 400)` | `first.exp` -60..127 × mantissas {1, 0x800000, 0xFFFFFF, U} × both signs × start sign | random huge-coordinate edges with `x0 = 0` (left tile column, HALF_OFFSET[0] = 0) | 2 s |
| H7b half line | `PlaneT::Value(..., super = true, hx, hy = 1)` and the bare `Add(c_, bh, 62, 400)` + `FloorUnits` | `C` exponent -60..-10 × `B` in {±0, ±bad, tiny ±, ordinary} × grid offsets; exp gaps 40..100 | random coefficients and positions | 3 s |
| H7c mip minor | `Sub(q1, q2, 62, 200).cut(24)` | gaps 0..120 × LSB offsets × signs, with `q2` mantissas {1, 0x800000, U} | random 24-bit pairs | 2 s |
| H8 recip | `Recip(v, C<24>)` | all 2^23 normalized mantissas × 3 exponents × 2 signs; every unnormalized form 1..23 bits of 4096 values | the dividers' corner cases: `dn = 2^23`, `2^23 + 1`, `2^24 - 1` | 5 s |
| H9 cmp | `AbsAtMost`, `AtMost`, `atLeastPow2`, `Perpendicular`, `CulledBySize` / `Facing` (copy) | registers: every exponent field × {0, 1, 0x400000, 0x7FFFFF} × sign bit | `det` at the threshold in three representations, ±1 unit, both signs, ±0, bad | 2 s |
| H10 range | copies + in place via `PlaneT::Setup`, `DepthTileT::Setup` | class pairs {±0, ±bad, [2^-126, 2^-125), [2^-125, 2^-124), ordinary, [2^127, 2^128)} for both operands, 1000 members a pair, each flavour; `withZero`: every `z` in [2^-126, 2^-125) (2^23 × 2 signs) against zeros of every fraction | random sums and products that land at 2^128 and 2^-126 exactly | 3 s |
| H11 floor | `FloorScaled`, `FloorUnits`, copies of `units` and `TexCoordFixed` | 17-bit mantissas × shift -70..45 × sign + ±0 (~30M, quick: 16-bit) | the clamps (2^40, 2^30) ±1 | 5 s / 30 s |
| H12a value norm | copy of the normalizer; `PlaneT::Value` in place | `k` in [-2^20, 2^20] × `unit` in {-170..-100, 0} | random 27-bit `k` | 5 s |
| H12b depth block | `DepthTileT::At` with the block form set | | random `d0`, `dx`, `dy` up to 108 bits, `i, j` 0..31, both `h`; the > 64-bit cases with a negative pixel in `negE` | 3 s |
| H13 divider | `RecipTable::Mantissa`, `DenominatorSeen`, `Divide` | `recip_mant`: all 32768; `denominator_seen`: all 16-bit mantissas × both signs × tops around -127, plus the 17-bit `2^16`; `divide`: all 2^16 + 1 numerators × 64 denominators and all 32768 denominators × 64 numerators, both signs; `den` ±0, `-2^-143`, `0xFFFF 2^-143`; `num` 0 | random tuples | 5 s |
| H14 depth word | `StoredDepth::FromFp`, `Store`, `key`, `WrapWord`, copy of the background word | `from_fp`: all 19-bit mantissas × 40 exponents around -150, -126, 0, 127, 128 × sign (~42M; quick: 17-bit); `store`: all 2^20 negative mantissas × 4 exponents; `WrapWord`: all 2^30 (full only) and every whole step (`kWrap`); background word: all 2^32 (full) | `key`: 2^24 random + every boundary word (±0, NaNs, ±inf, denormals) | 10 s / 5 min |
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
  - **Edge L137**: `first.exp < 42` gives a start of 2^132 instead of `2^132 - first` (a 20-bit start differing
    by 32 or more units of the edge grid).
  - **TSP L370** (SupSample, `hy`): a `B/2` more than 90 exponents below `C` adds nothing. For a negative `C` the
    limit is 46 exponents, because of the 62-bit truncation (table in H7b). With `B = -0` this means: no unit down
    for a positive 16-bit `C >= 2^-22` and for a negative `C` of `|C| >= 2^-66`, where exact arithmetic gives -1
    when `C` is on the grid. This is consistent with every pixel of supsample, supsample2, ssrare and sshalf, but
    it is not known whether those pages contain such planes. Probe suggestion: an ssrare-like page with planes flat
    in y on negative-determinant triangles (`B = -0`), both signs of `C`, `C` from 2^-80 to 2^10.
  - **mip L644**: a `q2` more than 90 exponents below `q1` takes no borrow.

  `tsp.md`'s conventions call `N = 62` / `R = 200/400` "exact". That holds at L267 and for the experiments, not at
  L370 or L644.
- **A2 Depth block → `Fp` truncates to 64 significant bits** (L509-511) before `Store` rounds a negative size up.
  It is reachable for slopes 2^33 .. 2^71 times the start, with a negative pixel in the block's top binade.
- **A3 Depth float-form fallback** (L422, L512-518). For `pair - unit > 97` (slopes above about 2^71 times the
  start) the reference evaluates each pixel with `Mul` / `Add` 24 and `cut_19`. This is an emulator convenience
  because the `i128` holds no more. What the hardware's stepping register does there is unmeasured (zmeas mix
  reach: "at least 29 powers of two above the start"). It is also the only place where `DepthHW::coefBits = 24`
  is visible.
- **A4 Unreachable clamps.** `FloorUnits`' `s >= 62` (L97), the depth ovf `r0` shift clamps (L314), `Add`'s step 5
  `cut_32`, and `Mul`'s input `cut_32`. The RTL omits them and the tbs assert that they never act.

### Defect

- **D1 `MipSelect` divides by zero** (L621: `Recip(det = w.Sdet, 24)` with `Sdet == 0`). A mipmapped triangle whose
  TSP determinant is exactly zero crashes refsw3 with SIGFPE. Examples: three equal corners, or collinear corners
  whose sum cancels exactly. Such triangles are drawn when not culled (covmeas mix degen). Reproduced in the
  scratch run: three equal corners give `Sdet = +0`, then SIGFPE. The console's value is unknown.

  Proposal for the RTL until a console test settles it: treat the reciprocal as `+0`, as for a bad determinant.
  Then `undivided` is false, both numerators are 0, the length is zero, `K = 2^(-127 + size)`, and the level
  follows from the pixel's `w`.

  Console probe: covmeas degen triangles with a mipmapped texture whose levels are flat colours (mipdump's method).

### GAPs (unmeasured)

- **G1** `MipSelect`'s DCalcCtrl-1 sums (`radd`, L728) use **reach 53**, the TSP's value before uvmeas reach1
  established 25 for the setup adders. mipmeas mwextd1 (4,147,200 of 4,147,200) does not tell 53 and 25 apart. The
  RTL implements 53, to match the reference.
- **G2** `zeroReach` 2 or 3: whether the TSP's last-addition zero rule reaches 2^-125 or 2^-124. Probably not
  observable (README).
- **G3** faredge: 10 regions (page 4's first-column strip, page 1's control strip) where the console keeps 2^127
  instead of the 2^132 rule. Which rule applies when is not known.
- **G4** zovf: 6 cells where the constant is exactly 2^128. refsw3 calls it an overflow; the console does not.
- **G5** Depth overflow: an infinite determinant gives depth 0 (a guess; detinf is consistent with it). The low 5
  bits of the ovf words, the words between -1 step and 0, and a negative finite start rounded onto 2^102 are also
  unmeasured.
- **G6** Stored depth:
  - below 2^-126 (RNE to the denormal grid) and from 2^128, the float's range is assumed;
  - negative sizes below about 2^-122 (perpmean_tiny's first version);
  - negative pixels outside the block's top binade (the depthgaps item: neither the 16-bit round-up nor the 19-bit
    cut fits).
- **G7** The ISP depth's range rules are the TSP's, adopted (huge 250 of 250). They are not measured number by
  number.
- **G8** The TSP value of -1 unit is `-2^-143`. Measured only as "below 2^-130"; the divider's reading of it is
  pinned by texfar_m1.
- **G9** The mean: a division by 3 or a multiplication by `0xAAAAAB 2^-25` give the same 19 bits for every 24-bit
  sum (checked by the README over all 2^23 mantissas). This is not observable, and the RTL may use either.
- **G10** The edge unit with a coordinate difference that overflows (hugepos a at 2^125: the console draws 4
  pixels, refsw3 1).
- **G11** The exponent field bounds (section 1.4) are derived, not measured. Since the reference has 32-bit
  exponents, the tbs assert the bounds.
- **G12** A perpendicular triangle with an infinite or NaN corner depth takes the first vertex's depth as given.
