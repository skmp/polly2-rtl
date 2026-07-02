// TB top: object_list_parser + injected data_cache256 + behavioral 64-bit DDR.
// `consume` pulses ack.entry_done: the C++ TB pulses it when it wants the
// parser to advance past the currently-presented entry.
module object_list_parser_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             start,
    input      [26:0] list_ptr,
    input             consume,          // pulse: ack.entry_done for one cycle
    output            busy,
    output            done,
    output            entry_ready,
    output     [1:0]  entry_type,
    output     [20:0] entry_param_offs,
    output     [2:0]  entry_skip,
    output            entry_shadow,
    output     [5:0]  entry_mask,
    output     [4:0]  entry_count
);
    prim_out_t prim;
    prim_ack_t ack;
    assign ack.entry_done   = consume;
    assign entry_ready       = prim.entry_ready;
    assign entry_type        = prim.entry_type;
    assign entry_param_offs  = prim.entry.param_offs_in_words;
    assign entry_skip        = prim.entry.skip;
    assign entry_shadow      = prim.entry.shadow;
    assign entry_mask        = prim.entry.mask;
    assign entry_count       = prim.entry.count;

    ddr_rd_req_t  dreq;
    ddr_rd_resp_t dresp;
    object_list_parser u_olp (
        .clk(clk),.reset(reset),.start(start),.list_ptr(list_ptr),
        .busy(busy),.done(done),.prim(prim),.ack(ack),.dreq(dreq),.dresp(dresp));

    // BURST + latency DDR model (matches tex_mem sim path / shared arbiter).
    localparam integer RD_LAT = 8;
    (* verilator public_flat_rw *) reg [63:0] vram [0:65535];
    reg busy_r; reg [15:0] word_r; reg [7:0] beats_r, lat_r;
    reg [63:0] dout_r; reg dready_r;
    assign dresp.busy=busy_r; assign dresp.dout=dout_r; assign dresp.dready=dready_r;
    always @(posedge clk) begin
        dready_r <= 1'b0;
        if (reset) busy_r <= 1'b0;
        else if (!busy_r) begin
            if (dreq.rd) begin busy_r<=1'b1; word_r<=dreq.addr[15:0];
                beats_r<=dreq.burst; lat_r<=RD_LAT[7:0]; end
        end else if (lat_r != 0) lat_r <= lat_r - 8'd1;
        else begin
            dout_r<=vram[word_r]; dready_r<=1'b1; word_r<=word_r+16'd1;
            if (beats_r <= 8'd1) busy_r <= 1'b0;
            beats_r <= beats_r - 8'd1;
        end
    end
endmodule
