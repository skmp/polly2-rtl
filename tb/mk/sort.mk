# sort.mk: M8, the run queue and the span sorter (PLAN M8; ARCHITECTURE 3.5, 3.6): p2_runq and p2_sort (rtl/v1/sort)
# with p2_entq (rtl/v1/isp/p2_isp_entq.sv) beside them; the testbench tb/sort against refsw3's SpanSort through p2ref.
#
#   make sort             the M8 gate (tools/gate/gate_sort.sh): check_ref_copies, check_ref_switches, the builds, the
#                         recorded run streams of the tile subset (tools/gate/capture_runs.sh: the ISP tile testbench in
#                         free-running mode on M7's quick inputs, --dump-runs; redone when the ISP or its testbench
#                         changed), lint-sort, the sorter on every recorded stream and on 100k random streams under
#                         SPAN_SORT_CFG 0x101, 0x001 and 0x000; "sort: PASS" last; build/gate/sort/summary.txt
#   make sort-full        the same with 1M random streams and the streams of M7's full set (isp-tile-full's inputs);
#                         SAMPLE=<seed>: a seeded sample of it (PLAN 0 rule 10)
#   make sort-mutants     the M8 mutants (tb/sort/mutants.txt) alone
#   make sort-build       build/obj_sort/tb
#   make lint-sort        verilator -Wall on p2_runq, p2_sort and the tb top (a prerequisite of make lint)
#
# Overridable: SORT_DIR (the RTL folder; tools/gate/mutants.py points it at a mutated copy), SORT_OBJDIR.
SORT_DIR     ?= rtl/v1/sort
SORT_OBJDIR  ?= $(BUILD)/obj_sort
SORT_SRC      = $(SORT_DIR)/p2_runq.sv $(SORT_DIR)/p2_sort.sv rtl/v1/isp/p2_isp_entq.sv
SORT_TB_SRC   = tb/sort/p2_sort_tb_top.sv
SORT_REFOBJ   = $(BUILD)/sort/sort_ref.o $(REFGLUE_OBJS)
SORT_CFLAGS   = -CFLAGS "-I$(CWD)/tb/common -I$(CWD)/tb/sort" -LDFLAGS "-lpthread -lz"

.PHONY: sort sort-full sort-mutants sort-build lint-sort

$(BUILD)/sort/sort_ref.o: tb/sort/sort_ref.cpp tb/sort/sort_ref.h tb/ref/p2ref.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -c $< -o $@

sort-build: $(SORT_REFOBJ)
	@mkdir -p $(SORT_OBJDIR)
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(SORT_CFLAGS) --top-module p2_sort_tb_top \
	  $(P2_PKG_SRC) $(SORT_SRC) $(SORT_TB_SRC) $(CWD)/tb/sort/sort_tb.cpp \
	  $(addprefix $(CWD)/,$(SORT_REFOBJ)) --Mdir $(SORT_OBJDIR) -o tb

sort:
	+@MAKE="$(MAKE)" bash tools/gate/gate_sort.sh
sort-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_sort.sh --full $(if $(SAMPLE),--sample $(SAMPLE))
sort-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_sort.sh --mutants

SORT_LINT = $(P2_LINT) rtl/v1/p2_lint.vlt tb/sort/sort_lint.vlt
lint-units: lint-sort
lint-sort:
	@for t in p2_runq p2_sort; do \
	  $(SORT_LINT) --top-module $$t $(P2_PKG_SRC) $(SORT_SRC) || { echo "lint-sort: $$t FAILED"; exit 1; }; done
	@$(SORT_LINT) --top-module p2_sort_tb_top $(P2_PKG_SRC) $(SORT_SRC) $(SORT_TB_SRC) || \
	  { echo "lint-sort: p2_sort_tb_top FAILED"; exit 1; }
	@echo "lint-sort: PASS"
