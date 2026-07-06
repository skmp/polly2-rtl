# Target 120 MHz (8.333 ns) - tighter than the 100 MHz other stages use, so the slack
# report pinpoints exactly which paths block 120. Actual Fmax is still read from the
# STA Fmax Summary regardless of this period.
create_clock -name core_clk -period 8.333 \
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]
derive_pll_clocks
derive_clock_uncertainty
