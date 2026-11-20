# gen.mk: the generated packages (conventions.md 5). Both are checked in; synthesis needs them.
#
#   make hw-pkg          rtl/v1/pkg/p2_hw_pkg.sv from refcore's *HW structs (tools/gen/gen_hw_pkg.cpp)
#   make regs-pkg        rtl/v1/pkg/p2_regs_pkg.sv from pvr_regs.h, core_structs.h, refsw_lists_regtypes.h,
#                        refsw_lists.h (tools/gen/gen_regs.py)
#   make hw-pkg-check    regenerate into build/gen/ and cmp; every MODE member's change fails elaboration (p2_hw_check.sv)
#   make hw-pkg-selftest the generator's header check and hw-pkg-check's MODE check, each rule shown failing
#   make regs-pkg-check  regenerate into build/gen/ and cmp; the C compiler's layout of every field equals the package's
GEN_HW_BIN   = $(BUILD)/tools/gen/gen_hw_pkg
REFCORE_HDRS = $(wildcard $(REFCORE)/*.h)

.PHONY: hw-pkg hw-pkg-check hw-pkg-selftest regs-pkg regs-pkg-check

$(GEN_HW_BIN): tools/gen/gen_hw_pkg.cpp $(REFCORE_HDRS)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(HOST_CXXFLAGS) $< -o $@

hw-pkg: $(GEN_HW_BIN)
	@mkdir -p $(BUILD)/gen
	$(GEN_HW_BIN) $(REFCORE) > $(BUILD)/gen/p2_hw_pkg.sv.new
	mv $(BUILD)/gen/p2_hw_pkg.sv.new rtl/v1/pkg/p2_hw_pkg.sv

# the RTL file lists of core.mk, for the elaborations of the MODE check
HW_PKG_CHECK_ENV = VERILATOR="$(VERILATOR)" P2_PKG_SRC="$(P2_PKG_SRC)" P2_CORE_SRC="$(P2_CORE_SRC)"

hw-pkg-check: $(GEN_HW_BIN)
	@$(HW_PKG_CHECK_ENV) bash tools/gen/check_hw_pkg.sh $(GEN_HW_BIN) $(REFCORE)

hw-pkg-selftest: $(GEN_HW_BIN)
	@$(HW_PKG_CHECK_ENV) bash tools/gen/check_hw_pkg.sh --selftest $(GEN_HW_BIN) $(REFCORE)

regs-pkg:
	@mkdir -p $(BUILD)/gen
	python3 tools/gen/gen_regs.py $(NULLDC3) > $(BUILD)/gen/p2_regs_pkg.sv.new
	mv $(BUILD)/gen/p2_regs_pkg.sv.new rtl/v1/pkg/p2_regs_pkg.sv

regs-pkg-check:
	@bash tools/gen/check_regs_pkg.sh $(NULLDC3) "$(HOSTCXX)" "$(REFOFF_FLAGS) $(REFOFF_DEF) $(REFOFF_INC)"
