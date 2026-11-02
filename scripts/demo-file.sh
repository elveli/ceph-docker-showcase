#!/usr/bin/env bash
# Demo: CephFS shared filesystem, mounted with ceph-fuse on two client
# containers. The kernel CephFS client is tested and fails on LinuxKit.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

FS=cephfs
MNT=/mnt/cephfs
KEYRING=/run/ceph.client.demo.keyring
DATA_POOL="cephfs.$FS.data"

unmount_all() {
  local c
  for c in client-a client-b; do
    on_q "$c" "if mountpoint -q $MNT; then fusermount3 -u $MNT || umount -l $MNT; fi" >/dev/null 2>&1 || true
  done
}

banner "Demo · Shared filesystem (CephFS)"
cat <<'EOF'
  CephFS is a POSIX filesystem: file data lives in a RADOS pool, while the
  MDS (metadata server) owns the namespace (directories, inodes, permissions)
  and hands out capabilities so clients cache safely. Closest AWS analogue: EFS.
EOF
require_cluster
ensure_clients
trap unmount_all EXIT

step "Create the filesystem (idempotent)" \
  "'ceph fs volume create' makes a metadata pool and a data pool and registers the filesystem. With no orchestrator it deploys no MDS itself; our standalone 'mds' container picks up rank 0."
if ceph fs ls --format json | grep -q "\"name\":\"$FS\""; then
  ok "filesystem '$FS' already exists"
else
  run ceph fs volume create "$FS"
fi
wait_for "MDS rank 0 active" 120 bash -c "docker compose exec -T mon-a ceph mds stat | grep -q '$FS:1 .*up:active'"
run ceph fs status "$FS"

step "Create a least-privilege client identity" \
  "'ceph fs authorize' issues a cephx key that can only read/write this filesystem, like an IAM policy scoped to one EFS access point. The admin key never leaves the cluster."
if ! ceph auth get client.demo >/dev/null 2>&1; then
  ceph fs authorize "$FS" client.demo / rw >/dev/null
fi
keyring="$(ceph auth get client.demo)"
for c in client-a client-b; do
  printf '%s\n' "$keyring" | compose exec -T "$c" bash -c "umask 077 && cat > $KEYRING"
done
run admin bash -c "ceph auth get client.demo | grep -v key"

step "Try the kernel client: mount -t ceph" \
  "LinuxKit has no CephFS kernel module (no 'ceph' in /proc/filesystems), so this is expected to fail."
unmount_all
if on_q client-a "mkdir -p $MNT && mount -t ceph :/ $MNT -o name=demo" >/dev/null 2>&1; then
  warn "kernel CephFS mount worked on this host; unmounting and continuing with ceph-fuse"
  on_q client-a "umount $MNT"
else
  on client-a "grep -c ceph /proc/filesystems || true; mount -t ceph :/ $MNT -o name=demo 2>&1 || true"
  ok "kernel CephFS client unavailable here, as expected"
fi

step "Mount with ceph-fuse on both clients" \
  "ceph-fuse is the userspace CephFS client (libcephfs + FUSE). FUSE is built into LinuxKit; the containers are privileged to open /dev/fuse."
for c in client-a client-b; do
  on "$c" "mkdir -p $MNT && ceph-fuse --id demo -k $KEYRING $MNT >/dev/null 2>&1 && df -h $MNT | tail -1"
done

step "client-a writes, client-b reads" "Two separate containers, one namespace. The MDS keeps their caches coherent."
on client-a "rm -rf $MNT/shared && mkdir -p $MNT/shared && echo 'hello from client-a' > $MNT/shared/notes.txt && head -c 8M /dev/urandom > $MNT/shared/blob.bin && sync"
sum_a="$(on_q client-a "sha256sum $MNT/shared/blob.bin | cut -d' ' -f1")"
on client-b "ls -l $MNT/shared && cat $MNT/shared/notes.txt"
sum_b="$(on_q client-b "sha256sum $MNT/shared/blob.bin | cut -d' ' -f1")"
printf '    blob.bin on client-a %s\n    blob.bin on client-b %s\n' "$sum_a" "$sum_b"
[[ -n "$sum_a" && "$sum_a" == "$sum_b" ]] || die "clients see different data"
ok "both clients see identical data"

step "client-b appends, client-a sees it immediately"
on client-b "echo 'reply from client-b' >> $MNT/shared/notes.txt"
on client-a "cat $MNT/shared/notes.txt"
on_q client-a "grep -q 'reply from client-b' $MNT/shared/notes.txt" || die "client-a did not see client-b's write"
ok "write from client-b visible on client-a"

step "Where the file data lives" \
  "Each file is striped into 4 MiB RADOS objects named <inode-hex>.<index> in the data pool. The layout is exposed as a virtual xattr."
on client-a "getfattr --absolute-names -n ceph.file.layout $MNT/shared/blob.bin"
ino_hex="$(on_q client-a "printf '%x' \$(stat -c %i $MNT/shared/blob.bin)")"
run admin bash -c "rados -p $DATA_POOL ls | grep '^$ino_hex\\.' | sort"

step "The MDS view: who is connected"
run ceph fs status "$FS"

unmount_all
trap - EXIT
ok "file demo complete (data kept under /shared; remount with: docker compose exec client-a ceph-fuse --id demo -k $KEYRING $MNT)"
