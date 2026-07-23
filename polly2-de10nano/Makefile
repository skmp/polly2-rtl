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

TSP_PKG = ../polly2-core/rtl/gen/tsp_pkg.sv

all: spg-sync pvr-burst spg-loopback audio-i2s spg-bands spg-depth fb-write render-irq

#   make fb-write - FB write master formats: every FB_W_CTRL packmode
#                   (0555K/565/4444/1555/888/0888K/8888, refsw2 dither
#                   quantization) x 32-bit split area / dense 64-bit
#                   render-to-texture mirror (FB_W_SOF1[24]); exact DDR
#                   byte-map compare incl. byte enables
fb-write: obj_dir/fb_write_tb
	./obj_dir/fb_write_tb

obj_dir/fb_write_tb: rtl/simplex_pvr_top.sv tb/peel_core_stub.sv tb/fb_write_tb.cpp $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module simplex_pvr_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv tb/fb_write_tb.cpp \
	    -o fb_write_tb

#   make spg-depth - FB_R_CTRL read formats + per-line FB_R_SOF: all four
#                    fb_depth modes (linear + split, misaligned bases,
#                    fb_concat, the packed-888 fetch quirk) against a
#                    refsw2 Present() software model; mid-frame SOF change
#                    lands line-exactly; fb_enable=0 blanks the window
spg-depth: obj_dir/spg_depth_tb
	./obj_dir/spg_depth_tb

obj_dir/spg_depth_tb: rtl/spg.sv tb/spg_depth_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/spg.sv tb/spg_depth_tb.cpp -o spg_depth_tb

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

obj_dir/spg_bands_tb: rtl/spg.sv tb/spg_bands_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/spg.sv tb/spg_bands_tb.cpp -o spg_bands_tb

spg-sync: obj_dir/spg_sync_tb
	./obj_dir/spg_sync_tb

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

obj_dir/spg_sync_tb: rtl/spg.sv tb/spg_sync_tb.cpp
	$(VERILATOR) --cc --exe --build $(VFLAGS) rtl/spg.sv tb/spg_sync_tb.cpp -o spg_sync_tb

pvr-burst: obj_dir/pvr_burst_tb
	./obj_dir/pvr_burst_tb

#   make spg-loopback - stream a full frame through the FB write master in
#                       tile order, scan it out through spg, compare every
#                       window pixel (write layout vs scanout layout)
spg-loopback: obj_dir/spg_loopback_tb
	./obj_dir/spg_loopback_tb

obj_dir/spg_loopback_tb: rtl/simplex_pvr_top.sv rtl/spg.sv tb/spg_loopback_top.sv tb/peel_core_stub.sv tb/spg_loopback_tb.cpp $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module spg_loopback_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv rtl/spg.sv \
	    tb/spg_loopback_top.sv tb/spg_loopback_tb.cpp \
	    -o spg_loopback_tb

obj_dir/pvr_burst_tb: rtl/simplex_pvr_top.sv tb/peel_core_stub.sv tb/pvr_burst_tb.cpp $(TSP_PKG)
	$(VERILATOR) --cc --exe --build $(VFLAGS) \
	    -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINMISSING \
	    -I../polly2-core/rtl/gen \
	    --top-module simplex_pvr_top \
	    $(TSP_PKG) tb/peel_core_stub.sv rtl/simplex_pvr_top.sv tb/pvr_burst_tb.cpp \
	    -o pvr_burst_tb

clean:
	rm -rf obj_dir

.PHONY: all spg-sync pvr-burst spg-loopback audio-i2s spg-bands spg-depth fb-write render-irq clean
