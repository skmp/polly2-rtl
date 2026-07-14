// fp_mul16_spp_ro must be BIT-EXACT to combinational fp_mul16. in_valid is held high
// and stall tied low, so the DUT emits one out_valid per input IN ORDER; we FIFO the
// combinational ref and compare the k-th valid output to the k-th input's ref (offset-
// agnostic). Any mismatch is a hard failure (0 tolerance).
#include "Vfp_mul16_spp_ro_tb_top.h"
#include "verilated.h"
#include "spp_ro_check.h"
#include <cstdlib>

static Vfp_mul16_spp_ro_tb_top* dut;

static uint32_t randf() {
    int r = rand() % 16;
    if (r == 0) return (rand()&1) ? 0x3F800000u : 0xBF800000u;   // +/-1.0 passthrough
    if (r == 1) return (uint32_t)(rand()&1) << 31;                // +/-0 (DaZ)
    uint32_t s = rand()&1;
    uint32_t e = 1 + (rand()%254);
    uint32_t m = rand() & 0x7FFFFF;
    return (s<<31)|(e<<23)|m;
}

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    dut = new Vfp_mul16_spp_ro_tb_top;
    srand(0x16C0FFEE);

    dut->reset = 1; dut->in_valid = 0; dut->a = 0; dut->b = 0;
    for (int i=0;i<4;i++) tick();
    dut->reset = 0;

    SppChecker chk("fp_mul16_spp_ro");
    long N = 3000000;
    for (long i=0; i<N; i++) {
        uint32_t a = randf(), b = randf();
        dut->a = a; dut->b = b; dut->in_valid = 1;
        dut->eval();                       // settle comb ref for this input
        tick();
        chk.step(dut->y_ref, dut->out_valid, dut->y, i);
    }
    int rc = chk.report(N);
    dut->final(); delete dut;
    return rc;
}
