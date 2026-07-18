/*
 * polly2_mmio.h - minicast <-> polly2-rtl PVR over the HPS lightweight bridge.
 *
 * Counterpart of polly2-rtl/mister/rtl/polly2_mmio.sv (behind rtl/hps_lw_bridge.sv).
 * All accesses are 32-bit; the fabric ignores narrower writes.
 *
 *   0xFF200000-0xFF201FFF  PVR register file window (WRITE ONLY),
 *                          word address = offset[12:2]
 *   0xFF202000  VRAM_BASE  RW   [31:24] = top byte of 16MB-aligned VRAM base
 *   0xFF202004  STATUS     RO   [0] WORKING (0 = IDLE), [1] DONE (sticky)
 *   0xFF202008  GO         WO   any write starts the region-array parse
 *   0xFF20200C  RESET      WO   any write runs a stretched PVR reset cycle
 *   0xFF202010  CYCLES     RO   clk_sys cycles GO->DONE (resets on GO)
 *   0xFF202014  CLK        RW   [1:0] core clock: 0=75 1=90 2=100 3=112.5MHz
 *   0xFF202018  AUDIO_DATA W: push a stereo sample ([15:0] left, [31:16]
 *                          right, signed 16-bit PCM) into the 2048-entry
 *                          48 kHz HDMI audio FIFO. While the FIFO is full
 *                          the store BLOCKS THIS CPU until the I2S side
 *                          frees a slot (~21us per sample).
 *                          R: [11:0] samples currently queued (0..2048).
 *   0xFF20201C  REVISION   RO   MMIO interface revision. 0 = pre-audio
 *                          bitstream (slot was reserved, read 0), 1 = audio
 *                          (AUDIO_DATA + this register), 2 = border bands
 *                          (FB_TOP/FB_BOT), 3 = render-done interrupt on
 *                          f2h IRQ1 (GIC ID 73).
 *   0xFF202020  FB_TOP     RW   DDR byte address of a 640x30 RGB565 linear
 *                          framebuffer (stride 1280 bytes) shown 2x-doubled
 *                          as a 1280x60 band in the top border of the 1080p
 *                          raster. 128-byte aligned (low 7 bits forced 0);
 *                          0 = band off. Sampled once per frame at vblank
 *                          start.
 *   0xFF202024  FB_BOT     RW   same, bottom border
 *
 * REVISION >= 3 bitstreams also raise f2h IRQ1 (GIC ID 73) on render done.
 * The polly2 kernel module (driver/polly2) claims it and sends SIGUSR1 to
 * every process holding /dev/polly2 open - open the node, block SIGUSR1 in
 * a sigmask, kick GO and sigwait() instead of polling STATUS.
 *
 * Prerequisites (load_fpga_bitstream already does both): L3 remap = 0x19
 * (lwhps2fpga visible) and brg_mod_reset = 0 (bridge out of reset).
 */

#pragma once

#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define POLLY2_MMIO_BASE      0xFF200000u
#define POLLY2_MMIO_SPAN      0x00004000u

#define POLLY2_MMIO_VRAM_BASE 0x2000
#define POLLY2_MMIO_STATUS    0x2004
#define POLLY2_MMIO_GO        0x2008
#define POLLY2_MMIO_RESET     0x200C
#define POLLY2_MMIO_CYCLES    0x2010
#define POLLY2_MMIO_CLK       0x2014
#define POLLY2_MMIO_AUDIO_DATA 0x2018
#define POLLY2_MMIO_REVISION  0x201C
#define POLLY2_MMIO_FB_TOP    0x2020
#define POLLY2_MMIO_FB_BOT    0x2024

#define POLLY2_AUDIO_FIFO_DEPTH 2048u

#define POLLY2_REV_AUDIO 1u   /* first revision with AUDIO_DATA + REVISION */
#define POLLY2_REV_BANDS 2u   /* first revision with FB_TOP/FB_BOT */
#define POLLY2_REV_IRQ   3u   /* first revision with render-done f2h IRQ1 */

/* border band framebuffer geometry (source; displayed 2x as 1280x60) */
#define POLLY2_BAND_W      640u
#define POLLY2_BAND_H      30u
#define POLLY2_BAND_STRIDE 1280u  /* bytes; 128-byte-aligned base required */

#define POLLY2_STATUS_WORKING 0x1u
#define POLLY2_STATUS_DONE    0x2u

#define POLLY2_75MHZ 0
#define POLLY2_90MHZ 1
#define POLLY2_100MHZ 2
#define POLLY2_112MHZ 3

static volatile uint8_t *polly2_mmio;

static inline int polly2_mmio_init(void)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
	if (fd < 0) return -1;
	void *m = mmap(0, POLLY2_MMIO_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
	               POLLY2_MMIO_BASE);
	close(fd);
	if (m == MAP_FAILED) return -1;
	polly2_mmio = (volatile uint8_t *)m;
	return 0;
}

