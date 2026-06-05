#!/usr/bin/env bash
# Broad inventory — Resource Explorer, tagging API
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-inventory.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/resourcegroupstaggingapi-get-resources.json" \
  resourcegroupstaggingapi get-resources

safe_aws_json "${OUT_DIR}/raw/resource-explorer-2-list-views.json" \
  resource-explorer-2 list-views

local_view_arn="$(jq -r 'first((.Views // [])[]? | if type == "object" then .ViewArn // empty else . end)' \
  "${OUT_DIR}/raw/resource-explorer-2-list-views.json" 2>/dev/null || true)"
if [[ -n "$local_view_arn" && "$local_view_arn" != "null" ]]; then
  safe_aws_json "${OUT_DIR}/raw/resource-explorer-2-search.json" \
    resource-explorer-2 search --view-arn "$local_view_arn" --query-string "*"
fi
