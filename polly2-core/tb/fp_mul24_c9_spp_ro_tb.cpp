// fp_mul24_c9_spp_ro must be BIT-EXACT to combinational fp_mul24_c9. FIFO-ordered
// compare (see spp_ro_check.h); 0 tolerance. The combinational ref itself is ALSO
// checked against an independent C model of float * 9-bit-signed with a full-mantissa
// truncated result, so a shared RTL bug can't self-certify.
#include "Vfp_mul24_c9_spp_ro_tb_top.h"
#include "verilated.h"
#include "spp_ro_check.h"
#include <cstdlib>
#include <cstdio>

static Vfp_mul24_c9_spp_ro_tb_top* dut;

// independent software model: y = f * k, full 1.23 significand, 24x9 -> 33-bit
// product, truncate to 23 fractional bits, DaZ, k==0 -> signed zero, overflow
// saturates. No underflow is possible (|k| >= 1 -> e >= ef >= 1).
static uint32_t model_mul24_c9(uint32_t f, int k) {
    uint32_t s  = (f & 0x80000000u) ^ (k < 0 ? 0x80000000u : 0);
    uint32_t ef = (f >> 23) & 0xFF;
    if (!ef || k == 0) return s;                             // DaZ / k==0
    uint64_t kabs = (k < 0) ? (uint64_t)(-(int64_t)k) : (uint64_t)k;   // 1..256
    uint64_t p = (uint64_t)((f & 0x7FFFFF) | 0x800000) * kabs;         // <= 33 bits
    int sh = 0;
    while (p >> (24 + sh)) sh++;                             // leading one -> bit 23+sh
    uint32_t mant = (uint32_t)(p >> sh) & 0x7FFFFF;
    int e = (int)ef + sh;
    if (e >= 255) return s | (0xFEu << 23) | 0x7FFFFF;
    return s | ((uint32_t)e << 23) | mant;
}

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
    dut = new Vfp_mul24_c9_spp_ro_tb_top;
    srand(0xC924C0FE);

    dut->reset = 1; dut->in_valid = 0; dut->f = 0; dut->k = 0;
    for (int i=0;i<4;i++) tick();
    dut->reset = 0;

    SppChecker chk("fp_mul24_c9_spp_ro");
    long model_mism = 0;
    long N = 3000000;
    for (long i=0; i<N; i++) {
        uint32_t f = randf();
        // k: the real datapath uses 0..255 colour channels (plus 0 edge). include the
        // full 9-bit signed range anyway to cover the |k| path.
        uint32_t k = (rand()%8==0) ? 0 : (rand() & 0x1FF);
        dut->f = f; dut->k = k; dut->in_valid = 1;
        dut->eval();
        int ks = (k & 0x100) ? (int)k - 512 : (int)k;        // sign-extend 9-bit raw
        if (dut->y_ref != model_mul24_c9(f, ks) && model_mism++ < 15)
            printf("[%ld] MODEL MISMATCH f=%08x k=%d rtl=%08x model=%08x\n",
                   i, f, ks, (uint32_t)dut->y_ref, model_mul24_c9(f, ks));
        tick();
        chk.step(dut->y_ref, dut->out_valid, dut->y, i);
    }
    int rc = chk.report(N);
    if (model_mism) { printf("fp_mul24_c9 comb vs C model: %ld mismatches\n", model_mism); rc = 1; }
    dut->final(); delete dut;
    return rc;
}
