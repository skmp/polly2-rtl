# ---- Base clocks ----
# The old MiSTer build got these from sys/sys_top.sdc (included via sys.qip);
# this project has a single SDC, so they must be declared here. Without the
# h2f_user0_clk clock the whole clk_100m domain (sysmem_lite, the f2sdram
# terminator, spg's Avalon fetch FSM) is unconstrained and the fitter ignores
# it entirely.
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK1_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK2_50]
create_clock -period "50.0 MHz"  [get_ports FPGA_CLK3_50]
create_clock -period "100.0 MHz" [get_pins -compatibility_mode *|h2f_user0_clk]
create_clock -period "10.0 MHz"  [get_pins -compatibility_mode hdmi_i2c|out_clk] -name hdmi_sck

derive_pll_clocks
derive_clock_uncertainty

# ---- Decouple the clock domains (from sys/sys_top.sdc) ----
# Every crossing is either a proper synchronizer or quasi-static config
# (fb_base into spg is sampled once per frame). Without these cuts TimeQuest
# analyzes all CDC paths as synchronous-related: reset_req (50 MHz) into the
# whole core at ~2.2 ns, and clk_sys -> clk_hdmi (112.5 vs 148.5 MHz) at
# ~0.07 ns worst-case - unmeetable paths that wreck fitting and routing.
set_clock_groups -exclusive \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

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

# ---- render-done f2h IRQ (sys_top render_irq_stretch) ----
# The stretcher's output goes into the HPS interrupts atom, which the GIC
# samples asynchronously - a 64-cycle pulse needs no timing at all. Cut every
# path out of it so the fitter spends zero effort (and trades zero core
# margin) on the IRQ plumbing.
set_false_path -from [get_registers {*render_irq_stretch*}]


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
