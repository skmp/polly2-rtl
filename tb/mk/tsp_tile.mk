# tsp_tile.mk: M11, the pixel pipe's texture, shading, fog, SupSample and blend, and the tile buffers (PLAN M11;
# ARCHITECTURE 3.7.7, 3.8, 3.9): p2_tex_coord, p2_tex_addr, p2_tex_cache (C4), p2_tex_pal, p2_tex_decode, p2_tex_filter
# (rtl/v1/tex), p2_pp_shade, p2_pp_fog, p2_pp_ss, p2_pp_blend and the pipe p2_tsp_pp (rtl/v1/tsp), p2_tbuf (rtl/v1/tbuf).
# Two testbenches:
#   tb/tsp_tile/tsp_tile_tb.cpp   the TSP tile testbench (PLAN 1.3): the TSP side from the sorter's items to the tile
#                                 buffers (p2_tsp_tile_tb_top) on the captures (build/pre), against the M5 phase driver
#                                 through p2ref (the lists half tb/tsp_tile/refcore_glue_lists_rpt.cpp)
#   tb/tsp_tile/tsp_unit_tb.cpp   the unit sections: the texture path P3 - P6 (p2_tex_*) against p2ref::texture_filter, and
#                                 P7 - P10 (p2_pp_shade, p2_pp_fog, p2_pp_ss, p2_pp_blend, p2_tbuf) against the copies of
#                                 PixelFlush_tsp's bumpLight / shade / fade / SupSample average (tb/tsp_tile/ref_copies_tile.h)
#                                 and p2ref::combiner / bump / fog / blend, on random inputs (p2_tsp_unit_tb_top)
#
#   make tsp-tile             the M11 gate (tools/gate/gate_tsp_tile.sh); "tsp-tile: PASS" last; build/gate/tsp-tile/
#   make tsp-tile-mutants     the M11 mutants (tb/tsp_tile/mutants*.txt)
#   make tsp-tile-full        every render of every case (fit/hw tests, every dump, seeds 1-5000); SAMPLE=<seed>: a seeded
#                             sample of it (PLAN 0 rule 10)
#   make tsp-tile-build, tsp-unit-build, lint-tsp-tile
#
# Overridable: TSP_DIR, TEX_DIR, TBUF_DIR (tsp_run.mk; tools/gate/mutants.py points them at mutated copies),
# TSP_TILE_OBJDIR (the unit testbench builds into its unit/: one object folder for tools/gate/mutants.py).
TSP_TILE_OBJDIR  ?= $(BUILD)/obj_tsp_tile
TSP_UNIT_OBJDIR   = $(TSP_TILE_OBJDIR)/unit
TSP_TILE_SRC      = $(TSP_RUN_SRC)
TSP_TILE_TB_SRC   = tb/tsp_tile/p2_tsp_tile_tb_top.sv
TSP_UNIT_TB_SRC   = tb/tsp_tile/p2_tsp_unit_tb_top.sv
# the glue with the lists half that routes the walk's RenderParamTags calls through the pass hook
TSP_TILE_GLUE     = $(filter-out %/refcore_glue_lists.o,$(REFGLUE_OBJS)) $(BUILD)/tsp_tile/refcore_glue_lists_rpt.o
TSP_TILE_REFOBJ   = $(BUILD)/tsp_tile/tsp_tile_ref.o $(BUILD)/tsp_tile/phase_driver.o $(TSP_TILE_GLUE)
TSP_UNIT_REFOBJ   = $(BUILD)/tsp_tile/tsp_unit_ref.o $(REFGLUE_OBJS)
TSP_TILE_CFLAGS   = -CFLAGS "-I$(CWD)/tb/common -I$(CWD)/tb/tsp_tile" -LDFLAGS "-lpthread -lz"

.PHONY: tsp-tile tsp-tile-mutants tsp-tile-full tsp-tile-build tsp-unit-build lint-tsp-tile

$(BUILD)/tsp_tile/refcore_glue_lists_rpt.o: tb/tsp_tile/refcore_glue_lists_rpt.cpp tb/ref/refcore_glue_lists.cpp tb/ref/p2ref.h \
                                            tb/ref/ref_copies.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -c $< -o $@
