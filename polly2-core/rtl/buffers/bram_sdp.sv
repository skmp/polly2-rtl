//
// bram_sdp - SIMPLE DUAL-PORT block RAM: one dedicated write port + one dedicated read
// port, independent addresses, both usable in the SAME cycle. This is the M10K's native
// two-port-but-one-is-write mode, and unlike bram_tdp it has NO x20 width restriction.
//
// Used for storage whose read port must stay live WHILE writes are happening - in
// tex_cache_4p_1c that is the prefill probe's private tag copy, which answers residency
// questions during fills and during the invalidate sweep, exactly when the four demand
// ports are frozen.
//
// READ-DURING-WRITE: no bypass (ramstyle no_rw_check). A read of the address being
// written THIS cycle returns undefined data - callers that can collide must forward the
// write themselves (tex_cache_4p_1c does; see pf_fwd).
//
// STYLE: default M10K, but pass "MLAB, no_rw_check" for WIDE-AND-SHALLOW instances.
// An M10K caps port width at 40 bits, so a W-bit RAM costs ceil(W/40) blocks REGARDLESS
// of how few entries it holds - u_fq_a (171 x 32) burns 5 blocks on 5,472 bits (10.7%).
// Depth <= 32 maps to one MLAB row (32x20), so ceil(W/20) cells at ~10 ALMs each.
// Keep M10K for anything deep - u_iwr is 31 x 1024 and is 77% efficient as a block.
module bram_sdp #(
    parameter integer W  = 32,
    parameter integer D  = 1024,
    parameter integer AW = $clog2(D),
    parameter         STYLE = "M10K, no_rw_check"
) (
    input                 clk,
    input                 we,
    input      [AW-1:0]   waddr,
    input      [W-1:0]    din,
    input                 re,
    input      [AW-1:0]   raddr,
    output reg [W-1:0]    q
);
    (* ramstyle = STYLE *) reg [W-1:0] mem [0:D-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= din;
        if (re) q          <= mem[raddr];
    end
endmodule
