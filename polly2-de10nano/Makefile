# polly2-de10nano - display/DDR-path testbenches (Verilator)
#
#   make            - build + run all testbenches
#   make spg-sync   - spg.sv sync-geometry check: HS/VS periods and widths,
#                     VS edges aligned to the HS leading edge (CEA-861),
#                     DE exactly 1920x1080 per frame
#   make pvr-burst  - simplex_pvr_top DDR masters vs core reset: an in-flight
#                     write burst completes under reset (a cut burst desyncs
#                     the HPS f2sdram bridge until the fabric is reloaded),
#                     stale read beats are swallowed without reaching the core
#   make clean

VERILATOR ?= verilator

NJOBS := $(shell nproc 2>/dev/null || echo 4)

VFLAGS = -Wno-WIDTH -Wno-UNUSEDSIGNAL -j $(NJOBS) --build-jobs $(NJOBS) \
         -CFLAGS "-O3"

# spg testbenches read the module's parameters (and its derived window localparams)
# out of the generated model instead of hardcoding a raster - see tb/spg_mode.h.
SPGFLAGS = --public-params

# The stock 1080p configuration, as a second instantiation of the SAME spg.sv.
# spg.sv now carries the 480p mode as its defaults and gates its address generators
# on SCALE; without this the SCALE=2 arm would only ever be verified by reading the
# diff. Built into its own --Mdir: the parameters differ, so the generated model
# cannot be shared with the default-mode build.
#
# Written ONCE as name=value pairs and rendered two ways, because the override has to
# reach spg through a different door depending on where spg sits in the hierarchy:
#   -G  when spg IS the top module          (spg-sync/bands/depth-1080p)
#   -D  when it is not, feeding the guarded defparam block in tb/spg_loopback_top.sv
#       (spg-loopback-1080p) - -G only ever reaches the top, which there is the wrapper
STOCK_1080P_MODE = H_ACTIVE=1920 H_FP=88 H_SYNC=44 H_BP=148 \
                   V_ACTIVE=1080 V_FP=4  V_SYNC=5  V_BP=36  \
                   SRC_W=640 SRC_H=480 SCALE=2
STOCK_1080P   = $(addprefix -G,$(STOCK_1080P_MODE))
STOCK_1080P_D = -DSPG_LB_STOCK $(addprefix -DSPG_LB_,$(STOCK_1080P_MODE))

TSP_PKG = ../polly2-core/rtl/gen/tsp_pkg.sv
# polly2-core video-out (framebuffer write master) instantiated by simplex_pvr_top
VO_RTL  = ../polly2-core/rtl/vo.sv

all: spg-sync pvr-burst spg-loopback audio-i2s spg-bands spg-depth spg-240p fb-write render-irq \
     spg-480p spg-1to1 spg-1080p

#   make fb-write - FB write master formats: every FB_W_CTRL packmode
#                   (0555K/565/4444/1555/888/0888K/8888, refsw2 dither
#                   quantization) x 32-bit split area / dense 64-bit
#                   render-to-texture mirror (FB_W_SOF1[24]); exact DDR
#                   byte-map compare incl. byte enables
fb-write: obj_dir/fb_write_tb
	./obj_dir/fb_write_tb

obj_dir/fb_write_tb: rtl/simplex_pvr_top.sv $(VO_RTL) tb/peel_core_stub.sv tb/fb_write_tb.cpp $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module simplex_pvr_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv $(VO_RTL) tb/fb_write_tb.cpp \
	    -o fb_write_tb

#   make spg-depth - FB_R_CTRL read formats + per-line FB_R_SOF: all four
#                    fb_depth modes (linear + split, misaligned bases,
#                    fb_concat, the packed-888 fetch quirk) against a
#                    refsw2 Present() software model; mid-frame SOF change
#                    lands line-exactly; fb_enable=0 blanks the window
spg-depth: obj_dir/spg_depth_tb
	./obj_dir/spg_depth_tb

obj_dir/spg_depth_tb: rtl/spg.sv tb/spg_depth_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) rtl/spg.sv tb/spg_depth_tb.cpp -o spg_depth_tb

#   make spg-240p  - 240p (line-doubled) display: a 640x240 source shown at
#                    twice the raster's vertical scale (2 output lines per source
#                    line at 480p, 4 at stock 1080p - see spg-240p-1080p; last
#                    source line 239), every fb_depth, linear + split, composed
#                    with pixel_double, bands (where the raster has them) at SCALE
spg-240p: obj_dir/spg_240p_tb
	./obj_dir/spg_240p_tb

