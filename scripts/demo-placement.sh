#!/usr/bin/env bash
# Demo: make CRUSH visible. Show which placement group and which OSDs hold an
# object, that placement is computed (not looked up), and why this lab uses
# 'osd' rather than 'host' as the failure domain.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POOL=demo

banner "Demo · Data placement (PGs and CRUSH)"
cat <<'EOF'
  Ceph has no central table of "object → disk". A client computes placement:
    object name ──hash──▶ placement group (PG) ──CRUSH(cluster map)──▶ [OSDs]
  The first OSD in the list is the primary: it takes the write and
  replicates it to the others. Every client and daemon gets the same answer
  from the same cluster map, so there's no metadata lookup on the data path.
EOF
require_cluster

step "Create pool '$POOL' with 16 PGs (idempotent)" \
  "16 PGs spreads objects visibly. The autoscaler is turned off for this pool so the PG count stays put while we look at it."
if ! ceph osd pool ls | grep -qx "$POOL"; then
  run ceph osd pool create "$POOL" 16 16
  ceph osd pool application enable "$POOL" rados >/dev/null 2>&1
fi
ceph osd pool set "$POOL" pg_autoscale_mode off >/dev/null 2>&1
run ceph osd pool get "$POOL" pg_num

step "Write a few objects"
for name in invoice-001 invoice-002 photo.jpg backup.tar; do
  admin bash -c "head -c 64K /dev/urandom | rados -p $POOL put $name -"
done
run admin rados -p "$POOL" ls

step "Ask where each object lives: ceph osd map" \
  "Reads as: pool.PG → up set [OSDs] p<primary>. 'up' is what CRUSH computes; 'acting' is who serves it right now (they differ during recovery)."
for name in invoice-001 invoice-002 photo.jpg backup.tar; do
  run ceph osd map "$POOL" "$name"
done

step "Placement is computed, not stored" \
  "This object was never written, yet Ceph can already say where it would go. That's the whole point of CRUSH: the map is the algorithm's input, not an index."
run ceph osd map "$POOL" does-not-exist-yet

step "All PGs of the pool, with object counts and their OSD sets"
run_as "ceph pg ls-by-pool $POOL  (formatted)" admin bash -c "ceph pg ls-by-pool $POOL --format json | python3 -c '
import json, sys
d = json.load(sys.stdin)
pgs = d[\"pg_stats\"] if isinstance(d, dict) else d
print(\"%-7s %-8s %-10s %s\" % (\"PG\", \"OBJECTS\", \"UP\", \"ACTING (primary first)\"))
for p in sorted(pgs, key=lambda p: int(p[\"pgid\"].split(\".\")[1], 16)):
    print(\"%-7s %-8s %-10s %s\" % (p[\"pgid\"], p[\"stat_sum\"][\"num_objects\"], p[\"up\"], p[\"acting\"]))
'"

step "The CRUSH rule behind it" \
  "Default rule: take 'root default', pick N distinct items of type 'osd'. In production this step says 'host' (or 'rack'), so replicas never share a machine."
run ceph osd crush rule dump replicated_rule
run ceph osd crush tree

step "Why not failure domain 'host' here? Ask CRUSH." \
  "Create a temporary host-level rule and simulate 1024 placements with crushtool. With one host, CRUSH can't find 3 distinct hosts, so every mapping is short (bad)."
ceph osd crush rule rm by-host >/dev/null 2>&1 || true
run ceph osd crush rule create-replicated by-host default host
rule_id="$(admin bash -c "ceph osd crush rule dump by-host --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"rule_id\"])'")"
admin bash -c "ceph osd getcrushmap -o /tmp/crushmap 2>/dev/null"
run admin bash -c "crushtool -i /tmp/crushmap --test --rule $rule_id --num-rep 3 --min-x 0 --max-x 1023 --show-bad-mappings 2>&1 | head -3; echo '...'; crushtool -i /tmp/crushmap --test --rule $rule_id --num-rep 3 --min-x 0 --max-x 1023 --show-bad-mappings 2>&1 | wc -l | xargs echo 'bad mappings:'"
run admin bash -c "crushtool -i /tmp/crushmap --test --rule 0 --num-rep 3 --min-x 0 --max-x 1023 --show-bad-mappings 2>&1 | wc -l | xargs echo 'bad mappings with the osd rule (replicated_rule):'"
run ceph osd crush rule rm by-host
ok "placement demo complete"
