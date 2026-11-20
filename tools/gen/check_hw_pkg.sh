#!/bin/bash
# check_hw_pkg.sh: rtl/v1/pkg/p2_hw_pkg.sv is up to date with refcore's *HW structs, and a change to any MODE member
# breaks the RTL build (make hw-pkg-check, conventions.md 5). A few seconds; the self-test about 15 s.
#   1. gen_hw_pkg checks the structs and their members against the headers' text and regenerates into build/gen/;
#      cmp with the checked-in file (out of date: make hw-pkg);
#   2. every member the generator marks (MODE) has a check that works: the package as generated elaborates, and for
#      each MODE member, the package with that member at its value - 1 and at its value + 1 fails elaboration of
#      p2_hw_check with Verilator's USERFATAL (rtl/v1/pkg/p2_hw_check.sv's $fatal). One such change must also fail
#      elaboration of p2_core: the core runs the checks. A comment naming the member, a check that cannot fire or a
#      one-sided one fails here.
#
#   tools/gen/check_hw_pkg.sh <gen_hw_pkg binary> <refcore dir>
#   tools/gen/check_hw_pkg.sh --selftest <gen_hw_pkg binary> <refcore dir>   (make hw-pkg-selftest) each rule of the
#       generator's header check and of item 2 failing, on a fake refcore and a fake rtl/ in build/
# Environment (make passes them): VERILATOR, P2_PKG_SRC (the packages in order), P2_CORE_SRC (p2_core's files), paths
# relative to the repository.
# Last line "hw-pkg-check: PASS" / "FAIL", exit code to match.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERILATOR=${VERILATOR:-verilator}
HWPKG=rtl/v1/pkg/p2_hw_pkg.sv
if [ -z "${P2_PKG_SRC:-}" ] || [ -z "${P2_CORE_SRC:-}" ]; then
  echo "hw-pkg-check: P2_PKG_SRC and P2_CORE_SRC are not set: run it as make hw-pkg-check"; echo "hw-pkg-check: FAIL"
  exit 1
fi

# elab <root> <top> <p2_hw_pkg file> <log>: Verilator elaborates <top> (p2_hw_check or p2_core) from <root>'s files,
# <p2_hw_pkg file> in place of the package. Only USERFATAL is an error: the other warnings are make lint's.
elab() {
  local root=$1 top=$2 hw=$3 f files=()
  local src="$P2_PKG_SRC rtl/v1/pkg/p2_hw_check.sv"
  [ "$top" = p2_core ] && src="$P2_PKG_SRC $P2_CORE_SRC"
  for f in $src; do
    if [ "$f" = "$HWPKG" ]; then files+=("$hw"); else files+=("$root/$f"); fi
  done
  "$VERILATOR" --lint-only -Wno-fatal -Werror-USERFATAL --top-module "$top" "${files[@]}" > "$4" 2>&1
}

