#!/usr/bin/env bash
# Cloud Map / Service Discovery
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-cloudmap.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/servicediscovery-list-namespaces.json" \
  servicediscovery list-namespaces
namespace_ids="$(jq -r '.Namespaces[]?.Id // empty' \
  "${OUT_DIR}/raw/servicediscovery-list-namespaces.json")"
: > "${OUT_DIR}/raw/servicediscovery-namespaces.ndjson"
: > "${OUT_DIR}/raw/servicediscovery-services.ndjson"
: > "${OUT_DIR}/raw/servicediscovery-instances.ndjson"

while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" servicediscovery get-namespace --id "$ns" 2>/dev/null | \
    jq -c --arg ns "$ns" '{namespace_id:$ns, data:.}' \
    >> "${OUT_DIR}/raw/servicediscovery-namespaces.ndjson" || true
done <<< "$namespace_ids"

safe_aws_json "${OUT_DIR}/raw/servicediscovery-list-services.json" \
  servicediscovery list-services
service_ids="$(jq -r '.Services[]?.Id // empty' \
  "${OUT_DIR}/raw/servicediscovery-list-services.json")"

while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" servicediscovery get-service --id "$svc" 2>/dev/null | \
    jq -c --arg svc "$svc" '{service_id:$svc, data:.}' \
    >> "${OUT_DIR}/raw/servicediscovery-services.ndjson" || true
  safe_aws_json "${OUT_DIR}/raw/servicediscovery-list-instances-${svc}.json" \
    servicediscovery list-instances --service-id "$svc"
  jq -c --arg service_id "$svc" '{service_id:$service_id, data:.}' \
    "${OUT_DIR}/raw/servicediscovery-list-instances-${svc}.json" \
    >> "${OUT_DIR}/raw/servicediscovery-instances.ndjson"
done <<< "$service_ids"
