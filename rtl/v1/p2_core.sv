// p2_core: the CORE, region array to framebuffer, on one register port and two VRAM half ports
// (docs/ARCHITECTURE.md 1.2).
//
// M0: an EMPTY SHELL. It has the external interface only, every output tied to 0, so that make lint has a top to
// check the packages under. The units are instanced here from M12 on (PLAN M12).
module p2_core
  import p2_pkg::*;
(
  input  logic                                         clk,
  input  logic                                         rst,           // power-on, synchronous, active high

  // register port: a write takes effect at the next edge; a read returns its data one clock later
  input  logic                                         reg_wr,
  input  logic                                         reg_rd,
  input  logic [12:2]                                  reg_addr,      // word index in the 8 KB block (0x000-0x1FFC)
  input  logic [31:0]                                  reg_wdata,
  output logic [31:0]                                  reg_rdata,

  // VRAM halves h = 0, 1: valid/ready per request; read responses in request order per half, any latency
  output logic [P2_VRAM_HALVES-1:0]                        vh_req_v,
  input  logic [P2_VRAM_HALVES-1:0]                        vh_req_rdy,
  output logic [P2_VRAM_HALVES-1:0]                        vh_req_we,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_IDX_BITS-1:0]  vh_req_idx,    // 32-bit word index within the half
  output logic [P2_VRAM_HALVES-1:0][3:0]                   vh_req_be,
  output logic [P2_VRAM_HALVES-1:0][31:0]                  vh_req_wdata,
  output logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]  vh_req_src,    // client id (P2_C_*)
  input  logic [P2_VRAM_HALVES-1:0]                        vh_rsp_v,
  input  logic [P2_VRAM_HALVES-1:0][31:0]                  vh_rsp_data,
  input  logic [P2_VRAM_HALVES-1:0][P2_VRAM_SRC_BITS-1:0]  vh_rsp_src,

  // end-of-render events, 1-clock pulses: SB_ISTNRM bits 1 (ISP), 2 (TSP), 0 (video); SB_ISTERR bit 0
  output logic                                         ev_isp,
  output logic                                         ev_tsp,
  output logic                                         ev_vid,
  output logic                                         ev_isp_ovf     // tied 0 unless P2_ISTERR = 1 (PLAN D11)
);

  // the elaboration checks on p2_hw_pkg's MODE switches and the shared formats' widths
  p2_hw_check u_hw_check ();

  assign reg_rdata    = '0;
  assign vh_req_v     = '0;
  assign vh_req_we    = '0;
  assign vh_req_idx   = '0;
  assign vh_req_be    = '0;
  assign vh_req_wdata = '0;
  assign vh_req_src   = '0;
  assign ev_isp       = 1'b0;
  assign ev_tsp       = 1'b0;
  assign ev_vid       = 1'b0;
  assign ev_isp_ovf   = 1'b0;

endmodule
