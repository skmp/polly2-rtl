# refglue.mk: M5, the tile-harness infrastructure (PLAN M5, 1.1, 1.3): the L2 glue (tb/ref: refcore_glue.cpp,
# refcore_env.cpp, the p2ref API p2ref.h, the copies ref_copies.h), the phase driver (tb/ref/phase_driver.cpp), its
# self-test, the scene generator (tb/gen/scenegen.cpp) and the captures (tools/gate/capture_prerender.sh).
#
#   make refglue-selftest          the M5 gate (tools/gate/gate_refglue.sh): check_ref_copies, check_ref_switches, the
#                                  builds, the captures of the tile subset (tb/tile/subset_*.txt) and 200 scenegen seeds,
#                                  the phase driver against refsw3-offline's video memory after every render, every word;
#                                  refsw3_known.sh against the dreamcast-tests README's scores; the phase-driver mutants;
#                                  "refglue-selftest: PASS" last; build/gate/refglue-selftest/summary.txt
#   make refglue-selftest-full     the same on every test page, every dump and 5000 seeds (hours)
#   make refglue-mutants           the phase-driver mutants alone (tb/ref/mutants.txt)
#   make refglue-build             build/ref/refglue_selftest (the glue, the environment, the driver, the self-test)
#   make scenegen                  build/tools/scenegen
#
# The glue is compiled with refsw3-offline's own FLAGS / INC / DEF, parsed from its build.sh (Makefile REFOFF_*), plus
# -DRenderCORE=RenderCORE_sw (conventions.md 7.3): refcore's numbers are refsw3-offline's. The support objects are
# refsw3-offline's other sources (pvr_mem.cpp, TexCache.cpp, threading.cpp), built here with the same flags.
#
# Overridable: REFGLUE_DRV_DIR (the folder phase_driver.cpp and the self-test are compiled from; tools/gate/mutants.py
# points it at a mutated copy of tb/ref), REFGLUE_COMMON_DIR (where isp_live.h is taken from first: tb/ref/mutants_live.txt
# points it at a mutated copy of tb/common), REFGLUE_OBJDIR (where the self-test binary goes).
REFGLUE_DRV_DIR ?= tb/ref
REFGLUE_COMMON_DIR ?= tb/common
REFGLUE_OBJDIR  ?= $(BUILD)/ref
REFGLUE_LIBDIR   = $(BUILD)/ref/lib
P2REF_CXXFLAGS   = $(REFOFF_FLAGS) $(REFOFF_INC) $(REFOFF_DEF) -DRenderCORE=RenderCORE_sw -I$(REFCORE)
REFGLUE_SUPPORT  = $(NULLDC3)/libswirl/hw/pvr/pvr_mem.cpp $(NULLDC3)/libswirl/rend/TexCache.cpp \
                   $(NULLDC3)/libswirl/oslib/posix/threading.cpp
REFGLUE_SUP_OBJ  = $(addprefix $(REFGLUE_LIBDIR)/,$(notdir $(REFGLUE_SUPPORT:.cpp=.o)))
REFGLUE_REFDEPS  = $(wildcard $(REFCORE)/*.h $(REFCORE)/*.cpp) $(REFOFF_SH)
REFGLUE_OBJS     = $(REFGLUE_LIBDIR)/refcore_glue.o $(REFGLUE_LIBDIR)/refcore_glue_lists.o $(REFGLUE_LIBDIR)/refcore_bgkey.o \
                   $(REFGLUE_LIBDIR)/refcore_env.o $(REFGLUE_SUP_OBJ)
REFGLUE_BIN      = $(REFGLUE_OBJDIR)/refglue_selftest
SCENEGEN         = $(BUILD)/tools/scenegen

.PHONY: refglue-selftest refglue-selftest-full refglue-mutants refglue-build scenegen

$(REFGLUE_LIBDIR)/refcore_glue.o: tb/ref/refcore_glue.cpp tb/ref/p2ref.h tb/ref/ref_copies.h tb/fp/ref_copies.h \
                                  $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -c $< -o $@

$(REFGLUE_LIBDIR)/refcore_glue_lists.o: tb/ref/refcore_glue_lists.cpp tb/ref/p2ref.h tb/ref/ref_copies.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -c $< -o $@

# L1: the background key's copy (tb/fp/ref_copies.h fp-bgkey) beside no libswirl header
$(REFGLUE_LIBDIR)/refcore_bgkey.o: tb/ref/refcore_bgkey.cpp tb/fp/ref_copies.h $(wildcard $(REFCORE)/*.h)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(HOST_CXXFLAGS) -c $< -o $@

$(REFGLUE_LIBDIR)/refcore_env.o: tb/ref/refcore_env.cpp tb/ref/p2ref.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -c $< -o $@

$(REFGLUE_LIBDIR)/pvr_mem.o: $(NULLDC3)/libswirl/hw/pvr/pvr_mem.cpp $(REFOFF_SH)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -c $< -o $@
$(REFGLUE_LIBDIR)/TexCache.o: $(NULLDC3)/libswirl/rend/TexCache.cpp $(REFOFF_SH)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -c $< -o $@
$(REFGLUE_LIBDIR)/threading.o: $(NULLDC3)/libswirl/oslib/posix/threading.cpp $(REFOFF_SH)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -c $< -o $@

# the driver and the self-test: from REFGLUE_DRV_DIR (a mutant's copy of tb/ref), linked with the shared glue objects
REFGLUE_DRV_SRC = $(REFGLUE_DRV_DIR)/phase_driver.cpp $(REFGLUE_DRV_DIR)/refglue_selftest.cpp
$(REFGLUE_BIN): $(REFGLUE_DRV_SRC) $(wildcard $(REFGLUE_DRV_DIR)/*.h) $(REFGLUE_COMMON_DIR)/isp_live.h \
                tb/fp/ref_copies.h $(REFGLUE_OBJS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -I$(REFGLUE_DRV_DIR) -I$(REFGLUE_COMMON_DIR) $(REFGLUE_DRV_SRC) $(REFGLUE_OBJS) -lpthread -lz -o $@

refglue-build: $(REFGLUE_BIN)

$(SCENEGEN): tb/gen/scenegen.cpp tb/common/p2tb.h $(REFGLUE_REFDEPS)
	@mkdir -p $(dir $@)
	$(CXX) $(P2REF_CXXFLAGS) -Itb/ref -Itb/common $< $(REFGLUE_LIBDIR)/refcore_env.o $(REFGLUE_LIBDIR)/pvr_mem.o -lz -o $@
$(SCENEGEN): $(REFGLUE_LIBDIR)/refcore_env.o $(REFGLUE_LIBDIR)/pvr_mem.o
scenegen: $(SCENEGEN)

refglue-selftest:
	+@MAKE="$(MAKE)" bash tools/gate/gate_refglue.sh
refglue-selftest-full:
	+@MAKE="$(MAKE)" bash tools/gate/gate_refglue.sh --full
refglue-mutants:
	+@MAKE="$(MAKE)" bash tools/gate/gate_refglue.sh --mutants
