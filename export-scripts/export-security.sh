#!/usr/bin/env bash
# Security & governance — KMS, CloudTrail, Config, GuardDuty, SecurityHub, Access Analyzer,
#                         Organizations/SCPs (global, skip with --skip-globals)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-security.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── KMS ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/kms-keys.json"    kms list-keys
safe_aws_json "${OUT_DIR}/raw/kms-aliases.json" kms list-aliases
kms_key_ids="$(jq -r '.Keys[]?.KeyId // empty' \
  "${OUT_DIR}/raw/kms-keys.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/kms-key-details.ndjson"
: > "${OUT_DIR}/raw/kms-key-policies.ndjson"
while IFS= read -r key_id; do
  [[ -z "$key_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" kms describe-key --key-id "$key_id" 2>/dev/null | \
    jq -c --arg id "$key_id" '{key_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/kms-key-details.ndjson" || true
  if kms_policy_out="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" kms get-key-policy \
      --key-id "$key_id" --policy-name default 2>/dev/null)"; then
    echo "$kms_policy_out" | jq -c --arg id "$key_id" '{key_id:$id, data:.}' \
      >> "${OUT_DIR}/raw/kms-key-policies.ndjson"
  fi
done <<< "$kms_key_ids"

# ── CloudTrail ────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/cloudtrail-trails.json" cloudtrail describe-trails
trail_arns="$(jq -r '.trailList[]?.TrailARN // empty' \
  "${OUT_DIR}/raw/cloudtrail-trails.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/cloudtrail-trail-status.ndjson"
: > "${OUT_DIR}/raw/cloudtrail-event-selectors.ndjson"
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" cloudtrail get-trail-status --name "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{trail_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/cloudtrail-trail-status.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" cloudtrail get-event-selectors \
    --trail-name "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{trail_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/cloudtrail-event-selectors.ndjson" || true
done <<< "$trail_arns"

# ── AWS Config ────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/config-recorders.json"        configservice describe-configuration-recorders
safe_aws_json "${OUT_DIR}/raw/config-delivery-channels.json" configservice describe-delivery-channels
safe_aws_json "${OUT_DIR}/raw/config-rules.json"            configservice describe-config-rules

# ── GuardDuty ─────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/guardduty-detectors.json" guardduty list-detectors
gd_ids="$(jq -r '.DetectorIds[]? // empty' \
  "${OUT_DIR}/raw/guardduty-detectors.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/guardduty-detector-details.ndjson"
while IFS= read -r det_id; do
  [[ -z "$det_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" guardduty get-detector --detector-id "$det_id" 2>/dev/null | \
    jq -c --arg id "$det_id" '{detector_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/guardduty-detector-details.ndjson" || true
done <<< "$gd_ids"

# ── Security Hub ──────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/securityhub-hub.json"       securityhub describe-hub
safe_aws_json "${OUT_DIR}/raw/securityhub-standards.json" securityhub list-standards-subscriptions

# ── Access Analyzer ───────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/accessanalyzer-analyzers.json" accessanalyzer list-analyzers
analyzer_arns="$(jq -r '.analyzers[]?.arn // empty' \
  "${OUT_DIR}/raw/accessanalyzer-analyzers.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/accessanalyzer-findings.ndjson"
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" accessanalyzer list-findings \
    --analyzer-arn "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{analyzer_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/accessanalyzer-findings.ndjson" || true
done <<< "$analyzer_arns"

# ── Organizations / SCPs (global — skip in multi-region mode) ─────────────────
if [[ "$SKIP_GLOBALS" != "true" ]]; then
  safe_aws_json "${OUT_DIR}/raw/organizations-organization.json" \
    organizations describe-organization
  safe_aws_json "${OUT_DIR}/raw/organizations-accounts.json" \
    organizations list-accounts
  safe_aws_json "${OUT_DIR}/raw/organizations-scps.json" \
    organizations list-policies --filter SERVICE_CONTROL_POLICY
  scp_ids="$(jq -r '.Policies[]?.Id // empty' \
    "${OUT_DIR}/raw/organizations-scps.json" 2>/dev/null || true)"
  : > "${OUT_DIR}/raw/organizations-scp-details.ndjson"
  while IFS= read -r scp_id; do
    [[ -z "$scp_id" ]] && continue
    scp_policy_out="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" organizations describe-policy \
      --policy-id "$scp_id" 2>/dev/null)" || scp_policy_out="{}"
    [[ -z "$scp_policy_out" ]] && scp_policy_out="{}"
    scp_targets_out="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" organizations list-targets-for-policy \
      --policy-id "$scp_id" 2>/dev/null)" || scp_targets_out="{}"
    [[ -z "$scp_targets_out" ]] && scp_targets_out="{}"
    jq -cn \
      --arg id "$scp_id" \
      --argjson policy "$scp_policy_out" \
      --argjson targets "$scp_targets_out" \
      '{policy_id:$id, policy:$policy, targets:$targets}' \
      >> "${OUT_DIR}/raw/organizations-scp-details.ndjson"
  done <<< "$scp_ids"
fi
