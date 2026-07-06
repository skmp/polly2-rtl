#!/usr/bin/env python3
# gen_stage_harnesses.py - generate one timing harness (top module + Quartus project)
# per pipeline STAGE of tsp_shade_pp, under timming_tests/<stage>/.
#
# Each harness follows the same pattern as tsp_shade_pp_ddr:
#   input register bank (HPS-writable)  ->  the stage's combinational unit(s)
#   ->  RAW registered outputs (pure stage timing)  ->  XOR-fold to one `digest`
#       pin the NEXT cycle (fold tree never contaminates the measured paths).
#
# Purely-combinational stages use a plain clk/reset top (no DDR). The TEX stage
# needs DDR + the two texture caches, so it reuses the full DDR-backed wrapper
# (tsp_shade_pp_ddr already isolates the whole shade pipe incl. TEX; the per-stage
# TEX harness here isolates JUST the 4 fetchers + caches).
#
# Run:  python3 timming_tests/gen_stage_harnesses.py   (from simplex/)
#
import os

ROOT = os.path.dirname(os.path.abspath(__file__))          # .../simplex/timming_tests
SIMPLEX = os.path.dirname(ROOT)                            # .../simplex

DEVICE = "5CSEBA6U23I7"
QUARTUS_VER = "17.0.0 Standard Edition"

# Files every project needs before the stage's own RTL (package first). Paths are
# in the SAME bare "rtl/..." form as each stage's deps; rel() prepends the "../../"
# that makes them relative to timming_tests/<stage>/.
COMMON_HEAD = [
    "rtl/tsp/tsp_pkg.sv",
]

# ---------------------------------------------------------------------------
# Per-stage definitions. Each entry:
#   deps  : RTL files the stage instantiates (relative to the project dir, i.e.
#           two levels up from timming_tests/<stage>/)
#   body  : the generated top-module Verilog (input bank + stage + capture/fold)
#   clk   : "plain"  -> clk/reset ports + clk-based SDC
#           "ddr"    -> sysmem_lite bridge + core_clk SDC (TEX only)
# ---------------------------------------------------------------------------

def rel(p):  # rtl path relative to timming_tests/<stage>/
    return "../../" + p

# ---- plain combinational-stage harness template -------------------------------
def plain_top(name, deps, decls, inst, raw_width, raw_expr, comment):
    """
    raw_width : bit width of the stage's raw output vector.
    raw_expr  : a Verilog concatenation of ALL the stage's outputs (== raw_width bits).
    The template registers `raw_expr` VERBATIM (no logic between stage and flop, so the
    captured path is the PURE stage timing), then XOR-folds the REGISTERED vector to the
    single `digest` pin one cycle later - the fold tree is off the register, never in the
    measured stage->flop path.
    """
    dep_lines = "\n".join(
        f"set_global_assignment -name SYSTEMVERILOG_FILE {rel(d)}" for d in COMMON_HEAD + deps)
    return dep_lines, f"""//
// {name} - per-stage timing harness for tsp_shade_pp.
// {comment}
//
// Pattern: HPS-writable input reg bank -> stage (combinational) -> RAW registered
// output vector (PURE stage timing, no logic before the flop) -> XOR-fold the
// REGISTERED vector to `digest` the NEXT cycle (fold tree off the register).
//
module {name} import tsp_pkg::*; (
    input             clk,
    input             reset,
    input             wr_en,
    input      [12:0] wr_addr,
    input      [31:0] wr_data,
    output reg        digest
);
    // ---- input register bank (every stage input has a real register source) ----
    localparam integer NREG = 64;
    reg [31:0] in_reg [0:NREG-1];
    integer ir;
    always @(posedge clk) begin
        if (reset) begin
            for (ir=0; ir<NREG; ir=ir+1) in_reg[ir] <= 32'd0;
        end else if (wr_en && wr_addr < NREG) begin
            in_reg[wr_addr] <= wr_data;
        end
    end

{decls}

{inst}

    // ---- RAW capture: register the stage's whole output vector with NO logic in
    //      between, so this flop's setup path IS the pure stage delay. ----
    reg [{raw_width-1}:0] raw_cap;
    always @(posedge clk) begin
        if (reset) raw_cap <= '0;
        else       raw_cap <= {raw_expr};
    end

    // ---- next cycle: XOR-fold the REGISTERED vector to one `digest` pin (keeps every
    //      output bit alive; this reduce tree is off raw_cap, not the stage). ----
    always @(posedge clk) begin
        if (reset) digest <= 1'b0;
        else       digest <= ^raw_cap;
    end
endmodule
"""

