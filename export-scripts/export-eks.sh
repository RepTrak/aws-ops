#!/usr/bin/env bash
# EKS clusters, node groups, Fargate profiles
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-eks.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/eks-clusters.json" eks list-clusters
eks_cluster_names="$(jq -r '.clusters[]? // empty' "${OUT_DIR}/raw/eks-clusters.json" 2>/dev/null || true)"
echo "  Found EKS clusters: $(echo "$eks_cluster_names" | grep -c . || true)"

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
