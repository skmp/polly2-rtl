// Top-left-bias / exact-edge raster regression.
//
// The RE:CV-intro fullscreen quad: two coplanar triangles sharing the
// diagonal (0,80)-(640,400), slope 1/2, which passes EXACTLY through 32x32
// tile origins every other tile column. The edge constant C of a tile whose
// origin lies on the edge is exactly +0; the old top-left bias (raw integer
// C-1) wrapped that to 0xFFFFFFFF (-NaN), whose exponent dominates every Xhs
// sum -> the WHOLE tile lost the triangle (alternating black holes along the
// diagonal). This tb runs isp_setup_streamed + isp_raster_line for both
// triangles over the tiles along the diagonal (and off-diagonal controls) and
// compares every pixel of every tile against a refsw2-rule model:
//   inside = e > 0 || (e == 0 && IsTopLeft(edge))     (refsw_tile.cpp)
// It also checks the corner probe never rejects a tile the model covers, and
// pins the user-reported black pixel (173,178) as covered by the lower tri.
#include "Vraster_topleft_tb_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>

static Vraster_topleft_tb_top* dut;
static int errors = 0;

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
static uint32_t f2b(float f) { uint32_t b; memcpy(&b, &f, 4); return b; }

struct Tri { double x1,y1, x2,y2, x3,y3; };

// ---- refsw2 RasterizeTriangle model (exact doubles; halfpixel = 0) ----
static bool is_top_left(double dx, double dy) {
    return (dy == 0 && dx > 0) || dy < 0;
}
// coverage of tile-local (x, y), tile origin (bx, by)
static bool model_inside(const Tri& t, double bx, double by, int x, int y) {
    double area = (t.x1 - t.x3) * (t.y2 - t.y3) - (t.y1 - t.y3) * (t.x2 - t.x3);
    double sgn = area > 0 ? -1.0 : 1.0;
    double DX12 = sgn * (t.x1 - t.x2), DY12 = sgn * (t.y1 - t.y2);
    double DX23 = sgn * (t.x2 - t.x3), DY23 = sgn * (t.y2 - t.y3);
    double DX31 = sgn * (t.x3 - t.x1), DY31 = sgn * (t.y3 - t.y1);
    double C1 = DY12 * (t.x1 - bx) - DX12 * (t.y1 - by);
    double C2 = DY23 * (t.x2 - bx) - DX23 * (t.y2 - by);
    double C3 = DY31 * (t.x3 - bx) - DX31 * (t.y3 - by);
    bool T1 = is_top_left(t.x2 - t.x1, t.y2 - t.y1);
    bool T2 = is_top_left(t.x3 - t.x2, t.y3 - t.y2);
    bool T3 = is_top_left(t.x1 - t.x3, t.y1 - t.y3);
    double e1 = C1 + DX12 * y - DY12 * x;
    double e2 = C2 + DX23 * y - DY23 * x;
    double e3 = C3 + DX31 * y - DY31 * x;
    return (e1 > 0 || (T1 && e1 == 0)) &&
           (e2 > 0 || (T2 && e2 == 0)) &&
           (e3 > 0 || (T3 && e3 == 0));
}

