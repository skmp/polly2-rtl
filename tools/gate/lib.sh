#!/bin/bash
# tools/gate/lib.sh: what every gate script shares (PLAN 0 rule 2, conventions.md 2 and 7.8). Source it:
#
#   . "$(dirname "$0")/lib.sh"
#   gate_begin <gate>                 build/gate/<gate>/ (cleared); the revision header
#   gate_step <name> <command ...>    runs the command, its output in build/gate/<gate>/<name>.log; prints and records
#                                     "<name>: PASS (<s> s)" or "<name>: FAIL (<s> s)" with the log's last lines
#   gate_end                          writes build/gate/<gate>/summary.txt (header, the runtime-switch check, one line
#                                     per step, "<gate>: PASS" / "FAIL" last), prints the verdict, exits 0 / 1
#
# The revision header (conventions.md 2): nulldc3 HEAD and refsw3-dirty (clean, or the first 8 hex digits of the md5
# of `git status --porcelain` and `git diff HEAD` of refsw3 and refsw3-offline: the content, not only the file names),
# dreamcast-tests HEAD, polly2-rtl HEAD (+dirty when the working tree has changes).
# The runtime-switch check (PLAN 1.1) is the check_ref_switches step's verdict when the gate ran one, else a run of
# tools/check_ref_switches.sh --no-hwpkg made by gate_end.

P2_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export NULLDC3=${NULLDC3:-$P2_ROOT/../nulldc3}
export REFCORE=${REFCORE:-$NULLDC3/refsw3/refcore}
export DCTESTS=${DCTESTS:-$P2_ROOT/../dreamcast-tests}
MAKE=${MAKE:-make}

rev_header() {
  local n3 dirty dct p2
  n3=$(git -C "$NULLDC3" rev-parse --short HEAD 2>/dev/null || echo "none")
  if [ -z "$(git -C "$NULLDC3" status --porcelain refsw3 refsw3-offline 2>/dev/null)" ]; then
    dirty=clean
  else
    dirty=$({ git -C "$NULLDC3" status --porcelain refsw3 refsw3-offline; git -C "$NULLDC3" diff HEAD -- refsw3 refsw3-offline; } |
            md5sum | cut -c1-8)
  fi
  dct=$(git -C "$DCTESTS" rev-parse --short HEAD 2>/dev/null || echo "none")
  if p2=$(git -C "$P2_ROOT" rev-parse --short HEAD 2>/dev/null); then
    [ -n "$(git -C "$P2_ROOT" status --porcelain 2>/dev/null)" ] && p2="$p2+dirty"
  else
    p2=untracked
  fi
  echo "nulldc3 $n3 refsw3-dirty $dirty"
  echo "dreamcast-tests $dct ; polly2-rtl $p2"
}

gate_begin() {
  GATE=$1
  GATE_DIR="$P2_ROOT/build/gate/$GATE"
  rm -rf "$GATE_DIR" && mkdir -p "$GATE_DIR"
  GATE_HEADER=$(rev_header)
  GATE_LINES=()
  GATE_FAILED=0
  GATE_T0=$(date +%s.%N)
  echo "$GATE_HEADER"
}

gate_step() {
  local name=$1; shift
  local t0 t1 st secs
  t0=$(date +%s.%N)
  ( cd "$P2_ROOT" && "$@" ) > "$GATE_DIR/$name.log" 2>&1
  st=$?
  t1=$(date +%s.%N)
  secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
  if [ $st = 0 ]; then
    GATE_LINES+=("$name: PASS ($secs s)")
    echo "$name: PASS ($secs s)"
  else
    GATE_LINES+=("$name: FAIL ($secs s, exit $st; build/gate/$GATE/$name.log)")
    GATE_FAILED=1
    echo "$name: FAIL ($secs s, exit $st)"
    tail -15 "$GATE_DIR/$name.log" | sed 's/^/    /'
  fi
}

gate_end() {
  local sw verdict total
  if [ -f "$GATE_DIR/check_ref_switches.log" ]; then
    sw=$(tail -1 "$GATE_DIR/check_ref_switches.log")
  else
    sw=$(bash "$P2_ROOT/tools/check_ref_switches.sh" --no-hwpkg 2>&1 | tail -1)
    case "$sw" in *PASS) ;; *) GATE_FAILED=1 ;; esac
  fi
  verdict=$([ "$GATE_FAILED" = 0 ] && echo PASS || echo FAIL)
  total=$(awk -v a="$GATE_T0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
  {
    echo "$GATE_HEADER"
    echo "switches: $sw"
    printf '%s\n' "${GATE_LINES[@]}"
    echo "total: $total s"
    echo "$GATE: $verdict"
  } > "$GATE_DIR/summary.txt"
  echo "summary: build/gate/$GATE/summary.txt ($total s)"
  echo "$GATE: $verdict"
  [ "$verdict" = PASS ]
  exit $?
}
