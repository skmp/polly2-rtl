# pvr-renderer - KOS app that replays the polly2-data dumps on real hardware.
#
#   source /opt/toolchains/dc/kos/environ.sh
#   make
#   make run            # uploads to DC_IP over dcload-ip and runs it
#
# The dumps are read from, and the results written to, the HOST filesystem over
# dcload, so DATA_DIR is a host path with the /pc prefix.

TARGET   = pvr_renderer.elf
OBJS     = dump_render.o

DUMPDIR ?= $(abspath ../polly2-data/dumps)
DATA_DIR = /pc$(DUMPDIR)

# renders per scene (the fastest pass is the one reported)
PASSES  ?= 1

DC_IP   ?= 192.168.178.95
DC_TOOL ?= $(abspath ../../shrike4-rtl/tools/dcload-ip/host-src/tool/dc-tool-ip)

CFLAGS += -DDATA_DIR=\"$(DATA_DIR)\" -DRENDER_PASSES=$(PASSES) \
          -DSCENE_FILTER=\"$(SCENE)\" -DSCENE_SKIP=\"$(SKIP)\"

all: rm-elf $(TARGET)

include $(KOS_BASE)/Makefile.rules

clean: rm-elf
	-rm -f $(OBJS) $(FLAGSTAMP)

rm-elf:
	-rm -f $(TARGET)

# CFLAGS carry SCENE/SKIP/PASSES, and make cannot see those change on its own -
# stamp them into a file so flipping a knob actually forces a recompile.
FLAGSTAMP := .build-flags
$(shell echo '$(CFLAGS)' | cmp -s - $(FLAGSTAMP) || echo '$(CFLAGS)' > $(FLAGSTAMP))
$(OBJS): $(FLAGSTAMP) Makefile

$(TARGET): $(OBJS)
	kos-cc -o $(TARGET) $(OBJS)

# make SCENE=daytona,jgr run  -> only scenes matching one of those substrings
# make SKIP=mipmap run        -> render everything except the matching scenes
# make DCFAST=1 run           -> dcload without FIFO delays (much faster, lossier)
run: $(TARGET)
	$(DC_TOOL) -t $(DC_IP) $(if $(DCFAST),-f,) -x $(TARGET)

.PHONY: all clean rm-elf run
