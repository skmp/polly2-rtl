// SPDX-License-Identifier: GPL-2.0
/*
 * polly2 - render-done interrupt to signal forwarder for the polly2 PVR.
 *
 * The DE10-Nano bitstream (polly2-de10nano/rtl/sys_top.v, MMIO REVISION
 * >= 3) stretches the PVR's render-done pulse onto FPGA-to-HPS interrupt 1,
 * which on Cyclone V is GIC interrupt ID 72+1 = 73 (SPI 41). This module
 * claims that interrupt edge-triggered and forwards every render-done event
 * as a signal (SIGUSR1 by default) to each process holding /dev/polly2
 * open:
 *
 *     int fd = open("/dev/polly2", O_RDONLY);   // register for SIGUSR1
 *     ...                                        // GO, sigwait, repeat
 *     close(fd);                                 // unregister
 *
 * The signal goes to the process (thread group) that opened the device; an
 * fd inherited over fork() does NOT register the child - each interested
 * process opens its own fd. Multiple opens by one process mean multiple
 * kill_pid() calls, but non-RT signals coalesce so it still sees one
 * SIGUSR1 per render.
 *
 * read() returns a u64 count of render-done interrupts since load (debug
 * aid: `xxd /dev/polly2` after a frame should not show zero).
 *
 * No device tree changes are needed: the GIC mapping is created at load
 * time against the arm,cortex-a9-gic node, and the signal is sent from a
 * threaded IRQ handler (process context).
 */

#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/interrupt.h>
#include <linux/irq.h>
#include <linux/irqdomain.h>
#include <linux/of.h>
#include <linux/of_irq.h>
#include <linux/sched/signal.h>
#include <linux/signal.h>
#include <linux/pid.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/spinlock.h>

#define DEVICE_NAME "polly2"

/*
 * Cyclone V HPS: f2h_irq[n] -> GIC interrupt ID 72+n = SPI (40+n).
 *
 * The GIC mapping outlives bitstream swaps: when minicast exits, MiSTer
 * reloads the MENU core, whose framework sys_top drives its own signals
 * (HDMI vsync, 60 Hz) onto the same f2h lines - so interrupts received
 * while the polly2 bitstream is not loaded belong to whatever core is.
 * Not a bug in this driver; just don't interpret them as render-dones.
 */
#define F2H_SPI_BASE  40
#define F2H_IRQ_COUNT 64

static int f2h_irq = 1;
module_param(f2h_irq, int, 0444);
MODULE_PARM_DESC(f2h_irq, "f2h interrupt index the bitstream raises on render done (default 1)");

static int signum = SIGUSR1;
module_param(signum, int, 0444);
MODULE_PARM_DESC(signum, "signal sent to openers on render done (default SIGUSR1)");

struct polly2_listener {
	struct list_head node;
	struct pid *pid;          /* thread group of the opener */
};

/*
 * Everything below runs in process context - open/release/read are
 * syscalls and the IRQ handler is threaded - so a plain spinlock is
 * enough. Protects the listener list and the event counter.
 */
static DEFINE_SPINLOCK(polly2_lock);
static LIST_HEAD(polly2_listeners);
static u64 polly2_events;
static int polly2_virq;

static irqreturn_t polly2_irq_thread(int irq, void *dev_id)
{
	struct polly2_listener *l;

	spin_lock(&polly2_lock);
	polly2_events++;
	list_for_each_entry(l, &polly2_listeners, node)
		kill_pid(l->pid, signum, 1);
	spin_unlock(&polly2_lock);

	return IRQ_HANDLED;
}

static int polly2_open(struct inode *inode, struct file *file)
{
	struct polly2_listener *l = kmalloc(sizeof(*l), GFP_KERNEL);

	if (!l)
		return -ENOMEM;

	l->pid = get_pid(task_tgid(current));

	spin_lock(&polly2_lock);
	list_add_tail(&l->node, &polly2_listeners);
	spin_unlock(&polly2_lock);

	file->private_data = l;
	return 0;
}

