// tsp_setup_stream (II=2 rewrite) vs tsp_setup_min on random triangles.
//
// The two are NOT bit-exact by design (stream: no t15 delta truncation, fused 3-way c,
// clean adds), so both are compared against a double-precision reference of the same
// math; the stream must not be meaningfully worse than min. Also checks:
//   * exactly the enabled plane set is emitted, each idx once, both units
//   * per-triangle cycle counts (reports averages; sanity-bounds the stream)
#include "Vtsp_setup_stream_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

static Vtsp_setup_stream_tb_top* dut;

static float    f32(uint32_t b){ float f; memcpy(&f,&b,4); return f; }
static uint32_t b32(float f){ uint32_t b; memcpy(&b,&f,4); return b; }

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static float frnd(float lo, float hi) { return lo + (hi-lo) * (rand() / (float)RAND_MAX); }

struct Plane { bool got; double ddx, ddy, c; };

// run one unit (sel: 0=min, 1=stream) on the already-applied inputs; returns cycles
static int run_unit(int sel, Plane out[10]) {
    for (int i=0;i<10;i++) out[i].got = false;
    if (sel) dut->start_str = 1; else dut->start_min = 1;
    tick();
    dut->start_str = 0; dut->start_min = 0;
    for (int cyc = 1; cyc < 1200; cyc++) {
        bool pv   = sel ? dut->pv_str   : dut->pv_min;
        bool done = sel ? dut->done_str : dut->done_min;
        if (pv) {
            int idx = sel ? dut->pidx_str : dut->pidx_min;
            if (idx > 9 || out[idx].got) { printf("BAD plane idx=%d (dup or range)\n", idx); exit(1); }
            out[idx].got = true;
            out[idx].ddx = f32(sel ? dut->ddx_str : dut->ddx_min);
            out[idx].ddy = f32(sel ? dut->ddy_str : dut->ddy_min);
            out[idx].c   = f32(sel ? dut->c_str   : dut->c_min);
        }
        if (done) return cyc;
        tick();
    }
    printf("TIMEOUT (unit %d)\n", sel); exit(1);
}

