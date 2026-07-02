//
// plane_cache - the 64-entry TSP plane cache for peel_core, banked into M10K with
// its RAM port owned + the access pattern enforced by typed ports.
//
// Each entry is one shaded triangle's resolved TSP parameters: {tag, isp, tsp, tcw}
// + 30 plane coefficients (10 x ddx, 10 x ddy, 10 x c). As registers that was
// 64 x (4 + 30) x 32 = ~70 kbit of flip-flops (the bulk of peel_core's registers);
// here the WIDE plane payload is packed into one M10K word per entry, so only the
// small tag + valid mirrors remain in logic.
//
// Split storage:
//   * pc_ram  : the wide payload {isp, tsp, tcw, 10xddx, 10xddy, 10xc} in a
//     REGISTERED-read block RAM (M10K; M10K has no async read) -> 1-cycle read.
//   * tags[]  : a small 64x32 register mirror of each entry's tag, and
//   * valid[] : a 64-bit register, both read COMBINATIONALLY for the hit test and
//     bulk-cleared in one cycle on `inval` (a RAM can't clear all entries at once).
//
// Keyed by slot (direct-mapped; caller computes it) + full tag. Protocol:
//   LOOKUP: pulse lu_req with lu_slot/lu_tag. rd_valid + hit + the payload appear
//           the NEXT cycle (payload from the registered RAM read). `hit` already
//           means valid && tag-match; the caller need not compare.
//   WRITE : pulse wr_req with wr_slot + the full payload; entry stored, valid set.
//   INVAL : pulse inval to clear all valid bits (start of a shade sub-phase).
// Payload plane arrays cross the port as FLAT 320-bit vectors (10 x 32), lane j at
// [32*j +: 32], matching cur_ddx[j] etc. in the caller.
//
module plane_cache #(
    parameter integer NENT  = 64,
    parameter integer SLOTW = 6            // clog2(NENT)
) (
    input                 clk,
    input                 reset,

    input                 inval,           // clear all valid bits (1 cyc)

    // ---- LOOKUP (registered read, 1-cycle latency) ----
    input                 lu_req,
    input  [SLOTW-1:0]    lu_slot,
    input  [31:0]         lu_tag,
    output reg            rd_valid,        // 1 cyc after lu_req: outputs ready
    output reg            hit,             // valid && tag match (aligned w/ rd_valid)
    output [31:0]         o_isp,
    output [31:0]         o_tsp,
    output [31:0]         o_tcw,
    output [319:0]        o_ddx,           // 10 x 32, lane j at [32*j +: 32]
    output [319:0]        o_ddy,
    output [319:0]        o_c,

    // ---- WRITE (commit a resolved entry) ----
    input                 wr_req,
    input  [SLOTW-1:0]    wr_slot,
    input  [31:0]         wr_tag,
    input  [31:0]         wr_isp,
    input  [31:0]         wr_tsp,
    input  [31:0]         wr_tcw,
    input  [319:0]        wr_ddx,
    input  [319:0]        wr_ddy,
    input  [319:0]        wr_c
);
    // wide payload layout inside pc_ram (LSB-first)
    localparam integer PW_ISP = 0;
    localparam integer PW_TSP = 32;
    localparam integer PW_TCW = 64;
    localparam integer PW_DDX = 96;         // 320 bits
    localparam integer PW_DDY = 416;        // 320 bits
    localparam integer PW_C   = 736;        // 320 bits
    localparam integer EW     = 1056;       // 3*32 + 3*320

    // small combinational-read mirrors for the hit test (bulk-clearable)
    reg [NENT-1:0] valid;
    reg [31:0]     tags [0:NENT-1];

    // wide payload store: registered-read M10K
    (* ramstyle = "M10K, no_rw_check" *) reg [EW-1:0] pc_ram [0:NENT-1];
    reg [EW-1:0] rd_word;                    // registered read data (1-cyc)

    // assemble the write word from the payload ports (tag is NOT in pc_ram; it lives
    // in the tags[] mirror)
    wire [EW-1:0] wr_word;
    assign wr_word[PW_ISP +: 32]  = wr_isp;
    assign wr_word[PW_TSP +: 32]  = wr_tsp;
    assign wr_word[PW_TCW +: 32]  = wr_tcw;
    assign wr_word[PW_DDX +: 320] = wr_ddx;
    assign wr_word[PW_DDY +: 320] = wr_ddy;
    assign wr_word[PW_C   +: 320] = wr_c;

    // combinational hit test at lookup (tags[]/valid[] are registers): register it so
    // it lands aligned with the registered payload read next cycle.
    wire lu_hit = lu_req && valid[lu_slot] && (tags[lu_slot] == lu_tag);

    always @(posedge clk) begin
        if (reset) begin
            valid    <= '0;
            rd_valid <= 1'b0;
            hit      <= 1'b0;
        end else begin
            rd_valid <= 1'b0;

            // WRITE: store wide payload + tag mirror + set valid.
            if (wr_req) begin
                pc_ram[wr_slot] <= wr_word;
                tags  [wr_slot] <= wr_tag;
                valid [wr_slot] <= 1'b1;
            end

            // LOOKUP: registered payload read + registered hit/valid strobe.
            if (lu_req) begin
                rd_word  <= pc_ram[lu_slot];
                rd_valid <= 1'b1;
            end
            hit <= lu_hit;

            // INVALIDATE all: single-cycle clear. Callers issue inval only at shade
            // sub-phase entry, never concurrently with a lookup.
            if (inval) valid <= '0;
        end
    end

    // payload outputs (valid the cycle rd_valid is high)
    assign o_isp = rd_word[PW_ISP +: 32];
    assign o_tsp = rd_word[PW_TSP +: 32];
    assign o_tcw = rd_word[PW_TCW +: 32];
    assign o_ddx = rd_word[PW_DDX +: 320];
    assign o_ddy = rd_word[PW_DDY +: 320];
    assign o_c   = rd_word[PW_C   +: 320];
endmodule
