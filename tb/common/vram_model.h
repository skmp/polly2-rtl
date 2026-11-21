// vram_model.h: the VRAM model the tile and frame testbenches put behind p2_core's two VRAM half ports (ARCHITECTURE
// 3.2.1, PLAN 1.6; testbench code, not RTL). Header only, C++17, no dependency on refcore or Verilator: the memory is
// refcore's emu_vram in the 64-bit physical order (half 0 is bytes 8w .. 8w+3 of word w, half 1 is 8w+4 .. 8w+7),
// handed in as a pointer.
//
// Per half:
//   a request queue of Q entries: vh_req_rdy while it has room (and, with +vramvary, not on a random clock; +vramvary
//     also stalls a half for up to 63 clocks one clock in 64);
//   the queue's head is granted when the half is free and its row is open: an access to another row than the open one
//     costs VR_ROW clocks first (rows of ROW_WORDS words [G]); +vramvary adds a random 0 .. VARY_MAX clocks to each;
//   a request takes effect at the clock it is granted (the visibility rule): a write commits to emu_vram then (byte
//     enables), a read samples emu_vram then and is answered VR_LAT clocks later, in request order, one a clock;
//   refresh and display stalls: off (GAP T9; ARCHITECTURE 3.2.1 lists them).
// The hazard detector: per render the words C5 wrote and the words C0 .. C4 read; a render where they meet is VRAM-race
// (race_words(), first_race()).
//
// Use, each clock (the Verilated top's ports are the caller's):
//   model.drive(rdy, rsp_v, rsp_data, rsp_src)      the inputs of this clock, from the model's state
//   ... eval with clk low; read the DUT's requests ...
//   model.edge(req_v, we, idx, be, wdata, src)      at the rising edge: accepts, pops, grants; advances the clock
#pragma once
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>

namespace p2tb {

struct VramModel {
    // parameters (ARCHITECTURE 6: VR_LAT 8 [G], VR_ROW fitted later [G], the row size from SDRAM_CFG GAP)
    int vrLat = 8;
    int vrRow = 2;
    uint32_t rowWords = 512;        // 2 KB rows a half [G]
    size_t queue = 4;
    uint64_t varySeed = 0;          // +vramvary=<seed>: 0 off
    int varyMax = 12;

    uint8_t* mem = nullptr;         // emu_vram, 8 MB, 64-bit physical order

    struct Req {
        bool we;
        uint32_t idx, wdata;
        uint8_t be, src;
        uint64_t at;                // when it may be granted (set when it reaches the head)
        bool timed;
    };
    struct Rsp {
        uint64_t t;
        uint32_t data;
        uint8_t src;
    };
    struct Half {
        std::deque<Req> q;
        std::deque<Rsp> out;
        uint32_t openRow = ~0u;
        uint64_t free = 0;
        bool rdy = true, rspV = false;
    } h[2];
    uint64_t now = 0;
    uint64_t grants = 0, reads = 0, writes = 0;
    uint64_t readsBy[2][8] = {};    // per half, per client

    // the hazard detector's bitmaps: 2M 32-bit words, one bit each
    std::vector<uint64_t> wrC5, rdOther;
    uint64_t raceWords = 0;
    int64_t firstRace = -1;

    uint64_t rs = 0;
    uint32_t rnd()
    {
        rs ^= rs >> 12;
        rs ^= rs << 25;
        rs ^= rs >> 27;
        return (uint32_t)((rs * 0x2545F4914F6CDD1Dull) >> 32);
    }

