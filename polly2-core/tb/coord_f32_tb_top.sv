//
// coord_f32_tb_top - drives BOTH coord_f32 styles from one address stream so the
// tb can check each against the C model AND against each other (the styles must be
// bit-identical drop-ins, which is the whole point of having both).
//
module coord_f32_tb_top (
    input             clk,
    input             en,
    input      [10:0] coord,
    input             half,
    output     [31:0] f_logic,
    output     [31:0] f_rom
);
    coord_f32 #(.USE_ROM(0)) u_l (.clk(clk),.en(en),.coord(coord),.half(half),.f(f_logic));
    coord_f32 #(.USE_ROM(1)) u_r (.clk(clk),.en(en),.coord(coord),.half(half),.f(f_rom));
endmodule
