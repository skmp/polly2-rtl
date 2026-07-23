# refsw2 ISP/TSP core - simulation build
#
#   make test          - fast unit tests: TSP texture blocks + front-end blocks
#   make tex           - TSP texture-pipeline block tests (randomized vs refsw):
#                        tex-addr / tex-uv / tex-filter / tex-combiner
#   make frontendtsplp - front-end + ISP + TSP + layer peeling -> shaded_lp_<name>.bmp
#   make spannerv2     - spanner_v2 standalone replay vs C++ golden
#   make regen         - regenerate PVR register typedefs from minicast's pvr_regs.h
#   make clean
#
# NOTE: the legacy combinational/sequenced setup design (sim/seq/ip/quartus/fp)
# and superseded integration TBs were retired in the rtl/ reorg; their sources
# now live in ../_unused/.

VERILATOR ?= verilator

# Parallel build by default. NJOBS = host CPU count (fallback 4). It drives:
#   - MAKEFLAGS: any `make` (recursive or multi-target) fans out
#   - Verilator's --build-jobs / -j: parallel model codegen + C++ compile
NJOBS    := $(shell nproc 2>/dev/null || echo 4)
MAKEFLAGS += -j$(NJOBS)

# NOTE: --threads was tried but SLOWED this design down: the testbenches are
# dominated by one large sequential FSM `always` block, so Verilator can't find
# enough independent dataflow to parallelize, and per-cycle thread-sync overhead
# dominates. Left single-threaded. To parallelize, run independent scenes with
# `make -j` instead. (Set VTHREADS>1 to re-enable experimentally.)
VTHREADS ?= 1
VFLAGS    = -Wno-WIDTH -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-DECLFILENAME -Irtl/tsp/gen \
            -j $(NJOBS) $(if $(filter-out 1,$(VTHREADS)),--threads $(VTHREADS),) \
            --output-split 40000 --output-split-cfuncs 1000 \
            -CFLAGS "-O3 -march=native"

BUILD = build
CWD  := $(shell pwd)

.PHONY: raster-topleft clean test tex tex-addr tex-uv tex-filter tex-combiner \
        oparse region regfile regen sortcache itquad taginvw dense_span_buffer \
        frontendtsplp spannerv2 mulc9 mul16sppro add24sppro mulc9sppro add3sppro \
        mul24sppro mul24c9sppro

