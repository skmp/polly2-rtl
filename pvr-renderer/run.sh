#!/bin/bash
# Build and run pvr-renderer on the Dreamcast, retrying the upload until the
# console accepts it (dcload sometimes ignores the first few attempts), then
# letting the run go to completion.
#
#   ./run.sh                 all scenes
#   ./run.sh daytona         only scenes whose name contains "daytona"
#
# Everything the app reads and writes goes over dcload to polly2-data/dumps.
set +u   # KOS environ.sh trips over unset vars
cd "$(dirname "$0")"

DC_IP=${DC_IP:-192.168.178.95}
DC_TOOL=${DC_TOOL:-$(realpath ../../shrike4-rtl/tools/dcload-ip/host-src/tool/dc-tool-ip)}
SCENE=${1:-}
PASSES=${PASSES:-1}
TIMEOUT=${TIMEOUT:-7200}

source /opt/toolchains/dc/kos/environ.sh
make SCENE="$SCENE" PASSES="$PASSES" || exit 1

for attempt in $(seq 1 30); do
  rm -f dctool.log
  ( timeout "$TIMEOUT" stdbuf -oL "$DC_TOOL" -t "$DC_IP" -x pvr_renderer.elf > dctool.log 2>&1
    echo "exit $?" >> dctool.log ) &
  pid=$!
  for i in $(seq 1 8); do sleep 5; grep -q "Executing" dctool.log 2>/dev/null && break; done
  if grep -q "Executing" dctool.log 2>/dev/null; then
    echo "attempt $attempt: running (tail -f dctool.log to watch)"
    wait $pid
    tail -5 dctool.log
    exit 0
  fi
  pkill -x dc-tool-ip; sleep 2
  echo "attempt $attempt: no response from $DC_IP"
done
echo "gave up - is the Dreamcast at $DC_IP sitting in dcload?"
exit 1