static int polly2_release(struct inode *inode, struct file *file)
{
	struct polly2_listener *l = file->private_data;

	spin_lock(&polly2_lock);
	list_del(&l->node);
	spin_unlock(&polly2_lock);

	put_pid(l->pid);
	kfree(l);
	return 0;
}

/* One u64: render-done interrupts since load. EOF on the second read so
 * `xxd < /dev/polly2` terminates; reopen (or pread at 0) to sample again. */
static ssize_t polly2_read(struct file *file, char __user *buf, size_t count,
			   loff_t *ppos)
{
	u64 snap;

	if (*ppos != 0)
		return 0;
	if (count < sizeof(snap))
		return -EINVAL;

	spin_lock(&polly2_lock);
	snap = polly2_events;
	spin_unlock(&polly2_lock);

	if (copy_to_user(buf, &snap, sizeof(snap)))
		return -EFAULT;

	*ppos = sizeof(snap);
	return sizeof(snap);
}

static const struct file_operations polly2_fops = {
	.owner   = THIS_MODULE,
	.open    = polly2_open,
	.release = polly2_release,
	.read    = polly2_read,
	.llseek  = default_llseek,
};

static struct miscdevice polly2_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = DEVICE_NAME,
	.fops  = &polly2_fops,
	.mode  = 0666,   /* registering for a signal is harmless: open to all */
};

static int __init polly2_init(void)
{
	struct device_node *gic;
	struct irq_fwspec fwspec = {};
	int ret;

	if (f2h_irq < 0 || f2h_irq >= F2H_IRQ_COUNT) {
		pr_err("polly2: f2h_irq %d out of range 0..%d\n",
		       f2h_irq, F2H_IRQ_COUNT - 1);
		return -EINVAL;
	}
	if (signum < 1 || !valid_signal(signum)) {
		pr_err("polly2: invalid signum %d\n", signum);
		return -EINVAL;
	}

	gic = of_find_compatible_node(NULL, NULL, "arm,cortex-a9-gic");
	if (!gic) {
		pr_err("polly2: no arm,cortex-a9-gic node (not a Cyclone V HPS?)\n");
		return -ENODEV;
	}

	fwspec.fwnode = of_node_to_fwnode(gic);
	fwspec.param_count = 3;
	fwspec.param[0] = 0;                       /* GIC_SPI */
	fwspec.param[1] = F2H_SPI_BASE + f2h_irq;
	fwspec.param[2] = IRQ_TYPE_EDGE_RISING;

	polly2_virq = irq_create_fwspec_mapping(&fwspec);
	of_node_put(gic);
	if (polly2_virq <= 0) {
		pr_err("polly2: failed to map f2h IRQ %d (SPI %d)\n",
		       f2h_irq, F2H_SPI_BASE + f2h_irq);
		return -EINVAL;
	}

	ret = request_threaded_irq(polly2_virq, NULL, polly2_irq_thread,
				   IRQF_ONESHOT, DEVICE_NAME, NULL);
	if (ret) {
		pr_err("polly2: request_irq failed: %d\n", ret);
		goto err_dispose;
	}

	ret = misc_register(&polly2_dev);
	if (ret) {
		pr_err("polly2: misc_register failed: %d\n", ret);
		goto err_irq;
	}

	pr_info("polly2: loaded, f2h IRQ %d (GIC ID %d) -> signal %d to /dev/polly2 openers\n",
		f2h_irq, 32 + F2H_SPI_BASE + f2h_irq, signum);
	return 0;

err_irq:
	free_irq(polly2_virq, NULL);
err_dispose:
	irq_dispose_mapping(polly2_virq);
	return ret;
}

static void __exit polly2_exit(void)
{
	/* open fds pin the module (fops owner), so no listeners remain here */
	misc_deregister(&polly2_dev);
	free_irq(polly2_virq, NULL);
	irq_dispose_mapping(polly2_virq);
	pr_info("polly2: unloaded\n");
}

module_init(polly2_init);
module_exit(polly2_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("dc-fpga");
MODULE_DESCRIPTION("polly2 PVR render-done IRQ to signal forwarder");
