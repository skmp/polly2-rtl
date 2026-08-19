// polly2_dumpload - DE10-Nano (HPS) standalone dump replayer.
//
// Loads a captured PVR dump (vram.bin + pvr_regs.bin) straight into the FPGA and
// triggers ONE polly2 render on real hardware - NO emulator (minicast) needed. This
// is the render-vs-upload isolator: feed the exact VRAM+regs snapshot the Verilator
// sim uses, render it on silicon, and compare. If a symptom (e.g. the VQ-1555 black
// transparency / "black leaves") reproduces from the static dump, it is in the
// RENDER RTL; if it does not, it is in the live texture/TA upload path.
//
// The rendered frame lands in the FPGA's scanout framebuffer, so the result shows on
// the HDMI output (same as a normal minicast frame). Run it repeatedly to A/B.
//
// Dump format = exactly what minicast's do_vram_dump() writes:
//   vram.bin     : the 8 MB 32-bit VIEW, i.e. word q holds vram_phys[pvr_map32(q*4)].
//                  We invert that here: view word q -> physical byte pvr_map32(q*4).
//   pvr_regs.bin : the 8 KB PVR register file (byte offset == the MMIO reg offset).
//
// Build (cross for the DE10-Nano Cortex-A9, hard-float):
//   arm-linux-gnueabihf-gcc -O2 -o polly2_dumpload polly2_dumpload.c
// Run (as root, needs /dev/mem):
//   ./polly2_dumpload <dumpdir>        # dumpdir/vram.bin + dumpdir/pvr_regs.bin
//   ./polly2_dumpload <vram.bin> <pvr_regs.bin>
//
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>
#include "polly2_mmio.h"

#define VRAM_PHYS      0x32000000u   // FPGA-shared DDR3 VRAM window (matches polly2 power-up base)
#define VRAM_BYTES     0x00800000u   // 8 MB
#define VRAM_BANK_BIT  0x00400000u   // 4 MB banks, interleaved every 32 bits (pvr_map32)
#define REGS_BYTES     0x00002000u   // 8 KB PVR register file

// minicast pvr_map32: 32-bit VIEW byte offset -> physical byte offset. 64-bit bus is
// achieved by interleaving the two 4 MB banks every 32 bits.
static inline uint32_t pvr_map32(uint32_t off32) {
    const uint32_t static_bits = 0x3u;          // (VRAM_MASK - (2*BANK-1)) | 3  == 3 for 8 MB
    const uint32_t offset_bits = (VRAM_BANK_BIT - 1u) & ~3u;   // 0x3FFFFC
    uint32_t bank = (off32 & VRAM_BANK_BIT) ? 1u : 0u;
    uint32_t rv = off32 & static_bits;
    rv |= (off32 & offset_bits) << 1;
    rv |= bank << 2;
    return rv;
}

static uint8_t *load_file(const char *path, size_t want, size_t *got) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return NULL; }
    uint8_t *buf = (uint8_t *)calloc(1, want);
    size_t n = fread(buf, 1, want, f);
    fclose(f);
    if (got) *got = n;
    return buf;
}

int main(int argc, char **argv) {
    char vram_path[512], regs_path[512];
    if (argc == 2) {
        snprintf(vram_path, sizeof vram_path, "%s/vram.bin", argv[1]);
        snprintf(regs_path, sizeof regs_path, "%s/pvr_regs.bin", argv[1]);
    } else if (argc == 3) {
        snprintf(vram_path, sizeof vram_path, "%s", argv[1]);
        snprintf(regs_path, sizeof regs_path, "%s", argv[2]);
    } else {
        fprintf(stderr, "usage: %s <dumpdir> | <vram.bin> <pvr_regs.bin>\n", argv[0]);
        return 2;
    }

    size_t vsz = 0, rsz = 0;
    uint8_t *view = load_file(vram_path, VRAM_BYTES, &vsz);
    uint8_t *regs = load_file(regs_path, REGS_BYTES, &rsz);
    if (!view || !regs) return 1;
    printf("dump: vram=%s (%zu B)  regs=%s (%zu B)\n", vram_path, vsz, regs_path, rsz);

    // ---- mmap the FPGA VRAM DDR (write-combining preferred for the bulk copy) ----
    int fd = open("/dev/mem_wc", O_RDWR | O_SYNC);
    if (fd < 0) fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem(_wc)"); return 1; }
    volatile uint8_t *vram = (volatile uint8_t *)
        mmap(0, VRAM_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, VRAM_PHYS);
    close(fd);
    if (vram == MAP_FAILED) { perror("mmap vram"); return 1; }

    // ---- write the 32-bit VIEW into the physical interleaved layout (inverse dump) ----
    uint32_t nwords = (uint32_t)(vsz / 4);
    for (uint32_t q = 0; q < nwords; q++) {
        uint32_t w; memcpy(&w, view + q * 4u, 4);
        *(volatile uint32_t *)(vram + pvr_map32(q * 4u)) = w;
    }
    // ensure the write-combining VRAM stores drain to DDR before the FPGA reads them.
#if defined(__arm__) || defined(__aarch64__)
    __asm__ volatile("dsb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
    printf("VRAM loaded (%u words)\n", nwords);

    // ---- MMIO: reset, point at VRAM, upload regs, GO ----
    if (polly2_mmio_init() != 0) { fprintf(stderr, "polly2_mmio_init failed (root? bitstream loaded?)\n"); return 1; }
    printf("polly2 revision %u\n", polly2_revision());

    polly2_reset();
    polly2_set_vram_base(VRAM_PHYS);

    uint32_t nregs = (uint32_t)(rsz / 4);
    for (uint32_t i = 0; i < nregs; i++) {
        uint32_t v; memcpy(&v, regs + i * 4u, 4);
        polly2_reg_write(i * 4u, v);
    }
    printf("regs uploaded (%u words). REGION_BASE=%08x PARAM_BASE=%08x ISP_BACKGND_T=%08x\n",
           nregs,
           *(uint32_t *)(regs + 0x2C), *(uint32_t *)(regs + 0x20), *(uint32_t *)(regs + 0x8C));

    // ---- fire the render, wait for DONE (poll; IRQ optional) ----
    polly2_go();
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    unsigned spins = 0;
    while (!polly2_done()) {
        if (++spins > 200000000u) { fprintf(stderr, "TIMEOUT waiting for DONE\n"); return 1; }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double us = (t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) / 1e3;

    // PAGE FLIP: the render wrote to FB_W_SOF1, but the SPG scanout reads FB_R_SOF1.
    // The dump likely captured FB_R_SOF1 still on the PREVIOUS frame (the game flips
    // after render), so display it now by pointing the read pointer at what we rendered:
    //   FB_R_SOF1 <- FB_W_SOF1 ; FB_R_SOF2 <- FB_W_SOF2   (SOF2 = interlace field 2)
    // Offsets: FB_R_SOF1=0x050 FB_R_SOF2=0x054 FB_W_SOF1=0x060 FB_W_SOF2=0x064.
    uint32_t fb_w_sof1 = *(uint32_t *)(regs + 0x060);
    uint32_t fb_w_sof2 = *(uint32_t *)(regs + 0x064);
    polly2_reg_write(0x050, fb_w_sof1);
    polly2_reg_write(0x054, fb_w_sof2);

    printf("DONE in %u core cycles (~%.1f us wall). Flipped FB_R_SOF1<-%08x; frame is on HDMI.\n",
           polly2_frame_cycles(), us, fb_w_sof1);
    return 0;
}
