# core.mk: the RTL's file lists and make lint (conventions.md 4.8).
#
#   make lint        verilator --lint-only -Wall on p2_core (lint-core) and on every unit top; every warning fails
#
# P2_PKG_SRC is every package, in dependency order (a package before its first import). P2_CORE_SRC is everything
# p2_core instances. A unit's fragment appends its files to these with +=, and adds its own top's lint as a
# prerequisite of lint-units (`lint-units: lint-<unit>`) with its own rule and waiver file, tb/<unit>/<unit>_lint.vlt.
# make lint runs lint-units' prerequisites LINT_J at a time (PLAN 0 rule 8).
P2_PKG_SRC  = rtl/v1/pkg/p2_hw_pkg.sv rtl/v1/pkg/p2_regs_pkg.sv rtl/v1/pkg/p2_pkg.sv rtl/v1/pkg/p2_zword_pkg.sv
P2_CORE_SRC = rtl/v1/pkg/p2_hw_check.sv rtl/v1/p2_core.sv
P2_LINT     = $(VERILATOR) --lint-only -Wall -Werror-USERFATAL

.PHONY: lint lint-core lint-units
lint-units: lint-core
lint:
	+@$(MAKE) --no-print-directory -j$(LINT_J) -s lint-units
	@echo "lint: PASS"

lint-core:
	$(P2_LINT) rtl/v1/p2_lint.vlt --top-module p2_core $(P2_PKG_SRC) $(P2_CORE_SRC)
