//
// timming_isp_primitive_iterator_pf - standalone synthesis/timing harness for the WHOLE
// isp_primitive_iterator_pf (the prefetching entry->triangle iterator). Sibling to the
// other timming_* projects: an isolated place-and-route + timing-close context so the
// fitter reports Fmax/area for JUST this unit - it carries the ex_shadow -> geometry
// multiply cones (now staged per entry) that were peel_core's Fmax violators.
//
// Plain clk/reset harness (the DDR client is not functionally serviced - its dresp
// fields are driven from the input register bank, which is all timing needs: every
// input bit has a real register source and every output bit reaches the digest).
//
// Pattern (identical to the other timing harnesses):
//   * ALL inputs are driven from a free-running input register bank (in_reg) the HPS
//     pokes via wr_en/wr_addr/wr_data, so input paths are realistic and the fitter
//     cannot fold the DUT away.
//   * ALL outputs (trio struct, handshakes, dreq) are captured into RAW registers with
//     NO logic in between (pure unit timing), then XOR-folded to a SINGLE `digest` pin
//     one cycle LATER (fold tree off the capture regs, never in the measured paths).
//
// Build: cd timming_tests/timming_isp_primitive_iterator_pf && quartus_sh --flow compile timming_isp_primitive_iterator_pf
// Fmax:  output_files/timming_isp_primitive_iterator_pf.sta.rpt
//
module timming_isp_primitive_iterator_pf import tsp_pkg::*; (
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
    //   0 : param_base [26:0]
    //   1 : entry[31:0]                      (low 32 bits of objlist_entry_t)
    //   2 : { dresp.dready, dresp.busy, ack.triangle_done, intensity_shadow,
    //         entry_valid, entry_pt, entry_type[1:0], entry[35:32] }  (control)
    //   3 : dresp.dout[31:0]
    //   4 : dresp.dout[63:32]
    localparam integer NREG = 5;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

    wire [31:0] ctl = in_reg[2];

    objlist_entry_t  w_entry;
    assign w_entry = objlist_entry_t'({ctl[3:0], in_reg[1]});
    entry_type_e     w_etype;
    assign w_etype = entry_type_e'(ctl[5:4]);
    wire             w_entry_pt = ctl[6];
    wire             w_entry_v  = ctl[7];
    wire             w_ishadow  = ctl[8];
    triangle_ack_t   w_ack;
    assign w_ack = triangle_ack_t'(ctl[9]);

    ddr_rd_resp_t    w_dresp;
    assign w_dresp.busy   = ctl[10];
    assign w_dresp.dready = ctl[11];
    assign w_dresp.dout   = {in_reg[4], in_reg[3]};

    // ---- DUT ----
    wire            s_entry_ack, s_busy;
    triangle_out_t  s_trio;
    ddr_rd_req_t    s_dreq;
    isp_primitive_iterator_pf u_dut (
        .clk(clk), .reset(reset),
        .param_base(in_reg[0][26:0]),
        .intensity_shadow(w_ishadow),
        .entry_valid(w_entry_v), .entry_type(w_etype), .entry(w_entry),
        .entry_pt(w_entry_pt), .entry_ack(s_entry_ack), .busy(s_busy),
        .trio(s_trio), .ack(w_ack),
        .dreq(s_dreq), .dresp(w_dresp));

    // ---- RAW capture (no logic before the flops -> pure unit timing) ----
    reg [$bits(triangle_out_t)-1:0] cap_trio;
    reg [$bits(ddr_rd_req_t)-1:0]   cap_dreq;
    reg [1:0]                       cap_hs;
    always @(posedge clk) begin
        if (reset) begin cap_trio <= '0; cap_dreq <= '0; cap_hs <= '0; end
        else begin
            cap_trio <= s_trio;
            cap_dreq <= s_dreq;
            cap_hs   <= {s_entry_ack, s_busy};
        end
    end

    // ---- next cycle: XOR-fold to one pin (off cap_*, not the DUT) ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^{ cap_trio, cap_dreq, cap_hs };
    end
endmodule
