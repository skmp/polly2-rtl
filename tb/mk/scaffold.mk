# scaffold.mk: the M0 gate (PLAN M0) and the refsw3 checks every gate runs (PLAN 1.1).
#
#   make scaffold            tools/gate/gate_scaffold.sh: hw-pkg-check, regs-pkg-check, lint, check_ref_copies,
#                            check_ref_switches, the checkers' (hw-pkg-selftest too) and tb/common's self-tests;
#                            "scaffold: PASS" last; build/gate/scaffold/summary.txt
#   make check-ref-copies    tools/check_ref_copies.sh (the verbatim copies in tb/**/ref_copies*.h against refcore)
#   make check-ref-switches  tools/check_ref_switches.sh (MIP_K / MIP_ARITH / FOG_VARIANT ..., and hw-pkg-check)
.PHONY: scaffold check-ref-copies check-ref-switches

scaffold:
	+@MAKE="$(MAKE)" bash tools/gate/gate_scaffold.sh

check-ref-copies:
	@bash tools/check_ref_copies.sh

check-ref-switches:
	+@MAKE="$(MAKE)" bash tools/check_ref_switches.sh
