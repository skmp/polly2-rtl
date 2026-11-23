# tsp_setup.mk: M9, the TSP's fetch, set-up store, plane setup and mip K (PLAN M9; ARCHITECTURE 3.7.1-3.7.4): the
# generated microprograms (tools/gen/gen_tsp_prog.cpp -> rtl/v1/pkg/p2_tsp_prog_pkg.sv), p2_tsp_store, p2_tsp_pfetch,
# p2_tsp_setup on p2_tsp_alu (rtl/v1/tsp), p2_mem's client C3; the testbench tb/tsp_setup against refsw3's GetFpuEntry
# through p2ref and the copies of MipSelect's K part.
#
#   make tsp-setup          the M9 gate (tools/gate/gate_tsp_setup.sh): hw-pkg-check, tsp-prog-check, check_ref_copies,
#                           check_ref_switches, the schedule and the sweep (reported), the build, then on one queue
#                           lint-tsp-setup, the graph check (1M random jobs, the dropped-offset class A3, the named cases,
#                           the console sets) and the testbench's sections (named, a3, console, random: 1M primitives)
#                           in slices; "tsp-setup: PASS" last; build/gate/tsp-setup/summary.txt
#   make tsp-setup-mutants  the M9 mutants (tb/tsp_setup/mutants.txt: the RTL; mutants_gen.txt: the generator's graphs)
#   make tsp-prog           regenerate rtl/v1/pkg/p2_tsp_prog_pkg.sv, build/gen/p2_tsp_prog.h, build/gen/p2_tsp_prog.txt
#   make tsp-prog-check     regenerate into build/gen/check/ and cmp against the checked-in package
#   make tsp-prog-sweep     the program lengths over the free parameters against the measured 39 / 48 / 64 / +5
#   make tsp-setup-graph    the graph check alone (TSP_GRAPH_N random jobs, 1M)
#   make tsp-setup-build    build/obj_tsp_setup/tb;  make lint-tsp-setup  verilator -Wall on the units and the tb top
#
# Overridable: TSP_DIR (the RTL folder), TSP_GEN_DIR and TSP_GEN_OBJDIR (the generator's folder and binary's): tools/gate/
# mutants.py points them at mutated copies; TSP_SETUP_OBJDIR, TSP_GRAPH_N, TSP_GRAPH_THREADS (8).
TSP_DIR           ?= rtl/v1/tsp
TSP_SETUP_OBJDIR  ?= $(BUILD)/obj_tsp_setup
TSP_GEN_DIR       ?= tools/gen
TSP_GEN_OBJDIR    ?= $(BUILD)/tools/gen
TSP_GRAPH_N       ?= 1000000
TSP_GRAPH_THREADS ?= 8
TSP_PROG_PKG       = rtl/v1/pkg/p2_tsp_prog_pkg.sv
TSP_PKG            = rtl/v1/pkg/p2_tsp_pkg.sv
GEN_TSP_BIN        = $(TSP_GEN_OBJDIR)/gen_tsp_prog
TSP_SETUP_SRC      = $(TSP_DIR)/p2_tsp_alu.sv $(TSP_DIR)/p2_tsp_setup.sv $(TSP_DIR)/p2_tsp_pfetch.sv $(TSP_DIR)/p2_tsp_store.sv \
                     $(MEM_DIR)/p2_mem.sv
TSP_SETUP_LIB      = $(FP_PKG_SRC) $(TSP_PKG) $(TSP_PROG_PKG) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC)
TSP_SETUP_TB_SRC   = tb/tsp_setup/p2_tsp_setup_tb_top.sv
TSP_SETUP_REFOBJ   = $(BUILD)/tsp_setup/tsp_setup_ref.o $(REFGLUE_OBJS)
TSP_SETUP_CFLAGS   = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/tsp_setup -I$(CWD)/$(BUILD)/gen" -LDFLAGS "-lpthread -lz"
GEN_TSP_FLAGS      = -std=c++17 -O2 -Wall -Wextra -I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/tsp_setup
TSP_CASE_HDRS      = tb/tsp_setup/tsp_cases.h tb/tsp_setup/ref_copies_tsp.h

.PHONY: tsp-setup tsp-setup-mutants tsp-prog tsp-prog-check tsp-prog-sweep tsp-setup-graph tsp-setup-graph-bin \
        tsp-setup-build lint-tsp-setup

