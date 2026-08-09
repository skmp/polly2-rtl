//
// coord_f32 - screen coordinate (0..2047) + pixel-center select -> fp32, 1 cycle.
//
// The absolute-coordinate raster/interp path needs the float form of a pixel index,
// optionally at the PIXEL CENTRE (+0.5) per HALF_OFFSET. This is that conversion, as
// a registered 1-cycle lookup:
//
//     addr = (coord << 1) | half        (12 bits: 0, 0.5, 1, 1.5, ... 2047, 2047.5)
//     f    = fp32(addr / 2)
//
// so the table IS just "float(addr) with the exponent one lower" - the .0/.5 variants
// are adjacent entries and `half` is the address LSB, exactly as intended.
//
// STORAGE. The sign is always 0 and the significand is at most 12 bits (addr < 2^12),
// so mantissa bits [11:0] are ALWAYS zero and only {exp[7:0], mant[22:12]} = 19 bits
// per entry are real. The table is therefore 4096 x 19, not 4096 x 32.
//
// STYLE - this matters, measure before committing:
//   "ROM"   : a 4096 x 19 lookup. On Cyclone V an M10K in 4096-deep mode is 2 bits
//             wide, so ONE read port costs ~10 M10K. The raster needs a port per lane
//             plus one for y (LANES+1 = 9 ports at LANES=8) -> ~90 M10K, which is a
//             quarter of the device's block RAM for what is arithmetically a shift.
//   "LOGIC" : the same function as a 12-bit leading-one detect + shift, ~30 ALMs and
//             no block RAM. Identical output, identical 1-cycle registered contract
//             (coord_tb checks the two styles agree on all 4096 entries).
// Default is USE_ROM=0 for that reason; set USE_ROM=1 per instance if the fitter
// prefers it on a particular path. (An INTEGER parameter, not a string: a string in a
// generate condition made Verilator elaborate both branches, and Quartus 17 is no more
// reliable with them.)
//
// `en` gates the output register so a stalled pipeline holds its value (the address is
// combinational, so a held address would re-read the same entry anyway - the enable is
// for the callers that gate every stage off one clock-enable).
//
module coord_f32 #(
    parameter integer USE_ROM = 0      // 0 = LZC+shift logic, 1 = 4096x19 table
) (
    input             clk,
    input             en,
    input      [10:0] coord,           // pixel index 0..2047
    input             half,            // 0 = pixel edge (.0), 1 = pixel centre (.5)
    output     [31:0] f                // fp32, registered (1 cycle), sign always 0
);
    wire [11:0] addr = {coord, half};  // (coord << 1) | half

    // Shared conversion function: fp32(addr/2), packed to the stored 19-bit form
    // {exp[7:0], mant[22:12]}. addr==0 -> +0.0.
    function automatic [18:0] conv(input [11:0] a);
        integer i, p;
        reg [22:0] m;
        begin
            if (a == 12'd0) conv = 19'd0;
            else begin
                p = 0;
                for (i = 0; i < 12; i = i + 1) if (a[i]) p = i;   // leading-one position
                // value = a * 2^-1 = 1.f * 2^(p-1)  ->  exp field = 127 + p - 1
                m = 23'({20'd0, a} << (23 - p));                  // hidden 1 shifts out
                conv = {8'(126 + p), m[22:12]};
            end
        end
    endfunction

    // Both styles land the stored entry in ONE register, so the module is 1 cycle
    // either way and the two are drop-in interchangeable.
    reg [18:0] ent_r;

    generate
        if (USE_ROM != 0) begin : g_rom
            (* romstyle = "M10K" *) reg [18:0] rom [0:4095];
            integer r;
            initial for (r = 0; r < 4096; r = r + 1) rom[r] = conv(r[11:0]);
            always @(posedge clk) if (en) ent_r <= rom[addr];
        end else begin : g_logic
            always @(posedge clk) if (en) ent_r <= conv(addr);
        end
    endgenerate

    // sign 0 ; the low 12 mantissa bits are structurally zero (see STORAGE above)
    assign f = {1'b0, ent_r, 12'd0};
endmodule
