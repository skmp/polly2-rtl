// frontend_tsp_lp_tb_top - SIM wrapper around peel_core.
//
// Instantiates peel_core + the shared sim backend (sim_ddr_fb: behavioral 8 MB
// vram[] faux DDR read + 640x480 fb[] faux write). The C++ TB loads the PVR reg
// dump through wr_* before `go`, preloads vram[] (at u_sim.vram), and reads fb[]
// (at u_sim.fb) after `done` to write the BMP.
//
module frontend_tsp_lp_tb_top import tsp_pkg::*; #(
    parameter integer RAS_LANES = 8     // override with verilator -GRAS_LANES=4
) (
    input             clk,
    input             reset,
    // register write path (C++ TB loads the PVR reg dump through this before go)
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    input             go,             // 1-cycle: start rendering the region array
    output reg        done            // 1-cycle: region array fully processed
);
    // injected core <-> backend bundles
    ddr_rd_req_t  ddr_req;  ddr_rd_resp_t ddr_resp;
    fb_wr_req_t   fbw_req;  fb_wr_resp_t  fbw_resp;

    // shared faux DDR + framebuffer backend (vram[]/fb[] live here, at u_sim)
    sim_ddr_fb u_sim (
        .clk(clk), .reset(reset),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp)
    );

    // the render core
    peel_core #(.RAS_LANES(RAS_LANES)) u_core (
        .clk(clk), .reset(reset),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .go(go), .done(done),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp),
        .regs_out()                              // exposed PVR regs (unused by this TB)
    );
endmodule
