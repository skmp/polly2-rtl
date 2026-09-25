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

# Quartus 17 inconsistently preserves the auto-derived name of the fractional
# HDMI output clock between fitting seeds. Replace it with one deterministic
# 148.5 MHz clock on the C0 counter pin so both fitter and post-fit TimeQuest
# always analyze the HDMI pixel pipeline.
set hdmi_derived_clks [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}]
if {[get_collection_size $hdmi_derived_clks] > 0} {
    remove_clock $hdmi_derived_clks
}
create_clock -period 6.734006734 \
    [get_pins -compatibility_mode {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
    -name clk_hdmi

derive_clock_uncertainty

# ---- Decouple the clock domains (from sys/sys_top.sdc) ----
# Every crossing is either a proper synchronizer or quasi-static config
# (fb_base into spg is sampled once per frame). Without these cuts TimeQuest
# analyzes all CDC paths as synchronous-related: reset_req (50 MHz) into the
# whole core at ~2.2 ns, and clk_sys -> clk_hdmi (112.5 vs 148.5 MHz) at
# ~0.07 ns worst-case - unmeetable paths that wreck fitting and routing.
set_clock_groups -exclusive \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
    -group [get_clocks {clk_hdmi}] \
    -group [get_clocks {pll_video|video_pll|auto_generated|generic_pll1~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {*|h2f_user0_clk}] \
    -group [get_clocks {hdmi_sck}] \
    -group [get_clocks {FPGA_CLK1_50}] \
    -group [get_clocks {FPGA_CLK2_50}] \
    -group [get_clocks {FPGA_CLK3_50}]

# ---- clk_sys core clock: 4 fixed PLL outputs muxed through an altclkctrl ----
# The emu PLL (rtl/pll) has 4 fixed outputs from the 900 MHz VCO:
# outclk_0/1/2/3 = 75 / 90 / 100 / 112.5 MHz. No runtime PLL
# reconfig anymore - clk_sys is picked by the pixclk_mux clkctrl (glitch-free
# switchover), so derive_pll_clocks constrains each counter at its real
# frequency and all four propagate through the mux into the clk_sys domain.
# Only one can be active at a time: declare them physically exclusive so
# TimeQuest doesn't analyze impossible cross-transfers (e.g. 75->112.5 on the
# same register pair, which would be ~1.1 ns bogus setup requirements). The
# Without the cuts below, the fitter tries to close the fastest slot at
# 112.5 MHz and trades away margin from slot 0. Slot 0 is the supported 75 MHz
# default; faster slots remain functional but are explicitly unsupported.
set_clock_groups -physically_exclusive \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[2].*|divclk}] \
    -group [get_clocks {pll|pll_inst|altera_pll_i|*[3].*|divclk}]

# Slots 1-3 are unsupported overclocks. Keep their runtime selection logic, but
# do not let their impossible 90/100/112.5 MHz requirements consume placement
# effort or routing margin needed by the supported 75 MHz default (slot 0).
set_false_path -from [get_clocks {pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
               -to   [get_clocks {pll|pll_inst|altera_pll_i|*[1].*|divclk}]
set_false_path -from [get_clocks {pll|pll_inst|altera_pll_i|*[2].*|divclk}] \
               -to   [get_clocks {pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set_false_path -from [get_clocks {pll|pll_inst|altera_pll_i|*[3].*|divclk}] \
               -to   [get_clocks {pll|pll_inst|altera_pll_i|*[3].*|divclk}]

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