int main(int argc, char** argv){
    Verilated::commandArgs(argc, argv);
    dut = new Vtsp_setup_stream_tb_top;
    srand(0x75E7);

    dut->reset = 1; dut->start_min = 0; dut->start_str = 0;
    for (int i=0;i<4;i++) tick();
    dut->reset = 0;

    long NT = 20000;
    double worst_min = 0, worst_str = 0;
    long   bad = 0, tot_planes = 0;
    long   cyc_min_sum = 0, cyc_str_sum = 0;
    int    cyc_str_max = 0;

    for (long t = 0; t < NT; t++) {
        // ---- random triangle (screen-ish coords, non-degenerate) ----
        float xs[3], ys[3], zs[3];
        double area;
        do {
            for (int i=0;i<3;i++) { xs[i]=frnd(0,640); ys[i]=frnd(0,480); }
            area = ((double)xs[1]-xs[0])*((double)ys[2]-ys[0])
                 - ((double)xs[2]-xs[0])*((double)ys[1]-ys[0]);
        } while (fabs(area) < 4.0);
        for (int i=0;i<3;i++) zs[i] = frnd(0.01f, 50.f);
        float xb = 32.f * (int)(fminf(fminf(xs[0],xs[1]),xs[2]) / 32.f);
        float yb = 32.f * (int)(fminf(fminf(ys[0],ys[1]),ys[2]) / 32.f);
        float us[3], vs[3];
        for (int i=0;i<3;i++) { us[i]=frnd(0,8); vs[i]=frnd(0,8); }
        uint32_t col[3] = { (uint32_t)rand()<<16 ^ (uint32_t)rand(),
                            (uint32_t)rand()<<16 ^ (uint32_t)rand(),
                            (uint32_t)rand()<<16 ^ (uint32_t)rand() };
        uint32_t ofs[3] = { (uint32_t)rand()<<16 ^ (uint32_t)rand(),
                            (uint32_t)rand()<<16 ^ (uint32_t)rand(),
                            (uint32_t)rand()<<16 ^ (uint32_t)rand() };
        int gour = rand()&1, tex = rand()&1, ofl = rand()&1;

        dut->x1=b32(xs[0]); dut->y1=b32(ys[0]); dut->z1=b32(zs[0]);
        dut->x2=b32(xs[1]); dut->y2=b32(ys[1]); dut->z2=b32(zs[1]);
        dut->x3=b32(xs[2]); dut->y3=b32(ys[2]); dut->z3=b32(zs[2]);
        dut->xbase=b32(xb); dut->ybase=b32(yb);
        dut->u1=b32(us[0]); dut->v1=b32(vs[0]);
        dut->u2=b32(us[1]); dut->v2=b32(vs[1]);
        dut->u3=b32(us[2]); dut->v3=b32(vs[2]);
        dut->col1=col[0]; dut->col2=col[1]; dut->col3=col[2];
        dut->ofs1=ofs[0]; dut->ofs2=ofs[1]; dut->ofs3=ofs[2];
        dut->gouraud=gour; dut->texture=tex; dut->offset=ofl;

        Plane pm[10], ps[10];
        cyc_min_sum += run_unit(0, pm);
        int cs = run_unit(1, ps);
        cyc_str_sum += cs; if (cs > cyc_str_max) cyc_str_max = cs;

        // ---- double-precision reference + comparison per enabled plane ----
        double X21=(double)xs[1]-xs[0], X31=(double)xs[2]-xs[0];
        double Y21=(double)ys[1]-ys[0], Y31=(double)ys[2]-ys[0];
        for (int idx=0; idx<10; idx++) {
            bool en = (idx<=1) ? tex : (idx<=5) ? true : ofl;
            if (pm[idx].got != en || ps[idx].got != en) {
                printf("[t=%ld] plane %d presence: en=%d min=%d str=%d\n",
                       t, idx, en, pm[idx].got, ps[idx].got); return 1;
            }
            if (!en) continue;
            tot_planes++;
            // per-vertex attribute
            double a[3];
            for (int i=0;i<3;i++) {
                if (idx<=1)      a[i] = (idx==0) ? us[i] : vs[i];
                else {
                    int ch = (idx-2)&3;
                    uint32_t w = (idx<=5) ? (gour?col[i]:col[2]) : (gour?ofs[i]:ofs[2]);
                    a[i] = (double)((w >> (8*ch)) & 0xFF);
                }
            }
            double p1=zs[0]*a[0], p2=zs[1]*a[1], p3=zs[2]*a[2];
            double da2=p2-p1, da3=p3-p1;
            double Aa = da3*Y21 - da2*Y31;
            double Ba = X31*da2 - X21*da3;
            double ddx = -Aa/area, ddy = -Ba/area;
            double c   = p1 - ddx*((double)xs[0]-xb) - ddy*((double)ys[0]-yb);
            // hybrid abs+rel error, worst over the 3 outputs
            double scale = fmax(fabs(ddx)+fabs(ddy)+fabs(c), 1e-3);
            double em=0, es=0;
            em = fmax(em, fabs(pm[idx].ddx-ddx)/fmax(fabs(ddx),scale*1e-2));
            em = fmax(em, fabs(pm[idx].ddy-ddy)/fmax(fabs(ddy),scale*1e-2));
            em = fmax(em, fabs(pm[idx].c  -c  )/fmax(fabs(c),  scale*1e-2));
            es = fmax(es, fabs(ps[idx].ddx-ddx)/fmax(fabs(ddx),scale*1e-2));
            es = fmax(es, fabs(ps[idx].ddy-ddy)/fmax(fabs(ddy),scale*1e-2));
            es = fmax(es, fabs(ps[idx].c  -c  )/fmax(fabs(c),  scale*1e-2));
            if (em > worst_min) worst_min = em;
            if (es > worst_str) worst_str = es;
            // stream must not be meaningfully worse than min on the same plane
            if (es > em*4.0 + 1e-3) {
                bad++;
                if (bad <= 10)
                    printf("[t=%ld idx=%d] str worse: es=%.3g em=%.3g "
                           "(ref ddx=%.6g ddy=%.6g c=%.6g | str %.6g %.6g %.6g | min %.6g %.6g %.6g)\n",
                           t, idx, es, em, ddx, ddy, c,
                           ps[idx].ddx, ps[idx].ddy, ps[idx].c,
                           pm[idx].ddx, pm[idx].ddy, pm[idx].c);
            }
        }
    }

    printf("tsp_setup_stream vs min: %ld triangles, %ld planes\n", NT, tot_planes);
    printf("  worst rel-err vs double ref: min=%.4g stream=%.4g\n", worst_min, worst_str);
    printf("  avg cycles/tri: min=%.1f stream=%.1f (stream max %d)\n",
           (double)cyc_min_sum/NT, (double)cyc_str_sum/NT, cyc_str_max);
    printf("  planes where stream >4x worse than min: %ld\n", bad);

    // ================= PHASE 2: back-to-back (rdy handshake) =================
    // Same RTL, same triangles run twice: first serially (start after done), then
    // back-to-back (start held, latched on rdy). The emission sequences must be
    // BIT-EXACT (overlapping triangles share the units + delay lines, so any overlap
    // hazard corrupts bits), and done must pulse exactly once per triangle.
    struct Tri { uint32_t x[3],y[3],z[3],u[3],v[3],co[3],of[3],xb,yb; int g,tex,ofl; };
    struct Emit { int idx; uint32_t ddx, ddy, c; };

    auto apply_tri = [&](const Tri& tr){
        dut->x1=tr.x[0]; dut->y1=tr.y[0]; dut->z1=tr.z[0];
        dut->x2=tr.x[1]; dut->y2=tr.y[1]; dut->z2=tr.z[1];
        dut->x3=tr.x[2]; dut->y3=tr.y[2]; dut->z3=tr.z[2];
        dut->xbase=tr.xb; dut->ybase=tr.yb;
        dut->u1=tr.u[0]; dut->v1=tr.v[0];
        dut->u2=tr.u[1]; dut->v2=tr.v[1];
        dut->u3=tr.u[2]; dut->v3=tr.v[2];
        dut->col1=tr.co[0]; dut->col2=tr.co[1]; dut->col3=tr.co[2];
        dut->ofs1=tr.of[0]; dut->ofs2=tr.of[1]; dut->ofs3=tr.of[2];
        dut->gouraud=tr.g; dut->texture=tr.tex; dut->offset=tr.ofl;
    };
    auto gen_tri = [&](int force_all)->Tri{
        Tri tr; float xs[3], ys[3]; double a;
        do {
            for (int i=0;i<3;i++) { xs[i]=frnd(0,640); ys[i]=frnd(0,480); }
            a = ((double)xs[1]-xs[0])*((double)ys[2]-ys[0])
              - ((double)xs[2]-xs[0])*((double)ys[1]-ys[0]);
        } while (fabs(a) < 4.0);
        for (int i=0;i<3;i++) {
            tr.x[i]=b32(xs[i]); tr.y[i]=b32(ys[i]); tr.z[i]=b32(frnd(0.01f,50.f));
            tr.u[i]=b32(frnd(0,8)); tr.v[i]=b32(frnd(0,8));
            tr.co[i]=(uint32_t)rand()<<16 ^ (uint32_t)rand();
            tr.of[i]=(uint32_t)rand()<<16 ^ (uint32_t)rand();
        }
        tr.xb=b32(32.f*(int)(fminf(fminf(xs[0],xs[1]),xs[2])/32.f));
        tr.yb=b32(32.f*(int)(fminf(fminf(ys[0],ys[1]),ys[2])/32.f));
        tr.g   = force_all ? 1 : (rand()&1);
        tr.tex = force_all ? 1 : (rand()&1);
        tr.ofl = force_all ? 1 : (rand()&1);
        return tr;
    };
    // serial run of the STREAM unit, recording raw-bit emissions in order
    auto run_serial = [&](const Tri& tr, std::vector<Emit>& out)->void{
        apply_tri(tr);
        if (!dut->rdy_str) { printf("B2B: rdy low at serial start\n"); exit(1); }
        dut->start_str = 1; tick(); dut->start_str = 0;
        for (int cyc=1; cyc<1200; cyc++) {
            if (dut->pv_str) out.push_back({(int)dut->pidx_str, dut->ddx_str, dut->ddy_str, dut->c_str});
            if (dut->done_str) return;
            tick();
        }
        printf("B2B: serial TIMEOUT\n"); exit(1);
    };
    // back-to-back run of a whole batch: start held, latched on rdy; collect the
    // global emission sequence + done count; returns total ticks
    auto run_b2b = [&](const std::vector<Tri>& tris, std::vector<Emit>& out, long& dones)->long{
        long ticks = 0, guard = 0;
        size_t next = 0; dones = 0;
        while (next < tris.size() || dones < (long)tris.size()) {
            bool accepted = false;
            if (next < tris.size()) {
                apply_tri(tris[next]);
                dut->start_str = 1;
                accepted = dut->rdy_str;   // latch happens on this edge
            } else dut->start_str = 0;
            tick(); ticks++;
            if (accepted) next++;
            if (dut->pv_str) out.push_back({(int)dut->pidx_str, dut->ddx_str, dut->ddy_str, dut->c_str});
            if (dut->done_str) dones++;
            if (++guard > 500000) { printf("B2B: TIMEOUT (next=%zu dones=%ld)\n", next, dones); exit(1); }
        }
        dut->start_str = 0;
        return ticks;
    };
    auto check_batch = [&](const char* name, const std::vector<Tri>& tris)->long{
        std::vector<std::vector<Emit>> ser(tris.size());
        for (size_t t=0; t<tris.size(); t++) run_serial(tris[t], ser[t]);
        std::vector<Emit> b2b; long dones=0;
        long ticks = run_b2b(tris, b2b, dones);
        long mism = 0; size_t k = 0, expect_total = 0;
        for (size_t t=0; t<tris.size(); t++) {
            for (auto& e : ser[t]) {
                expect_total++;
                if (k >= b2b.size()) { mism++; continue; }
                Emit& o = b2b[k++];
                if (o.idx!=e.idx || o.ddx!=e.ddx || o.ddy!=e.ddy || o.c!=e.c) {
                    mism++;
                    if (mism <= 8)
                        printf("B2B MISMATCH t=%zu: got idx%d %08x/%08x/%08x want idx%d %08x/%08x/%08x\n",
                               t, o.idx,o.ddx,o.ddy,o.c, e.idx,e.ddx,e.ddy,e.c);
                }
            }
        }
        if (b2b.size() != expect_total) { printf("B2B %s: emission count %zu != %zu\n", name, b2b.size(), expect_total); mism++; }
        if (dones != (long)tris.size())  { printf("B2B %s: done count %ld != %zu\n", name, dones, tris.size()); mism++; }
        printf("  b2b %s: %zu tris, %zu planes, mismatches=%ld, sustained %.1f cyc/tri\n",
               name, tris.size(), expect_total, mism, (double)ticks/tris.size());
        return mism;
    };

    std::vector<Tri> batch_rand, batch_full;
    for (int t=0; t<3000; t++) batch_rand.push_back(gen_tri(0));
    for (int t=0; t<500;  t++) batch_full.push_back(gen_tri(1));
    long b2b_mism = 0;
    printf("back-to-back (rdy handshake) vs serial, bit-exact:\n");
    b2b_mism += check_batch("random-flags", batch_rand);
    b2b_mism += check_batch("all-10-plane", batch_full);

    dut->final(); delete dut;
    return (bad || b2b_mism) ? 1 : 0;
}
