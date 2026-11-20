#!/bin/bash
# gate_scaffold.sh: the M0 gate (PLAN M0), run by `make scaffold`. About 25 s, 15 s of it hw-pkg-selftest (about 200
# small Verilator elaborations); a few more from clean (the C++ builds).
#   hw-pkg-check, regs-pkg-check   the generated packages are up to date (and regs' bit positions are the compiler's)
#   lint                           verilator -Wall on the p2_core shell, 0 warnings
#   check_ref_copies, check_ref_switches   the refsw3 checks every gate runs (PLAN 1.1)
#   *-selftest                     the checkers (gen_hw_pkg's header check and hw-pkg-check's MODE check,
#                                  check_ref_copies, check_ref_switches) and tb/common (p2tb.h, zkey.h) each shown
#                                  able to fail
# Ends with "scaffold: PASS" or "scaffold: FAIL", exit code to match; build/gate/scaffold/summary.txt.
set -u
. "$(dirname "$0")/lib.sh"

gate_begin scaffold
gate_step hw-pkg-check                $MAKE -s hw-pkg-check
gate_step regs-pkg-check              $MAKE -s regs-pkg-check
gate_step lint                        $MAKE -s lint
gate_step check_ref_copies            bash tools/check_ref_copies.sh
gate_step check_ref_switches          bash tools/check_ref_switches.sh --no-hwpkg
gate_step hw-pkg-selftest             $MAKE -s hw-pkg-selftest
gate_step check_ref_copies-selftest   bash tools/check_ref_copies.sh --selftest
gate_step check_ref_switches-selftest bash tools/check_ref_switches.sh --selftest
gate_step tbcommon-selftest           $MAKE -s tbcommon-selftest
gate_end
