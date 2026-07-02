// TB top: isp_primitive_iterator + injected data_cache256 + behavioral 64-bit DDR.
module isp_primitive_iterator_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             start,
    input      [1:0]  etype,            // 0=ENT_STRIP 1=ENT_TRI (array)
    input      [26:0] param_base,
    input      [20:0] entry_param_offs,
    input      [2:0]  entry_skip,
    input             entry_shadow,
    input             intensity_shadow, // FPU_SHAD_SCALE.intensity_shadow
    input      [5:0]  entry_mask,
    input      [4:0]  entry_count,      // tri array: prims+1
    input             consume,          // pulse: ack.triangle_done
    output            busy,
    output            triangle_ready,
    output            prim_done,
    output     [31:0] out_isp,
    output     [31:0] out_tag,          // the triangle's CoreTag (ISP_BACKGND_T layout)
    output     [31:0] v0x,v0y,v0z, v1x,v1y,v1z, v2x,v2y,v2z
);
    objlist_entry_t entry;
    assign entry.param_offs_in_words = entry_param_offs;
    assign entry.skip   = entry_skip;
    assign entry.shadow = entry_shadow;
    assign entry.mask   = entry_mask;
    assign entry.count  = entry_count;

    triangle_out_t trio;
    triangle_ack_t ack;
    assign ack.triangle_done = consume;
    assign triangle_ready = trio.triangle_ready;
    assign prim_done      = trio.prim_done;
    assign out_isp        = trio.isp;
    assign out_tag        = trio.tag;
    assign v0x=trio.v0.x; assign v0y=trio.v0.y; assign v0z=trio.v0.z;
    assign v1x=trio.v1.x; assign v1y=trio.v1.y; assign v1z=trio.v1.z;
    assign v2x=trio.v2.x; assign v2y=trio.v2.y; assign v2z=trio.v2.z;

    ddr_rd_req_t  dreq;
    ddr_rd_resp_t dresp;
    isp_primitive_iterator u_it (
        .clk(clk),.reset(reset),.start(start),.param_base(param_base),
        .intensity_shadow(intensity_shadow),
        .entry_type(entry_type_e'(etype)),.entry(entry),
        .busy(busy),.trio(trio),.ack(ack),.dreq(dreq),.dresp(dresp));

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