static inline void polly2_mmio_wr(uint32_t offs, uint32_t v)
{
	*(volatile uint32_t *)(polly2_mmio + offs) = v;
}

static inline uint32_t polly2_mmio_rd(uint32_t offs)
{
	return *(volatile uint32_t *)(polly2_mmio + offs);
}

/* reg_offs: PVR register byte offset (0x0000..0x1FFC, as in the reg dump) */
static inline void polly2_reg_write(uint32_t reg_offs, uint32_t value)
{
	polly2_mmio_wr(reg_offs & 0x1FFCu, value);
}

static inline void polly2_regs_upload(uint32_t reg_offs, const uint32_t *vals, unsigned n)
{
	for (unsigned i = 0; i < n; i++) polly2_reg_write(reg_offs + i * 4, vals[i]);
}

/* vram_byte_base: 16MB-aligned DDR3 byte address (only [31:24] is kept).
 * Change only while IDLE or right after polly2_reset(). Power-up 0x32000000. */
static inline void polly2_set_vram_base(uint32_t vram_byte_base)
{
	polly2_mmio_wr(POLLY2_MMIO_VRAM_BASE, vram_byte_base);
}

static inline uint32_t polly2_status(void)      { return polly2_mmio_rd(POLLY2_MMIO_STATUS); }
static inline int      polly2_working(void)     { return polly2_status() & POLLY2_STATUS_WORKING; }
static inline int      polly2_done(void)        { return (polly2_status() & POLLY2_STATUS_DONE) != 0; }
static inline uint32_t polly2_frame_cycles(void){ return polly2_mmio_rd(POLLY2_MMIO_CYCLES); }

/* 0=75, 1=90, 2=100, 3=112.5 MHz. Switching briefly pauses clk_sys and
 * pulses the core reset window; leave the MMIO alone for ~2us afterwards
 * and re-upload nothing - registers and VRAM base survive. */
static inline void polly2_set_clock(unsigned sel)
{
	polly2_mmio_wr(POLLY2_MMIO_CLK, sel & 3u);
	usleep(10);
}

/* current core clock in Hz, from the CLK register readback */
static inline uint32_t polly2_clock_hz(void)
{
	static const uint32_t hz[4] = { 75000000u, 90000000u,
	                                100000000u, 112500000u };
	return hz[polly2_mmio_rd(POLLY2_MMIO_CLK) & 3u];
}

static inline void polly2_go(void)    { polly2_mmio_wr(POLLY2_MMIO_GO, 1); }
static inline void polly2_reset(void) { polly2_mmio_wr(POLLY2_MMIO_RESET, 1); }

/* Push one 48 kHz stereo sample. Hardware-blocking: when the FIFO is full
 * the store stalls this CPU until a slot frees (one sample = ~20.8us).
 * Check polly2_audio_space() first to feed without ever blocking. */
static inline void polly2_audio_push(int16_t l, int16_t r)
{
	polly2_mmio_wr(POLLY2_MMIO_AUDIO_DATA,
	               ((uint32_t)(uint16_t)r << 16) | (uint16_t)l);
}

static inline uint32_t polly2_audio_level(void) /* samples queued, 0..2048 */
{
	return polly2_mmio_rd(POLLY2_MMIO_AUDIO_DATA) & 0xFFFu;
}

static inline uint32_t polly2_audio_space(void)
{
	return POLLY2_AUDIO_FIFO_DEPTH - polly2_audio_level();
}

/* 0 = pre-audio bitstream (the slot read 0 before REVISION existed);
 * >= POLLY2_REV_AUDIO means AUDIO_DATA is present. */
static inline uint32_t polly2_revision(void)
{
	return polly2_mmio_rd(POLLY2_MMIO_REVISION);
}

static inline int polly2_has_audio(void)
{
	return polly2_revision() >= POLLY2_REV_AUDIO;
}

static inline int polly2_has_bands(void)
{
	return polly2_revision() >= POLLY2_REV_BANDS;
}

/* Render done raises f2h IRQ1; with the polly2 kernel module loaded, every
 * process holding /dev/polly2 open gets SIGUSR1. On older bitstreams the
 * IRQ never fires - keep polling polly2_done() when this returns 0. */
static inline int polly2_has_render_irq(void)
{
	return polly2_revision() >= POLLY2_REV_IRQ;
}

/* ddr_byte_addr: 128-byte-aligned DDR byte address of a 640x30 RGB565
 * linear framebuffer (stride 1280), or 0 to turn the band off. The SPG
 * samples these once per frame at vblank start. */
static inline void polly2_set_fb_top(uint32_t ddr_byte_addr)
{
	polly2_mmio_wr(POLLY2_MMIO_FB_TOP, ddr_byte_addr);
}

static inline void polly2_set_fb_bot(uint32_t ddr_byte_addr)
{
	polly2_mmio_wr(POLLY2_MMIO_FB_BOT, ddr_byte_addr);
}

