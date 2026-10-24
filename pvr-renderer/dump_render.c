/* pvr-renderer - replay the polly2-data PVR dumps on a real Dreamcast.
 *
 * For every scene found in the dump directory (a vram_<scene>.bin /
 * pvr_regs_<scene>.bin pair, captured by minicast's do_vram_dump()):
 *
 *   1. stream vram_<scene>.bin into VRAM,
 *   2. program the captured PVR register file,
 *   3. fire STARTRENDER and time the render on silicon,
 *   4. read all of VRAM back out to vram_out_<scene>.bin,
 *   5. append one line to rendertimes.txt.
 *
 * Everything is read from / written to the HOST over dcload (/pc/...), so the
 * results land straight in polly2-data/dumps next to the inputs. This is the
 * hardware counterpart of driver/polly2_dumpload.c (which does the same thing
 * on the DE10-Nano) and of the verilator harness - same inputs, same render,
 * so the three outputs are directly comparable.
 *
 * Dump format (minicast do_vram_dump / pvr_RegSize):
 *   vram_<scene>.bin     8 MB, the 32-bit VIEW of VRAM: word q is the word at
 *                        the 32-bit access area offset q*4. On the Dreamcast
 *                        that view IS the 32-bit access area at 0xa5000000, so
 *                        the file loads linearly with no unswizzling.
 *   pvr_regs_<scene>.bin the 8 KB PVR register file (byte offset == MMIO reg
 *                        offset from 0xa05f8000), zero padded to 32 KB.
 */

#include <kos.h>
#include <dc/asic.h>
#include <dc/sq.h>
#include <arch/timer.h>
#include <kos/fs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Host directory holding the dumps; override with make DATA_DIR=... */
#ifndef DATA_DIR
#define DATA_DIR "/pc/home/skmp/projects/dreamster/polly2-rtl/polly2-data/dumps"
#endif

/* Renders per scene. The render is idempotent (it only reads the display list
 * and fully rewrites the framebuffer), so repeating it just gives a cleaner
 * timing sample; the VRAM that gets dumped is the last pass's. */
#ifndef RENDER_PASSES
#define RENDER_PASSES 1
#endif

/* Write the scan-out / sync-generator registers too. Off by default: they are
 * not used by the render, and programming a captured game's video mode would
 * yank the console's display out from under KOS for no gain. */
/* Pause between the two register upload passes, and after the second. */
#ifndef REG_SETTLE_MS
#define REG_SETTLE_MS 2
#endif

/* Only render scenes whose name contains one of these comma separated
 * substrings; empty = all of them. dc-tool cannot pass argv to the program, so
 * this is a build-time knob (make SCENE=jgr,daytona). */
#ifndef SCENE_FILTER
#define SCENE_FILTER ""
#endif

/* Never render scenes matching one of these comma separated substrings
 * (make SKIP=mipmap,mvsc2). Some dumps wedge the core for good. */
#ifndef SCENE_SKIP
#define SCENE_SKIP ""
#endif

#define VRAM32_BASE   0xa5000000u   /* VRAM, 32-bit access area, P2 (uncached) */
#define VRAM_SIZE     0x00800000u   /* 8 MB */
#define PVR_REGS_BASE 0xa05f8000u
#define REGS_BYTES    0x00002000u   /* 8 KB register file, as dumped */

#define PVR_REG(off)  (*(volatile uint32_t *)(PVR_REGS_BASE + (off)))
#define STARTRENDER   0x014
#define SOFTRESET     0x008

#define ASIC_ISTNRM   (*(volatile uint32_t *)0xa05f6900)
#define ISTNRM_RENDER_DONE 0x7u     /* video | isp | tsp */

#define CHUNK_SZ      (512 * 1024)
#define MAX_SCENES    256
#define MAX_NAME      64

/* Give up on a render after this long, and stop waiting for the remaining
 * stages this long after the first one reported in. */
