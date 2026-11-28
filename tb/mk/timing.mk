# timing.mk: MT0, the timing harness (PLAN MT0, 1.5; conventions.md 7.6): the timemeas scenes replayed on p2-offline
# (dreamcast-tests pvr-tests/timemeas, main.c TM_EMIT: make -C pvr-tests/timemeas emit) and judged against the console's
# archived logs (fit/timemeas_logs), tools/timing/.
#
#   make timing-harness          the MT0 gate (tools/timing/gate_timing.sh): K and the write-out's format dependence (the
#                                empty 0888, 565 and 888 tiles against one K, within 0 .. 14), the cutter (one clock a
#                                run), the palette clock end to end, the races lists' consistency; "timing-harness: PASS"
#   make timing-harness-mutants  its mutants (tb/timing/mutants*.txt): the cutter +1 clk a run, the 888 write-out
#   make timing-fit              the fits, once: VR_ROW, then K (tb/timing/k.txt; docs/timing.md 11)
#   make timing-report           every timed scene, console against RTL (build/timing/report/): the starting table of MT1
.PHONY: timing-harness timing-harness-mutants timing-fit timing-report p2-offline-tprobe

timing-harness:
	+@MAKE="$(MAKE)" bash tools/timing/gate_timing.sh
timing-harness-mutants:
	+@MAKE="$(MAKE)" bash tools/timing/gate_timing.sh --mutants
timing-fit:
	+@MAKE="$(MAKE)" bash tools/timing/gate_timing.sh --fit
timing-report:
	+@MAKE="$(MAKE)" bash tools/timing/gate_timing.sh --report

# the timing harness's mutant probe beside p2-offline (tools/timing/timing_probe.sh)
p2-offline-tprobe: p2-offline
	@cp tools/timing/timing_probe.sh $(P2OFF_OBJDIR)/timing_probe
