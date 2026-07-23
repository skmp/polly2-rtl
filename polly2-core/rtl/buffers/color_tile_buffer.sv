//
// color_tile_buffer - the shaded-ARGB accumulation buffer for one 32x32 tile,
// banked into a single M10K, with its access pattern ENFORCED by typed ports.
//
// col_buf is low-load: only the TSP blend (1 px/cyc RMW) and the FLUSH readout
// (1 px/cyc) ever touch it, never LANES-wide. So it is a single-bank 1024x32 M10K
// (1R1W, registered read), addressed by the full pixel index (0..1023).
//
// The blend is a 2-stage RMW because the read is registered, but the blend unit
// itself lives OUTSIDE this module: only the producer half blends at a time, so
// peel_core keeps ONE shared tsp_blend instead of one per ping-pong half.
//   stage CA (bl_ca_valid): present the col-RAM read of bl_ca_id (the dst).
//   stage CB (bl_cb_valid): rd_argb = OLD col_buf[cb_id] = dst feeds the external
//     tsp_blend; its result returns on cb_data and is written to col_ram[cb_id].
// The shade pipeline is in-order and pixel ids ascend within a sub-phase, so a CA
// read and a CB write never hit the same address in the same cycle (no RMW hazard).
//
// Read clients  (at most one/cycle): blend stage CA | FLUSH read.
// Write clients (at most one/cycle): blend stage CB.
// The module owns the ports and asserts the exclusion (sim).
//
module color_tile_buffer #(
    parameter integer DEPTH = 1024
) (
    input                       clk,
    input                       reset,

    // ---- BLEND stage CA: present the read of the dst for out-pixel bl_ca_id ----
    input                       bl_ca_valid,
    input      [9:0]            bl_ca_id,

    // ---- BLEND stage CB: write the externally blended result to col_ram[cb_id] ----
    input                       bl_cb_valid,
    input      [9:0]            cb_id,
    input      [31:0]           cb_data,     // blended color (shared tsp_blend output)

    // ---- FLUSH: hold the read of pixel fl_id; fl_argb is the registered read ----
    input                       fl_rd_valid,
    input      [9:0]            fl_id,
    output     [31:0]           rd_argb      // registered read data (dst / flush pixel)
);
    reg          we;
    reg  [9:0]   waddr, raddr;
    reg  [31:0]  wdata;
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] col_ram [0:DEPTH-1];
    reg  [31:0]  rdata_r;
    always @(posedge clk) begin
        if (we) col_ram[waddr] <= wdata;
        rdata_r <= col_ram[raddr];          // registered read (read-first)
    end
    assign rd_argb = rdata_r;

    // -------------------- READ port mux --------------------
    always @(*) begin
        raddr = 10'd0;
        if (bl_ca_valid)      raddr = bl_ca_id;
        else if (fl_rd_valid) raddr = fl_id;
    end

    // -------------------- WRITE port (blend stage CB) --------------------
    always @(*) begin
        we    = bl_cb_valid;
        waddr = cb_id;
        wdata = cb_data;
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
        if ((bl_ca_valid + fl_rd_valid) > 1)
            $error("color_tile_buffer: multiple READ clients (%b%b)",
                   bl_ca_valid, fl_rd_valid);
    end
`endif
endmodule
