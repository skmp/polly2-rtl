// Native SD raster checks for 480i, 240p, 576i and 288p.
#include "Vspg_sd.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

struct EdgeSet {
    std::vector<int64_t> field_rise;
    std::vector<int64_t> normal_sync_rise;
};

static void init(Vspg_sd* d, bool pal, bool interlace, bool native) {
    d->clk = d->avl_clk = 0;
    d->reset = 1;
    d->fb_base1 = 0; d->fb_base2 = 0x100000;
    d->fb_stride = 1280; d->fb_pix_dbl = 0; d->fb_split = 1;
    d->fb_disp_half1 = 0; d->fb_disp_half2 = 1;
    d->fb_depth = 1; d->fb_concat = 0; d->fb_enable = 1;
    d->mode_pal = pal; d->mode_interlace = interlace;
    d->mode_native_interlace = native;
    d->avl_waitrequest = 1;
    for (int i = 0; i < 4; ++i) d->avl_readdata[i] = 0;
    d->avl_readdatavalid = 0;
}

static void tick(Vspg_sd* d) {
    d->clk = 0; d->avl_clk = 0; d->eval();
    d->clk = 1; d->avl_clk = 1; d->eval();
}

// Distinct adjacent RGB565 pixels expose stale/swapped byte and word lanes.
static uint16_t grid_pixel(unsigned x) {
    const uint16_t r = x & 31;
    const uint16_t g = (x >> 1) & 63;
    const uint16_t b = (x >> 3) & 31;
    return (r << 11) | (g << 5) | b;
}

static void drive_split_565_beat(Vspg_sd* d, uint32_t address) {
    const unsigned beat = address % 160;
    const unsigned x = beat * 4;
    const uint32_t w0 = uint32_t(grid_pixel(x + 0)) |
                        (uint32_t(grid_pixel(x + 1)) << 16);
    const uint32_t w1 = uint32_t(grid_pixel(x + 2)) |
                        (uint32_t(grid_pixel(x + 3)) << 16);
    // Dreamcast's split view stores consecutive 32-bit FB words in the
    // selected half of successive 64-bit lanes: low = words 0/2, high = 1/3.
    d->avl_readdata[0] = w0;
    d->avl_readdata[1] = w0;
    d->avl_readdata[2] = w1;
    d->avl_readdata[3] = w1;
}

static void expected_565(unsigned x, uint8_t& r, uint8_t& g, uint8_t& b) {
    const uint16_t p = grid_pixel(x);
    r = uint8_t((p >> 11) << 3);
    g = uint8_t(((p >> 5) & 63) << 2);
    b = uint8_t((p & 31) << 3);
}

