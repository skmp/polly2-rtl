# isp_setup.mk: M4, the ISP setup sequencer and row stepper (PLAN M4): the generated microprograms
# (tools/gen/gen_setup_prog.cpp -> rtl/v1/pkg/p2_isp_prog_pkg.sv), p2_isp_setup on p2_isp_alu with the 1-deep hand-off,
# p2_isp_raster; the testbench tb/isp_setup in lockstep with refsw3 (the composition of M2's and M3's references).
#
#   make isp-setup          the M4 gate (tools/gate/gate_isp_setup.sh): hw-pkg-check, isp-prog-check, check_ref_copies (the
#                           setup copies), check_ref_switches, the vectors (isp-edge-vec, isp-depth-vec), the graph check,
#                           the build, lint-isp-setup, then the testbench in quick mode; "isp-setup: PASS" last;
#                           build/gate/isp-setup/summary.txt
#   make isp-setup-full     the same with the full counts (--full), sharded ISP_SETUP_SHARDS ways
#   make isp-setup-mutants  every mutant of tb/isp_setup/mutants.txt (rtl/v1/isp) and mutants_gen.txt (the generator's
#                           graphs: the graph check) caught, the control passing (tools/gate/mutants.py)
#   make isp-prog           regenerate rtl/v1/pkg/p2_isp_prog_pkg.sv, build/gen/p2_isp_prog.h (the testbench's copy of
#                           the schedule) and build/gen/p2_isp_prog.txt (the schedule, readable)
#   make isp-prog-check     regenerate into build/gen/ and cmp against the checked-in package
#   make isp-prog-sweep     the program lengths over the free parameters (ARCHITECTURE 6) against the measured 16 / 19
#   make isp-setup-graph    the graph check alone (PLAN M4 item 1): ISP_GRAPH_N random primitives (1M) and the console
#                           pages' records (build/vec/*.trz)
#   make isp-setup-tb       the testbench alone, quick (build/obj_isp_setup/tb); isp-setup-build the build only
#   make lint-isp-setup     verilator -Wall on p2_isp_setup, p2_isp_raster and the tb top (a prerequisite of make lint)
#
# Overridable: ISP_DIR (the RTL folder), ISP_GEN_DIR (the generator's folder) and ISP_GEN_OBJDIR (where its binary goes):
# tools/gate/mutants.py points them at mutated copies; ISP_SETUP_OBJDIR, ISP_SETUP_SHARDS, ISP_GRAPH_N.
ISP_SETUP_OBJDIR ?= $(BUILD)/obj_isp_setup
ISP_SETUP_SHARDS ?= 12
ISP_GEN_DIR      ?= tools/gen
ISP_GEN_OBJDIR   ?= $(BUILD)/tools/gen
ISP_GRAPH_N      ?= 1000000
ISP_PROG_PKG      = rtl/v1/pkg/p2_isp_prog_pkg.sv
GEN_SETUP_BIN     = $(ISP_GEN_OBJDIR)/gen_setup_prog
ISP_SETUP_SRC     = $(sort $(wildcard $(ISP_DIR)/p2_isp_*.sv))
ISP_SETUP_LIB     = $(FP_PKG_SRC) $(ISP_PROG_PKG) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC)
ISP_SETUP_TB_SRC  = tb/isp_setup/p2_isp_setup_tb_top.sv
ISP_SETUP_CFLAGS  = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/isp_setup -I$(CWD)/tb/isp_edge -I$(CWD)/tb/isp_depth \
                    -I$(CWD)/$(BUILD)/gen -I$(CWD)/tools/gate" -LDFLAGS "-lz"
GEN_SETUP_FLAGS   = -std=c++17 -O2 -Wall -Wextra -I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/isp_setup -I$(CWD)/tb/isp_depth

.PHONY: isp-setup isp-setup-full isp-setup-mutants isp-prog isp-prog-check isp-prog-sweep isp-setup-graph isp-setup-graph-bin \
        isp-setup-tb isp-setup-build lint-isp-setup

