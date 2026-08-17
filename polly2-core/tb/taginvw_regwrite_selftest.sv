// self-checking test for taginvw_tile_buffer's REGISTERED WRITE PORT (REG_WRITE=1).
//
// WHY THE PIPELINE EXISTS: wr_we is peel_tile_buffer's stage-B accept, which is
// combinational off ITS tile_ram read data through isp_depth_cmp_lp's compare chain.
// Unregistered, "peel M10K rdata -> 5-level compare -> we[] -> THIS M10K's write-enable
// pin" was one single-cycle path and the worst in the design (-5.391 ns at 143 MHz).
// Registering {we, waddr, wdata} together breaks it. This buffer never reads itself to
// decide a write, so there is no RMW loop to close and the write may simply land later.
//
// WHAT THIS PINS DOWN:
//   1) EQUIVALENCE   - a REG_WRITE=1 and a REG_WRITE=0 instance, driven with identical
//                      stimulus that respects the one-cycle spacing contract, return
//                      bit-identical reads on every port, every cycle. This is the claim
//                      that matters: the pipeline changes WHEN a write lands, not WHAT.
//   2) EXACTLY ONE   - the write lands exactly one cycle late. Read at T+1 after a write
//      CYCLE LATE      presented at T still returns the OLD value (read-first RAM), read
//                      at T+2 returns the new one. Not zero cycles, not two.
//   3) THE ASSERTION - the in-module collision check actually FIRES on the illegal
//      IS REAL         pattern, rather than being dead code that happens never to trip.
//                      The DUT counts collisions into collide_cnt as well as reporting
//                      them, so this tb can deliberately commit the violation (with the
//                      $error suppressed via CHK_COLLIDE=0) and then assert the detector
//                      saw exactly it. Without this, "golden-check never tripped the
//                      assertion" would be worth nothing.
//
// The three write clients (raster duplicate / CLEAR / PeelBuffers walk) all go through
// the same registered port, so all three are covered by the equivalence sweep.
//
module taginvw_regwrite_selftest import tsp_pkg::*; #(
    parameter integer LANES  = 8,
    parameter integer COPIES = 4
) ;
    localparam integer BW  = $clog2(LANES);
    localparam integer TAW = 10 - BW;
    localparam integer CBW = (COPIES > 1) ? $clog2(COPIES) : 1;

    reg clk=0; always #5 clk=~clk;
    reg reset;

    reg  [CBW-1:0]      wr_buf, rd_buf;
    reg                 wr_valid;
    reg  [LANES-1:0]    wr_we;
    reg  [4:0]          wr_y, wr_x;
    reg  [31:0]         wr_tag;
    reg  [31*LANES-1:0] wr_invw;
    reg                 wr_pt;
    reg                 clr_valid; reg [TAW-1:0] clr_addr; reg [30:0] clr_depth; reg [31:0] clr_tag;
    reg                 pbc_valid; reg [TAW-1:0] pbc_addr;
    reg                 rd4_valid; reg [9:0] rd4_group;
    reg                 sh_rd_valid; reg [9:0] sh_rd_id;

    // ---- two DUTs, identical but for REG_WRITE ----
    wire [3:0]  g4_valid_r, g4_pt_r, g4_valid_c, g4_pt_c;
    wire [31:0] g4_tag_r [0:3];  wire [30:0] g4_invw_r [0:3];
    wire [31:0] g4_tag_c [0:3];  wire [30:0] g4_invw_c [0:3];
    wire        sh_valid_r, sh_pt_r, sh_valid_c, sh_pt_c;
    wire [31:0] sh_tag_r, sh_tag_c;
    wire [30:0] sh_depth_r, sh_depth_c;

