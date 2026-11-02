#!/usr/bin/env bash
# Demo: block storage with RBD. Kernel `rbd map` is tested (and fails on
# Docker Desktop's LinuxKit kernel); rbd-nbd provides a real block device
# through userspace librbd instead.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POOL=rbd
IMAGE=demo-disk
SPEC="$POOL/$IMAGE"
MNT=/mnt/rbd
C=client-a
DEVFILE=/run/demo-disk.dev

# Unmount and unmap whatever a previous (possibly interrupted) run left behind.
# NBD devices belong to the shared VM kernel, so leaking one is worth avoiding.
release_device() {
  on_q "$C" "
    if mountpoint -q $MNT; then umount $MNT; fi
    if [[ -s $DEVFILE ]]; then rbd device unmap -t nbd \$(cat $DEVFILE) 2>/dev/null || true; rm -f $DEVFILE; fi
  " || true
}
map_and_mount() {
  local dev
  dev="$(on_q "$C" "rbd device map -t nbd $SPEC 2>/dev/null")"
  on_q "$C" "echo $dev > $DEVFILE; mkdir -p $MNT"
  printf '%s\n' "$dev"
}

banner "Demo · Block storage (RBD)"
cat <<'EOF'
  RBD images are thin-provisioned block devices striped across 4 MiB RADOS
  objects, the Ceph equivalent of an EBS volume. Clients normally attach
  them with the kernel driver (rbd map) or through librbd (QEMU, rbd-nbd).
EOF
require_cluster
ensure_clients
trap release_device EXIT

step "Create and initialise the '$POOL' pool (idempotent)" \
  "A pool is a namespace with its own replication rule and PG count; 'rbd pool init' tags it for RBD."
if ! ceph osd pool ls | grep -qx "$POOL"; then
  run ceph osd pool create "$POOL"
fi
run admin rbd pool init "$POOL"
run ceph osd pool get "$POOL" size

step "Create a fresh 1 GiB image (re-runs start clean)"
release_device
if admin rbd info "$SPEC" >/dev/null 2>&1; then
  admin rbd snap purge --no-progress "$SPEC" >/dev/null
  admin rbd rm --no-progress "$SPEC" >/dev/null
fi
run admin rbd create "$SPEC" --size 1G
run admin rbd info "$SPEC"

step "Try the kernel client: rbd map" \
  "This is how a Linux host normally attaches RBD. Docker Desktop's LinuxKit kernel is built without the rbd module, so we expect this to fail."
if on_q "$C" "rbd map $SPEC" >/dev/null 2>&1; then
  warn "kernel rbd map worked on this host; unmapping and continuing with rbd-nbd anyway"
  on_q "$C" "rbd unmap $SPEC"
else
  on "$C" "rbd map $SPEC 2>&1 || true" | grep -Ev '^\s*$' || true
  ok "kernel rbd map is unavailable here, as expected (no CONFIG_BLK_DEV_RBD)"
fi

step "Attach it with rbd-nbd instead" \
  "rbd-nbd runs librbd in userspace and exposes the image through the kernel's NBD driver, which LinuxKit does include. Same block device, different transport."
dev="$(map_and_mount)"
ok "mapped $SPEC at $dev"
on "$C" "blockdev --getsize64 $dev | numfmt --to=iec"

step "Make a filesystem and write known data (version 1)"
on "$C" "mkfs.ext4 -q -L demo $dev && mount $dev $MNT"
on "$C" "echo 'version 1: written before the snapshot' > $MNT/state.txt && head -c 32M /dev/urandom > $MNT/payload.bin && sync"
on "$C" "cd $MNT && sha256sum state.txt payload.bin | tee /run/v1.sha256"

step "Thin provisioning" "The image is 1 GiB but only the blocks actually written exist as RADOS objects."
run admin rbd du "$SPEC"
run admin bash -c "rados -p $POOL ls | grep -c rbd_data"

step "Snapshot the image (filesystem frozen for consistency)" \
  "RBD snapshots are instant and copy-on-write. fsfreeze flushes and blocks writes for a moment so the snapshot is application-consistent, like EBS snapshots with a quiesce hook."
on "$C" "fsfreeze -f $MNT && rbd snap create --no-progress $SPEC@v1 && fsfreeze -u $MNT"
run admin rbd snap ls "$SPEC"
v1_export="$(admin bash -c "rbd export --no-progress $SPEC@v1 - | sha256sum | cut -d' ' -f1")"
printf '    sha256 of the whole snapshot (rbd export): %s\n' "$v1_export"

step "Change the data (version 2)" "Overwrite the text file and delete the payload."
on "$C" "echo 'version 2: this should disappear after rollback' > $MNT/state.txt && rm $MNT/payload.bin && sync && ls -l $MNT && cat $MNT/state.txt"

step "Roll back to @v1" "Rollback rewrites the image from the snapshot, so it must not be in use: unmount and unmap first."
release_device
run admin rbd snap rollback --no-progress "$SPEC@v1"

step "Re-attach and verify version 1 is back"
dev="$(map_and_mount)"
on "$C" "mount $dev $MNT && ls -l $MNT && cat $MNT/state.txt"
on "$C" "cd $MNT && sha256sum -c /run/v1.sha256"
after_export="$(admin bash -c "rbd export --no-progress $SPEC@v1 - | sha256sum | cut -d' ' -f1")"
[[ "$after_export" == "$v1_export" ]] || die "snapshot content changed"
ok "files match their pre-snapshot checksums; snapshot export unchanged ($after_export)"

step "Raw librbd throughput with rbd bench" \
  "Pure userspace I/O path, no kernel involved. Numbers reflect a laptop VM writing 3 replicas to sparse files, not real hardware."
admin rbd rm --no-progress "$POOL/bench" >/dev/null 2>&1 || true
run admin rbd create "$POOL/bench" --size 1G
run admin rbd bench --io-type write --io-size 4M --io-total 128M --io-pattern seq "$POOL/bench"
admin rbd rm --no-progress "$POOL/bench" >/dev/null

release_device
trap - EXIT
ok "block demo complete (image $SPEC and snapshot @v1 kept for exploring: make shell → rbd ls -l)"
