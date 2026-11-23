// p2_sort_tb_top: the sorter testbench's DUT (PLAN M8; tb/sort/sort_tb.cpp): p2_runq -> p2_sort, and p2_entq
// (rtl/v1/isp/p2_isp_entq.sv) beside them as in p2_core: the testbench is p2_isp_cut on the input side (it pushes an
// entry's record with its eoe item, a full p2_entq holding that item) and the SRQ / p2_tbuf on the output side (it pops
// the record when the eoe item leaves the sorter). Flat ports for the C++ side.
module p2_sort_tb_top
  import p2_pkg::*;
  import p2_regs_pkg::*;
#(
  parameter int RUNQ_N = 300,
  parameter int ENT_N  = 32
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        cfg_on,
  input  logic        cfg_offs,
  // the run stream in (p2_isp_cut's side)
  input  logic        in_v,
  output logic        in_rdy,
  input  logic        in_null,
  input  logic [31:0] in_tag,
  input  logic [4:0]  in_y,
  input  logic [4:0]  in_x,
  input  logic [4:0]  in_lenm1,
  input  logic [2:0]  in_rm,
  input  logic [6:0]  in_epoch,
  input  logic [31:0] in_vmask,
  input  logic [31:0] in_pmask,
  input  logic        in_eop,
  input  logic        in_eoe,
  // p2_entq's push, with the eoe item
  input  logic        eqi_v,
  output logic        eqi_rdy,
  input  logic [5:0]  eqi_tilex,
  input  logic [5:0]  eqi_tiley,
  input  logic        eqi_z_keep,
  input  logic        eqi_no_writeout,
  input  logic        eqi_last,
  input  logic        eqi_shaded_any,
  // the sorted stream out (the SRQ's side)
  output logic        out_v,
  input  logic        out_rdy,
  output logic        out_null,
  output logic [31:0] out_tag,
  output logic [4:0]  out_y,
  output logic [4:0]  out_x,
  output logic [4:0]  out_lenm1,
  output logic [2:0]  out_rm,
  output logic [6:0]  out_epoch,
  output logic [31:0] out_vmask,
  output logic [31:0] out_pmask,
  output logic        out_eop,
  output logic        out_eoe,
  output logic        out_new_drain,
  // p2_entq's pop
  output logic        eq_v,
  input  logic        eq_rdy,
  output logic [5:0]  eq_tilex,
  output logic [5:0]  eq_tiley,
  output logic        eq_z_keep,
  output logic        eq_no_writeout,
  output logic        eq_last,
  output logic        eq_shaded_any,
  // statistics
  output logic [8:0]  t_runq_occ,
  output logic        t_full,
  output logic        t_wait,
  output logic        t_end
);
  p2_rs_t i_d, q_d, s_d;
  logic   q_v, q_rdy;
  always_comb begin
    i_d.null_ = in_null;
    i_d.tag   = p2_tag_t'(in_tag);
    i_d.y     = in_y;
    i_d.x     = in_x;
    i_d.lenm1 = in_lenm1;
    i_d.rm    = p2_rm_t'(in_rm);
    i_d.epoch = in_epoch;
    i_d.vmask = in_vmask;
    i_d.pmask = in_pmask;
    i_d.eop   = in_eop;
    i_d.eoe   = in_eoe;
  end

  logic [$clog2(RUNQ_N + 1)-1:0] occ;
  p2_runq #(.RUNQ_N(RUNQ_N)) u_runq (
    .clk, .rst, .in_v, .in_rdy, .in_d(i_d), .out_v(q_v), .out_rdy(q_rdy), .out_d(q_d), .occ
  );
  assign t_runq_occ = 9'(occ);

  p2_sort u_sort (
    .clk, .rst, .cfg_on, .cfg_offs, .in_v(q_v), .in_rdy(q_rdy), .in_d(q_d), .out_v, .out_rdy, .out_d(s_d),
    .out_new_drain, .t_full, .t_wait, .t_end
  );
  assign out_null  = s_d.null_;
  assign out_tag   = 32'(s_d.tag);
  assign out_y     = s_d.y;
  assign out_x     = s_d.x;
  assign out_lenm1 = s_d.lenm1;
  assign out_rm    = 3'(s_d.rm);
  assign out_epoch = s_d.epoch;
  assign out_vmask = s_d.vmask;
  assign out_pmask = s_d.pmask;
  assign out_eop   = s_d.eop;
  assign out_eoe   = s_d.eoe;

  p2_entrec_t eqi_d, eq_d;
  always_comb begin
    eqi_d.tilex       = eqi_tilex;
    eqi_d.tiley       = eqi_tiley;
    eqi_d.z_keep      = eqi_z_keep;
    eqi_d.no_writeout = eqi_no_writeout;
    eqi_d.last        = eqi_last;
    eqi_d.shaded_any  = eqi_shaded_any;
  end
  p2_isp_entq #(.ENT_N(ENT_N)) u_entq (
    .clk, .rst, .in_v(eqi_v), .in_rdy(eqi_rdy), .in_d(eqi_d), .out_v(eq_v), .out_rdy(eq_rdy), .out_d(eq_d)
  );
  assign eq_tilex       = eq_d.tilex;
  assign eq_tiley       = eq_d.tiley;
  assign eq_z_keep      = eq_d.z_keep;
  assign eq_no_writeout = eq_d.no_writeout;
  assign eq_last        = eq_d.last;
  assign eq_shaded_any  = eq_d.shaded_any;
endmodule
