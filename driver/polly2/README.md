# polly2 — render-done interrupt → signal

A small char driver that exposes `/dev/polly2` and forwards the PVR's
render-done interrupt as a **SIGUSR1** to every process that holds the device
open. It turns the "poll `STATUS` until `DONE`" loop into a proper sleep.

## Hardware side

Bitstreams with MMIO `REVISION >= 3` (`POLLY2_REV_IRQ`) stretch the core's
1-clock `done` pulse to ~64 `clk_sys` cycles and drive it onto **FPGA-to-HPS
interrupt 1** (`polly2-de10nano/rtl/sys_top.v`). On the Cyclone V HPS,
`f2h_irq[n]` is GIC interrupt ID `72+n`, so render done is **GIC ID 73 /
SPI 41**. The driver claims it edge-triggered — one interrupt per render, no
ack register, and the MMIO map is untouched.

**Gotcha:** the GIC mapping outlives bitstream swaps. When minicast exits,
MiSTer reloads the **menu core**, whose framework sys_top drives its own
signals (HDMI vsync — a clean 60 Hz / 16.7 ms) onto the same f2h lines.
Interrupts received while the polly2 bitstream is not loaded belong to
whatever core is — they are not render-dones, and not a driver bug.

On older bitstreams the module loads fine but the interrupt never fires;
gate on `polly2_has_render_irq()` (driver/polly2_mmio.h) and fall back to
polling `STATUS`.

## Behaviour

- `open()` registers the calling **process** (thread group) for the signal;
  `close()` (or process exit) unregisters it. An fd inherited over `fork()`
  does *not* register the child — each interested process opens its own fd.
- On every render-done interrupt the driver sends `SIGUSR1` (configurable,
  see below) to all registered processes, from a threaded IRQ handler.
- `read()` returns a `u64` count of render-done interrupts since load, then
  EOF — `xxd /dev/polly2` after a frame is a quick "is the IRQ alive" check.
- The node is 0666: registering for a signal is harmless, no root needed.

## Usage

```c
#include <signal.h>

int fd = open("/dev/polly2", O_RDONLY | O_CLOEXEC);

sigset_t set;
sigemptyset(&set);
sigaddset(&set, SIGUSR1);
pthread_sigmask(SIG_BLOCK, &set, NULL);   /* block: consume via sigwait */

polly2_go();
int sig;
sigwait(&set, &sig);                      /* sleeps until render done */
```

A default-action `SIGUSR1` **terminates** the process — block it (as above)
or install a handler before opening the device.

## Module parameters

```sh
insmod polly2.ko                # f2h IRQ1, SIGUSR1
insmod polly2.ko signum=12      # SIGUSR2 instead
insmod polly2.ko f2h_irq=2      # a different f2h line (0..63)
```

## Build

Same recipe as `minicast/mem_wc` (see its README for preparing the kernel
tree): the MiSTer 5.15.1 source with the device's `/proc/config.gz` and
`make modules_prepare`, cross-compiled with the Arm 10.2-2020.11 toolchain.

```sh
make KDIR=/path/to/Linux-Kernel_MiSTer
```

Produces `polly2.ko`. No device tree changes are needed — the GIC mapping is
created at load time against the `arm,cortex-a9-gic` node.

## Demo

`polly2_demo.c` is a minimal listener: it opens `/dev/polly2`, blocks
SIGUSR1 and `sigtimedwait()`s for it, printing one line per render with the
driver's IRQ count and the time since the previous one (plus a heartbeat
after 5s of silence, so a dead IRQ line is obvious).

```sh
make demo               # cross-compiles a static ARM binary, polly2_demo
scp polly2_demo root@de10:
# on the device, with polly2.ko loaded and minicast rendering:
./polly2_demo
#   polly2_demo: listening on /dev/polly2 (7 renders so far), ^C to quit
#   render #8     +16.7ms
#   render #9     +16.6ms
```

## Load

```sh
insmod polly2.ko
dmesg | tail            # "polly2: loaded, f2h IRQ 1 (GIC ID 73) -> signal 10 ..."
ls -l /dev/polly2
cat /proc/interrupts | grep polly2
```
