#!/usr/bin/env bash
# Cluster status plus the URLs and credentials to reach it.
#   status.sh            full status (ceph -s, OSD tree, pools, containers)
#   status.sh --summary  short version printed at the end of `make up`
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

mode="${1:-full}"
require_cluster

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
