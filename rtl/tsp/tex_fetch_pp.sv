//
// tex_fetch_pp - pipeline-friendly single-texel fetch/decode with stall.
//
// Same texel path as tex_fetch (tex_addr -> data-cache -> optional VQ codebook
// read -> palette/decode), but wrapped for a pipelined shader:
//
//   convention:
//     - clk
//     - inputs buffered by the caller (u/v/tsp/tcw/text_ctrl valid when in_valid)
//     - in_valid : a new texel request is presented this clock
//     - out_valid: this clock's argb corresponds to a completed fetch
//     - busy     : this unit is still working (miss in flight); the parent
//                  pipeline must STALL (hold all its registers) until !busy
//
// A texel takes >=1 cache round-trip, so this unit is not 1/clock on a miss.
// The parent (tsp_shade_pp) stalls its whole pipe while ANY texel port is busy;
// on cache hits the round-trip is short so throughput stays high after warmup.
//
// One transaction outstanding (matches tex_cache). Present in_valid only when
// !busy (the parent guarantees this via the shared stall).
//
module tex_fetch_pp import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             in_valid,
    input      [10:0] u,
    input      [10:0] v,
    input      [3:0]  miplevel,     // selected mip level (0 = base)
    input      [31:0] tsp,
    input      [31:0] tcw,
    input      [4:0]  text_ctrl,
    output reg        out_valid,
    output reg [31:0] argb,
    output            busy,

    // injected caches: data (texel/index) + VQ codebook
    output cache_req_t   tc_req,
    input  cache_resp_t  tc_resp,
    output cache_req_t   vq_req,
    input  cache_resp_t  vq_resp
);
    // latch the request fields at accept time so the address gen is stable
    reg [10:0] u_r, v_r;
    reg [3:0]  mip_r;
    reg [31:0] tsp_r, tcw_r_f;
    reg [4:0]  tc_r;

    wire [2:0] texu=tsp_r[5:3], texv=tsp_r[2:0];
    wire [20:0] tcw_addr=tcw_r_f[20:0];
    wire strdsel=tcw_r_f[25], scan=tcw_r_f[26];
    wire [2:0] pixfmt=tcw_r_f[29:27];
    wire vq=tcw_r_f[30];
    wire mipmapped=tcw_r_f[31];
    wire [5:0] palsel=tcw_r_f[26:21];

    // address gen (combinational, off the latched request). fbpp_shr is the byte-
    // offset shift amount (unused here; byte_addr already folds it in).
    wire [28:0] ta_byte; wire [2:0] ta_fbpp_shr; wire [19:0] ta_off;
    tex_addr u_ta (
        .tcw_addr(tcw_addr),.vq(vq),.scan(scan),.stride_sel(strdsel),.mipmapped(mipmapped),.pixfmt(pixfmt),
        .texu(texu),.texv(texv),.miplevel(mip_r),.text_ctrl(tc_r),.u(u_r),.v(v_r),
        .byte_addr(ta_byte),.fbpp_shr(ta_fbpp_shr),.offset(ta_off));

    // palette ROM placeholder (ARGB8888) - matches tex_fetch
    (* rom_style = "block" *) reg [31:0] pal_rom [0:255];
    integer pri;
    initial for (pri=0; pri<256; pri=pri+1)
        pal_rom[pri] = {8'hFF, pri[7:0], pri[7:0], pri[7:0]};   // grayscale placeholder
    reg [7:0] pal_idx; wire [31:0] pal_argb = pal_rom[pal_idx];

    // decode (combinational)
    reg [63:0] dec_memtel; reg [3:0] dec_off_lo;
    wire [31:0] dec_argb;
    tex_decode u_dec (.pixfmt(pixfmt),.scan(scan),.memtel(dec_memtel),
                      .offset_lo(dec_off_lo),.pal_argb(pal_argb),.argb(dec_argb));

    // palette index selection from the fetched line (before decode)
    wire [7:0]  pal8_local  = dec_memtel[8*ta_off[2:0] +: 8];
    wire [3:0]  pal4_nib    = dec_memtel[4*ta_off[3:0] +: 4];
    wire [7:0]  pal8_idx    = {palsel[5:4], pal8_local};
    wire [7:0]  pal4_idx    = {palsel[3:0], pal4_nib};

    localparam S_IDLE=0,S_RD=1,S_WAIT=2,S_VQ=3,S_VQW=4,S_DEC=5,S_ACK=6;
    reg [2:0] st;
    reg [2:0] vq_bytesel;

    reg        tcq_r, vqq_r; reg [28:0] tcw_r, vqw_r;
    assign tc_req.req = tcq_r; assign tc_req.waddr = tcw_r;
    assign vq_req.req = vqq_r; assign vq_req.waddr = vqw_r;

    // busy = a transaction is in flight (not idle), OR a new one is accepted this
    // clock. Combinational so the parent's stall is valid the same cycle it
    // presents in_valid.
    assign busy = (st != S_IDLE) || in_valid;

    always @(posedge clk) begin
        if (reset) begin st<=S_IDLE; out_valid<=0; tcq_r<=0; vqq_r<=0; end
        else begin
            out_valid<=0; tcq_r<=0; vqq_r<=0;
            case (st)
            S_IDLE: if (in_valid) begin
                // latch request; address gen (ta_byte) settles next clock
                u_r<=u; v_r<=v; mip_r<=miplevel; tsp_r<=tsp; tcw_r_f<=tcw; tc_r<=text_ctrl;
                st<=S_RD;
            end
            S_RD: begin
                // inputs latched: issue the data-cache read
                tcq_r <= 1'b1; tcw_r <= ta_byte[28:3];
                st <= S_WAIT;
            end
            S_WAIT: if (tc_resp.ack) begin
                dec_memtel <= tc_resp.rdata;
                dec_off_lo <= ta_off[3:0];
                vq_bytesel <= ta_byte[2:0];
                st <= vq ? S_VQ : S_DEC;
            end
            S_VQ: begin
                vqq_r <= 1;
                vqw_r <= {8'd0, tcw_addr} + dec_memtel[8*vq_bytesel +: 8];
                st <= S_VQW;
            end
            S_VQW: if (vq_resp.ack) begin
                dec_memtel <= vq_resp.rdata;
                st <= S_DEC;
            end
            S_DEC: begin
                if (pixfmt==3'd6) pal_idx <= pal8_idx;
                else if (pixfmt==3'd5) pal_idx <= pal4_idx;
                st <= S_ACK;
            end
            S_ACK: begin argb <= dec_argb; out_valid <= 1; st <= S_IDLE; end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
