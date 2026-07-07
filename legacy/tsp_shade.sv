//
// tsp_shade - per-pixel TSP shading (1 pixel/request, stalls on DDR).
// Orchestrates verified blocks; the texel fetch is delegated to tex_fetch.
//   fp_rcp_fast          : W = 1/invW  (invW from depth buffer)
//   fp_mul_i5/add24/mul16: perspective interpolation of the 10 planes
//   tex_uvmap         : UV -> 4 corner texel coords + fractions
//   tex_fetch            : per-corner texel -> ARGB (addr/cache/VQ/palette/decode)
//   tex_filter           : nearest / bilinear
//   color_combiner       : texenv (ShadInstr) + offset
// No fog/clamp/blend/bump/mipmap. The two texture caches are INJECTED as bundle
// pairs and passed straight through to tex_fetch.
//
module tsp_shade import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             req,
    input      [4:0]  px,
    input      [4:0]  py,
    output reg        done,
    output reg [31:0] argb,

    input      [31:0] invw_in,               // depth-buffer invW for this pixel
    input      [31:0] p_ddx [0:9],
    input      [31:0] p_ddy [0:9],
    input      [31:0] p_c   [0:9],

    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    input             pp_texture,
    input             pp_offset,

    // injected caches (passed through to tex_fetch)
    output cache_req_t   tc_req,
    input  cache_resp_t  tc_resp,
    output cache_req_t   vq_req,
    input  cache_resp_t  vq_resp
);
    wire [2:0] texv=tsp[2:0], texu=tsp[5:3];
    wire [1:0] shadinstr=tsp[7:6], filtmode=tsp[14:13];
    wire clampv=tsp[15],clampu=tsp[16],flipv=tsp[17],flipu=tsp[18],ignoretexa=tsp[19];
    wire bilinear = (filtmode != 2'd0);

    // ---- FP interp units ----
    reg  [31:0] mi_f; reg [4:0] mi_k; wire [31:0] mi_y;
    fp_mul_i5 u_mi (.f(mi_f), .k(mi_k), .y(mi_y));
    reg  [31:0] mm_a, mm_b; wire [31:0] mm_y;
    fp_mul16  u_mm (.a(mm_a), .b(mm_b), .y(mm_y));
    // add split into two ~10ns halves (align | normalize) so each interp cycle
    // holds at most one; registered `ad_sum/ad_ebig/ad_sbig` between them.
    reg  [31:0] ad_a, ad_b; reg ad_s;
    wire [24:0] ad_sum_c; wire [7:0] ad_eb_c; wire ad_sb_c;
    fp_add24_s1 u_ad1 (.a(ad_a), .b_in(ad_b), .sub(ad_s),
                       .sum(ad_sum_c), .e_big(ad_eb_c), .s_big(ad_sb_c));
    reg [24:0] ad_sum; reg [7:0] ad_eb; reg ad_sb;
    wire [31:0] ad_y;
    fp_add24_s2 u_ad2 (.sum(ad_sum), .e_big(ad_eb), .s_big(ad_sb), .y(ad_y));
    reg        rc_req; reg [31:0] rc_in; wire rc_ack; wire [31:0] rc_y;
    fp_rcp_fast u_rc (.clk(clk),.reset(reset),.stall(1'b0),.in_valid(rc_req),.x(rc_in),
                      .out_valid(rc_ack),.y(rc_y));

    reg [31:0] Wp;
    reg [31:0] attr [0:9];

    // float -> u8 per colour/offset channel (attr planes 2..9), shared f2u8 module.
    wire [7:0] u8a [2:9];
    genvar gci;
    generate
      for (gci = 2; gci <= 9; gci = gci + 1) begin : cvt
        f2u8 u_c (.f(attr[gci]), .u(u8a[gci]));
      end
    endgenerate

    reg [3:0]  pidx; reg [2:0] istep;
    reg [31:0] t_ddx_x;

    // ---- uv -> texel corners (combinational; outputs registered below) ----
    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v; wire [7:0] ufrac,vfrac;
    tex_uvmap u_uv (
        .u(attr[0]), .v(attr[1]), .texu(texu), .texv(texv),
        .miplevel(4'd0),
        .clampu(clampu),.clampv(clampv),.flipu(flipu),.flipv(flipv),
        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),
        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(ufrac),.vfrac(vfrac));
    // registered uv2texel results (breaks the attr -> uv2texel -> ... -> argb chain)
    reg [10:0] r00u,r00v,r01u,r01v,r10u,r10v,r11u,r11v; reg [7:0] uf_r,vf_r;

    // ---- texel fetch (per corner) ----
    reg        tf_req; reg [10:0] tf_u, tf_v; wire tf_ack; wire [31:0] tf_argb;
    tex_fetch u_tf (
        .clk(clk),.reset(reset),.req(tf_req),.u(tf_u),.v(tf_v),
        .tsp(tsp),.tcw(tcw),.text_ctrl(text_ctrl),.ack(tf_ack),.argb(tf_argb),
        .tc_req(tc_req),.tc_resp(tc_resp),.vq_req(vq_req),.vq_resp(vq_resp));

    reg [31:0] corner [0:3];
    wire [31:0] t_filt;
    tex_filter u_flt (.filter(bilinear),.ignore_texa(ignoretexa),.ufrac(uf_r),.vfrac(vf_r),
                      .t00(corner[0]),.t01(corner[1]),.t10(corner[2]),.t11(corner[3]),.textel(t_filt));
    reg [31:0] textel_r;    // registered filter result (its own pipeline stage)

    reg [31:0] base_col, ofs_col;
    wire [31:0] comb_col;
    color_combiner u_cc (.pp_texture(pp_texture),.pp_offset(pp_offset),.shadinstr(shadinstr),
                         .base(base_col),.textel(textel_r),.offset(ofs_col),.col(comb_col));

    // ---- FSM ----
    localparam S_IDLE=0,S_IW=1,S_INTERP=2,S_TEXSEL=3,S_CSEL=4,S_CFETCH=5,
               S_CNEXT=6,S_FILT=9,S_COMB=7,S_DONE=8;
    reg [3:0] st;
    reg [1:0] corner_i;

    always @(posedge clk) begin
        if (reset) begin st<=S_IDLE; done<=0; rc_req<=0; tf_req<=0; end
        else begin
            done<=0; rc_req<=0; tf_req<=0;
            case (st)
            S_IDLE: if (req) begin rc_in<=invw_in; rc_req<=1; st<=S_IW; end
            S_IW: if (rc_ack) begin Wp<=rc_y; pidx<=0; istep<=0; st<=S_INTERP; end

            // Per-plane serial interp; the add is split (s1 align | s2 normalize)
            // across two isteps so no cycle holds a full fp_add24 (~19ns).
            //   a = (ddx*x + ddy*y + c) * W
            S_INTERP: begin
                case (istep)
                0: begin mi_f<=p_ddx[pidx]; mi_k<=px; istep<=1; end          // ddx*x
                1: begin t_ddx_x<=mi_y; mi_f<=p_ddy[pidx]; mi_k<=py; istep<=2; end // ddy*y
                2: begin ad_a<=t_ddx_x; ad_b<=mi_y; ad_s<=0; istep<=3; end   // add s1 in
                3: begin ad_sum<=ad_sum_c; ad_eb<=ad_eb_c; ad_sb<=ad_sb_c; istep<=4; end // s1->reg
                4: begin ad_a<=ad_y; ad_b<=p_c[pidx]; ad_s<=0; istep<=5; end // +c: add s1 in
                5: begin ad_sum<=ad_sum_c; ad_eb<=ad_eb_c; ad_sb<=ad_sb_c; istep<=6; end // s1->reg
                6: begin mm_a<=ad_y; mm_b<=Wp; istep<=7; end                 // *W
                7: begin attr[pidx]<=mm_y;
                        if (pidx==4'd9) st<=S_TEXSEL;
                        else begin pidx<=pidx+1; istep<=0; end
                    end
                endcase
            end

            // register the uv2texel results here (this cycle contains only the
            // uv2texel combinational block -> breaks the long chain into the
            // filter/combiner cycles below). Also pack base/offset colours.
            S_TEXSEL: begin
                base_col <= {u8a[5],u8a[4],u8a[3],u8a[2]};
                ofs_col  <= {u8a[9],u8a[8],u8a[7],u8a[6]};
                r00u<=c00u; r00v<=c00v; r01u<=c01u; r01v<=c01v;
                r10u<=c10u; r10v<=c10v; r11u<=c11u; r11v<=c11v;
                uf_r<=ufrac; vf_r<=vfrac;
                if (!pp_texture) begin textel_r<=32'h00000000; st<=S_COMB; end
                else begin corner_i<=2'd3; st<=S_CSEL; end   // t11 first (nearest)
            end

            // select corner (registered u,v) and issue fetch
            S_CSEL: begin
                case (corner_i)
                  2'd0: begin tf_u<=r00u; tf_v<=r00v; end
                  2'd1: begin tf_u<=r01u; tf_v<=r01v; end
                  2'd2: begin tf_u<=r10u; tf_v<=r10v; end
                  2'd3: begin tf_u<=r11u; tf_v<=r11v; end
                endcase
                tf_req<=1; st<=S_CFETCH;
            end
            S_CFETCH: if (tf_ack) begin corner[corner_i]<=tf_argb; st<=S_CNEXT; end
            S_CNEXT: begin
                if (!bilinear)            st<=S_FILT;   // nearest: only t11 needed
                else if (corner_i==2'd2)  st<=S_FILT;   // order 3,0,1,2 done
                else begin
                    corner_i <= (corner_i==2'd3)?2'd0:corner_i+2'd1;
                    st<=S_CSEL;
                end
            end

            // filter cycle (only tex_filter combinational) -> register result
            S_FILT: begin textel_r <= t_filt; st<=S_COMB; end
            // combiner cycle (only color_combiner combinational)
            S_COMB: begin argb<=comb_col; st<=S_DONE; end
            S_DONE: begin done<=1; st<=S_IDLE; end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
