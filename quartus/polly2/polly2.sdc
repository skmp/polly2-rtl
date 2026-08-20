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

# ---- clk_sys core clock: a HARD 2:1 altclkctrl on two PLL outputs ----
# The emu PLL (rtl/pll) has 4 fixed outputs (75 / 112.5 / 131 / 141 MHz) but
# only outclk_0 (75) and outclk_1 (112.5) reach clk_sys, through the hard
# clkctrl in sys_top (inclk2/inclk3 - the only PLL-routable inputs; a 4:1 is
# impossible on this device, see the sysclk_ctrl comment there). outclk_2/3
# have no fanout. derive_pll_clocks constrains each counter at its real
# frequency and the two muxed clocks propagate through the clkctrl into the
# clk_sys domain. Only one can be active at a time: declare them physically
# exclusive so TimeQuest doesn't analyze impossible cross-transfers (e.g.
# 75->112.5 on the same register pair, ~1.1 ns bogus setup requirements).
set_clock_groups -physically_exclusive \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[2].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[3].*|divclk}]

# Slots 2/3 (131 / 141 MHz) no longer reach clk_sys at all (the hard 2:1
# clkctrl carries only 75/112.5), so they have no timed fanout. The multicycle
# below is kept as a belt-and-braces guard in case something is ever hung off
# them again: it relaxes their analysis to just past the 75 MHz requirement,
# so general[0] governs and fitter effort stays where it counts (asking the
# fitter to chase 7.0 ns everywhere is what produced the 18.7 ns single-net
# routing detour and thousands of small 75 MHz violations on baseline-clean
# paths). general[1] (112.5) stays fully timed as the shipping overclock.
foreach oc {2 3} {
    set g [get_clocks "pll|pll_inst|altera_pll_i|*\[$oc\].*|divclk"]
    set_multicycle_path -setup -end 2 -from $g -to $g
    set_multicycle_path -hold  -end 1 -from $g -to $g
}

# clkselect: MMIO clk_sel reg (clk_sys) -> 50MHz sync pair -> clk_sel -> the
# hard clkctrl's clkselect port. Quasi-static (the flip lands inside the
# clk_switch_reset window); cut every hop.
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

# ---- PVR core reset is STRETCHED, not timing-critical ----
# pvr_mmio drives pvr_rst from a 9-bit stretcher (pvr_rst <= (rst_cnt != 0)), so the
# reset is asserted for up to 511 consecutive cycles and the core does not begin work
# until the separate `go` strobe, many cycles after release. Nothing depends on reset
# ARRIVING in one cycle - only on it eventually arriving and eventually releasing - so
# a few cycles of skew across the die is harmless in both directions.
#
# Left untimed, this single register fans out to every pipeline stage in peel_core and
# became the design's critical path (-10.5 ns, 901 of the top 10000 setup paths) once
# the absolute-coordinate rework replaced 45 combinational fp_mul_i5 instances with 58
# registered *_spp_ro FP units, all of which take reset. It does not appear at all in
# the pre-rework report.
#
# NOTE this makes reset RELEASE skewed by construction. That is safe here only because
# of the `go` handshake above; if a future change ever starts traffic immediately on
# release, this cut must go and the reset must be pipelined/duplicated instead.
set_false_path -from [get_registers {*pvr_mmio*|pvr_rst}]
