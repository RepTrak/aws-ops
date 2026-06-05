#!/usr/bin/env bash
# Storage — EFS + S3 (S3 is global, skipped with --skip-globals)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-storage.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── EFS ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/efs-file-systems.json" efs describe-file-systems
efs_ids="$(jq -r '.FileSystems[]?.FileSystemId // empty' \
  "${OUT_DIR}/raw/efs-file-systems.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/efs-mount-targets.ndjson"
: > "${OUT_DIR}/raw/efs-access-points.ndjson"
: > "${OUT_DIR}/raw/efs-mount-target-sgs.ndjson"
while IFS= read -r fs; do
  [[ -z "$fs" ]] && continue
  mt_out="$(aws "${AWS_ARGS[@]}" efs describe-mount-targets \
    --file-system-id "$fs" 2>/dev/null)" || mt_out="{}"
  [[ -z "$mt_out" ]] && mt_out="{}"
  echo "$mt_out" | jq -c --arg fs "$fs" '{file_system_id:$fs, data:.}' \
    >> "${OUT_DIR}/raw/efs-mount-targets.ndjson"
  while IFS= read -r mt_id; do
    [[ -z "$mt_id" ]] && continue
    aws "${AWS_ARGS[@]}" efs describe-mount-target-security-groups \
      --mount-target-id "$mt_id" 2>/dev/null | \
      jq -c --arg mt "$mt_id" --arg fs "$fs" \
        '{mount_target_id:$mt, file_system_id:$fs, data:.}' \
      >> "${OUT_DIR}/raw/efs-mount-target-sgs.ndjson" || true
  done < <(echo "$mt_out" | jq -r '.MountTargets[]?.MountTargetId // empty')
  aws "${AWS_ARGS[@]}" efs describe-access-points \
    --file-system-id "$fs" 2>/dev/null | \
    jq -c --arg fs "$fs" '{file_system_id:$fs, data:.}' \
    >> "${OUT_DIR}/raw/efs-access-points.ndjson" || true
done <<< "$efs_ids"

# ── S3 (global — skip in multi-region mode) ───────────────────────────────────
if [[ "$SKIP_GLOBALS" != "true" ]]; then
  safe_aws_json "${OUT_DIR}/raw/s3-buckets.json" s3api list-buckets
  s3_bucket_names="$(jq -r '.Buckets[]?.Name // empty' \
    "${OUT_DIR}/raw/s3-buckets.json" 2>/dev/null || true)"
  s3_bucket_count="$(echo "$s3_bucket_names" | grep -c . || true)"
  echo "→ ${OUT_DIR}/raw/s3-bucket-details.ndjson (${s3_bucket_count} buckets)"
  : > "${OUT_DIR}/raw/s3-bucket-details.ndjson"
  s3_bucket_idx=0
  while IFS= read -r bucket; do
    [[ -z "$bucket" ]] && continue
    s3_bucket_idx=$((s3_bucket_idx + 1))
    echo "  s3 (${s3_bucket_idx}/${s3_bucket_count}): $bucket" >&2
    s3_location="$(aws "${BASE_AWS_ARGS[@]}" s3api get-bucket-location \
      --bucket "$bucket" 2>/dev/null)" || s3_location="{}"
    [[ -z "$s3_location" ]] && s3_location="{}"
    bucket_region="$(echo "$s3_location" | jq -r '.LocationConstraint // "us-east-1"')"
    BUCKET_ARGS=("${BASE_AWS_ARGS[@]}" --region "$bucket_region")
    s3_versioning="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-versioning \
      --bucket "$bucket" 2>/dev/null)" || s3_versioning="{}"
    [[ -z "$s3_versioning" ]] && s3_versioning="{}"
    s3_public_access="$(aws "${BUCKET_ARGS[@]}" s3api get-public-access-block \
      --bucket "$bucket" 2>/dev/null)" || s3_public_access="{}"
    [[ -z "$s3_public_access" ]] && s3_public_access="{}"
    s3_notifications="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-notification-configuration \
      --bucket "$bucket" 2>/dev/null)" || s3_notifications="{}"
    [[ -z "$s3_notifications" ]] && s3_notifications="{}"
    s3_encryption="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-encryption \
      --bucket "$bucket" 2>/dev/null)" || s3_encryption="{}"
    [[ -z "$s3_encryption" ]] && s3_encryption="{}"
    s3_policy="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-policy \
      --bucket "$bucket" 2>/dev/null)" || s3_policy="{}"
    [[ -z "$s3_policy" ]] && s3_policy="{}"
    s3_lifecycle="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-lifecycle-configuration \
      --bucket "$bucket" 2>/dev/null)" || s3_lifecycle="{}"
    [[ -z "$s3_lifecycle" ]] && s3_lifecycle="{}"
    s3_cors="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-cors \
      --bucket "$bucket" 2>/dev/null)" || s3_cors="{}"
    [[ -z "$s3_cors" ]] && s3_cors="{}"
    jq -cn \
      --arg bucket "$bucket" \
      --argjson location "$s3_location" \
      --argjson versioning "$s3_versioning" \
      --argjson encryption "$s3_encryption" \
      --argjson public_access "$s3_public_access" \
      --argjson policy "$s3_policy" \
      --argjson lifecycle "$s3_lifecycle" \
      --argjson cors "$s3_cors" \
      --argjson notifications "$s3_notifications" \
      '{bucket_name:$bucket, location:$location, versioning:$versioning,
        encryption:$encryption, public_access:$public_access, policy:$policy,
        lifecycle:$lifecycle, cors:$cors, notifications:$notifications}' \
      >> "${OUT_DIR}/raw/s3-bucket-details.ndjson"
  done <<< "$s3_bucket_names"
fi