# ---- stage bodies ----

def stage_rcp():
    decls = "    wire ov; wire [31:0] y;"
    inst  = ("    fp_rcp_fast u_dut (.clk(clk),.reset(reset),.stall(1'b0),\n"
             "        .in_valid(in_reg[1][0]),.x(in_reg[0]),.out_valid(ov),.y(y));")
    # raw = {ov, y} = 33 bits
    return plain_top("stage_rcp", ["rtl/isp_min/fp_rcp_fast.sv"],
                     decls, inst, 33, "{ ov, y }",
                     "STAGE RCP: W = 1/invW (fp_rcp_fast, 3-clock).")

def stage_i1():
    # ONE fp_mul_i5_pp (pipelined 2-stage mul). The 10 planes are independent+identical,
    # so a single instance has the same critical path (Fmax) as 20 - instantiate one for
    # a clean timing probe. clk/reset/stall/in_valid->out_valid. raw = {ov, product}.
    decls = "    wire [31:0] prod; wire ov;"
    inst = ("    fp_mul_i5_pp mx (.clk(clk),.reset(reset),.stall(in_reg[34][0]),.in_valid(in_reg[34][1]),\n"
            "        .f(in_reg[0]),.k(in_reg[32][4:0]),.out_valid(ov),.y(prod));")
    return plain_top("stage_i1", ["rtl/isp_min/fp_mul_i5_pp.sv"],
                     decls, inst, 33, "{ ov, prod }",
                     "STAGE INTERP i1: fp_mul_i5_pp (pipelined 2-stage mul, 1 instance).")

def stage_i2():
    # ONE fp_add3_24_pp (pipelined 5-stage 3-way add). One instance = same Fmax as 10.
    decls = "    wire [31:0] s; wire ov;"
    inst = ("    fp_add3_24_pp a (.clk(clk),.reset(reset),.stall(in_reg[34][0]),.in_valid(in_reg[34][1]),\n"
            "        .a(in_reg[0]),.b(in_reg[10]),.c(in_reg[20]),.out_valid(ov),.y(s));")
    return plain_top("stage_i2", ["rtl/isp_min/fp_add3_24_pp.sv"],
                     decls, inst, 33, "{ ov, s }",
                     "STAGE INTERP i2: fp_add3_24_pp (pipelined 5-stage 3-way add, 1 instance).")

def stage_i3():
    # ONE fp_mul16_pp (pipelined 2-stage mul). One instance = same Fmax as 10.
    decls = "    wire [31:0] a; wire ov;"
    inst = ("    fp_mul16_pp m (.clk(clk),.reset(reset),.stall(in_reg[34][0]),.in_valid(in_reg[34][1]),\n"
            "        .a(in_reg[0]),.b(in_reg[32]),.out_valid(ov),.y(a));")
    return plain_top("stage_i3", ["rtl/isp_min/fp_mul16_pp.sv"],
                     decls, inst, 33, "{ ov, a }",
                     "STAGE INTERP i3: fp_mul16_pp (pipelined 2-stage sum * W, 1 instance).")

