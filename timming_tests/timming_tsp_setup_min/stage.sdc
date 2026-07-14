# timming_tsp_setup_min runs on a real top-level `clk` pin (tsp_setup_min is a plain
# clk/reset unit, no HPS core clock). Target 100 MHz (10.0 ns) - the real floor for
# the setup core. Actual Fmax is read from the STA Fmax Summary regardless of this
# period.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
