/*
 * polly2_demo - listen for render-done interrupts from /dev/polly2.
 *
 * Holding the device open registers this process for a SIGUSR1 on every
 * render-done IRQ; the signal is blocked and consumed with sigtimedwait()
 * so nothing asynchronous happens. Run it alongside minicast (or anything
 * that kicks GO) and it prints one line per render:
 *
 *     # ./polly2_demo
 *     polly2_demo: listening on /dev/polly2 (7 renders so far), ^C to quit
 *     render #8    +16.7ms
 *     render #9    +16.6ms
 *
 * The count comes from the driver's read() interface (u64 IRQs since
 * module load), the delta is wall time between signals here. A 5s silence
 * prints a heartbeat so a dead IRQ line is obvious.
 *
 * Build: make demo   (cross-compiles with the same toolchain as the module)
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

#define DEV "/dev/polly2"

static uint64_t read_count(int fd)
{
	uint64_t n = 0;

	if (pread(fd, &n, sizeof(n), 0) != (ssize_t)sizeof(n))
		perror("polly2_demo: pread");
	return n;
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(void)
{
	int fd = open(DEV, O_RDONLY | O_CLOEXEC);

	if (fd < 0) {
		perror("polly2_demo: open " DEV);
		fprintf(stderr, "polly2_demo: is polly2.ko loaded?\n");
		return 1;
	}

	/* Block the signals BEFORE they can be delivered: a default-action
	 * SIGUSR1 would terminate us. sigtimedwait() pulls them off the
	 * pending queue synchronously. */
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, SIGUSR1);
	sigaddset(&set, SIGINT);
	sigaddset(&set, SIGTERM);
	sigprocmask(SIG_BLOCK, &set, NULL);

	printf("polly2_demo: listening on " DEV " (%llu renders so far), ^C to quit\n",
	       (unsigned long long)read_count(fd));

	double prev = 0.0;
	for (;;) {
		struct timespec timeout = { .tv_sec = 5 };
		int sig = sigtimedwait(&set, NULL, &timeout);

		if (sig < 0) {
			if (errno == EAGAIN) {          /* 5s of silence */
				printf("  ... no render-done for 5s\n");
				continue;
			}
			if (errno == EINTR)
				continue;
			perror("polly2_demo: sigtimedwait");
			break;
		}
		if (sig != SIGUSR1)                     /* SIGINT/SIGTERM */
			break;

		double t = now_ms();
		if (prev != 0.0)
			printf("render #%-6llu +%.1fms\n",
			       (unsigned long long)read_count(fd), t - prev);
		else
			printf("render #%-6llu\n",
			       (unsigned long long)read_count(fd));
		prev = t;
	}

	printf("polly2_demo: bye (%llu renders total)\n",
	       (unsigned long long)read_count(fd));
	close(fd);
	return 0;
}
