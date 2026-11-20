// refglue_selftest.cpp: the self-test of the L2 glue and the phase driver (PLAN 1.1, M5; make refglue-selftest).
//
//   refglue_selftest [--mode drv|core|ptcopy|scramble] [--seed S] [--check-take N] <case folder> | @<list file> ...
//
// A case folder is a capture (tools/gate/capture_prerender.sh): r0, r1, ... one per render, each with the video memory
// and registers before the render (vram.bin[.gz], pvr_regs.bin) and refsw3-offline's video memory after it
// (post/vram.bin[.gz]); r<k>/skipped where refsw3-offline did not render (it refused: a register never written, no last
// region array entry). The renders of a case run in order in one core (p2ref::reset_core first): what a render leaves
// in the core (the tile buffers, offsKept) is the next one's, as in refsw3-offline's one process.
//
// Modes (every one compares the whole video memory after every render with refsw3-offline's, word for word):
//   drv       the phase driver (tb/ref/phase_driver.cpp): RenderCORE's frame from the copies, each entry's phases by
//             p2ref calls, every SHADE pass through the copies of RenderParamTags and PixelFlush_tsp
//   core      RenderCORE_sw, the glue's own refcore (the build's control: refsw3-offline's flags and sources)
//   ptcopy    drv with the PT phases by the verbatim PT loop (copy core-pt-loop)
//   scramble  drv, and at every phase boundary every field of every pixel that tb/common/isp_live.h says is dead is
//             overwritten with random values (--seed): the liveness masks are sound if nothing changes
// --check-take N: PtChunkTake's copy against refcore's on N random calls first. --shard k/N: every N-th case.
// --jobs N: the cases in N child processes. --max-passes P (1024): a punch-through chunk or a translucent sort of more
// passes ends the render as one that did not end (a failure: refsw3-offline's ended); scramble's broken masks can loop.
//
// Prints a line per render that differs (the first differing word, its address, the framebuffer pixel and tile when it
// is one), a line per case, then "refglue_selftest: <n> checks, <m> failures" and PASS / FAIL (the exit code).
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <algorithm>

#include "phase_driver.h"
#include "p2tb.h"

