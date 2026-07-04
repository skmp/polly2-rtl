//
// span_expander - converts spanner_v2's coalesced SPARSE spans into per-pixel entries for
// span_buffer_v2, so the shade reader can walk pixels densely.
//
// spanner_v2 emits one span/clock: {sp_idx (run start), rep 1..4, invw[0:3], shmask, id,
// at}. This walks the run's `rep` covered pixels and writes one span_buffer_v2 entry each:
//   span_buffer_v2[sp_idx+k] = { shade=shmask[k], id, invw[k], at }   for k = 0..rep-1
// A rep>1 span takes `rep` clocks to expand, so sp_ready is deasserted while expanding
// (spanner_v2 freezes its SPANGEN pipeline on !sp_ready). rep==1 spans stream 1/clk with
// sp_ready held high. SPANGEN then effectively paces at ~1 px/clk (<= the shade floor, so
// still hidden). NON timing-critical: this runs during the spanner phase, not the shade.
//
module span_expander (
    input             clk,
    input             reset,
    // ---- span input (spanner_v2 sp_* port) ----
    input             sp_we,
    input      [9:0]  sp_idx,
    input      [2:0]  sp_rep,
    input      [31:0] sp_invw [0:3],
    input      [3:0]  sp_shmask,
    input      [9:0]  sp_id,
    input             sp_at,
    output            sp_ready,           // 1 = can accept a span this cycle
    // ---- per-pixel write (span_buffer_v2 producer half) ----
    output reg        xe_we,
    output reg [9:0]  xe_addr,
    output reg        xe_shade,
    output reg [9:0]  xe_id,
    output reg [31:0] xe_invw,
    output reg        xe_at
);
    // mid-expansion state (for rep>1)
    reg        active;
    reg [9:0]  base_r, id_r;
    reg [2:0]  rep_r;
    reg [1:0]  k_r;                        // next covered-pixel index (1..rep-1) while active
    reg [31:0] invw_r [0:3];
    reg [3:0]  shmask_r;
    reg        at_r;

    assign sp_ready = !active;             // accept a new span only when not mid-expansion

    integer q;
    always @(*) begin
        // combinational write: pixel k=0 on accept, else the active run's pixel k_r
        xe_we=1'b0; xe_addr=10'd0; xe_shade=1'b0; xe_id=10'd0; xe_invw=32'd0; xe_at=1'b0;
        if (active) begin
            xe_we    = 1'b1;
            xe_addr  = base_r + {8'd0, k_r};
            xe_shade = shmask_r[k_r];
            xe_id    = id_r;
            xe_invw  = invw_r[k_r];
            xe_at    = at_r;
        end else if (sp_we) begin           // accept: write covered pixel 0 now
            xe_we    = 1'b1;
            xe_addr  = sp_idx;
            xe_shade = sp_shmask[0];
            xe_id    = sp_id;
            xe_invw  = sp_invw[0];
            xe_at    = sp_at;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            active <= 1'b0; k_r <= 2'd0;
        end else begin
            if (active) begin
                if (k_r == rep_r - 3'd1) active <= 1'b0;  // wrote the last covered pixel
                else                     k_r    <= k_r + 2'd1;
            end else if (sp_we) begin
                if (sp_rep > 3'd1) begin                  // rep>1 -> expand over rep clocks
                    active   <= 1'b1;
                    base_r   <= sp_idx; rep_r <= sp_rep; id_r <= sp_id; at_r <= sp_at;
                    shmask_r <= sp_shmask; k_r <= 2'd1;
                    for (q=0;q<4;q=q+1) invw_r[q] <= sp_invw[q];
                end
                // rep==1: pixel 0 already written combinationally, stay idle (ready high)
            end
        end
    end
endmodule
