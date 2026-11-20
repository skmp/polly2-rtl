# isp_edge.mk: M2, the ISP edge path (PLAN M2): rtl/v1/isp's edge units, the testbench tb/isp_edge in lockstep with
# refsw3 (L1 headers and the verbatim copies of tb/isp_edge/ref_copies_edge.h), the console pages' primitives.
#
#   make isp-edge          the M2 gate (tools/gate/gate_isp_edge.sh): hw-pkg-check, check_ref_copies (the edge copies),
#                          check_ref_switches, tria_extract (build/vec), the build, lint-isp-edge, then the testbench in
#                          quick mode; "isp-edge: PASS" last; build/gate/isp-edge/summary.txt
#   make isp-edge-full     the same with the testbench's full sweeps (--full), sharded ISP_EDGE_SHARDS ways
#   make isp-edge-mutants  every mutant of tb/isp_edge/mutants.txt caught, the control passing (tools/gate/mutants.py)
#   make isp-edge-tb       the testbench alone, quick (build/obj_isp_edge/tb); isp-edge-build the build only
#   make isp-edge-vec      tools/gate/tria_extract.sh on the M2 tests (fit/hw faredge*, hugepos*, edge2_*)
#   make refsw3-offline    nulldc3's refsw3-offline, built into build/refsw3-offline (its own build.sh)
#   make lint-isp-edge     verilator -Wall on the edge units and the tb top (a prerequisite of make lint)
#
# Overridable: ISP_DIR (the RTL folder; tools/gate/mutants.py points it at a mutated copy), ISP_EDGE_OBJDIR,
# ISP_EDGE_SHARDS.
ISP_DIR          ?= rtl/v1/isp
ISP_EDGE_OBJDIR  ?= $(BUILD)/obj_isp_edge
ISP_EDGE_SHARDS  ?= 12
ISP_EDGE_SRC      = $(sort $(wildcard $(ISP_DIR)/p2_isp_*.sv))
ISP_EDGE_LIB      = $(FP_PKG_SRC) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC)
ISP_EDGE_TB_SRC   = tb/isp_edge/p2_isp_edge_tb_top.sv
ISP_EDGE_CFLAGS   = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/isp_edge -I$(CWD)/tools/gate" -LDFLAGS "-lz"
ISP_EDGE_TESTS    = $(sort $(filter faredge% hugepos% edge2_%,$(filter-out %_races,$(notdir $(wildcard $(DCTESTS)/fit/hw/*)))))
TRIA_CONV         = $(BUILD)/tools/tria_conv

.PHONY: isp-edge isp-edge-full isp-edge-mutants isp-edge-tb isp-edge-build isp-edge-vec refsw3-offline lint-isp-edge

isp-edge-build:
	@mkdir -p $(ISP_EDGE_OBJDIR)
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(ISP_EDGE_CFLAGS) --top-module p2_isp_edge_tb_top \
	  $(ISP_EDGE_LIB) $(ISP_EDGE_SRC) $(ISP_EDGE_TB_SRC) $(CWD)/tb/isp_edge/isp_edge_tb.cpp \
	  --Mdir $(ISP_EDGE_OBJDIR) -o tb

isp-edge-tb: isp-edge-build
	$(ISP_EDGE_OBJDIR)/tb

$(TRIA_CONV): tools/gate/tria_conv.cpp tb/isp_edge/tri_rec.h tb/isp_depth/triz_rec.h tb/common/p2tb.h
	@mkdir -p $(dir $@)
	$(HOSTCXX) -std=c++17 -O2 -Wall -Wextra -Itb/common -Itb/isp_edge -Itb/isp_depth $< -o $@

refsw3-offline:
	@bash $(NULLDC3)/refsw3-offline/build.sh $(CWD)/$(BUILD)/refsw3-offline

isp-edge-vec: refsw3-offline $(TRIA_CONV)
	@bash tools/gate/tria_extract.sh -j 8 $(ISP_EDGE_TESTS)

isp-edge:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_edge.sh
isp-edge-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_edge.sh --full
isp-edge-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_edge.sh --mutants

ISP_EDGE_LINT = $(P2_LINT) tb/isp_edge/isp_edge_lint.vlt
lint: lint-isp-edge
lint-isp-edge:
	@for t in p2_isp_edge_setup p2_isp_edge_raster; do \
	  $(ISP_EDGE_LINT) --top-module $$t $(FP_PKG_SRC) $(FP_SRC) $(ISP_EDGE_SRC) || { echo "lint-isp-edge: $$t FAILED"; exit 1; }; done
	@$(ISP_EDGE_LINT) --top-module p2_isp_edge_tb_top $(ISP_EDGE_LIB) $(ISP_EDGE_SRC) $(ISP_EDGE_TB_SRC) || \
	  { echo "lint-isp-edge: p2_isp_edge_tb_top FAILED"; exit 1; }
	@echo "lint-isp-edge: PASS"
