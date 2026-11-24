# frames.mk: M12, the frame testbench p2-offline (PLAN M12, 1.4; conventions.md 7.4): refsw3-offline's own sources (its
# main.cpp, refsw3-ta, pvr_mem, TexCache, threading, with its flags) without refsw_lists.cpp / refsw_tile.cpp, plus
# tb/frame/p2_rendercore.cpp and the Verilated p2_core.
#
#   make p2-offline          build/p2-offline/p2-offline (tools/p2-offline/build.sh builds it for dreamcast-tests' scripts)
#   make p2-offline-dual     build/p2-offline-dual/p2-offline: the L2 glue linked too, RenderCORE_sw on a copy first, the
#                            first differing word reported (tb/frame/p2_rendercore.cpp)
#   make frames              the M12 frame gate (tools/gate/gate_frames_off.sh --subset): every word of video memory after
#                            every render against refsw3-offline on tb/frames/subset_*.txt, VRAM-race renders apart, also
#                            under +vramvary and at VR_LAT 1 and 16; "frames: PASS" last
#   make frames-mutants      PLAN M12's mutants through the frame gate's probes (tb/frames/mutants*.txt)
#
# Overridable: FRAME_DIR (the folder p2_rendercore.cpp is compiled from), P2OFF_OBJDIR, P2OFF_DUAL_OBJDIR (mutants.py).
FRAME_DIR         ?= tb/frame
P2OFF_OBJDIR      ?= $(BUILD)/p2-offline
P2OFF_DUAL_OBJDIR ?= $(BUILD)/p2-offline-dual
P2OFF_LIBDIR       = $(BUILD)/p2-offline/lib
# refsw3-offline's flags without the glue's RenderCORE rename: main.cpp calls refcore::RenderCORE, which is ours
P2OFF_CXXFLAGS     = $(REFOFF_FLAGS) $(REFOFF_INC) $(REFOFF_DEF)
P2OFF_SUP_OBJ      = $(P2OFF_LIBDIR)/main.o $(P2OFF_LIBDIR)/refta.o $(REFGLUE_SUP_OBJ)
P2OFF_DUAL_GLUE    = $(REFGLUE_LIBDIR)/refcore_glue.o $(REFGLUE_LIBDIR)/refcore_glue_lists.o $(REFGLUE_LIBDIR)/refcore_bgkey.o
P2OFF_VCFLAGS      = -CFLAGS "-I$(CWD)/tb/common" -LDFLAGS "-lpthread -lz"

.PHONY: p2-offline p2-offline-dual p2-offline-probe frames frames-mutants

$(P2OFF_LIBDIR)/main.o: $(NULLDC3)/refsw3-offline/main.cpp $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2OFF_CXXFLAGS) -c $< -o $@
$(P2OFF_LIBDIR)/refta.o: $(REFTA)/refta.cpp $(wildcard $(REFTA)/*.h) $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2OFF_CXXFLAGS) -c $< -o $@

p2-offline: $(P2OFF_SUP_OBJ)
	@mkdir -p $(P2OFF_OBJDIR)
	@if [ -f $(P2OFF_OBJDIR)/p2-offline ] && [ -n "$$(find $(P2OFF_SUP_OBJ) -newer $(P2OFF_OBJDIR)/p2-offline)" ]; then \
	  rm -f $(P2OFF_OBJDIR)/p2-offline; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) $(P2OFF_VCFLAGS) --top-module p2_core \
	  $(P2_CORE_LIB) $(P2_CORE_SRC) $(CWD)/$(FRAME_DIR)/p2_rendercore.cpp \
	  $(addprefix $(CWD)/,$(P2OFF_SUP_OBJ)) --Mdir $(P2OFF_OBJDIR)/obj -o ../p2-offline

p2-offline-dual: $(P2OFF_SUP_OBJ) $(P2OFF_DUAL_GLUE)
	@mkdir -p $(P2OFF_DUAL_OBJDIR)
	@if [ -f $(P2OFF_DUAL_OBJDIR)/p2-offline ] && \
	  [ -n "$$(find $(P2OFF_SUP_OBJ) $(P2OFF_DUAL_GLUE) -newer $(P2OFF_DUAL_OBJDIR)/p2-offline)" ]; then \
	  rm -f $(P2OFF_DUAL_OBJDIR)/p2-offline; fi
	+$(VERILATOR) --cc --exe --build -O3 $(VFLAGS) $(P2_CC) -CFLAGS "-I$(CWD)/tb/common -DP2_DUAL" \
	  -LDFLAGS "-lpthread -lz" --top-module p2_core \
	  $(P2_CORE_LIB) $(P2_CORE_SRC) $(CWD)/$(FRAME_DIR)/p2_rendercore.cpp \
	  $(addprefix $(CWD)/,$(P2OFF_SUP_OBJ) $(P2OFF_DUAL_GLUE)) --Mdir $(P2OFF_DUAL_OBJDIR)/obj -o ../p2-offline

# the frame gate's mutant probe beside p2-offline (tools/gate/frames_probe.sh)
p2-offline-probe: p2-offline
	@cp tools/gate/frames_probe.sh $(P2OFF_OBJDIR)/frames_probe

frames:
	+@MAKE="$(MAKE)" bash tools/gate/gate_frames_off.sh --subset
frames-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_frames_off.sh --mutants
