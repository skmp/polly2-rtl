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

# NOTE: --threads was tried but SLOWED this design down: the testbenches are
# dominated by one large sequential FSM `always` block, so Verilator can't find
# enough independent dataflow to parallelize, and per-cycle thread-sync overhead
# dominates. Left single-threaded. To parallelize, run independent scenes with
# `make -j` instead. (Set VTHREADS>1 to re-enable experimentally.)
VTHREADS ?= 1
VFLAGS    = -Wno-WIDTH -Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-DECLFILENAME -Irtl/tsp/gen \
            -j $(NJOBS) $(if $(filter-out 1,$(VTHREADS)),--threads $(VTHREADS),) \
            --output-split 40000 --output-split-cfuncs 20000 \
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
        test tex tex-addr tex-uv tex-filter tex-combiner tex-fetch pipe oparse isprim region regfile regen planecache setupstream

# TSP module files (package first). ISP shared FP units come from rtl/isp_min.
TSP_RTL = rtl/tsp/tsp_pkg.sv $(filter-out rtl/tsp/tsp_pkg.sv,$(wildcard rtl/tsp/*.sv))

all: fp sim-tri sim-quad seq-tri seq-quad ip-tri ip-quad

# ---- run the fast unit tests (FP prims + TSP texture blocks + full pipeline) ----
test: fp tex oparse isprim region regfile setupstream pipe

# ---- TSP texture-pipeline block tests (randomized vectors vs refsw) ----
TSP = rtl/tsp
tex: tex-addr tex-uv tex-filter tex-combiner tex-fetch
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

# ---- LEGACY full TSP shading pipeline co-sim (legacy/tile_engine_top) ----
# Drives regs -> ISP_SETUP -> ISP_RASTERIZE -> TSP_SETUP -> TSP_SHADE and checks
# the shaded colour buffer vs a refsw-equivalent model. tile_engine_top is the
# superseded host-sequenced top (now in legacy/); peel_core/isp_core are current.
DDRSTUB = tb/ddram_stub.sv tb/sysmem_stub.sv
pipe: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-PINCONNECTEMPTY -Wno-PINMISSING --public-flat-rw \
	  --top-module tile_engine_top \
	  $(TSP_RTL) legacy/tile_engine_top.sv $(wildcard rtl/isp_min/*.sv) $(DDRSTUB) \
	  $(CWD)/legacy/tsp_pipe_tb.cpp --Mdir $(BUILD)/obj_pipe -o tb
	./$(BUILD)/obj_pipe/tb

# object_list_parser unit test: list walker (direct-DDR reader) + behav burst DDR.
oparse: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module object_list_parser_tb_top \
	  $(TSP)/tsp_pkg.sv tb/object_list_parser_tb_top.sv $(TSP)/object_list_parser.sv \
	  $(CWD)/tb/object_list_parser_tb.cpp --Mdir $(BUILD)/obj_oparse -o tb
	./$(BUILD)/obj_oparse/tb

# isp_setup_streamed unit test: 4-way interleaved setup vs isp_setup_min reference,
# bit-exact per triangle. Confirms the interleave timing (lane/slot alignment).
setupstream: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module isp_setup_streamed_tb_top \
	  tb/isp_setup_streamed_tb_top.sv \
	  rtl/isp_min/isp_setup_min.sv rtl/isp_min/isp_setup_streamed.sv \
	  rtl/isp_min/mac16.sv rtl/isp_min/fp_mul16.sv rtl/isp_min/fp_add24.sv rtl/isp_min/fp_rcp_fast.sv \
	  $(CWD)/tb/isp_setup_streamed_tb.cpp --Mdir $(BUILD)/obj_setupstream -o tb
	./$(BUILD)/obj_setupstream/tb

# regenerate the PVR register typedefs from minicast's pvr_regs.h
PVR_REGS_H = ../minicast/libswirl/hw/pvr/pvr_regs.h
regen:
	python3 tools/gen_pvr_regs.py $(PVR_REGS_H) > rtl/tsp/gen/pvr_regs_gen.svh
	@echo "regenerated rtl/tsp/gen/pvr_regs_gen.svh"

# front-end integration run: reg_file + 8MB VRAM + RA/OL/tristrip + faux ISP,
# driven from real PVR dumps (dumps/pvr_regs_menu.bin, dumps/vram_menu.bin).
frontend: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_tb_top \
	  $(TSP)/tsp_pkg.sv tb/frontend_tb_top.sv \
	  $(TSP)/reg_file.sv $(TSP)/region_array_parser.sv $(TSP)/object_list_parser.sv \
	  $(TSP)/isp_primitive_iterator.sv \
	  $(CWD)/tb/frontend_tb.cpp --Mdir $(BUILD)/obj_frontend -o tb
	./$(BUILD)/obj_frontend/tb

# front-end + real ISP integration: isp_core (region/objlist walk + isp_setup_min
# + isp_raster_line + depth/tag compare) driven through the shared sim backend
# (sim_ddr_fb); tile FLUSH -> 640x480 fb (CoreTags) -> output.bmp.
frontendisp: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_isp_tb_top \
	  $(TSP_RTL) tb/frontend_isp_tb_top.sv tb/sim_ddr_fb.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/frontend_isp_tb.cpp --Mdir $(BUILD)/obj_frontendisp -o tb
	./$(BUILD)/obj_frontendisp/tb $(DUMP)

# front-end + ISP + TSP: tile flush shades every pixel through a tag-keyed TSP
# plane cache (param fetch + tsp_setup_min) and tsp_shade -> shaded_<name>.bmp.
frontendtsp: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module frontend_tsp_tb_top \
	  $(TSP_RTL) tb/frontend_tsp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/frontend_tsp_tb.cpp --Mdir $(BUILD)/obj_frontendtsp -o tb
	./$(BUILD)/obj_frontendtsp/tb $(DUMP)

# taginvw_tile_buffer unit test: the split-out {valid,tag,invW} slice TSP reads. Exercises
# the 4-wide aligned read (rd4/g4) with FOUR DISTINCT per-lane tags + a moving-address
# streaming read + concurrent write/read, against the real M10K tile_ram. Self-checking.
taginvw: | $(BUILD)
	+$(VERILATOR) --binary $(VFLAGS) -Wno-BLKSEQ --top-module taginvw_selftest \
	  rtl/tsp/tsp_pkg.sv rtl/isp_min/tile_ram.sv rtl/tsp/taginvw_tile_buffer.sv \
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
	  --top-module frontend_tsp_lp_tb_top \
	  $(TSP_RTL) tb/frontend_tsp_lp_tb_top.sv tb/sim_ddr_fb.sv \
	  $(wildcard rtl/isp_min/*.sv) \
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

# front-end + ISP + TSP, TRIPLE-BUFFERED: 3 concurrent tile stages (ISP / TSP /
# writeout) on rotating buffers -> shaded_pp_<name>.bmp.
frontendtsppp: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ -Wno-MULTIDRIVEN --public-flat-rw \
	  --top-module frontend_tsp_pp_tb_top \
	  $(TSP_RTL) tb/frontend_tsp_pp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/frontend_tsp_pp_tb.cpp --Mdir $(BUILD)/obj_frontendtsppp -o tb
	./$(BUILD)/obj_frontendtsppp/tb $(DUMP)

# tsp_shade_pp: fully-pipelined shader, verified bit-equal vs serial tsp_shade.
tspshadepp: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module tsp_shade_pp_tb_top \
	  $(TSP_RTL) tb/tsp_shade_pp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/tsp_shade_pp_tb.cpp --Mdir $(BUILD)/obj_tspshadepp -o tb
	./$(BUILD)/obj_tspshadepp/tb

# tsp_shade_pp REPLAY: feed the exact recorded per-pixel shade input stream (shade_pp_
# input.log from peel_core +shadedump) through serial vs pipelined over REAL scene VRAM.
# Isolates shade/cache-path bugs on genuine data. Args: LOG=<input.log> VRAMBIN=<vram.bin>
LOG      ?= shade_pp_input.log
VRAMBIN  ?= dumps/vram_menu2.bin
tspshadereplay: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module tsp_shade_pp_tb_top \
	  $(TSP_RTL) tb/tsp_shade_pp_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/tsp_shade_pp_replay_tb.cpp --Mdir $(BUILD)/obj_tspshadereplay -o tb
	./$(BUILD)/obj_tspshadereplay/tb $(LOG) $(VRAMBIN)

# streamed rasterizer consume-path equivalence vs serial (bit-exact tile diff).
rasterstream: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw \
	  --top-module isp_raster_stream_tb_top \
	  $(TSP)/tsp_pkg.sv tb/isp_raster_stream_tb_top.sv \
	  $(wildcard rtl/isp_min/*.sv) \
	  $(CWD)/tb/isp_raster_stream_tb.cpp --Mdir $(BUILD)/obj_rasterstream -o tb
	./$(BUILD)/obj_rasterstream/tb

# fp_mul_c9 (colour*z) fuzz vs float*int
mulc9: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_mul_c9_tb_top \
	  rtl/tsp/fp_mul_c9.sv tb/fp_mul_c9_tb_top.sv \
	  $(CWD)/tb/fp_mul_c9_tb.cpp --Mdir $(BUILD)/obj_mulc9 -o tb
	./$(BUILD)/obj_mulc9/tb

# reg_file unit test: PVR scalar regs (generated) + FOG/PAL M10K tables.
regfile: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -Wno-BLKSEQ --public-flat-rw -Irtl/tsp/gen \
	  --top-module reg_file_tb_top \
	  $(TSP)/tsp_pkg.sv tb/reg_file_tb_top.sv $(TSP)/reg_file.sv \
	  $(CWD)/tb/reg_file_tb.cpp --Mdir $(BUILD)/obj_regfile -o tb
	./$(BUILD)/obj_regfile/tb

# region_array_parser unit test: region walk -> per-tile ordered states.
region: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module region_array_parser_tb_top \
	  $(TSP)/tsp_pkg.sv tb/region_array_parser_tb_top.sv $(TSP)/region_array_parser.sv \
	  $(CWD)/tb/region_array_parser_tb.cpp --Mdir $(BUILD)/obj_region -o tb
	./$(BUILD)/obj_region/tb

# isp_primitive_iterator unit test: strip + tri-array iterator (XYZ only).
isprim: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module isp_primitive_iterator_tb_top \
	  $(TSP)/tsp_pkg.sv tb/isp_primitive_iterator_tb_top.sv $(TSP)/isp_primitive_iterator.sv \
	  $(CWD)/tb/isp_primitive_iterator_tb.cpp --Mdir $(BUILD)/obj_isprim -o tb
	./$(BUILD)/obj_isprim/tb

# tex_fetch integrated test: tex_fetch + 2 injected caches + behavioural DDR.
tex-fetch: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --public-flat-rw --top-module texfetch_tb_top \
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
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fp_prims \
	  -Irtl tb/fp_prims.sv $(CWD)/tb/fp_prims_tb.cpp \
	  --Mdir $(BUILD)/obj_fpprims -o fp_prims_tb
	./$(BUILD)/obj_fpprims/fp_prims_tb

# ---- FIFO unit tests (randomized push/pop vs reference queue model) ----
fifo_pq: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fifo_pq \
	  rtl/tsp/fifo_pq.sv $(CWD)/tb/fifo_pq_tb.cpp \
	  --Mdir $(BUILD)/obj_fifopq -o fifo_pq_tb
	./$(BUILD)/obj_fifopq/fifo_pq_tb
fifo_fq: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fifo_fq \
	  rtl/tsp/fifo_fq.sv $(CWD)/tb/fifo_fq_tb.cpp \
	  --Mdir $(BUILD)/obj_fifofq -o fifo_fq_tb
	./$(BUILD)/obj_fifofq/fifo_fq_tb
fifo_eq: | $(BUILD)
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module fifo_eq \
	  rtl/tsp/fifo_eq.sv $(CWD)/tb/fifo_eq_tb.cpp \
	  --Mdir $(BUILD)/obj_fifoeq -o fifo_eq_tb
	./$(BUILD)/obj_fifoeq/fifo_eq_tb
fifos: fifo_pq fifo_fq fifo_eq

# ---- combinational setup TB (bit-exact) ----
sim: vectors
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tri_setup_top \
	  -CFLAGS "-I$(CWD)/build" \
	  -Irtl $(RTL_COMB) $(CWD)/tb/tri_setup_tb.cpp \
	  --Mdir $(BUILD)/obj_setup -o tri_setup_tb
	cd $(CWD) && ./$(BUILD)/obj_setup/tri_setup_tb

sim-tri:  ; $(MAKE) sim MODE=tri
sim-quad: ; $(MAKE) sim MODE=quad

# ---- sequenced setup TB (one mul+add/unit, one reciprocal; ULP tolerance) ----
seq: vectors
	+$(VERILATOR) --cc --exe --build $(VFLAGS) --top-module tri_setup_seq_top \
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
	+$(VERILATOR) --cc --exe --build $(VFLAGS) -DSYNTHESIS -Wno-MULTITOP \
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
