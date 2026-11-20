// p2tb.h: what every polly2-rtl testbench shares (conventions.md 7.2, 7.8; PLAN 1.2). Header only, C++17, no
// dependency on refcore or Verilator.
//
//   Fails     counts checks; shows the first 25 failures of each section; ends with "<unit>: <n> checks, <m> failures"
//             and "<unit>: PASS" / "<unit>: FAIL"; finish() is the exit code (shrike4 tb/v1_clk_tbutil.h).
//   Args      the arguments every unit testbench takes: --seed S, --n N, --shard k/N (k = 0 .. N-1), --only <section>,
//             --vec <file>, --set <console set file>, --trace, --full; the rest is left for the testbench.
//   Rng       xorshift64*, seeded per case (Rng::of(seed, i)) so that a case's vector does not depend on the shard.
//   raise_stack()   RLIMIT_STACK to the hard limit (Verilated settle functions can need several MB: conventions 6.2).
//   banner()  the first line of a run: unit, seed, shard, and the nulldc3 revision from the environment (P2_REFREV,
//             which the Makefile exports) so that a reference change shows in the log (num 7.1).
//   VecFile   fixed-size binary records behind a small header ("P2VEC1", record size, count).
#pragma once

#include <cerrno>
#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace p2tb {

// ---------------------------------------------------------------------------------------------------------------
struct Fails {
    const char* unit;
    long n = 0, checks = 0;
    int shownInSection = 0;
    std::string section;
    static constexpr int kShow = 25;

    explicit Fails(const char* u) : unit(u) {}
    // a new section: its own 25 failures are shown
    void set(const char* s)
    {
        section = s;
        shownInSection = 0;
    }
    bool ok(bool c, const char* fmt, ...) __attribute__((format(printf, 3, 4)))
    {
        checks++;
        if (c)
            return true;
        n++;
        if (shownInSection < kShow) {
            va_list ap;
            va_start(ap, fmt);
            char b[1024];
            vsnprintf(b, sizeof b, fmt, ap);
            va_end(ap);
            printf("  FAIL [%s] %s\n", section.c_str(), b);
            shownInSection++;
        }
        return false;
    }
    int finish() const
    {
        printf("%s: %ld checks, %ld failures\n", unit, checks, n);
        printf("%s: %s\n", unit, n ? "FAIL" : "PASS");
        fflush(stdout);
        return n ? 1 : 0;
    }
};

// ---------------------------------------------------------------------------------------------------------------
struct Args {
    uint64_t seed = 1;
    uint64_t n = 0;              // 0: the testbench's own default
    unsigned shardK = 0, shardN = 1;
    std::string only;            // empty: every section
    std::string vec, set;
    bool trace = false;
    bool full = false;
    std::vector<std::string> rest;   // arguments this parser does not know, in order, for the testbench
    std::string error;

    // false (with error set) on a malformed known argument; unknown ones go to rest
    bool parse(int argc, char** argv)
    {
        for (int i = 1; i < argc; i++) {
            const std::string a = argv[i];
            auto value = [&](const char* name) -> const char* {
                if (i + 1 >= argc) {
                    error = std::string(name) + " needs a value";
                    return nullptr;
                }
                return argv[++i];
            };
            if (a == "--seed" || a == "--n") {
                const char* v = value(a.c_str());
                if (!v)
                    return false;
                char* end = nullptr;
                errno = 0;
                const uint64_t x = strtoull(v, &end, 0);
                if (errno || !*v || *end) {
                    error = a + ": not a number: " + v;
                    return false;
                }
                (a == "--seed" ? seed : n) = x;
            } else if (a == "--shard") {
                const char* v = value("--shard");
                if (!v)
                    return false;
                unsigned k = 0, cnt = 0;
                char tail = 0;
                if (sscanf(v, "%u/%u%c", &k, &cnt, &tail) != 2 || cnt == 0 || k >= cnt) {
                    error = std::string("--shard k/N with 0 <= k < N: ") + v;
                    return false;
                }
                shardK = k;
                shardN = cnt;
            } else if (a == "--only" || a == "--vec" || a == "--set") {
                const char* v = value(a.c_str());
                if (!v)
                    return false;
                (a == "--only" ? only : a == "--vec" ? vec : set) = v;
            } else if (a == "--trace") {
                trace = true;
            } else if (a == "--full") {
                full = true;
            } else {
                rest.push_back(a);
            }
        }
        return true;
    }
    // the section is run: --only absent, or naming it (a comma-separated list of section names)
    bool want(const char* section) const
    {
        if (only.empty())
            return true;
        const std::string s = section;
        size_t p = 0;
        while (p <= only.size()) {
            size_t q = only.find(',', p);
            if (q == std::string::npos)
                q = only.size();
            if (only.compare(p, q - p, s) == 0 && q - p == s.size())
                return true;
            p = q + 1;
        }
        return false;
    }
    // case i belongs to this shard (round robin)
    bool mine(uint64_t i) const { return i % shardN == shardK; }
    // this shard's contiguous part [lo, hi) of 0 .. count-1, for cases that are cheaper in order
    void range(uint64_t count, uint64_t* lo, uint64_t* hi) const
    {
        *lo = count * shardK / shardN;
        *hi = count * (shardK + 1) / shardN;
    }
    // n if given, else the default
    uint64_t count(uint64_t dflt) const { return n ? n : dflt; }
};

