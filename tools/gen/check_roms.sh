#!/bin/bash
# check_roms.sh: the generated ROMs (conventions.md 5; PLAN M1c) are up to date with refcore, or (--write) regenerate
# them in place. Under a second.
#
#   tools/gen/check_roms.sh [--write] <gen_recip_rom binary> <gen_table_roms binary> <refcore dir>
#
#   rtl/v1/lib/fp/p2_fp_recip_rom.sv   gen_recip_rom <refcore>          pvr_tsp_plane.h RecipTable (num H13)
#   rtl/v1/lib/rom/p2_rom_bm_sin.sv    gen_table_roms <refcore> sin     refsw_tile.cpp BM_HW_SIN (tsp 12, appendix B)
#   rtl/v1/lib/rom/p2_rom_bm_cos.sv    gen_table_roms <refcore> cos     refsw_tile.cpp BM_HW_COS
#   rtl/v1/lib/rom/p2_rom_dither.sv    gen_table_roms <refcore> dither  refsw_lists.cpp ditherAdd (tsp 17.3)
#
# Check: each regenerated into build/gen/ and compared (cmp) with the checked-in file. Last line "roms-check: PASS" /
# "FAIL" (exit code to match); --write: "roms: written".
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
write=0
[ "${1:-}" = --write ] && { write=1; shift; }
[ $# = 3 ] || { echo "usage: check_roms.sh [--write] <gen_recip_rom> <gen_table_roms> <refcore dir>"; exit 2; }
RECIP=$1 TABLE=$2 RC=$3
OUT="$ROOT/build/gen"
mkdir -p "$OUT"
st=0
one() {   # one <checked-in file> <generator and arguments ...>
  local file=$1; shift
  local new="$OUT/$(basename "$file")"
  if ! "$@" > "$new"; then
    echo "roms-check: the generator failed for $file (above)"; st=1; return
  fi
  if [ $write = 1 ]; then
    mv "$new" "$ROOT/$file"
  elif ! cmp -s "$new" "$ROOT/$file"; then
    diff -u "$ROOT/$file" "$new" | head -20
    echo "roms-check: $file differs from what refcore gives (diff above): make roms"; st=1
  else
    echo "roms-check: $file up to date"
  fi
}
one rtl/v1/lib/fp/p2_fp_recip_rom.sv "$RECIP" "$RC"
one rtl/v1/lib/rom/p2_rom_bm_sin.sv  "$TABLE" "$RC" sin
one rtl/v1/lib/rom/p2_rom_bm_cos.sv  "$TABLE" "$RC" cos
one rtl/v1/lib/rom/p2_rom_dither.sv  "$TABLE" "$RC" dither
if [ $write = 1 ]; then
  [ $st = 0 ] && echo "roms: written" || echo "roms: FAILED"
  exit $st
fi
echo "roms-check: $([ $st = 0 ] && echo PASS || echo FAIL)"
exit $st
