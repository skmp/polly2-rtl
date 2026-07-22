// TB top: region_array_parser + behavioral 64-bit BURST DDR (no data_cache256).
// The parser now reads DDR directly (8-word sliding-window line reader), so the
// TB drives a burst-capable DDR model matching the shared-arbiter timing.
module region_array_parser_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             start,
    input      [26:0] region_base,
    input             region_v1,
    input             consume,          // pulse: ack.list_done
    output            busy,
    output            tiles_parsed,
    output            list_ready,
    output     [5:0]  tile_x,
    output     [5:0]  tile_y,
    output     [4:0]  state,
    output     [26:0] list_ptr,
    output            writeout,
    output            z_keep
);
    region_out_t rout;
    region_ack_t ack;
    assign ack.list_done = consume;
    assign list_ready = rout.list_ready;
    assign tile_x     = rout.tile_x;
    assign tile_y     = rout.tile_y;
    assign state      = rout.state;
    assign list_ptr   = rout.list_ptr;
    assign writeout   = rout.writeout;
    assign z_keep     = rout.z_keep;

    ddr_rd_req_t  dreq;
    ddr_rd_resp_t dresp;
    region_array_parser u_rap (
        .clk(clk),.reset(reset),.start(start),.region_base(region_base),
        .region_v1(region_v1),.busy(busy),.tiles_parsed(tiles_parsed),
        .rout(rout),.ack(ack),.dreq(dreq),.dresp(dresp));

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