def stage_mip():
    # tsp_miplevel is now a STREAMED 2-stage pipeline (clk/reset/stall + in_valid->
    # out_valid). The harness buffers in (in_reg) and out (raw_cap); DUT buffers
    # neither. `stall` from a control bit exercises the hold path. Capture out_valid
    # alongside miplevel so both stay alive through the fold.
    decls = "    wire [3:0] lvl; wire mv;"
    inst = ("    tsp_miplevel u_dut (\n"
            "        .clk(clk),.reset(reset),.stall(in_reg[5][30]),.in_valid(in_reg[5][29]),\n"
            "        .ddxU(in_reg[0]),.ddxV(in_reg[1]),.ddyU(in_reg[2]),.ddyV(in_reg[3]),\n"
            "        .w(in_reg[4]),.texu(in_reg[5][2:0]),.mipmapd(in_reg[5][11:8]),\n"
            "        .mipmapped(in_reg[5][31]),.out_valid(mv),.miplevel(lvl));")
    return plain_top("stage_mip", ["rtl/tsp/tsp_miplevel.sv"],
                     decls, inst, 5, "{ mv, lvl }",
                     "STAGE MIP: tsp_miplevel (streamed 2-stage exponent-domain LOD).")

def stage_uv():
    # tex_uvmap is now a STREAMED 3-stage pipeline (clk/reset/stall + in_valid->
    # out_valid). The harness buffers in (in_reg) and out (raw_cap); the DUT buffers
    # neither. `stall` is driven from a control bit so the hold path is present. The
    # 8x f2u8 are combinational off in_reg (shallow, not the limiter); registered into
    # raw_cap alongside the UV outputs. out_valid is captured so it stays alive.
    decls = ("    wire [10:0] c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v; wire [7:0] uf,vf;\n"
             "    wire uvv; wire [7:0] u8 [2:9]; genvar gi;")
    inst = ("    tex_uvmap u_uv (\n"
            "        .clk(clk),.reset(reset),.stall(in_reg[3][8]),.in_valid(in_reg[3][9]),\n"
            "        .u(in_reg[0]),.v(in_reg[1]),.texu(in_reg[2][5:3]),.texv(in_reg[2][2:0]),\n"
            "        .miplevel(in_reg[3][3:0]),\n"
            "        .clampu(in_reg[2][16]),.clampv(in_reg[2][15]),.flipu(in_reg[2][18]),.flipv(in_reg[2][17]),\n"
            "        .out_valid(uvv),\n"
            "        .c00u(c00u),.c00v(c00v),.c01u(c01u),.c01v(c01v),\n"
            "        .c10u(c10u),.c10v(c10v),.c11u(c11u),.c11v(c11v),.ufrac(uf),.vfrac(vf));\n"
            "    generate for (gi=2; gi<=9; gi=gi+1) begin : cvt\n"
            "        f2u8 u_c (.f(in_reg[10+gi]),.u(u8[gi]));\n"
            "    end endgenerate")
    # raw = uvv(1) + 8x11 corner coords (88) + uf,vf (16) + 8x8 u8 (64) = 169 bits
    raw = ("{ uvv, c00u,c00v,c01u,c01v,c10u,c10v,c11u,c11v, uf, vf,\n"
           "               u8[2],u8[3],u8[4],u8[5],u8[6],u8[7],u8[8],u8[9] }")
    return plain_top("stage_uv", ["rtl/tsp/tex_uvmap.sv","rtl/tsp/f2u8.sv"],
                     decls, inst, 169, raw,
                     "STAGE UV: tex_uvmap (streamed 3-stage) + 8x f2u8.")

def stage_filt():
    # tex_filter is now a STREAMED 4-stage pipeline (clk/reset + in_valid->out_valid).
    # The harness buffers in (in_reg) and out (raw_cap); the DUT buffers neither. We
    # register `textel` (raw) into raw_cap, capturing out_valid alongside so every
    # output bit stays alive through the fold.
    decls = "    wire [31:0] t; wire tv;"
    inst = ("    tex_filter u_dut (.clk(clk),.reset(reset),.in_valid(in_reg[8][2]),\n"
            "        .filter(in_reg[8][0]),.ignore_texa(in_reg[8][1]),\n"
            "        .ufrac(in_reg[9][7:0]),.vfrac(in_reg[9][15:8]),\n"
            "        .t00(in_reg[0]),.t01(in_reg[1]),.t10(in_reg[2]),.t11(in_reg[3]),\n"
            "        .out_valid(tv),.textel(t));")
    return plain_top("stage_filt", ["rtl/tsp/tex_filter.sv"],
                     decls, inst, 33, "{ tv, t }",
                     "STAGE FILT: tex_filter (streamed 4-stage bilinear/nearest blend).")

