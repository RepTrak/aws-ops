#!/usr/bin/env bash
# Load balancing & edge — ALB/NLB, ACM, WAFv2 regional+CloudFront, Shield, CloudFront distributions
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-elb.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── ELBv2 ────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/elbv2-load-balancers.json" elbv2 describe-load-balancers
lb_arns="$(jq -r '.LoadBalancers[]?.LoadBalancerArn // empty' \
  "${OUT_DIR}/raw/elbv2-load-balancers.json")"
: > "${OUT_DIR}/raw/elbv2-target-health.ndjson"
: > "${OUT_DIR}/raw/elbv2-load-balancer-attributes.ndjson"
: > "${OUT_DIR}/raw/elbv2-listeners.ndjson"
: > "${OUT_DIR}/raw/elbv2-rules.ndjson"
: > "${OUT_DIR}/raw/elbv2-listener-certificates.ndjson"

if [[ -n "$lb_arns" ]]; then
  safe_aws_json "${OUT_DIR}/raw/elbv2-target-groups.json" elbv2 describe-target-groups
  tg_arns="$(jq -r '.TargetGroups[]?.TargetGroupArn // empty' \
    "${OUT_DIR}/raw/elbv2-target-groups.json")"
  while IFS= read -r tg; do
    [[ -z "$tg" ]] && continue
    aws "${AWS_ARGS[@]}" elbv2 describe-target-health --target-group-arn "$tg" 2>/dev/null | \
      jq -c --arg tg "$tg" '{target_group_arn:$tg, data:.}' \
      >> "${OUT_DIR}/raw/elbv2-target-health.ndjson" || true
  done <<< "$tg_arns"

  while IFS= read -r lb; do
    [[ -z "$lb" ]] && continue
    aws "${AWS_ARGS[@]}" elbv2 describe-load-balancer-attributes \
      --load-balancer-arn "$lb" 2>/dev/null | \
      jq -c --arg lb "$lb" '{load_balancer_arn:$lb, data:.}' \
      >> "${OUT_DIR}/raw/elbv2-load-balancer-attributes.ndjson" || true
    listeners_file="${OUT_DIR}/raw/elbv2-listeners-$(basename "$lb").json"
    safe_aws_json "$listeners_file" elbv2 describe-listeners --load-balancer-arn "$lb"
    jq -c --arg lb "$lb" '{load_balancer_arn:$lb, data:.}' "$listeners_file" \
      >> "${OUT_DIR}/raw/elbv2-listeners.ndjson"
    listener_arns="$(jq -r '.Listeners[]?.ListenerArn // empty' "$listeners_file")"
    while IFS= read -r listener; do
      [[ -z "$listener" ]] && continue
      aws "${AWS_ARGS[@]}" elbv2 describe-rules --listener-arn "$listener" 2>/dev/null | \
        jq -c --arg l "$listener" '{listener_arn:$l, data:.}' \
        >> "${OUT_DIR}/raw/elbv2-rules.ndjson" || true
      aws "${AWS_ARGS[@]}" elbv2 describe-listener-certificates \
        --listener-arn "$listener" 2>/dev/null | \
        jq -c --arg l "$listener" '{listener_arn:$l, data:.}' \
        >> "${OUT_DIR}/raw/elbv2-listener-certificates.ndjson" || true
    done <<< "$listener_arns"
  done <<< "$lb_arns"
fi

# ── ACM ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/acm-certificates.json" acm list-certificates
cert_arns="$(jq -r '.CertificateSummaryList[]?.CertificateArn // empty' \
  "${OUT_DIR}/raw/acm-certificates.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/acm-certificate-details.ndjson"
while IFS= read -r cert; do
  [[ -z "$cert" ]] && continue
  aws "${AWS_ARGS[@]}" acm describe-certificate --certificate-arn "$cert" 2>/dev/null | \
    jq -c --arg arn "$cert" '{certificate_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/acm-certificate-details.ndjson" || true
done <<< "$cert_arns"

