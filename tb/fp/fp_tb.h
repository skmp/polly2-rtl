// fp_tb.h: what the tb/fp testbenches share (docs/spec/numerics.md 7.1; PLAN 1.2; conventions.md 7.2). Header only.
//
//   tuples     a reference value is a pvrfp::Fp; a port group X of a tb top is X_neg, X_bad, X_exp (10 bits, two's
//              complement), X_mant. FP_SET / FP_GET move one between them. same() is the comparison of num 7.1: neg,
//              bad, mant, and exp only when mant != 0 (never as a double).
//   fits()     the G11 / port-width assertion on a reference value before it is compared: exp in the 10-bit field
//              (num 1.4) and mant within the port. A reference value that does not fit is a failure of the generator's
//              domain, reported as such.
//   Lockstep   one vector a clock into a tb top whose DUTs are combinational and whose outputs it registers: the
//              result of the vector driven before an edge is on the outputs after it (latency kLat = 1). Each case is
//              checked when its result is due; with gaps() on, random idle clocks (in_v = 0) sit between cases and
//              out_v must be 0 on each (PLAN 1.2 section 4: no value may change; these primitives have no
//              handshake, so there is no back-pressure to apply).
//   expect()   a Fails check whose message is only built on failure.
#pragma once

#include <deque>
#include <string>
#include <utility>

#include "p2tb.h"
#include "pvr_softfp.h"

namespace fptb {

using pvrfp::Fp;
using p2tb::Fails;

constexpr int kEW = 10;   // P2_FP_EW

inline int64_t sext(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }
inline uint32_t efield(int e) { return (uint32_t)e & ((1u << kEW) - 1); }
inline bool expFits(int e) { return e >= -(1 << (kEW - 1)) && e < (1 << (kEW - 1)); }
inline bool mantFits(uint64_t m, int w) { return w >= 64 || (m >> w) == 0; }
inline int bl(uint64_t m) { return pvrfp::BitLength(m); }

inline Fp mk(bool neg, bool bad, int exp, uint64_t mant)
{
    Fp r;
    r.neg = neg;
    r.bad = bad;
    r.exp = exp;
    r.mant = mant;
    return r;
}
inline Fp fromPort(uint64_t neg, uint64_t bad, uint64_t exp, uint64_t mant)
{
    return mk(neg != 0, bad != 0, (int)sext(exp, kEW), mant);
}

inline bool same(const Fp& want, const Fp& got)
{
    return want.neg == got.neg && want.bad == got.bad && want.mant == got.mant && (want.mant == 0 || want.exp == got.exp);
}

inline std::string str(const Fp& f)
{
    char b[96];
    snprintf(b, sizeof b, "{%c%s exp %d mant 0x%llx}", f.neg ? '-' : '+', f.bad ? " bad" : "", f.exp,
             (unsigned long long)f.mant);
    return b;
}

// a reference value can be compared through a port of mant width w (and the 10-bit exponent field)
inline bool fits(const Fp& f, int w) { return mantFits(f.mant, w) && (f.mant == 0 || expFits(f.exp)); }

template <class Msg>
inline bool expect(Fails& f, bool c, Msg msg)
{
    if (c)
        return f.ok(true, "%s", "");
    const std::string m = msg();
    return f.ok(false, "%s", m.c_str());
}

// the RTL's tuple against the reference's, with the G11 / width assertion on the reference first; in() describes the
// inputs (called only on a failure)
template <class In>
inline bool expectFp(Fails& f, const char* what, const Fp& want, const Fp& got, int w, In in)
{
    if (!fits(want, w))
        return expect(f, false, [&] {
            return std::string(what) + ": the reference " + str(want) + " does not fit the port (G11 / width); in " + in();
        });
    return expect(f, same(want, got),
                  [&] { return std::string(what) + ": got " + str(got) + " want " + str(want) + "; in " + in(); });
}

#define FP_SET(t, X, f)                                \
    do {                                               \
        const pvrfp::Fp& fp_set_ = (f);                \
        (t)->X##_neg = fp_set_.neg;                    \
        (t)->X##_bad = fp_set_.bad;                    \
        (t)->X##_exp = fptb::efield(fp_set_.exp);      \
        (t)->X##_mant = fp_set_.mant;                  \
    } while (0)
#define FP_GET(t, X) fptb::fromPort((t)->X##_neg, (t)->X##_bad, (t)->X##_exp, (uint64_t)(t)->X##_mant)

// ---------------------------------------------------------------------------------------------------------------
// Case: void drive(Top*) const sets the DUT inputs; void check(Top*, Fails&) const compares the registered outputs
template <class Top, class Case>
class Lockstep {
public:
    static constexpr size_t kLat = 1;

    Lockstep(Top* t, Fails& f, uint64_t seed) : t_(t), f_(f), rng_(seed) {}
    void gaps(unsigned perMille) { gapPm_ = perMille; }
    void push(const Case& c)
    {
        while (gapPm_ && rng_.chance(gapPm_))
            clock(false, c);
        clock(true, c);
    }
    uint64_t cases() const { return cases_; }
    uint64_t clocks() const { return clocks_; }

private:
    void clock(bool v, const Case& c)
    {
        c.drive(t_);
        t_->in_v = v;
        t_->clk = 0;
        t_->eval();
        t_->clk = 1;
        t_->eval();
        clocks_++;
        q_.emplace_back(v, c);
        if (q_.size() >= kLat) {
            const std::pair<bool, Case>& h = q_.front();
            const bool ov = t_->out_v != 0;
            if (ov != h.first)
                f_.ok(false, "out_v %d at clock %llu, want %d", (int)ov, (unsigned long long)clocks_, (int)h.first);
            else if (h.first) {
                h.second.check(t_, f_);
                cases_++;
            } else
                f_.ok(true, "%s", "");
            q_.pop_front();
        }
    }

    Top* t_;
    Fails& f_;
    p2tb::Rng rng_;
    unsigned gapPm_ = 0;
    std::deque<std::pair<bool, Case>> q_;
    uint64_t cases_ = 0, clocks_ = 0;
};

// the common start of every tb/fp main(): stack, arguments, banner
inline bool start(const char* unit, int argc, char** argv, p2tb::Args* a)
{
    p2tb::raise_stack();
    if (!a->parse(argc, argv)) {
        fprintf(stderr, "%s: %s\n", unit, a->error.c_str());
        return false;
    }
    if (!a->rest.empty()) {
        fprintf(stderr, "%s: unknown argument %s\n", unit, a->rest[0].c_str());
        return false;
    }
    p2tb::banner(unit, *a);
    return true;
}

// one line per section: its case count
inline void sectionDone(const char* unit, const char* section, uint64_t n)
{
    printf("%s: section %s: %llu cases\n", unit, section, (unsigned long long)n);
    fflush(stdout);
}

}   // namespace fptb