#define RENDER_TIMEOUT_NS  5000000000ull
#define RENDER_GRACE_NS     500000000ull

static uint8_t  chunk[CHUNK_SZ] __attribute__((aligned(32)));
static uint32_t regs[REGS_BYTES / 4];
static char     scenes[MAX_SCENES][MAX_NAME];
static int      nscenes;

/* ------------------------------------------------------------------ render */

static volatile uint32_t done_mask;       /* bit 0 video, 1 isp, 2 tsp */
static volatile uint64_t done_ns[3];
static volatile uint64_t done_last_ns;

static void render_done_cb(uint32_t code, void *data) {
    uint64_t now = timer_ns_gettime64();
    unsigned idx = (unsigned)(uintptr_t)data;

    (void)code;
    if(!(done_mask & (1u << idx))) {
        done_ns[idx] = now;
        done_mask |= 1u << idx;
    }
    done_last_ns = now;
}

static void render_irq_setup(void) {
    asic_evt_set_handler(ASIC_EVT_PVR_RENDERDONE_VIDEO, render_done_cb, (void *)0);
    asic_evt_set_handler(ASIC_EVT_PVR_RENDERDONE_ISP,   render_done_cb, (void *)1);
    asic_evt_set_handler(ASIC_EVT_PVR_RENDERDONE_TSP,   render_done_cb, (void *)2);
    asic_evt_enable(ASIC_EVT_PVR_RENDERDONE_VIDEO, ASIC_IRQ_DEFAULT);
    asic_evt_enable(ASIC_EVT_PVR_RENDERDONE_ISP,   ASIC_IRQ_DEFAULT);
    asic_evt_enable(ASIC_EVT_PVR_RENDERDONE_TSP,   ASIC_IRQ_DEFAULT);
}

static void render_irq_teardown(void) {
    asic_evt_disable(ASIC_EVT_PVR_RENDERDONE_VIDEO, ASIC_IRQ_DEFAULT);
    asic_evt_disable(ASIC_EVT_PVR_RENDERDONE_ISP,   ASIC_IRQ_DEFAULT);
    asic_evt_disable(ASIC_EVT_PVR_RENDERDONE_TSP,   ASIC_IRQ_DEFAULT);
    asic_evt_remove_handler(ASIC_EVT_PVR_RENDERDONE_VIDEO);
    asic_evt_remove_handler(ASIC_EVT_PVR_RENDERDONE_ISP);
    asic_evt_remove_handler(ASIC_EVT_PVR_RENDERDONE_TSP);
}

/* TA + pipeline soft reset (NOT bit 2, the SDRAM interface). Registers keep
 * their values; this just drops any state machine left running by the previous
 * scene. Some dumps wedge the core (unterminated OPBs and friends) or finish
 * without reporting every stage, and without this the NEXT scene inherits the
 * mess and hangs. */
/* The registers we deliberately never replay from a dump: the VRAM controller
 * and the console's own scan-out/sync setup. Nothing rewrites these during a
 * run, so if SOFTRESET does clear the register file they would stay lost -
 * and a zeroed SDRAM_REFRESH means VRAM stops being refreshed. We snapshot
 * them at startup and put them back after every reset; if the reset leaves
 * registers alone this is just a no-op rewrite of identical values. */
static const uint16_t keep_regs[] = {
    0x0a0, 0x0a4, 0x0a8,                    /* SDRAM_REFRESH/ARB_CFG/CFG */
    0x040, 0x044, 0x050, 0x054, 0x05c,      /* VO_BORDER_COL, FB_R_* */
    0x0c4, 0x0c8, 0x0cc, 0x0d0, 0x0d4,      /* SPG_TRIGGER_POS .. */
    0x0d8, 0x0dc, 0x0e0,                    /* .. SPG_WIDTH */
    0x0e8, 0x0ec, 0x0f0,                    /* VO_CONTROL, VO_STARTX/Y */
    0x110,                                  /* FB_BURSTCTRL */
};
#define N_KEEP (sizeof keep_regs / sizeof keep_regs[0])

