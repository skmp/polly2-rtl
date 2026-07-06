# per-stage timing harness clock. A real top-level `clk` pin (10 ns / 100 MHz
# target); reported Fmax comes from real path delay regardless.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
