# core.mk: the RTL's file lists and make lint (conventions.md 4.8).
#
#   make lint        verilator --lint-only -Wall on p2_core (lint-core) and on every unit top; every warning fails
#
# P2_PKG_SRC is every package, in dependency order (a package before its first import). P2_CORE_SRC is everything
# p2_core instances. A unit's fragment appends its files to these with +=, and adds its own top's lint as a
# prerequisite (`lint: lint-<unit>`) with its own rule and waiver file, tb/<unit>/<unit>_lint.vlt.
P2_PKG_SRC  = rtl/v1/pkg/p2_hw_pkg.sv rtl/v1/pkg/p2_regs_pkg.sv rtl/v1/pkg/p2_pkg.sv rtl/v1/pkg/p2_zword_pkg.sv
P2_CORE_SRC = rtl/v1/pkg/p2_hw_check.sv rtl/v1/p2_core.sv
P2_LINT     = $(VERILATOR) --lint-only -Wall -Werror-USERFATAL

.PHONY: lint lint-core
lint: lint-core
	@echo "lint: PASS"

lint-core:
	$(P2_LINT) rtl/v1/p2_lint.vlt --top-module p2_core $(P2_PKG_SRC) $(P2_CORE_SRC)
