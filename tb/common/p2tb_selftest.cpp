// p2tb_selftest: tests tb/common/p2tb.h and zkey.h (make tbcommon-selftest, part of make scaffold). About a second.
//
//   p2tb.h: Fails counts and the exit code; Args parsing, sections, shards (every case in exactly one shard);
//           Rng per-case determinism; VecFile round trip.
//   zkey.h: every key refsw3 makes in each class round-trips to the same key and the same bits, through refcore's own
//           StoredDepth::Bits, FromFp, Neg, Big, Flat, Saturated and DepthTileT::RegDepth; keys refsw3 cannot make
//           are rejected.
#include "p2tb.h"
#include "zkey.h"

#include <string>
#include <unistd.h>

using p2tb::Fails;
using pvrfp::Fp;
using pvrisp::StoredDepth;

namespace {

// runs f with stdout sent to /dev/null (for the Fails tests, which print on purpose)
template<class F> void Quiet(F f)
{
    fflush(stdout);
    const int saved = dup(1);
    FILE* null = fopen("/dev/null", "w");
    dup2(fileno(null), 1);
    f();
    fflush(stdout);
    dup2(saved, 1);
    close(saved);
    fclose(null);
}

void TestFails(Fails& t)
{
    t.set("fails");
    int pass = -1, fail = -1;
    long checks = -1, failures = -1;
    Quiet([&] {
        Fails a("a");
        a.ok(true, "x");
        pass = a.finish();
        Fails b("b");
        b.set("s1");
        for (int i = 0; i < 30; i++)
            b.ok(i < 3, "case %d", i);
        b.set("s2");
        b.ok(false, "y");
        fail = b.finish();
        checks = b.checks;
        failures = b.n;
    });
    t.ok(pass == 0, "a passing Fails exits %d", pass);
    t.ok(fail == 1, "a failing Fails exits %d", fail);
    t.ok(checks == 31 && failures == 28, "checks %ld failures %ld (want 31, 28)", checks, failures);
}

void TestArgs(Fails& t)
{
    t.set("args");
    const char* argv1[] = {"tb", "--seed", "0x10", "--n", "5", "--shard", "2/4", "--only", "a,bb", "--vec", "v.bin",
                           "--set", "s.npz", "--trace", "--full", "--other", "7"};
    p2tb::Args a;
    const bool ok = a.parse((int)(sizeof argv1 / sizeof *argv1), (char**)argv1);
    t.ok(ok, "parse: %s", a.error.c_str());
    t.ok(a.seed == 16 && a.n == 5 && a.shardK == 2 && a.shardN == 4, "seed %llu n %llu shard %u/%u",
         (unsigned long long)a.seed, (unsigned long long)a.n, a.shardK, a.shardN);
    t.ok(a.vec == "v.bin" && a.set == "s.npz" && a.trace && a.full, "vec / set / trace / full");
    t.ok(a.rest.size() == 2 && a.rest[0] == "--other" && a.rest[1] == "7", "the rest: %zu", a.rest.size());
    t.ok(a.want("a") && a.want("bb") && !a.want("b") && !a.want("abb") && !a.want("c"), "--only a,bb");
    t.ok(a.count(9) == 5, "count with --n");
    p2tb::Args d;
    t.ok(d.want("anything") && d.count(9) == 9 && d.seed == 1 && d.shardN == 1, "defaults");
    const char* bad[][3] = {{"tb", "--shard", "4/4"}, {"tb", "--shard", "1/0"}, {"tb", "--shard", "1/2x"},
                            {"tb", "--seed", "12q"}, {"tb", "--n", ""}};
    for (auto& b : bad) {
        p2tb::Args x;
        t.ok(!x.parse(3, (char**)b), "accepted %s %s", b[1], b[2]);
    }
    const char* missing[] = {"tb", "--vec"};
    p2tb::Args m;
    t.ok(!m.parse(2, (char**)missing), "accepted --vec without a value");
}

void TestShards(Fails& t)
{
    t.set("shards");
    for (unsigned N = 1; N <= 7; N++)
        for (uint64_t count : {0ull, 1ull, 5ull, 100ull, 1001ull}) {
            std::vector<int> byMine(count, 0), byRange(count, 0);
            for (unsigned k = 0; k < N; k++) {
                p2tb::Args a;
                a.shardK = k;
                a.shardN = N;
                for (uint64_t i = 0; i < count; i++)
                    byMine[i] += a.mine(i);
                uint64_t lo, hi;
                a.range(count, &lo, &hi);
                for (uint64_t i = lo; i < hi && i < count; i++)
                    byRange[i]++;
            }
            bool once = true;
            for (uint64_t i = 0; i < count; i++)
                once = once && byMine[i] == 1 && byRange[i] == 1;
            t.ok(once, "N %u count %llu: a case not in exactly one shard", N, (unsigned long long)count);
        }
}

void TestRng(Fails& t)
{
    t.set("rng");
    p2tb::Rng a = p2tb::Rng::of(7, 123), b = p2tb::Rng::of(7, 123), c = p2tb::Rng::of(7, 124);
    const uint64_t a1 = a.u64(), b1 = b.u64(), c1 = c.u64();
    t.ok(a1 == b1 && a1 != c1, "per-case generators");
    p2tb::Rng r(1);
    bool inRange = true;
    for (int i = 0; i < 100000; i++) {
        const uint64_t n = 1 + (uint64_t)(i % 37);
        inRange = inRange && r.below(n) < n;
        const int64_t x = r.range(-5, 5);
        inRange = inRange && x >= -5 && x <= 5;
    }
    t.ok(inRange, "below / range out of range");
}

void TestVecFile(Fails& t, const std::string& dir)
{
    t.set("vecfile");
    struct Rec {
        uint32_t a;
        uint64_t b;
    };
    std::vector<Rec> recs = {{1, 2}, {3, 4}, {0xffffffffu, ~0ull}};
    const std::string path = dir + "/p2tb_selftest.vec";
    t.ok(p2tb::VecFile::write(path, 0x1234, sizeof(Rec), recs.data(), recs.size()), "write %s", path.c_str());
    std::vector<uint8_t> raw;
    uint64_t n = 0;
    const bool r = p2tb::VecFile::read(path, 0x1234, sizeof(Rec), &raw, &n);
    t.ok(r && n == 3 && !memcmp(raw.data(), recs.data(), raw.size()), "read back");
    t.ok(!p2tb::VecFile::read(path, 0x1235, sizeof(Rec), &raw, &n), "another record type accepted");
    t.ok(!p2tb::VecFile::read(path, 0x1234, sizeof(Rec) + 8, &raw, &n), "another record size accepted");
    unlink(path.c_str());
}

// ---- zkey ----

void RoundTrip(Fails& t, const StoredDepth& d, const char* cls, long* count)
{
    (*count)++;
    StoredDepth back;
    const bool ok = p2tb::zkey_stored(d.k, &back);
    // refsw3 makes -0 (0x80000000) with the key of +0: the inverse gives the word 0
    const uint32_t wantBits = d.bits == 0x80000000u ? 0 : d.bits;
    t.ok(ok && back.k == d.k && back.bits == wantBits, "%s: key %016llx bits %08x -> %s key %016llx bits %08x", cls,
         (unsigned long long)d.k, d.bits, ok ? "ok" : "rejected", (unsigned long long)back.k, back.bits);
}

Fp RandomFp(p2tb::Rng& r, int bitsMax, int expLo, int expHi)
{
    Fp v;
    const int nb = (int)r.range(1, bitsMax);
    v.mant = (r.u64() & ((1ull << nb) - 1)) | (1ull << (nb - 1));
    v.exp = (int)r.range(expLo, expHi);
    v.neg = r.chance(500);
    return v;
}

void TestZkey(Fails& t)
{
    t.set("zkey");
    p2tb::Rng r(12345);
    long nBits = 0, nFromFp = 0, nNeg = 0, nBig = 0, nFlat = 0, nReg = 0, nSat = 0;
    // Bits: every special word, then random words
    const uint32_t special[] = {0, 0x80000000u, 1, 0x80000001u, 0x007fffffu, 0x807fffffu, 0x00800000u, 0x7f7fffffu,
                                0x7f800000u, 0xff800000u, 0x7f800001u, 0x7fffffffu, 0xffffffffu, 0x7f000000u,
                                0xff000000u, 0x3f800000u, 0xbf800000u, 0xc2ffffffu, 0xc2ffffe0u};
    for (uint32_t w : special)
        RoundTrip(t, StoredDepth::Bits(w), "Bits", &nBits);
    for (int i = 0; i < 200000; i++)
        RoundTrip(t, StoredDepth::Bits(r.u32()), "Bits", &nBits);
    // FromFp of 19-bit and 24-bit values across the float's range and past it
    for (int i = 0; i < 200000; i++)
        RoundTrip(t, StoredDepth::FromFp(RandomFp(r, i & 1 ? 19 : 24, -200, 140)), "FromFp", &nFromFp);
    // Neg: every block exponent, M in, above and below the window, and their ends
    for (int E = -122; E <= 128; E++) {
        const int64_t ends[] = {-1, -2, -(1 << 15) + 1, -(1 << 15), -(1 << 15) - 1, -(1 << 16) + 1, -(1 << 16),
                                -(1 << 16) - 1, -(1 << 22), -(1 << 23) + 1, -((int64_t)1 << 29), -((int64_t)1 << 30) + 1};
        for (int64_t M : ends)
            RoundTrip(t, StoredDepth::Neg(E, M), "Neg", &nNeg);
        for (int i = 0; i < 400; i++) {
            const int64_t M = -(int64_t)(1 + r.below((uint64_t)1 << r.range(1, 29)));
            RoundTrip(t, StoredDepth::Neg(E, M), "Neg", &nNeg);
        }
    }
    // Big: 19-bit values from 2^128 up (the register's reach 2^131, block depths beyond)
    for (int i = 0; i < 100000; i++) {
        Fp v = RandomFp(r, 19, 0, 0);
        v.neg = false;
        v.exp = (int)r.range(129, 170) - Fp::Bits(v.mant);   // top 129 .. 170
        RoundTrip(t, StoredDepth::Big(v), "Big", &nBig);
    }
    // Flat at the depth unit's widths (startBits 20, storedBits 19), bad values included
    for (int i = 0; i < 100000; i++) {
        Fp v = RandomFp(r, 24, -160, 110);
        if (r.chance(20)) {
            v.bad = true;
            v.mant = 0;
        }
        RoundTrip(t, StoredDepth::Flat(v, pvrisp::DepthHW::startBits, pvrisp::DepthHW::storedBits), "Flat", &nFlat);
    }
    RoundTrip(t, StoredDepth::Saturated(false), "Saturated", &nSat);
    RoundTrip(t, StoredDepth::Saturated(true), "Saturated", &nSat);
    // RegDepth: every whole step of 2^25 (the register's words), then random registers of all 30 bits
    using DT = pvrisp::DepthTileT<pvrisp::DepthHW>;
    for (int64_t s = -32; s < 32; s++)
        for (int64_t d : {-1, 0, 1})
            RoundTrip(t, DT::RegDepth(s * ((int64_t)1 << 25) + d), "RegDepth", &nReg);
    for (int i = 0; i < 200000; i++)
        RoundTrip(t, DT::RegDepth((int64_t)(r.u64() >> 34) - ((int64_t)1 << 29)), "RegDepth", &nReg);
    printf("p2tb_selftest: zkey round trips: Bits %ld, FromFp %ld, Neg %ld, Big %ld, Flat %ld, Saturated %ld, "
           "RegDepth %ld\n", nBits, nFromFp, nNeg, nBig, nFlat, nSat, nReg);

    // keys refsw3 cannot make are rejected
    t.set("zkey-reject");
    const int64_t notKeys[] = {
        (int64_t)StoredDepth::Key32(0x3f800000u) * ((int64_t)1 << 32) + 1,   // a positive ordinary word plus a bit
        (int64_t)StoredDepth::Key32(0xbf800001u) * ((int64_t)1 << 32) + 5,   // a negative word with a fraction
        (int64_t)StoredDepth::Key32(0xbf800000u) * ((int64_t)1 << 32) + (1 << 15),   // M = 0 above a window
        // below a window with M = -2^15, inside the window (refsw3 stores that as a word), and with M = +5
        (int64_t)StoredDepth::Key32(0xbf800000u) * ((int64_t)1 << 32) + ((int64_t)3 << 30) - (1 << 15),
        (int64_t)StoredDepth::Key32(0xbf800000u) * ((int64_t)1 << 32) + ((int64_t)3 << 30) + 5,
    };
    for (int64_t k : notKeys) {
        StoredDepth d;
        t.ok(!p2tb::zkey_stored(k, &d), "accepted %016llx", (unsigned long long)k);
    }
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Fails t("p2tb_selftest");
    TestFails(t);
    TestArgs(t);
    TestShards(t);
    TestRng(t);
    std::string dir = argv[0];
    dir = dir.find('/') == std::string::npos ? "." : dir.substr(0, dir.rfind('/'));
    TestVecFile(t, dir);
    TestZkey(t);
    (void)argc;
    return t.finish();
}
