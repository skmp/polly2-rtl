//
// reg_file - PVR register/table storage + write path, kept OUT of the top.
// Exposes:
//   * ALL scalar PVR registers (auto-generated from pvr_regs.h) as a pvr_regs_t
//     packed struct output - the top refers to them by name (regs.param_base,
//     regs.isp_backgnd_t.shadow, ...). Bitfield regs are typed structs.
//   * FOG table : M10K, 128 x 32-bit, own read port (fog_req/fog_resp).
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

    // FOG table read port (0..127)
    input  fog_rd_req_t  fog_req,
    output fog_rd_resp_t fog_resp,
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

    // ---- FOG table (M10K, 128 x 32) ----
    (* ramstyle = "M10K" *) reg [31:0] fog_mem [0:127];
    reg [31:0] fog_rd_r;
    always @(posedge clk) begin
        if (wr_en && is_fog) fog_mem[woff - 11'h080] <= wr_data;  // 0x200>>2 = 0x80
        fog_rd_r <= fog_mem[fog_req.raddr];
    end
    assign fog_resp.rdata = fog_rd_r;

    // ---- PAL RAM (M10K, 1024 x 32) - 4-copy replicated for 4 corner read ports. Each copy
    //      takes the SAME host write; each has its own registered read (like the tex cache). ----
    genvar pc;
    generate for (pc=0; pc<4; pc=pc+1) begin : palcopy
        (* ramstyle = "M10K" *) reg [31:0] pal_mem [0:1023];
        reg [31:0] pal_rd_r;
        always @(posedge clk) begin
            if (wr_en && is_pal) pal_mem[woff - 11'h400] <= wr_data;  // 0x1000>>2 = 0x400
            pal_rd_r <= pal_mem[pal_req[pc].raddr];
        end
        assign pal_resp[pc].rdata = pal_rd_r;
    end endgenerate
endmodule
