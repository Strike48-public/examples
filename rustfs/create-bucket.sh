#!/bin/sh
# Create the example S3 buckets on rustfs with nothing but curl + openssl
# (AWS Signature V4 "PutBucket"). Avoids the MinIO client (mc), which is AGPL.
set -eu

HOST="rustfs:9000"
BUCKETS="${BUCKETS:-studio forge-data strike-construct-kv strike-construct-fs}"
ACCESS_KEY="${S3_ACCESS_KEY}"
SECRET_KEY="${S3_SECRET_KEY}"
REGION="${S3_REGION:-us-east-1}"
SERVICE="s3"

# Wait for rustfs to accept connections.
i=0
until curl -s -o /dev/null --max-time 2 "http://$HOST/"; do
  i=$((i + 1))
  [ "$i" -ge 60 ] && { echo "create-bucket: rustfs unreachable at $HOST" >&2; exit 1; }
  sleep 1
done

sha256() { openssl dgst -sha256 | sed 's/^.*= //'; }
hmac()   { openssl dgst -sha256 -mac HMAC -macopt "$1" | sed 's/^.*= //'; }

create_bucket() {
  bucket="$1"
  amzdate="$(date -u +%Y%m%dT%H%M%SZ)"
  datestamp="$(date -u +%Y%m%d)"
  empty_hash="$(printf '' | sha256)"

  canonical_request="PUT
/$bucket

host:$HOST
x-amz-content-sha256:$empty_hash
x-amz-date:$amzdate

host;x-amz-content-sha256;x-amz-date
$empty_hash"

  scope="$datestamp/$REGION/$SERVICE/aws4_request"
  string_to_sign="AWS4-HMAC-SHA256
$amzdate
$scope
$(printf '%s' "$canonical_request" | sha256)"

  k_date="$(printf '%s' "$datestamp"    | hmac "key:AWS4$SECRET_KEY")"
  k_region="$(printf '%s' "$REGION"     | hmac "hexkey:$k_date")"
  k_service="$(printf '%s' "$SERVICE"   | hmac "hexkey:$k_region")"
  k_signing="$(printf '%s' aws4_request | hmac "hexkey:$k_service")"
  signature="$(printf '%s' "$string_to_sign" | hmac "hexkey:$k_signing")"

  auth="AWS4-HMAC-SHA256 Credential=$ACCESS_KEY/$scope, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=$signature"

  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "http://$HOST/$bucket" \
    -H "Host: $HOST" -H "x-amz-date: $amzdate" \
    -H "x-amz-content-sha256: $empty_hash" -H "Authorization: $auth")"

  case "$code" in
    200 | 409) echo "create-bucket: bucket '$bucket' ready (HTTP $code)" ;;
    *) echo "create-bucket: '$bucket' failed (HTTP $code)" >&2; return 1 ;;
  esac
}

for b in $BUCKETS; do create_bucket "$b"; done
