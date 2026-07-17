# tile_engine_top runs on the HPS-provided core clock (h2f_user0_clk from the
# cyclonev_hps_interface hard IP). There is no top-level `clk` port.
#
# The clock reaches the fabric through a global clock-enable buffer named
#   ...|h2f_user0_clk[0]~CLKENA0   (drives CLKCTRL_G9, ~411 fanout = whole design)
# The bare HPS boundary name h2f_user0_clk[0] does NOT match get_pins (it is the
# hard-IP edge), so constrain the CLKENA buffer's output pin instead.
#
# The 10 ns period (100 MHz) is a target; reported Fmax is derived from real
# path delay regardless of this value.
create_clock -name core_clk -period 10.000 \
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]

derive_pll_clocks
derive_clock_uncertainty

# ---- PVR reg_file is QUASI-STATIC during a render ----
# All scalar PVR registers (reg_file r[*] -> the pvr_regs_t `regs` bus) are
# programmed through wr_en/wr_addr while the core is IDLE, before the `go`
# strobe (a dedicated 1-cycle port, NOT an r[] bit), and never change while a
# render is in flight. FOG/PAL tables are separate M10Ks with their own
# synchronous read ports (not r[]). Cut these paths so the fitter stops burning
# effort on multi-level config cones (e.g. r[*] -> record_fetcher ts_addr_r).
# (Softer alternative if ever needed: set_multicycle_path -setup 4 / -hold 3.)
set_false_path -from [get_registers {*|reg_file:*|r[*]}]
