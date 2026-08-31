// 50 MHz -> 27 MHz native-standard-definition video PLL.
module pll_video (
	input  wire        refclk,
	input  wire        rst,
	output wire        outclk_0,
	output wire        locked,
	input  wire [63:0] reconfig_to_pll,
	output wire [63:0] reconfig_from_pll
);
	wire [4:0] pll_clks;
	wire       pll_locked;

	altpll #(
		.bandwidth_type("AUTO"),
		.clk0_divide_by(50),
		.clk0_duty_cycle(50),
		.clk0_multiply_by(27),
		.clk0_phase_shift("0"),
		.compensate_clock("CLK0"),
		.inclk0_input_frequency(20000),
		.intended_device_family("Cyclone V"),
		.lpm_hint("CBX_MODULE_PREFIX=pll_video"),
		.lpm_type("altpll"),
		.operation_mode("NORMAL"),
		.pll_type("AUTO"),
		.port_activeclock("PORT_UNUSED"),
		.port_areset("PORT_USED"),
		.port_clkbad0("PORT_UNUSED"),
		.port_clkbad1("PORT_UNUSED"),
		.port_clkloss("PORT_UNUSED"),
		.port_clkswitch("PORT_UNUSED"),
		.port_configupdate("PORT_UNUSED"),
		.port_fbin("PORT_UNUSED"),
		.port_inclk0("PORT_USED"),
		.port_inclk1("PORT_UNUSED"),
		.port_locked("PORT_USED"),
		.port_pfdena("PORT_UNUSED"),
		.port_phasecounterselect("PORT_UNUSED"),
		.port_phasedone("PORT_UNUSED"),
		.port_phasestep("PORT_UNUSED"),
		.port_phaseupdown("PORT_UNUSED"),
		.port_pllena("PORT_UNUSED"),
		.port_scanaclr("PORT_UNUSED"),
		.port_scanclk("PORT_UNUSED"),
		.port_scanclkena("PORT_UNUSED"),
		.port_scandata("PORT_UNUSED"),
		.port_scandataout("PORT_UNUSED"),
		.port_scandone("PORT_UNUSED"),
		.port_scanread("PORT_UNUSED"),
		.port_scanwrite("PORT_UNUSED"),
		.port_clk0("PORT_USED"),
		.port_clk1("PORT_UNUSED"),
		.port_clk2("PORT_UNUSED"),
		.port_clk3("PORT_UNUSED"),
		.port_clk4("PORT_UNUSED"),
		.port_clk5("PORT_UNUSED"),
		.port_clkena0("PORT_UNUSED"),
		.port_clkena1("PORT_UNUSED"),
		.port_clkena2("PORT_UNUSED"),
		.port_clkena3("PORT_UNUSED"),
		.port_clkena4("PORT_UNUSED"),
		.port_clkena5("PORT_UNUSED"),
		.port_extclk0("PORT_UNUSED"),
		.port_extclk1("PORT_UNUSED"),
		.port_extclk2("PORT_UNUSED"),
		.port_extclk3("PORT_UNUSED"),
		.width_clock(5)
	) video_pll (
		.areset(rst),
		.inclk({1'b0, refclk}),
		.clk(pll_clks),
		.locked(pll_locked),
		.activeclock(), .clkbad(), .clkena({6{1'b1}}), .clkloss(),
		.clkswitch(1'b0), .configupdate(1'b0), .enable0(), .enable1(),
		.extclk(), .extclkena({4{1'b1}}), .fbin(1'b1), .fbmimicbidir(),
		.fbout(), .fref(), .icdrclk(), .pfdena(1'b1),
		.phasecounterselect(4'b1111), .phasedone(), .phasestep(1'b1),
		.phaseupdown(1'b1), .pllena(1'b1), .scanaclr(1'b0),
		.scanclk(1'b0), .scanclkena(1'b1), .scandata(1'b0),
		.scandataout(), .scandone(), .scanread(1'b0), .scanwrite(1'b0),
		.sclkout0(), .sclkout1(), .vcooverrange(), .vcounderrange()
	);

	assign outclk_0 = pll_clks[0];
	assign locked = pll_locked;
	assign reconfig_from_pll = 64'd0;
endmodule