static uint32_t keep_vals[N_KEEP];
static int keep_checked;

static void snapshot_keep_regs(void) {
    unsigned k;

    for(k = 0; k < N_KEEP; k++)
        keep_vals[k] = PVR_REG(keep_regs[k]);
}

static void core_reset(void) {
    unsigned k;

    PVR_REG(SOFTRESET) = 0x3;
    timer_spin_sleep(4);
    PVR_REG(SOFTRESET) = 0;
    timer_spin_sleep(4);

    /* One-off: does SOFTRESET actually clear the register file? Report it the
     * first time so the answer comes out of a real run rather than a guess. */
    if(!keep_checked) {
        int changed = 0;

        for(k = 0; k < N_KEEP; k++) {
            uint32_t now = PVR_REG(keep_regs[k]);

            if(now != keep_vals[k]) {
                printf("\n  SOFTRESET cleared reg %03x: %08x -> %08x",
                       keep_regs[k], (unsigned)keep_vals[k], (unsigned)now);
                changed++;
            }
        }
        printf("\n  SOFTRESET: %d of %u kept registers changed\n",
               changed, (unsigned)N_KEEP);
        keep_checked = 1;
    }

    for(k = 0; k < N_KEEP; k++)
        PVR_REG(keep_regs[k]) = keep_vals[k];

    ASIC_ISTNRM = ISTNRM_RENDER_DONE;
    done_mask = 0;
}

/* Put the PVR and VRAM back somewhere KOS (and dcload after us) can live: a
 * quiet core, zeroed VRAM and a known video mode. Without this the console is
 * left staring at a game's register state over 8 MB of foreign VRAM. */
static void restore_console(void) {
    uint32_t off;
    unsigned k;

    core_reset();
    for(k = 0; k < N_KEEP; k++)
        PVR_REG(keep_regs[k]) = keep_vals[k];
    for(off = 0; off < VRAM_SIZE; off += 4)
        *(volatile uint32_t *)(VRAM32_BASE + off) = 0;
    vid_set_mode(DM_640x480, PM_RGB565);
}

/* Program the captured register file. Everything in the dump goes in except
 * SOFTRESET and STARTRENDER: SOFTRESET is not state, and STARTRENDER is the
 * trigger we fire ourselves once the registers have settled.
 *
 * Note this includes the scan-out and sync generator, so the console's video
 * mode becomes the captured game's for the rest of the run, and it includes
 * TA_LIST_CONT, which four of the thps2 dumps have armed at 0x80000000. */
static void upload_regs(void) {
    uint32_t off;

    for(off = 0; off < REGS_BYTES; off += 4) {
        if(off == SOFTRESET || off == STARTRENDER)
            continue;
        PVR_REG(off) = regs[off / 4];
    }
}

/* Two passes with a settle in between: the first write brings the whole file
 * up from whatever the soft reset left behind, the pause lets it take, and the
 * second pass puts back anything the first one's own side effects disturbed. */
static void upload_regs_settled(void) {
    upload_regs();
    timer_spin_sleep(REG_SETTLE_MS);
    upload_regs();
    timer_spin_sleep(REG_SETTLE_MS);
}

/* Fire one render and return the time from STARTRENDER to the last stage-done
 * interrupt, in ns. Returns 0 on timeout. */
