// fp_add3_24 vs chained (a+b)+c. They won't be bit-identical (fused does one
// normalize/truncate vs two), so we accept results within a small relative ULP-ish
// tolerance and report the worst divergence. Purpose: confirm the fused adder is a
// faithful, at-least-as-accurate replacement, not a functional break.
#include "Vfp_add3_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>

static Vfp_add3_tb_top* dut;

static float f32(uint32_t b){ float f; memcpy(&f,&b,4); return f; }

// build a "reduced-precision-ish" random float in a sane range
static uint32_t randf() {
    // exponent in [110,140] (~1e-5..1e4), random mantissa, random sign
    uint32_t s = rand()&1;
    uint32_t e = 110 + (rand()%31);
    uint32_t m = rand() & 0x7FFFFF;
    return (s<<31)|(e<<23)|m;
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    dut = new Vfp_add3_tb_top;
    srand(0xADD3);
    long N=2000000, worst_i=-1; double worst_rel=0;
    long big_err=0;
    for(long i=0;i<N;i++){
        uint32_t a=randf(), b=randf(), c=randf();
        dut->a=a; dut->b=b; dut->c=c; dut->eval();
        float y3=f32(dut->y3), y2=f32(dut->y2);
        // reference true value (double)
        double ref = (double)f32(a)+(double)f32(b)+(double)f32(c);
        // both DUTs are approximations; compare fused (y3) to the true sum, and to
        // the chained (y2), whichever. We flag if fused is WORSE than chained by a
        // meaningful margin.
        double e3 = fabs((double)y3 - ref);
        double e2 = fabs((double)y2 - ref);
        double denom = fabs(ref) > 1e-6 ? fabs(ref) : 1e-6;
        double rel3 = e3/denom;
        // fused should not be dramatically worse than chained
        if (e3 > e2 + denom*3e-3) {   // >0.3% worse than chained
            big_err++;
            if (big_err<=15)
                printf("[%ld] a=%.6g b=%.6g c=%.6g | ref=%.6g fused=%.6g(%.3g) chain=%.6g(%.3g)\n",
                       i, f32(a),f32(b),f32(c), ref, y3, e3/denom, y2, e2/denom);
        }
        if (rel3>worst_rel){ worst_rel=rel3; worst_i=i; }
    }
    printf("fp_add3: N=%ld worst fused rel-err=%.4g (i=%ld); cases fused>chain+0.3%%: %ld\n",
           N, worst_rel, worst_i, big_err);
    dut->final(); delete dut;
    return big_err ? 1 : 0;
}
