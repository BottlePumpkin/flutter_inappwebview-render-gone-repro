#!/usr/bin/env bash
# Usage: tool/summarize.sh <logs/label>  -> rebuilds summary.tsv from the saved logs and prints counts
D=$1
{
  printf 'scenario\tmethod\tdelay\trun\tresult\tdispose_gone_false\tdestroy_seen\n'
  for f in "$D"/*.log; do
    b=$(basename "$f" .log)               # e.g. G_crash_d500_03 or E_crash_d1000_then8000_01
    IFS=_ read -r scen method delay rest <<<"$b"
    printf '%s\t%s\t%s\t%s\t%s\n' "$scen" "$method" "${delay#d}" "${b##*_}" "$("$(dirname "$0")/classify.sh" "$f")"
  done
} > "$D/summary.tsv"
tail -n +2 "$D/summary.tsv" | awk -F'\t' '{k=$1" "$2" d="$3; n[k]++; if($5!="ALIVE")bad[k]++} END{for(k in n) printf "%-18s app died %d/%d\n", k, bad[k], n[k]}' | sort
