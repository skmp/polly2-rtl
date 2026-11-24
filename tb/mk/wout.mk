# wout.mk: M12, the write-out (PLAN M12; ARCHITECTURE 3.9, 3.10): p2_wout, p2_wout_put (rtl/v1/wout), the tile buffers'
# controller p2_tbuf_ctl / p2_tbuf_hs (rtl/v1/tbuf) and p2_tbuf, on C5 of p2_mem.
#   tb/wout/wout_tb.cpp   random frames against RenderCORE's frame from its verbatim copies (p2ref::copy::RenderFrame:
#                         core-put, core-prev, core-writeout, core-endframe), every word of video memory (p2_wout_tb_top)
#
#   make wout             the M12 write-out gate (tools/gate/gate_wout.sh); "wout: PASS" last; build/gate/wout/
#   make wout-mutants     PLAN M12's write-out mutants (tb/wout/mutants.txt, mutants_tbuf.txt)
#   make wout-build, lint-wout
#
# Overridable: WOUT_DIR, TBUF_DIR (mutants.py), WOUT_OBJDIR.
WOUT_OBJDIR  ?= $(BUILD)/obj_wout
WOUT_SRC      = $(WOUT_DIR)/p2_wout.sv $(WOUT_DIR)/p2_wout_put.sv $(TBUF_DIR)/p2_tbuf.sv $(TBUF_DIR)/p2_tbuf_ctl.sv \
                $(TBUF_DIR)/p2_tbuf_hs.sv rtl/v1/isp/p2_isp_entq.sv $(MEM_DIR)/p2_mem.sv
WOUT_LIB      = $(P2_PKG_SRC) rtl/v1/pkg/p2_hw_check.sv
WOUT_TB_SRC   = tb/wout/p2_wout_tb_top.sv
WOUT_REFOBJ   = $(BUILD)/wout/wout_ref.o $(REFGLUE_OBJS)
WOUT_CFLAGS   = -CFLAGS "-I$(CWD)/tb/common -I$(CWD)/tb/wout" -LDFLAGS "-lpthread -lz"

.PHONY: wout wout-mutants wout-build lint-wout

$(BUILD)/wout/wout_ref.o: tb/wout/wout_ref.cpp tb/wout/wout_ref.h tb/ref/p2ref.h tb/ref/ref_copies.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/wout -c $< -o $@

wout-build: $(WOUT_REFOBJ)
	@mkdir -p $(WOUT_OBJDIR)
	@if [ -f $(WOUT_OBJDIR)/tb ] && [ -n "$$(find $(WOUT_REFOBJ) -newer $(WOUT_OBJDIR)/tb)" ]; then rm -f $(WOUT_OBJDIR)/tb; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(WOUT_CFLAGS) --top-module p2_wout_tb_top \
	  $(WOUT_LIB) $(WOUT_SRC) $(WOUT_TB_SRC) $(CWD)/tb/wout/wout_tb.cpp \
	  $(addprefix $(CWD)/,$(WOUT_REFOBJ)) --Mdir $(WOUT_OBJDIR) -o tb

wout:
	+@MAKE="$(MAKE)" bash tools/gate/gate_wout.sh
wout-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_wout.sh --mutants

WOUT_LINT = $(P2_LINT) $(P2_CORE_VLT)
lint-units: lint-wout
lint-wout:
	@for t in p2_regs p2_seq p2_tbuf_ctl p2_wout p2_wout_put; do \
	  $(WOUT_LINT) --top-module $$t $(P2_CORE_LIB) $(P2_CORE_SRC) || { echo "lint-wout: $$t FAILED"; exit 1; }; done
	@$(WOUT_LINT) --top-module p2_wout_tb_top $(WOUT_LIB) $(WOUT_SRC) $(WOUT_TB_SRC) || { echo "lint-wout: p2_wout_tb_top FAILED"; exit 1; }
	@echo "lint-wout: PASS"