$(BUILD)/tsp_tile/tsp_tile_ref.o: tb/tsp_tile/tsp_tile_ref.cpp tb/tsp_tile/tsp_tile_ref.h tb/ref/phase_driver.h tb/ref/p2ref.h \
                                  tb/common/isp_live.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/common -c $< -o $@
$(BUILD)/tsp_tile/phase_driver.o: tb/ref/phase_driver.cpp tb/ref/phase_driver.h tb/ref/p2ref.h tb/ref/ref_copies.h \
                                  tb/common/isp_live.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/common -c $< -o $@
$(BUILD)/tsp_tile/tsp_unit_ref.o: tb/tsp_tile/tsp_unit_ref.cpp tb/tsp_tile/tsp_unit_ref.h tb/ref/p2ref.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/tsp_tile -c $< -o $@

tsp-tile-build: $(TSP_TILE_REFOBJ)
	@mkdir -p $(TSP_TILE_OBJDIR)
	@if [ -f $(TSP_TILE_OBJDIR)/tb ] && [ -n "$$(find $(TSP_TILE_REFOBJ) -newer $(TSP_TILE_OBJDIR)/tb)" ]; then \
	  rm -f $(TSP_TILE_OBJDIR)/tb; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(TSP_TILE_CFLAGS) --top-module p2_tsp_tile_tb_top \
	  $(TSP_SETUP_LIB) $(TSP_TILE_SRC) $(TSP_TILE_TB_SRC) $(CWD)/tb/tsp_tile/tsp_tile_tb.cpp \
	  $(addprefix $(CWD)/,$(TSP_TILE_REFOBJ)) --Mdir $(TSP_TILE_OBJDIR) -o tb

tsp-unit-build: $(TSP_UNIT_REFOBJ)
	@mkdir -p $(TSP_UNIT_OBJDIR)
	@if [ -f $(TSP_UNIT_OBJDIR)/tb ] && [ -n "$$(find $(TSP_UNIT_REFOBJ) -newer $(TSP_UNIT_OBJDIR)/tb)" ]; then \
	  rm -f $(TSP_UNIT_OBJDIR)/tb; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(TSP_TILE_CFLAGS) --top-module p2_tsp_unit_tb_top \
	  $(TSP_SETUP_LIB) $(TSP_TILE_SRC) $(TSP_UNIT_TB_SRC) $(CWD)/tb/tsp_tile/tsp_unit_tb.cpp \
	  $(addprefix $(CWD)/,$(TSP_UNIT_REFOBJ)) --Mdir $(TSP_UNIT_OBJDIR) -o tb

tsp-tile:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_tile.sh
tsp-tile-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_tile.sh --mutants
tsp-tile-full:
	+@MAKE="$(MAKE)" SAMPLE="$(SAMPLE)" bash tools/gate/gate_tsp_tile.sh --full

TSP_TILE_LINT = $(P2_LINT) tb/fp/fp_lint.vlt tb/isp_setup/isp_setup_lint.vlt tb/tsp_setup/tsp_setup_lint.vlt \
                tb/tsp_run/tsp_run_lint.vlt tb/tsp_tile/tsp_tile_lint.vlt
lint-units: lint-tsp-tile
lint-tsp-tile:
	@for t in p2_tex_coord p2_tex_addr p2_tex_cache p2_tex_pal p2_tex_decode p2_tex_filter p2_pp_shade p2_pp_fog p2_pp_ss \
	  p2_pp_blend p2_tsp_pp p2_tbuf; do \
	  $(TSP_TILE_LINT) --top-module $$t $(TSP_SETUP_LIB) $(TSP_TILE_SRC) || { echo "lint-tsp-tile: $$t FAILED"; exit 1; }; done
	@for t in p2_tsp_tile_tb_top p2_tsp_unit_tb_top; do \
	  $(TSP_TILE_LINT) --top-module $$t $(TSP_SETUP_LIB) $(TSP_TILE_SRC) $(TSP_TILE_TB_SRC) $(TSP_UNIT_TB_SRC) || \
	  { echo "lint-tsp-tile: $$t FAILED"; exit 1; }; done
	@echo "lint-tsp-tile: PASS"
