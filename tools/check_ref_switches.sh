#!/bin/bash
# check_ref_switches.sh: refsw3's run-time and compile-time switches are at their hardware values (PLAN 1.1). Every
# gate runs it and records its verdict in the summary. A second or two (item 4 builds the generator once).
#
#   1. env       MIP_K and MIP_ARITH are unset, empty or 0 (pvr_tsp_plane.h MipSelect reads both with getenv);
#   2. defines   FOG_VARIANT (refsw_tile.cpp) is not defined other than 0, and PVRFP_NO_INT128 (pvr_softfp.h) not at
#                all, by refsw3-offline's build.sh (the L2 glue and p2-offline take its flags) or by this repository's
#                build files; refsw_tile.cpp's own default is still 0;
#   3. refcore   has no switch beyond the known ones: its getenv names are {MIP_K, MIP_ARITH}, and every macro its
#                #if / #ifdef / #ifndef / #elif lines test is known (a new one must be classified here);
#   4. *HW       the *HW structs are the ones p2_hw_pkg was generated from (make hw-pkg-check).
#
#   tools/check_ref_switches.sh [--no-hwpkg]     --no-hwpkg: skip item 4 (a caller that runs hw-pkg-check itself)
#   tools/check_ref_switches.sh --selftest       each item fails when its switch is set (on a fake nulldc3 in build/)
#
# Prints one line per item, then "check_ref_switches: PASS" / "FAIL" (exit code to match).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
N3=${NULLDC3:-$ROOT/../nulldc3}
RC=${REFCORE:-$N3/refsw3/refcore}

# the macros refcore's preprocessor conditionals may test, and why each is not a hardware switch
KNOWN_MACROS="_MSC_VER __clang__ __GNUC__ __SIZEOF_INT128__ REFSW_OFFLINE FOG_VARIANT PVRFP_NO_INT128"
#   compilers: _MSC_VER __clang__ __GNUC__ __SIZEOF_INT128__; REFSW_OFFLINE: the offline build (refsw3-offline, the
#   glue, p2-offline all define it); FOG_VARIANT, PVRFP_NO_INT128: checked by item 2
KNOWN_GETENV="MIP_K MIP_ARITH"
# this repository's build files, where a -D of a switch would come from
OUR_BUILD_FILES="$ROOT/Makefile $ROOT/tb/mk/*.mk $ROOT/tools/p2-offline/build.sh"

check() {   # check <nulldc3> <refcore> <hwpkg: 1/0>
  local n3=$1 rc=$2 hw=$3 bad=0 line
  # 1. environment
  for v in MIP_K MIP_ARITH; do
    local val
    val=$(printenv "$v")
    if [ -n "$val" ] && [ "$val" != 0 ]; then
      echo "check_ref_switches: env: $v=$val (must be unset or 0: MipSelect's experiment)"; bad=1
    fi
  done
  [ $bad = 0 ] && echo "check_ref_switches: env: MIP_K, MIP_ARITH unset or 0"
  # 2. defines
  local b2=0 f
  local offsh="$n3/refsw3-offline/build.sh"
  if [ ! -f "$offsh" ]; then
    echo "check_ref_switches: defines: no $offsh"; b2=1
  fi
  for f in "$offsh" $OUR_BUILD_FILES; do
    [ -f "$f" ] || continue
    # every -D of either macro on a line that is not a comment; only -DFOG_VARIANT=0 is allowed
    while IFS= read -r line; do
      [ "$line" = "-DFOG_VARIANT=0" ] && continue
      echo "check_ref_switches: defines: $f sets $line"; b2=1
    done < <(grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -o -- '-D *\(FOG_VARIANT\|PVRFP_NO_INT128\)\(=[^[:space:]"]*\)\{0,1\}')
  done
  if ! grep -q '^#define FOG_VARIANT 0$' "$rc/refsw_tile.cpp" 2>/dev/null; then
    echo "check_ref_switches: defines: refsw_tile.cpp no longer defaults FOG_VARIANT to 0"; b2=1
  fi
  [ $b2 = 0 ] && echo "check_ref_switches: defines: FOG_VARIANT default 0 and not set; PVRFP_NO_INT128 not set"
  # 3. refcore's switches
  local b3=0 name
  for name in $(grep -oh 'getenv *( *"[A-Za-z0-9_]*"' "$rc"/*.h "$rc"/*.cpp 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | sort -u); do
    case " $KNOWN_GETENV " in *" $name "*) ;; *) echo "check_ref_switches: refcore: a new run-time switch getenv(\"$name\")"; b3=1 ;; esac
  done
  for name in $(grep -h '^[[:space:]]*#[[:space:]]*\(if\|ifdef\|ifndef\|elif\)\b' "$rc"/*.h "$rc"/*.cpp 2>/dev/null |
                sed 's://.*$::; s:/\*.*$::; s/^[[:space:]]*#[[:space:]]*[a-z]*//' | grep -o '[A-Za-z_][A-Za-z0-9_]*' |
                grep -v '^defined$' | sort -u); do
    case " $KNOWN_MACROS " in *" $name "*) ;; *) echo "check_ref_switches: refcore: a new compile-time switch $name"; b3=1 ;; esac
  done
  [ $b3 = 0 ] && echo "check_ref_switches: refcore: getenv {$KNOWN_GETENV}, macros {$KNOWN_MACROS} only"
  # 4. the *HW structs
  local b4=0
  if [ "$hw" = 1 ]; then
    if out=$(${MAKE:-make} -s -C "$ROOT" hw-pkg-check 2>&1); then
      echo "check_ref_switches: *HW: $(echo "$out" | tail -1)"
    else
      echo "$out" | sed 's/^/    /' | tail -20; echo "check_ref_switches: *HW: hw-pkg-check failed"; b4=1
    fi
  fi
  if [ $bad = 0 ] && [ $b2 = 0 ] && [ $b3 = 0 ] && [ $b4 = 0 ]; then
    echo "check_ref_switches: PASS"; return 0
  fi
  echo "check_ref_switches: FAIL"; return 1
}

