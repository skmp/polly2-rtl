// fp_add24_spp_ro must be BIT-EXACT to combinational fp_add24. FIFO-ordered compare
// (see spp_ro_check.h); 0 tolerance.
#include "Vfp_add24_spp_ro_tb_top.h"
#include "verilated.h"
#include "spp_ro_check.h"
#include <cstdlib>

static Vfp_add24_spp_ro_tb_top* dut;

static uint32_t randf() {
    int r = rand() % 12;
    if (r == 0) return (uint32_t)(rand()&1) << 31;   // +/-0 (DaZ)
    uint32_t s = rand()&1;
    uint32_t e = 1 + (rand()%254);
    uint32_t m = rand() & 0x7FFFFF;
    return (s<<31)|(e<<23)|m;
}

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    dut = new Vfp_add24_spp_ro_tb_top;
    srand(0xADD24C0F);

    dut->reset = 1; dut->in_valid = 0; dut->a = 0; dut->b_in = 0; dut->sub = 0;
    for (int i=0;i<4;i++) tick();
    dut->reset = 0;

    SppChecker chk("fp_add24_spp_ro");
    long N = 3000000;
    for (long i=0; i<N; i++) {
        uint32_t a = randf(), b = randf();
        uint32_t s = rand()&1;
        if ((rand()%8)==0) { b = a ^ 0x80000000u; }  // near-total cancellation (deep LZ)
        dut->a = a; dut->b_in = b; dut->sub = s; dut->in_valid = 1;
        dut->eval();
        tick();
        chk.step(dut->y_ref, dut->out_valid, dut->y, i);
    }
    int rc = chk.report(N);
    dut->final(); delete dut;
    return rc;
}
