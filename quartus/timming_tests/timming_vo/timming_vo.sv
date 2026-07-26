//
// timming_vo - standalone synthesis/timing harness that wraps the WHOLE `vo`
// unit (polly2-core's video out / framebuffer write master: hs pixel pairer ->
// s0 format convert + address -> stage A word assembler -> stage B beat mapper
// -> run/burst engine). Sibling to the other timming_* projects: a self-contained
// place-and-route + timing-close context so the fitter reports Fmax/area for JUST
// this unit, decoupled from peel_core and the board top.
//
// Why it matters: s0 carries a py*FB_W_LINESTRIDE multiply plus the packmode
// quantizer adder chains, all in the clk_sys domain - the domain that closes by
// picoseconds on the real build. This harness is the cheap way to see what that
// path costs before a full polly2 compile.
//
// vo is a plain clk/reset unit (no DDR bridge, its DDR write port is injected),
// so this uses a real top-level `clk` pin - no sysmem_lite here.
//
// Pattern (identical to the other timing harnesses):
//   * ALL inputs are driven from a free-running input register bank (in_reg) the
//     HPS pokes via wr_en/wr_addr/wr_data, so every input bit has a real register
//     source and the fitter cannot fold the DUT away against constant inputs.
//   * ALL outputs are captured into RAW registers with NO logic in between (pure
//     unit timing), then XOR-folded to a SINGLE `digest` pin one cycle LATER (the
//     fold tree sits off the capture regs, never in the measured output paths).
//
// Build: cd timming_tests/timming_vo && quartus_sh --flow compile timming_vo
// Fmax:  output_files/timming_vo.sta.rpt
//
module timming_vo import tsp_pkg::*; (
    input             clk,
    input             reset,

    // ---- input register load (driven by the HPS) ----
    input             wr_en,        // 1: in_reg[wr_addr] <= wr_data
    input      [12:0] wr_addr,
    input      [31:0] wr_data,

    // ---- single folded output pin (keeps every output bit alive) ----
    output reg        digest
);
    // ---- input register bank ----
    //   0 : FB_W_CTRL        (packmode / dither / kval / alpha threshold)
    //   1 : FB_W_SOF1        (base; bit 24 = RTT dense mirror, bit 22 = bank)
    //   2 : FB_W_LINESTRIDE
    //   3 : SCALER_CTL       (hscale)
    //   4 : fbw_req.argb
    //   5 : { ..., ddr_busy@31, we@30, py@29:20, px@19:9, ... }  (control bits)
    //   6 : fbw_req.pix_idx  (legacy field; driven so it is never a constant)
    localparam integer NREG = 8;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire [31:0] w_ctl     = in_reg[5];
    wire        w_ddrbusy = w_ctl[31];
    wire        w_we      = w_ctl[30];
    wire  [9:0] w_py      = w_ctl[29:20];
    wire [10:0] w_px      = w_ctl[19:9];

    // ---- config registers handed to the DUT (the only four vo takes) ----
    // (plain declarations + assign: Quartus 17.0 rejects `wire <typedef> n = ...`)
    fb_w_ctrl_reg_t       w_fb_w_ctrl;
    wire           [31:0] w_fb_w_sof1;
    fb_w_linestride_reg_t w_fb_w_linestride;
    scaler_ctl_reg_t      w_scaler_ctl;
    assign w_fb_w_ctrl       = fb_w_ctrl_reg_t'(in_reg[0]);
    assign w_fb_w_sof1       = in_reg[1];
    assign w_fb_w_linestride = fb_w_linestride_reg_t'(in_reg[2]);
    assign w_scaler_ctl      = scaler_ctl_reg_t'(in_reg[3]);

    // ---- pixel port stimulus ----
    fb_wr_req_t  q_req;
    fb_wr_resp_t q_resp;
    always @* begin
        q_req.we      = w_we;
        q_req.pix_idx = in_reg[6][19:0];
        q_req.px      = w_px;
        q_req.py      = w_py;
        q_req.argb    = in_reg[4];
    end

    // ---- DUT ----
    wire        d_we;
    wire  [7:0] d_burstcnt;
    wire [28:0] d_addr;
    wire [63:0] d_din;
    wire  [7:0] d_be;

    vo u_vo (
        .clk(clk), .reset(reset),
        .fb_w_ctrl(w_fb_w_ctrl),
        .fb_w_sof1(w_fb_w_sof1),
        .fb_w_linestride(w_fb_w_linestride),
        .scaler_ctl(w_scaler_ctl),
        .fbw_req(q_req), .fbw_resp(q_resp),
        .ddr_busy(w_ddrbusy),
        .ddr_burstcnt(d_burstcnt),
        .ddr_addr(d_addr),
        .ddr_din(d_din),
        .ddr_be(d_be),
        .ddr_we(d_we)
    );

    // ---- RAW capture (no logic before the flops -> pure unit timing) ----
    reg [63:0] cap_din;
    reg [28:0] cap_addr;
    reg [17:0] cap_misc;
    always @(posedge clk) begin
        if (reset) begin cap_din <= '0; cap_addr <= '0; cap_misc <= '0; end
        else begin
            cap_din  <= d_din;
            cap_addr <= d_addr;
            cap_misc <= {d_be, d_burstcnt, d_we, q_resp.busy};
        end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_din, cap_addr, cap_misc };
    end
endmodule
