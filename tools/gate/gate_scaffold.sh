#!/bin/bash
# gate_scaffold.sh: the M0 gate (PLAN M0), run by `make scaffold`. About 25 s, 15 s of it hw-pkg-selftest (about 200
# small Verilator elaborations); a few more from clean (the C++ builds).
#   hw-pkg-check, regs-pkg-check   the generated packages are up to date (and regs' bit positions are the compiler's)
#   lint                           verilator -Wall on the p2_core shell, 0 warnings
#   check_ref_copies, check_ref_switches   the refsw3 checks every gate runs (PLAN 1.1)
#   *-selftest                     the checkers (gen_hw_pkg's header check and hw-pkg-check's MODE check,
#                                  check_ref_copies, check_ref_switches) and tb/common (p2tb.h, zkey.h) each shown
#                                  able to fail
# The checks run at once on one queue (PLAN 0 rule 8), after the two binaries they share are built (prep).
# Ends with "scaffold: PASS" or "scaffold: FAIL", exit code to match; build/gate/scaffold/summary.txt.
set -u
. "$(dirname "$0")/lib.sh"

gate_begin scaffold
gate_step prep $MAKE -s build/tools/gen/gen_hw_pkg build/tb/common/p2tb_selftest
items=$GATE_DIR/items.txt
: > "$items"
for s in "hw-pkg-check 1 $MAKE -s hw-pkg-check" "regs-pkg-check 1 $MAKE -s regs-pkg-check" \
         "lint 17 $MAKE -s lint LINT_J=8" "check_ref_copies 1 bash tools/check_ref_copies.sh" \
         "check_ref_switches 1 bash tools/check_ref_switches.sh --no-hwpkg" "hw-pkg-selftest 6 $MAKE -s hw-pkg-selftest" \
         "check_ref_copies-selftest 1 bash tools/check_ref_copies.sh --selftest" \
         "check_ref_switches-selftest 1 bash tools/check_ref_switches.sh --selftest" \
         "tbcommon-selftest 1 $MAKE -s tbcommon-selftest"; do
  set -- $s
  n=$1 e=$2; shift 2
  sl=1; [ "$n" = lint ] && sl=8
  gate_item "$items" "$n" - "$e" "$sl" step "$n.log" "$@"
done
gate_queue checks "$items"
gate_end
