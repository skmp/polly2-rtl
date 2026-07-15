//
// tile_engine_top - simple command-driven tile engine for simplex.
//
// A self-contained MiSTer-style top level. DDR3 is reached through the HPS
// SDRAM bridge (sysmem_lite, in rtl/mister/), NOT through FPGA pins - so this
// top has almost no external I/O. sysmem_lite provides the 100MHz core clock
// and the reset; the DC_MiSTer `ddram` controller (rtl/mister/ddram.sv) sits
// between it and the tile engine. A 7-bit command / 32-bit data interface
// drives the 32x32 tile pipeline.
//
//   Clock / reset:
//     - The whole design runs on `core_clk` (100MHz) from the HPS bridge.
//     - `reset_req` (async input) requests a core reset; `core_reset` is the
//       synchronous active-high reset actually used inside the design.
//     - `cold_req` maps to the HPS cold-reset button (DE10-nano has none on
//       GPIO), tie 0 if unused.
//
//   Command / data interface (synchronous to core_clk):
//     - cmd[6:0], data[31:0], cmd_valid : host drives cmd+data and pulses
//       cmd_valid=1 for one cycle to submit a command.
//     - cmd_done : output, goes 1 for one cycle *one clock before* the engine
//       is ready to accept a new command.
//     - ready    : level output, 1 while idle and able to accept a command.
//
//   Commands:
//     0..63   : write `data` into register file entry cmd[5:0].
//     64..127 : engine command (data ignored for now):
//       64 TILE_CLEAR           : depth/tag tile <= {REG_BG_DEPTH, REG_BG_TAG}
//       65 TRIANGLE_ISP_SETUP   : compute edge/invW-plane coeffs (isp_setup_min)
//       66 TRIANGLE_ISP_RASTERIZE: opaque; one line/clock, depth test + tag write
//       67 TRIANGLE_TSP_SETUP    : compute 10 interp planes (tsp_setup_min)
//       68 TRIANGLE_TSP_SHADE    : nop
//       69 TILE_DRAW_TAGS        : color[y][x] <= {8'hFF, tag[y][x]}
//       70 TILE_FLUSH            : color tile -> DDR3 at REG_TILE_BASE + y*32+x
//
// The depth/tag buffer holds {32-bit depth, 24-bit tag}; the color buffer holds
// a 32-bit color per pixel. Both are 32x32 (1024 entries).
//
module tile_engine_top import tsp_pkg::*; #(
    parameter integer TILE_W   = 32,
    parameter integer TILE_H   = 32,
    parameter integer TAG_BITS = 24
) (
    // ---- HPS reset control (no DDR3 pins: DDR3 is on the HPS) ----
    input             reset_req,   // async: request a core reset
    input             cold_req,    // HPS cold-reset button (tie 0 if unused)
    output            core_clk,    // 100MHz core clock (from HPS bridge)
    output            core_reset,  // active-high synchronous core reset

    // ---- command / data interface ----
    // Two access paths share the cmd_valid/cmd_done/ready handshake:
    //   * register write : reg_we=1, reg_addr[9:0] selects one of 1024 PVR regs,
    //                       data is the value. Completes in one cycle.
    //   * command        : cmd_stb=1, cmd[6:0] is the opcode (see CMD_* below).
    // For backward compatibility the LEGACY encoding is still accepted: when
    // neither reg_we nor cmd_stb is driven, cmd[6]==0 => write reg cmd[5:0],
    // cmd[6]==1 => run command cmd[6:0]. (co-sim submit() uses the legacy form.)
    input      [6:0]  cmd,
    input      [31:0] data,
    input      [9:0]  reg_addr,    // full 1024-register index (when reg_we)
    input             reg_we,      // 1: this cmd_valid is a wide register write
    input             cmd_stb,     // 1: this cmd_valid is a command opcode
    input             cmd_valid,   // 1-cycle strobe: submit cmd+data
    output reg        cmd_done,    // 1-cycle pulse, one clock before ready
    output            ready        // level: idle and able to accept a command
);
    localparam integer N_PIX   = TILE_W * TILE_H;         // 1024
    localparam integer IDX_W   = $clog2(N_PIX);           // 10
    localparam integer XW      = $clog2(TILE_W);          // 5
    localparam integer YW      = $clog2(TILE_H);          // 5
    localparam [IDX_W-1:0] LAST_IDX = IDX_W'(N_PIX - 1);  // last pixel index

    // ---- register file (full 1024 PVR registers) ----
    reg [31:0] regs [0:1023];

    // Named registers (indices are part of the host ABI). Low indices keep the
    // original 6-bit values so the legacy cmd[5:0] write path still targets them.
    localparam REG_BG_DEPTH = 10'd0;
    localparam REG_BG_TAG   = 10'd1;
    localparam REG_TILE_BASE= 10'd2;

    // ISP triangle setup inputs (host writes these before CMD_TRIANGLE_ISP_SETUP)
    localparam REG_X1 = 6'd8,  REG_Y1 = 6'd9,  REG_Z1 = 6'd10;
    localparam REG_X2 = 6'd11, REG_Y2 = 6'd12, REG_Z2 = 6'd13;
    localparam REG_X3 = 6'd14, REG_Y3 = 6'd15, REG_Z3 = 6'd16;
    localparam REG_X_BASE = 6'd17, REG_Y_BASE = 6'd18;   // tile origin (screen)
    localparam REG_ISP_WORD = 6'd19;                     // params->isp (Cull/Depth/ZWrite)
    localparam REG_ISP_TAG  = 6'd20;                     // parameter_tag_t written on pass

    // TSP triangle setup inputs (host writes before CMD_TRIANGLE_TSP_SETUP).
    // TSP has its OWN vertices (separate from the ISP ones above).
    localparam REG_T_X1=6'd24, REG_T_Y1=6'd25, REG_T_Z1=6'd26;
    localparam REG_T_X2=6'd27, REG_T_Y2=6'd28, REG_T_Z2=6'd29;
    localparam REG_T_X3=6'd30, REG_T_Y3=6'd31, REG_T_Z3=6'd32;
    localparam REG_T_U1=6'd33, REG_T_V1=6'd34, REG_T_U2=6'd35, REG_T_V2=6'd36, REG_T_U3=6'd37, REG_T_V3=6'd38;
    localparam REG_T_COL1=6'd39, REG_T_COL2=6'd40, REG_T_COL3=6'd41;   // packed ARGB
    localparam REG_T_OFS1=6'd42, REG_T_OFS2=6'd43, REG_T_OFS3=6'd44;   // packed offset
    localparam REG_ISP_TSP=6'd45, REG_TSP=6'd46, REG_TCW=6'd47;        // TA words
    // TSP shade (CMD_TRIANGLE_TSP_SHADE)
    localparam REG_TSP_SHADE_TAG=6'd48;   // per-pixel tag to shade (compare)
    localparam REG_TEXT_CTRL    =6'd49;   // TEXT_CONTROL (stride unit, low 5b)
    localparam REG_TAG          =6'd50;   // TAG register (per spec)

    // Convenient reads of the input registers (assign-from-regs style).
    wire [31:0] isp_x1 = regs[REG_X1], isp_y1 = regs[REG_Y1], isp_z1 = regs[REG_Z1];
    wire [31:0] isp_x2 = regs[REG_X2], isp_y2 = regs[REG_Y2], isp_z2 = regs[REG_Z2];
    wire [31:0] isp_x3 = regs[REG_X3], isp_y3 = regs[REG_Y3], isp_z3 = regs[REG_Z3];
    wire [31:0] isp_xbase = regs[REG_X_BASE], isp_ybase = regs[REG_Y_BASE];
    wire [31:0] isp_word  = regs[REG_ISP_WORD];

    // TSP: the isp_tsp word carries the Gouraud/Texture/Offset flags for setup.
    wire        tsp_gouraud = regs[REG_ISP_TSP][23];
    wire        tsp_offset  = regs[REG_ISP_TSP][24];
    wire        tsp_texture = regs[REG_ISP_TSP][25];

    // ---- command opcodes ----
    localparam CMD_TILE_CLEAR            = 7'd64;
    localparam CMD_TRIANGLE_ISP_SETUP    = 7'd65;
    localparam CMD_TRIANGLE_ISP_RASTERIZE= 7'd66;
    localparam CMD_TRIANGLE_TSP_SETUP    = 7'd67;
    localparam CMD_TRIANGLE_TSP_SHADE    = 7'd68;
    localparam CMD_TILE_DRAW_TAGS        = 7'd69;
    localparam CMD_TILE_FLUSH            = 7'd70;
    localparam CMD_START_RENDER          = 7'd71;   // autonomous whole-tile render

    // ---- upper-bank PVR registers (only reachable via the wide reg_addr path) ----
    localparam REG_PARAM_BASE   = 10'd64;   // VRAM byte base of the param buffer
    localparam REG_OBJLIST_PTR  = 10'd65;   // object-list pointer (byte addr) for START_RENDER
    localparam REG_REGION_BASE  = 10'd66;   // (reserved) region-array base

    // ---- tile buffers (block RAM, banked) ----
    // Both buffers are NBANKS single-port M10K banks so a NBANKS-pixel span of a
    // scanline is accessed per clock while still mapping to block RAM. See
    // tile_ram: bank = x[BW-1:0], addr = {y, x[4:BW]}.
    localparam integer NBANKS = 8;
    localparam integer DTW    = 32 + TAG_BITS;   // depth+tag width (56)

    // depth/tag RAM. Addresses are driven COMBINATIONALLY from the FSM's state
    // registers so a registered-read RAM returns the addressed entry on the next
    // clock (addr valid in cycle N -> rdata valid N+1). we/wdata are registered.
    reg  [NBANKS-1:0]      dt_we;
    reg  [7*NBANKS-1:0]    dt_addr;
    reg  [DTW*NBANKS-1:0]  dt_wdata;
    wire [DTW*NBANKS-1:0]  dt_rdata;
    tile_ram #(.WIDTH(DTW), .NBANKS(NBANKS)) u_dt (
        .clk(clk_100m), .we(dt_we), .addr(dt_addr), .wdata(dt_wdata), .rdata(dt_rdata));

    // color RAM
    reg  [NBANKS-1:0]      col_we;
    reg  [7*NBANKS-1:0]    col_addr;
    reg  [32*NBANKS-1:0]   col_wdata;
    wire [32*NBANKS-1:0]   col_rdata;
    tile_ram #(.WIDTH(32), .NBANKS(NBANKS)) u_col (
        .clk(clk_100m), .we(col_we), .addr(col_addr), .wdata(col_wdata), .rdata(col_rdata));

    // pixel (x,y) -> {bank, addr}. bank = x[2:0], addr = {y, x[4:3]}.
    function [2:0] pix_bank(input [4:0] x);           pix_bank = x[2:0]; endfunction
    function [6:0] pix_addr(input [4:0] x, input [4:0] y); pix_addr = {y, x[4:3]}; endfunction

    // linear-index split helpers (for the CLEAR/DRAWTAGS/FLUSH iterators)
    wire [XW-1:0] idx_x;
    wire [YW-1:0] idx_y;

    // ------------------------------------------------------------------
    // HPS DDR3 bridge + ddram controller
    // ------------------------------------------------------------------
    // sysmem_lite is the HPS f2sdram bridge (cyclonev_hps_interface_* hard IP).
    // It gives us the core clock + reset and three Avalon RAM ports; we use
    // ram1. DDR3 therefore lives on the HPS - no top-level DDRAM pins.
    wire         clk_100m;
    wire         reset_100m;   // active-high, from bridge

    assign core_clk   = clk_100m;
    assign core_reset = reset_100m;

    // ddram <-> bridge (ram1) Avalon wiring, all internal (no pins)
    wire        ram_clk;
    wire        ram_busy;         // ram1_waitrequest
    wire  [7:0] ram_burstcnt;
    wire [28:0] ram_addr;
    wire [63:0] ram_readdata;
    wire        ram_readdatavalid;
    wire        ram_rd;
    wire [63:0] ram_writedata;
    wire  [7:0] ram_byteenable;
    wire        ram_we;

    sysmem_lite u_sysmem (
        .reset_core_req    (reset_req),
        .reset_out         (reset_100m),
        .clock             (clk_100m),
        .reset_hps_cold_req(cold_req),
        .reset_hps_warm_req(1'b0),

        // ram1 : driven by ddram controller below
        .ram1_clk          (ram_clk),
        .ram1_address      (ram_addr),
        .ram1_burstcount   (ram_burstcnt),
        .ram1_waitrequest  (ram_busy),
        .ram1_readdata     (ram_readdata),
        .ram1_readdatavalid(ram_readdatavalid),
        .ram1_read         (ram_rd),
        .ram1_writedata    (ram_writedata),
        .ram1_byteenable   (ram_byteenable),
        .ram1_write        (ram_we),

        // ram2 : texture read channel (driven by tex_mem under SYNTHESIS)
        .ram2_clk          (clk_100m),
        .ram2_address      (tex_ram2_address),
        .ram2_burstcount   (tex_ram2_burstcount),
        .ram2_waitrequest  (tex_ram2_waitrequest),
        .ram2_readdata     (tex_ram2_readdata),
        .ram2_readdatavalid(tex_ram2_readdatavalid),
        .ram2_read         (tex_ram2_read),
        .ram2_writedata    (64'd0),
        .ram2_byteenable   (8'd0),
        .ram2_write        (1'b0),

        // vbuf : unused
        .vbuf_clk          (clk_100m),
        .vbuf_address      (28'd0),
        .vbuf_burstcount   (8'd0),
        .vbuf_waitrequest  (),
        .vbuf_readdata     (),
        .vbuf_readdatavalid(),
        .vbuf_read         (1'b0),
        .vbuf_writedata    (128'd0),
        .vbuf_byteenable   (16'd0),
        .vbuf_write        (1'b0)
    );

    // ---- DDR3 controller instance ----
    // simple side of the DC_MiSTer ddram wrapper:
    //   mem_addr[27:1] word address, mem_din/mem_dout 32-bit, mem_wr 4-bit BE.
    reg  [27:1] mem_addr;
    reg  [31:0] mem_din;
    reg         mem_rd;
    reg  [3:0]  mem_wr;
    reg  [1:0]  mem_chan;
    wire [31:0] mem_dout;
    wire        mem_busy;

    ddram u_ddram (
        .DDRAM_CLK       (ram_clk),
        .DDRAM_BUSY      (ram_busy),
        .DDRAM_BURSTCNT  (ram_burstcnt),
        .DDRAM_ADDR      (ram_addr),
        .DDRAM_DOUT      (ram_readdata),
        .DDRAM_DOUT_READY(ram_readdatavalid),
        .DDRAM_RD        (ram_rd),
        .DDRAM_DIN       (ram_writedata),
        .DDRAM_BE        (ram_byteenable),
        .DDRAM_WE        (ram_we),

        .clk     (clk_100m),
        .mem_addr(mem_addr),
        .mem_dout(mem_dout),
        .mem_din (mem_din),
        .mem_rd  (mem_rd),
        .mem_wr  (mem_wr),
        .mem_chan(mem_chan),
        .mem_16b (1'b0),
        .mem_busy(mem_busy)
    );

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    localparam [4:0]
        S_IDLE      = 5'd0,
        S_CLEAR     = 5'd1,
        S_DRAWTAGS  = 5'd2,
        S_FLUSH_RD  = 5'd3,  // present pixel, issue write
        S_FLUSH_WAIT= 5'd4,  // wait for ddram to accept (not busy)
        S_ISP_SETUP = 5'd6,  // wait for isp_setup_min to finish
        S_ISP_RASTER= 5'd7,  // rasterize a chunk (read phase)
        S_TSP_SETUP = 5'd8,  // wait for tsp_setup_min to finish
        S_DRAW_RD   = 5'd9,  // draw-tags: present dt read addr
        S_RAS_WR    = 5'd10, // rasterize: depth-compare + write-back phase
        S_RAS_WAIT  = 5'd11, // rasterize: wait for pipelined line eval
        S_SH_RD     = 5'd12, // shade: present dt read addr for pixel
        S_SH_CMP    = 5'd13, // shade: dt_rdata valid -> tag compare, invW
        S_SH_RUN    = 5'd14, // shade: wait tsp_shade done
        S_SH_WR     = 5'd15, // shade: write colour, advance pixel
        S_DONE      = 5'd5;

    reg [4:0]       state;
    reg [IDX_W-1:0] idx;         // pixel iterator (0..N_PIX-1)
    integer         bi;          // rasterizer per-bank loop var
    assign idx_x = idx[XW-1:0];
    assign idx_y = idx[IDX_W-1:XW];

    // pipelined-RMW helpers (block-RAM read latency)
    reg [2:0]  dr_bank; reg [6:0] dr_addr; reg dr_last;   // draw-tags read->write
    reg [2:0]  fl_bank;                                    // flush read bank

    // 32-bit word address for the current flush pixel: REG_TILE_BASE + idx.
    wire [31:0] word32_addr = regs[REG_TILE_BASE] + {{(32-IDX_W){1'b0}}, idx};

    assign ready = (state == S_IDLE);

    // ------------------------------------------------------------------
    // Combinational RAM control drive (we / addr / wdata all together, so a
    // registered-read/write RAM samples a consistent set at the clock edge).
    // Read addr valid in cycle N -> rdata valid N+1, consumed in the adjacent
    // state. Writes take effect at the edge leaving the state that asserts we.
    //  CLEAR      : dt  write @ idx           (bank idx[2:0])
    //  DRAW_RD    : dt  read  @ idx           -> S_DRAWTAGS consumes rdata
    //  DRAWTAGS   : col write @ dr (from rdata) + dt read @ idx (pipeline next)
    //  FLUSH_RD   : col read  @ idx           -> S_FLUSH_WAIT consumes
    //  ISP_RASTER : dt  read  @ chunk         -> S_RAS_WR consumes rdata
    //  RAS_WR     : dt  write @ chunk (pass lanes), same addr as the read
    integer ai;
    always @(*) begin
        dt_we = '0; dt_addr = '0; dt_wdata = '0;
        col_we = '0; col_addr = '0; col_wdata = '0;
        case (state)
        S_CLEAR: begin
            dt_we[idx[2:0]]               = 1'b1;
            dt_addr [7*idx[2:0] +: 7]     = idx[9:3];
            dt_wdata[DTW*idx[2:0] +: DTW] = {regs[REG_BG_DEPTH], regs[REG_BG_TAG][TAG_BITS-1:0]};
        end
        S_DRAW_RD:  dt_addr[7*idx[2:0] +: 7] = idx[9:3];
        S_DRAWTAGS: begin
            dt_addr[7*idx[2:0] +: 7] = idx[9:3];              // pipeline next read
            col_we[dr_bank]              = 1'b1;
            col_addr [7*dr_bank +: 7]    = dr_addr;
            col_wdata[32*dr_bank +: 32]  = {8'hFF, dt_rdata[DTW*dr_bank + TAG_BITS-1 -: TAG_BITS]};
        end
        S_FLUSH_RD: col_addr[7*idx[2:0] +: 7] = idx[9:3];
        // shade: present dt read (pixel = idx) so S_SH_CMP has tag+invW.
        S_SH_RD, S_SH_CMP, S_SH_RUN: dt_addr[7*idx[2:0] +: 7] = idx[9:3];
        S_SH_WR: begin
            col_we[idx[2:0]]             = 1'b1;
            col_addr[7*idx[2:0] +: 7]    = idx[9:3];
            col_wdata[32*idx[2:0] +: 32] = sh_argb;
        end
        S_ISP_RASTER, S_RAS_WAIT:
            for (ai = 0; ai < NBANKS; ai = ai + 1)
                dt_addr[7*ai +: 7] = pix_addr(ras_x + ai[4:0], ras_y);
        S_RAS_WR:
            for (ai = 0; ai < NBANKS; ai = ai + 1) begin
                dt_addr[7*ai +: 7] = pix_addr(ras_x + ai[4:0], ras_y);
                if (ras_inside[ai] && ras_pass[ai]) begin
                    dt_we[ai]              = 1'b1;
                    dt_wdata[DTW*ai +: DTW] = {
                        zwrite_dis ? dt_rdata[DTW*ai + DTW-1 -: 32] : ras_invw(ai),
                        regs[REG_ISP_TAG][TAG_BITS-1:0] };
                end
            end
        default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // ISP triangle setup (CMD_TRIANGLE_ISP_SETUP)
    // ------------------------------------------------------------------
    // 4-lane, ~14-cycle, minimal-DSP setup. invW plane only. Tile-local:
    // C1..C4 / c_invw anchored at (REG_X_BASE, REG_Y_BASE). Reduced precision
    // (16-bit-mantissa mults, ~24-bit adds, cheap 1/x). Outputs are latched into
    // the isp_* result registers below for the rasterizer to consume.
    reg         isp_start;
    wire        isp_done;
    wire        isp_sgn_neg, isp_cull;
    wire [31:0] w_dx12,w_dx23,w_dx31,w_dx41, w_dy12,w_dy23,w_dy31,w_dy41;
    wire [31:0] w_c1,w_c2,w_c3,w_c4, w_ddx,w_ddy,w_cinvw;

    isp_setup_min u_isp (
        .clk(clk_100m), .reset(reset_100m), .start(isp_start), .done(isp_done),
        .isp_word(isp_word),
        .x1(isp_x1), .y1(isp_y1), .z1(isp_z1),
        .x2(isp_x2), .y2(isp_y2), .z2(isp_z2),
        .x3(isp_x3), .y3(isp_y3), .z3(isp_z3),
        .xbase(isp_xbase), .ybase(isp_ybase),
        .sgn_neg(isp_sgn_neg), .cull(isp_cull),
        .dx12(w_dx12), .dx23(w_dx23), .dx31(w_dx31), .dx41(w_dx41),
        .dy12(w_dy12), .dy23(w_dy23), .dy31(w_dy31), .dy41(w_dy41),
        .c1(w_c1), .c2(w_c2), .c3(w_c3), .c4(w_c4),
        .ddx_invw(w_ddx), .ddy_invw(w_ddy), .c_invw(w_cinvw)
    );

    // Latched setup results (the inner-loop rasterizer consumes these).
    reg        isp_r_sgn_neg, isp_r_cull;
    reg [31:0] isp_dx12,isp_dx23,isp_dx31,isp_dx41;
    reg [31:0] isp_dy12,isp_dy23,isp_dy31,isp_dy41;
    reg [31:0] isp_c1,isp_c2,isp_c3,isp_c4;
    reg [31:0] isp_ddx_invw, isp_ddy_invw, isp_c_invw;

    // ------------------------------------------------------------------
    // ISP rasterize (CMD_TRIANGLE_ISP_RASTERIZE) - opaque only.
    // ------------------------------------------------------------------
    // Processes RAS_LANES pixels per clock. isp_raster_line evaluates the
    // Xhs/invW of RAS_LANES consecutive pixels [ras_x .. ras_x+RAS_LANES-1]
    // combinationally; per inside-pixel we run the opaque DepthMode test and, on
    // pass, write invW depth + tag into those banks (all in the same clock).
    // The FSM sweeps ras_x across the line in TILE_W/RAS_LANES chunks.
    // Set RAS_LANES back to TILE_W (32) to restore whole-line-per-clock.
    localparam integer RAS_LANES = 8;
    reg  [4:0]  ras_y;                 // current line (0..31)
    reg  [4:0]  ras_x;                 // first pixel of the current chunk
    reg         ras_in_valid;          // issue this chunk into the pipeline
    wire        ras_out_valid;         // pipeline results ready
    wire [RAS_LANES-1:0]    ras_inside;
    wire [32*RAS_LANES-1:0] ras_invw_flat;
    // per-lane invW slice (function avoids an unpacked wire array + generate)
    function [31:0] ras_invw(input integer lane);
        ras_invw = ras_invw_flat[32*lane +: 32];
    endfunction

    isp_raster_line #(.LANES(RAS_LANES)) u_line (
        .clk(clk_100m), .reset(reset_100m),
        .in_valid(ras_in_valid), .y(ras_y), .x_base(ras_x),
        .c1(isp_c1), .c2(isp_c2), .c3(isp_c3), .c4(isp_c4),
        .dx12(isp_dx12),.dx23(isp_dx23),.dx31(isp_dx31),.dx41(isp_dx41),
        .dy12(isp_dy12),.dy23(isp_dy23),.dy31(isp_dy31),.dy41(isp_dy41),
        .ddx(isp_ddx_invw),.ddy(isp_ddy_invw),.c_invw(isp_c_invw),
        .out_valid(ras_out_valid),
        .inside_mask(ras_inside),
        .invw_flat(ras_invw_flat),
        // this top uses the non-streamed FSM (issue chunk, wait, RMW at ras_x/y),
        // so the echoed result coords are unused here.
        .out_x(), .out_y()
    );

    // opaque DepthMode compare per rasterizer lane: does the lane's new invW
    // pass against the stored depth in its bank? (isp_depth_cmp, refsw modes)
    wire [RAS_LANES-1:0] ras_pass;
    genvar gd;   // declared out-of-line (Quartus Standard rejects inline for-genvar)
    generate
        for (gd = 0; gd < RAS_LANES; gd = gd + 1) begin : dcmp
            isp_depth_cmp u_cmp (
                .peel(1'b0), .tag(32'h0), .zb2(32'h0), .pb(32'h0), .pb2(32'h0),
                .valid(1'b0), .more(),
                .mode(depth_mode),
                .nw  (ras_invw_flat[32*gd +: 32]),
                .zb  (dt_rdata[DTW*gd + DTW-1 -: 32]),
                .pass(ras_pass[gd]));
        end
    endgenerate

    // ISP_TSP word bitfields (refsw core_structs ISP layout, LSB-first):
    //  [22]UV_16b [23]Gouraud [24]Offset [25]Texture [26]ZWriteDis
    //  [28:27]CullMode [31:29]DepthMode
    wire [2:0] depth_mode = isp_word[31:29];
    wire       zwrite_dis = isp_word[26];

    // ------------------------------------------------------------------
    // TSP FPU setup (CMD_TRIANGLE_TSP_SETUP)
    // ------------------------------------------------------------------
    // Produces the 10 interpolation planes (U,V, base Col RGBA, offset Ofs RGBA)
    // in PlaneStepper {ddx,ddy,c} form, streamed out one per plane_valid pulse.
    // Latched into isp-plane result registers for the (future) TSP shade step.
    reg         tsp_start;
    wire        tsp_done, tsp_pvalid;
    wire [3:0]  tsp_pidx;
    wire [31:0] tsp_pddx, tsp_pddy, tsp_pc;

    tsp_setup_min u_tsp (
        .clk(clk_100m), .reset(reset_100m), .start(tsp_start), .done(tsp_done),
        .gouraud(tsp_gouraud), .texture(tsp_texture), .offset(tsp_offset),
        .x1(regs[REG_T_X1]),.y1(regs[REG_T_Y1]),.z1(regs[REG_T_Z1]),
        .x2(regs[REG_T_X2]),.y2(regs[REG_T_Y2]),.z2(regs[REG_T_Z2]),
        .x3(regs[REG_T_X3]),.y3(regs[REG_T_Y3]),.z3(regs[REG_T_Z3]),
        .xbase(isp_xbase), .ybase(isp_ybase),
        .u1(regs[REG_T_U1]),.v1(regs[REG_T_V1]),.u2(regs[REG_T_U2]),.v2(regs[REG_T_V2]),
        .u3(regs[REG_T_U3]),.v3(regs[REG_T_V3]),
        .col1(regs[REG_T_COL1]),.col2(regs[REG_T_COL2]),.col3(regs[REG_T_COL3]),
        .ofs1(regs[REG_T_OFS1]),.ofs2(regs[REG_T_OFS2]),.ofs3(regs[REG_T_OFS3]),
        .plane_valid(tsp_pvalid), .plane_idx(tsp_pidx),
        .o_ddx(tsp_pddx), .o_ddy(tsp_pddy), .o_c(tsp_pc)
    );

    // Latched TSP planes: index 0=U 1=V 2..5=Col 6..9=Ofs; each {ddx,ddy,c}.
    reg [31:0] tsp_ddx [0:9];
    reg [31:0] tsp_ddy [0:9];
    reg [31:0] tsp_c   [0:9];
    always @(posedge clk_100m) begin
        if (tsp_pvalid) begin
            tsp_ddx[tsp_pidx] <= tsp_pddx;
            tsp_ddy[tsp_pidx] <= tsp_pddy;
            tsp_c  [tsp_pidx] <= tsp_pc;
        end
    end

    // ------------------------------------------------------------------
    // TSP shade datapath (CMD_TRIANGLE_TSP_SHADE): 2 texture caches fed by
    // tex_mem, tsp_shade orchestrating the per-pixel pipeline.
    // ------------------------------------------------------------------
    // HPS ram2 texture read channel (driven by tex_mem under SYNTHESIS; tied off
    // in sim where tex_mem serves a behavioural VRAM instead).
    wire [28:0] tex_ram2_address;
    wire [7:0]  tex_ram2_burstcount;
    wire        tex_ram2_read;
`ifdef SYNTHESIS
    wire        tex_ram2_waitrequest, tex_ram2_readdatavalid;
    wire [63:0] tex_ram2_readdata;
`else
    wire        tex_ram2_waitrequest   = 1'b0;
    wire        tex_ram2_readdatavalid = 1'b0;
    wire [63:0] tex_ram2_readdata      = 64'd0;
`endif

    // cache <-> tex_mem DDR bundles
    ddr_rd_req_t  dc_dreq, qc_dreq;
    ddr_rd_resp_t dc_dresp, qc_dresp;
    // tex_fetch/shade <-> cache client bundles
    cache_req_t   dc_creq, qc_creq;
    cache_resp_t  dc_cresp, qc_cresp;

    tex_cache u_dcache (.clk(clk_100m),.reset(reset_100m),
        .creq(dc_creq),.cresp(dc_cresp),.dreq(dc_dreq),.dresp(dc_dresp));
    tex_cache u_qcache (.clk(clk_100m),.reset(reset_100m),
        .creq(qc_creq),.cresp(qc_cresp),.dreq(qc_dreq),.dresp(qc_dresp));

    // ISP/TSP param data caches (32-byte line). Client ports are driven by the
    // object-list parser (ISP$) and the plane cache (TSP$) in later stages; for
    // now they sit idle. Both share the tex_mem 4-port arbiter.
    // These two tex_mem ISP$/TSP$ read ports are unused in this legacy top; idle
    // them (no data_cache256 - that module has been removed).
    ddr_rd_req_t  ispd_dreq, tspd_dreq;
    ddr_rd_resp_t ispd_dresp, tspd_dresp;
    assign ispd_dreq = '0;
    assign tspd_dreq = '0;

    tex_mem u_texmem (.clk(clk_100m),.reset(reset_100m),
        .d_dreq(dc_dreq),.d_dresp(dc_dresp),.q_dreq(qc_dreq),.q_dresp(qc_dresp),
        .i_dreq(ispd_dreq),.i_dresp(ispd_dresp),.t_dreq(tspd_dreq),.t_dresp(tspd_dresp)
`ifdef SYNTHESIS
        ,.ram2_address(tex_ram2_address),.ram2_burstcount(tex_ram2_burstcount),
        .ram2_waitrequest(tex_ram2_waitrequest),.ram2_readdata(tex_ram2_readdata),
        .ram2_readdatavalid(tex_ram2_readdatavalid),.ram2_read(tex_ram2_read)
`endif
    );
`ifndef SYNTHESIS
    assign tex_ram2_address=29'd0; assign tex_ram2_burstcount=8'd0; assign tex_ram2_read=1'b0;
`endif

    // flatten the plane arrays for the tsp_shade port (packed vectors)
    // tsp_shade takes p_ddx/p_ddy/p_c as [0:9] arrays directly.
    reg        sh_req;
    reg  [4:0] sh_px, sh_py;
    reg [31:0] sh_invw;
    wire       sh_done;
    wire [31:0] sh_argb;
    tsp_shade u_shade (
        .clk(clk_100m),.reset(reset_100m),.req(sh_req),.px(sh_px),.py(sh_py),
        .done(sh_done),.argb(sh_argb),
        .invw_in(sh_invw),
        .p_ddx(tsp_ddx),.p_ddy(tsp_ddy),.p_c(tsp_c),
        .tsp(regs[REG_TSP]),.tcw(regs[REG_TCW]),.text_ctrl(regs[REG_TEXT_CTRL][4:0]),
        .pp_texture(isp_word[25]),.pp_offset(isp_word[24]),
        .tc_req(dc_creq),.tc_resp(dc_cresp),.vq_req(qc_creq),.vq_resp(qc_cresp));

    always @(posedge clk_100m) begin
        if (reset_100m) begin
            state    <= S_IDLE;
            idx      <= 0;
            cmd_done <= 1'b0;
            mem_rd   <= 1'b0;
            mem_wr   <= 4'b0;
            mem_chan <= 2'b0;
            isp_start<= 1'b0;
            tsp_start<= 1'b0;
            ras_in_valid <= 1'b0;
            sh_req   <= 1'b0;
        end else begin
            cmd_done <= 1'b0;    // default: single-cycle pulse
            mem_rd   <= 1'b0;
            mem_wr   <= 4'b0;
            isp_start<= 1'b0;    // default: single-cycle start pulse
            tsp_start<= 1'b0;
            ras_in_valid <= 1'b0;   // default: single-cycle issue pulse
            sh_req   <= 1'b0;       // default: single-cycle shade start pulse

            case (state)
            // --------------------------------------------------------
            S_IDLE: begin
                if (cmd_valid) begin
                    // Register-write path: explicit wide write (reg_we), OR the
                    // legacy encoding (no reg_we/cmd_stb and cmd[6]==0 -> reg cmd[5:0]).
                    if (reg_we || (!cmd_stb && cmd[6] == 1'b0)) begin
                        regs[reg_we ? reg_addr : {4'b0, cmd[5:0]}] <= data;
                        cmd_done <= 1'b1;   // ready again next cycle (still idle)
                    end else begin
                        idx <= 0;
                        case (cmd)
                            CMD_TILE_CLEAR:     state <= S_CLEAR;
                            CMD_TILE_DRAW_TAGS: state <= S_DRAW_RD;
                            CMD_TILE_FLUSH:     state <= S_FLUSH_RD;
                            CMD_TRIANGLE_ISP_SETUP: begin
                                isp_start <= 1'b1;      // kick the setup pipeline
                                state     <= S_ISP_SETUP;
                            end
                            CMD_TRIANGLE_ISP_RASTERIZE: begin
                                ras_y <= 5'd0; ras_x <= 5'd0;   // start at (0,0)
                                state <= S_ISP_RASTER;
                            end
                            CMD_TRIANGLE_TSP_SETUP: begin
                                tsp_start <= 1'b1;
                                state     <= S_TSP_SETUP;
                            end
                            CMD_TRIANGLE_TSP_SHADE: state <= S_SH_RD;
                            // nop commands: acknowledge, one cycle before ready
                            default: begin
                                cmd_done <= 1'b1;
                                // stays in S_IDLE -> ready next cycle
                            end
                        endcase
                    end
                end
            end

            // --------------------------------------------------------
            // TILE_CLEAR: every entry <= {REG_BG_DEPTH, REG_BG_TAG}.
            // One entry/cycle: bank=idx[2:0], addr=idx[9:3] (write-only).
            // RAM control (we/addr/wdata) for all of these states is driven by
            // the combinational block above; the FSM only advances iterators.
            S_CLEAR: begin
                if (idx == LAST_IDX) state <= S_DONE;
                else                 idx   <= idx + 1'b1;
            end

            // --------------------------------------------------------
            // TILE_DRAW_TAGS: color[p] <= {8'hFF, dt_tag[p]}. Read-modify:
            //  S_DRAW_RD presents dt read addr for idx; next cycle S_DRAWTAGS
            //  has dt_rdata valid and writes col. idx advances in RD.
            S_DRAW_RD: begin
                dr_bank <= idx[2:0];                     // bank/addr to write in WR
                dr_addr <= idx[9:3];
                dr_last <= (idx == LAST_IDX);
                idx     <= idx + 1'b1;
                state   <= S_DRAWTAGS;
            end
            S_DRAWTAGS: begin
                if (dr_last) state <= S_DONE;
                else         state <= S_DRAW_RD;
            end

            // --------------------------------------------------------
            // TILE_FLUSH: colour[y][x] -> DDR3[REG_TILE_BASE + y*32 + x].
            //  S_FLUSH_RD presents col read addr (comb); data valid S_FLUSH_WAIT.
            S_FLUSH_RD: begin
                fl_bank <= idx[2:0];
                state   <= S_FLUSH_WAIT;
            end

            S_FLUSH_WAIT: begin
                // col_rdata[fl_bank] valid now.
                if (!mem_busy) begin
                    mem_addr <= word32_addr[26:0] << 1;
                    mem_din  <= col_rdata[32*fl_bank +: 32];
                    mem_wr   <= 4'b1111;      // full 32-bit write
                    if (idx == LAST_IDX) state <= S_DONE;
                    else begin
                        idx   <= idx + 1'b1;
                        state <= S_FLUSH_RD;
                    end
                end
            end

            // --------------------------------------------------------
            // TRIANGLE_ISP_SETUP: wait for the setup pipeline, latch results.
            S_ISP_SETUP: begin
                if (isp_done) begin
                    isp_r_sgn_neg <= isp_sgn_neg; isp_r_cull <= isp_cull;
                    isp_dx12<=w_dx12; isp_dx23<=w_dx23; isp_dx31<=w_dx31; isp_dx41<=w_dx41;
                    isp_dy12<=w_dy12; isp_dy23<=w_dy23; isp_dy31<=w_dy31; isp_dy41<=w_dy41;
                    isp_c1<=w_c1; isp_c2<=w_c2; isp_c3<=w_c3; isp_c4<=w_c4;
                    isp_ddx_invw<=w_ddx; isp_ddy_invw<=w_ddy; isp_c_invw<=w_cinvw;
                    state <= S_DONE;
                end
            end

            // --------------------------------------------------------
            // TRIANGLE_ISP_RASTERIZE (opaque), RAS_LANES pixels/chunk, banked RAM
            // read-modify-write. S_ISP_RASTER = READ phase: present the chunk's
            // depth read address to all lane-banks (all banks share the same addr
            // in a chunk). isp_raster_line evaluates inside/invW combinationally.
            S_ISP_RASTER: begin
                if (isp_r_cull) state <= S_DONE;
                else begin
                    ras_in_valid <= 1'b1;   // issue this chunk into the pipeline
                    state        <= S_RAS_WAIT;
                end
            end

            // WAIT: hold ras_x/ras_y (so dt read addr + pipeline inputs are
            // stable) until the pipelined line eval produces out_valid. dt_rdata
            // for this chunk is valid throughout (addr held by the comb block).
            S_RAS_WAIT: begin
                if (ras_out_valid) state <= S_RAS_WR;
            end

            // WRITE phase: pipelined inside/invW valid; the comb block does the
            // per-lane DepthMode test + write-back. Here we just advance.
            S_RAS_WR: begin
                // advance x-chunk; at end of line advance y (or finish)
                if (ras_x == XW'(TILE_W-RAS_LANES)) begin
                    ras_x <= 5'd0;
                    if (ras_y == YW'(TILE_H-1)) state <= S_DONE;
                    else begin ras_y <= ras_y + 1'b1; state <= S_ISP_RASTER; end
                end else begin
                    ras_x <= ras_x + XW'(RAS_LANES);
                    state <= S_ISP_RASTER;
                end
            end

            // --------------------------------------------------------
            // TRIANGLE_TSP_SETUP: wait for the plane pipeline. Planes are
            // latched into tsp_ddx/ddy/c by the dedicated always block above.
            S_TSP_SETUP: begin
                if (tsp_done) state <= S_DONE;
            end

            // --------------------------------------------------------
            // TRIANGLE_TSP_SHADE: for each pixel, read its dt entry (tag+invW);
            // if tag == REG_TSP_SHADE_TAG, run tsp_shade and write the colour.
            // idx iterates 0..N_PIX-1; bank=idx[2:0], addr=idx[9:3].
            S_SH_RD: state <= S_SH_CMP;                 // dt read addr presented
            S_SH_CMP: begin
                // dt_rdata[bank] valid now: {invW(32), tag(TAG_BITS)}
                if (dt_rdata[DTW*idx[2:0] + TAG_BITS-1 -: TAG_BITS]
                        == regs[REG_TSP_SHADE_TAG][TAG_BITS-1:0]) begin
                    sh_invw <= dt_rdata[DTW*idx[2:0] + DTW-1 -: 32];
                    sh_px   <= idx[XW-1:0];
                    sh_py   <= idx[IDX_W-1:XW];
                    sh_req  <= 1'b1;
                    state   <= S_SH_RUN;
                end else begin
                    // skip this pixel
                    if (idx == LAST_IDX) state <= S_DONE;
                    else begin idx <= idx + 1'b1; state <= S_SH_RD; end
                end
            end
            S_SH_RUN: if (sh_done) state <= S_SH_WR;    // col write driven comb
            S_SH_WR: begin
                if (idx == LAST_IDX) state <= S_DONE;
                else begin idx <= idx + 1'b1; state <= S_SH_RD; end
            end

            // --------------------------------------------------------
            S_DONE: begin
                cmd_done <= 1'b1;   // pulse: ready next cycle
                state    <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
