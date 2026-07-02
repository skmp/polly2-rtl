// frontend_tb_top - integration of the render front-end for a Verilator run:
//   reg_file (full PVR regs, loaded from a dump) + 8 MB behavioral VRAM +
//   region_array_parser -> object_list_parser -> isp_primitive_iterator ->
//   a FAUX ISP that just $display()s each triangle's tag/isp/xyz.
//
// Only the OPAQUE (ENT... op) list is walked, and only ENT_STRIP entries are
// handed to the tristrip iterator (tri/quad arrays are acknowledged + skipped
// for now). clear/pt/tr/flush states are acknowledged and skipped.
//
// Three data_cache256 instances (region / objlist / param) each read the shared
// behavioral VRAM through their own stub DDR port (they never run concurrently,
// but separate ports keep the wiring trivial). VRAM is the 64-bit PHYSICAL view;
// the caches de-interleave to the 32-bit param view internally.
//
module frontend_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
    // register write path (C++ TB loads the PVR reg dump through this before go)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done            // 1-cycle: region array fully processed
);
    // -------------------- reg_file --------------------
    pvr_regs_t  regs;
    fog_rd_req_t fog_req; fog_rd_resp_t fog_resp;
    pal_rd_req_t pal_req; pal_rd_resp_t pal_resp;
    assign fog_req = '0; assign pal_req = '0;
    reg_file u_rf (.clk(clk),.reset(reset),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .regs(regs),.fog_req(fog_req),.fog_resp(fog_resp),.pal_req(pal_req),.pal_resp(pal_resp));

    // REGION_BASE / PARAM_BASE are byte addresses in the 32-bit view. The caches
    // take a 32-byte-line address (byte>>5). Region array walk uses region_base;
    // param records use PARAM_BASE & 0xF00000 (refsw RenderTriangleStrip).
    wire [26:0] region_base = regs.region_base[26:0];
    wire [26:0] param_base  = {regs.param_base[23:20], 23'd0}; // PARAM_BASE & 0xF00000
    wire        region_v1   = (regs.fpu_param_cfg.region_header_type == 1'b0);

    // -------------------- 8 MB behavioral VRAM (1M x 64-bit) --------------------
    (* verilator public_flat_rw *) reg [63:0] vram [0:1048575];

    // generic behavioral DDR read stub for a data_cache256's injected port
    // (1-cycle latency, never busy). Macro-like via a task per port below.
    // region port
    ddr_rd_req_t  ra_dreq; ddr_rd_resp_t ra_dresp;
    reg [63:0] ra_do; reg ra_dv;
    assign ra_dresp.busy=1'b0; assign ra_dresp.dout=ra_do; assign ra_dresp.dready=ra_dv;
    always @(posedge clk) begin ra_dv<=0; if(ra_dreq.rd) begin ra_do<=vram[ra_dreq.addr[19:0]]; ra_dv<=1; end end
    // objlist port
    ddr_rd_req_t  ol_dreq; ddr_rd_resp_t ol_dresp;
    reg [63:0] ol_do; reg ol_dv;
    assign ol_dresp.busy=1'b0; assign ol_dresp.dout=ol_do; assign ol_dresp.dready=ol_dv;
    always @(posedge clk) begin ol_dv<=0; if(ol_dreq.rd) begin ol_do<=vram[ol_dreq.addr[19:0]]; ol_dv<=1; end end
    // param port
    ddr_rd_req_t  pr_dreq; ddr_rd_resp_t pr_dresp;
    reg [63:0] pr_do; reg pr_dv;
    assign pr_dresp.busy=1'b0; assign pr_dresp.dout=pr_do; assign pr_dresp.dready=pr_dv;
    always @(posedge clk) begin pr_dv<=0; if(pr_dreq.rd) begin pr_do<=vram[pr_dreq.addr[19:0]]; pr_dv<=1; end end

    // -------------------- caches --------------------
    cache_req256_t ra_creq, ol_creq, pr_creq;
    cache_resp256_t ra_cresp, ol_cresp, pr_cresp;
    data_cache256 u_ra_c (.clk(clk),.reset(reset),.creq(ra_creq),.cresp(ra_cresp),.dreq(ra_dreq),.dresp(ra_dresp));
    data_cache256 u_ol_c (.clk(clk),.reset(reset),.creq(ol_creq),.cresp(ol_cresp),.dreq(ol_dreq),.dresp(ol_dresp));
    data_cache256 u_pr_c (.clk(clk),.reset(reset),.creq(pr_creq),.cresp(pr_cresp),.dreq(pr_dreq),.dresp(pr_dresp));

    // -------------------- parsers --------------------
    reg          ra_start;
    wire         ra_busy, ra_tiles_parsed;
    region_out_t ra_out; region_ack_t ra_ack;
    region_array_parser u_ra (.clk(clk),.reset(reset),.start(ra_start),
        .region_base(region_base),.region_v1(region_v1),.busy(ra_busy),
        .tiles_parsed(ra_tiles_parsed),.rout(ra_out),.ack(ra_ack),
        .creq(ra_creq),.cresp(ra_cresp));

    reg          ol_start; reg [26:0] ol_list_ptr;
    wire         ol_busy, ol_done;
    prim_out_t   ol_prim; prim_ack_t ol_ack;
    object_list_parser u_ol (.clk(clk),.reset(reset),.start(ol_start),
        .list_ptr(ol_list_ptr),.busy(ol_busy),.done(ol_done),
        .prim(ol_prim),.ack(ol_ack),.creq(ol_creq),.cresp(ol_cresp));

    reg              it_start; objlist_entry_t it_entry; entry_type_e it_etype;
    wire             it_busy;
    triangle_out_t   it_trio; triangle_ack_t it_ack;
    isp_primitive_iterator u_it (.clk(clk),.reset(reset),.start(it_start),
        .intensity_shadow(regs.fpu_shad_scale.intensity_shadow),
        .param_base(param_base),.entry_type(it_etype),.entry(it_entry),.busy(it_busy),
        .trio(it_trio),.ack(it_ack),.creq(pr_creq),.cresp(pr_cresp));

    // -------------------- orchestration FSM --------------------
    // region -> (op state) -> objlist -> (strip entry) -> tristrip -> faux ISP.
    localparam S_IDLE=0, S_RA=1, S_STATE=2,
               S_OL_START=3, S_OL_WAIT=4, S_ENTRY=5,
               S_IT_START=6, S_IT_WAIT=7, S_OL_ACK=8,
               S_RA_ACK=9, S_DONE=10;
    reg [3:0] st;

    // faux ISP: print the current triangle
    integer tri_count;

    always @(posedge clk) begin
        if (reset) begin
            st<=S_IDLE; done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;
            tri_count<=0;
        end else begin
            done<=0; ra_start<=0; ol_start<=0; it_start<=0;
            ra_ack.list_done<=0; ol_ack.entry_done<=0; it_ack.triangle_done<=0;

            case (st)
            S_IDLE: if (go) begin ra_start<=1; st<=S_RA; end

            // wait for the region parser to present a state (or finish)
            S_RA: begin
                if (ra_tiles_parsed) st<=S_DONE;
                else if (ra_out.list_ready) st<=S_STATE;
            end

            // classify the presented state: op/pt/tr all walk the object list.
            S_STATE: begin
                if (ra_out.state == RSTATE_OP ||
                    ra_out.state == RSTATE_PT ||
                    ra_out.state == RSTATE_TR) begin
                    ol_list_ptr <= ra_out.list_ptr;
                    ol_start <= 1'b1;
                    $display("[TILE %0d,%0d] %s list @ %h", ra_out.tile_x, ra_out.tile_y,
                        (ra_out.state==RSTATE_OP)?"OP":(ra_out.state==RSTATE_PT)?"PT":"TR",
                        ra_out.list_ptr);
                    st <= S_OL_WAIT;
                end else begin
                    // clear/flush: acknowledge + skip
                    ra_ack.list_done <= 1'b1;
                    st <= S_RA_ACK;
                end
            end

            // object-list walk: wait for an entry or list done
            S_OL_WAIT: begin
                if (ol_done) begin ra_ack.list_done<=1'b1; st<=S_RA_ACK; end
                else if (ol_prim.entry_ready) st<=S_ENTRY;
            end

            S_ENTRY: begin
                if (ol_prim.entry_type == ENT_STRIP || ol_prim.entry_type == ENT_TRI) begin
                    it_entry <= ol_prim.entry;
                    it_etype <= ol_prim.entry_type;
                    it_start <= 1'b1;
                    st <= S_IT_WAIT;
                end else begin
                    // quad array: skip for now
                    ol_ack.entry_done <= 1'b1;
                    st <= S_OL_ACK;
                end
            end

            // tristrip: print each triangle, ack it; when strip done, ack the entry
            S_IT_WAIT: begin
                // triangle_ready holds until we ack; only latch/print once per
                // triangle (skip the cycle where our registered ack is still high).
                if (it_trio.triangle_ready && !it_ack.triangle_done) begin
                    $display("  TRI %0d: isp=%08h  v0=(%08h,%08h,%08h) v1=(%08h,%08h,%08h) v2=(%08h,%08h,%08h)",
                        tri_count, it_trio.isp,
                        it_trio.v0.x, it_trio.v0.y, it_trio.v0.z,
                        it_trio.v1.x, it_trio.v1.y, it_trio.v1.z,
                        it_trio.v2.x, it_trio.v2.y, it_trio.v2.z);
                    tri_count <= tri_count + 1;
                    it_ack.triangle_done <= 1'b1;
                end
                if (it_trio.prim_done) begin
                    ol_ack.entry_done <= 1'b1;
                    st <= S_OL_ACK;
                end
            end

            S_OL_ACK: st <= S_OL_WAIT;     // back for next object-list entry
            S_RA_ACK: st <= S_RA;          // back for next region state

            S_DONE: begin
                $display("=== done: %0d triangles ===", tri_count);
                done<=1'b1; st<=S_IDLE;
            end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule
