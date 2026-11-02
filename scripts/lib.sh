#!/usr/bin/env bash
# Shared helpers for the showcase scripts. Source it, don't run it.
# shellcheck disable=SC2034  # variables are used by the scripts sourcing this

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Optional local overrides (ports, subnet, image) live in .env, like compose.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
DASHBOARD_PORT="${DASHBOARD_PORT:-18443}"
RGW_PORT="${RGW_PORT:-17480}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-19090}"
GRAFANA_PORT="${GRAFANA_PORT:-13000}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_RESET=$'\e[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_RESET=""
fi

compose() { docker compose "$@"; }

# Run the ceph CLI (or any command) inside mon-a, which has the admin keyring.
ceph() { compose exec -T mon-a ceph "$@"; }
admin() { compose exec -T mon-a "$@"; }

banner() {
  printf '\n%s══════════════════════════════════════════════════════════════════%s\n' "$C_BLUE" "$C_RESET"
  printf '%s  %s%s\n' "$C_BOLD" "$*" "$C_RESET"
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$C_BLUE" "$C_RESET"
}

# step "what" "why": announce what is about to happen and why it matters.
step() {
  printf '\n%s▶ %s%s\n' "$C_BOLD" "$1" "$C_RESET"
  if [[ $# -gt 1 ]]; then
    printf '%s  %s%s\n' "$C_DIM" "$2" "$C_RESET" | fold -s -w 78 | sed '2,$s/^/  /'
  fi
}

# run cmd...: echo the command, then run it with output indented.
run() {
  printf '%s  $ %s%s\n' "$C_YELLOW" "$*" "$C_RESET"
  "$@" 2>&1 | sed 's/^/    /'
}

# run_as "label" cmd...: like run, but show a readable label instead of cmd.
run_as() {
  printf "%s  \$ %s%s\n" "$C_YELLOW" "$1" "$C_RESET"
  shift
  "$@" 2>&1 | sed "s/^/    /"
}

ok() { printf '%s  ✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die() {
  printf '%s  ✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
  exit 1
}

require_cluster() {
  ceph health >/dev/null 2>&1 || die "cluster not reachable; run 'make up' first"
}

# wait_for "description" timeout_seconds cmd...: poll until cmd succeeds.
wait_for() {
  local what="$1" timeout="$2" start=$SECONDS
  shift 2
  printf '%s  … waiting for %s (up to %ss)%s\n' "$C_DIM" "$what" "$timeout" "$C_RESET"
  until "$@" >/dev/null 2>&1; do
    if ((SECONDS - start >= timeout)); then
      die "timed out after ${timeout}s waiting for $what"
    fi
    sleep 3
  done
  ok "$what (after $((SECONDS - start))s)"
}

health_is() { [[ "$(ceph health 2>/dev/null)" == "$1"* ]]; }

# Client containers (profile "clients") act as separate client machines.
ensure_clients() {
  compose --progress quiet --profile clients up -d client-a client-b
}

# on NAME "shell cmd": run in a client container, echoing the command first.
on() {
  local name="$1"
  shift
  printf '%s  [%s]$ %s%s\n' "$C_YELLOW" "$name" "$*" "$C_RESET"
  compose exec -T "$name" bash -euo pipefail -c "$*" 2>&1 | sed 's/^/    /'
}

# on_q NAME "shell cmd": same, but silent; for capturing values.
on_q() { compose exec -T "$1" bash -euo pipefail -c "$2"; }
