// sort_tb.cpp: the run queue and span sorter testbench (PLAN M8; make sort, sort-full, sort-mutants).
//
//   tb --cfg C [--seed S] [--shard k/N] [--max-fails N] [--limit CLK] <stream file> ... | @<list file>
//   tb --cfg C --random NSTREAMS [--block B] [--seed S] [--shard k/N] [--max-fails N]
//
// The DUT (p2_sort_tb_top.sv) is p2_runq -> p2_sort with p2_entq beside them. The testbench is p2_isp_cut on one side
// (it pushes the run stream, an entry's record into p2_entq with its eoe item, a full p2_entq holding that item) and the
// SRQ / p2_tbuf on the other (it pops the sorted stream, and p2_entq's record when the eoe item leaves). SPAN_SORT_CFG is
// C for the whole run (bit 0 the sorter, bit 8 offset sort), the reference's too.
//
// The reference: refsw3's SpanSort (sort_ref.h: p2ref::span_sort, under SPAN_SORT_CFG = C) of each pass's runs, the
// pass being the items from one eop to the next (a null item is in no pass). The expected stream is every pass's runs
// in SpanSort's order, eop on the pass's last and eoe on it when the pass ended its entry, a null item where it came
// (between the passes), and every item of pass e before any of pass e + 1. The DUT's stream must equal it item by item,
// every field (tag, line, column, length, rm, epoch, vmask, pmask, null, eop, eoe), and each eoe item's entry record
// from p2_entq the one pushed with it. Passes come back to back with no barrier between them (but where the ISP was
// reset: a recorded stream's render that starts with R_RESET waits for the sorter to empty, as p2_isp_cut's epoch
// restarts there).
//
// The inputs:
// - recorded streams (tb/common/runstream.h, written by tb/isp_tile --mode free --dump-runs: M7's run streams of the
//   tile subset as p2_isp_cut emitted them), a case per file;
// - --random NSTREAMS: random streams (PLAN M8): each with a tag pool of 1..200 tags (some sharing all but bits 2..0,
//   so that offset sort merges them), 1..32 runs per row at most, 1..20 passes (some empty: they emit nothing and do not
//   count in the epoch), entries of one or more passes ending with eoe on their last run or a null item after it, and
//   entries with no run (a null item alone); in blocks of B (1000) streams back to back, each block a work item: its
//   generators are seeded from the seed, C and the block, its epoch starts at random.
// Back-pressure: per render (recorded) or stream (random), a class drawn at random: none; random gaps on both sides; a
// slow cutter (the input offered one clock in 3, held in bursts: the window starves, so the emit condition is what keeps
// the order); a slow TSP (the output stalls often, in bursts of up to 24 clocks).
//
// new_drain (the sorter's output to the TSP's look-ahead, ARCHITECTURE 3.6) is checked on every item with the sorter on:
// 1 exactly on a pass's first item and where the key differs from the item before it in the pass, 0 on a null item.
//
// Reports per case its renders / streams, entries, passes and items, and the clocks: per item, the clocks the window
// was full, the steps held by the emit condition, the drains (new_drain) and the drain ends without an emit, the run
// queue's deepest occupancy; then "sort: <n> checks, <m> failures" and PASS / FAIL.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include <zlib.h>

#include "Vp2_sort_tb_top.h"
#include "verilated.h"

#include "p2tb.h"
#include "runstream.h"
#include "sort_ref.h"

namespace {

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed = 1) : s(seed * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull) {}
    uint32_t u32()
    {
        s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
        return (uint32_t)((s * 0x2545F4914F6CDD1Dull) >> 32);
    }
    uint32_t below(uint32_t n) { return n ? u32() % n : 0; }
};

struct Item {
    bool null_ = false, eop = false, eoe = false;
    uint32_t tag = 0, vmask = 0, pmask = 0;
    int y = 0, x = 0, len = 1, rm = 0, epoch = 0;
    // the eoe item's entry record
    int tilex = 0, tiley = 0;
    uint8_t ent = 0;
    // a control record of the input: the back-pressure class from here on (cls >= 0); a barrier (wait for the DUT
    // to empty)
    int cls = -1;
    bool barrier = false;
};

