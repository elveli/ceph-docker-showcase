#!/usr/bin/env bash
# Demo: object storage through the RADOS Gateway (RGW) with stock AWS CLI v2.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

BUCKET=showcase
KEY=sample.bin
SIZE_MIB=24

# AWS CLI in a throwaway container on the cluster network. Credentials are
# passed by name (-e VAR) so they never appear on a command line.
s3() { compose --progress quiet run --rm -T -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY s3 "$@"; }
s3sh() { compose --progress quiet run --rm -T -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY --entrypoint bash s3 -c "$1"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

banner "Demo · Object storage (RGW, S3 API)"
cat <<'EOF'
  RGW is a stateless HTTP gateway that speaks the S3 (and Swift) API and
  stores everything as RADOS objects in ordinary Ceph pools. Think of it as
  a self-hosted S3 endpoint: the client below is the unmodified AWS CLI.
EOF
require_cluster

step "Create an S3 user (idempotent)" \
  "radosgw-admin writes users straight into RADOS; no RGW API call needed. Like creating an IAM user with an access key."
if admin radosgw-admin user info --uid=demo >/dev/null 2>&1; then
  ok "user 'demo' already exists"
else
  run admin radosgw-admin user create --uid=demo --display-name="Showcase demo user" >/dev/null
  ok "user 'demo' created"
fi
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY < <(
  admin bash -c "radosgw-admin user info --uid=demo | python3 -c 'import json,sys; k=json.load(sys.stdin)[\"keys\"][0]; print(k[\"access_key\"], k[\"secret_key\"])'"
)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
printf '    access key: %s   secret: %s…\n' "$AWS_ACCESS_KEY_ID" "${AWS_SECRET_ACCESS_KEY:0:4}"

step "Create bucket s3://$BUCKET" "Plain 'aws s3 mb' against the RGW endpoint (AWS_ENDPOINT_URL=http://rgw:7480)."
if s3 s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  ok "bucket already exists"
else
  run s3 s3 mb "s3://$BUCKET"
fi
run s3 s3 ls

step "Generate ${SIZE_MIB} MiB of random data and upload it" \
  "Above 8 MiB the AWS CLI switches to multipart upload, so this also exercises CreateMultipartUpload/UploadPart/Complete."
run s3sh "head -c $((SIZE_MIB * 1024 * 1024)) /dev/urandom > /work/$KEY && sha256sum /work/$KEY | tee /work/$KEY.sha256"
src_sum="$(s3sh "cut -d' ' -f1 /work/$KEY.sha256")"
run s3 s3 cp "/work/$KEY" "s3://$BUCKET/$KEY" --metadata origin=ceph-showcase --no-progress

step "Exercise more of the S3 API" "ListObjectsV2, HeadObject (note the multipart ETag suffix and user metadata), object tagging."
run s3 s3api list-objects-v2 --bucket "$BUCKET" --query 'Contents[].{Key:Key,Size:Size,ETag:ETag}' --output table
run s3 s3api head-object --bucket "$BUCKET" --key "$KEY" --query '{ETag:ETag,Length:ContentLength,Metadata:Metadata}'
run s3 s3api put-object-tagging --bucket "$BUCKET" --key "$KEY" --tagging 'TagSet=[{Key=demo,Value=object}]'
run s3 s3api get-object-tagging --bucket "$BUCKET" --key "$KEY"

step "Download through the S3 API and verify the checksum"
run s3 s3 cp "s3://$BUCKET/$KEY" "/work/$KEY.downloaded" --no-progress
dl_sum="$(s3sh "sha256sum /work/$KEY.downloaded | cut -d' ' -f1")"
printf '    uploaded   %s\n    downloaded %s\n' "$src_sum" "$dl_sum"
[[ -n "$src_sum" && "$src_sum" == "$dl_sum" ]] || die "checksum mismatch"
ok "SHA-256 matches"

step "Presigned URL, fetched from the Mac with plain curl" \
  "SigV4 presigning works as on AWS. The URL is signed for localhost:$RGW_PORT, the port Compose publishes RGW on."
url="$(s3 s3 presign "s3://$BUCKET/$KEY" --expires-in 300 --endpoint-url "http://localhost:$RGW_PORT")"
printf '    %s…\n' "${url:0:110}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsS -o "$tmp" "$url"
host_sum="$(sha256 "$tmp" | cut -d' ' -f1)"
[[ "$host_sum" == "$src_sum" ]] || die "presigned download checksum mismatch"
ok "host download via presigned URL matches ($host_sum)"

step "What RADOS actually stores" \
  "The S3 object is striped into RADOS objects in the default.rgw.buckets.data pool: a head object plus multipart parts."
run admin bash -c "rados -p default.rgw.buckets.data ls | grep -F '$KEY' | sort | head -8"
run admin bash -c "rados -p default.rgw.buckets.data ls | grep -cF '$KEY'"
run ceph df

s3sh "rm -f /work/$KEY.downloaded"
ok "object demo complete"