obj_dir/spg_240p_tb: rtl/spg.sv tb/spg_240p_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) rtl/spg.sv tb/spg_240p_tb.cpp -o spg_240p_tb

#   make render-irq - irq_stretch (render-done -> f2h IRQ1): a done edge
#                     gives exactly one 64-cycle pulse (a held level does
#                     not retrigger), edges mid-stretch coalesce without
#                     the line dropping, a later edge gives a fresh pulse
render-irq: obj_dir/irq_stretch_tb
	./obj_dir/irq_stretch_tb

obj_dir/irq_stretch_tb: rtl/irq_stretch.sv tb/irq_stretch_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/irq_stretch.sv tb/irq_stretch_tb.cpp -o irq_stretch_tb

#   make spg-bands - border bands: per-pixel compare of full frames (top
#                    band / game window / bottom band / black borders),
#                    band enable/disable latching at vblank, no underrun
spg-bands: obj_dir/spg_bands_tb
	./obj_dir/spg_bands_tb

obj_dir/spg_bands_tb: rtl/spg.sv tb/spg_bands_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) rtl/spg.sv tb/spg_bands_tb.cpp -o spg_bands_tb

spg-sync: obj_dir/spg_sync_tb
	./obj_dir/spg_sync_tb

#   make spg-480p  - asserts the 480p target raster (CEA-861 VIC 2/3, 720x480p@59.94,
#                    27 MHz, 858x525). Written test-first: FAILS against the stock 1080p
#                    spg.sv by design, and passes only once the parameters are retargeted.
obj_dir/spg_480p_tb: rtl/spg.sv tb/spg_480p_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/spg.sv tb/spg_480p_tb.cpp -o spg_480p_tb

spg-480p: obj_dir/spg_480p_tb
	./obj_dir/spg_480p_tb

#   make spg-1to1  - per-pixel SAMPLING at the 480p target: source column n lands at
#                    raster X0+n exactly once, source line m occupies exactly one output
#                    line, no line buffer is written while it is scanned out, and
#                    fb_pix_dbl / fb_line_dbl still give 2x. Complements spg-480p, which
#                    asserts the raster only. Written test-first: FAILS while the address
#                    generators still assume the 2x doubling 1080p needed.
obj_dir/spg_1to1_tb: rtl/spg.sv tb/spg_1to1_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/spg.sv tb/spg_1to1_tb.cpp -o spg_1to1_tb

spg-1to1: obj_dir/spg_1to1_tb
	./obj_dir/spg_1to1_tb

#   make audio-i2s - MMIO AUDIO_DATA -> 2048-entry async FIFO -> I2S:
#                    framing/order/one-shot delivery, blocking-write
#                    backpressure when full, non-audio accesses unaffected,
#                    full-drain integrity (no loss or duplication)
audio-i2s: obj_dir/audio_i2s_tb
	./obj_dir/audio_i2s_tb

obj_dir/audio_i2s_tb: rtl/pvr_mmio.sv rtl/audio_i2s.sv tb/audio_tb_top.sv tb/audio_i2s_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-PINCONNECTEMPTY --top-module audio_tb_top \
	    rtl/pvr_mmio.sv rtl/audio_i2s.sv tb/audio_tb_top.sv tb/audio_i2s_tb.cpp \
	    -o audio_i2s_tb

obj_dir/spg_sync_tb: rtl/spg.sv tb/spg_sync_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) rtl/spg.sv tb/spg_sync_tb.cpp -o spg_sync_tb

#   make spg-1080p - the spg testbenches re-run against a STOCK 1080p instantiation
#                    (SCALE=2). spg.sv's SCALE=1 and SCALE=2 arms are written
#                    `(SCALE == 2) ? <stock> : <1:1>`; this is what machine-checks the
#                    SCALE=2 arm rather than arguing from the diff that it constant-folds
#                    back to stock. sync/bands/depth cover geometry and the read formats;
#                    loopback covers the fetch path and the post-reset toggle parity;
#                    240p covers fb_line_dbl doubling on top of the SCALE=2 arm.
spg-1080p: spg-sync-1080p spg-bands-1080p spg-depth-1080p spg-loopback-1080p spg-240p-1080p

spg-sync-1080p: obj_1080p/spg_sync_tb
	./obj_1080p/spg_sync_tb

