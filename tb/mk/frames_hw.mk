# frames_hw.mk: M13, the console-archive gate (PLAN M13, 1.4 "gate_frames_hw.sh"; conventions.md 7.4.3): p2-offline against
# the console's archives in dreamcast-tests (fit/hw pages, the archived measurement sets, the polly2-data dumps' hw.png
# frames and vram_out video memory, fit/zdump_data's depths), judged by the computed refsw3-known.
#
#   make frames-hw           tools/gate/gate_frames_hw.sh --subset (tb/frames_hw/subset_*.txt), base and +vramvary;
#                            "frames-hw: PASS" last
#   make frames-hw-full      every fit/hw test (*_races excluded), every set, every hw.png and vram_out, every zdump;
#                            SAMPLE=<seed>: a seeded sample (PLAN 0 rule 10), else the exhaustive run
#   make ztap-cmp            build/tools/ztap_cmp: the depth tap's keys (p2-offline +ztap) in refsw3's bits against
#                            fit/zdump_data (tb/common/zkey.h)
#   make ztap-cmp-check      tools/gate/ztap_selftest.sh: ztap_cmp on synthetic taps (a tile tapped twice: the last entry
#                            wins; an untapped tile, a key that is no stored depth fail); a step of both gates
#   make refsw3-known        tools/gate/refsw3_known.sh: build/gate/refsw3_known.txt (the gate runs it when stale)
ZTAP_CMP = $(BUILD)/tools/ztap_cmp

.PHONY: frames-hw frames-hw-full ztap-cmp ztap-cmp-check refsw3-known

$(ZTAP_CMP): tools/gate/ztap_cmp.cpp tb/common/zkey.h $(wildcard $(REFCORE)/pvr_*.h)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(HOST_CXXFLAGS) $< -o $@
ztap-cmp: $(ZTAP_CMP)
ztap-cmp-check: $(ZTAP_CMP)
	@bash tools/gate/ztap_selftest.sh

refsw3-known: refsw3-offline
	+@bash tools/gate/refsw3_known.sh -j $(P2_J)
frames-hw:
	+@MAKE="$(MAKE)" bash tools/gate/gate_frames_hw.sh --subset
frames-hw-full:
	+@MAKE="$(MAKE)" SAMPLE="$(SAMPLE)" bash tools/gate/gate_frames_hw.sh --full
