# Out-of-tree build for the polly2 render-done interrupt driver.
#
# Build against the MiSTer 5.15.1 kernel source, cross-compiled with the same
# Arm 10.2-2020.11 toolchain the kernel itself was built with (per /proc/version).
#
#   make KDIR=/path/to/Linux-Kernel_MiSTer
#
# KDIR must be a kernel tree that has had `make modules_prepare` run against the
# device's /proc/config.gz, so vermagic matches (5.15.1-MiSTer SMP ...). See
# minicast/mem_wc/README.md for the full tree-preparation recipe.

obj-m := polly2.o

# Kernel source / build tree. Override on the command line as needed.
KDIR ?= /lib/modules/$(shell uname -r)/build

ARCH          ?= arm
CROSS_COMPILE ?= /opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-

PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

# Userspace listener demo (see polly2_demo.c). Static so the toolchain's
# glibc version doesn't have to match the device's.
demo: polly2_demo

polly2_demo: polly2_demo.c
	$(CROSS_COMPILE)gcc -O2 -Wall -static -o $@ $<

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
	rm -f polly2_demo

.PHONY: all demo clean
