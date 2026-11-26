# core_units.mk: M12, everything p2_core instances (PLAN M12; ARCHITECTURE 1.1): the units of M2-M11 and M12's p2_regs
# (rtl/v1/regs), p2_seq (rtl/v1/seq), p2_tbuf_ctl / p2_tbuf_hs (rtl/v1/tbuf), p2_wout / p2_wout_put (rtl/v1/wout).
# P2_CORE_LIB: the packages and the numerics library; P2_CORE_SRC (core.mk): p2_core's units. Overridable: REGS_DIR,
# SEQ_DIR, WOUT_DIR (tools/gate/mutants.py points them at mutated copies; TBUF_DIR, TSP_DIR, ... as their fragments say).
REGS_DIR ?= $(RTLV1)/regs
SEQ_DIR  ?= $(RTLV1)/seq
WOUT_DIR ?= $(RTLV1)/wout
P2_CORE_LIB  = $(FP_PKG_SRC) $(ISP_PROG_PKG) $(TSP_PKG) $(TSP_PROG_PKG) $(FP_SRC)
P2_M12_SRC   = $(REGS_DIR)/p2_regs.sv $(SEQ_DIR)/p2_seq.sv $(TBUF_DIR)/p2_tbuf_ctl.sv $(TBUF_DIR)/p2_tbuf_hs.sv \
               $(WOUT_DIR)/p2_wout.sv $(WOUT_DIR)/p2_wout_put.sv
P2_CORE_SRC += $(sort $(ISP_TILE_SRC) $(SORT_DIR)/p2_runq.sv $(SORT_DIR)/p2_sort.sv $(TSP_RUN_SRC)) $(P2_M12_SRC)
P2_CORE_VLT  = rtl/v1/p2_lint.vlt tb/fp/fp_lint.vlt tb/isp_setup/isp_setup_lint.vlt tb/isp_tile/isp_tile_lint.vlt \
               tb/sort/sort_lint.vlt tb/tsp_setup/tsp_setup_lint.vlt tb/tsp_run/tsp_run_lint.vlt tb/tsp_tile/tsp_tile_lint.vlt \
               tb/wout/wout_lint.vlt
