#!/usr/bin/env bash
# Check that Docker has enough memory/CPU, a supported architecture, and that
# the ports and subnet the cluster needs are free. Fails with a clear message.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

MIN_MEM_GIB=6
REC_MEM_GIB=8
MIN_CPUS=2
MIN_DISK_GIB=10
failed=0

fail() {
  printf '%s  ✘ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
  failed=1
}

banner "Preflight"

docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon. Is Docker Desktop running?"
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is not available"

os="$(docker info --format '{{.OperatingSystem}}')"
arch="$(docker info --format '{{.Architecture}}')"
ncpu="$(docker info --format '{{.NCPU}}')"
mem_bytes="$(docker info --format '{{.MemTotal}}')"
mem_gib=$(awk -v b="$mem_bytes" 'BEGIN { printf "%.1f", b / 1024 / 1024 / 1024 }')

case "$arch" in
  x86_64 | amd64) ok "architecture $arch (Intel/AMD image)" ;;
  aarch64 | arm64) ok "architecture $arch (Apple Silicon / arm64 image)" ;;
  *) fail "architecture $arch is not supported (need amd64 or arm64)" ;;
esac

if [[ "$os" == *"Docker Desktop"* ]]; then
  ok "running on $os"
else
  warn "not Docker Desktop ($os); this works on Linux too, but is only tested on Docker Desktop and CI"
fi

# Docker Desktop reports slightly less than the configured value (kernel reserve).
if awk -v m="$mem_gib" -v min="$MIN_MEM_GIB" 'BEGIN { exit !(m + 0.5 < min) }'; then
  fail "Docker has ${mem_gib} GiB memory; need at least ${MIN_MEM_GIB} GiB (Settings → Resources → Memory)"
elif awk -v m="$mem_gib" -v rec="$REC_MEM_GIB" 'BEGIN { exit !(m + 0.5 < rec) }'; then
  warn "Docker has ${mem_gib} GiB memory; works, but ${REC_MEM_GIB} GiB is recommended with the observability profile"
else
  ok "memory ${mem_gib} GiB (min ${MIN_MEM_GIB} GiB)"
fi

if ((ncpu < MIN_CPUS)); then
  fail "Docker has $ncpu CPUs; need at least $MIN_CPUS"
else
  ok "CPUs $ncpu (min $MIN_CPUS)"
fi

# Free disk inside the Docker VM (where volumes live). The mon warns when its
# data disk gets low, so check before we start.
images="$(compose config --images)"
image="$(grep -m1 "quay.io/ceph/ceph" <<<"$images")"
if docker image inspect "$image" >/dev/null 2>&1; then
  avail_kib=$(docker run --rm --entrypoint df -v ceph-showcase-preflight:/probe "$image" -Pk /probe | awk 'NR==2 {print $4}')
  docker volume rm ceph-showcase-preflight >/dev/null 2>&1 || true
  avail_gib=$((avail_kib / 1024 / 1024))
  if ((avail_gib < MIN_DISK_GIB)); then
    fail "only ${avail_gib} GiB free in the Docker VM; need ${MIN_DISK_GIB} GiB (docker system prune, or raise the disk limit)"
  else
    ok "disk ${avail_gib} GiB free in the Docker VM (min ${MIN_DISK_GIB} GiB)"
  fi
else
  warn "Ceph image not pulled yet; skipping the disk check (needs ~${MIN_DISK_GIB} GiB free)"
fi

# Ports: free, or already published by this project (re-running `make up`).
ours="$(compose ps --format '{{.Ports}}' 2>/dev/null || true)"
check_port() {
  local port="$1" label="$2"
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    if [[ "$ours" == *":$port->"* ]]; then
      ok "port $port ($label) already published by this cluster"
    else
      fail "port $port ($label) is in use; free it or set ${label}_PORT in .env"
    fi
  else
    ok "port $port ($label) free"
  fi
}
check_port "$DASHBOARD_PORT" DASHBOARD
check_port "$RGW_PORT" RGW
if [[ "${CHECK_OBSERVABILITY:-0}" == 1 ]]; then
  check_port "$PROMETHEUS_PORT" PROMETHEUS
  check_port "$GRAFANA_PORT" GRAFANA
fi

# Subnet: the mons need fixed IPs, so the Compose subnet must not overlap
# another Docker network.
subnet="${CEPH_NET_PREFIX:-10.250.0}.0/24"
clash="$(docker network ls -q | xargs docker network inspect \
  --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null |
  awk -v s="$subnet" '$1 != "ceph-showcase_ceph" { for (i = 2; i <= NF; i++) if ($i == s) print $1 }')"
if [[ -n "$clash" ]]; then
  fail "subnet $subnet is already used by Docker network '$clash'; set CEPH_NET_PREFIX in .env"
else
  ok "subnet $subnet available"
fi

if ((failed)); then
  die "preflight failed (see above)"
fi
ok "preflight passed"
