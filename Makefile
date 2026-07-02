# refsw2 ISP/TSP triangle-setup core - simulation build
#
#   make vectors    - regenerate golden VRAM image + expected coefficients (MODE=tri|quad)
#   make fp         - FP-primitive fuzz test (add/mul/div vs host IEEE-754)
#   make sim        - COMBINATIONAL setup TB, bit-exact (uses MODE)
#   make sim-tri / sim-quad
#   make seq        - SEQUENCED (one mul+add/unit, one reciprocal) setup TB (behavioral FP)
#   make seq-tri / seq-quad
#   make ip         - sequenced design wired to Altera FP IP, run via IP stubs (uses MODE)
#   make ip-tri / ip-quad
#   make all        - fp + comb + sequenced + IP-path, tri & quad
#   make test       - fast unit tests: fp prims + TSP texture blocks + pipeline
#   make tex        - TSP texture-pipeline block tests (randomized vs refsw):
#                     tex-addr / tex-uv / tex-filter / tex-combiner / tex-fetch
#   make pipe       - full TSP shading pipeline co-sim (setup->raster->shade),
#                     VRAM-backed tex_mem, vs refsw model
#   make quartus    - synthesize the sequenced+IP design (needs Quartus on PATH)
#   make clean
#
# MODE selects the scene fed to gen_vectors (default: tri).

VERILATOR ?= verilator

# Parallel build by default. NJOBS = host CPU count (fallback 4). It drives:
#   - MAKEFLAGS: any `make` (recursive or multi-target) fans out
#   - Verilator's --build-jobs / -j: parallel model codegen + C++ compile
NJOBS    := $(shell nproc 2>/dev/null || echo 4)
MAKEFLAGS += -j$(NJOBS)

VFLAGS    = -Wno-WIDTH -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-DECLFILENAME -Irtl/tsp/gen \
            -j $(NJOBS) \
            -CFLAGS "-O3 -march=native"

# combinational (bit-exact) design
RTL_COMB  = rtl/fp_add.sv rtl/fp_mul.sv rtl/fp_div.sv \
            rtl/plane_stepper.sv rtl/u8_to_float.sv \
            rtl/isp_setup.sv rtl/tsp_setup.sv rtl/tri_setup_top.sv

# sequenced (area-optimized) design
RTL_SEQ   = rtl/fp_add.sv rtl/fp_mul.sv rtl/fp_div.sv \
            rtl/fp_mac.sv rtl/fp_recip.sv rtl/fmac_seq.sv rtl/u8_to_float.sv \
            rtl/isp_setup_seq.sv rtl/tsp_setup_seq.sv rtl/tri_setup_seq_top.sv

BUILD = build
CWD  := $(shell pwd)
MODE ?= tri
MODEARG = $(if $(filter quad,$(MODE)),quad,)

.PHONY: all vectors fp sim sim-tri sim-quad seq seq-tri seq-quad ip ip-tri ip-quad quartus clean \
        test tex tex-addr tex-uv tex-filter tex-combiner tex-fetch pipe dcache256 oparse isprim region regfile regen planecache