`define DUT_PORTS(gv, gt, gi, gp, sv, st, sd, sp)                                    \
        .clk(clk), .reset(reset),                                                    \
        .wr_buf(wr_buf), .rd_buf(rd_buf),                                            \
        .wr_valid(wr_valid), .wr_we(wr_we), .wr_y(wr_y), .wr_x(wr_x),                \
        .wr_tag(wr_tag), .wr_invw(wr_invw), .wr_pt(wr_pt),                           \
        .clr_valid(clr_valid), .clr_addr(clr_addr), .clr_depth(clr_depth),           \
        .clr_tag(clr_tag),                                                           \
        .pbc_valid(pbc_valid), .pbc_addr(pbc_addr),                                  \
        .sh_rd_valid(sh_rd_valid), .sh_rd_id(sh_rd_id),                              \
        .sh_valid(sv), .sh_tag(st), .sh_depth(sd), .sh_pt(sp),                       \
        .rd4_valid(rd4_valid), .rd4_group(rd4_group),                                \
        .g4_valid(gv), .g4_tag(gt), .g4_invw(gi), .g4_pt(gp)

    // the shipping configuration
    // CHK_COLLIDE=0: part (2) below violates the spacing contract ON PURPOSE, and the
    // $error would $stop the run. The violation is still COUNTED, and part (3) checks it.
    taginvw_tile_buffer #(.LANES(LANES), .COPIES(COPIES), .REG_WRITE(1'b1),
                          .CHK_COLLIDE(1'b0)) dut_reg (
        `DUT_PORTS(g4_valid_r, g4_tag_r, g4_invw_r, g4_pt_r,
                   sh_valid_r, sh_tag_r, sh_depth_r, sh_pt_r));
    // the reference: old combinational write. Its own collision check is meaningless
    // (REG_WRITE=0 gates it off), so CHK_COLLIDE is left at its default.
    taginvw_tile_buffer #(.LANES(LANES), .COPIES(COPIES), .REG_WRITE(1'b0)) dut_comb (
        `DUT_PORTS(g4_valid_c, g4_tag_c, g4_invw_c, g4_pt_c,
                   sh_valid_c, sh_tag_c, sh_depth_c, sh_pt_c));

    integer errs = 0;
    integer k, l, c;
    // SEPARATE loop variables. wr_chunk runs inside the main sweep's own `for (k...)`,
    // so sharing `k` made every call reset the outer loop counter to LANES - an infinite
    // loop, not a slow test. `el` likewise keeps the concurrent equivalence checker off
    // the `l` the stimulus thread uses.
    integer wk, el;
    task fail(input string what);
        begin $display("FAIL: %s", what); errs = errs + 1; end
    endtask

    // ---- (1) EQUIVALENCE: compare both DUTs' read ports on EVERY cycle -----------
    // Runs for the whole test. Any divergence at all, on any port, is a failure. Only
    // meaningful while the stimulus respects the spacing contract, so the deliberate
    // violation in part (3) below runs with `eqv_on` lowered.
    // COMPARE ONLY WHERE THE OUTPUTS MEAN SOMETHING: one cycle after a read was
    // presented. On a cycle with no read asserted the module drives raddr to 0, so both
    // DUTs sit reading address 0 and show the one-cycle write skew there - a difference
    // that is real but that no consumer can observe, because peel_core only looks at
    // g4_*/sh_* in the cycle following its own rd4_valid/sh_rd_valid.
    reg eqv_on = 1'b0;
    reg rd4_v_q = 1'b0, sh_v_q = 1'b0;
    integer eqv_cycles = 0;
    always @(posedge clk) begin
        rd4_v_q <= rd4_valid;
        sh_v_q  <= sh_rd_valid;
    end
    always @(posedge clk) if (!reset && eqv_on) begin
        if (rd4_v_q || sh_v_q) eqv_cycles = eqv_cycles + 1;
        if (rd4_v_q) begin
            if (g4_valid_r !== g4_valid_c) fail("equivalence: g4_valid differs");
            if (g4_pt_r    !== g4_pt_c)    fail("equivalence: g4_pt differs");
            for (el = 0; el < 4; el = el + 1) begin
                if (g4_tag_r[el]  !== g4_tag_c[el])  fail($sformatf("equivalence: g4_tag[%0d] differs", el));
                if (g4_invw_r[el] !== g4_invw_c[el]) fail($sformatf("equivalence: g4_invw[%0d] differs", el));
            end
        end
        if (sh_v_q) begin
            if (sh_valid_r !== sh_valid_c) fail("equivalence: sh_valid differs");
            if (sh_tag_r   !== sh_tag_c)   fail("equivalence: sh_tag differs");
            if (sh_depth_r !== sh_depth_c) fail("equivalence: sh_depth differs");
            if (sh_pt_r    !== sh_pt_c)    fail("equivalence: sh_pt differs");
        end
    end

    // ---- stimulus helpers (all honour the one-cycle settle after a write) --------
    task settle; begin @(posedge clk); #1; end endtask

    task wr_chunk(input integer cp, input [4:0] y, input [4:0] xbase,
                  input [31:0] tag, input [30:0] iv0, input pt, input [LANES-1:0] lanes);
        begin
            wr_buf = cp[CBW-1:0]; wr_valid = 1'b1; wr_we = lanes;
            wr_y = y; wr_x = xbase; wr_tag = tag; wr_pt = pt;
            for (wk = 0; wk < LANES; wk = wk + 1) wr_invw[31*wk +: 31] = iv0 + 31'(wk);
            @(posedge clk); #1 wr_valid = 1'b0; wr_we = '0;
            settle;
        end
    endtask

    task rd4(input integer cp, input [4:0] y, input [4:0] x);
        begin
            rd_buf = cp[CBW-1:0]; rd4_valid = 1'b1; rd4_group = {y, x} & ~10'd3;
            @(posedge clk); #1 rd4_valid = 1'b0;
        end
    endtask

    task rd1(input integer cp, input [9:0] id);
        begin
            rd_buf = cp[CBW-1:0]; sh_rd_valid = 1'b1; sh_rd_id = id;
            @(posedge clk); #1 sh_rd_valid = 1'b0;
        end
    endtask

    initial begin
        reset = 1'b1;
        wr_valid=0; wr_we='0; wr_y=0; wr_x=0; wr_tag=0; wr_invw='0; wr_pt=0;
        clr_valid=0; clr_addr='0; clr_depth='0; clr_tag='0;
        pbc_valid=0; pbc_addr='0;
        rd4_valid=0; rd4_group=0; sh_rd_valid=0; sh_rd_id=0;
        wr_buf='0; rd_buf='0;
        repeat (4) @(posedge clk);
        #1 reset = 1'b0;
        @(posedge clk); #1;
        eqv_on = 1'b1;

        // ================= (1) EQUIVALENCE SWEEP =================
        // Randomised traffic over all three write clients and both read ports, always
        // with a settle cycle after a write. The always-block above is doing the
        // checking; this just has to generate enough varied traffic.
        for (k = 0; k < 400; k = k + 1) begin
            c = k % COPIES;
            case (k % 8)
              0,1,2,3: wr_chunk(c, 5'((k*7) % 32), 5'((k*3) % 32),
                                32'hA5A5_0000 | k[15:0], 31'd1000 + 31'(k*LANES),
                                k[0], {LANES{1'b1}});
              4:       wr_chunk(c, 5'((k*7) % 32), 5'((k*3) % 32),
                                32'h5A5A_0000 | k[15:0], 31'd2000 + 31'(k),
                                k[1], LANES'(k));            // partial lane mask
              5: begin                                        // CLEAR walk
                     wr_buf = c[CBW-1:0]; clr_valid = 1'b1;
                     clr_addr = TAW'(k); clr_depth = 31'h1234_000 + 31'(k);
                     clr_tag = 32'h0BAD_0000 | k[15:0];
                     @(posedge clk); #1 clr_valid = 1'b0;
                     settle;
                 end
              6: begin                                        // PeelBuffers valid-clear
                     wr_buf = c[CBW-1:0]; pbc_valid = 1'b1; pbc_addr = TAW'(k);
                     @(posedge clk); #1 pbc_valid = 1'b0;
                     settle;
                 end
              7: ;                                            // idle cycle
            endcase
            // read both ports back, from a copy that may or may not be the write copy
            rd4((k+1) % COPIES, 5'((k*7) % 32), 5'((k*3) % 32));
            rd1((k+2) % COPIES, 10'((k*13) % 1024));
        end
        if (eqv_cycles < 400)
            fail($sformatf("equivalence checker only compared %0d read results - stimulus too short",
                           eqv_cycles));

        // ================= (2) EXACTLY ONE CYCLE LATE =================
        // Seed a known value, then overwrite it and watch when the change appears.
        wr_chunk(0, 5'd9, 5'd0, 32'hDEAD_0000, 31'd500, 1'b0, {LANES{1'b1}});
        if (dut_reg.collide_cnt !== 0)
            fail($sformatf("(1) equivalence sweep tripped %0d collisions - the settle-cycle contract is not being honoured by this tb",
                           dut_reg.collide_cnt));
        rd4(0, 5'd9, 5'd0);
        if (g4_tag_r[0] !== 32'hDEAD_0000) fail("(2) seed not visible");

        // present the overwrite at cycle T (no settle - we want to look at T+1 and T+2)
        wr_buf = '0; wr_valid = 1'b1; wr_we = {LANES{1'b1}};
        wr_y = 5'd9; wr_x = 5'd0; wr_tag = 32'hBEEF_0000; wr_pt = 1'b0;
        for (wk = 0; wk < LANES; wk = wk + 1) wr_invw[31*wk +: 31] = 31'd700 + 31'(wk);
        @(posedge clk); #1 wr_valid = 1'b0; wr_we = '0;
        // T+1: the registered write is landing on THIS edge; read-first -> still OLD.
        // (this is the illegal pattern, so drop the equivalence check and the in-module
        //  assertion for it - see part 3)
        eqv_on = 1'b0;
        rd4(0, 5'd9, 5'd0);
        if (g4_tag_r[0] !== 32'hDEAD_0000)
            fail($sformatf("(2) REG_WRITE landed too early: T+1 tag %08x, expected the OLD %08x",
                           g4_tag_r[0], 32'hDEAD_0000));
        if (g4_tag_c[0] !== 32'hBEEF_0000)
            fail($sformatf("(2) the COMBINATIONAL reference should already show the new tag, got %08x",
                           g4_tag_c[0]));
        // T+2: now it must be there.
        rd4(0, 5'd9, 5'd0);
        if (g4_tag_r[0] !== 32'hBEEF_0000)
            fail($sformatf("(2) REG_WRITE landed too late: T+2 tag %08x, expected %08x",
                           g4_tag_r[0], 32'hBEEF_0000));
        for (l = 0; l < 4; l = l + 1)
            if (g4_invw_r[l] !== 31'd700 + 31'(l))
                fail($sformatf("(2) T+2 invw[%0d] = %0d, expected %0d",
                               l, g4_invw_r[l], 31'd700 + 31'(l)));
        eqv_on = 1'b1;

        // ================= (3) THE COLLISION DETECTOR IS LIVE =================
        // Part (2) presented a read on the exact cycle the delayed write landed, at the
        // same address. That is the one pattern peel_core's ti_ready credit is required
        // to make impossible, and the in-module check must have seen it. If this reads 0
        // the detector is broken and its silence during golden-check proves nothing.
        if (dut_reg.collide_cnt == 0)
            fail("(3) collision detector never fired on a deliberate same-cycle read/write - the check is dead code");
        else
            $display("  (3) collision detector fired %0d time(s) on the deliberate violation - live",
                     dut_reg.collide_cnt);

        if (errs == 0)
            $display("taginvw_regwrite_selftest PASS (LANES=%0d COPIES=%0d, %0d equivalence cycles)",
                     LANES, COPIES, eqv_cycles);
        else
            $display("taginvw_regwrite_selftest: %0d FAILURES", errs);
        $finish;
    end
endmodule