static uint64_t render_once(uint64_t stage_ns[3], uint32_t *stages) {
    uint64_t t0, now, deadline, last = 0;
    uint32_t mask;
    int i;

    done_mask = 0;
    done_last_ns = 0;
    for(i = 0; i < 3; i++)
        done_ns[i] = 0;

    ASIC_ISTNRM = ISTNRM_RENDER_DONE;   /* drop anything stale */

    t0 = timer_ns_gettime64();
    PVR_REG(STARTRENDER) = 1;
    deadline = t0 + RENDER_TIMEOUT_NS;

    for(;;) {
        mask = done_mask;
        if((mask & 7) == 7)
            break;
        now = timer_ns_gettime64();
        /* some stages reported and the rest have gone quiet - take what we got */
        if(mask && now > done_last_ns + RENDER_GRACE_NS)
            break;
        if(now > deadline) {
            *stages = done_mask;
            return 0;   /* wedged; the caller resets the core */
        }
    }

    *stages = done_mask;
    for(i = 0; i < 3; i++) {
        stage_ns[i] = done_ns[i] ? done_ns[i] - t0 : 0;
        if(done_ns[i] > last)
            last = done_ns[i];
    }
    return last - t0;
}

/* --------------------------------------------------------------------- I/O */

static int read_exact(file_t fd, void *buf, size_t n) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;

    while(got < n) {
        ssize_t r = fs_read(fd, p + got, n - got);
        if(r <= 0)
            break;
        got += (size_t)r;
    }
    return (int)got;
}

static int write_exact(file_t fd, const void *buf, size_t n) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t put = 0;

    while(put < n) {
        ssize_t w = fs_write(fd, p + put, n - put);
        if(w <= 0)
            return 0;
        put += (size_t)w;
    }
    return 1;
}

static int load_vram(const char *scene) {
    char path[320];
    file_t fd;
    uint32_t off;

    snprintf(path, sizeof path, DATA_DIR "/vram_%s.bin", scene);
    fd = fs_open(path, O_RDONLY);
    if(fd < 0) {
        printf("  ! cannot open %s\n", path);
        return 0;
    }

    for(off = 0; off < VRAM_SIZE; off += CHUNK_SZ) {
        int got = read_exact(fd, chunk, CHUNK_SZ);
        if(got <= 0) {
            printf("  ! short vram dump at %u/%u bytes\n",
                   (unsigned)off, (unsigned)VRAM_SIZE);
            fs_close(fd);
            return 0;
        }
        if((size_t)got < CHUNK_SZ)
            memset(chunk + got, 0, CHUNK_SZ - got);
        sq_cpy((void *)(VRAM32_BASE + off), chunk, CHUNK_SZ);
    }

    fs_close(fd);
    return 1;
}

static int load_regs(const char *scene) {
    char path[320];
    file_t fd;
    int got;

    snprintf(path, sizeof path, DATA_DIR "/pvr_regs_%s.bin", scene);
    fd = fs_open(path, O_RDONLY);
    if(fd < 0) {
        printf("  ! cannot open %s\n", path);
        return 0;
    }
    memset(regs, 0, sizeof regs);
    got = read_exact(fd, regs, sizeof regs);
    fs_close(fd);

    /* The dumps come in three flavours: 8 KB exactly, 8 KB zero-padded to
     * 32 KB, and (pvr_regs_menu) a 4 KB truncation that stops before
     * PALETTE_RAM. Anything that holds the register file proper is usable. */
    if(got < 0x400) {
        printf("  ! reg dump too short (%d bytes) ", got);
        return 0;
    }
    if((size_t)got < sizeof regs)
        printf("[short regs: %d B] ", got);
    if(regs[0x160 / 4])
        printf("[TA_LIST_CONT armed: %08x] ", (unsigned)regs[0x160 / 4]);
    if(regs[0x144 / 4])
        printf("[TA_LIST_INIT armed: %08x] ", (unsigned)regs[0x144 / 4]);
    return 1;
}