// ---------------------------------------------------------------------------------------------------------------
struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(Mix(seed)) {}
    // the generator of case i of a run seeded with seed: independent of the shard that runs it
    static Rng of(uint64_t seed, uint64_t i) { return Rng(seed * 0x9E3779B97F4A7C15ull + i); }
    static uint64_t Mix(uint64_t z)   // splitmix64's finalizer; never 0 for xorshift
    {
        z += 0x9E3779B97F4A7C15ull;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        z ^= z >> 31;
        return z ? z : 0x9E3779B97F4A7C15ull;
    }
    uint64_t u64()   // xorshift64*
    {
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        return s * 0x2545F4914F6CDD1Dull;
    }
    uint32_t u32() { return (uint32_t)(u64() >> 32); }
    // uniform in 0 .. n-1 (n > 0), without modulo bias worth caring about at these sizes
    uint64_t below(uint64_t n) { return n ? (uint64_t)(((unsigned __int128)u64() * n) >> 64) : 0; }
    // a in .. b inclusive
    int64_t range(int64_t a, int64_t b) { return a + (int64_t)below((uint64_t)(b - a) + 1); }
    bool chance(unsigned perMille) { return below(1000) < perMille; }
};

// ---------------------------------------------------------------------------------------------------------------
inline void raise_stack()
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_STACK, &rl) == 0 && rl.rlim_cur != rl.rlim_max) {
        rl.rlim_cur = rl.rlim_max;
        setrlimit(RLIMIT_STACK, &rl);
    }
}

inline void banner(const char* unit, const Args& a)
{
    const char* rev = getenv("P2_REFREV");
    printf("%s: seed %" PRIu64 " shard %u/%u%s refsw3 %s\n", unit, a.seed, a.shardK, a.shardN, a.full ? " full" : "",
           rev && *rev ? rev : "unknown");
    fflush(stdout);
}

// ---------------------------------------------------------------------------------------------------------------
// fixed-size records: "P2VEC1\0\0", u32 magic of the record type, u32 record size, u64 count, then the records
struct VecFile {
    static constexpr char kTag[8] = {'P', '2', 'V', 'E', 'C', '1', 0, 0};

    static bool write(const std::string& path, uint32_t magic, uint32_t recSize, const void* recs, uint64_t count)
    {
        FILE* f = fopen(path.c_str(), "wb");
        if (!f)
            return false;
        bool ok = fwrite(kTag, 1, 8, f) == 8 && fwrite(&magic, 4, 1, f) == 1 && fwrite(&recSize, 4, 1, f) == 1 &&
                  fwrite(&count, 8, 1, f) == 1 && (count == 0 || fwrite(recs, recSize, count, f) == count);
        ok = (fclose(f) == 0) && ok;
        return ok;
    }
    // false if the file is missing, not a vector file, or of another record type or size
    static bool read(const std::string& path, uint32_t magic, uint32_t recSize, std::vector<uint8_t>* out,
                     uint64_t* count)
    {
        FILE* f = fopen(path.c_str(), "rb");
        if (!f)
            return false;
        char tag[8];
        uint32_t m = 0, rs = 0;
        uint64_t c = 0;
        bool ok = fread(tag, 1, 8, f) == 8 && !memcmp(tag, kTag, 8) && fread(&m, 4, 1, f) == 1 &&
                  fread(&rs, 4, 1, f) == 1 && fread(&c, 8, 1, f) == 1 && m == magic && rs == recSize;
        if (ok) {
            out->resize((size_t)(c * recSize));
            ok = c == 0 || fread(out->data(), recSize, c, f) == c;
        }
        fclose(f);
        if (ok)
            *count = c;
        return ok;
    }
};

}   // namespace p2tb
