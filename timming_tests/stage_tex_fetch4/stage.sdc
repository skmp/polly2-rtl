# tex_fetch4 runs on the HPS core clock (h2f_user0_clk); constrain the CLKENA buffer.
# Target 120 MHz (8.333 ns). Actual Fmax is still read from the STA Fmax Summary.
create_clock -name core_clk -period 8.333 \
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]
derive_pll_clocks
derive_clock_uncertainty