# modes <root> <generated package> <work dir>: item 2. Prints what fails; 0 / 1.
modes() {
  local root=$1 gen=$2 w=$3 p v x first="" bad="" top
  rm -rf "$w" && mkdir -p "$w"
  local list
  list=$(sed -n 's/^ *localparam int \(P2_[A-Z0-9_]*\) .*(MODE)$/\1/p' "$gen")
  [ -n "$list" ] || { echo "hw-pkg-check: no MODE members in the generated package"; return 1; }
  for top in p2_hw_check p2_core; do
    if ! elab "$root" $top "$gen" "$w/base.$top.log"; then
      echo "hw-pkg-check: $top does not elaborate with the package as generated (a MODE value the RTL does not"
      echo "hw-pkg-check: implement, or an RTL error):"; grep -m6 '%Error' "$w/base.$top.log" | sed 's/^/    /'
      return 1
    fi
  done
  local flips=""
  for p in $list; do
    v=$(sed -n "s/^ *localparam int $p *= *\(-\{0,1\}[0-9]\{1,\}\);.*/\1/p" "$gen")
    [ -n "$v" ] || { echo "hw-pkg-check: cannot read the value of $p"; return 1; }
    for x in $((v - 1)) $((v + 1)); do
      sed "s/^\( *localparam int $p *= *\)-\{0,1\}[0-9]\{1,\};/\1$x;/" "$gen" > "$w/$p.$x.sv"
      if cmp -s "$gen" "$w/$p.$x.sv"; then echo "hw-pkg-check: could not set $p to $x"; return 1; fi
      flips="$flips $p.$x"
    done
  done
  # the elaborations, 8 at a time; a failed one has an %Error-USERFATAL line in its log
  for x in $flips; do
    while [ "$(jobs -rp | wc -l)" -ge 8 ]; do wait -n; done
    elab "$root" p2_hw_check "$w/$x.sv" "$w/$x.log" &
  done
  wait
  for x in $flips; do
    grep -q '%Error-USERFATAL' "$w/$x.log" || bad="$bad ${x%.*}=${x##*.}"
    [ -n "$first" ] || first=$x
  done
  if [ -n "$bad" ]; then
    echo "hw-pkg-check: these MODE values still elaborate: rtl/v1/pkg/p2_hw_check.sv has no working check (if (P2_X !="
    echo "hw-pkg-check: <value the RTL implements>) \$fatal) for them:$bad"
    return 1
  fi
  if elab "$root" p2_core "$w/$first.sv" "$w/core.$first.log" || ! grep -q '%Error-USERFATAL' "$w/core.$first.log"; then
    echo "hw-pkg-check: p2_core elaborates with ${first%.*} = ${first##*.}: it no longer runs p2_hw_check"
    return 1
  fi
  echo "hw-pkg-check: $(echo $list | wc -w) MODE members, each one's change in either direction fails elaboration"
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  GEN=$2 RC=$3
  T="$ROOT/build/check_hw_pkg_selftest"
  rm -rf "$T" && mkdir -p "$T"
  st=0
  report() {   # report <want> <got> <case> <log>
    if [ "$2" = "$1" ]; then echo "check_hw_pkg --selftest: $3: ok (exit $2)"
    else echo "check_hw_pkg --selftest: $3: exit $2, want $1"; sed 's/^/    /' "$4"; st=1; fi
  }
  # the generator's header check, on a copy of refcore (the binary's values are compiled from the real one)
  F="$T/rc"
  fresh() { rm -rf "$F" && mkdir -p "$F" && cp -r "$RC"/. "$F"/; }
  gen() {   # gen <want> <case> <shell commands that change $F>
    fresh; ( cd "$F" && eval "$3" ) || { echo "check_hw_pkg --selftest: $2: the change failed"; st=1; return; }
    "$GEN" "$F" > "$T/$2.sv" 2> "$T/$2.log"; report "$1" $? "gen $2" "$T/$2.log"
  }
  # into <file>: before the line of struct <S>'s closing `};` (the first one after `struct <S> {`)
  ins() { sed -i "/^struct $2 {/,/^};/{/^};/i\\
$3
}" "$1"; }
  gen 0 clean ":"
  gen 0 comments-and-strings "printf '%s\n' '// struct FakeHW { static constexpr int x = 1; };' '/* class Fake2HW {}; */' \
    'static const char* s = \"struct Fake3HW {\";' 'static const int k = 1'\\''000;' >> refsw_tile.cpp;
    ins pvr_isp_edge.h EdgeHW '    // a comment, a brace } and a member static constexpr int c{};'"
  gen 1 member-eq "ins pvr_isp_edge.h EdgeHW '    static constexpr int newMember = 3;'"
  gen 1 member-brace-value "ins pvr_isp_depth.h DepthHW '    static constexpr int x{3};'"
  gen 1 member-nonstatic "ins pvr_isp_depth.h DepthHW '    int extra = 0;'"
  gen 1 member-function "ins pvr_isp_edge.h EdgeHW '    static constexpr int f() { return 1; }'"
  gen 1 member-macro "ins pvr_tsp_plane.h PlaneHW '    PVR_HW_MEMBER(extra, 1);'"
  gen 1 member-two-names "sed -i 's/pvrfp::C<24> productBits{};/pvrfp::C<24> productBits{}, extra{};/' pvr_isp_edge.h"
  gen 1 member-after-comment-brace "ins pvr_tsp_plane.h PlaneHW '    // } a brace in a comment\\
    static constexpr pvrfp::C<1> hidden{};'"
  gen 1 member-include "ins pvr_isp_edge.h EdgeHW '#include \"more_members.inc\"'"
  gen 1 member-dropped "sed -i '/C<131> walkExp{};/d' pvr_isp_edge.h"
  gen 1 member-commented-out "sed -i 's:^ *static constexpr pvrfp\\:\\:C<131> walkExp{};://&:' pvr_isp_edge.h"
  gen 1 struct-class "printf '\nclass BazHW {};\n' >> pvr_isp_edge.h"
  gen 1 struct-alignas "printf '\nstruct alignas(4) BarHW { static constexpr int a = 1; };\n' >> pvr_isp_edge.h"
  gen 1 struct-derived "printf '\nstruct TexHW : EdgeHW {};\n' >> pvr_isp_edge.h"
  gen 1 struct-comment-inside "printf '\nstruct /* x */ QuxHW {};\n' >> pvr_isp_depth.h"
  gen 1 struct-using "printf '\nusing AliasHW = pvrisp::EdgeHW;\n' >> pvr_isp_depth.h"
  gen 1 struct-typedef "printf '\ntypedef struct { int a; } TypedefHW;\n' >> pvr_tsp_plane.h"
  gen 1 struct-macro "printf '\n#define HW_STRUCT(n) struct n##HW\nHW_STRUCT(Tex) {};\n' >> pvr_tsp_plane.h"
  gen 1 struct-new-file "printf 'struct FogHW { static constexpr int a = 1; };\n' > pvr_tsp_fog.h"
  gen 1 struct-subdir "mkdir -p sub && printf 'struct SubHW {};\n' > sub/x.h"
  gen 1 struct-after-digit-separator "printf '\nstatic const int k = 1'\\''000; struct SepHW {};\n' >> refsw_tile.cpp"
  gen 1 struct-after-raw-string "printf '\nstatic const char* r = R\"x(\")x\"; struct RawHW {};\n' >> refsw_tile.cpp"
  gen 0 known-class-alignas "sed -i 's/^struct EdgeHW {/class alignas(8) EdgeHW {/' pvr_isp_edge.h"
  gen 1 known-class-alignas-member "ins pvr_isp_edge.h EdgeHW '    static constexpr int newMember = 3;' &&
    sed -i 's/^struct EdgeHW {/class alignas(8) EdgeHW {/' pvr_isp_edge.h"
  gen 1 known-derived "sed -i 's/^struct PlaneHW {/struct PlaneHW : pvrisp::EdgeHW {/' pvr_tsp_plane.h"
  gen 1 known-twice "printf '\nnamespace other { struct EdgeHW {}; }\n' >> refsw_tile.h"
  gen 1 known-moved "sed -i 's/^struct DepthHW {/struct DepthHW_ {/' pvr_isp_depth.h &&
    printf 'struct DepthHW {};\n' >> pvr_isp_edge.h"

  # item 2, on a copy of rtl/ with the checked-in package
  R="$T/root"
  rfresh() { rm -rf "$R" && mkdir -p "$R" && cp -r "$ROOT/rtl" "$R/"; }
  CK="$R/rtl/v1/pkg/p2_hw_check.sv"
  mode() {   # mode <want> <case> <shell commands that change $R>
    rfresh; ( cd "$R" && eval "$3" ) || { echo "check_hw_pkg --selftest: $2: the change failed"; st=1; return; }
    if cmp -s "$ROOT/rtl/v1/pkg/p2_hw_check.sv" "$CK" && cmp -s "$ROOT/rtl/v1/p2_core.sv" "$R/rtl/v1/p2_core.sv" &&
       [ "$2" != clean ]; then
      echo "check_hw_pkg --selftest: $2: the change changed nothing"; st=1; return
    fi
    modes "$R" "$R/$HWPKG" "$T/modes.$2" > "$T/mode.$2.log" 2>&1; report "$1" $? "mode $2" "$T/mode.$2.log"
  }
  mode 0 clean ":"
  mode 1 comment-only "sed -i '/if (P2_TSP_PLANE_SUM_W != 0)/,/^    end\$/c\\    // P2_TSP_PLANE_SUM_W: TODO' $CK"
  mode 1 removed "sed -i '/if (P2_ISP_DEPTH_RANGE != 1)/,/^    end\$/d' $CK"
  mode 1 block-comment "sed -i -e '/if (P2_TSP_PLANE_MAC_ORDER != 0)/i\\    /*' \
    -e '/if (P2_TSP_PLANE_MAC_ORDER != 0)/,/^    end\$/{/^    end\$/a\\    */
}' $CK"
  mode 1 never-fires "sed -i 's/if (P2_ISP_EDGE_GUARD != -1)/if (0 \\&\\& P2_ISP_EDGE_GUARD != -1)/' $CK"
  mode 1 one-sided "sed -i 's/if (P2_TSP_PLANE_TILE_LOCAL != 0)/if (P2_TSP_PLANE_TILE_LOCAL > 0)/' $CK"
  mode 1 wrong-value "sed -i 's/if (P2_TSP_PLANE_SUM_A != 0)/if (P2_TSP_PLANE_SUM_A != 1)/' $CK"
  mode 1 core-without-checks "sed -i '/p2_hw_check u_hw_check ();/d' rtl/v1/p2_core.sv"
  echo "check_hw_pkg --selftest: $([ $st = 0 ] && echo PASS || echo FAIL)"
  exit $st
fi

GEN=$1 RC=$2
PKG="$ROOT/$HWPKG" OUT="$ROOT/build/gen/p2_hw_pkg.sv"
mkdir -p "$ROOT/build/gen"
fail() { echo "hw-pkg-check: $1"; echo "hw-pkg-check: FAIL"; exit 1; }
"$GEN" "$RC" > "$OUT" || fail "the generator failed (above)"
if ! cmp -s "$OUT" "$PKG"; then
  diff -u "$PKG" "$OUT" | head -40
  fail "rtl/v1/pkg/p2_hw_pkg.sv differs from what refcore gives (diff above): make hw-pkg, then fix the RTL"
fi
echo "hw-pkg-check: $(grep -c '^ *localparam int P2_' "$OUT") members up to date"
modes "$ROOT" "$OUT" "$ROOT/build/gen/modes" || fail "a MODE member's change would not break the RTL build"
echo "hw-pkg-check: PASS"
