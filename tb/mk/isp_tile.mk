# isp_tile.mk: M6 and M7, the ISP tile (PLAN M6, M7, 1.3 "ISP tile testbench"): p2_isp_ctl, p2_isp_olw, p2_isp_pfetch,
# p2_isp_buf, p2_isp_pix, p2_isp_ptc, p2_isp_pcache, p2_isp_cut, p2_isp_fb, p2_isp_entq with M4's p2_isp_setup and
# p2_isp_raster, p2_mem with the clients C1 and C2; the testbench tb/isp_tile in phase-halt and free-running mode against
# the M5 phase driver (tb/ref) through p2ref, the VRAM model tb/common/vram_model.h.
#
#   make isp-tile             the M7 gate (tools/gate/gate_isp_tile.sh): check_ref_copies, check_ref_switches, the builds,
#                             the captures (M6's and M7's pages, the dumps, scenegen seeds 1-200), lint-isp-tile, the
#                             testbench in phase-halt mode and in free-running mode (--vramvary 7); "isp-tile: PASS" last;
#                             build/gate/isp-tile/summary.txt
#   make isp-tile-full        the same on the full set (every fit/hw test, every dump, seeds 1-5000)
#   make isp-tile-mutants     the M7 mutants (tb/isp_tile/mutants_m7.txt) alone
#
#   make isp-tile-op          the M6 gate (tools/gate/gate_isp_tile_op.sh): check_ref_copies, check_ref_switches, the
#                             builds, the captures of the M6 inputs (tb/tile/subset_isp_op.txt, the tile subset's dumps,
#                             scenegen seeds 1-200), lint-isp-tile, the testbench in phase-halt mode with the VRAM model
#                             plain and with --vramvary, the mutants (tb/isp_tile/mutants.txt); "isp-tile-op: PASS" last;
#                             build/gate/isp-tile-op/summary.txt
#   make isp-tile-op-full     the same on every capture of build/pre (the M5 full set when captured) and both VRAM modes
#   make isp-tile-op-mutants  the mutants alone
#   make isp-tile-build       build/obj_isp_tile/tb (the Verilated ISP, the testbench, the L2 glue, the phase driver)
#   make lint-isp-tile        verilator -Wall on the M6 units, p2_mem and the tb top (a prerequisite of make lint)
#
# Overridable: ISP_DIR (the RTL folder), MEM_DIR (p2_mem's): tools/gate/mutants.py points them at mutated copies;
# ISP_TILE_OBJDIR.
ISP_TILE_OBJDIR ?= $(BUILD)/obj_isp_tile
MEM_DIR         ?= rtl/v1/mem
ISP_TILE_SRC     = $(sort $(wildcard $(ISP_DIR)/p2_isp_*.sv)) $(MEM_DIR)/p2_mem.sv
ISP_TILE_LIB     = $(FP_PKG_SRC) $(ISP_PROG_PKG) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC)
ISP_TILE_TB_SRC  = tb/isp_tile/p2_isp_tile_tb_top.sv
ISP_TILE_REFOBJ  = $(BUILD)/isp_tile/isp_tile_ref.o $(BUILD)/isp_tile/phase_driver.o $(REFGLUE_OBJS)
ISP_TILE_CFLAGS  = -CFLAGS "-I$(CWD)/tb/common -I$(CWD)/tb/isp_tile" -LDFLAGS "-lpthread -lz"

.PHONY: isp-tile isp-tile-full isp-tile-mutants isp-tile-op isp-tile-op-full isp-tile-op-mutants isp-tile-build \
        lint-isp-tile

$(BUILD)/isp_tile/isp_tile_ref.o: tb/isp_tile/isp_tile_ref.cpp tb/isp_tile/isp_tile_ref.h tb/ref/phase_driver.h tb/ref/p2ref.h \
                                  tb/common/isp_live.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/common -c $< -o $@
$(BUILD)/isp_tile/phase_driver.o: tb/ref/phase_driver.cpp tb/ref/phase_driver.h tb/ref/p2ref.h tb/ref/ref_copies.h \
                                  tb/common/isp_live.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/common -c $< -o $@

isp-tile-build: $(ISP_TILE_REFOBJ)
	@mkdir -p $(ISP_TILE_OBJDIR)
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(ISP_TILE_CFLAGS) --top-module p2_isp_tile_tb_top \
	  $(ISP_TILE_LIB) $(ISP_TILE_SRC) $(ISP_TILE_TB_SRC) $(CWD)/tb/isp_tile/isp_tile_tb.cpp \
	  $(addprefix $(CWD)/,$(ISP_TILE_REFOBJ)) --Mdir $(ISP_TILE_OBJDIR) -o tb

isp-tile:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile.sh
isp-tile-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile.sh --full
isp-tile-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile.sh --mutants
isp-tile-op:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile_op.sh
isp-tile-op-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile_op.sh --full
isp-tile-op-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_tile_op.sh --mutants

ISP_TILE_LINT = $(P2_LINT) tb/isp_setup/isp_setup_lint.vlt tb/isp_tile/isp_tile_lint.vlt
lint-units: lint-isp-tile
lint-isp-tile:
	@for t in p2_isp_ctl p2_isp_olw p2_isp_pfetch p2_isp_pix p2_isp_buf p2_isp_ptc p2_isp_pcache p2_isp_fb p2_isp_cut \
	  p2_isp_entq; do \
	  $(ISP_TILE_LINT) --top-module $$t $(FP_PKG_SRC) $(ISP_PROG_PKG) $(FP_SRC) $(ISP_TILE_SRC) || \
	  { echo "lint-isp-tile: $$t FAILED"; exit 1; }; done
	@$(ISP_TILE_LINT) --top-module p2_mem $(P2_PKG_SRC) $(MEM_DIR)/p2_mem.sv || { echo "lint-isp-tile: p2_mem FAILED"; exit 1; }
	@$(ISP_TILE_LINT) --top-module p2_isp_tile_tb_top $(ISP_TILE_LIB) $(ISP_TILE_SRC) $(ISP_TILE_TB_SRC) || \
	  { echo "lint-isp-tile: p2_isp_tile_tb_top FAILED"; exit 1; }
	@echo "lint-isp-tile: PASS"