// the back-pressure of a class
struct Pace {
    uint32_t inGap = 0, inBurst = 1, outStall = 0, outBurst = 1;
    bool slow = false;
};
Pace PaceOf(int cls, Rng& r)
{
    Pace p;
    switch (cls) {
    case 0: break;
    case 1: p.inGap = 8 + r.below(120); p.inBurst = 1 + r.below(8); p.outStall = 8 + r.below(120); p.outBurst = 1 + r.below(8); break;
    case 2: p.slow = true; p.inBurst = 1 + r.below(24); p.outStall = r.below(64); p.outBurst = 1 + r.below(4); break;
    default: p.outStall = 128 + r.below(100); p.outBurst = 1 + r.below(24); break;
    }
    return p;
}

struct Tb {
    Vp2_sort_tb_top* t = nullptr;
    p2tb::Fails& f;
    uint32_t cfg = 0x101;
    uint64_t cyc = 0, limit = 2000000;
    std::string where;

    // the input (in order, with control records) and the expected output
    std::deque<Item> in;
    std::deque<Item> exp;
    std::deque<Item> recs;              // records pushed into p2_entq, for the message
    std::vector<Item> pass;             // the current pass's runs, raster order (the input side)

    Rng rng;
    Pace pin, pout;
    int curCls = 0;                     // the input side's back-pressure class (for messages)
    uint32_t inHold = 0, outHold = 0;
    std::deque<Pace> paceAt;            // the output side takes the class of the items it pops (queued at their input)
    std::deque<size_t> paceIdx;

    // statistics
    long items = 0, nulls = 0, passes = 0, entries = 0, drains = 0, waits = 0, ends = 0, fullClk = 0;
    // new_drain (ARCHITECTURE 3.6: the TSP's look-ahead): with the sorter on, 1 exactly on a pass's first item and where
    // the key (the tag, & ~7 with offset sort) differs from the item before it in the pass; never on a null item
    bool ndFirst = true;
    uint32_t ndKey = 0;
    long ndChecks = 0;
    uint64_t c0 = 0;
    unsigned occMax = 0;
    bool broken = false;
    size_t pushed = 0, popped = 0;

    explicit Tb(p2tb::Fails& fl) : f(fl) {}

    void reset()
    {
        t->rst = 1;
        t->in_v = 0;
        t->out_rdy = 0;
        t->eqi_v = 0;
        t->eq_rdy = 0;
        t->cfg_on = cfg & 1;
        t->cfg_offs = (cfg >> 8) & 1;
        for (int i = 0; i < 4; i++) {
            t->clk = 0;
            t->eval();
            t->clk = 1;
            t->eval();
        }
        t->rst = 0;
        in.clear();
        exp.clear();
        recs.clear();
        pass.clear();
        paceAt.clear();
        paceIdx.clear();
        inHold = outHold = 0;
        pushed = popped = 0;
        broken = false;
        ndFirst = true;
    }

    // the input side: an item into the stream; at a pass's eop its expected order (refsw3's SpanSort)
    void add(const Item& it)
    {
        in.push_back(it);
        if (it.null_) {
            exp.push_back(it);
            nulls++;
            if (it.eoe)
                entries++;
            return;
        }
        pass.push_back(it);
        if (!it.eop)
            return;
        std::vector<sortref::Span> s(pass.size());
        for (size_t i = 0; i < pass.size(); i++)
            s[i] = { pass[i].tag, (uint8_t)pass[i].y, (uint8_t)pass[i].x, (uint8_t)pass[i].len };
        std::vector<uint16_t> order(pass.size() + 1);
        const int n = sortref::span_sort(cfg, s.data(), (int)s.size(), order.data());
        if (!f.ok(n == (int)pass.size(), "%s: SpanSort returned %d of %zu runs", where.c_str(), n, pass.size())) {
            broken = true;
            return;
        }
        for (int k = 0; k < n; k++) {
            Item e = pass[order[k]];
            e.eop = k == n - 1;
            e.eoe = e.eop && it.eoe;
            exp.push_back(e);
        }
        passes++;
        if (it.eoe)
            entries++;
        pass.clear();
    }
    void control(int cls, bool barrier)
    {
        Item c;
        c.cls = cls;
        c.barrier = barrier;
        in.push_back(c);
    }

