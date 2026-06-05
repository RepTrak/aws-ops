#!/usr/bin/env bash
# Cache & search — ElastiCache, MemoryDB, OpenSearch
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-cache.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/elasticache-replication-groups.json" elasticache describe-replication-groups
safe_aws_json "${OUT_DIR}/raw/elasticache-cache-clusters.json"     elasticache describe-cache-clusters --show-cache-node-info
safe_aws_json "${OUT_DIR}/raw/elasticache-serverless-caches.json"  elasticache describe-serverless-caches
safe_aws_json "${OUT_DIR}/raw/elasticache-users.json"              elasticache describe-users
safe_aws_json "${OUT_DIR}/raw/elasticache-user-groups.json"        elasticache describe-user-groups
safe_aws_json "${OUT_DIR}/raw/elasticache-subnet-groups.json"      elasticache describe-cache-subnet-groups
safe_aws_json "${OUT_DIR}/raw/elasticache-parameter-groups.json"   elasticache describe-cache-parameter-groups
safe_aws_json "${OUT_DIR}/raw/elasticache-snapshots.json"          elasticache describe-snapshots

ec_pg_names="$(jq -r '.CacheParameterGroups[]?.CacheParameterGroupName // empty' \
  "${OUT_DIR}/raw/elasticache-parameter-groups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/elasticache-parameter-group-contents.ndjson"
while IFS= read -r pg; do
  [[ -z "$pg" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" elasticache describe-cache-parameters \
    --cache-parameter-group-name "$pg" 2>/dev/null | \
    jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' \
    >> "${OUT_DIR}/raw/elasticache-parameter-group-contents.ndjson" || true
done <<< "$ec_pg_names"

safe_aws_json "${OUT_DIR}/raw/memorydb-clusters.json"       memorydb describe-clusters
safe_aws_json "${OUT_DIR}/raw/memorydb-users.json"          memorydb describe-users
safe_aws_json "${OUT_DIR}/raw/memorydb-acls.json"           memorydb describe-acls
safe_aws_json "${OUT_DIR}/raw/memorydb-subnet-groups.json"  memorydb describe-subnet-groups

safe_aws_json "${OUT_DIR}/raw/opensearch-domains.json" opensearch list-domain-names
os_domain_names="$(jq -r '.DomainNames[]?.DomainName // empty' \
  "${OUT_DIR}/raw/opensearch-domains.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/opensearch-domain-details.ndjson"
while IFS= read -r domain; do
  [[ -z "$domain" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" opensearch describe-domain --domain-name "$domain" 2>/dev/null | \
    jq -c --arg d "$domain" '{domain_name:$d, data:.}' \
    >> "${OUT_DIR}/raw/opensearch-domain-details.ndjson" || true
done <<< "$os_domain_names"
