derive_pll_clocks
derive_clock_uncertainty

# ---- clk_sys core clock: 4 fixed PLL outputs muxed through an altclkctrl ----
# The emu PLL (rtl/pll) has 4 fixed outputs from the 900 MHz VCO:
# outclk_0/1/2/3 = 75 / 90 / 100 / 112.5 MHz (C0=12/10/9/8). No runtime PLL
# reconfig anymore - clk_sys is picked by the pixclk_mux clkctrl (glitch-free
# switchover), so derive_pll_clocks constrains each counter at its real
# frequency and all four propagate through the mux into the clk_sys domain.
# Only one can be active at a time: declare them physically exclusive so
# TimeQuest doesn't analyze impossible cross-transfers (e.g. 75->112.5 on the
# same register pair, which would be ~1.1 ns bogus setup requirements). The
# core then has to close timing on the fastest slot, 112.5 MHz - the
# deliberate overclock option.
set_clock_groups -physically_exclusive \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[2].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[3].*|divclk}]

# clkselect: MMIO clk_sel reg (clk_sys) -> 50MHz sync pair -> clk_sel -> the
# soft mux's per-domain synchronizers. All hops are synchronized; cut them.
set_false_path -from [get_registers {*clk_sel*}]


# ---- PVR reg_file is QUASI-STATIC during a render ----
# All scalar PVR registers (reg_file r[*] -> the pvr_regs_t `regs` bus: PARAM_BASE,
# FPU_SHAD_SCALE, TEXT_CONTROL, ...) are programmed through wr_en/wr_addr while the
# core is IDLE, many cycles before the `go` strobe (a dedicated 1-cycle input port,
# NOT an r[] bit), and never change while a render is in flight. The FOG/PAL tables
# are separate M10Ks with their own synchronous read ports (not r[]), so nothing
# timing-live is sourced from r[*]. Cut these paths so the fitter stops burning
# effort on multi-level config cones (e.g. r[*] -> record_fetcher ts_addr_r was
# reported at -3.8 ns).
# (Softer alternative if ever needed: set_multicycle_path -setup 4 / -hold 3.)
set_false_path -from [get_registers {*|reg_file:*|r[*]}]

#set_instance_assignment -name RAM_STYLE "AUTO" -to cache_tags
#set_instance_assignment -name RAM_STYLE "AUTO" -to cache_data
