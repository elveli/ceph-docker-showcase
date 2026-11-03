#!/usr/bin/env bash
# Cluster status plus the URLs and credentials to reach it.
#   status.sh            full status (ceph -s, OSD tree, pools, containers)
#   status.sh --summary  short version printed at the end of `make up`
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

mode="${1:-full}"
require_cluster

# `compose up --wait` returns once one-shot jobs are *running*; for the
# summary after `make up`, wait until init has finished and health settled.
init_done() {
  local state
  state="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$(compose ps -aq init)")"
  if [[ "$state" == exited* && "$state" != "exited 0" ]]; then
    compose logs init >&2
    die "init job failed ($state)"
  fi
  [[ "$state" == "exited 0" ]]
}
if [[ "$mode" == "--summary" ]]; then
  wait_for "init job (mgr modules, dashboard user)" 180 init_done
  wait_for "HEALTH_OK with all PGs active+clean" 180 bash -c \
    "docker compose exec -T mon-a ceph health | grep -q HEALTH_OK && docker compose exec -T mon-a ceph pg stat | grep -Eq '^[0-9]+ pgs: [0-9]+ active\+clean;'"
fi

banner "Ceph cluster status"
run ceph -s

if [[ "$mode" != "--summary" ]]; then
  step "OSD tree" "CRUSH hierarchy: all three OSDs sit under one host bucket, because they share one machine."
  run ceph osd tree
  step "Pools"
  run ceph osd pool ls detail
  step "Containers"
  run compose ps --format 'table {{.Service}}\t{{.Status}}'
fi

password="$(ceph config-key get showcase/dashboard-password 2>/dev/null || echo '<not ready yet: run make status in a moment>')"

banner "Endpoints"
printf '  Ceph dashboard   https://localhost:%s   (self-signed cert)\n' "$DASHBOARD_PORT"
printf '                   user: admin   password: %s\n' "$password"
printf '  RGW (S3 API)     http://localhost:%s\n' "$RGW_PORT"
if compose ps --status running --services 2>/dev/null | grep -qx grafana; then
  printf '  Prometheus       http://localhost:%s\n' "$PROMETHEUS_PORT"
  printf '  Grafana          http://localhost:%s   (anonymous viewer; admin/admin to edit)\n' "$GRAFANA_PORT"
fi
printf '  Ceph shell       make shell   (then: ceph -s, ceph osd tree, rados lspools …)\n'
printf '  Demos            make demo    (or demo-object / demo-block / demo-file / demo-failure / demo-placement)\n'