    // one clock
    void tick()
    {
        // the input side: control records first (the class, a barrier: everything pushed has left)
        while (!in.empty() && (in.front().cls >= 0 || in.front().barrier)) {
            if (in.front().barrier && popped < pushed)
                break;
            if (in.front().cls >= 0) {
                curCls = in.front().cls;
                pin = PaceOf(in.front().cls, rng);
                pout = pin;
            }
            in.pop_front();
        }
        bool offer = false;
        if (!in.empty() && !in.front().barrier && in.front().cls < 0) {
            if (inHold)
                inHold--;
            else if (pin.slow ? rng.below(3) != 0 : (pin.inGap && rng.below(256) < pin.inGap))
                inHold = pin.slow ? rng.below(pin.inBurst) : rng.below(pin.inBurst);
            else
                offer = true;
        }
        const Item* ii = offer ? &in.front() : nullptr;
        t->in_v = 0;
        t->eqi_v = 0;
        if (ii) {
            t->in_null = ii->null_;
            t->in_tag = ii->tag;
            t->in_y = ii->y;
            t->in_x = ii->x;
            t->in_lenm1 = ii->len - 1;
            t->in_rm = ii->rm;
            t->in_epoch = ii->epoch;
            t->in_vmask = ii->vmask;
            t->in_pmask = ii->pmask;
            t->in_eop = ii->eop;
            t->in_eoe = ii->eoe;
            t->eqi_tilex = ii->tilex;
            t->eqi_tiley = ii->tiley;
            t->eqi_z_keep = ii->ent & p2rs::E_ZKEEP ? 1 : 0;
            t->eqi_no_writeout = ii->ent & p2rs::E_NOWO ? 1 : 0;
            t->eqi_last = ii->ent & p2rs::E_LAST ? 1 : 0;
            t->eqi_shaded_any = ii->ent & p2rs::E_SHADED ? 1 : 0;
        }
        // the output side
        if (outHold)
            outHold--;
        else if (pout.outStall && rng.below(256) < pout.outStall)
            outHold = rng.below(pout.outBurst);
        t->out_rdy = outHold == 0;
        // every ready / valid the DUT gives depends on its state only (p2_runq's in_rdy, p2_entq's in_rdy and out_v,
        // p2_sort's out_v and item), as the last clock left them: the handshakes are decided here, then one clock
        // the cutter: an eoe item only with room in p2_entq (p2_isp_cut: rs_v = !eoe || eq_rdy), its record with it
        if (ii) {
            t->in_v = !ii->eoe || t->eqi_rdy;
            t->eqi_v = t->in_v && t->in_rdy && ii->eoe;
        }
        // p2_tbuf: the record when the eoe item leaves
        t->eq_rdy = t->out_v && t->out_rdy && t->out_eoe;
        const bool inTake = t->in_v && t->in_rdy;
        if (inTake && ii->eoe)
            recs.push_back(*ii);
        if (t->out_v && t->out_rdy)
            check_out();
        if (t->t_full)
            fullClk++;
        if (t->t_wait)
            waits++;
        if (t->t_end)
            ends++;
        occMax = std::max(occMax, (unsigned)t->t_runq_occ);
        t->clk = 0;
        t->eval();
        t->clk = 1;
        t->eval();
        if (inTake) {
            in.pop_front();
            pushed++;
        }
        cyc++;
    }

