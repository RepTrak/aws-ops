#!/usr/bin/env bash
# ECR repositories, images, scanning config
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-ecr.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/ecr-repositories.json" ecr describe-repositories
safe_aws_json "${OUT_DIR}/raw/ecr-registry-scanning-config.json" ecr get-registry-scanning-configuration

repo_names="$(jq -r '.repositories[]?.repositoryName // empty' \
  "${OUT_DIR}/raw/ecr-repositories.json" 2>/dev/null || true)"
repo_count="$(echo "$repo_names" | grep -c . || true)"
echo "→ ${OUT_DIR}/raw/ecr-repository-policies.ndjson"
: > "${OUT_DIR}/raw/ecr-repository-policies.ndjson"
echo "→ ${OUT_DIR}/raw/ecr-lifecycle-policies.ndjson"
: > "${OUT_DIR}/raw/ecr-lifecycle-policies.ndjson"
echo "→ ${OUT_DIR}/raw/ecr-images.ndjson (${repo_count} repos)"
: > "${OUT_DIR}/raw/ecr-images.ndjson"

_ecr_tmp=$(mktemp)
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  echo "  ecr: $repo" >&2
  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr get-repository-policy \
      --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
    jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" \
      >> "${OUT_DIR}/raw/ecr-repository-policies.ndjson"
  fi
  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr get-lifecycle-policy \
      --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
    jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" \
      >> "${OUT_DIR}/raw/ecr-lifecycle-policies.ndjson"
  fi
  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr describe-images \
      --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
    jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" \
      >> "${OUT_DIR}/raw/ecr-images.ndjson"
  fi
done <<< "$repo_names"
rm -f "$_ecr_tmp"
