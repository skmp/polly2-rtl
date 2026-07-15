// isp_raster_stream_tb_top - one isp_raster_line, driven two ways over a 32x32
// tile so the C++ TB can prove the STREAMED consume path (issue a chunk every
// clock, write results at the echoed out_x/out_y) matches the SERIAL path
// (issue a chunk, wait out_valid, write at ras_x/ras_y).
//
// The C++ TB sets the planes + depth_mode, runs one mode, reads back the tag
// buffer via public_flat_rw, and diffs.
module isp_raster_stream_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    input      [31:0] c1,c2,c3,c4,
    input      [31:0] dx12,dx23,dx31,dx41,
    input      [31:0] dy12,dy23,dy31,dy41,
    input      [31:0] ddx,ddy,c_invw,
    input      [2:0]  depth_mode,
    input      [31:0] tri_tag,
    input             start,       // pulse: begin a sweep
    input             streamed,    // 1 = streamed path, 0 = serial path
    output reg        busy
);
    localparam integer TILE_W=32, TILE_H=32, RAS_LANES=8;
    (* verilator public_flat_rw *) reg [31:0] dt_depth [0:TILE_W*TILE_H-1];
    (* verilator public_flat_rw *) reg [31:0] dt_tag   [0:TILE_W*TILE_H-1];

    reg  [4:0] ras_x, ras_y;
    // serial path pulses ras_in_valid_r; streamed path issues combinationally
    // (in phase with ras_x/y). ras_in_valid selects per mode.
    reg        ras_in_valid_r;
    wire       ras_in_valid = streamed ? (st == S_STR) : ras_in_valid_r;
    wire       ras_out_valid;
    wire [RAS_LANES-1:0]    ras_inside;
    wire [32*RAS_LANES-1:0] ras_invw_flat;
    wire [4:0] ras_ox, ras_oy;
    function [31:0] ras_invw(input integer lane); ras_invw = ras_invw_flat[32*lane +: 32]; endfunction

    isp_raster_line #(.LANES(RAS_LANES)) u_line (
        .clk(clk),.reset(reset),.in_valid(ras_in_valid),.y(ras_y),.x_base(ras_x),
        .c1(c1),.c2(c2),.c3(c3),.c4(c4),
        .dx12(dx12),.dx23(dx23),.dx31(dx31),.dx41(dx41),
        .dy12(dy12),.dy23(dy23),.dy31(dy31),.dy41(dy41),
        .ddx(ddx),.ddy(ddy),.c_invw(c_invw),
        .out_valid(ras_out_valid),.inside_mask(ras_inside),.invw_flat(ras_invw_flat),
        .out_x(ras_ox),.out_y(ras_oy));

    // depth compare: SERIAL reads at issue coords (ras_x,ras_y); STREAMED at
    // result coords (ras_ox,ras_oy).
    wire [4:0] cmp_x = streamed ? ras_ox : ras_x;
    wire [4:0] cmp_y = streamed ? ras_oy : ras_y;
    wire [RAS_LANES-1:0] ras_pass;
    generate
      for (genvar gd=0; gd<RAS_LANES; gd=gd+1) begin : dcmp
        isp_depth_cmp u_cmp (.mode(depth_mode),
            .peel(1'b0), .tag(32'h0), .zb2(32'h0), .pb(32'h0), .pb2(32'h0),
            .valid(1'b0), .more(),
            .nw(ras_invw_flat[32*gd +: 32]),
            .zb(dt_depth[{cmp_y, cmp_x + 5'(gd)}]),.pass(ras_pass[gd]));
      end
    endgenerate

    localparam integer NCHUNK = (TILE_W/RAS_LANES)*TILE_H;
    integer inflight, l;
    localparam S_IDLE=0, S_SER_ISSUE=1, S_SER_WAIT=2, S_STR=3, S_STR_DRAIN=4;
    reg [2:0] st;

    always @(posedge clk) begin
        if (reset) begin st<=S_IDLE; busy<=0; ras_in_valid_r<=0; inflight<=0; end
        else begin
            ras_in_valid_r<=0;

            // consumer (streamed): write at result coords every out_valid
            if (streamed && ras_out_valid) begin
                for (l=0;l<RAS_LANES;l=l+1)
                    if (ras_inside[l] && ras_pass[l]) begin
                        dt_depth[{27'd0,ras_oy}*TILE_W+{27'd0,ras_ox}+l] = ras_invw(l);
                        dt_tag[{27'd0,ras_oy}*TILE_W+{27'd0,ras_ox}+l] = tri_tag;
                    end
                /* verilator lint_off WIDTH */
            end
            if (streamed)
                inflight <= inflight + (ras_in_valid?1:0) - (ras_out_valid?1:0);

            case (st)
            S_IDLE: if (start) begin ras_x<=0; ras_y<=0; inflight<=0;
                        busy<=1; st<= streamed ? S_STR : S_SER_ISSUE; end

            // ---- serial ----
            S_SER_ISSUE: begin ras_in_valid_r<=1; st<=S_SER_WAIT; end
            S_SER_WAIT: if (ras_out_valid) begin
                for (l=0;l<RAS_LANES;l=l+1)
                    if (ras_inside[l] && ras_pass[l]) begin
                        dt_depth[{27'd0,ras_y}*TILE_W+{27'd0,ras_x}+l] = ras_invw(l);
                        dt_tag[{27'd0,ras_y}*TILE_W+{27'd0,ras_x}+l] = tri_tag;
                    end
                if (ras_x==5'(TILE_W-RAS_LANES)) begin
                    ras_x<=0;
                    if (ras_y==5'(TILE_H-1)) begin busy<=0; st<=S_IDLE; end
                    else begin ras_y<=ras_y+5'd1; st<=S_SER_ISSUE; end
                end else begin ras_x<=ras_x+5'(RAS_LANES); st<=S_SER_ISSUE; end
            end

            // ---- streamed ---- (ras_in_valid is combinational = st==S_STR)
            S_STR: begin
                if (ras_x==5'(TILE_W-RAS_LANES)) begin
                    ras_x<=0;
                    if (ras_y==5'(TILE_H-1)) st<=S_STR_DRAIN;
                    else ras_y<=ras_y+5'd1;
                end else ras_x<=ras_x+5'(RAS_LANES);
            end
            S_STR_DRAIN: if (inflight==0 && !ras_in_valid && !ras_out_valid) begin
                busy<=0; st<=S_IDLE;
            end
            /* verilator lint_on WIDTH */
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