    void check_out()
    {
        Item g;
        g.null_ = t->out_null;
        g.tag = t->out_tag;
        g.y = t->out_y;
        g.x = t->out_x;
        g.len = t->out_lenm1 + 1;
        g.rm = t->out_rm;
        g.epoch = t->out_epoch;
        g.vmask = t->out_vmask;
        g.pmask = t->out_pmask;
        g.eop = t->out_eop;
        g.eoe = t->out_eoe;
        popped++;
        items++;
        if (t->out_new_drain)
            drains++;
        if (exp.empty()) {
            f.ok(false, "%s: an item out that was never expected {null %d tag %08x y %d x %d}", where.c_str(), g.null_,
                 g.tag, g.y, g.x);
            broken = true;
            return;
        }
        const Item e = exp.front();
        exp.pop_front();
        const bool same = g.null_ == e.null_ && g.eop == e.eop && g.eoe == e.eoe && g.epoch == e.epoch &&
                          (e.null_ || (g.tag == e.tag && g.y == e.y && g.x == e.x && g.len == e.len && g.rm == e.rm &&
                                       g.vmask == e.vmask && g.pmask == e.pmask));
        if (!f.ok(same, "%s: item %zu out {null %d tag %08x y %d x %d len %d rm %d epoch %d vmask %08x pmask %08x eop %d "
                  "eoe %d}, reference {%d %08x %d %d %d %d %d %08x %08x %d %d} (input class %d)", where.c_str(), popped - 1, g.null_,
                  g.tag, g.y, g.x, g.len, g.rm, g.epoch, g.vmask, g.pmask, g.eop, g.eoe, e.null_, e.tag, e.y, e.x,
                  e.len, e.rm, e.epoch, e.vmask, e.pmask, e.eop, e.eoe, curCls)) {
            broken = true;
            return;
        }
        if (cfg & 1) {
            const uint32_t key = g.tag & ((cfg & 0x100) ? ~7u : ~0u);
            const bool want = !g.null_ && (ndFirst || key != ndKey);
            ndChecks++;
            if (!f.ok((bool)t->out_new_drain == want, "%s: item %zu out {null %d tag %08x y %d x %d epoch %d}: new_drain %d, expected %d "
                      "(%s)", where.c_str(), popped - 1, g.null_, g.tag, g.y, g.x, g.epoch, (int)t->out_new_drain, want,
                      g.null_ ? "a null item" : ndFirst ? "the pass's first item" : key != ndKey ? "a new key" : "the key of the item before")) {
                broken = true;
                return;
            }
            if (!g.null_) {
                ndFirst = false;
                ndKey = key;
            }
            if (g.eop)
                ndFirst = true;
        }
        if (g.eoe) {
            if (!f.ok(t->eq_v && !recs.empty(), "%s: an eoe item out with no record in p2_entq", where.c_str())) {
                broken = true;
                return;
            }
            const Item r = recs.front();
            recs.pop_front();
            const uint8_t ent = (t->eq_z_keep ? p2rs::E_ZKEEP : 0) | (t->eq_no_writeout ? p2rs::E_NOWO : 0) |
                                (t->eq_last ? p2rs::E_LAST : 0) | (t->eq_shaded_any ? p2rs::E_SHADED : 0);
            if (!f.ok((int)t->eq_tilex == r.tilex && (int)t->eq_tiley == r.tiley && ent == r.ent,
                      "%s: entry record {%d, %d, %02x} from p2_entq, pushed {%d, %d, %02x}", where.c_str(),
                      (int)t->eq_tilex, (int)t->eq_tiley, ent, r.tilex, r.tiley, r.ent)) {
                broken = true;
                return;
            }
        }
    }

    // run until everything given has left
    bool drain()
    {
        uint64_t last = cyc;
        size_t lastPop = popped;
        while (!broken && (!in.empty() || !exp.empty())) {
            tick();
            if (popped != lastPop) {
                lastPop = popped;
                last = cyc;
            } else if (cyc - last > limit) {
                f.ok(false, "%s: no item out in %llu clocks (%zu in the input, %zu expected)", where.c_str(),
                     (unsigned long long)limit, in.size(), exp.size());
                broken = true;
            }
        }
        if (!broken)
            f.ok(pass.empty() && recs.empty() && !t->out_v && !t->eq_v,
                 "%s: at the end: %zu runs of an unfinished pass, %zu records, out_v %d, p2_entq %d", where.c_str(),
                 pass.size(), recs.size(), (int)t->out_v, (int)t->eq_v);
        return !broken;
    }

    void stats_reset()
    {
        items = nulls = passes = entries = drains = waits = ends = fullClk = 0;
        occMax = 0;
        c0 = cyc;
    }
    void report(const char* what, long units, const char* unitName)
    {
        const uint64_t clk = cyc - c0;
        printf("sort: %s: %ld %s, %ld entries, %ld passes, %ld items (%ld null); %llu clocks, %.3f an item; window full "
               "%ld clk, %ld steps held by the emit condition, %ld drains (%.2f items a drain), %ld drain ends with no "
               "emit; run queue at most %u\n",
               what, units, unitName, entries, passes, items, nulls, (unsigned long long)clk,
               items ? (double)clk / items : 0.0, fullClk, waits, drains,
               drains ? (double)(items - nulls) / drains : 0.0, ends, occMax);
    }
};

