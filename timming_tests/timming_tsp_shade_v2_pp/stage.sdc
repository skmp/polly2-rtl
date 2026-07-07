# timming_tsp_shade_v2_pp runs on the HPS-provided core clock (h2f_user0_clk); constrain the
# CLKENA buffer the HPS clock reaches the fabric through. Target 100 MHz (10.0 ns) -
# the real floor for the whole shade pipeline. Actual Fmax is read from the STA
# Fmax Summary regardless of this period.
create_clock -name core_clk -period 9.500 \
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]
derive_pll_clocks
derive_clock_uncertainty