// run setup for (tri, tile), sweep the tile + probe; compare
static void run_tile(const Tri& t, int tx, int ty, const char* name) {
    double bx = tx * 32.0, by = ty * 32.0;

    // ---- setup ----
    dut->s_clear = 1; tick(); dut->s_clear = 0;
    dut->x1 = f2b((float)t.x1); dut->y1 = f2b((float)t.y1); dut->z1 = f2b(0.000015f);
    dut->x2 = f2b((float)t.x2); dut->y2 = f2b((float)t.y2); dut->z2 = f2b(0.000015f);
    dut->x3 = f2b((float)t.x3); dut->y3 = f2b((float)t.y3); dut->z3 = f2b(0.000015f);
    dut->xbase = f2b((float)bx); dut->ybase = f2b((float)by);
    dut->s_valid = 1;
    int guard = 0;
    while (!(dut->s_ready) && ++guard < 100) tick();
    tick();                      // accepted this edge
    dut->s_valid = 0;
    guard = 0;
    while (!dut->s_done && ++guard < 200) tick();
    if (!dut->s_done) { printf("[%s %d,%d] setup timeout\n", name, tx, ty); errors++; return; }
    if (getenv("DBG_C2")) printf("[%s %d,%d] c2 = %08x\n", name, tx, ty, dut->c2_dbg);

    // ---- corner probe ----
    dut->r_valid = 1; dut->r_probe = 1; dut->r_y = 0; dut->r_xb = 0;
    tick();
    dut->r_valid = 0; dut->r_probe = 0;
    guard = 0;
    while (!dut->probe_valid && ++guard < 50) tick();
    int rejected = dut->probe_valid ? dut->probe_reject : -1;

    // ---- full sweep: 32 rows x 4 chunks of 8 lanes ----
    static uint8_t got[32][32];
    memset(got, 0xFF, sizeof(got));
    int outstanding = 0;
    auto drain = [&](bool all) {
        while (outstanding > 0) {
            tick();
            if (dut->out_valid) {
                for (int l = 0; l < 8; l++)
                    got[dut->out_y][dut->out_x + l] = (dut->inside_mask >> l) & 1;
                outstanding--;
            }
            if (!all) break;
        }
    };
    for (int y = 0; y < 32; y++)
        for (int xb = 0; xb < 32; xb += 8) {
            dut->r_valid = 1; dut->r_y = y; dut->r_xb = xb;
            tick();
            if (dut->out_valid) {
                for (int l = 0; l < 8; l++)
                    got[dut->out_y][dut->out_x + l] = (dut->inside_mask >> l) & 1;
                outstanding--;
            }
            outstanding++;
        }
    dut->r_valid = 0;
    int g2 = 0;
    while (outstanding > 0 && ++g2 < 200) {
        tick();
        if (dut->out_valid) {
            for (int l = 0; l < 8; l++)
                got[dut->out_y][dut->out_x + l] = (dut->inside_mask >> l) & 1;
            outstanding--;
        }
    }
    if (outstanding) { printf("[%s %d,%d] sweep drain timeout\n", name, tx, ty); errors++; return; }

    // ---- compare ----
    int diffs = 0, covered = 0;
    for (int y = 0; y < 32; y++)
        for (int x = 0; x < 32; x++) {
            int want = model_inside(t, bx, by, x, y) ? 1 : 0;
            covered += want;
            if (got[y][x] != want) {
                if (diffs < 4)
                    printf("[%s %d,%d] px(%d,%d) got %d want %d (global %d,%d)\n",
                           name, tx, ty, x, y, got[y][x], want,
                           tx * 32 + x, ty * 32 + y);
                diffs++;
            }
        }
    if (diffs) { printf("[%s tile %d,%d] FAIL: %d pixel diffs\n", name, tx, ty, diffs); errors++; }
    if (covered > 0 && rejected != 0) {
        printf("[%s tile %d,%d] FAIL: probe rejected a covered tile (%d px)\n",
               name, tx, ty, covered);
        errors++;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vraster_topleft_tb_top;
    dut->reset = 1; dut->s_valid = 0; dut->r_valid = 0; dut->s_clear = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0;
    for (int i = 0; i < 4; i++) tick();

    // the RE:CV intro fullscreen quad
    const Tri t1 = { 0,400,   0,80,  640,400 };   // lower-left
    const Tri t2 = { 640,400, 0,80,  640,80  };   // upper-right

    // tiles along the diagonal y = 80 + x/2: origins on the line at odd tile
    // columns ((32,96),(96,128),(160,160),(224,192)...), plus even-column
    // crossings and off-diagonal controls
    static const int tiles[][2] = {
        {1,3}, {2,3}, {2,4}, {3,4}, {4,4}, {4,5}, {5,5}, {6,5}, {6,6}, {7,6},
        {0,0}, {10,10}, {19,14},
    };
    for (auto& tt : tiles) {
        run_tile(t1, tt[0], tt[1], "tri1");
        run_tile(t2, tt[0], tt[1], "tri2");
    }

    // pin the reported black pixel: (173,178) is tile (5,5) local (13,18),
    // below the diagonal -> must be covered by tri1
    if (!model_inside(t1, 160, 160, 13, 18)) {
        printf("model sanity FAIL: (173,178) not in tri1\n"); errors++;
    }

    printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    delete dut;
    return errors != 0;
}
