#!/usr/bin/env bash
# Config & secrets — Secrets Manager metadata, SSM Parameters (+ values with --with-secret-values)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-secrets.sh [--region R] [--profile P] [--with-secret-values]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/secretsmanager-list-secrets.json" secretsmanager list-secrets
sm_secret_ids="$(jq -r '.SecretList[]?.ARN // empty' \
  "${OUT_DIR}/raw/secretsmanager-list-secrets.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/secretsmanager-secret-details.ndjson"
: > "${OUT_DIR}/raw/secretsmanager-secret-versions.ndjson"
: > "${OUT_DIR}/raw/secretsmanager-secret-policies.ndjson"
while IFS= read -r secret_id; do
  [[ -z "$secret_id" ]] && continue
  aws "${AWS_ARGS[@]}" secretsmanager describe-secret \
    --secret-id "$secret_id" 2>/dev/null | \
    jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/secretsmanager-secret-details.ndjson" || true
  aws "${AWS_ARGS[@]}" secretsmanager list-secret-version-ids \
    --secret-id "$secret_id" 2>/dev/null | \
    jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/secretsmanager-secret-versions.ndjson" || true
  if sm_policy_out="$(aws "${AWS_ARGS[@]}" secretsmanager get-resource-policy \
      --secret-id "$secret_id" 2>/dev/null)"; then
    echo "$sm_policy_out" | jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' \
      >> "${OUT_DIR}/raw/secretsmanager-secret-policies.ndjson"
  fi
done <<< "$sm_secret_ids"

safe_aws_json "${OUT_DIR}/raw/ssm-describe-parameters.json" ssm describe-parameters

if [[ "$WITH_SECRET_VALUES" == "true" ]]; then
  echo "  Exporting secret and parameter values..." >&2
  : > "${OUT_DIR}/raw/secretsmanager-secret-values.ndjson"
  while IFS= read -r secret_id; do
    [[ -z "$secret_id" ]] && continue
    aws "${AWS_ARGS[@]}" secretsmanager get-secret-value \
      --secret-id "$secret_id" 2>/dev/null | jq -c '.' \
      >> "${OUT_DIR}/raw/secretsmanager-secret-values.ndjson" || true
  done <<< "$sm_secret_ids"

  param_names="$(jq -r '.Parameters[]?.Name // empty' \
    "${OUT_DIR}/raw/ssm-describe-parameters.json")"
  : > "${OUT_DIR}/raw/ssm-parameter-values.ndjson"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    aws "${AWS_ARGS[@]}" ssm get-parameter --name "$name" \
      --with-decryption 2>/dev/null | jq -c '.' \
      >> "${OUT_DIR}/raw/ssm-parameter-values.ndjson" || true
  done <<< "$param_names"
fi