// ---------------------------------------------------------------------------------------------------------- inputs
// a recorded stream (runstream.h) into the input
bool LoadStream(Tb& tb, const std::string& path, Rng& r, long* renders)
{
    gzFile g = gzopen(path.c_str(), "rb");
    if (!g)
        return false;
    p2rs::Rec rec;
    int n;
    while ((n = gzread(g, &rec, sizeof rec)) == (int)sizeof rec) {
        if (rec.kind == p2rs::K_RENDER) {
            (*renders)++;
            tb.control((int)r.below(4), (rec.flags & p2rs::R_RESET) != 0);
            continue;
        }
        Item it;
        it.null_ = rec.flags & p2rs::F_NULL;
        it.eop = rec.flags & p2rs::F_EOP;
        it.eoe = rec.flags & p2rs::F_EOE;
        it.tag = rec.tag;
        it.y = rec.y;
        it.x = rec.x;
        it.len = rec.len;
        it.rm = rec.rm;
        it.epoch = rec.epoch;
        it.vmask = rec.vmask;
        it.pmask = rec.pmask;
        it.tilex = rec.tilex;
        it.tiley = rec.tiley;
        it.ent = rec.ent;
        tb.add(it);
    }
    const bool ok = n == 0;
    gzclose(g);
    return ok;
}

// a random stream (PLAN M8): appended to the input, the epoch carried in *ep
void RandomStream(Tb& tb, Rng& r, int* ep)
{
    tb.control((int)r.below(4), false);
    // the tag pool: 1..200 tags, from fewer bases (tag & ~7) so that offset sort merges some
    const int P = 1 + (int)r.below(200);
    const int nb = 1 + (int)r.below(P);
    std::vector<uint32_t> base(nb), pool(P);
    for (auto& b : base)
        b = r.u32() & ~7u;
    for (auto& t : pool)
        t = base[r.below(nb)] | r.below(8);
    // runs per row at most, and a row's chance to have runs (in 1/256): both drawn towards small numbers (a stream of
    // ~300 items on average), all of 1..32 and 1..256 possible
    const int R = 1 + (int)r.below(1 + r.below(32));
    const int rowP = 1 + (int)r.below(1 + r.below(256));
    const int passes = 1 + (int)r.below(20);
    int ex = (int)r.below(64), ey = (int)r.below(64);
    for (int p = 0; p < passes; p++) {
        const int rm = (int)r.below(6);
        // the pass's runs, raster order
        std::vector<Item> runs;
        if (r.below(8) != 0) {
            for (int y = 0; y < 32; y++) {
                if (r.below(256) >= (uint32_t)rowP)
                    continue;
                const int k = 1 + (int)r.below(R);
                // k distinct first columns, each run up to the next one's start
                std::vector<int> xs;
                for (int x = 0; x < 32; x++)
                    xs.push_back(x);
                for (int i = 0; i < 32; i++)
                    std::swap(xs[i], xs[i + r.below(32 - i)]);
                xs.resize(k);
                std::sort(xs.begin(), xs.end());
                for (int i = 0; i < k; i++) {
                    const int room = (i + 1 < k ? xs[i + 1] : 32) - xs[i];
                    Item it;
                    it.y = y;
                    it.x = xs[i];
                    it.len = 1 + (int)r.below(room);
                    it.rm = rm;
                    // runs of one primitive near each other, sometimes
                    it.tag = (!runs.empty() && r.below(4) == 0) ? runs[r.below((uint32_t)runs.size())].tag
                                                                 : pool[r.below(P)];
                    const uint32_t lm = it.len == 32 ? ~0u : (1u << it.len) - 1;
                    it.vmask = r.u32() & lm;
                    it.pmask = (rm >= 1 && rm <= 3) ? (r.u32() & lm) : 0;
                    runs.push_back(it);
                }
            }
        }
        const bool endEntry = p == passes - 1 || r.below(3) == 0;
        const bool nullEnd = endEntry && (runs.empty() || r.below(4) == 0);
        if (!runs.empty()) {
            for (auto& it : runs)
                it.epoch = *ep & 127;
            runs.back().eop = true;
            runs.back().eoe = endEntry && !nullEnd;
            if (runs.back().eoe) {
                runs.back().tilex = ex;
                runs.back().tiley = ey;
                runs.back().ent = (uint8_t)r.below(16);
            }
            for (auto& it : runs)
                tb.add(it);
            *ep = (*ep + 1) & 127;
        }
        if (nullEnd) {
            // the entry's end on a null item (with the epoch the next pass will have, as p2_isp_cut gives it)
            Item n;
            n.null_ = true;
            n.eoe = true;
            n.rm = rm;
            n.epoch = *ep & 127;
            n.tilex = ex;
            n.tiley = ey;
            n.ent = (uint8_t)r.below(16);
            tb.add(n);
        }
        if (endEntry) {
            ex = (int)r.below(64);
            ey = (int)r.below(64);
        }
    }
}

}   // namespace