$(GEN_SETUP_BIN): $(ISP_GEN_DIR)/gen_setup_prog.cpp tb/isp_setup/ref_copies_setup.h $(REFCORE_HDRS)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(GEN_SETUP_FLAGS) $< -o $@

isp-setup-graph-bin: $(GEN_SETUP_BIN)

isp-prog: $(GEN_SETUP_BIN)
	@mkdir -p $(BUILD)/gen
	$(GEN_SETUP_BIN) --sv $(BUILD)/gen/p2_isp_prog_pkg.sv.new --hdr $(BUILD)/gen/p2_isp_prog.h --report $(BUILD)/gen/p2_isp_prog.txt
	mv $(BUILD)/gen/p2_isp_prog_pkg.sv.new $(ISP_PROG_PKG)

# the testbench's copy of the schedule comes from the same generator run as the package it is checked against
$(BUILD)/gen/p2_isp_prog.h: $(GEN_SETUP_BIN)
	@mkdir -p $(BUILD)/gen/check
	$(GEN_SETUP_BIN) --sv $(BUILD)/gen/check/p2_isp_prog_pkg.sv --hdr $@ --report $(BUILD)/gen/p2_isp_prog.txt

# regenerates every time: the package against the checked-in one, and the testbench's header refreshed if it differs
isp-prog-check: $(GEN_SETUP_BIN)
	@mkdir -p $(BUILD)/gen/check
	@$(GEN_SETUP_BIN) --sv $(BUILD)/gen/check/p2_isp_prog_pkg.sv --hdr $(BUILD)/gen/check/p2_isp_prog.h \
	  --report $(BUILD)/gen/p2_isp_prog.txt
	@cmp -s $(BUILD)/gen/check/p2_isp_prog.h $(BUILD)/gen/p2_isp_prog.h || cp $(BUILD)/gen/check/p2_isp_prog.h $(BUILD)/gen/p2_isp_prog.h
	@cmp $(BUILD)/gen/check/p2_isp_prog_pkg.sv $(ISP_PROG_PKG) && echo "isp-prog-check: PASS" || \
	  { echo "isp-prog-check: $(ISP_PROG_PKG) is not the generator's output (make isp-prog)"; echo "isp-prog-check: FAIL"; exit 1; }

isp-prog-sweep: $(GEN_SETUP_BIN)
	$(GEN_SETUP_BIN) --sweep

isp-setup-graph: $(GEN_SETUP_BIN)
	$(GEN_SETUP_BIN) --check --n $(ISP_GRAPH_N) --vec $(BUILD)/vec --threads 8

isp-setup-build: $(BUILD)/gen/p2_isp_prog.h
	@mkdir -p $(ISP_SETUP_OBJDIR)
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(ISP_SETUP_CFLAGS) --top-module p2_isp_setup_tb_top \
	  $(ISP_SETUP_LIB) $(ISP_SETUP_SRC) $(ISP_SETUP_TB_SRC) $(CWD)/tb/isp_setup/isp_setup_tb.cpp \
	  --Mdir $(ISP_SETUP_OBJDIR) -o tb

isp-setup-tb: isp-setup-build
	$(ISP_SETUP_OBJDIR)/tb

isp-setup:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_setup.sh
isp-setup-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_setup.sh --full
isp-setup-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_setup.sh --mutants

ISP_SETUP_LINT = $(P2_LINT) tb/isp_setup/isp_setup_lint.vlt
lint: lint-isp-setup
lint-isp-setup:
	@for t in p2_isp_setup p2_isp_raster; do \
	  $(ISP_SETUP_LINT) --top-module $$t $(FP_PKG_SRC) $(ISP_PROG_PKG) $(FP_SRC) $(ISP_SETUP_SRC) || \
	  { echo "lint-isp-setup: $$t FAILED"; exit 1; }; done
	@$(ISP_SETUP_LINT) --top-module p2_isp_setup_tb_top $(ISP_SETUP_LIB) $(ISP_SETUP_SRC) $(ISP_SETUP_TB_SRC) || \
	  { echo "lint-isp-setup: p2_isp_setup_tb_top FAILED"; exit 1; }
	@echo "lint-isp-setup: PASS"
