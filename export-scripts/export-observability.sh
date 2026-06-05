#!/usr/bin/env bash
# Observability — CloudWatch logs, alarms, dashboards
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-observability.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/logs-log-groups.json"    logs describe-log-groups
safe_aws_json "${OUT_DIR}/raw/logs-metric-filters.json" logs describe-metric-filters

safe_aws_json "${OUT_DIR}/raw/cloudwatch-alarms.json" \
  cloudwatch describe-alarms --alarm-types MetricAlarm CompositeAlarm
safe_aws_json "${OUT_DIR}/raw/cloudwatch-anomaly-detectors.json" \
  cloudwatch describe-anomaly-detectors
safe_aws_json "${OUT_DIR}/raw/cloudwatch-dashboards.json" cloudwatch list-dashboards

dashboard_names="$(jq -r '.DashboardEntries[]?.DashboardName // empty' \
  "${OUT_DIR}/raw/cloudwatch-dashboards.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/cloudwatch-dashboard-bodies.ndjson"
while IFS= read -r dashboard; do
  [[ -z "$dashboard" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" cloudwatch get-dashboard \
    --dashboard-name "$dashboard" 2>/dev/null | \
    jq -c --arg name "$dashboard" '{dashboard_name:$name, data:.}' \
    >> "${OUT_DIR}/raw/cloudwatch-dashboard-bodies.ndjson" || true
done <<< "$dashboard_names"
