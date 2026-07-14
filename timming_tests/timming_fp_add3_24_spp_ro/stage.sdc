# timming_fp_add3_24_spp_ro runs on a real top-level `clk` pin (plain streaming unit,
# no HPS core clock). Target 100 MHz (10.0 ns). Actual Fmax is read from the STA Fmax
# Summary regardless of this period.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