static int run_mode(const char* name, bool pal, bool interlace, bool native) {
    Vspg_sd* d = new Vspg_sd;
    init(d, pal, interlace, native);
    for (int i = 0; i < 8; ++i) tick(d);
    d->reset = 0;

    const int half = pal ? 864 : 858;
    const int halves = pal ? 625 : 525;
    const int64_t field_period = (int64_t)half * halves;
    const int64_t frame_period = interlace ? field_period * 2 : field_period;
    const int de_lines = pal ? 288 : 240;
    const int sync_w = pal ? 128 : 126;
    // RTL reset defaults to NTSC interlace.  Allow that initial frame to
    // finish, then allow the intentionally blank first field of a new mode.
    const int64_t warm = 2 * (int64_t)858 * 525 + field_period;
    const int64_t run = warm + field_period * 3;

    int errors = 0, prev_vs = 0, prev_hs = 0;
    int64_t pulse_start = -1;
    int64_t de_count = 0, image_count = 0;
    bool have_line_sample = false;
    bool source_discontinuity = false;
    uint16_t line_source = 0;
    std::vector<int64_t> vs_rise, sync_rise, sync_fall;
    std::vector<int64_t> ordinary_phase;
    std::vector<int> fields;

    for (int64_t t = 0; t < run; ++t) {
        tick(d);
        if (d->vsync && !prev_vs && t >= warm) {
            vs_rise.push_back(t); fields.push_back(d->field);
        }
        if (d->hsync && !prev_hs) {
            sync_rise.push_back(t);
            pulse_start = t;
            have_line_sample = false;
        }
        if (!d->hsync && prev_hs) {
            sync_fall.push_back(t);
            if (pulse_start >= warm && t - pulse_start == sync_w)
                ordinary_phase.push_back(pulse_start % (2 * half));
        }
        if (t >= warm && t < warm + field_period) {
            if (d->de) de_count++;
            if (d->de && !d->border) image_count++;
            if (d->de && !d->border) {
                if (!have_line_sample) {
                    line_source = d->src_line;
                    have_line_sample = true;
                } else if (d->src_line != line_source) {
                    source_discontinuity = true;
                }
            }
        }
        prev_vs = d->vsync; prev_hs = d->hsync;
    }

    for (size_t i = 1; i < vs_rise.size(); ++i)
        if (vs_rise[i] - vs_rise[i-1] != field_period) {
            std::printf("%s: bad field period %lld\n", name,
                        (long long)(vs_rise[i] - vs_rise[i-1])); errors++;
        }
    if (interlace) {
        for (size_t i = 1; i < fields.size(); ++i)
            if (fields[i] == fields[i-1]) {
                std::printf("%s: field did not alternate\n", name); errors++;
            }
    } else {
        for (size_t i = 1; i < fields.size(); ++i)
            if (fields[i] != 0) { std::printf("%s: progressive field=1\n", name); errors++; }
    }

    const int64_t expect_de = (int64_t)de_lines * 1440;
    const int64_t expect_img = (int64_t)240 * 1280;
    if (de_count != expect_de) {
        std::printf("%s: DE %lld expected %lld\n", name,
                    (long long)de_count, (long long)expect_de); errors++;
    }
    if (image_count != expect_img) {
        std::printf("%s: image %lld expected %lld\n", name,
                    (long long)image_count, (long long)expect_img); errors++;
    }
    if (source_discontinuity) {
        std::printf("%s: source line changed within a physical scanline\n", name);
        errors++;
    }

    // Find ordinary line-sync pulses after the 18-half-line vertical interval.
    int ordinary = 0;
    for (size_t i = 1; i < sync_fall.size() && i < sync_rise.size(); ++i) {
        int64_t width = sync_fall[i] - sync_rise[i];
        if (width == sync_w) ordinary++;
    }
    if (ordinary < 100) { std::printf("%s: too few ordinary syncs\n", name); errors++; }
    if (vs_rise.size() < 2) { std::printf("%s: too few fields\n", name); errors++; }
    if (interlace && !ordinary_phase.empty()) {
        const int64_t phase = ordinary_phase.front();
        for (int64_t p : ordinary_phase) {
            if (p != phase) {
                std::printf("%s: ordinary H sync changed half-line phase (%lld -> %lld)\n",
                            name, (long long)phase, (long long)p);
                errors++;
                break;
            }
        }
    }

    std::printf("%-5s field=%lld de=%lld image=%lld %s\n", name,
                (long long)field_period, (long long)de_count,
                (long long)image_count, errors ? "FAIL" : "PASS");
    delete d;
    return errors;
}

// SOF/base writes are asynchronous to the video clock.  They may become
// stable at any point in a field, but must not alter line fetches until the
// next complete frame boundary.
static int run_fb_boundary() {
    Vspg_sd* d = new Vspg_sd;
    init(d, false, false, false);
    d->avl_waitrequest = 0;
    d->avl_readdatavalid = 1;
    for (int i = 0; i < 8; ++i) tick(d);
    d->reset = 0;

    const int half = 858;
    const int64_t field_period = (int64_t)half * 525;
    const int64_t warm = 2 * field_period + field_period;
    for (int64_t t = 0; t < warm; ++t) tick(d);

    // Move well into the field before changing SOF1 by 16 MiB.  Avalon
    // addresses count 16-byte beats, so the new base is 0x100000.
    for (int i = 0; i < half * 100; ++i) tick(d);
    d->fb_base1 = 0x01000000;

    int errors = 0;
    bool prev_vs = d->vsync;
    bool next_frame = false;
    bool saw_old_fetch = false;
    bool saw_new_fetch = false;
    const uint32_t new_base = 0x00100000;

    for (int64_t t = 0; t < field_period * 2; ++t) {
        tick(d);
        if (d->vsync && !prev_vs) next_frame = true;
        if (d->avl_read) {
            if (!next_frame) {
                saw_old_fetch = true;
                if (d->avl_address >= new_base) {
                    std::printf("fb-boundary: new base used before frame boundary\n");
                    errors++;
                    break;
                }
            } else if (d->avl_address >= new_base) {
                saw_new_fetch = true;
                break;
            }
        }
        prev_vs = d->vsync;
    }
    if (!saw_old_fetch) {
        std::printf("fb-boundary: no pre-boundary fetch observed\n"); errors++;
    }
    if (!saw_new_fetch) {
        std::printf("fb-boundary: new base not used after frame boundary\n"); errors++;
    }

    std::printf("fb-boundary %s\n", errors ? "FAIL" : "PASS");
    delete d;
    return errors;
}

