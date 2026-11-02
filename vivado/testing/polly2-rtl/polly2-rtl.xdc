# polly2_rtl_test runs on a real top-level `clk` pin: the render core's clock (clk_sys on the DE10, one of the 75 / 90 /
# 100 / 112.5 MHz PLL slots; quartus/polly2/polly2.sdc).
#
# Target 10 ns (100 MHz), as caique-rtl's project and polly2's old peel_core_top. Vivado reports slack, not Fmax:
# Fmax = 1000 / (10 - WNS) MHz (create_project.tcl's build step prints it). Once the target is met the tool stops
# pushing, so a positive WNS gives a lower bound; tighten the period to measure the ceiling.
create_clock -name clk -period 10.000 [get_ports clk]

# PVR register file is quasi-static during a render (polly2.sdc): reg_file's scalar registers are written while the
# core is idle, before `go`, and never change while a render is in flight. Cut the paths out of them, as the DE10 build
# does. (reg_file's `r` is one flat vector, so Vivado names its flops r_reg[<bit>]; r_reg* also covers replicas.)
set_false_path -from [get_cells -hierarchical -filter {IS_SEQUENTIAL && NAME =~ */u_core/u_rf/r_reg*}]

# The core reset comes straight from the `reset` pin. Input paths are unconstrained, so it is untimed, matching the
# DE10 build's false path on pvr_mmio's stretched pvr_rst. simplex_pvr_top synchronises its own copy for the read
# master, as on the board.

# The harness's 50 pins go to no board: no locations, one I/O standard every K26 bank (HP and HD) takes. Only the
# register-to-register paths are timed, as in caique-rtl's project.
set_property IOSTANDARD LVCMOS18 [get_ports *]
# Unplaced pins are fine for a timing build; let write_bitstream run anyway.
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