namespace {

bool IsFile(const std::string& p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}
bool IsDir(const std::string& p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// a video memory file (32-bit-area order, raw or gzipped) as words
bool ReadWords(const std::string& path, std::vector<uint32_t>& w)
{
    gzFile f = gzopen(path.c_str(), "rb");
    if (!f)
        return false;
    const size_t n = VRAM_SIZE / 4;
    w.assign(n + 1, 0);
    size_t got = 0;
    for (;;) {
        int k = gzread(f, (char*)w.data() + got, (unsigned)((n + 1) * 4 - got));
        if (k <= 0)
            break;
        got += k;
    }
    gzclose(f);
    if (got != n * 4)
        return false;
    w.resize(n);
    return true;
}

std::string VramIn(const std::string& d)
{
    return IsFile(d + "/vram.bin.gz") ? d + "/vram.bin.gz" : d + "/vram.bin";
}

struct Scramble {
    uint64_t seed;
    uint64_t calls = 0;
    long fieldsHit = 0;
};

void ScrambleHook(p2live::Phase ph, const p2ref::RegionArrayEntry&, const p2ref::taRECT&, void* user)
{
    Scramble& s = *(Scramble*)user;
    p2tb::Rng rng = p2tb::Rng::of(s.seed, s.calls++);
    for (int i = 0; i < 1024; i++) {
        p2ref::IspPix p = p2ref::isp_pixel(i);
        const uint32_t dead = p2live::ALL_FIELDS & ~p2live::live(ph, p.rendered, p.everRendered);
        auto z = [&]() { return p2ref::ZType::Bits(rng.u32()); };
        if (dead & p2live::DEPTH_B) p.depthB = z();
        if (dead & p2live::TAG_B) p.tagB = rng.u32();
        if (dead & p2live::DEPTH_C) p.depthC = z();
        if (dead & p2live::REFTAG_C) p.refTagC = rng.u32();
        if (dead & p2live::OPTAG) p.opTag = rng.u32();
        if (dead & p2live::EVER_RENDERED) p.everRendered = rng.u32() & 1;
        if (dead & p2live::RES_PASS) p.resPass = (int)(rng.u32() % 64) - 16;
        if (dead & p2live::RENDERED) p.rendered = rng.u32() & 1;
        if (dead & p2live::RES_TAG) p.resTag = rng.u32();
        if (dead & p2live::RES_DEPTH) p.resDepth = z();
        if (dead & p2live::SAVED_DEPTH) p.savedDepth = z();
        s.fieldsHit += __builtin_popcount(dead);
        p2ref::set_isp_pixel(i, p);
    }
}

// where a word of video memory is in the framebuffer the render wrote (FB_W_SOF1, FB_W_LINESTRIDE, the pack mode):
// "pixel (x, y) tile (tx, ty)", or "" when it is not in it
std::string FbWhere(uint32_t addr)
{
    const uint32_t sof = FB_W_SOF1 & 0x7fffff, stride = FB_W_LINESTRIDE.stride * 8;
    const int pm = FB_W_CTRL.fb_packmode, bpp = pm <= 3 ? 2 : pm == 4 ? 3 : 4;
    if (!stride || addr < sof || (FB_W_SOF1 & 0x1000000))
        return "";
    const uint32_t off = addr - sof, y = off / stride, x = (off % stride) / bpp;
    if (y >= 2048)
        return "";
    char b[96];
    snprintf(b, sizeof b, " pixel (%u, %u) tile (%u, %u)", x, y, x / 32, y / 32);
    return b;
}

// the cases of one process (or of one child of --jobs): their lines, the summary line, Fails' two lines
int Run(const p2tb::Args& a, const std::string& mode, long checkTake, int maxPasses, const std::vector<std::string>& mine)
{
    p2tb::Fails f("refglue_selftest");
    if (checkTake) {
        f.set("pt-take");
        const long bad = p2ref::check_pt_take(a.seed, checkTake);
        f.ok(bad == 0, "PtChunkTake's copy differs from refcore's on %ld of %ld calls", bad, checkTake);
        printf("refglue_selftest: pt-take: %ld calls, %ld differ\n", checkTake, bad);
    }
    f.set(mode.c_str());
    long renders = 0, skipped = 0, scrambled = 0, hung = 0;
    p2drv::Stats st;
    for (const std::string& c : mine) {
        p2ref::reset_core();
        int k = 0, equal = 0, differ = 0;
        Scramble sc{ a.seed };
        for (;; k++) {
            const std::string r = c + "/r" + std::to_string(k);
            if (!IsDir(r))
                break;
            if (IsFile(r + "/skipped")) {
                skipped++;
                continue;
            }
            if (!f.ok(p2ref::load_state(r.c_str()), "%s: cannot load the capture", r.c_str()))
                break;
            std::vector<uint32_t> post;
            if (!f.ok(ReadWords(VramIn(r + "/post"), post), "%s: no post/vram.bin[.gz]", r.c_str()))
                break;
            bool ended = true;
            if (mode == "core") {
                p2ref::render_core();
            } else {
                p2drv::Options o;
                o.ptCopy = mode == "ptcopy";
                o.maxPasses = maxPasses;
                ended = p2drv::render(o, mode == "scramble" ? ScrambleHook : nullptr, &sc, &st);
            }
            renders++;
            if (!f.ok(ended, "%s: did not end: a punch-through chunk or a translucent sort took more than %d passes "
                             "(refsw3-offline's render ended)", r.c_str(), maxPasses)) {
                hung++;
                differ++;
                break;          // what it left is not a render's: the case's later renders would differ too
            }
            long n = 0;
            uint32_t first = 0;
            for (uint32_t i = 0; i < post.size(); i++)
                if (p2ref::vram32(4 * i) != post[i]) {
                    if (!n++)
                        first = i;
                }
            if (f.ok(n == 0, "%s: %ld words differ from refsw3-offline's; the first at %06X: %08X, refsw3-offline %08X%s",
                     r.c_str(), n, 4 * first, p2ref::vram32(4 * first), post[first], FbWhere(4 * first).c_str()))
                equal++;
            else
                differ++;
        }
        scrambled += sc.fieldsHit;
        printf("refglue_selftest: %s %s: %d renders, %d equal, %d differ\n", mode.c_str(), c.c_str(), equal + differ,
               equal, differ);
        f.ok(k > 0, "%s: no renders (r0 missing)", c.c_str());
    }
    printf("refglue_selftest: %s: %zu cases, %ld renders, %ld not rendered by refsw3-offline, %ld did not end%s\n",
           mode.c_str(), mine.size(), renders, skipped, hung,
           mode == "scramble" ? (", " + std::to_string(scrambled) + " dead fields scrambled").c_str() : "");
    if (mode != "core")
        printf("refglue_selftest: %s: at most %d chunks and %d passes a punch-through entry, %d passes a translucent "
               "sort (%ld entries)\n", mode.c_str(), st.ptChunks, st.ptPasses, st.trPasses, st.entries);
    return f.finish();
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "refglue_selftest: %s\n", a.error.c_str());
        return 2;
    }
    std::string mode = "drv";
    long checkTake = 0;
    int jobs = 1, maxPasses = 1024;
    std::vector<std::string> cases;
    for (size_t i = 0; i < a.rest.size(); i++) {
        if (a.rest[i] == "--mode" && i + 1 < a.rest.size())
            mode = a.rest[++i];
        else if (a.rest[i] == "--check-take" && i + 1 < a.rest.size())
            checkTake = atol(a.rest[++i].c_str());
        else if (a.rest[i] == "--jobs" && i + 1 < a.rest.size())
            jobs = std::max(1, atoi(a.rest[++i].c_str()));
        else if (a.rest[i] == "--max-passes" && i + 1 < a.rest.size())
            maxPasses = atoi(a.rest[++i].c_str());
        else if (a.rest[i][0] == '@') {         // @file: case folders, one a line
            FILE* lf = fopen(a.rest[i].c_str() + 1, "r");
            if (!lf) {
                fprintf(stderr, "refglue_selftest: cannot read %s\n", a.rest[i].c_str() + 1);
                return 2;
            }
            char line[4096];
            while (fgets(line, sizeof line, lf)) {
                std::string l = line;
                while (!l.empty() && (l.back() == '\n' || l.back() == ' '))
                    l.pop_back();
                if (!l.empty() && l[0] != '#')
                    cases.push_back(l);
            }
            fclose(lf);
        } else
            cases.push_back(a.rest[i]);
    }
    if (mode != "drv" && mode != "core" && mode != "ptcopy" && mode != "scramble") {
        fprintf(stderr, "refglue_selftest: --mode drv | core | ptcopy | scramble\n");
        return 2;
    }
    std::vector<std::string> mine;          // --shard k/N: every N-th case
    for (size_t i = 0; i < cases.size(); i++)
        if (a.mine(i))
            mine.push_back(cases[i]);
    if (jobs == 1)
        return Run(a, mode, checkTake, maxPasses, mine);

