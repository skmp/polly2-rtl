// frontend_isp_tb_top - SIM wrapper around isp_core (ISP-only render core).
//
// Instantiates isp_core + the shared sim backend (sim_ddr_fb: behavioral 8 MB
// vram[] faux DDR read + 640x480 fb[] faux write). isp_core walks the region /
// object lists, sets up + rasterizes every triangle with depth/tag compare, and
// FLUSHes each tile's 32x32 CoreTag buffer out to fb[] (one 32-bit tag/pixel).
//
// The C++ TB (frontend_isp_tb.cpp) loads the PVR reg dump through wr_* before
// `go`, preloads vram[] (at u_sim.vram), and after `done` reads fb[] (at
// u_sim.fb) - each entry a CoreTag - and colorizes it into output.bmp.
//
module frontend_isp_tb_top import tsp_pkg::*; (
    input             clk,
    input             reset,
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

    // the ISP-only render core (fb holds CoreTags, no TSP shading)
    isp_core u_core (
        .clk(clk), .reset(reset),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .go(go), .done(done),
        .ddr_req(ddr_req), .ddr_resp(ddr_resp),
        .fbw_req(fbw_req), .fbw_resp(fbw_resp)
    );
endmodule
