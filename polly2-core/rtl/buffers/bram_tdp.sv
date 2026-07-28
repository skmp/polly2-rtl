//
// bram_tdp - TRUE DUAL-PORT block RAM: TWO read ports + ONE write port, sharing one
// copy of the storage. The point is M10K economy: a Cyclone V M10K in true dual-port
// (BIDIR_DUAL_PORT) mode has two INDEPENDENT ports, each doing one operation per cycle,
// so two simultaneous reads come out of ONE block instead of two replicated copies.
//
// PORT A is bidirectional (read OR write, one per cycle, ONE shared address); PORT B is
// read-only. Write wins on A: when a_we is high, A performs the write and a_q holds.
// Callers must therefore mux A's address themselves -> a_addr is the write address on a
// write cycle and the read address otherwise (see the a_we ? wa : ra pattern in
// tex_cache_4p_1c). This is not a limitation of the wrapper, it is what the hardware is:
// a port is one address and one operation per cycle.
//
// WIDTH LIMIT (the reason this is a win here): M10K supports x1/x2/x5/x10/x20/x40, but
// TRUE DUAL-PORT tops out at x20 - x40 is single-port / simple-dual-port only. So TDP is
// free only when the per-block width the fitter would pick is <= 20, i.e. when the array
// is >= 512 deep. At 1024 deep the per-block config is 1024x10 either way, so a
// 1024 x N array costs the SAME block count in TDP as in SDP and the second read port is
// genuinely free. A 256-deep array would be penalised 2x - do not blindly reuse this.
//
// READ-DURING-WRITE: no bypass (ramstyle no_rw_check). A port-B read of the address
// port A is writing THIS cycle returns undefined data - not old data. Callers must
// either never overlap (tex_cache_4p_1c freezes all reads during a fill) or forward the
// write themselves.
//
// Only PORT A writes `mem`, so this stays single-driver and needs no Verilator
// MULTIDRIVEN waiver, unlike the symmetric two-writer TDP template.
//
module bram_tdp #(
    parameter integer W  = 256,                 // data width
    parameter integer D  = 1024,                // depth (entries)
    parameter integer AW = $clog2(D)
) (
    input                 clk,
    // ---- port A: read OR write (a_we picks; a_addr serves whichever runs) ----
    input                 a_en,                 // read enable (ignored while a_we)
    input                 a_we,                 // write enable (takes priority)
    input      [AW-1:0]   a_addr,
    input      [W-1:0]    a_din,
    output reg [W-1:0]    a_q,
    // ---- port B: read only ----
    input                 b_en,
    input      [AW-1:0]   b_addr,
    output reg [W-1:0]    b_q
);
    (* ramstyle = "M10K, no_rw_check" *) reg [W-1:0] mem [0:D-1];

    always @(posedge clk) begin
        if (a_we)      mem[a_addr] <= a_din;
        else if (a_en) a_q         <= mem[a_addr];
    end

    always @(posedge clk) begin
        if (b_en) b_q <= mem[b_addr];
    end
endmodule
