#!/usr/bin/env bash
# Demo: kill an OSD, watch the cluster go degraded while I/O continues, then
# bring it back and watch recovery to HEALTH_OK with checksums intact.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POOL=demo
OBJECTS=8
WORK=/tmp/failure-demo
VICTIM=""

# Never leave the cluster with a dead OSD, even if the demo is interrupted.
restore() {
  if [[ -n "$VICTIM" ]]; then
    compose start "osd-$VICTIM" >/dev/null 2>&1 || true
  fi
}

pg_line() { ceph pg stat | sed 's/;.*//'; }

banner "Demo · Failure and self-healing"
cat <<'EOF'
  Pools here keep 3 replicas (size=3) and keep serving I/O as long as 2 are
  available (min_size=2). When an OSD stops answering heartbeats its peers
  report it, the MONs mark it "down", and its PGs continue on the remaining
  replicas in a "degraded" state. After mon_osd_down_out_interval (60s here,
  600s by default) it is also marked "out" and CRUSH would re-place its data.
EOF
require_cluster
trap restore EXIT

step "Start from a healthy cluster"
wait_for "HEALTH_OK" 300 health_is HEALTH_OK
run ceph -s

step "Write $OBJECTS known objects (4 MiB each) and record their checksums"
if ! ceph osd pool ls | grep -qx "$POOL"; then
  ceph osd pool create "$POOL" 16 16 >/dev/null 2>&1
  ceph osd pool application enable "$POOL" rados >/dev/null 2>&1
  ceph osd pool set "$POOL" pg_autoscale_mode off >/dev/null 2>&1
fi
admin bash -euo pipefail -c "
  rm -rf $WORK && mkdir -p $WORK
  for i in \$(seq 1 $OBJECTS); do
    head -c 4M /dev/urandom > $WORK/obj-\$i
    rados -p $POOL put obj-\$i $WORK/obj-\$i
  done
  cd $WORK && sha256sum obj-* > SHA256SUMS"
run admin bash -c "cat $WORK/SHA256SUMS | head -3; echo '…'"

step "Pick the victim: the primary OSD of obj-1" \
  "Killing a primary is the interesting case: another replica has to take over as primary for its PGs."
run ceph osd map "$POOL" obj-1
VICTIM="$(ceph osd map "$POOL" obj-1 | sed -E 's/.*acting \(\[[0-9,]*\], p([0-9]+)\).*/\1/')"
[[ "$VICTIM" =~ ^[0-9]+$ ]] || die "could not determine primary OSD"
ok "victim is osd.$VICTIM (container osd-$VICTIM)"

step "Kill osd-$VICTIM (SIGKILL, like a crashed daemon)" \
  "No graceful shutdown. The kernel closes the dead process's sockets, so peers get connection-refused and report it at once (osd_fast_fail_on_connection_refused). A host that silently lost power would be caught by missed heartbeats after osd_heartbeat_grace (20s) instead."
run compose --progress quiet kill "osd-$VICTIM"
killed_at=$SECONDS
wait_for "MONs to mark osd.$VICTIM down" 120 bash -c "docker compose exec -T mon-a ceph osd dump | grep -E '^osd\\.$VICTIM ' | grep -q ' down '"
wait_for "PGs to finish re-peering on the survivors" 120 bash -c "! docker compose exec -T mon-a ceph pg stat | grep -q peering"
wait_for "health to report degraded PGs" 60 bash -c "docker compose exec -T mon-a ceph health | grep -q 'Degraded data redundancy'"

step "The cluster is degraded but available"
run ceph health detail
run ceph osd tree
run ceph pg stat

step "I/O continues: read every object and write a new one" \
  "Each PG still has 2 of 3 replicas, which meets min_size=2, so reads and writes are served."
admin bash -euo pipefail -c "
  head -c 4M /dev/urandom > $WORK/obj-during-outage
  rados -p $POOL put obj-during-outage $WORK/obj-during-outage
  cd $WORK && sha256sum obj-during-outage >> SHA256SUMS"
run admin bash -euo pipefail -c "
  mkdir -p $WORK/read && cd $WORK
  for o in \$(cut -d' ' -f3 SHA256SUMS); do rados -p $POOL get \$o read/\$o; done
  cd read && sha256sum -c ../SHA256SUMS"
ok "all reads verified and a new write succeeded with osd.$VICTIM down"
run ceph osd map "$POOL" obj-1

step "Wait for the down → out timeout (mon_osd_down_out_interval)"
run ceph config show mon.a mon_osd_down_out_interval
wait_for "osd.$VICTIM to be marked out" 180 bash -c "docker compose exec -T mon-a ceph osd dump | grep -E '^osd\\.$VICTIM ' | grep -q ' out '"
printf '    marked out %ss after the kill\n' "$((SECONDS - killed_at))"
run ceph osd tree
run ceph pg stat
cat <<'EOF'
    Note what did NOT happen: no backfill. CRUSH needs 3 distinct OSDs per PG
    and only 2 are left, so PGs stay active+undersized+degraded. With 4+ OSDs
    (or, in production, 4+ hosts for size=3) Ceph would re-replicate the
    missing copies onto the survivors and return to HEALTH_OK by itself.
EOF

step "Bring osd-$VICTIM back" \
  "On boot the OSD rejoins, is marked up and in again, and peers with the others. Only objects changed while it was away are recovered (from the PG log), not the whole disk."
run compose --progress quiet start "osd-$VICTIM"
VICTIM_BACK="$VICTIM"
VICTIM=""
start=$SECONDS
until health_is HEALTH_OK; do
  printf '    t+%3ss  %s\n' "$((SECONDS - start))" "$(pg_line)"
  ((SECONDS - start < 300)) || die "cluster did not return to HEALTH_OK within 300s"
  sleep 4
done
ok "HEALTH_OK $((SECONDS - start))s after restarting osd.$VICTIM_BACK"
run ceph -s

step "Verify every object again, including the one written during the outage" \
  "The returning OSD received obj-during-outage via recovery; deep-scrubbing its PG compares all 3 replicas byte for byte."
run admin bash -euo pipefail -c "
  rm -rf $WORK/read && mkdir -p $WORK/read && cd $WORK
  for o in \$(cut -d' ' -f3 SHA256SUMS); do rados -p $POOL get \$o read/\$o; done
  cd read && sha256sum -c ../SHA256SUMS"
pgid="$(ceph osd map "$POOL" obj-during-outage | sed -E 's/.*-> pg [0-9a-f.]+ \(([0-9a-f.]+)\).*/\1/')"
run ceph osd map "$POOL" obj-during-outage
before="$(ceph pg "$pgid" query | grep -m1 '"last_deep_scrub_stamp"' || true)"
ceph pg deep-scrub "$pgid" >/dev/null 2>&1
wait_for "deep scrub of pg $pgid" 120 bash -c "[[ \"\$(docker compose exec -T mon-a ceph pg $pgid query | grep -m1 '\"last_deep_scrub_stamp\"')\" != '$before' ]]"
run admin bash -c "rados list-inconsistent-obj $pgid --format=json-pretty 2>&1 | head -5"
health_is HEALTH_OK || die "cluster not healthy after scrub"
trap - EXIT
ok "failure demo complete: data intact, cluster HEALTH_OK"
