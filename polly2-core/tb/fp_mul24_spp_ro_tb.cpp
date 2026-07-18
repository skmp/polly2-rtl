// fp_mul24_spp_ro must be BIT-EXACT to combinational fp_mul24. in_valid is held high
// and stall tied low, so the DUT emits one out_valid per input IN ORDER; we FIFO the
// combinational ref and compare the k-th valid output to the k-th input's ref (offset-
// agnostic). Any mismatch is a hard failure (0 tolerance).
// The combinational ref itself is ALSO checked against an independent C model of the
// full-mantissa truncating multiply, so a shared RTL bug can't self-certify. This
// includes the (implicit) +/-1.0 exact passthrough: at full precision *1.0 must
// reproduce the other operand bit-for-bit through the NORMAL path.
#include "Vfp_mul24_spp_ro_tb_top.h"
#include "verilated.h"
#include "spp_ro_check.h"
#include <cstdlib>
#include <cstdio>

static Vfp_mul24_spp_ro_tb_top* dut;

// independent software model: full 1.23 significands, 48-bit product, truncate,
// DaZ, overflow saturates to {s,FE,7FFFFF}, underflow flushes to signed zero.
static uint32_t model_mul24(uint32_t a, uint32_t b) {
    uint32_t s  = (a ^ b) & 0x80000000u;
    uint32_t ea = (a >> 23) & 0xFF, eb = (b >> 23) & 0xFF;
    if (!ea || !eb) return s;                                // DaZ
    uint64_t p = (uint64_t)((a & 0x7FFFFF) | 0x800000)
               * (uint64_t)((b & 0x7FFFFF) | 0x800000);      // 24x24 -> 48
    int e = (int)ea + (int)eb - 127;
    uint32_t mant;
    if (p >> 47) { mant = (uint32_t)(p >> 24) & 0x7FFFFF; e++; }
    else         { mant = (uint32_t)(p >> 23) & 0x7FFFFF; }
    if (e <= 0)   return s;
    if (e >= 255) return s | (0xFEu << 23) | 0x7FFFFF;
    return s | ((uint32_t)e << 23) | mant;
}

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
    dut = new Vfp_mul24_spp_ro_tb_top;
    srand(0x24C0FFEE);

    dut->reset = 1; dut->in_valid = 0; dut->a = 0; dut->b = 0;
    for (int i=0;i<4;i++) tick();
    dut->reset = 0;

    SppChecker chk("fp_mul24_spp_ro");
    long model_mism = 0;
    long N = 3000000;
    for (long i=0; i<N; i++) {
        uint32_t a = randf(), b = randf();
        dut->a = a; dut->b = b; dut->in_valid = 1;
        dut->eval();                       // settle comb ref for this input
        if (dut->y_ref != model_mul24(a, b) && model_mism++ < 15)
            printf("[%ld] MODEL MISMATCH a=%08x b=%08x rtl=%08x model=%08x\n",
                   i, a, b, (uint32_t)dut->y_ref, model_mul24(a, b));
        tick();
        chk.step(dut->y_ref, dut->out_valid, dut->y, i);
    }
    int rc = chk.report(N);
    if (model_mism) { printf("fp_mul24 comb vs C model: %ld mismatches\n", model_mism); rc = 1; }
    dut->final(); delete dut;
    return rc;
}
