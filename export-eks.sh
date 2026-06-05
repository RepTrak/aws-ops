#!/usr/bin/env bash
# Snapshot EKS clusters, node groups, and Fargate profiles for an existing snapshot folder.
#
# Usage:
#   OUT_DIR=snapshots/2026-06-05T00-17-42Z-eu-west-1 ./export-eks.sh
#   OUT_DIR=snapshots/... ./export-eks.sh --region eu-west-1 --profile prod
#
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)  REGION="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Validate OUT_DIR ──────────────────────────────────────────────────────────
if [[ -z "${OUT_DIR:-}" ]]; then
  echo "ERROR: OUT_DIR is not set. Example:" >&2
  echo "  OUT_DIR=snapshots/2026-06-05T00-17-42Z-eu-west-1 ./export-eks.sh" >&2
  exit 1
fi

if [[ ! -d "$OUT_DIR/raw" ]]; then
  echo "ERROR: $OUT_DIR/raw does not exist — is OUT_DIR pointing at a valid snapshot folder?" >&2
  exit 1
fi

# ── AWS CLI args ──────────────────────────────────────────────────────────────
AWS_ARGS=(--output json)
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")

# Determine region: explicit flag → manifest.json → CLI default
if [[ -z "$REGION" && -f "$OUT_DIR/manifest.json" ]]; then
  REGION="$(jq -r '.region // empty' "$OUT_DIR/manifest.json" 2>/dev/null || true)"
fi
[[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")

# ── Timeout command ───────────────────────────────────────────────────────────
_TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_CMD="gtimeout 90"
elif command -v timeout  >/dev/null 2>&1; then _TIMEOUT_CMD="timeout 90"
fi

echo "[$(date '+%H:%M:%S')] Exporting EKS data to: $OUT_DIR"
echo "[$(date '+%H:%M:%S')] Region: ${REGION:-<CLI default>}  Profile: ${PROFILE:-<default>}"

# ── EKS clusters ──────────────────────────────────────────────────────────────
echo "→ ${OUT_DIR}/raw/eks-clusters.json"
if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" eks list-clusters \
    > "${OUT_DIR}/raw/eks-clusters.json" 2>/dev/null; then
  true
else
  echo '{}' > "${OUT_DIR}/raw/eks-clusters.json"
  echo "WARN: eks list-clusters failed" >&2
fi

eks_cluster_names="$(jq -r '.clusters[]? // empty' "${OUT_DIR}/raw/eks-clusters.json" 2>/dev/null || true)"
echo "  Found clusters: $(echo "$eks_cluster_names" | grep -c . || true)"

echo "→ ${OUT_DIR}/raw/eks-cluster-details.ndjson"
: > "${OUT_DIR}/raw/eks-cluster-details.ndjson"
echo "→ ${OUT_DIR}/raw/eks-nodegroups.ndjson"
: > "${OUT_DIR}/raw/eks-nodegroups.ndjson"
echo "→ ${OUT_DIR}/raw/eks-fargate-profiles.ndjson"
: > "${OUT_DIR}/raw/eks-fargate-profiles.ndjson"

_eks_tmp=$(mktemp)
while IFS= read -r cluster; do
  [[ -z "$cluster" ]] && continue
  echo "  eks: $cluster" >&2

  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" eks describe-cluster \
      --name "$cluster" > "$_eks_tmp" 2>/dev/null; then
    jq -c --arg name "$cluster" '{cluster_name:$name, data:.}' "$_eks_tmp" \
      >> "${OUT_DIR}/raw/eks-cluster-details.ndjson" || true
  fi

  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" eks list-nodegroups \
      --cluster-name "$cluster" > "$_eks_tmp" 2>/dev/null; then
    jq -c --arg name "$cluster" '{cluster_name:$name, data:.}' "$_eks_tmp" \
      >> "${OUT_DIR}/raw/eks-nodegroups.ndjson" || true
  fi

  if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" eks list-fargate-profiles \
      --cluster-name "$cluster" > "$_eks_tmp" 2>/dev/null; then
    jq -c --arg name "$cluster" '{cluster_name:$name, data:.}' "$_eks_tmp" \
      >> "${OUT_DIR}/raw/eks-fargate-profiles.ndjson" || true
  fi
done <<< "$eks_cluster_names"
rm -f "$_eks_tmp"

echo "[$(date '+%H:%M:%S')] Done. Re-run derive-topology.sh to rebuild derived files:"
echo "  OUT_DIR=$OUT_DIR ./derive-topology.sh"