# TSP module files (package first). ISP shared FP units come from rtl/isp_min.
TSP_RTL = rtl/tsp/tsp_pkg.sv $(filter-out rtl/tsp/tsp_pkg.sv,$(wildcard rtl/tsp/*.sv))

# --- reorganized core: RTL now lives in rtl/<subsystem>/ trees. --------------
# Package (must be listed, not just searched) + `-y` search dirs so Verilator
# auto-resolves every module by name from any subtree.
TSP_PKG   = rtl/gen/tsp_pkg.sv
RTL_DIRS  = rtl rtl/gen rtl/buffers rtl/fp rtl/isp \
            rtl/lists rtl/setup rtl/tsp rtl/tsp/tex rtl/spanner
# Files holding modules whose name != filename, so `-y` won't auto-find them:
#   fp_add24.sv    -> fp_add24_s1 / fp_add24_s2
#   stage_interp.sv-> interp_unit
RTL_EXTRA = rtl/fp/fp_add24.sv rtl/tsp/stage_interp.sv
RTL_INC   = $(addprefix -y ,$(RTL_DIRS)) -Irtl/gen

# ---- run the fast unit tests (TSP texture blocks + front-end block tests) ----
test: tex oparse region regfile sortcache itquad raster-topleft

# ---- top-left bias / exact-edge raster regression ----
# isp_setup_streamed + isp_raster_line on a coplanar fullscreen quad whose
# shared diagonal passes exactly through tile origins (C = +0): per-pixel
# coverage vs a refsw2-rule model + corner-probe sanity. Guards the raw
# C-1 bias wrap (+0 -> -NaN) that dropped whole tiles.
raster-topleft: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ -Wno-PINCONNECTEMPTY \
	  --top-module raster_topleft_tb_top $(RTL_INC) \
	  $(TSP_PKG) $(RTL_EXTRA) tb/raster_topleft_tb_top.sv \
	  $(CWD)/tb/raster_topleft_tb.cpp \
	  --Mdir $(BUILD)/obj_rastertl -o tb
	./$(BUILD)/obj_rastertl/tb

# ---- TSP texture-pipeline block tests (randomized vectors vs refsw) ----
TSP = rtl/tsp
tex: tex-addr tex-uv tex-filter tex-combiner
	@echo "=== all texture block tests passed ==="

tex-addr: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_addr \
	  $(TSP)/tex_addr.sv $(CWD)/tb/tex_addr_tb.cpp \
	  --Mdir $(BUILD)/obj_texaddr -o tb
	./$(BUILD)/obj_texaddr/tb

tex-uv: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_uvmap \
	  $(TSP)/tex_uvmap.sv $(CWD)/tb/tex_uvmap_tb.cpp \
	  --Mdir $(BUILD)/obj_texuv -o tb
	./$(BUILD)/obj_texuv/tb

tex-filter: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_filter \
	  $(TSP)/tex_filter.sv $(CWD)/tb/tex_filter_tb.cpp \
	  --Mdir $(BUILD)/obj_texfilt -o tb
	./$(BUILD)/obj_texfilt/tb

tex-combiner: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module color_combiner \
	  $(TSP)/color_combiner.sv $(CWD)/tb/tex_combiner_tb.cpp \
	  --Mdir $(BUILD)/obj_texcomb -o tb
	./$(BUILD)/obj_texcomb/tb

# object_list_parser unit test: list walker (direct-DDR reader) + behav burst DDR.
oparse: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module object_list_parser_tb_top \
	  $(TSP)/tsp_pkg.sv tb/object_list_parser_tb_top.sv $(TSP)/object_list_parser.sv \
	  $(CWD)/tb/object_list_parser_tb.cpp --Mdir $(BUILD)/obj_oparse -o tb
	./$(BUILD)/obj_oparse/tb

# sort_cache unit test: enter/demote/check semantics, same-cycle demote-wins
# priority, alias mismatch conservatism, reset sweep, random soak vs a C model.
sortcache: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module sort_cache \
	  rtl/tsp/sort_cache.sv \
	  $(CWD)/tb/sort_cache_tb.cpp --Mdir $(BUILD)/obj_sortcache -o tb
	./$(BUILD)/obj_sortcache/tb

# isp_primitive_iterator_pf quad unit test: ENT_QUAD / ENT_TRI / ENT_STRIP entries
# through a behavioral DDR; checks vertices, quad flag + v3x/v3y, and the tag
# param_offs advance (hdr + nverts*stride per array record).
itquad: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module isp_primitive_iterator_pf \
	  $(TSP)/tsp_pkg.sv $(TSP)/isp_primitive_iterator_pf.sv \
	  $(CWD)/tb/isp_primitive_iterator_quad_tb.cpp --Mdir $(BUILD)/obj_itquad -o tb
	./$(BUILD)/obj_itquad/tb

# regenerate the PVR register typedefs from minicast's pvr_regs.h
PVR_REGS_H = ../minicast/libswirl/hw/pvr/pvr_regs.h
regen:
	python3 tools/gen_pvr_regs.py $(PVR_REGS_H) > rtl/tsp/gen/pvr_regs_gen.svh
	@echo "regenerated rtl/tsp/gen/pvr_regs_gen.svh"

# taginvw_tile_buffer unit test: the split-out {valid,tag,invW} slice TSP reads. Exercises
# the 4-wide aligned read (rd4/g4) with FOUR DISTINCT per-lane tags + a moving-address
# streaming read + concurrent write/read, against the real M10K tile_ram. Self-checking.
taginvw: | $(BUILD)
	+$(VERILATOR) --binary $(VFLAGS) -Wno-BLKSEQ --top-module taginvw_selftest \
	  rtl/tsp/tsp_pkg.sv rtl/isp_min/tile_ram.sv rtl/buffers/taginvw_tile_buffer.sv \
	  tb/taginvw_selftest.sv --Mdir $(BUILD)/obj_taginvw -o taginvw
	./$(BUILD)/obj_taginvw/taginvw

# dense_span_buffer unit test: the DENSE spanner_v2->TSP handoff (one span/slot:
# {start,rep,id,invw[0:3],at}). Writes spans at dense slots, reads back + streaming read.
dense_span_buffer: | $(BUILD)
	+$(VERILATOR) --binary $(VFLAGS) -Wno-BLKSEQ --top-module dense_span_buffer_selftest \
	  rtl/tsp/dense_span_buffer.sv tb/dense_span_buffer_selftest.sv \
	  --Mdir $(BUILD)/obj_densespan -o densespan
	./$(BUILD)/obj_densespan/densespan

# front-end + ISP + TSP + LAYER PEELING: OP as before; PT/TR use the peel depth
# compare (isp_depth_cmp_lp) with dual depth/tag buffers + a per-pixel valid bit,
# re-running the object list per peel pass, and blending at the end of the TSP
# pipe -> shaded_lp_<name>.bmp.
frontendtsplp: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_tsp_lp_tb_top $(RTL_INC) \
	  $(TSP_PKG) $(RTL_EXTRA) tb/frontend_tsp_lp_tb_top.sv tb/sim_ddr_fb.sv \
	  $(CWD)/tb/frontend_tsp_lp_tb.cpp --Mdir $(BUILD)/obj_frontendtsplp -o tb
	./$(BUILD)/obj_frontendtsplp/tb $(DUMP)

# spanner_v2 standalone check: replays captured TSP-input vectors
# (spanner_test_vectors/spanner_input_<N>.txt + vram.bin) through spanner_v2 and
# compares span emission + triangle_setups writes against a C++ golden. ARGS lets you
# pass "<dir> <first> <count>" (default: spanner_test_vectors 0 8).
spannerv2: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module spanner_v2_tb_top \
	  $(TSP_RTL) tb/spanner_v2_tb_top.sv tb/sim_ddr_fb.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/spanner_v2_tb.cpp --Mdir $(BUILD)/obj_spannerv2 -o tb
	./$(BUILD)/obj_spannerv2/tb $(ARGS)

# fp_mul_c9 (colour*z) fuzz vs float*int
mulc9: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul_c9_tb_top \
	  rtl/tsp/fp_mul_c9.sv tb/fp_mul_c9_tb_top.sv \
	  $(CWD)/tb/fp_mul_c9_tb.cpp --Mdir $(BUILD)/obj_mulc9 -o tb
	./$(BUILD)/obj_mulc9/tb

# streaming registered-output FP units vs their combinational parents (BIT-EXACT).
# Each TB clocks the pipelined DUT + a combinational ref and checks 0-tolerance match.
mul16sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul16_spp_ro_tb_top \
	  rtl/isp_min/fp_mul16.sv rtl/isp_min/fp_mul16_spp_ro.sv tb/fp_mul16_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_mul16_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_mul16sppro -o tb
	./$(BUILD)/obj_mul16sppro/tb

add24sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_add24_spp_ro_tb_top \
	  rtl/isp_min/fp_add24.sv rtl/isp_min/fp_add24_spp_ro.sv tb/fp_add24_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_add24_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_add24sppro -o tb
	./$(BUILD)/obj_add24sppro/tb

mulc9sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul_c9_spp_ro_tb_top \
	  rtl/tsp/fp_mul_c9.sv rtl/tsp/fp_mul_c9_spp_ro.sv tb/fp_mul_c9_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_mul_c9_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_mulc9sppro -o tb
	./$(BUILD)/obj_mulc9sppro/tb

add3sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_add3_24_spp_ro_tb_top \
	  rtl/isp_min/fp_add3_24.sv rtl/isp_min/fp_add3_24_spp_ro.sv tb/fp_add3_24_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_add3_24_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_add3sppro -o tb
	./$(BUILD)/obj_add3sppro/tb

# full-mantissa (1.23) streaming muls: pipelined DUT vs combinational parent
# (BIT-EXACT), AND the parent vs an independent C model in the same run.
mul24sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul24_spp_ro_tb_top \
	  rtl/fp/fp_mul24.sv rtl/fp/fp_mul24_spp_ro.sv tb/fp_mul24_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_mul24_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_mul24sppro -o tb
	./$(BUILD)/obj_mul24sppro/tb

mul24c9sppro: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul24_c9_spp_ro_tb_top \
	  rtl/fp/fp_mul24_c9.sv rtl/fp/fp_mul24_c9_spp_ro.sv tb/fp_mul24_c9_spp_ro_tb_top.sv \
	  $(CWD)/tb/fp_mul24_c9_spp_ro_tb.cpp -CFLAGS -I$(CWD)/tb --Mdir $(BUILD)/obj_mul24c9sppro -o tb
	./$(BUILD)/obj_mul24c9sppro/tb

# reg_file unit test: PVR scalar regs (generated) + FOG/PAL M10K tables.
regfile: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw -Irtl/tsp/gen \
	  --top-module reg_file_tb_top \
	  $(TSP)/tsp_pkg.sv tb/reg_file_tb_top.sv $(TSP)/reg_file.sv \
	  $(CWD)/tb/reg_file_tb.cpp --Mdir $(BUILD)/obj_regfile -o tb
	./$(BUILD)/obj_regfile/tb

# region_array_parser unit test: region walk -> per-tile ordered states.
region: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) $(RTL_INC) --public-flat-rw --top-module region_array_parser_tb_top \
	  $(TSP_PKG) tb/region_array_parser_tb_top.sv rtl/lists/region_array_parser.sv \
	  $(CWD)/tb/region_array_parser_tb.cpp --Mdir $(BUILD)/obj_region -o tb
	./$(BUILD)/obj_region/tb

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