    // --jobs N: N children, child j the cases j, j + N, ...; their output in order, then the merged verdict
    fflush(stdout);
    std::vector<FILE*> outs(jobs);
    std::vector<pid_t> pids(jobs);
    for (int j = 0; j < jobs; j++) {
        outs[j] = tmpfile();
        pids[j] = fork();
        if (pids[j] == 0) {
            dup2(fileno(outs[j]), 1);
            std::vector<std::string> part;
            for (size_t i = j; i < mine.size(); i += jobs)
                part.push_back(mine[i]);
            const int st = Run(a, mode, j == 0 ? checkTake : 0, maxPasses, part);
            fflush(stdout);
            _exit(st);
        }
    }
    long checks = 0, failures = 0;
    bool ok = true;
    for (int j = 0; j < jobs; j++) {
        int st = 0;
        waitpid(pids[j], &st, 0);
        ok = ok && WIFEXITED(st) && WEXITSTATUS(st) == 0;
        rewind(outs[j]);
        char line[8192];
        while (fgets(line, sizeof line, outs[j])) {
            long c, x;
            if (sscanf(line, "refglue_selftest: %ld checks, %ld failures", &c, &x) == 2) {
                checks += c;
                failures += x;
                continue;
            }
            if (!strncmp(line, "refglue_selftest: PASS", 22) || !strncmp(line, "refglue_selftest: FAIL", 22))
                continue;
            fputs(line, stdout);
        }
        fclose(outs[j]);
    }
    printf("refglue_selftest: %ld checks, %ld failures\n", checks, failures);
    printf("refglue_selftest: %s\n", ok && !failures ? "PASS" : "FAIL");
    return ok && !failures ? 0 : 1;
}
