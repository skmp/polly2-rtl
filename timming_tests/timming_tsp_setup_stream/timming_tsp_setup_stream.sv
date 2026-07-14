//
// timming_tsp_setup_stream - standalone synthesis/timing harness that wraps the WHOLE
// tsp_setup_stream unit. Sibling to timming_tsp_setup_min / timming_tsp_shade_v2_pp:
// a self-contained place-and-route + timing-close context so the fitter reports
// Fmax/area for JUST the streamed (II=4) TSP setup core (its 4+4 fp_mul16 lanes,
// 6 GEO adders, reciprocal, and shared attr multipliers), decoupled from the rest of
// the pipeline.
//
// tsp_setup_stream is a plain clk/reset unit (no DDR, no texture caches) with the SAME
// port list as tsp_setup_min, so - like that harness - this uses a plain clocked top
// (a real top-level `clk` pin, no sysmem bridge).
//
// Pattern (identical to the other timing harnesses):
//   * ALL tsp_setup_stream inputs are driven from a single free-running input register
//     bank (in_reg) the HPS pokes via wr_en/wr_addr/wr_data, so every input bit has a
//     real register source and input paths are realistic - and the fitter cannot fold
//     the DUT away against constant inputs.
//   * ALL tsp_setup_stream outputs are captured into RAW registers with NO logic in
//     between (so the DUT-output -> flop path is the PURE setup timing), then XOR-folded
//     to a SINGLE `digest` pin one cycle LATER (fold tree off the capture regs, never in
//     the measured output paths). Every output bit feeds digest, so none can be pruned.
//
// This is NOT functionally meaningful - it computes nothing usable. It exists only to
// give tsp_setup_stream a self-contained fitting context for perf iteration.
//
// Build: cd timming_tests/timming_tsp_setup_stream && quartus_sh --flow compile timming_tsp_setup_stream
// Fmax:  output_files/timming_tsp_setup_stream.sta.rpt
//
module timming_tsp_setup_stream import tsp_pkg::*; (
    input             clk,
    input             reset,

    // ---- input register load (driven by the HPS) ----
    input             wr_en,        // 1: in_reg[wr_addr] <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every setup output alive) ----
    output reg        digest
);
    // ==================================================================
    // INPUT REGISTER BANK. The HPS writes 32-bit words at wr_addr; the DUT inputs
    // are slices of this bank so every input bit has a real register source. Layout
    // (word index -> field):
    //   0..8   : x1,y1,z1, x2,y2,z2, x3,y3,z3
    //   9..10  : xbase, ybase
    //   11..16 : u1,v1, u2,v2, u3,v3
    //   17..19 : col1,col2,col3
    //   20..22 : ofs1,ofs2,ofs3
    //   23     : { ..., offset, texture, gouraud, start }   (control bits)
    // ==================================================================
    localparam integer NREG = 24;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    // unpack the bank into DUT inputs
    wire [31:0] w_ctl     = in_reg[23];
    wire        w_start   = w_ctl[0];
    wire        w_gouraud = w_ctl[1];
    wire        w_texture = w_ctl[2];
    wire        w_offset  = w_ctl[3];

    // ==================================================================
    // DUT: tsp_setup_stream (the module under test).
    // ==================================================================
    wire        s_done;
    wire        s_plane_valid;
    wire [3:0]  s_plane_idx;
    wire [31:0] s_o_ddx, s_o_ddy, s_o_c;

    tsp_setup_stream u_setup (
        .clk(clk), .reset(reset),
        .start(w_start), .done(s_done),
        .gouraud(w_gouraud), .texture(w_texture), .offset(w_offset),
        .x1(in_reg[0]), .y1(in_reg[1]), .z1(in_reg[2]),
        .x2(in_reg[3]), .y2(in_reg[4]), .z2(in_reg[5]),
        .x3(in_reg[6]), .y3(in_reg[7]), .z3(in_reg[8]),
        .xbase(in_reg[9]), .ybase(in_reg[10]),
        .u1(in_reg[11]), .v1(in_reg[12]),
        .u2(in_reg[13]), .v2(in_reg[14]),
        .u3(in_reg[15]), .v3(in_reg[16]),
        .col1(in_reg[17]), .col2(in_reg[18]), .col3(in_reg[19]),
        .ofs1(in_reg[20]), .ofs2(in_reg[21]), .ofs3(in_reg[22]),
        .plane_valid(s_plane_valid), .plane_idx(s_plane_idx),
        .o_ddx(s_o_ddx), .o_ddy(s_o_ddy), .o_c(s_o_c));

    // ==================================================================
    // OUTPUT CAPTURE. Stage the RAW setup outputs into registers with NO logic in
    // between - so the DUT-output -> register path is the PURE tsp_setup_stream timing
    // (nothing but the flop's own setup on the far end). The XOR-fold that keeps every
    // bit alive happens ONE CYCLE LATER, off these registers.
    // ==================================================================
    reg [31:0] cap_ddx, cap_ddy, cap_c;
    reg [3:0]  cap_idx;
    reg        cap_done, cap_pvalid;
    always @(posedge clk) begin
        if (reset) begin
            cap_ddx <= 32'd0; cap_ddy <= 32'd0; cap_c <= 32'd0;
            cap_idx <= 4'd0; cap_done <= 1'b0; cap_pvalid <= 1'b0;
        end else begin
            cap_ddx    <= s_o_ddx;      // raw - no combinational fold here
            cap_ddy    <= s_o_ddy;
            cap_c      <= s_o_c;
            cap_idx    <= s_plane_idx;
            cap_done   <= s_done;
            cap_pvalid <= s_plane_valid;
        end
    end

    // next cycle: XOR-fold the captured registers down to one `digest` pin so the
    // fitter cannot prune any output bit. This tree is OFF cap_* regs, not the DUT.
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_ddx, cap_ddy, cap_c, cap_idx, cap_done, cap_pvalid };
    end
endmodule