def stage_comb():
    # color_combiner is now a STREAMED 3-stage pipeline (clk/reset + in_valid->
    # out_valid, no stall - the COMB back-half advances on valid). Harness buffers
    # in (in_reg) and out (raw_cap); DUT buffers neither. Capture out_valid alongside.
    decls = "    wire [31:0] col; wire cv;"
    inst = ("    color_combiner u_dut (.clk(clk),.reset(reset),.in_valid(in_reg[8][4]),\n"
            "        .pp_texture(in_reg[8][0]),.pp_offset(in_reg[8][1]),\n"
            "        .shadinstr(in_reg[8][3:2]),.base(in_reg[0]),.textel(in_reg[1]),\n"
            "        .offset(in_reg[2]),.out_valid(cv),.col(col));")
    return plain_top("stage_comb", ["rtl/tsp/color_combiner.sv"],
                     decls, inst, 33, "{ cv, col }",
                     "STAGE COMB: color_combiner (streamed 3-stage texenv + offset).")

PLAIN_STAGES = {
    "stage_rcp":  stage_rcp,
    "stage_i1":   stage_i1,
    "stage_i2":   stage_i2,
    "stage_i3":   stage_i3,
    "stage_mip":  stage_mip,
    "stage_uv":   stage_uv,
    "stage_filt": stage_filt,
    "stage_comb": stage_comb,
}

# ---- SDC / QSF / QPF templates ------------------------------------------------

SDC_PLAIN = """# per-stage timing harness clock. A real top-level `clk` pin (10 ns / 100 MHz
# target); reported Fmax comes from real path delay regardless.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
"""

SDC_DDR = """# TEX stage runs on the HPS-provided core clock (h2f_user0_clk); constrain the
# CLKENA buffer the HPS clock reaches the fabric through (see simplex.sdc).
create_clock -name core_clk -period 10.000 \\
    [get_pins -compatibility_mode {*h2f_user0_clk*~CLKENA0*}]
derive_pll_clocks
derive_clock_uncertainty
"""

def qsf(name, dep_lines, ddr):
    macros = 'set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"\n'
    sdc = "stage.sdc"
    return f"""# {name} - standalone Quartus timing project (one tsp_shade_pp pipeline stage).
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE {DEVICE}
set_global_assignment -name LAST_QUARTUS_VERSION "{QUARTUS_VER}"

set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"
set_global_assignment -name OPTIMIZATION_TECHNIQUE SPEED

{macros}
set_global_assignment -name SEARCH_PATH .
set_global_assignment -name SEARCH_PATH ../../rtl/tsp/gen

{dep_lines}
set_global_assignment -name SDC_FILE {sdc}

set_global_assignment -name TOP_LEVEL_ENTITY {name}
"""

def qpf(name):
    return f'QUARTUS_VERSION = "17.0"\nPROJECT_REVISION = "{name}"\n'


def write_stage(name, dep_lines, verilog, ddr=False):
    d = os.path.join(ROOT, name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"{name}.sv"), "w") as f: f.write(verilog)
    with open(os.path.join(d, f"{name}.qsf"), "w") as f: f.write(qsf(name, dep_lines, ddr))
    with open(os.path.join(d, f"{name}.qpf"), "w") as f: f.write(qpf(name))
    with open(os.path.join(d, "stage.sdc"), "w") as f: f.write(SDC_DDR if ddr else SDC_PLAIN)
    # the top .sv is itself a source; append it to the fileset
    with open(os.path.join(d, f"{name}.qsf"), "a") as f:
        f.write(f"set_global_assignment -name SYSTEMVERILOG_FILE {name}.sv\n")
    print(f"  wrote {name}/")


def main():
    print("generating plain (combinational) stage harnesses:")
    for name, fn in PLAIN_STAGES.items():
        dep_lines, verilog = fn()
        write_stage(name, dep_lines, verilog, ddr=False)
    print("done. (TEX stage handled separately - see stage_tex/.)")

if __name__ == "__main__":
    main()
