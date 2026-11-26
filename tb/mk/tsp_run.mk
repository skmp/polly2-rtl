# tsp_run.mk: M10, run start and pixel values (PLAN M10; ARCHITECTURE 3.7.5-3.7.7): p2_tsp_rstart, p2_pxq, the pixel pipe's
# P0-P3 (p2_pp_issue, p2_pp_plane, p2_pp_div, p2_pp_col, p2_pp_mip) behind M9's store, fetch, setup and ALU; the testbench
# tb/tsp_run against refsw3's PlaneT::Value, Divide, InterpolateBase / InterpolateOffs (ColorRounded), MipSelect and the
# copy of mipChoose (tb/tsp_run/ref_copies_run.h), and dreamcast-tests' archived console sets (tb/tsp_run/tsp_sets.h).
#
#   make tsp-run            the M10 gate (tools/gate/gate_tsp_run.sh): hw-pkg-check, check_ref_copies, check_ref_switches,
#                           the builds, then on one queue lint-tsp-run and the testbench's sections in slices: random
#                           (2M pixels), super (SupSample points), console (every set; uvmeas and mipmeas every 8th run,
#                           the rest every reading); "tsp-run: PASS" last; build/gate/tsp-run/summary.txt
#   make tsp-run-mutants    the M10 mutants (tb/tsp_run/mutants.txt)
#   make tsp-run-full       every reading of every console set (uvmeas 24.7M, mipmeas 12.5M), as a seeded sample with
#                           SAMPLE=<seed> (PLAN 0 rule 10; tools/gate/sample_items.py), exhaustively without
#   make tsp-run-build      build/obj_tsp_run/tb;  make lint-tsp-run  verilator -Wall on the units and the tb top
#
# Overridable: TSP_DIR (the RTL folder: tools/gate/mutants.py points it at a mutated copy), TSP_RUN_OBJDIR.
TSP_RUN_OBJDIR   ?= $(BUILD)/obj_tsp_run
# M11: the whole pixel pipe (p2_tsp_pp, P0 - P11: the texture units of rtl/v1/tex, the shade, fog, SupSample and blend
# stages) and the tile buffers (rtl/v1/tbuf); TEX_DIR and TBUF_DIR are overridable as TSP_DIR (tools/gate/mutants.py)
TEX_DIR          ?= $(RTLV1)/tex
TBUF_DIR         ?= $(RTLV1)/tbuf
TSP_PP_SRC        = $(TSP_DIR)/p2_pp_issue.sv $(TSP_DIR)/p2_pp_plane.sv $(TSP_DIR)/p2_pp_div.sv $(TSP_DIR)/p2_pp_col.sv \
                    $(TSP_DIR)/p2_pp_mip.sv $(TEX_DIR)/p2_tex_coord.sv $(TEX_DIR)/p2_tex_addr.sv $(TEX_DIR)/p2_tex_cache.sv \
                    $(TEX_DIR)/p2_tex_pal.sv $(TEX_DIR)/p2_tex_decode.sv $(TEX_DIR)/p2_tex_filter.sv \
                    $(TSP_DIR)/p2_pp_shade.sv $(TSP_DIR)/p2_pp_fog.sv $(TSP_DIR)/p2_pp_ss.sv $(TSP_DIR)/p2_pp_blend.sv \
                    $(TSP_DIR)/p2_tsp_pp.sv $(TBUF_DIR)/p2_tbuf.sv
TSP_RUN_SRC       = $(TSP_SETUP_SRC) $(TSP_DIR)/p2_tsp_rstart.sv $(TSP_DIR)/p2_pxq.sv $(TSP_PP_SRC)
TSP_RUN_TB_SRC    = tb/tsp_run/p2_tsp_run_tb_top.sv
TSP_RUN_REFOBJ    = $(BUILD)/tsp_run/tsp_run_ref.o $(REFGLUE_OBJS)
TSP_RUN_CFLAGS    = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/tsp_setup -I$(CWD)/tb/tsp_run -I$(CWD)/tools/gate" \
                    -LDFLAGS "-lpthread -lz"

.PHONY: tsp-run tsp-run-mutants tsp-run-full tsp-run-build lint-tsp-run

$(BUILD)/tsp_run/tsp_run_ref.o: tb/tsp_run/tsp_run_ref.cpp tb/tsp_run/tsp_run_ref.h tb/ref/p2ref.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/tsp_run -c $< -o $@

tsp-run-build: $(TSP_RUN_REFOBJ)
	@mkdir -p $(TSP_RUN_OBJDIR)
	@# Verilator's own make does not relink when only an object of ours changed
	@if [ -f $(TSP_RUN_OBJDIR)/tb ] && [ -n "$$(find $(TSP_RUN_REFOBJ) -newer $(TSP_RUN_OBJDIR)/tb)" ]; then \
	  rm -f $(TSP_RUN_OBJDIR)/tb; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(TSP_RUN_CFLAGS) --top-module p2_tsp_run_tb_top \
	  $(TSP_SETUP_LIB) $(TSP_RUN_SRC) $(TSP_RUN_TB_SRC) $(CWD)/tb/tsp_run/tsp_run_tb.cpp \
	  $(addprefix $(CWD)/,$(TSP_RUN_REFOBJ)) --Mdir $(TSP_RUN_OBJDIR) -o tb

tsp-run:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_run.sh
tsp-run-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_tsp_run.sh --mutants
tsp-run-full:
	+@MAKE="$(MAKE)" SAMPLE="$(SAMPLE)" bash tools/gate/gate_tsp_run.sh --full

TSP_RUN_LINT = $(P2_LINT) tb/fp/fp_lint.vlt tb/isp_setup/isp_setup_lint.vlt tb/tsp_setup/tsp_setup_lint.vlt tb/tsp_run/tsp_run_lint.vlt \
               tb/tsp_tile/tsp_tile_lint.vlt
lint-units: lint-tsp-run
lint-tsp-run:
	@for t in p2_tsp_rstart p2_pxq p2_pp_issue p2_pp_plane p2_pp_div p2_pp_col p2_pp_mip; do \
	  $(TSP_RUN_LINT) --top-module $$t $(TSP_SETUP_LIB) $(TSP_RUN_SRC) || { echo "lint-tsp-run: $$t FAILED"; exit 1; }; done
	@$(TSP_RUN_LINT) --top-module p2_tsp_run_tb_top $(TSP_SETUP_LIB) $(TSP_RUN_SRC) $(TSP_RUN_TB_SRC) || \
	  { echo "lint-tsp-run: p2_tsp_run_tb_top FAILED"; exit 1; }
	@echo "lint-tsp-run: PASS"
