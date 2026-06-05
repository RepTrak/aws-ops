#!/usr/bin/env bash
# DNS — Route53 global (skip with --skip-globals) + Route53 Resolver (always)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-route53.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── Route53 global ────────────────────────────────────────────────────────────
if [[ "$SKIP_GLOBALS" != "true" ]]; then
  safe_aws_json "${OUT_DIR}/raw/route53-hosted-zones.json" route53 list-hosted-zones
  hz_ids="$(jq -r '.HostedZones[]?.Id // empty' \
    "${OUT_DIR}/raw/route53-hosted-zones.json" | sed 's#^/hostedzone/##')"
  : > "${OUT_DIR}/raw/route53-record-sets.ndjson"
  : > "${OUT_DIR}/raw/route53-hosted-zone-details.ndjson"
  while IFS= read -r hz; do
    [[ -z "$hz" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53 list-resource-record-sets --hosted-zone-id "$hz" 2>/dev/null | \
      jq -c --arg hz "$hz" '{hosted_zone_id:$hz, data:.}' \
      >> "${OUT_DIR}/raw/route53-record-sets.ndjson" || true
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53 get-hosted-zone --id "$hz" 2>/dev/null | \
      jq -c --arg hz "$hz" '{hosted_zone_id:$hz, data:.}' \
      >> "${OUT_DIR}/raw/route53-hosted-zone-details.ndjson" || true
  done <<< "$hz_ids"

  safe_aws_json "${OUT_DIR}/raw/route53-health-checks.json"           route53 list-health-checks
  safe_aws_json "${OUT_DIR}/raw/route53-traffic-policies.json"        route53 list-traffic-policies
  safe_aws_json "${OUT_DIR}/raw/route53-traffic-policy-instances.json" route53 list-traffic-policy-instances
  : > "${OUT_DIR}/raw/route53-traffic-policy-versions.ndjson"
  while IFS= read -r tp_info; do
    [[ -z "$tp_info" ]] && continue
    tp_id="$(echo "$tp_info" | cut -d'|' -f1)"
    tp_ver="$(echo "$tp_info" | cut -d'|' -f2)"
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53 get-traffic-policy \
      --id "$tp_id" --version "$tp_ver" 2>/dev/null | \
      jq -c --arg id "$tp_id" '{traffic_policy_id:$id, data:.}' \
      >> "${OUT_DIR}/raw/route53-traffic-policy-versions.ndjson" || true
  done < <(jq -r '.TrafficPolicySummaries[]? | [.Id, (.LatestVersion | tostring)] | join("|")' \
    "${OUT_DIR}/raw/route53-traffic-policies.json" 2>/dev/null || true)
fi

# ── Route53 Resolver (regional — always captured) ─────────────────────────────
safe_aws_json "${OUT_DIR}/raw/r53resolver-endpoints.json" route53resolver list-resolver-endpoints
resolver_ep_ids="$(jq -r '.ResolverEndpoints[]?.Id // empty' \
  "${OUT_DIR}/raw/r53resolver-endpoints.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/r53resolver-endpoint-details.ndjson"
: > "${OUT_DIR}/raw/r53resolver-endpoint-ip-addresses.ndjson"
while IFS= read -r ep_id; do
  [[ -z "$ep_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53resolver get-resolver-endpoint \
    --resolver-endpoint-id "$ep_id" 2>/dev/null | \
    jq -c --arg id "$ep_id" '{endpoint_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/r53resolver-endpoint-details.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53resolver list-resolver-endpoint-ip-addresses \
    --resolver-endpoint-id "$ep_id" 2>/dev/null | \
    jq -c --arg id "$ep_id" '{endpoint_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/r53resolver-endpoint-ip-addresses.ndjson" || true
done <<< "$resolver_ep_ids"

safe_aws_json "${OUT_DIR}/raw/r53resolver-rules.json" route53resolver list-resolver-rules
resolver_rule_ids="$(jq -r '.ResolverRules[]?.Id // empty' \
  "${OUT_DIR}/raw/r53resolver-rules.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/r53resolver-rule-details.ndjson"
while IFS= read -r rule_id; do
  [[ -z "$rule_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" route53resolver get-resolver-rule \
    --resolver-rule-id "$rule_id" 2>/dev/null | \
    jq -c --arg id "$rule_id" '{rule_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/r53resolver-rule-details.ndjson" || true
done <<< "$resolver_rule_ids"
safe_aws_json "${OUT_DIR}/raw/r53resolver-rule-associations.json" \
  route53resolver list-resolver-rule-associations
