#!/usr/bin/env bash
# Usage: tool/classify.sh <logfile>  -> prints "<result>\t<dispose_gone_false>\t<destroy_seen>"
F=$1
if grep -Eq "crash wasn't handled by all associated +webviews" "$F"; then r=CRASH_UNHANDLED
elif grep -Eq "wasn't handed by all associated +webviews" "$F"; then r=KILL_UNHANDLED
elif grep -q "dart: ALIVE" "$F"; then r=ALIVE
elif grep -q "Process dev.repro.repro_app (pid [0-9]*) has died" "$F"; then r=DIED_OTHER
else r=TIMEOUT; fi
printf '%s\t%s\t%s\n' "$r" "$(grep -c "dispose client onRenderProcessGone.*returns=false" "$F")" "$(grep -c "IAWV-dispose: destroy()" "$F")"
