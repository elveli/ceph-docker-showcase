#!/usr/bin/env bash
# Run every demo in order and print a summary. Placement comes before the
# failure demo because it introduces the PG/acting-set output used there.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

demos=(object block file placement failure)
summary=""

require_cluster
for d in "${demos[@]}"; do
  start=$SECONDS
  "scripts/demo-$d.sh"
  summary+="$(printf '  ✔ %-10s %4ss' "$d" "$((SECONDS - start))")"$'\n'
done

banner "All demos passed"
printf '%s' "$summary"
run ceph -s