# TSP module files (package first). ISP shared FP units come from rtl/isp_min.
TSP_RTL = rtl/tsp/tsp_pkg.sv $(filter-out rtl/tsp/tsp_pkg.sv,$(wildcard rtl/tsp/*.sv))

all: fp sim-tri sim-quad seq-tri seq-quad ip-tri ip-quad

# ---- run the fast unit tests (FP prims + TSP texture blocks + full pipeline) ----
test: fp tex dcache256 oparse isprim region regfile pipe

# ---- TSP texture-pipeline block tests (randomized vectors vs refsw) ----
TSP = rtl/tsp
tex: tex-addr tex-uv tex-filter tex-combiner tex-fetch
	@echo "=== all texture block tests passed ==="

tex-addr: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_addr \
	  $(TSP)/tex_addr.sv $(CWD)/tb/tex_addr_tb.cpp \
	  --Mdir $(BUILD)/obj_texaddr -o tb
	./$(BUILD)/obj_texaddr/tb

tex-uv: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_uv2texel \
	  $(TSP)/tex_uv2texel.sv $(CWD)/tb/tex_uv2texel_tb.cpp \
	  --Mdir $(BUILD)/obj_texuv -o tb
	./$(BUILD)/obj_texuv/tb

tex-filter: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tex_filter \
	  $(TSP)/tex_filter.sv $(CWD)/tb/tex_filter_tb.cpp \
	  --Mdir $(BUILD)/obj_texfilt -o tb
	./$(BUILD)/obj_texfilt/tb

tex-combiner: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module color_combiner \
	  $(TSP)/color_combiner.sv $(CWD)/tb/tex_combiner_tb.cpp \
	  --Mdir $(BUILD)/obj_texcomb -o tb
	./$(BUILD)/obj_texcomb/tb

# ---- full TSP shading pipeline co-sim (tile_engine_top, VRAM-backed tex_mem) ----
# Drives regs -> ISP_SETUP -> ISP_RASTERIZE -> TSP_SETUP -> TSP_SHADE and checks
# the shaded colour buffer vs a refsw-equivalent model.
DDRSTUB = tb/ddram_stub.sv tb/sysmem_stub.sv
pipe: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-PINCONNECTEMPTY --public-flat-rw \
	  --top-module tile_engine_top \
	  $(TSP_RTL) rtl/tile_engine_top.sv $(wildcard rtl/isp_min/*.sv) $(DDRSTUB) \
	  $(CWD)/tb/tsp_pipe_tb.cpp --Mdir $(BUILD)/obj_pipe -o tb
	./$(BUILD)/obj_pipe/tb

# data_cache256 unit test: 256-bit line cache + behavioural 64-bit DDR.
dcache256: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module data_cache256_tb_top \
	  $(TSP)/tsp_pkg.sv tb/data_cache256_tb_top.sv $(TSP)/data_cache256.sv $(CWD)/tb/data_cache256_tb.cpp \
	  --Mdir $(BUILD)/obj_dcache256 -o tb
	./$(BUILD)/obj_dcache256/tb

# object_list_parser unit test: list walker + injected 256b data$ + behav DDR.
oparse: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module object_list_parser_tb_top \
	  $(TSP)/tsp_pkg.sv tb/object_list_parser_tb_top.sv $(TSP)/object_list_parser.sv $(TSP)/data_cache256.sv \
	  $(CWD)/tb/object_list_parser_tb.cpp --Mdir $(BUILD)/obj_oparse -o tb
	./$(BUILD)/obj_oparse/tb

# regenerate the PVR register typedefs from minicast's pvr_regs.h
PVR_REGS_H = ../minicast/libswirl/hw/pvr/pvr_regs.h
regen:
	python3 tools/gen_pvr_regs.py $(PVR_REGS_H) > rtl/tsp/gen/pvr_regs_gen.svh
	@echo "regenerated rtl/tsp/gen/pvr_regs_gen.svh"

# front-end integration run: reg_file + 8MB VRAM + RA/OL/tristrip + faux ISP,
# driven from real PVR dumps (dumps/pvr_regs_menu.bin, dumps/vram_menu.bin).
frontend: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_tb_top \
	  $(TSP)/tsp_pkg.sv tb/frontend_tb_top.sv \
	  $(TSP)/reg_file.sv $(TSP)/region_array_parser.sv $(TSP)/object_list_parser.sv \
	  $(TSP)/isp_primitive_iterator.sv $(TSP)/data_cache256.sv \
	  $(CWD)/tb/frontend_tb.cpp --Mdir $(BUILD)/obj_frontend -o tb
	./$(BUILD)/obj_frontend/tb

# front-end + real ISP integration: adds isp_setup_min + isp_raster_line +
# depth-test + CoreTag tag writes; tile FLUSH -> 640x480 fb -> output.bmp.
frontendisp: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_isp_tb_top \
	  $(TSP)/tsp_pkg.sv tb/frontend_isp_tb_top.sv \
	  $(TSP)/reg_file.sv $(TSP)/region_array_parser.sv $(TSP)/object_list_parser.sv \
	  $(TSP)/isp_primitive_iterator.sv $(TSP)/data_cache256.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/frontend_isp_tb.cpp --Mdir $(BUILD)/obj_frontendisp -o tb
	./$(BUILD)/obj_frontendisp/tb $(DUMP)

# front-end + ISP + TSP: tile flush shades every pixel through a tag-keyed TSP
# plane cache (param fetch + tsp_setup_min) and tsp_shade -> shaded_<name>.bmp.
frontendtsp: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_tsp_tb_top \
	  $(TSP_RTL) tb/frontend_tsp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/frontend_tsp_tb.cpp --Mdir $(BUILD)/obj_frontendtsp -o tb
	./$(BUILD)/obj_frontendtsp/tb $(DUMP)

# tsp_shade_pp: fully-pipelined shader, verified bit-equal vs serial tsp_shade.
tspshadepp: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module tsp_shade_pp_tb_top \
	  $(TSP_RTL) tb/tsp_shade_pp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/tsp_shade_pp_tb.cpp --Mdir $(BUILD)/obj_tspshadepp -o tb
	./$(BUILD)/obj_tspshadepp/tb

# streamed rasterizer consume-path equivalence vs serial (bit-exact tile diff).
rasterstream: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module isp_raster_stream_tb_top \
	  $(TSP)/tsp_pkg.sv tb/isp_raster_stream_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/isp_raster_stream_tb.cpp --Mdir $(BUILD)/obj_rasterstream -o tb
	./$(BUILD)/obj_rasterstream/tb

# fp_mul_c9 (colour*z) fuzz vs float*int
mulc9: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul_c9_tb_top \
	  rtl/tsp/fp_mul_c9.sv tb/fp_mul_c9_tb_top.sv \
	  $(CWD)/tb/fp_mul_c9_tb.cpp --Mdir $(BUILD)/obj_mulc9 -o tb
	./$(BUILD)/obj_mulc9/tb

# reg_file unit test: PVR scalar regs (generated) + FOG/PAL M10K tables.
regfile: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw -Irtl/tsp/gen \
	  --top-module reg_file_tb_top \
	  $(TSP)/tsp_pkg.sv tb/reg_file_tb_top.sv $(TSP)/reg_file.sv \
	  $(CWD)/tb/reg_file_tb.cpp --Mdir $(BUILD)/obj_regfile -o tb
	./$(BUILD)/obj_regfile/tb

# region_array_parser unit test: region walk -> per-tile ordered states.
region: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module region_array_parser_tb_top \
	  $(TSP)/tsp_pkg.sv tb/region_array_parser_tb_top.sv $(TSP)/region_array_parser.sv $(TSP)/data_cache256.sv \
	  $(CWD)/tb/region_array_parser_tb.cpp --Mdir $(BUILD)/obj_region -o tb
	./$(BUILD)/obj_region/tb

# isp_primitive_iterator unit test: strip + tri-array iterator (XYZ only).
isprim: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module isp_primitive_iterator_tb_top \
	  $(TSP)/tsp_pkg.sv tb/isp_primitive_iterator_tb_top.sv $(TSP)/isp_primitive_iterator.sv $(TSP)/data_cache256.sv \
	  $(CWD)/tb/isp_primitive_iterator_tb.cpp --Mdir $(BUILD)/obj_isprim -o tb
	./$(BUILD)/obj_isprim/tb

# tex_fetch integrated test: tex_fetch + 2 injected caches + behavioural DDR.
tex-fetch: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module texfetch_tb_top \
	  $(TSP)/tsp_pkg.sv tb/tex_fetch_tb_top.sv $(TSP)/tex_fetch.sv $(TSP)/tex_addr.sv \
	  $(TSP)/tex_decode.sv $(TSP)/tex_cache.sv $(CWD)/tb/tex_fetch_tb.cpp \
	  --Mdir $(BUILD)/obj_texfetch -o tb
	./$(BUILD)/obj_texfetch/tb

# ---- golden vectors ----
$(BUILD)/gen_vectors: sim/gen_vectors.c | $(BUILD)
	gcc -O2 -Wall -o $@ $< -lm

vectors: $(BUILD)/gen_vectors
	cd $(CWD) && ./$(BUILD)/gen_vectors $(MODEARG)

$(BUILD):
	mkdir -p $(BUILD)

# ---- FP primitive fuzz ----
fp: | $(BUILD)
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_prims \
	  -Irtl tb/fp_prims.sv $(CWD)/tb/fp_prims_tb.cpp \
	  --Mdir $(BUILD)/obj_fpprims -o fp_prims_tb
	./$(BUILD)/obj_fpprims/fp_prims_tb

# ---- combinational setup TB (bit-exact) ----
sim: vectors
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tri_setup_top \
	  -CFLAGS "-I$(CWD)/build" \
	  -Irtl $(RTL_COMB) $(CWD)/tb/tri_setup_tb.cpp \
	  --Mdir $(BUILD)/obj_setup -o tri_setup_tb
	cd $(CWD) && ./$(BUILD)/obj_setup/tri_setup_tb

sim-tri:  ; $(MAKE) sim MODE=tri
sim-quad: ; $(MAKE) sim MODE=quad

# ---- sequenced setup TB (one mul+add/unit, one reciprocal; ULP tolerance) ----
seq: vectors
	$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tri_setup_seq_top \
	  -CFLAGS "-I$(CWD)/build" \
	  -Irtl $(RTL_SEQ) $(CWD)/tb/tri_setup_seq_tb.cpp \
	  --Mdir $(BUILD)/obj_seqtop -o tri_setup_seq_tb
	cd $(CWD) && ./$(BUILD)/obj_seqtop/tri_setup_seq_tb

seq-tri:  ; $(MAKE) seq MODE=tri
seq-quad: ; $(MAKE) seq MODE=quad

# ---- IP-path test: sequenced design wired to the Altera FP IP, exercised in
# Verilator via behavioral stubs (tb/altera_fp_stubs.sv) that match the IP
# ports + latency. Defines SYNTHESIS (-> IP datapath) but NOT USE_MIF_ROM
# (-> $readmemh still loads the scene). Validates latency/valid alignment and
# the neg/sub sign handling of the IP wrappers; arithmetic is RNE here, the real
# IP rounds ties-away, hence the TB's ULP tolerance.
RTL_IP    = rtl/fp_add.sv rtl/fp_mul.sv rtl/fp_div.sv rtl/u8_to_float.sv \
            tb/altera_fp_stubs.sv rtl/fmac_seq.sv rtl/fp_recip.sv \
            rtl/isp_setup_seq.sv rtl/tsp_setup_seq.sv rtl/tri_setup_seq_top.sv
ip: vectors
	$(VERILATOR) --cc --exe --build $(VFLAGS) -DSYNTHESIS -Wno-MULTITOP \
	  --top-module tri_setup_seq_top -CFLAGS "-I$(CWD)/build" \
	  -Irtl $(RTL_IP) $(CWD)/tb/tri_setup_seq_tb.cpp \
	  --Mdir $(BUILD)/obj_ip -o tri_setup_ip_tb
	cd $(CWD) && ./$(BUILD)/obj_ip/tri_setup_ip_tb

ip-tri:  ; $(MAKE) ip MODE=tri
ip-quad: ; $(MAKE) ip MODE=quad

# ---- Quartus synthesis of the sequenced design (requires Quartus on PATH) ----
quartus: vectors
	@command -v quartus_map >/dev/null || { echo "Quartus not on PATH"; exit 1; }
	quartus_map simplex && quartus_fit simplex && quartus_sta simplex
	@echo "Reports in output_files/ (simplex.fit.rpt, simplex.sta.rpt)"

clean:
	rm -rf $(BUILD)
