# timing_tsp_blend runs on a real top-level `clk` pin (tsp_blend is pure
# combinational logic between the harness registers).
#
# Target 112.5 MHz (8.889 ns): in the real build the blend's stage-CC cone
# (cb2_* regs -> tsp_blend -> cb3_* regs) sits in the clk_sys domain, which has
# to close on its FASTEST PLL slot (112.5 MHz) - see quartus/polly2/polly2.sdc.
# Actual Fmax is read from the STA Fmax Summary regardless of this period.
create_clock -name clk -period 8.889 [get_ports clk]
derive_clock_uncertainty