// Feed deterministic RGB565 rows through the Avalon reader and compare every
// active output clock. Each source pixel is repeated twice by the 27 MHz SD
// scanout. Deterministic request stalls and response gaps model DDR latency;
// the comparison catches errors at byte, bank, beat and line-buffer borders.
static int run_pixel_grid() {
    Vspg_sd* d = new Vspg_sd;
    init(d, false, true, false);
    d->fb_base1 = 0;
    d->fb_base2 = 0;
    d->avl_waitrequest = 0;
    d->avl_readdatavalid = 0;
    for (int i = 0; i < 8; ++i) tick(d);
    d->reset = 0;

    const int64_t field_period = int64_t(858) * 525;
    const int64_t warm = 2 * field_period;
    uint32_t response_address = 0;
    unsigned response_left = 0;
    bool previous_image = false;
    unsigned output_x = 0;
    unsigned lines = 0;
    int errors = 0;

    for (int64_t t = 0; t < warm + field_period; ++t) {
        // Exercise held read requests and gapped return data while remaining
        // comfortably inside the one-line prefetch budget.
        d->avl_waitrequest = ((t % 11) == 3);
        const bool return_beat = response_left != 0 && ((t % 3) != 0);
        d->avl_readdatavalid = return_beat;
        if (return_beat) drive_split_565_beat(d, response_address);

        tick(d);

        if (return_beat) {
            response_address++;
            response_left--;
        }
        if (d->avl_read && !d->avl_waitrequest) {
            if (response_left != 0) {
                std::printf("pixel-grid: overlapping Avalon burst\n");
                errors++;
            }
            response_address = d->avl_address;
            response_left = d->avl_burstcount;
        }

        const bool image = d->de && !d->border;
        if (t >= warm && image) {
            if (!previous_image) output_x = 0;
            uint8_t er, eg, eb;
            expected_565(output_x >> 1, er, eg, eb);
            if (d->red != er || d->green != eg || d->blue != eb) {
                if (errors < 12) {
                    std::printf("pixel-grid: x=%u got=%02x/%02x/%02x expected=%02x/%02x/%02x\n",
                                output_x, d->red, d->green, d->blue, er, eg, eb);
                }
                errors++;
            }
            output_x++;
        } else if (t >= warm && previous_image) {
            if (output_x != 1280) {
                std::printf("pixel-grid: active width %u expected 1280\n", output_x);
                errors++;
            }
            lines++;
        }
        previous_image = image;
    }

    if (lines < 200) {
        std::printf("pixel-grid: only %u active lines checked\n", lines);
        errors++;
    }
    std::printf("pixel-grid lines=%u %s\n", lines, errors ? "FAIL" : "PASS");
    delete d;
    return errors;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    int errors = 0;
    errors += run_mode("480i", false, true, true);
    errors += run_mode("240p", false, false, false);
    errors += run_mode("576i", true, true, true);
    errors += run_mode("288p", true, false, false);
    errors += run_fb_boundary();
    errors += run_pixel_grid();
    std::printf(errors ? "FAIL (%d errors)\n" : "PASS\n", errors);
    return errors != 0;
}