int main(int argc, char** argv)
{
    p2tb::raise_stack();
    Verilated::commandArgs(argc, argv);
    p2tb::Args a;
    if (!a.parse(argc, argv)) {
        fprintf(stderr, "sort: %s\n", a.error.c_str());
        return 2;
    }
    uint32_t cfg = 0x101;
    long nRandom = 0, block = 1000, maxFails = 0;
    uint64_t limit = 2000000;
    std::vector<std::string> cases;
    for (size_t i = 0; i < a.rest.size(); i++) {
        const std::string& s = a.rest[i];
        if (s == "--cfg" && i + 1 < a.rest.size())
            cfg = (uint32_t)strtoul(a.rest[++i].c_str(), nullptr, 0);
        else if (s == "--random" && i + 1 < a.rest.size())
            nRandom = atol(a.rest[++i].c_str());
        else if (s == "--block" && i + 1 < a.rest.size())
            block = std::max(1L, atol(a.rest[++i].c_str()));
        else if (s == "--max-fails" && i + 1 < a.rest.size())
            maxFails = atol(a.rest[++i].c_str());
        else if (s == "--limit" && i + 1 < a.rest.size())
            limit = strtoull(a.rest[++i].c_str(), nullptr, 0);
        else if (s[0] == '@') {
            FILE* lf = fopen(s.c_str() + 1, "r");
            if (!lf) {
                fprintf(stderr, "sort: cannot read %s\n", s.c_str() + 1);
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
        } else if (s[0] != '+')
            cases.push_back(s);
    }
    p2tb::banner("sort", a);
    printf("sort: SPAN_SORT_CFG 0x%03x (sorter %s, %s)\n", cfg, cfg & 1 ? "on" : "off (raster order)",
           cfg & 0x100 ? "offset sort: tag & ~7" : "the whole tag");
    p2tb::Fails f("sort");
    Vp2_sort_tb_top* top = new Vp2_sort_tb_top;
    Tb tb(f);
    tb.t = top;
    tb.cfg = cfg;
    tb.limit = limit;

    long nCases = 0;
    uint64_t totItems = 0, totClk = 0;
    if (nRandom > 0) {
        f.set("random");
        const long blocks = (nRandom + block - 1) / block;
        for (long b = 0; b < blocks; b++) {
            if (!a.mine((size_t)b))
                continue;
            if (maxFails && f.n >= maxFails)
                break;
            nCases++;
            tb.rng = Rng(a.seed * 1000003ull + cfg * 7919ull + (uint64_t)b);
            Rng gen(a.seed * 0x100000001B3ull + (uint64_t)b);   // the streams: the same under every SPAN_SORT_CFG
            tb.reset();
            tb.stats_reset();
            char w[64];
            snprintf(w, sizeof w, "random block %ld", b);
            tb.where = w;
            int ep = (int)gen.below(128);
            const long first = b * block, n = std::min(block, nRandom - first);
            for (long s = 0; s < n && !tb.broken; s++) {
                RandomStream(tb, gen, &ep);
                // keep the input short: run while more than a few streams' worth is queued
                while (!tb.broken && tb.in.size() > 4096)
                    tb.tick();
            }
            tb.drain();
            tb.report(w, n, "streams");
            totItems += tb.items;
            totClk += tb.cyc - tb.c0;
        }
    } else {
        f.set("subset");
        for (size_t ci = 0; ci < cases.size(); ci++) {
            if (!a.mine(ci))
                continue;
            if (maxFails && f.n >= maxFails)
                break;
            nCases++;
            const std::string& c = cases[ci];
            tb.rng = Rng(a.seed * 1000003ull + cfg * 7919ull + ci);
            Rng cls(a.seed * 0x100000001B3ull + ci);
            tb.reset();
            tb.stats_reset();
            tb.where = c;
            long renders = 0;
            if (!f.ok(LoadStream(tb, c, cls, &renders), "%s: cannot read the stream", c.c_str()))
                continue;
            tb.drain();
            tb.report(c.c_str(), renders, "renders");
            totItems += tb.items;
            totClk += tb.cyc - tb.c0;
        }
    }
    printf("sort: %ld cases, %llu items, %llu clocks (%.3f an item)\n", nCases, (unsigned long long)totItems,
           (unsigned long long)totClk, totItems ? (double)totClk / totItems : 0.0);
    top->final();
    delete top;
    return f.finish();
}