if [ "${1:-}" = "--selftest" ]; then
  T="$ROOT/build/check_ref_switches_selftest"
  rm -rf "$T" && mkdir -p "$T/n3/refsw3/refcore" "$T/n3/refsw3-offline"
  fresh() {
    rm -rf "$T/n3/refsw3/refcore"/* && cp "$RC"/*.h "$RC"/*.cpp "$T/n3/refsw3/refcore/" &&
      cp "$N3/refsw3-offline/build.sh" "$T/n3/refsw3-offline/build.sh"
  }
  st=0
  expect() {   # expect <exit> <case>   (on the fake tree as it is now)
    ( unset MIP_K MIP_ARITH; eval "$3"; check "$T/n3" "$T/n3/refsw3/refcore" 0 ) > "$T/$2.log" 2>&1; local got=$?
    if [ "$got" = "$1" ]; then echo "check_ref_switches --selftest: $2: ok (exit $got)"
    else echo "check_ref_switches --selftest: $2: exit $got, want $1"; sed 's/^/    /' "$T/$2.log"; st=1; fi
  }
  fresh; expect 0 clean ":"
  fresh; expect 0 env-zero "export MIP_K=0 MIP_ARITH="
  fresh; expect 1 env-mipk "export MIP_K=99"
  fresh; expect 1 env-miparith "export MIP_ARITH=4"
  fresh; sed -i 's/^DEF="/DEF="-DFOG_VARIANT=1 /' "$T/n3/refsw3-offline/build.sh"; expect 1 fog-variant ":"
  fresh; sed -i 's/^DEF="/DEF="-DFOG_VARIANT=0 /' "$T/n3/refsw3-offline/build.sh"; expect 0 fog-variant-0 ":"
  fresh; sed -i 's/^FLAGS="/FLAGS="-DPVRFP_NO_INT128 /' "$T/n3/refsw3-offline/build.sh"; expect 1 no-int128 ":"
  fresh; sed -i 's/^#define FOG_VARIANT 0$/#define FOG_VARIANT 1/' "$T/n3/refsw3/refcore/refsw_tile.cpp"; expect 1 fog-default ":"
  fresh; printf '\nstatic int x = getenv("TSP_EXPERIMENT") ? 1 : 0;\n' >> "$T/n3/refsw3/refcore/refsw_tile.cpp"; expect 1 new-getenv ":"
  fresh; printf '\n#ifdef EDGE_EXPERIMENT\n#endif\n' >> "$T/n3/refsw3/refcore/pvr_isp_edge.h"; expect 1 new-macro ":"
  fresh; printf '\n#if defined(DEPTH_X) && DEPTH_Y > 1\n#endif\n' >> "$T/n3/refsw3/refcore/pvr_isp_depth.h"; expect 1 new-macro-expr ":"
  echo "check_ref_switches --selftest: $([ $st = 0 ] && echo PASS || echo FAIL)"
  exit $st
fi

hw=1
[ "${1:-}" = "--no-hwpkg" ] && hw=0
[ -d "$RC" ] || { echo "check_ref_switches: no refcore at $RC"; echo "check_ref_switches: FAIL"; exit 1; }
check "$N3" "$RC" $hw
