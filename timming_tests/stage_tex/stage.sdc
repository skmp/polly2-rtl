# TEX stage runs on the HPS-provided core clock (h2f_user0_clk); constrain the
# CLKENA buffer the HPS clock reaches the fabric through (see simplex.sdc).
create_clock -name core_clk -period 10.000 \
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]
derive_pll_clocks
derive_clock_uncertainty
