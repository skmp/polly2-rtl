#!/bin/bash
# jobs.sh: the gates' default job budget J (PLAN 0 rule 8): P2_J if set, else nproc - 4, but no more than the physical
# cores. Measured 2026-11-22 on the 16-core / 32-thread box (agents/gates): N copies of one isp_tile item at once took
# 3.5 s alone, 6-8 s at N = 12-16, 10 s at 18, 16 s at 20 and 22 s at 24-28: past the physical cores the throughput
# falls (the per-copy time grows faster than N), so a second thread per core costs more than it gives.
if [ -n "${P2_J:-}" ]; then echo "$P2_J"; exit 0; fi
n=$(nproc 2>/dev/null || echo 8)
c=$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)
j=$(( n > 4 ? n - 4 : 1 ))
[ "${c:-0}" -gt 0 ] && [ "$c" -lt "$j" ] && j=$c
echo "$j"
