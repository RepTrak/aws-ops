#!/usr/bin/env bash
# Auto Scaling — ECS application scaling, EC2 ASGs, launch templates
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-autoscaling.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/autoscaling-ecs-scalable-targets.json" \
  application-autoscaling describe-scalable-targets --service-namespace ecs
safe_aws_json "${OUT_DIR}/raw/autoscaling-ecs-scaling-policies.json" \
  application-autoscaling describe-scaling-policies --service-namespace ecs
safe_aws_json "${OUT_DIR}/raw/autoscaling-ecs-scheduled-actions.json" \
  application-autoscaling describe-scheduled-actions --service-namespace ecs

safe_aws_json "${OUT_DIR}/raw/autoscaling-groups.json" \
  autoscaling describe-auto-scaling-groups
safe_aws_json "${OUT_DIR}/raw/autoscaling-launch-configurations.json" \
  autoscaling describe-launch-configurations

safe_aws_json "${OUT_DIR}/raw/ec2-launch-templates.json" ec2 describe-launch-templates
lt_ids="$(jq -r '.LaunchTemplates[]?.LaunchTemplateId // empty' \
  "${OUT_DIR}/raw/ec2-launch-templates.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/ec2-launch-template-versions.ndjson"
while IFS= read -r lt; do
  [[ -z "$lt" ]] && continue
  aws "${AWS_ARGS[@]}" ec2 describe-launch-template-versions \
    --launch-template-id "$lt" --versions '$Default' '$Latest' 2>/dev/null | \
    jq -c --arg lt "$lt" '{launch_template_id:$lt, data:.}' \
    >> "${OUT_DIR}/raw/ec2-launch-template-versions.ndjson" || true
done <<< "$lt_ids"
