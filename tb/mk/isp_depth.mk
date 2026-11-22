# isp_depth.mk: M3, the ISP depth path (PLAN M3): rtl/v1/isp's depth units, the testbench tb/isp_depth in lockstep with
# refsw3 (L1 headers: pvrisp::DepthTileT<DepthHW>::Setup / At, StoredDepth; the verbatim copy of the plane setup in
# tb/isp_depth/ref_copies_depth.h), the archived zmeas and covmeas zprobe sets, the console pages' primitives.
#
#   make isp-depth          the M3 gate (tools/gate/gate_isp_depth.sh): hw-pkg-check, check_ref_copies (the depth copy),
#                           check_ref_switches, tria_extract (build/vec: .tri and the depth records .trz), the build,
#                           lint-isp-depth, then the testbench in quick mode; "isp-depth: PASS" last;
#                           build/gate/isp-depth/summary.txt
#   make isp-depth-full     the same with the testbench's full sweeps (--full), sharded ISP_DEPTH_SHARDS ways
#   make isp-depth-mutants  every mutant of tb/isp_depth/mutants*.txt caught, the control passing (tools/gate/mutants.py)
#   make isp-depth-tb       the testbench alone, quick (build/obj_isp_depth/tb); isp-depth-build the build only
#   make isp-depth-vec      tools/gate/tria_extract.sh on the M3 tests (pvr-tests depthgaps_*, zovf*, nantr_*, perpmean_*,
#                           zword, zbad*, zspec, zsign, bg*, depth2_*, trsort_*)
#   make lint-isp-depth     verilator -Wall on the depth units and the tb top (a prerequisite of make lint)
#
# Overridable: ISP_DIR (the RTL folder; tools/gate/mutants.py points it at a mutated copy), ISP_DEPTH_OBJDIR,
# ISP_DEPTH_SHARDS.
ISP_DEPTH_OBJDIR  ?= $(BUILD)/obj_isp_depth
ISP_DEPTH_SHARDS  ?= 12
# the depth units (the edge units in the same folder are not compiled into this testbench)
ISP_DEPTH_SRC      = $(sort $(wildcard $(ISP_DIR)/p2_isp_depth_*.sv)) $(ISP_DIR)/p2_isp_zadd.sv $(ISP_DIR)/p2_isp_zmul.sv
ISP_DEPTH_LIB      = $(FP_PKG_SRC) rtl/v1/pkg/p2_hw_check.sv $(FP_SRC)
ISP_DEPTH_TB_SRC   = tb/isp_depth/p2_isp_depth_tb_top.sv
ISP_DEPTH_CFLAGS   = -CFLAGS "-I$(REFCORE) -I$(CWD)/tb/common -I$(CWD)/tb/isp_depth -I$(CWD)/tb/isp_edge -I$(CWD)/tools/gate" \
                     -LDFLAGS "-lz"
ISP_DEPTH_TESTS    = $(sort $(filter depthgaps_% zovf% nantr_% perpmean_% zword zbad% zspec zsign bg% depth2_% trsort_%,\
                     $(notdir $(wildcard $(DCTESTS)/pvr-tests/*))))

.PHONY: isp-depth isp-depth-full isp-depth-mutants isp-depth-tb isp-depth-build isp-depth-vec lint-isp-depth

isp-depth-build:
	@mkdir -p $(ISP_DEPTH_OBJDIR)
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(ISP_DEPTH_CFLAGS) --top-module p2_isp_depth_tb_top \
	  $(ISP_DEPTH_LIB) $(ISP_DEPTH_SRC) $(ISP_DEPTH_TB_SRC) $(CWD)/tb/isp_depth/isp_depth_tb.cpp \
	  --Mdir $(ISP_DEPTH_OBJDIR) -o tb

isp-depth-tb: isp-depth-build
	$(ISP_DEPTH_OBJDIR)/tb

# (tb/mk/isp_edge.mk defines TRIA_CONV and its rule; this fragment is read first, so the path is spelled out)
isp-depth-vec: refsw3-offline $(BUILD)/tools/tria_conv
	@bash tools/gate/tria_extract.sh -j $(P2_J) $(ISP_DEPTH_TESTS)

isp-depth:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_depth.sh
isp-depth-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_depth.sh --full
isp-depth-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_isp_depth.sh --mutants

ISP_DEPTH_LINT = $(P2_LINT) tb/isp_depth/isp_depth_lint.vlt
lint-units: lint-isp-depth
lint-isp-depth:
	@for t in p2_isp_depth_setup p2_isp_depth_raster; do \
	  $(ISP_DEPTH_LINT) --top-module $$t $(FP_PKG_SRC) $(FP_SRC) $(ISP_DEPTH_SRC) || { echo "lint-isp-depth: $$t FAILED"; exit 1; }; done
	@$(ISP_DEPTH_LINT) --top-module p2_isp_depth_tb_top $(ISP_DEPTH_LIB) $(ISP_DEPTH_SRC) $(ISP_DEPTH_TB_SRC) || \
	  { echo "lint-isp-depth: p2_isp_depth_tb_top FAILED"; exit 1; }
	@echo "lint-isp-depth: PASS"