$(GEN_TSP_BIN): $(TSP_GEN_DIR)/gen_tsp_prog.cpp $(TSP_CASE_HDRS) tb/common/p2tb.h $(wildcard $(REFCORE)/*.h)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(GEN_TSP_FLAGS) $< -o $@

tsp-setup-graph-bin: $(GEN_TSP_BIN)

tsp-prog: $(GEN_TSP_BIN)
	@mkdir -p $(BUILD)/gen
	$(GEN_TSP_BIN) --sv $(BUILD)/gen/p2_tsp_prog_pkg.sv.new --hdr $(BUILD)/gen/p2_tsp_prog.h --report $(BUILD)/gen/p2_tsp_prog.txt
	mv $(BUILD)/gen/p2_tsp_prog_pkg.sv.new $(TSP_PROG_PKG)

$(BUILD)/gen/p2_tsp_prog.h: $(GEN_TSP_BIN)
	@mkdir -p $(BUILD)/gen/check
	$(GEN_TSP_BIN) --sv $(BUILD)/gen/check/p2_tsp_prog_pkg.sv --hdr $@ --report $(BUILD)/gen/p2_tsp_prog.txt

tsp-prog-check: $(GEN_TSP_BIN)
	@mkdir -p $(BUILD)/gen/check
	@$(GEN_TSP_BIN) --sv $(BUILD)/gen/check/p2_tsp_prog_pkg.sv --hdr $(BUILD)/gen/check/p2_tsp_prog.h \
	  --report $(BUILD)/gen/p2_tsp_prog.txt
	@cmp -s $(BUILD)/gen/check/p2_tsp_prog.h $(BUILD)/gen/p2_tsp_prog.h || cp $(BUILD)/gen/check/p2_tsp_prog.h $(BUILD)/gen/p2_tsp_prog.h
	@cmp $(BUILD)/gen/check/p2_tsp_prog_pkg.sv $(TSP_PROG_PKG) && echo "tsp-prog-check: PASS" || \
	  { echo "tsp-prog-check: $(TSP_PROG_PKG) is not the generator's output (make tsp-prog)"; echo "tsp-prog-check: FAIL"; exit 1; }

tsp-prog-sweep: $(GEN_TSP_BIN)
	$(GEN_TSP_BIN) --sweep

tsp-setup-graph: $(GEN_TSP_BIN)
	$(GEN_TSP_BIN) --check --n $(TSP_GRAPH_N) --threads $(TSP_GRAPH_THREADS) --dcts $(DCTESTS)

$(BUILD)/tsp_setup/tsp_setup_ref.o: tb/tsp_setup/tsp_setup_ref.cpp tb/tsp_setup/tsp_setup_ref.h tb/tsp_setup/ref_copies_tsp.h \
                                    tb/ref/p2ref.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/tsp_setup -c $< -o $@

tsp-setup-build: $(TSP_SETUP_REFOBJ) $(BUILD)/gen/p2_tsp_prog.h
	@mkdir -p $(TSP_SETUP_OBJDIR)
	@# Verilator's own make does not relink when only an object of ours changed
	@if [ -f $(TSP_SETUP_OBJDIR)/tb ] && [ -n "$$(find $(TSP_SETUP_REFOBJ) -newer $(TSP_SETUP_OBJDIR)/tb)" ]; then \
	  rm -f $(TSP_SETUP_OBJDIR)/tb; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(TSP_SETUP_CFLAGS) --top-module p2_tsp_setup_tb_top \
	  $(TSP_SETUP_LIB) $(TSP_SETUP_SRC) $(TSP_SETUP_TB_SRC) $(CWD)/tb/tsp_setup/tsp_setup_tb.cpp \
	  $(addprefix $(CWD)/,$(TSP_SETUP_REFOBJ)) --Mdir $(TSP_SETUP_OBJDIR) -o tb

tsp-setup:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_setup.sh
tsp-setup-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_setup.sh --mutants

TSP_SETUP_LINT = $(P2_LINT) tb/fp/fp_lint.vlt tb/isp_setup/isp_setup_lint.vlt tb/tsp_setup/tsp_setup_lint.vlt
lint-units: lint-tsp-setup
lint-tsp-setup:
	@for t in p2_tsp_alu p2_tsp_setup p2_tsp_pfetch p2_tsp_store; do \
	  $(TSP_SETUP_LINT) --top-module $$t $(TSP_SETUP_LIB) $(TSP_SETUP_SRC) || { echo "lint-tsp-setup: $$t FAILED"; exit 1; }; done
	@$(TSP_SETUP_LINT) --top-module p2_tsp_setup_tb_top $(TSP_SETUP_LIB) $(TSP_SETUP_SRC) $(TSP_SETUP_TB_SRC) || \
	  { echo "lint-tsp-setup: p2_tsp_setup_tb_top FAILED"; exit 1; }
	@echo "lint-tsp-setup: PASS"