    void init(uint8_t* m)
    {
        mem = m;
        rs = varySeed * 0x9E3779B97F4A7C15ull + 1;
        wrC5.assign((2u << 20) / 64, 0);
        rdOther.assign((2u << 20) / 64, 0);
        for (Half& x : h) {
            x.q.clear();
            x.out.clear();
            x.openRow = ~0u;
            x.free = now;
        }
    }
    // a new render: the hazard detector starts again
    void begin_render()
    {
        std::fill(wrC5.begin(), wrC5.end(), 0);
        std::fill(rdOther.begin(), rdOther.end(), 0);
        raceWords = 0;
        firstRace = -1;
    }
    // the render's VRAM-race words (C5 wrote a word that C0 .. C4 read); first: its 32-bit word index, half 0 even
    uint64_t race_words()
    {
        raceWords = 0;
        firstRace = -1;
        for (size_t i = 0; i < wrC5.size(); i++) {
            const uint64_t x = wrC5[i] & rdOther[i];
            if (x) {
                raceWords += __builtin_popcountll(x);
                if (firstRace < 0)
                    firstRace = (int64_t)(i * 64 + __builtin_ctzll(x));
            }
        }
        return raceWords;
    }
    bool busy() const { return !h[0].q.empty() || !h[1].q.empty() || !h[0].out.empty() || !h[1].out.empty(); }

    // this clock's inputs to the DUT
    void drive(int half, bool* rdy, bool* rspV, uint32_t* rspData, uint32_t* rspSrc)
    {
        Half& x = h[half];
        x.rdy = x.q.size() < queue && !(varySeed && (rnd() & 3) == 0);
        x.rspV = !x.out.empty() && x.out.front().t <= now;
        *rdy = x.rdy;
        *rspV = x.rspV;
        *rspData = x.rspV ? x.out.front().data : 0;
        *rspSrc = x.rspV ? x.out.front().src : 0;
    }

    // the rising edge, with the DUT's requests of this clock
    void edge(int half, bool reqV, bool we, uint32_t idx, uint32_t be, uint32_t wdata, uint32_t src)
    {
        Half& x = h[half];
        if (x.rspV)
            x.out.pop_front();
        if (reqV && x.rdy)
            x.q.push_back(Req{ we, idx & 0xFFFFF, wdata, (uint8_t)be, (uint8_t)src, 0, false });
        // +vramvary: now and then a half stalls for up to 63 clocks (as refresh and the display's reads would), so that
        // a client's reads on the two halves come back out of their request order (p2_mem's per-client order)
        if (varySeed && (rnd() & 63) == 0) {
            const uint64_t until = now + (rnd() & 63);
            if (until > x.free)
                x.free = until;
            if (!x.q.empty() && x.q.front().timed && x.q.front().at < x.free)
                x.q.front().at = x.free;
        }
        // the head's grant time: the half free, its row opened
        if (!x.q.empty()) {
            Req& r = x.q.front();
            if (!r.timed) {
                const uint32_t row = r.idx / rowWords;
                uint64_t t = x.free > now ? x.free : now;
                if (row != x.openRow)
                    t += vrRow;
                if (varySeed)
                    t += rnd() % (varyMax + 1);
                r.at = t;
                r.timed = true;
                x.openRow = row;
            }
            if (r.at <= now) {
                const uint32_t byte = 8 * r.idx + 4 * half;
                const uint32_t w2 = 2 * r.idx + half;       // the hazard bitmaps' word: half 0 even
                if (r.we) {
                    for (int b = 0; b < 4; b++)
                        if (r.be >> b & 1)
                            mem[byte + b] = (uint8_t)(r.wdata >> (8 * b));
                    if (r.src == 5)
                        wrC5[w2 / 64] |= 1ull << (w2 % 64);
                    writes++;
                } else {
                    uint32_t d;
                    memcpy(&d, mem + byte, 4);
                    x.out.push_back(Rsp{ now + (uint64_t)vrLat, d, r.src });
                    if (r.src != 5)
                        rdOther[w2 / 64] |= 1ull << (w2 % 64);
                    reads++;
                    readsBy[half][r.src & 7]++;
                }
                grants++;
                x.free = now + 1;
                x.q.pop_front();
            }
        }
    }
    void tick() { now++; }
};

}   // namespace p2tb