static int store_vram(const char *scene) {
    char path[320];
    file_t fd;
    uint32_t off;

    snprintf(path, sizeof path, DATA_DIR "/vram_out_%s.bin", scene);
    fd = fs_open(path, O_WRONLY | O_CREAT | O_TRUNC);
    if(fd < 0) {
        printf("  ! cannot create %s\n", path);
        return 0;
    }

    for(off = 0; off < VRAM_SIZE; off += CHUNK_SZ) {
        const volatile uint32_t *src = (const volatile uint32_t *)(VRAM32_BASE + off);
        uint32_t *dst = (uint32_t *)chunk;
        uint32_t i;

        for(i = 0; i < CHUNK_SZ / 4; i++)
            dst[i] = src[i];

        if(!write_exact(fd, chunk, CHUNK_SZ)) {
            printf("  ! write failed at %u\n", (unsigned)off);
            fs_close(fd);
            return 0;
        }
    }

    fs_close(fd);
    return 1;
}

/* ------------------------------------------------------------ scene lookup */

/* true if name contains any of the comma separated substrings in filter */
static int scene_matches(const char *name, const char *filter) {
    const char *p = filter;

    while(*p) {
        char pat[MAX_NAME];
        size_t n = 0;

        while(*p == ',' || *p == ' ')
            p++;
        while(p[n] && p[n] != ',' && p[n] != ' ' && n < sizeof pat - 1)
            n++;
        if(!n)
            break;
        memcpy(pat, p, n);
        pat[n] = '\0';
        p += n;
        if(strstr(name, pat))
            return 1;
    }
    return 0;
}

static int scene_cmp(const void *a, const void *b) {
    return strcmp((const char *)a, (const char *)b);
}

/* Every vram_<scene>.bin in DATA_DIR, minus the vram_out_* we write. */
static int list_scenes(const char *filter) {
    file_t d;
    const dirent_t *de;

    d = fs_open(DATA_DIR, O_RDONLY | O_DIR);
    if(d < 0) {
        printf("cannot open %s - is dc-tool running with host fs access?\n", DATA_DIR);
        return 0;
    }

    while((de = fs_readdir(d)) != NULL) {
        size_t len = strlen(de->name);
        size_t nlen;

        if(strncmp(de->name, "vram_", 5) != 0)
            continue;
        if(strncmp(de->name + 5, "out_", 4) == 0)
            continue;
        if(len < 10 || strcmp(de->name + len - 4, ".bin") != 0)
            continue;

        nlen = len - 5 - 4;
        if(nlen >= MAX_NAME)
            continue;
        if(nscenes >= MAX_SCENES)
            break;

        memcpy(scenes[nscenes], de->name + 5, nlen);
        scenes[nscenes][nlen] = '\0';

        if(filter && !scene_matches(scenes[nscenes], filter))
            continue;
        if(SCENE_SKIP[0] && scene_matches(scenes[nscenes], SCENE_SKIP)) {
            printf("skipping %s (SKIP list)\n", scenes[nscenes]);
            continue;
        }

        nscenes++;
    }

    fs_close(d);
    qsort(scenes, nscenes, MAX_NAME, scene_cmp);
    return nscenes;
}

/* -------------------------------------------------------------------- main */

static void print_ns(const char *label, uint64_t ns) {
    printf("%s%u.%03u ms", label, (unsigned)(ns / 1000000u),
           (unsigned)((ns / 1000u) % 1000u));
}

