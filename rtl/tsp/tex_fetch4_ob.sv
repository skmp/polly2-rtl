//
// tex_fetch4_ob - 4-corner raw texel fetch (rewrite; output-buffered). 4 byte-offsets in -> 4 raw 64-bit
// memory words out. Owns the two shared 4-read-port caches (data + VQ) as its ONLY
// submodules; the whole fetch pipeline is inline (no tex_fetch_core, no tex_decode).
//
// Addressing. tex_addr / vq_addr are 64-BIT-WORD base addresses (21b, DC VRAM). The 4
// corner offsets are in BYTES (20b). So per corner:
//   data word addr = tex_addr + offset[21:3]      (offset byte, its 64-bit-word part)
//   byte lane      = offset[2:0]                   (byte-within-word; also the VQ lane)
//
// Behaviour per corner:
//   !TEX          : issue NO request; output undefined (this fetcher is unused).
//   TEX & !VQ     : one data-cache read -> output = that raw 64-bit word. VQ idle.
//   TEX &  VQ     : data-cache read -> memtel ; index = memtel[8*offset[2:0] +: 8] ;
//                   VQ-cache read at (vq_addr + index) -> output = that 64-bit word.
//
// STREAMING (verbatim discipline from tex_fetch_pp/_core): accepts a new request every
// cycle; the 4 corners run LOCKSTEP over the 1-cycle caches (freeze together on a
// miss-fill), so out_valid / in_ready track corner 0. No external stall - the unit
// asserts !in_ready (stall) while a cache is filling; the caller holds inputs stable.
//   T0 : present data-cache req ; accepted when tc ready
//   T1 : data word landed. If VQ, present VQ req NOW (codebook addr from the data word).
//   T2 : VQ word landed (VQ) / data word (non-VQ)  -> texel out
//
// Exposes TWO DDR read ports (tc, vq) to the parent arbiter.
//
module tex_fetch4_ob import tsp_pkg::*; (
    input             clk,
    input             reset,

    input             in_valid,
    input             tex,               // TEX: textured pixel
    input             vq,               // VQ:  VQ-compressed texture
    input      [20:0] tex_addr,          // data base (64-bit-word units)
    input      [20:0] vq_addr,           // VQ codebook base (64-bit-word units)
    input      [21:0] tex_offset [0:3],  // per-corner byte offsets (22b: up to 16bpp+mip)
    output            in_ready,          // 0 = stall (cache filling); hold inputs

    output            out_valid,
    output     [63:0] texel [0:3],       // raw 64-bit memory words (undefined if !tex)

    // two DDR read ports to the parent arbiter ([0]=tc data, [1]=vq codebook)
    output ddr_rd_req_t  ddr_req  [0:1],
    input  ddr_rd_resp_t ddr_resp [0:1]
);
    // shared 4-read-port caches (data + VQ)
    cache_req_t   tc_req [0:3], vq_req [0:3];
    cache_resp_t  tc_resp[0:3], vq_resp[0:3];
    tex_cache_4p_1c u_tc4 (.clk(clk),.reset(reset),
        .creq(tc_req),.cresp(tc_resp),.dreq(ddr_req[0]),.dresp(ddr_resp[0]));
    tex_cache_4p_1c u_vq4 (.clk(clk),.reset(reset),
        .creq(vq_req),.cresp(vq_resp),.dreq(ddr_req[1]),.dresp(ddr_resp[1]));

    // per-corner data-cache word address + VQ byte lane (combinational off inputs)
    wire [28:0] tc_waddr [0:3];
    wire [2:0]  vqlane   [0:3];
    genvar gi;
    generate for (gi=0; gi<4; gi=gi+1) begin : addr
        assign tc_waddr[gi] = {8'd0, tex_addr} + {10'd0, tex_offset[gi][21:3]};
        assign vqlane[gi]   = tex_offset[gi][2:0];
    end endgenerate

    // ============================================================================
    // Streaming pipeline, 4 corners lockstep. All corners share the accept/advance
    // decisions (they freeze together), so control is computed ONCE (corner 0's cache
    // readiness == all, since the 4-read-port cache gates all ports together).
    // ============================================================================
    // ---- T0: accepted request in flight (data read) ----
    reg        t0_v;
    reg        t0_tex, t0_vq;
    reg [20:0] t0_vqbase;
    reg [2:0]  t0_lane [0:3];
    reg [63:0] t0_mem  [0:3];   // held data word (captured when it lands)
    reg        t0_dv;           // data word captured

    // ---- T1: data word held; if VQ, issue VQ read ----
    reg        t1_v;
    reg        t1_tex, t1_vq;
    reg [20:0] t1_vqbase;
    reg [2:0]  t1_lane [0:3];
    reg [63:0] t1_mem  [0:3];   // data word (per corner)

    // ---- T2: resolved word (VQ codebook / data) -> output ----
    reg        t2_v;
    reg [63:0] t2_word [0:3];
    reg        t2_dv;           // t2_word holds the final word
    reg        t2_vq;

    integer i;

    // VQ codebook address per corner (from the HELD T1 data word + lane)
    wire [7:0]  t1_idx  [0:3];
    wire [28:0] t1_vqaddr [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : vqa
        assign t1_idx[gi]    = t1_mem[gi][ {t1_lane[gi], 3'd0} +: 8 ];   // byte lane*8
        assign t1_vqaddr[gi] = {8'd0, t1_vqbase} + {21'd0, t1_idx[gi]};
    end endgenerate

    // ---- per-stage advance (lockstep; gate on shared cache readiness) ----
    // data cache ready == tc_resp[0].ready (all 4 ports gate together); same for vq.
    wire tc_ready = tc_resp[0].ready;
    wire vq_ready = vq_resp[0].ready;
    wire tc_ack   = tc_resp[0].ack;
    wire vq_ack   = vq_resp[0].ack;

    // T2 -> out : T2 result "here" (non-VQ done on entry; VQ when codebook word lands).
    wire t2_here = t2_dv || (t2_v && t2_vq && vq_ack);
    wire t2_adv  = t2_v && t2_here;            // out_ready tied high -> always drains
    wire t2_free = !t2_v || t2_adv;

    // T1 -> T2 : VQ pixel needs its VQ read accepted; non-VQ advances immediately.
    wire vq_need = t1_v && t1_tex && t1_vq;
    wire t1_okvq = !vq_need || vq_ready;
    wire t1_adv  = t1_v && t1_okvq && t2_free;
    wire t1_free = !t1_v || t1_adv;

    // T0 -> T1 : data word here (bypass for !tex; captured; or landing this cycle).
    wire t0_bypass = t0_v && !t0_tex;
    wire t0_here   = t0_bypass || t0_dv || (t0_v && tc_ack);
    wire t0_adv    = t0_v && t0_here && t1_free;
    wire t0_free   = !t0_v || t0_adv;

    // ---- accept a new pixel: T0 free and (textured -> data cache ready) ----
    assign in_ready = t0_free && (!tex || tc_ready);
    wire   accept   = in_valid && in_ready;

    // ---- issue data-cache read (only textured pixels) ----
    generate for (gi=0; gi<4; gi=gi+1) begin : tcreq
        assign tc_req[gi].req   = accept && tex;
        assign tc_req[gi].waddr = tc_waddr[gi];
    end endgenerate

    // ---- issue VQ read (T1 VQ pixel, when it can advance into a free T2) ----
    generate for (gi=0; gi<4; gi=gi+1) begin : vqreq
        assign vq_req[gi].req   = vq_need && t2_free && vq_ready;
        assign vq_req[gi].waddr = t1_vqaddr[gi];
    end endgenerate

    // ---- output ----
    generate for (gi=0; gi<4; gi=gi+1) begin : out
        assign texel[gi] = t2_word[gi];
    end endgenerate
    assign out_valid = t2_v;

    // ---- data words to carry/capture (held or just-landed) ----
    wire [63:0] t0_word [0:3];
    generate for (gi=0; gi<4; gi=gi+1) begin : t0w
        assign t0_word[gi] = t0_dv ? t0_mem[gi] : tc_resp[gi].rdata;
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            t0_v<=0; t0_dv<=0; t1_v<=0; t2_v<=0; t2_dv<=0;
            t0_tex<=0; t0_vq<=0; t1_tex<=0; t1_vq<=0; t2_vq<=0;
            for (i=0;i<4;i=i+1) begin
                t0_mem[i]<=64'd0; t1_mem[i]<=64'd0; t2_word[i]<=64'd0;
                t0_lane[i]<=3'd0; t1_lane[i]<=3'd0;
            end
        end else begin
            // ---- in -> T0 ----
            if (accept) begin
                t0_v <= 1'b1; t0_dv <= 1'b0;
                t0_tex <= tex; t0_vq <= vq; t0_vqbase <= vq_addr;
                for (i=0;i<4;i=i+1) t0_lane[i] <= vqlane[i];
            end else if (t0_adv) t0_v <= 1'b0;

            // ---- T0 data-word capture (lands cycle after accept; hold it) ----
            if (t0_v && !t0_dv && tc_ack && !t0_adv) begin
                for (i=0;i<4;i=i+1) t0_mem[i] <= tc_resp[i].rdata;
                t0_dv <= 1'b1;
            end

            // ---- T0 -> T1 ----
            if (t0_adv) begin
                t1_v <= 1'b1; t1_tex <= t0_tex; t1_vq <= t0_vq; t1_vqbase <= t0_vqbase;
                for (i=0;i<4;i=i+1) begin t1_mem[i] <= t0_word[i]; t1_lane[i] <= t0_lane[i]; end
            end else if (t1_adv) t1_v <= 1'b0;

            // ---- T1 -> T2 : non-VQ done immediately (word = data); VQ awaits its ack ----
            if (t1_adv) begin
                t2_v <= 1'b1; t2_vq <= (t1_tex && t1_vq);
                t2_dv <= !(t1_tex && t1_vq);           // done unless VQ
                for (i=0;i<4;i=i+1) t2_word[i] <= t1_mem[i];   // data word (VQ overwrites below)
            end else if (t2_adv) t2_v <= 1'b0;

            // ---- T2 VQ capture: codebook word lands cycle after its read accepted ----
            if (t2_v && t2_vq && !t2_dv && vq_ack && !t2_adv) begin
                for (i=0;i<4;i=i+1) t2_word[i] <= vq_resp[i].rdata;
                t2_dv <= 1'b1;
            end
        end
    end
endmodule