obj_1080p/spg_sync_tb: rtl/spg.sv tb/spg_sync_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) --Mdir obj_1080p \
	    $(STOCK_1080P) rtl/spg.sv tb/spg_sync_tb.cpp -o spg_sync_tb

spg-240p-1080p: obj_1080p/spg_240p_tb
	./obj_1080p/spg_240p_tb

obj_1080p/spg_240p_tb: rtl/spg.sv tb/spg_240p_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) --Mdir obj_1080p \
	    $(STOCK_1080P) rtl/spg.sv tb/spg_240p_tb.cpp -o spg_240p_tb

spg-bands-1080p: obj_1080p/spg_bands_tb
	./obj_1080p/spg_bands_tb

obj_1080p/spg_bands_tb: rtl/spg.sv tb/spg_bands_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) --Mdir obj_1080p \
	    $(STOCK_1080P) rtl/spg.sv tb/spg_bands_tb.cpp -o spg_bands_tb

spg-depth-1080p: obj_1080p/spg_depth_tb
	./obj_1080p/spg_depth_tb

obj_1080p/spg_depth_tb: rtl/spg.sv tb/spg_depth_tb.cpp tb/spg_mode.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) --Mdir obj_1080p \
	    $(STOCK_1080P) rtl/spg.sv tb/spg_depth_tb.cpp -o spg_depth_tb

#   make spg-loopback-1080p - the write-layout vs scanout-layout cross-check and the
#                    post-reset toggle-parity check, at stock 1920x1080/SCALE=2. The
#                    fetch path is the one part of spg the other -1080p targets do not
#                    reach: they instantiate spg alone, while this one needs the FB
#                    write master beside it. That makes it the target that shows the
#                    done_toggle reset fix holding in the configuration upstream ships,
#                    not only at the retargeted 480p.
spg-loopback-1080p: obj_1080p/spg_loopback_tb
	./obj_1080p/spg_loopback_tb

obj_1080p/spg_loopback_tb: rtl/simplex_pvr_top.sv $(VO_RTL) rtl/spg.sv tb/spg_loopback_top.sv tb/peel_core_stub.sv tb/spg_loopback_tb.cpp tb/spg_mode.h $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) --Mdir obj_1080p \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module spg_loopback_top $(STOCK_1080P_D) \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv $(VO_RTL) rtl/spg.sv \
	    tb/spg_loopback_top.sv tb/spg_loopback_tb.cpp \
	    -o spg_loopback_tb

pvr-burst: obj_dir/pvr_burst_tb
	./obj_dir/pvr_burst_tb

#   make spg-loopback - stream a full frame through the FB write master in
#                       tile order, scan it out through spg, compare every
#                       window pixel (write layout vs scanout layout)
spg-loopback: obj_dir/spg_loopback_tb
	./obj_dir/spg_loopback_tb

#   make spg-loopback-nobp - the same run with the DDR model's random backpressure
#                       removed. Diagnostic only, not part of `all`: it separates a
#                       fetch-BANDWIDTH margin problem (passes here, fails above)
#                       from an address/layout bug (fails both ways).
spg-loopback-nobp: obj_dir/spg_loopback_tb
	./obj_dir/spg_loopback_tb -nobp

obj_dir/spg_loopback_tb: rtl/simplex_pvr_top.sv $(VO_RTL) rtl/spg.sv tb/spg_loopback_top.sv tb/peel_core_stub.sv tb/spg_loopback_tb.cpp tb/spg_mode.h $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) $(SPGFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module spg_loopback_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv $(VO_RTL) rtl/spg.sv \
	    tb/spg_loopback_top.sv tb/spg_loopback_tb.cpp \
	    -o spg_loopback_tb

obj_dir/pvr_burst_tb: rtl/simplex_pvr_top.sv $(VO_RTL) tb/peel_core_stub.sv tb/pvr_burst_tb.cpp $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module simplex_pvr_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv $(VO_RTL) tb/pvr_burst_tb.cpp \
	    -o pvr_burst_tb

clean:
	rm -rf obj_dir obj_1080p

.PHONY: all spg-sync pvr-burst spg-loopback spg-loopback-nobp audio-i2s spg-bands spg-depth \
        spg-240p fb-write render-irq spg-480p spg-1to1 \
        spg-1080p spg-sync-1080p spg-bands-1080p spg-depth-1080p spg-loopback-1080p \
        spg-240p-1080p clean