int main(int argc, char **argv) {
    const char *filter = (argc > 1 && argv[1][0]) ? argv[1] :
                         (SCENE_FILTER[0] ? SCENE_FILTER : NULL);
    file_t times;
    char line[256];
    uint64_t grand_total = 0;
    int i, ok = 0, failed = 0;

    printf("\n=== pvr-renderer: polly2 dump replay on real hardware ===\n");
    printf("data dir : %s\n", DATA_DIR);
    printf("passes   : %d per scene\n", RENDER_PASSES);
    if(filter)
        printf("filter   : *%s*\n", filter);

    if(!list_scenes(filter)) {
        printf("no scenes found\n");
        return 1;
    }
    printf("scenes   : %d\n\n", nscenes);

    times = fs_open(DATA_DIR "/rendertimes.txt", O_WRONLY | O_CREAT | O_TRUNC);
    if(times < 0) {
        printf("cannot create " DATA_DIR "/rendertimes.txt\n");
        return 1;
    }
    snprintf(line, sizeof line,
             "# polly2 render times, measured on real Dreamcast hardware\n"
             "# STARTRENDER -> last end-of-render interrupt, %d pass(es) per scene\n"
             "# scene render_us isp_us tsp_us video_us status\n"
             "# a partial_* status means that end-of-render stage never reported\n",
             RENDER_PASSES);
    write_exact(times, line, strlen(line));

    /* the console's own PVR setup, before we touch anything */
    snapshot_keep_regs();
    render_irq_setup();

    for(i = 0; i < nscenes; i++) {
        const char *scene = scenes[i];
        uint64_t stage[3] = { 0, 0, 0 }, best = 0;
        uint32_t stages = 0, best_stages = 0;
        int pass, timed_out = 0;

        printf("[%3d/%3d] %-24s ", i + 1, nscenes, scene);
        fflush(stdout);

        /* Quiesce the core FIRST: a render left running by the previous scene
         * keeps hitting VRAM, and fighting it for the bus over an 8 MB upload
         * is how you wedge the machine. */
        core_reset();

        if(!load_regs(scene) || !load_vram(scene)) {
            snprintf(line, sizeof line, "%s 0 0 0 0 load_failed\n", scene);
            write_exact(times, line, strlen(line));
            failed++;
            continue;
        }

        upload_regs_settled();

        for(pass = 0; pass < RENDER_PASSES; pass++) {
            uint64_t s[3], t = render_once(s, &stages);

            if(!t) {
                timed_out = 1;
                break;
            }
            if(!best || t < best) {
                best = t;
                best_stages = stages;
                stage[0] = s[0];
                stage[1] = s[1];
                stage[2] = s[2];
            }
        }

        /* Always quiesce before the 8 MB readback. A render that is still
         * touching VRAM - including one that reported every stage but did not
         * really stop - starves the SH4's reads and hangs the console. */
        core_reset();

        if(timed_out) {
            printf("TIMEOUT\n");
            snprintf(line, sizeof line, "%s 0 0 0 0 timeout\n", scene);
            write_exact(times, line, strlen(line));
            failed++;
            continue;
        }

        grand_total += best;
        print_ns("render ", best);

        snprintf(line, sizeof line, "%s %u.%03u %u.%03u %u.%03u %u.%03u %s\n", scene,
                 (unsigned)(best / 1000u),     (unsigned)(best % 1000u),
                 (unsigned)(stage[1] / 1000u), (unsigned)(stage[1] % 1000u),
                 (unsigned)(stage[2] / 1000u), (unsigned)(stage[2] % 1000u),
                 (unsigned)(stage[0] / 1000u), (unsigned)(stage[0] % 1000u),
                 (best_stages & 7) == 7 ? "ok" :
                 (best_stages & 7) == 3 ? "partial_no_tsp" :
                 (best_stages & 7) == 6 ? "partial_no_video" :
                 (best_stages & 7) == 5 ? "partial_no_isp" : "partial");
        write_exact(times, line, strlen(line));

        if(store_vram(scene)) {
            printf(" -> vram_out_%s.bin\n", scene);
            ok++;
        }
        else {
            printf(" (readback FAILED)\n");
            failed++;
        }
    }

    render_irq_teardown();
    restore_console();

    snprintf(line, sizeof line, "# total %u.%03u us over %d scenes (%d failed)\n",
             (unsigned)(grand_total / 1000u), (unsigned)(grand_total % 1000u),
             ok, failed);
    write_exact(times, line, strlen(line));
    fs_close(times);

    printf("\n%d scenes rendered, %d failed\n", ok, failed);
    print_ns("total render time: ", grand_total);
    printf("\nresults in " DATA_DIR "/rendertimes.txt\nDONE\n");
    return 0;
}
