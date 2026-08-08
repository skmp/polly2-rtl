//
// reg_file - PVR register/table storage + write path, kept OUT of the top.
// Exposes:
//   * ALL scalar PVR registers (auto-generated from pvr_regs.h) as a pvr_regs_t
//     packed struct output - the top refers to them by name (regs.param_base,
//     regs.isp_backgnd_t.shadow, ...). Bitfield regs are typed structs.
//   * FOG table : M10K, 128 x 25-bit, own read port (fog_req/fog_resp). Entries are
//                 PRECOMPUTED on the write into the {base255, delta} pair fog_lut
//                 blends with one multiply; FOG_DENSITY is likewise pre-normalized
//                 to f32 (fog_den_f32) so no per-pixel unpack is needed.
//   * PAL RAM   : M10K, 1024 x 32-bit, FOUR read ports (pal_req[0:3]/pal_resp[0:3]) for
//                 the 4 bilinear-corner texture decoders. 4-copy replication (all copies
//                 take the same host writes), like tex_cache_4p_1c's 4-copy data.
//
// Write path: one 13-bit PVR BYTE offset (wr_addr) + wr_data + wr_en. Decode:
//   wr_addr < 0x0200            -> scalar register (generated PVR_REG_WRITE_CASE)
//   0x0200..0x03FC              -> FOG[(wr_addr>>2)-0x80]     (0..127)
//   0x1000..0x1FFC             -> PAL[(wr_addr>>2)-0x400]    (0..1023)
// Offsets mirror refsw pvr_regs.h. Tables read via their M10K ports; scalar regs
// are always live on `regs`.
//
module reg_file import tsp_pkg::*; (
    input                clk,
    input                reset,

    // write path (13-bit PVR byte offset)
    input                wr_en,
    input      [12:0]    wr_addr,
    input      [31:0]    wr_data,

    // all scalar registers (combinational struct output)
    output pvr_regs_t    regs,

    // FOG table read port (0..127), entries precomputed to {base255, delta}
    input  fog_rd_req_t  fog_req,
    output fog_rd_resp_t fog_resp,
    // FOG_DENSITY pre-normalized to IEEE-754 f32 (see the write-time convert below)
    output     [31:0]    fog_den_f32,
    // PAL RAM read ports (0..1023), one per bilinear corner decoder
    input  pal_rd_req_t  pal_req  [0:3],
    output pal_rd_resp_t pal_resp [0:3]
);
    // scalar register storage as a flat packed vector, aliased to the struct so
    // the generated write-case (which slices by bit position) and the struct
    // output view the same bits.
    localparam int W = 32 * PVR_REGS_N;
    reg  [W-1:0] r;
    assign regs = pvr_regs_t'(r);

    wire [10:0] woff   = wr_addr[12:2];
    wire        is_fog = (wr_addr >= OFF_FOG_TABLE_LO) && (wr_addr <= OFF_FOG_TABLE_HI);
    wire        is_pal = (wr_addr >= OFF_PAL_RAM_LO)   && (wr_addr <= OFF_PAL_RAM_HI);
    wire        is_scalar = (wr_addr < OFF_FOG_TABLE_LO);

    always @(posedge clk) begin
        if (reset) r <= '0;
        else if (wr_en && is_scalar) begin
            case (wr_addr)
            `PVR_REG_WRITE_CASE(r, wr_addr, wr_data)
            default: ; // unmapped scalar offset: ignored
            endcase
        end
    end

    // ---- FOG table (M10K, 128 x 25), PRECOMPUTED AT WRITE TIME ----
    // The host writes a 16-bit pair {b1,b0}; refsw2 blends it per pixel as
    //     alpha = (b0*bf + b1*(255-bf)) >> 8        (bf = the 8-bit blend factor)
    // which folds to  alpha = (b1*255 + (b0-b1)*bf) >> 8. Both b1*255 and b0-b1 are
    // functions of the ENTRY ALONE, so they are computed once here, on the write, and
    // the per-pixel path in fog_lut is a single 9x8 multiply + add. (Storing the pair
    // also costs less RAM than the raw word: 25 bits, not 32.)
    (* ramstyle = "M10K" *) reg [24:0] fog_mem [0:127];
    wire [7:0]        fog_b0 = wr_data[7:0];    // entry byte 0 (weighted by bf)
    wire [7:0]        fog_b1 = wr_data[15:8];   // entry byte 1 (weighted by 255-bf)
    wire [15:0]       fog_base255 = {fog_b1, 8'd0} - {8'd0, fog_b1};        // b1 * 255
    wire signed [8:0] fog_delta   = $signed({1'b0, fog_b0}) - $signed({1'b0, fog_b1});
    reg [24:0] fog_rd_r;
    always @(posedge clk) begin
        // 0x200>>2 = 0x80
        if (wr_en && is_fog) fog_mem[woff - 11'h080] <= {fog_delta, fog_base255};
        fog_rd_r <= fog_mem[fog_req.raddr];
    end
    assign fog_resp = fog_rd_resp_t'(fog_rd_r);

    // ---- FOG_DENSITY -> IEEE-754 f32, PRECOMPUTED AT WRITE TIME ----
    // FOG_DENSITY holds a {mantissa[15:8], exponent[7:0] signed} pair meaning
    //     fog_den = (mantissa / 128) * 2^exponent
    // (refsw2 LookupFogTable). Normalizing that to a float is a leading-zero count plus
    // a shift - per-render-constant work that has no business sitting in the per-pixel
    // path, so it happens once, here, and fog_lut just multiplies by it.
    //   mantissa = 0            -> +0.0 (fogW then clamps to 1.0, matching the reference)
    //   exponent out of range   -> flush to 0 / saturate, the fp units' own convention.
    reg [31:0] fog_den_r;
    reg [2:0]  fog_msb;          // index of the mantissa's leading 1 (7..0)
    reg signed [10:0] fog_e;     // unbiased exponent + bias
    wire [7:0]        fog_dm = wr_data[15:8];
    wire signed [8:0] fog_de = {wr_data[7], wr_data[7:0]};   // (s8)exponent
    integer fdi;
    always @(posedge clk) begin
        if (reset) fog_den_r <= 32'd0;
        else if (wr_en && (wr_addr == OFF_FOG_DENSITY)) begin
            fog_msb = 3'd0;
            for (fdi = 0; fdi < 8; fdi = fdi + 1)
                if (fog_dm[fdi]) fog_msb = fdi[2:0];
            // value = mantissa * 2^(exp-7) = 1.f * 2^(exp-7+msb)
            fog_e = 11'sd127 + {{2{fog_de[8]}}, fog_de} - 11'sd7 + {8'd0, fog_msb};
            if (fog_dm == 8'd0 || fog_e <= 0) fog_den_r <= 32'd0;                 // flush
            else if (fog_e >= 255)            fog_den_r <= {1'b0, 8'hFE, 23'h7FFFFF};
            else fog_den_r <= {1'b0, fog_e[7:0],
                               23'(({15'd0, fog_dm} << (23 - fog_msb)))};
        end
    end
    assign fog_den_f32 = fog_den_r;

    // ---- PAL RAM (M10K, 1024 x 32) - 4-copy replicated for 4 corner read ports. Each copy
    //      takes the SAME host write; each has its own registered read. The 4 copies are
    //      declared as ONE flattened [0:3][0:1023] memory written by a SINGLE always-block
    //      with a shared (address, data, enable) - the same SDP pattern tex_cache_4p_1c's
    //      4-copy data uses. Per-copy separate write always-blocks in a generate did NOT
    //      infer M10K (fell back to ~8.5k FFs -> no fit); this does. ----
    wire [9:0] pal_wa = 10'(woff - 11'h400);         // 0x1000>>2 = 0x400 base (10-bit index)
    wire       pal_we = wr_en && is_pal;
    (* ramstyle = "M10K" *) reg [31:0] pal_mem0 [0:1023];
    (* ramstyle = "M10K" *) reg [31:0] pal_mem1 [0:1023];
    (* ramstyle = "M10K" *) reg [31:0] pal_mem2 [0:1023];
    (* ramstyle = "M10K" *) reg [31:0] pal_mem3 [0:1023];
    reg [31:0] pal_rd0, pal_rd1, pal_rd2, pal_rd3;
    always @(posedge clk) begin
        if (pal_we) begin
            pal_mem0[pal_wa] <= wr_data;  pal_mem1[pal_wa] <= wr_data;
            pal_mem2[pal_wa] <= wr_data;  pal_mem3[pal_wa] <= wr_data;
        end
        pal_rd0 <= pal_mem0[pal_req[0].raddr];
        pal_rd1 <= pal_mem1[pal_req[1].raddr];
        pal_rd2 <= pal_mem2[pal_req[2].raddr];
        pal_rd3 <= pal_mem3[pal_req[3].raddr];
    end
    assign pal_resp[0].rdata = pal_rd0;
    assign pal_resp[1].rdata = pal_rd1;
    assign pal_resp[2].rdata = pal_rd2;
    assign pal_resp[3].rdata = pal_rd3;
endmodule
