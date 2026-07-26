# timming_vo runs on a real top-level `clk` pin (vo is a plain clk/reset unit -
# its DDR write port is injected, so there is no HPS bridge here).
#
# Target 112.5 MHz (8.889 ns): in the real build vo sits in the clk_sys domain,
# and clk_sys has to close on its FASTEST PLL slot (112.5 MHz, the overclock
# option) - see quartus/polly2/polly2.sdc. Actual Fmax is read from the STA Fmax
# Summary regardless of this period.
create_clock -name clk -period 8.889 [get_ports clk]
derive_clock_uncertainty
