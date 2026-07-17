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

all: spg-sync pvr-burst spg-loopback

spg-sync: obj_dir/spg_sync_tb
	./obj_dir/spg_sync_tb

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

.PHONY: all spg-sync pvr-burst spg-loopback clean
