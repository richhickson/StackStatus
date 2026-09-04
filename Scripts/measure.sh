#!/bin/bash
# Run StackStatus for a while and report network bytes, CPU and memory, so the
# figures in the README can be reproduced.
#
# Usage: Scripts/measure.sh [path/to/StackStatus.app] [seconds, default 600]
#
# nettop reports cumulative bytes per process since it launched, so one sample
# at the end of the window gives the total for the window.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/export/StackStatus.app}"
SECONDS_TO_RUN="${2:-600}"
if [[ ! -d "$APP" ]]; then
  APP=$(ls -d build/DerivedData/Build/Products/*/StackStatus.app 2>/dev/null | head -1 || true)
fi
test -d "$APP" || { echo "no app found; build first or pass a path" >&2; exit 1; }

pkill -x StackStatus 2>/dev/null || true
sleep 1
open -n "$APP"
sleep 3
PID=$(pgrep -x StackStatus | head -1)
test -n "$PID" || { echo "StackStatus did not start" >&2; exit 1; }
echo "StackStatus pid $PID from $APP, measuring for ${SECONDS_TO_RUN}s"

START=$(date +%s)
TICKS=0
CPU_SUM=0
while (( $(date +%s) - START < SECONDS_TO_RUN )); do
  sleep 10
  CPU=$(ps -o %cpu= -p "$PID" | tr -d ' ')
  CPU_SUM=$(echo "$CPU_SUM + ${CPU:-0}" | bc)
  TICKS=$((TICKS + 1))
done

echo
echo "== network (cumulative for the run, per nettop)"
nettop -p "$PID" -P -x -J bytes_in,bytes_out -l 1 | tail -n +2
BYTES=$(nettop -p "$PID" -P -x -J bytes_in,bytes_out -l 1 | tail -1 | awk '{print $3 + $4}')
echo "total bytes: ${BYTES:-?}  (x $((86400 / SECONDS_TO_RUN)) for a day at this rate)"
echo
echo "== process"
ps -o pid,%cpu,%mem,rss,etime,command -p "$PID"
echo "average %cpu over $TICKS samples: $(echo "scale=2; $CPU_SUM / $TICKS" | bc)"
echo "resident set MB (includes shared framework pages): $(( $(ps -o rss= -p "$PID") / 1024 ))"
echo "physical footprint (what Activity Monitor shows as Memory): $(vmmap --summary "$PID" 2>/dev/null | grep -m1 'Physical footprint:' | awk '{print $3}')"
echo
echo "Energy impact: open Activity Monitor > Energy while the app runs; it is not scriptable."
