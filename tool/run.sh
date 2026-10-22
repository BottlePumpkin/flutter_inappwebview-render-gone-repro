#!/usr/bin/env bash
# Usage: tool/run.sh <label> <scenario K|A|B|C> <delay_ms> <runs>
# Env: SERIAL (default emulator-5554), METHOD kill|crash (default kill),
#      THEN_KILL_AFTER ms (default -1 = off): one extra plain kill after the scenario
# Runs the scenario N times from a cold start and classifies each run:
#   CRASH_UNHANDLED - chromium "Render process ... crash wasn't handled by all associated webviews"
#                     (didCrash=true path, app aborted)
#   KILL_UNHANDLED  - chromium "Render process ... kill (OOM or update) wasn't handed by all
#                     associated webviews, killing application" (didCrash=false path, SIGKILL)
#   DIED_OTHER      - process gone without either line
#   ALIVE  - Dart logged ALIVE 5 s after the scenario finished
set -u
LABEL=$1; SCEN=$2; DELAY=$3; RUNS=$4
SERIAL=${SERIAL:-emulator-5554}
METHOD=${METHOD:-kill}
THEN=${THEN_KILL_AFTER:--1}
PKG=dev.repro.repro_app
ADB=(adb -s "$SERIAL")
OUT="$(cd "$(dirname "$0")/.." && pwd)/logs/$LABEL"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.tsv"
[ -f "$SUMMARY" ] || printf 'scenario\tmethod\tdelay\trun\tresult\tdispose_gone_false\tdestroy_seen\n' > "$SUMMARY"

for i in $(seq 1 "$RUNS"); do
  "${ADB[@]}" shell am force-stop "$PKG"
  sleep 1
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell am start -n "$PKG/.MainActivity" --es scenario "$SCEN" --ei delay "$DELAY" --es method "$METHOD" --ei thenKillAfter "$THEN" >/dev/null
  # Wait until the app logs ALIVE or its process is gone; classify from the full log afterwards.
  for _ in $(seq 1 80); do
    sleep 0.5
    "${ADB[@]}" logcat -d -s REPRO:W 2>/dev/null | grep -q "dart: ALIVE" && break
    "${ADB[@]}" shell pidof "$PKG" >/dev/null 2>&1 || break
  done
  sleep 1
  TAG=$([ "$THEN" -ge 0 ] && echo "_then$THEN")
  F="$OUT/${SCEN}_${METHOD}_d${DELAY}${TAG}_$(printf %02d "$i").log"
  "${ADB[@]}" logcat -d -v threadtime > "$F"
  printf '%s\t%s\t%s\t%s\t%s\n' "$SCEN" "$METHOD" "$DELAY" "$i" "$("$(dirname "$0")/classify.sh" "$F")" | tee -a "$SUMMARY"
done