# ── WAFv2 regional ────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/wafv2-webacls-regional.json" wafv2 list-web-acls --scope REGIONAL
: > "${OUT_DIR}/raw/wafv2-webacl-details-regional.ndjson"
: > "${OUT_DIR}/raw/wafv2-webacl-resources-regional.ndjson"
while IFS= read -r acl_json; do
  [[ -z "$acl_json" ]] && continue
  acl_name="$(echo "$acl_json" | jq -r '.Name')"
  acl_id="$(echo "$acl_json" | jq -r '.Id')"
  acl_arn="$(echo "$acl_json" | jq -r '.ARN')"
  aws "${AWS_ARGS[@]}" wafv2 get-web-acl --scope REGIONAL \
    --name "$acl_name" --id "$acl_id" 2>/dev/null | \
    jq -c --arg arn "$acl_arn" '{web_acl_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/wafv2-webacl-details-regional.ndjson" || true
  aws "${AWS_ARGS[@]}" wafv2 list-resources-for-web-acl \
    --web-acl-arn "$acl_arn" 2>/dev/null | \
    jq -c --arg arn "$acl_arn" '{web_acl_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/wafv2-webacl-resources-regional.ndjson" || true
done < <(jq -c '.WebACLs[]?' "${OUT_DIR}/raw/wafv2-webacls-regional.json" 2>/dev/null || true)

# ── Global: WAFv2 CloudFront, Shield, CloudFront distributions ───────────────
if [[ "$SKIP_GLOBALS" != "true" ]]; then
  CF_ARGS=("${BASE_AWS_ARGS[@]}" --region us-east-1)

  echo "→ ${OUT_DIR}/raw/wafv2-webacls-cloudfront.json"
  aws "${CF_ARGS[@]}" wafv2 list-web-acls --scope CLOUDFRONT \
    > "${OUT_DIR}/raw/wafv2-webacls-cloudfront.json" 2>/dev/null \
    || { echo "WARN: wafv2 list-web-acls CLOUDFRONT not available" >&2
         echo '{}' > "${OUT_DIR}/raw/wafv2-webacls-cloudfront.json"; }
  : > "${OUT_DIR}/raw/wafv2-webacl-details-cloudfront.ndjson"
  while IFS= read -r acl_json; do
    [[ -z "$acl_json" ]] && continue
    cf_acl_name="$(echo "$acl_json" | jq -r '.Name')"
    cf_acl_id="$(echo "$acl_json" | jq -r '.Id')"
    cf_acl_arn="$(echo "$acl_json" | jq -r '.ARN')"
    aws "${CF_ARGS[@]}" wafv2 get-web-acl --scope CLOUDFRONT \
      --name "$cf_acl_name" --id "$cf_acl_id" 2>/dev/null | \
      jq -c --arg arn "$cf_acl_arn" '{web_acl_arn:$arn, data:.}' \
      >> "${OUT_DIR}/raw/wafv2-webacl-details-cloudfront.ndjson" || true
  done < <(jq -c '.WebACLs[]?' "${OUT_DIR}/raw/wafv2-webacls-cloudfront.json" 2>/dev/null || true)

  safe_aws_json "${OUT_DIR}/raw/shield-protections.json" shield list-protections

  safe_aws_json "${OUT_DIR}/raw/cloudfront-distributions.json" cloudfront list-distributions
  dist_ids="$(jq -r '.DistributionList.Items[]?.Id // empty' \
    "${OUT_DIR}/raw/cloudfront-distributions.json" 2>/dev/null || true)"
  : > "${OUT_DIR}/raw/cloudfront-distribution-configs.ndjson"
  while IFS= read -r dist_id; do
    [[ -z "$dist_id" ]] && continue
    aws "${CF_ARGS[@]}" cloudfront get-distribution-config --id "$dist_id" 2>/dev/null | \
      jq -c --arg id "$dist_id" '{distribution_id:$id, data:.}' \
      >> "${OUT_DIR}/raw/cloudfront-distribution-configs.ndjson" || true
  done <<< "$dist_ids"
fi
