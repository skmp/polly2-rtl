// Stub peel_core for the simplex_pvr_top burst/reset testbench (pvr_burst_tb).
// Replaces the real core so the adapter's DDR masters can be driven directly.
// Commanded through the wr_en register port:
//   wr_addr 0  : set stream base pix_idx = wr_data[19:0]
//   wr_addr 4  : start streaming wr_data[19:0] pixels linearly from the base
//                (argb = {pix16,pix16} ^ {xorpat,xorpat})
//   wr_addr 8  : issue one DDR read burst, addr = wr_data[24:0], 8 beats
//   wr_addr 12 : set fb_w_sof1 = wr_data
//   wr_addr 16 : set argb xor pattern = wr_data[15:0]
//   wr_addr 20 : stream a full 640x480 frame in TILE order (20x15 tiles of
//                32x32, row-major inside each tile - the real peel_core
//                writeback pattern, with a pix_idx jump every 32 pixels)
// Telemetry surfaces on regs_out (visible on the DUT's top-level ports):
//   test_select = beats received (dready count since reset)
//   fb_r_sof1   = last dout[31:0]
//   fb_r_sof2   = XOR of all dout[31:0] received
//   fb_w_sof2   = UNEXPECTED beats: dready with no read outstanding (must
//                 stay 0 - a stray beat would desync the real core's arbiter)
module peel_core import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,
    output reg        done,
    output ddr_rd_req_t  ddr_req,
    input  ddr_rd_resp_t ddr_resp,
    output fb_wr_req_t   fbw_req,
    input  fb_wr_resp_t  fbw_resp,
    output pvr_regs_t    regs_out
);
    reg [19:0] pix    = 20'd0;
    reg [20:0] remain = 21'd0;
    reg        rd_on  = 1'b0;
    reg [24:0] raddr  = 25'd0;
    reg [3:0]  rleft  = 4'd0;
    reg [31:0] sof    = 32'd0;
    reg [31:0] beats  = 32'd0;
    reg [31:0] lastd  = 32'd0;
    reg [31:0] xacc   = 32'd0;
    reg [31:0] unexp  = 32'd0;
    reg [15:0] xorpat = 16'd0;

    // tile-order streaming (wr_addr 20): col fastest, then row, tx, ty
    reg        tile_mode = 1'b0;
    reg [4:0]  t_col = 5'd0, t_row = 5'd0;
    reg [4:0]  t_tx  = 5'd0;
    reg [3:0]  t_ty  = 4'd0;
    wire [9:0] t_y   = {t_ty, 5'd0} + {5'd0, t_row};    // ty*32 + row
    wire [19:0] tile_pix = {t_y, 9'd0} + {3'd0, t_y, 7'd0}   // y*640 = y*512+y*128
                         + {10'd0, t_tx, 5'd0} + {15'd0, t_col};

    wire [19:0] cur_pix = tile_mode ? tile_pix : pix;

    assign fbw_req.we      = tile_mode || (remain != 21'd0);
    assign fbw_req.pix_idx = cur_pix;
    assign fbw_req.argb    = {cur_pix[15:0] ^ xorpat, cur_pix[15:0] ^ xorpat};

    assign ddr_req.rd    = rd_on;
    assign ddr_req.addr  = {4'b0011, raddr};
    assign ddr_req.burst = 8'd8;

    always_comb begin
        regs_out             = '0;
        regs_out.fb_w_sof1   = sof;
        regs_out.fb_w_sof2   = unexp;
        regs_out.test_select = beats;
        regs_out.fb_r_sof1   = lastd;
        regs_out.fb_r_sof2   = xacc;
    end

    always @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            remain <= 21'd0;
            rd_on  <= 1'b0;
            rleft  <= 4'd0;
            beats  <= 32'd0;
            lastd  <= 32'd0;
            xacc   <= 32'd0;
            unexp  <= 32'd0;
            tile_mode <= 1'b0;
        end else begin
            if (wr_en) begin
                case (wr_addr)
                    13'd0:  pix    <= wr_data[19:0];
                    13'd4:  remain <= {1'b0, wr_data[19:0]};
                    13'd8:  begin
                        raddr <= wr_data[24:0];
                        rd_on <= 1'b1;
                        rleft <= 4'd8;
                    end
                    13'd12: sof <= wr_data;
                    13'd16: xorpat <= wr_data[15:0];
                    13'd20: begin
                        tile_mode <= 1'b1;
                        t_col <= 5'd0; t_row <= 5'd0;
                        t_tx  <= 5'd0; t_ty  <= 4'd0;
                    end
                    default: ;
                endcase
            end

            if (remain != 21'd0 && !fbw_resp.busy) begin
                pix    <= pix + 20'd1;
                remain <= remain - 21'd1;
            end

            if (tile_mode && !fbw_resp.busy) begin
                t_col <= t_col + 5'd1;
                if (t_col == 5'd31) begin
                    t_row <= t_row + 5'd1;
                    if (t_row == 5'd31) begin
                        t_tx <= t_tx + 5'd1;
                        if (t_tx == 5'd19) begin
                            t_tx <= 5'd0;
                            t_ty <= t_ty + 4'd1;
                            if (t_ty == 4'd14) begin
                                t_ty      <= 4'd0;
                                tile_mode <= 1'b0;   // frame done
                            end
                        end
                    end
                end
            end

            if (ddr_resp.dready) begin
                beats <= beats + 32'd1;
                lastd <= ddr_resp.dout[31:0];
                xacc  <= xacc ^ ddr_resp.dout[31:0];
                if (rleft != 4'd0) begin
                    rleft <= rleft - 4'd1;
                    if (rleft == 4'd1) rd_on <= 1'b0;
                end else begin
                    unexp <= unexp + 32'd1;
                end
            end
        end
    end
endmodule
