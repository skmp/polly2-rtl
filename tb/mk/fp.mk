# fp.mk: M1, the numerics primitives (PLAN M1; docs/spec/numerics.md 6, 7): rtl/v1/lib/fp, one testbench per
# primitive, each in lockstep with refcore (L1 headers and the verbatim copies of tb/fp/ref_copies.h).
#
#   make fp-a            the M1a gate (tools/gate/gate_fp.sh a): check_ref_copies, check_ref_switches, lint-fp, then
#                        every M1a testbench in quick mode; "fp-a: PASS" last; build/gate/fp-a/summary.txt
#   make fp-a-full       the M1a exhaustive sweeps (num 7.3), each testbench sharded FP_SHARDS ways (a few minutes)
#   make fp-a-mutants    every M1a mutant of tb/fp/mutants.txt is caught and the control passes (tools/gate/mutants.py)
#   make fp-b, fp-b-full, fp-b-mutants   the same for M1b (gate_fp.sh b); its mutants are in tb/fp/mutants.txt (lib/fp)
#                        and tb/fp/mutants_zword.txt (rtl/v1/pkg/p2_zword_pkg.sv)
#   make fp-c, fp-c-full, fp-c-mutants   the same for M1c (gate_fp.sh c; it also runs make roms-check, tb/mk/gen.mk); its
#                        mutants are in tb/fp/mutants.txt (lib/fp) and tb/fp/mutants_rom.txt (rtl/v1/lib/rom)
#   make fp, fp-full, fp-mutants   the same over every round (M1a, M1b, M1c): the M1 gate
#   make fp-<p>          one testbench, quick (build/obj_fp/<p>/tb); fp-<p>-full sharded; fp-<p>-build the build only
#                        <p>: lzc cut cutbelow in mul add recip cmp range (num H1, H2, H3, H4, H5, H6, H8, H9, H10);
#                        swamp halfline minor floor value zblock zword (num H7a, H7b, H7c, H11, H12a, H12b, H14);
#                        div colour rom (num H13, H15; the SIN / COS and dither ROMs)
#   make lint-fp         verilator -Wall on every lib/fp and lib/rom module and every tb/fp top (a prerequisite of make
#                        lint)
#
# Overridable: FP_DIR (the RTL folder; tools/gate/mutants.py points it at a mutated copy), ZW_DIR (the folder the
# testbenches take p2_zword_pkg.sv from: the same for tb/fp/mutants_zword.txt), ROM_DIR (the measured-table ROMs: the
# same for tb/fp/mutants_rom.txt), FP_OBJDIR, FP_SHARDS.
# A testbench's arguments: --seed S, --n N, --shard k/N, --only <section,...>, --full, --trace (tb/common/p2tb.h).
FP_DIR      ?= rtl/v1/lib/fp
FP_OBJDIR   ?= $(BUILD)/obj_fp
FP_SHARDS   ?= 12
ZW_DIR      ?= rtl/v1/pkg
ROM_DIR     ?= rtl/v1/lib/rom
FP_A_PRIMS   = lzc cut cutbelow in mul add recip cmp range
FP_B_PRIMS   = swamp halfline minor floor value zblock zword
FP_C_PRIMS   = div colour rom
FP_PRIMS     = $(FP_A_PRIMS) $(FP_B_PRIMS) $(FP_C_PRIMS)
FP_PKG_SRC   = $(patsubst rtl/v1/pkg/p2_zword_pkg.sv,$(ZW_DIR)/p2_zword_pkg.sv,$(P2_PKG_SRC)) $(FP_DIR)/p2_fp_pkg.sv
# the modules: lib/fp's primitives, and lib/rom's measured-table ROMs (PLAN M1c)
FP_SRC       = $(filter-out %/p2_fp_pkg.sv,$(sort $(wildcard $(FP_DIR)/p2_fp_*.sv))) $(sort $(wildcard $(ROM_DIR)/p2_rom_*.sv))
FP_TB_CFLAGS = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/fp"

.PHONY: fp fp-full fp-mutants fp-a fp-a-full fp-a-mutants fp-a-build fp-b fp-b-full fp-b-mutants fp-b-build \
        fp-c fp-c-full fp-c-mutants fp-c-build lint-fp \
        $(FP_PRIMS:%=fp-%) $(FP_PRIMS:%=fp-%-build) $(FP_PRIMS:%=fp-%-full)

$(FP_PRIMS:%=fp-%-build): fp-%-build:
	@mkdir -p $(FP_OBJDIR)/$*
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(FP_TB_CFLAGS) --top-module p2_fp_$*_tb_top \
	  $(FP_PKG_SRC) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC) tb/fp/p2_fp_$*_tb_top.sv $(CWD)/tb/fp/fp_$*_tb.cpp \
	  --Mdir $(FP_OBJDIR)/$* -o tb

$(FP_PRIMS:%=fp-%): fp-%: fp-%-build
	$(FP_OBJDIR)/$*/tb

$(FP_PRIMS:%=fp-%-full): fp-%-full: fp-%-build
	+@bash tools/gate/run_shards.sh fp-$*-full $(FP_SHARDS) $(BUILD)/fp/$*-full $(FP_OBJDIR)/$*/tb --full

fp-a-build: $(FP_A_PRIMS:%=fp-%-build)
fp-b-build: $(FP_B_PRIMS:%=fp-%-build)
fp-c-build: $(FP_C_PRIMS:%=fp-%-build)

fp-a:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh a
fp-a-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh a --full
fp-a-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh a --mutants
fp-b:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh b
fp-b-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh b --full
fp-b-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh b --mutants
fp-c:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh c
fp-c-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh c --full
fp-c-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh c --mutants
fp:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh all
fp-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh all --full
fp-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_fp.sh all --mutants

# every module alone (its default parameters) and every tb top (the instances' parameters), LINT_J at a time
FP_LINT = $(P2_LINT) tb/fp/fp_lint.vlt
lint-units: lint-fp
lint-fp:
	@printf '%s\n' $(notdir $(basename $(FP_SRC))) | \
	  xargs -P $(LINT_J) -I{} sh -c '$(FP_LINT) --top-module {} $(FP_PKG_SRC) $(FP_SRC) || { echo "lint-fp: {} FAILED"; exit 1; }'
	@printf '%s\n' $(FP_PRIMS) | \
	  xargs -P $(LINT_J) -I{} sh -c '$(FP_LINT) --top-module p2_fp_{}_tb_top $(FP_PKG_SRC) rtl/v1/pkg/p2_hw_check.sv \
	    $(FP_SRC) tb/fp/p2_fp_{}_tb_top.sv || { echo "lint-fp: p2_fp_{}_tb_top FAILED"; exit 1; }'
	@echo "lint-fp: PASS"
