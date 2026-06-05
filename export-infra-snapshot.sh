#!/usr/bin/env bash
set -euo pipefail

# Export a detailed AWS production infrastructure snapshot for SpecHub.
#
# Goals:
# - produce a repeatable, diffable snapshot directory
# - capture both broad inventory and topology-critical details
# - avoid downloading secret values by default
# - keep outputs easy for humans and tools to read
# - be explicit about region behavior so snapshots are not misleading
#
# Important region note:
# - This script is REGION-SCOPED for most services.
# - If you do not pass --region, it uses AWS_REGION / AWS_DEFAULT_REGION / profile default / current CLI default.
# - It does NOT automatically enumerate all AWS regions unless you explicitly ask it to.
# - Route53 and IAM are effectively account/global APIs and are still exported once.
#
# Usage:
#   ./deploy/aws/export-infra-snapshot.sh
#   ./deploy/aws/export-infra-snapshot.sh --region us-east-2 --profile prod
#   ./deploy/aws/export-infra-snapshot.sh --all-regions --profile prod
#   ./deploy/aws/export-infra-snapshot.sh --with-secret-values
#
# Requirements:
# - aws CLI v2
# - jq
# - python3

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE:-}"
WITH_SECRET_VALUES="false"
OUT_ROOT="${SCRIPT_DIR}/snapshots"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
ALL_REGIONS="false"

usage() {
  cat <<'EOF'
Export a detailed AWS infrastructure snapshot for SpecHub prod.

Options:
  --region <region>            AWS region to export from.
  --all-regions                Export one region-scoped snapshot for every enabled AWS region.
  --profile <profile>          AWS profile to use.
  --out-root <path>            Snapshot root directory (default: snapshots/ next to this script).
  --with-secret-values         Also export secret/parameter values (OFF by default).
  --help                       Show this help.

Behavior:
  If neither --region nor --all-regions is provided, the script uses the AWS CLI's
  effective default region (AWS_REGION / AWS_DEFAULT_REGION / profile config).
  It does NOT automatically scan all regions unless --all-regions is provided.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION="$2"
      shift 2
      ;;
    --all-regions)
      ALL_REGIONS="true"
      shift
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --out-root)
      OUT_ROOT="$2"
      shift 2
      ;;
    --with-secret-values)
      WITH_SECRET_VALUES="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  if ! has_cmd "$1"; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd aws
require_cmd jq
require_cmd python3

chunk_lines_file() {
  local size="$1"
  local infile="$2"
  awk -v size="$size" '
    NF {
      if (count > 0) printf " "
      printf "%s", $0
      count++
      if (count >= size) {
        printf "\n"
        count = 0
      }
    }
    END {
      if (count > 0) printf "\n"
    }
  ' "$infile"
}

BASE_AWS_ARGS=(--output json)
if [[ -n "$PROFILE" ]]; then
  BASE_AWS_ARGS+=(--profile "$PROFILE")
fi

resolve_default_region() {
  if [[ -n "$REGION" ]]; then
    echo "$REGION"
    return 0
  fi

  local configured
  configured="$(aws "${BASE_AWS_ARGS[@]}" configure get region 2>/dev/null || true)"
  if [[ -n "$configured" ]]; then
    echo "$configured"
    return 0
  fi

  return 1
}

safe_json_file() {
  local file="$1"
  if [[ ! -f "$file" || ! -s "$file" ]]; then
    echo '{}' > "$file"
  fi
}

run_snapshot_for_region() {
  local region="$1"
  local skip_globals="${2:-false}"
  local timestamp out_dir
  timestamp="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
  out_dir="${OUT_ROOT}/${timestamp}-${region}"

  mkdir -p "${out_dir}/raw" "${out_dir}/derived"

  local -a AWS_ARGS=("${BASE_AWS_ARGS[@]}" --region "$region")

  aws_json() {
    local outfile="$1"
    shift
    echo "→ $outfile"
    aws "${AWS_ARGS[@]}" "$@" > "$outfile"
  }

  # Resolve OS-level timeout command once for the whole region run.
  _TIMEOUT_CMD=""
  if command -v gtimeout >/dev/null 2>&1; then _TIMEOUT_CMD="gtimeout 90"
  elif command -v timeout  >/dev/null 2>&1; then _TIMEOUT_CMD="timeout 90"
  fi

  safe_aws_json() {
    local outfile="$1"
    shift
    echo "→ $outfile"
    if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" "$@" > "$outfile" 2>"${outfile}.stderr"; then
      rm -f "${outfile}.stderr"
    else
      local _exit=$?
      rm -f "${outfile}.stderr"
      echo '{}' > "$outfile"
      if [[ $_exit -eq 124 ]]; then
        echo "WARN: timed out after 90s: aws $*" >&2
      else
        echo "WARN: failed in ${region}: aws $*" >&2
      fi
    fi
  }

  progress() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
  }

  cat > "${out_dir}/manifest.json" <<EOF
{
  "timestamp_utc": "${timestamp}",
  "region": "${region}",
  "profile": $(jq -Rn --arg v "$PROFILE" 'if $v=="" then null else $v end'),
  "with_secret_values": ${WITH_SECRET_VALUES},
  "all_regions_mode": ${ALL_REGIONS}
}
EOF

  progress "Starting snapshot — ${region}"

  progress "Broad inventory (Resource Explorer, tagging API)"
  # ---------- Broad inventory ----------
  safe_aws_json "${out_dir}/raw/resourcegroupstaggingapi-get-resources.json" \
    resourcegroupstaggingapi get-resources

  safe_aws_json "${out_dir}/raw/resource-explorer-2-list-views.json" \
    resource-explorer-2 list-views

  local default_view_arn
  default_view_arn="$(jq -r 'first((.Views // [])[]? | if type == "object" then .ViewArn // empty else . end)' "${out_dir}/raw/resource-explorer-2-list-views.json" 2>/dev/null || true)"
  if [[ -n "$default_view_arn" && "$default_view_arn" != "null" ]]; then
    safe_aws_json "${out_dir}/raw/resource-explorer-2-search.json" \
      resource-explorer-2 search --view-arn "$default_view_arn" --query-string "*"
  fi

  progress "Compute — ECS (clusters, services, tasks, task definitions)"
  # ---------- ECS ----------
  safe_aws_json "${out_dir}/raw/ecs-clusters.json" ecs list-clusters
  local cluster_arns
  cluster_arns="$(jq -r '.clusterArns[]?' "${out_dir}/raw/ecs-clusters.json")"
  # Initialise ndjson files unconditionally so they always exist even when
  # there are no clusters, no permissions, or no matching resources.
  : > "${out_dir}/raw/ecs-describe-task-definitions.ndjson"
  : > "${out_dir}/raw/ecs-services.ndjson"
  : > "${out_dir}/raw/ecs-tasks.ndjson"
  : > "${out_dir}/raw/ecs-container-instances.ndjson"

  if [[ -n "$cluster_arns" ]]; then
    safe_aws_json "${out_dir}/raw/ecs-describe-clusters.json" ecs describe-clusters --clusters $cluster_arns --include ATTACHMENTS CONFIGURATIONS SETTINGS STATISTICS TAGS
    safe_aws_json "${out_dir}/raw/ecs-list-task-definitions.json" ecs list-task-definitions --sort DESC
    local task_def_arns
    task_def_arns="$(jq -r '.taskDefinitionArns[]?' "${out_dir}/raw/ecs-list-task-definitions.json")"
    if [[ -n "$task_def_arns" ]]; then
      while IFS= read -r arn; do
        [[ -z "$arn" ]] && continue
        aws "${AWS_ARGS[@]}" ecs describe-task-definition --task-definition "$arn" --include TAGS 2>/dev/null | \
          jq -c --arg arn "$arn" '{task_definition_arn:$arn, data:.}' >> "${out_dir}/raw/ecs-describe-task-definitions.ndjson" || true
      done <<< "$task_def_arns"
    fi

    while IFS= read -r cluster; do
      [[ -z "$cluster" ]] && continue
      local cluster_name
      cluster_name="$(basename "$cluster")"
      safe_aws_json "${out_dir}/raw/ecs-list-services-${cluster_name}.json" ecs list-services --cluster "$cluster"
      local service_arns service_arns_file
      service_arns_file="${out_dir}/raw/ecs-list-services-${cluster_name}.txt"
      jq -r '.serviceArns[]?' "${out_dir}/raw/ecs-list-services-${cluster_name}.json" > "$service_arns_file"
      service_arns="$(cat "$service_arns_file")"
      if [[ -n "$service_arns" ]]; then
        while IFS= read -r batch; do
          [[ -z "$batch" ]] && continue
          aws "${AWS_ARGS[@]}" ecs describe-services --cluster "$cluster" --services $batch --include TAGS 2>/dev/null | jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' >> "${out_dir}/raw/ecs-services.ndjson" || true
        done < <(chunk_lines_file 10 "$service_arns_file")
      fi

      safe_aws_json "${out_dir}/raw/ecs-list-tasks-${cluster_name}.json" ecs list-tasks --cluster "$cluster"
      local task_arns task_arns_file
      task_arns_file="${out_dir}/raw/ecs-list-tasks-${cluster_name}.txt"
      jq -r '.taskArns[]?' "${out_dir}/raw/ecs-list-tasks-${cluster_name}.json" > "$task_arns_file"
      task_arns="$(cat "$task_arns_file")"
      if [[ -n "$task_arns" ]]; then
        while IFS= read -r batch; do
          [[ -z "$batch" ]] && continue
          aws "${AWS_ARGS[@]}" ecs describe-tasks --cluster "$cluster" --tasks $batch --include TAGS 2>/dev/null | jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' >> "${out_dir}/raw/ecs-tasks.ndjson" || true
        done < <(chunk_lines_file 100 "$task_arns_file")
      fi

      safe_aws_json "${out_dir}/raw/ecs-list-container-instances-${cluster_name}.json" ecs list-container-instances --cluster "$cluster"
      local container_instance_arns container_instance_arns_file
      container_instance_arns_file="${out_dir}/raw/ecs-list-container-instances-${cluster_name}.txt"
      jq -r '.containerInstanceArns[]?' "${out_dir}/raw/ecs-list-container-instances-${cluster_name}.json" > "$container_instance_arns_file"
      container_instance_arns="$(cat "$container_instance_arns_file")"
      if [[ -n "$container_instance_arns" ]]; then
        while IFS= read -r batch; do
          [[ -z "$batch" ]] && continue
          aws "${AWS_ARGS[@]}" ecs describe-container-instances --cluster "$cluster" --container-instances $batch --include TAGS CONTAINER_INSTANCE_HEALTH 2>/dev/null | jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' >> "${out_dir}/raw/ecs-container-instances.ndjson" || true
        done < <(chunk_lines_file 100 "$container_instance_arns_file")
      fi
    done <<< "$cluster_arns"

    safe_aws_json "${out_dir}/raw/ecs-capacity-providers.json" ecs describe-capacity-providers
  fi

  # ---------- EC2 instances (ECS container hosts) ----------
  # Scoped to instances tagged as ECS container hosts — avoids capturing unrelated EC2.
  safe_aws_json "${out_dir}/raw/ec2-instances-ecs.json" \
    ec2 describe-instances \
    --filters "Name=tag-key,Values=aws:ecs:cluster-name"

  progress "Compute — EKS (clusters, node groups, Fargate profiles)"
  OUT_DIR="$out_dir" "$(dirname "$0")/export-eks.sh" \
    --region "$region" \
    ${PROFILE:+--profile "$PROFILE"}

  progress "Compute — ECR (repositories, images, scanning)"
  # ---------- ECR ----------
  safe_aws_json "${out_dir}/raw/ecr-repositories.json" ecr describe-repositories
  safe_aws_json "${out_dir}/raw/ecr-registry-scanning-config.json" ecr get-registry-scanning-configuration
  local repo_names
  repo_names="$(jq -r '.repositories[]?.repositoryName // empty' "${out_dir}/raw/ecr-repositories.json" 2>/dev/null || true)"
  echo "→ ${out_dir}/raw/ecr-repository-policies.ndjson"
  : > "${out_dir}/raw/ecr-repository-policies.ndjson"
  echo "→ ${out_dir}/raw/ecr-lifecycle-policies.ndjson"
  : > "${out_dir}/raw/ecr-lifecycle-policies.ndjson"
  echo "→ ${out_dir}/raw/ecr-images.ndjson"
  : > "${out_dir}/raw/ecr-images.ndjson"
  local _ecr_tmp
  _ecr_tmp=$(mktemp)
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    echo "  ecr: $repo" >&2
    if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr get-repository-policy --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
      jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" >> "${out_dir}/raw/ecr-repository-policies.ndjson"
    fi
    if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr get-lifecycle-policy --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
      jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" >> "${out_dir}/raw/ecr-lifecycle-policies.ndjson"
    fi
    if ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" ecr describe-images --repository-name "$repo" > "$_ecr_tmp" 2>/dev/null; then
      jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' "$_ecr_tmp" >> "${out_dir}/raw/ecr-images.ndjson"
    fi
  done <<< "$repo_names"
  rm -f "$_ecr_tmp"

  progress "Scaling — Auto Scaling (ECS policies, EC2 ASGs, launch templates)"
  # ---------- Application Auto Scaling (ECS) ----------
  safe_aws_json "${out_dir}/raw/autoscaling-ecs-scalable-targets.json" \
    application-autoscaling describe-scalable-targets --service-namespace ecs
  safe_aws_json "${out_dir}/raw/autoscaling-ecs-scaling-policies.json" \
    application-autoscaling describe-scaling-policies --service-namespace ecs
  safe_aws_json "${out_dir}/raw/autoscaling-ecs-scheduled-actions.json" \
    application-autoscaling describe-scheduled-actions --service-namespace ecs

  # ---------- EC2 Auto Scaling ----------
  safe_aws_json "${out_dir}/raw/autoscaling-groups.json" \
    autoscaling describe-auto-scaling-groups
  safe_aws_json "${out_dir}/raw/autoscaling-launch-configurations.json" \
    autoscaling describe-launch-configurations

  # ---------- EC2 Launch Templates ----------
  safe_aws_json "${out_dir}/raw/ec2-launch-templates.json" \
    ec2 describe-launch-templates
  local lt_ids
  lt_ids="$(jq -r '.LaunchTemplates[]?.LaunchTemplateId // empty' "${out_dir}/raw/ec2-launch-templates.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/ec2-launch-template-versions.ndjson"
  while IFS= read -r lt; do
    [[ -z "$lt" ]] && continue
    aws "${AWS_ARGS[@]}" ec2 describe-launch-template-versions \
      --launch-template-id "$lt" --versions '$Default' '$Latest' 2>/dev/null | \
      jq -c --arg lt "$lt" '{launch_template_id:$lt, data:.}' >> "${out_dir}/raw/ec2-launch-template-versions.ndjson" || true
  done <<< "$lt_ids"

  progress "Service discovery — Cloud Map"
  # ---------- Cloud Map / Service discovery ----------
  safe_aws_json "${out_dir}/raw/servicediscovery-list-namespaces.json" servicediscovery list-namespaces
  local namespace_ids
  namespace_ids="$(jq -r '.Namespaces[]?.Id // empty' "${out_dir}/raw/servicediscovery-list-namespaces.json")"
  : > "${out_dir}/raw/servicediscovery-namespaces.ndjson"
  : > "${out_dir}/raw/servicediscovery-services.ndjson"
  : > "${out_dir}/raw/servicediscovery-instances.ndjson"
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    aws "${AWS_ARGS[@]}" servicediscovery get-namespace --id "$ns" 2>/dev/null | \
      jq -c --arg ns "$ns" '{namespace_id:$ns, data:.}' >> "${out_dir}/raw/servicediscovery-namespaces.ndjson" || true
  done <<< "$namespace_ids"

  safe_aws_json "${out_dir}/raw/servicediscovery-list-services.json" servicediscovery list-services
  local service_ids
  service_ids="$(jq -r '.Services[]?.Id // empty' "${out_dir}/raw/servicediscovery-list-services.json")"
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    aws "${AWS_ARGS[@]}" servicediscovery get-service --id "$svc" 2>/dev/null | \
      jq -c --arg svc "$svc" '{service_id:$svc, data:.}' >> "${out_dir}/raw/servicediscovery-services.ndjson" || true
    safe_aws_json "${out_dir}/raw/servicediscovery-list-instances-${svc}.json" servicediscovery list-instances --service-id "$svc"
    jq -c --arg service_id "$svc" '{service_id:$service_id, data:.}' "${out_dir}/raw/servicediscovery-list-instances-${svc}.json" >> "${out_dir}/raw/servicediscovery-instances.ndjson"
  done <<< "$service_ids"

  progress "Load balancing & edge — ALB/NLB, ACM, WAFv2, CloudFront"
  # ---------- ELBv2 ----------
  safe_aws_json "${out_dir}/raw/elbv2-load-balancers.json" elbv2 describe-load-balancers
  local lb_arns
  lb_arns="$(jq -r '.LoadBalancers[]?.LoadBalancerArn // empty' "${out_dir}/raw/elbv2-load-balancers.json")"
  : > "${out_dir}/raw/elbv2-target-health.ndjson"
  : > "${out_dir}/raw/elbv2-load-balancer-attributes.ndjson"
  : > "${out_dir}/raw/elbv2-listeners.ndjson"
  : > "${out_dir}/raw/elbv2-rules.ndjson"
  : > "${out_dir}/raw/elbv2-listener-certificates.ndjson"

  if [[ -n "$lb_arns" ]]; then
    safe_aws_json "${out_dir}/raw/elbv2-target-groups.json" elbv2 describe-target-groups
    local tg_arns
    tg_arns="$(jq -r '.TargetGroups[]?.TargetGroupArn // empty' "${out_dir}/raw/elbv2-target-groups.json")"
    while IFS= read -r tg; do
      [[ -z "$tg" ]] && continue
      aws "${AWS_ARGS[@]}" elbv2 describe-target-health --target-group-arn "$tg" 2>/dev/null | jq -c --arg target_group_arn "$tg" '{target_group_arn:$target_group_arn, data:.}' >> "${out_dir}/raw/elbv2-target-health.ndjson" || true
    done <<< "$tg_arns"

    while IFS= read -r lb; do
      [[ -z "$lb" ]] && continue
      aws "${AWS_ARGS[@]}" elbv2 describe-load-balancer-attributes --load-balancer-arn "$lb" 2>/dev/null | \
        jq -c --arg lb "$lb" '{load_balancer_arn:$lb, data:.}' >> "${out_dir}/raw/elbv2-load-balancer-attributes.ndjson" || true
      local listeners_file listener_arns
      listeners_file="${out_dir}/raw/elbv2-listeners-$(basename "$lb").json"
      safe_aws_json "$listeners_file" elbv2 describe-listeners --load-balancer-arn "$lb"
      jq -c --arg load_balancer_arn "$lb" '{load_balancer_arn:$load_balancer_arn, data:.}' "$listeners_file" >> "${out_dir}/raw/elbv2-listeners.ndjson"
      listener_arns="$(jq -r '.Listeners[]?.ListenerArn // empty' "$listeners_file")"
      while IFS= read -r listener; do
        [[ -z "$listener" ]] && continue
        aws "${AWS_ARGS[@]}" elbv2 describe-rules --listener-arn "$listener" 2>/dev/null | jq -c --arg listener_arn "$listener" '{listener_arn:$listener_arn, data:.}' >> "${out_dir}/raw/elbv2-rules.ndjson" || true
        aws "${AWS_ARGS[@]}" elbv2 describe-listener-certificates --listener-arn "$listener" 2>/dev/null | \
          jq -c --arg listener_arn "$listener" '{listener_arn:$listener_arn, data:.}' >> "${out_dir}/raw/elbv2-listener-certificates.ndjson" || true
      done <<< "$listener_arns"
    done <<< "$lb_arns"
  fi

  # ---------- ACM ----------
  safe_aws_json "${out_dir}/raw/acm-certificates.json" acm list-certificates
  local cert_arns
  cert_arns="$(jq -r '.CertificateSummaryList[]?.CertificateArn // empty' "${out_dir}/raw/acm-certificates.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/acm-certificate-details.ndjson"
  while IFS= read -r cert; do
    [[ -z "$cert" ]] && continue
    aws "${AWS_ARGS[@]}" acm describe-certificate --certificate-arn "$cert" 2>/dev/null | \
      jq -c --arg arn "$cert" '{certificate_arn:$arn, data:.}' >> "${out_dir}/raw/acm-certificate-details.ndjson" || true
  done <<< "$cert_arns"

  # ---------- WAFv2 ----------
  safe_aws_json "${out_dir}/raw/wafv2-webacls-regional.json" \
    wafv2 list-web-acls --scope REGIONAL
  : > "${out_dir}/raw/wafv2-webacl-details-regional.ndjson"
  : > "${out_dir}/raw/wafv2-webacl-resources-regional.ndjson"
  while IFS= read -r acl_json; do
    [[ -z "$acl_json" ]] && continue
    local acl_name acl_id acl_arn
    acl_name="$(echo "$acl_json" | jq -r '.Name')"
    acl_id="$(echo "$acl_json" | jq -r '.Id')"
    acl_arn="$(echo "$acl_json" | jq -r '.ARN')"
    aws "${AWS_ARGS[@]}" wafv2 get-web-acl --scope REGIONAL --name "$acl_name" --id "$acl_id" 2>/dev/null | \
      jq -c --arg arn "$acl_arn" '{web_acl_arn:$arn, data:.}' >> "${out_dir}/raw/wafv2-webacl-details-regional.ndjson" || true
    aws "${AWS_ARGS[@]}" wafv2 list-resources-for-web-acl --web-acl-arn "$acl_arn" 2>/dev/null | \
      jq -c --arg arn "$acl_arn" '{web_acl_arn:$arn, data:.}' >> "${out_dir}/raw/wafv2-webacl-resources-regional.ndjson" || true
  done < <(jq -c '.WebACLs[]?' "${out_dir}/raw/wafv2-webacls-regional.json" 2>/dev/null || true)

  if [[ "$skip_globals" != "true" ]]; then
    # WAFv2 CloudFront-scoped ACLs must be queried from us-east-1
    local -a CF_ARGS=("${BASE_AWS_ARGS[@]}" --region us-east-1)
    echo "→ ${out_dir}/raw/wafv2-webacls-cloudfront.json"
    aws "${CF_ARGS[@]}" wafv2 list-web-acls --scope CLOUDFRONT \
      > "${out_dir}/raw/wafv2-webacls-cloudfront.json" 2>/dev/null \
      || { echo "WARN: wafv2 list-web-acls --scope CLOUDFRONT (us-east-1) not available" >&2
           echo '{}' > "${out_dir}/raw/wafv2-webacls-cloudfront.json"; }
    : > "${out_dir}/raw/wafv2-webacl-details-cloudfront.ndjson"
    while IFS= read -r acl_json; do
      [[ -z "$acl_json" ]] && continue
      local cf_acl_name cf_acl_id cf_acl_arn
      cf_acl_name="$(echo "$acl_json" | jq -r '.Name')"
      cf_acl_id="$(echo "$acl_json" | jq -r '.Id')"
      cf_acl_arn="$(echo "$acl_json" | jq -r '.ARN')"
      aws "${CF_ARGS[@]}" wafv2 get-web-acl --scope CLOUDFRONT --name "$cf_acl_name" --id "$cf_acl_id" | \
        jq -c --arg arn "$cf_acl_arn" '{web_acl_arn:$arn, data:.}' >> "${out_dir}/raw/wafv2-webacl-details-cloudfront.ndjson"
    done < <(jq -c '.WebACLs[]?' "${out_dir}/raw/wafv2-webacls-cloudfront.json" 2>/dev/null || true)

    # ---------- Shield ----------
    safe_aws_json "${out_dir}/raw/shield-protections.json" shield list-protections

    # ---------- CloudFront ----------
    safe_aws_json "${out_dir}/raw/cloudfront-distributions.json" cloudfront list-distributions
    local dist_ids
    dist_ids="$(jq -r '.DistributionList.Items[]?.Id // empty' "${out_dir}/raw/cloudfront-distributions.json" 2>/dev/null || true)"
    : > "${out_dir}/raw/cloudfront-distribution-configs.ndjson"
    while IFS= read -r dist_id; do
      [[ -z "$dist_id" ]] && continue
      aws "${CF_ARGS[@]}" cloudfront get-distribution-config --id "$dist_id" | \
        jq -c --arg id "$dist_id" '{distribution_id:$id, data:.}' >> "${out_dir}/raw/cloudfront-distribution-configs.ndjson"
    done <<< "$dist_ids"
  fi

  progress "Networking — VPC, subnets, SGs, route tables, TGW, VPN, Direct Connect"
  # ---------- VPC / networking ----------
  safe_aws_json "${out_dir}/raw/ec2-vpcs.json" ec2 describe-vpcs
  safe_aws_json "${out_dir}/raw/ec2-subnets.json" ec2 describe-subnets
  safe_aws_json "${out_dir}/raw/ec2-route-tables.json" ec2 describe-route-tables
  safe_aws_json "${out_dir}/raw/ec2-security-groups.json" ec2 describe-security-groups
  safe_aws_json "${out_dir}/raw/ec2-network-acls.json" ec2 describe-network-acls
  safe_aws_json "${out_dir}/raw/ec2-internet-gateways.json" ec2 describe-internet-gateways
  safe_aws_json "${out_dir}/raw/ec2-egress-only-internet-gateways.json" ec2 describe-egress-only-internet-gateways
  safe_aws_json "${out_dir}/raw/ec2-nat-gateways.json" ec2 describe-nat-gateways
  safe_aws_json "${out_dir}/raw/ec2-vpc-endpoints.json" ec2 describe-vpc-endpoints
  safe_aws_json "${out_dir}/raw/ec2-transit-gateways.json" ec2 describe-transit-gateways
  safe_aws_json "${out_dir}/raw/ec2-network-interfaces.json" ec2 describe-network-interfaces
  safe_aws_json "${out_dir}/raw/ec2-prefix-lists.json" ec2 describe-managed-prefix-lists
  safe_aws_json "${out_dir}/raw/ec2-addresses.json" ec2 describe-addresses
  safe_aws_json "${out_dir}/raw/ec2-vpc-peering-connections.json" ec2 describe-vpc-peering-connections
  safe_aws_json "${out_dir}/raw/ec2-transit-gateway-attachments.json" ec2 describe-transit-gateway-attachments
  safe_aws_json "${out_dir}/raw/ec2-transit-gateway-route-tables.json" ec2 describe-transit-gateway-route-tables
  safe_aws_json "${out_dir}/raw/ec2-vpn-gateways.json" ec2 describe-vpn-gateways
  safe_aws_json "${out_dir}/raw/ec2-vpn-connections.json" ec2 describe-vpn-connections
  safe_aws_json "${out_dir}/raw/ec2-customer-gateways.json" ec2 describe-customer-gateways

  # ---------- Direct Connect ----------
  safe_aws_json "${out_dir}/raw/directconnect-connections.json" directconnect describe-connections
  safe_aws_json "${out_dir}/raw/directconnect-virtual-interfaces.json" directconnect describe-virtual-interfaces
  safe_aws_json "${out_dir}/raw/directconnect-gateways.json" directconnect describe-direct-connect-gateways

  progress "Databases — RDS, RDS Proxy, Redshift, DocumentDB, DynamoDB"
  # ---------- RDS ----------
  safe_aws_json "${out_dir}/raw/rds-db-instances.json" rds describe-db-instances
  safe_aws_json "${out_dir}/raw/rds-db-clusters.json" rds describe-db-clusters
  safe_aws_json "${out_dir}/raw/rds-db-subnet-groups.json" rds describe-db-subnet-groups
  safe_aws_json "${out_dir}/raw/rds-db-parameter-groups.json" rds describe-db-parameter-groups
  safe_aws_json "${out_dir}/raw/rds-db-snapshots.json" rds describe-db-snapshots
  safe_aws_json "${out_dir}/raw/rds-db-cluster-snapshots.json" rds describe-db-cluster-snapshots
  safe_aws_json "${out_dir}/raw/rds-automated-backups.json" rds describe-db-instance-automated-backups
  safe_aws_json "${out_dir}/raw/rds-event-subscriptions.json" rds describe-event-subscriptions
  local rds_pg_names
  rds_pg_names="$(jq -r '.DBParameterGroups[]?.DBParameterGroupName // empty' \
    "${out_dir}/raw/rds-db-parameter-groups.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/rds-db-parameter-group-contents.ndjson"
  while IFS= read -r pg; do
    [[ -z "$pg" ]] && continue
    aws "${AWS_ARGS[@]}" rds describe-db-parameters --db-parameter-group-name "$pg" 2>/dev/null | \
      jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' >> "${out_dir}/raw/rds-db-parameter-group-contents.ndjson" || true
  done <<< "$rds_pg_names"

  # ---------- RDS Proxy ----------
  safe_aws_json "${out_dir}/raw/rds-db-proxies.json" rds describe-db-proxies
  local proxy_names
  proxy_names="$(jq -r '.DBProxies[]?.DBProxyName // empty' "${out_dir}/raw/rds-db-proxies.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/rds-db-proxy-targets.ndjson"
  : > "${out_dir}/raw/rds-db-proxy-target-groups.ndjson"
  while IFS= read -r proxy; do
    [[ -z "$proxy" ]] && continue
    aws "${AWS_ARGS[@]}" rds describe-db-proxy-targets --db-proxy-name "$proxy" 2>/dev/null | \
      jq -c --arg proxy "$proxy" '{db_proxy_name:$proxy, data:.}' >> "${out_dir}/raw/rds-db-proxy-targets.ndjson" || true
    aws "${AWS_ARGS[@]}" rds describe-db-proxy-target-groups --db-proxy-name "$proxy" 2>/dev/null | \
      jq -c --arg proxy "$proxy" '{db_proxy_name:$proxy, data:.}' >> "${out_dir}/raw/rds-db-proxy-target-groups.ndjson" || true
  done <<< "$proxy_names"

  # ---------- Redshift ----------
  safe_aws_json "${out_dir}/raw/redshift-clusters.json" redshift describe-clusters
  safe_aws_json "${out_dir}/raw/redshift-cluster-subnet-groups.json" redshift describe-cluster-subnet-groups
  safe_aws_json "${out_dir}/raw/redshift-parameter-groups.json" redshift describe-cluster-parameter-groups
  safe_aws_json "${out_dir}/raw/redshift-snapshots.json" redshift describe-cluster-snapshots
  safe_aws_json "${out_dir}/raw/redshift-event-subscriptions.json" redshift describe-event-subscriptions
  local rs_cluster_ids
  rs_cluster_ids="$(jq -r '.Clusters[]?.ClusterIdentifier // empty' \
    "${out_dir}/raw/redshift-clusters.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/redshift-logging-status.ndjson"
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    aws "${AWS_ARGS[@]}" redshift describe-logging-status --cluster-identifier "$cid" 2>/dev/null | \
      jq -c --arg id "$cid" '{cluster_identifier:$id, data:.}' >> "${out_dir}/raw/redshift-logging-status.ndjson" || true
  done <<< "$rs_cluster_ids"
  local rs_pg_names
  rs_pg_names="$(jq -r '.ParameterGroups[]?.ParameterGroupName // empty' \
    "${out_dir}/raw/redshift-parameter-groups.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/redshift-parameter-group-contents.ndjson"
  while IFS= read -r pg; do
    [[ -z "$pg" ]] && continue
    aws "${AWS_ARGS[@]}" redshift describe-cluster-parameters --parameter-group-name "$pg" 2>/dev/null | \
      jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' >> "${out_dir}/raw/redshift-parameter-group-contents.ndjson" || true
  done <<< "$rs_pg_names"

  # ---------- Redshift Serverless ----------
  safe_aws_json "${out_dir}/raw/redshift-serverless-namespaces.json" redshift-serverless list-namespaces
  local rs_ns_names
  rs_ns_names="$(jq -r '.namespaces[]?.namespaceName // empty' \
    "${out_dir}/raw/redshift-serverless-namespaces.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/redshift-serverless-namespace-details.ndjson"
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    aws "${AWS_ARGS[@]}" redshift-serverless get-namespace --namespace-name "$ns" 2>/dev/null | \
      jq -c --arg ns "$ns" '{namespace_name:$ns, data:.}' >> "${out_dir}/raw/redshift-serverless-namespace-details.ndjson" || true
  done <<< "$rs_ns_names"
  safe_aws_json "${out_dir}/raw/redshift-serverless-workgroups.json" redshift-serverless list-workgroups
  local rs_wg_names
  rs_wg_names="$(jq -r '.workgroups[]?.workgroupName // empty' \
    "${out_dir}/raw/redshift-serverless-workgroups.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/redshift-serverless-workgroup-details.ndjson"
  while IFS= read -r wg; do
    [[ -z "$wg" ]] && continue
    aws "${AWS_ARGS[@]}" redshift-serverless get-workgroup --workgroup-name "$wg" 2>/dev/null | \
      jq -c --arg wg "$wg" '{workgroup_name:$wg, data:.}' >> "${out_dir}/raw/redshift-serverless-workgroup-details.ndjson" || true
  done <<< "$rs_wg_names"
  safe_aws_json "${out_dir}/raw/redshift-serverless-snapshots.json" redshift-serverless list-snapshots

  # ---------- DocumentDB ----------
  safe_aws_json "${out_dir}/raw/docdb-clusters.json" docdb describe-db-clusters
  safe_aws_json "${out_dir}/raw/docdb-instances.json" docdb describe-db-instances
  safe_aws_json "${out_dir}/raw/docdb-subnet-groups.json" docdb describe-db-subnet-groups
  safe_aws_json "${out_dir}/raw/docdb-cluster-snapshots.json" docdb describe-db-cluster-snapshots
  safe_aws_json "${out_dir}/raw/docdb-event-subscriptions.json" docdb describe-event-subscriptions
  safe_aws_json "${out_dir}/raw/docdb-parameter-groups.json" docdb describe-db-cluster-parameter-groups
  local docdb_pg_names
  docdb_pg_names="$(jq -r '.DBClusterParameterGroups[]?.DBClusterParameterGroupName // empty' \
    "${out_dir}/raw/docdb-parameter-groups.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/docdb-parameter-group-contents.ndjson"
  while IFS= read -r pg; do
    [[ -z "$pg" ]] && continue
    aws "${AWS_ARGS[@]}" docdb describe-db-cluster-parameters \
      --db-cluster-parameter-group-name "$pg" 2>/dev/null | \
      jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' >> "${out_dir}/raw/docdb-parameter-group-contents.ndjson" || true
  done <<< "$docdb_pg_names"

  # ---------- DynamoDB ----------
  safe_aws_json "${out_dir}/raw/dynamodb-tables.json" dynamodb list-tables
  local ddb_table_names
  ddb_table_names="$(jq -r '.TableNames[]? // empty' "${out_dir}/raw/dynamodb-tables.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/dynamodb-table-details.ndjson"
  : > "${out_dir}/raw/dynamodb-continuous-backups.ndjson"
  while IFS= read -r table; do
    [[ -z "$table" ]] && continue
    aws "${AWS_ARGS[@]}" dynamodb describe-table --table-name "$table" 2>/dev/null | \
      jq -c --arg t "$table" '{table_name:$t, data:.}' >> "${out_dir}/raw/dynamodb-table-details.ndjson" || true
    aws "${AWS_ARGS[@]}" dynamodb describe-continuous-backups --table-name "$table" 2>/dev/null | \
      jq -c --arg t "$table" '{table_name:$t, data:.}' >> "${out_dir}/raw/dynamodb-continuous-backups.ndjson" || true
  done <<< "$ddb_table_names"
  safe_aws_json "${out_dir}/raw/dynamodb-backups.json" dynamodb list-backups

  progress "Storage — EFS, S3"
  # ---------- EFS ----------
  safe_aws_json "${out_dir}/raw/efs-file-systems.json" efs describe-file-systems
  local efs_ids
  efs_ids="$(jq -r '.FileSystems[]?.FileSystemId // empty' "${out_dir}/raw/efs-file-systems.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/efs-mount-targets.ndjson"
  : > "${out_dir}/raw/efs-access-points.ndjson"
  : > "${out_dir}/raw/efs-mount-target-sgs.ndjson"
  while IFS= read -r fs; do
    [[ -z "$fs" ]] && continue
    local mt_out
    mt_out="$(aws "${AWS_ARGS[@]}" efs describe-mount-targets --file-system-id "$fs" 2>/dev/null)" || mt_out="{}"
    [[ -z "$mt_out" ]] && mt_out="{}"
    echo "$mt_out" | jq -c --arg file_system_id "$fs" '{file_system_id:$file_system_id, data:.}' >> "${out_dir}/raw/efs-mount-targets.ndjson"
    while IFS= read -r mt_id; do
      [[ -z "$mt_id" ]] && continue
      aws "${AWS_ARGS[@]}" efs describe-mount-target-security-groups --mount-target-id "$mt_id" 2>/dev/null | \
        jq -c --arg mt "$mt_id" --arg fs "$fs" '{mount_target_id:$mt, file_system_id:$fs, data:.}' \
        >> "${out_dir}/raw/efs-mount-target-sgs.ndjson" || true
    done < <(echo "$mt_out" | jq -r '.MountTargets[]?.MountTargetId // empty')
    aws "${AWS_ARGS[@]}" efs describe-access-points --file-system-id "$fs" 2>/dev/null | jq -c --arg file_system_id "$fs" '{file_system_id:$file_system_id, data:.}' >> "${out_dir}/raw/efs-access-points.ndjson" || true
  done <<< "$efs_ids"

  if [[ "$skip_globals" != "true" ]]; then
    # ---------- S3 ----------
    safe_aws_json "${out_dir}/raw/s3-buckets.json" s3api list-buckets
    local s3_bucket_names
    s3_bucket_names="$(jq -r '.Buckets[]?.Name // empty' "${out_dir}/raw/s3-buckets.json" 2>/dev/null || true)"
    local s3_bucket_count
    s3_bucket_count="$(echo "$s3_bucket_names" | grep -c . || true)"
    echo "→ ${out_dir}/raw/s3-bucket-details.ndjson (${s3_bucket_count} buckets)"
    : > "${out_dir}/raw/s3-bucket-details.ndjson"
    local s3_bucket_idx=0
    while IFS= read -r bucket; do
      [[ -z "$bucket" ]] && continue
      s3_bucket_idx=$((s3_bucket_idx + 1))
      echo "  s3 (${s3_bucket_idx}/${s3_bucket_count}): $bucket" >&2
      local s3_location s3_versioning s3_encryption s3_public_access \
            s3_policy s3_lifecycle s3_cors s3_notifications
      # get-bucket-location works from any region; response gives the bucket's actual region
      s3_location="$(aws "${BASE_AWS_ARGS[@]}" s3api get-bucket-location \
        --bucket "$bucket" 2>/dev/null)" || s3_location="{}"
      [[ -z "$s3_location" ]] && s3_location="{}"
      local bucket_region
      bucket_region="$(echo "$s3_location" | jq -r '.LocationConstraint // "us-east-1"')"
      local -a BUCKET_ARGS=("${BASE_AWS_ARGS[@]}" --region "$bucket_region")
      s3_versioning="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-versioning \
        --bucket "$bucket" 2>/dev/null)" || s3_versioning="{}"
      [[ -z "$s3_versioning" ]] && s3_versioning="{}"
      s3_public_access="$(aws "${BUCKET_ARGS[@]}" s3api get-public-access-block \
        --bucket "$bucket" 2>/dev/null)" || s3_public_access="{}"
      [[ -z "$s3_public_access" ]] && s3_public_access="{}"
      s3_notifications="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-notification-configuration \
        --bucket "$bucket" 2>/dev/null)" || s3_notifications="{}"
      [[ -z "$s3_notifications" ]] && s3_notifications="{}"
      s3_encryption="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-encryption \
        --bucket "$bucket" 2>/dev/null)" || s3_encryption="{}"
      [[ -z "$s3_encryption" ]] && s3_encryption="{}"
      s3_policy="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-policy \
        --bucket "$bucket" 2>/dev/null)" || s3_policy="{}"
      [[ -z "$s3_policy" ]] && s3_policy="{}"
      s3_lifecycle="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-lifecycle-configuration \
        --bucket "$bucket" 2>/dev/null)" || s3_lifecycle="{}"
      [[ -z "$s3_lifecycle" ]] && s3_lifecycle="{}"
      s3_cors="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-cors \
        --bucket "$bucket" 2>/dev/null)" || s3_cors="{}"
      [[ -z "$s3_cors" ]] && s3_cors="{}"
      jq -cn \
        --arg bucket "$bucket" \
        --argjson location "$s3_location" \
        --argjson versioning "$s3_versioning" \
        --argjson encryption "$s3_encryption" \
        --argjson public_access "$s3_public_access" \
        --argjson policy "$s3_policy" \
        --argjson lifecycle "$s3_lifecycle" \
        --argjson cors "$s3_cors" \
        --argjson notifications "$s3_notifications" \
        '{bucket_name:$bucket, location:$location, versioning:$versioning,
          encryption:$encryption, public_access:$public_access, policy:$policy,
          lifecycle:$lifecycle, cors:$cors, notifications:$notifications}' \
        >> "${out_dir}/raw/s3-bucket-details.ndjson"
    done <<< "$s3_bucket_names"
  fi

  progress "Cache & search — ElastiCache, MemoryDB, OpenSearch"
  # ---------- Cache: ElastiCache / MemoryDB ----------
  safe_aws_json "${out_dir}/raw/elasticache-replication-groups.json" elasticache describe-replication-groups
  safe_aws_json "${out_dir}/raw/elasticache-cache-clusters.json" elasticache describe-cache-clusters --show-cache-node-info
  safe_aws_json "${out_dir}/raw/elasticache-serverless-caches.json" elasticache describe-serverless-caches
  safe_aws_json "${out_dir}/raw/elasticache-users.json" elasticache describe-users
  safe_aws_json "${out_dir}/raw/elasticache-user-groups.json" elasticache describe-user-groups
  safe_aws_json "${out_dir}/raw/elasticache-subnet-groups.json" elasticache describe-cache-subnet-groups

  safe_aws_json "${out_dir}/raw/memorydb-clusters.json" memorydb describe-clusters
  safe_aws_json "${out_dir}/raw/memorydb-users.json" memorydb describe-users
  safe_aws_json "${out_dir}/raw/memorydb-acls.json" memorydb describe-acls
  safe_aws_json "${out_dir}/raw/memorydb-subnet-groups.json" memorydb describe-subnet-groups
  safe_aws_json "${out_dir}/raw/elasticache-parameter-groups.json" \
    elasticache describe-cache-parameter-groups
  local ec_pg_names
  ec_pg_names="$(jq -r '.CacheParameterGroups[]?.CacheParameterGroupName // empty' \
    "${out_dir}/raw/elasticache-parameter-groups.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/elasticache-parameter-group-contents.ndjson"
  while IFS= read -r pg; do
    [[ -z "$pg" ]] && continue
    aws "${AWS_ARGS[@]}" elasticache describe-cache-parameters \
      --cache-parameter-group-name "$pg" 2>/dev/null | \
      jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' >> "${out_dir}/raw/elasticache-parameter-group-contents.ndjson" || true
  done <<< "$ec_pg_names"
  safe_aws_json "${out_dir}/raw/elasticache-snapshots.json" elasticache describe-snapshots

  # ---------- OpenSearch / Elasticsearch ----------
  safe_aws_json "${out_dir}/raw/opensearch-domains.json" opensearch list-domain-names
  local os_domain_names
  os_domain_names="$(jq -r '.DomainNames[]?.DomainName // empty' "${out_dir}/raw/opensearch-domains.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/opensearch-domain-details.ndjson"
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    aws "${AWS_ARGS[@]}" opensearch describe-domain --domain-name "$domain" 2>/dev/null | \
      jq -c --arg d "$domain" '{domain_name:$d, data:.}' >> "${out_dir}/raw/opensearch-domain-details.ndjson" || true
  done <<< "$os_domain_names"

  if [[ "$skip_globals" != "true" ]]; then
    progress "DNS — Route53, Route53 Resolver"
    # ---------- Route53 / DNS ----------
    safe_aws_json "${out_dir}/raw/route53-hosted-zones.json" route53 list-hosted-zones
    local hz_ids
    hz_ids="$(jq -r '.HostedZones[]?.Id // empty' "${out_dir}/raw/route53-hosted-zones.json" | sed 's#^/hostedzone/##')"
    : > "${out_dir}/raw/route53-record-sets.ndjson"
    while IFS= read -r hz; do
      [[ -z "$hz" ]] && continue
      aws "${AWS_ARGS[@]}" route53 list-resource-record-sets --hosted-zone-id "$hz" 2>/dev/null | jq -c --arg hosted_zone_id "$hz" '{hosted_zone_id:$hosted_zone_id, data:.}' >> "${out_dir}/raw/route53-record-sets.ndjson" || true
    done <<< "$hz_ids"

    # Route53 hosted zone details (VPC associations for private zones)
    : > "${out_dir}/raw/route53-hosted-zone-details.ndjson"
    while IFS= read -r hz; do
      [[ -z "$hz" ]] && continue
      aws "${AWS_ARGS[@]}" route53 get-hosted-zone --id "$hz" 2>/dev/null | \
        jq -c --arg hz "$hz" '{hosted_zone_id:$hz, data:.}' >> "${out_dir}/raw/route53-hosted-zone-details.ndjson" || true
    done <<< "$hz_ids"

    safe_aws_json "${out_dir}/raw/route53-health-checks.json" route53 list-health-checks
    safe_aws_json "${out_dir}/raw/route53-traffic-policies.json" route53 list-traffic-policies
    safe_aws_json "${out_dir}/raw/route53-traffic-policy-instances.json" route53 list-traffic-policy-instances
    : > "${out_dir}/raw/route53-traffic-policy-versions.ndjson"
    while IFS= read -r tp_info; do
      [[ -z "$tp_info" ]] && continue
      local tp_id tp_ver
      tp_id="$(echo "$tp_info" | cut -d'|' -f1)"
      tp_ver="$(echo "$tp_info" | cut -d'|' -f2)"
      aws "${AWS_ARGS[@]}" route53 get-traffic-policy --id "$tp_id" --version "$tp_ver" 2>/dev/null | \
        jq -c --arg id "$tp_id" '{traffic_policy_id:$id, data:.}' >> "${out_dir}/raw/route53-traffic-policy-versions.ndjson" || true
    done < <(jq -r '.TrafficPolicySummaries[]? | [.Id, (.LatestVersion | tostring)] | join("|")' \
      "${out_dir}/raw/route53-traffic-policies.json" 2>/dev/null || true)
  fi

  progress "DNS — Route53 Resolver"
  # ---------- Route53 Resolver ----------
  safe_aws_json "${out_dir}/raw/r53resolver-endpoints.json" route53resolver list-resolver-endpoints
  local resolver_ep_ids
  resolver_ep_ids="$(jq -r '.ResolverEndpoints[]?.Id // empty' \
    "${out_dir}/raw/r53resolver-endpoints.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/r53resolver-endpoint-details.ndjson"
  : > "${out_dir}/raw/r53resolver-endpoint-ip-addresses.ndjson"
  while IFS= read -r ep_id; do
    [[ -z "$ep_id" ]] && continue
    aws "${AWS_ARGS[@]}" route53resolver get-resolver-endpoint --resolver-endpoint-id "$ep_id" 2>/dev/null | \
      jq -c --arg id "$ep_id" '{endpoint_id:$id, data:.}' >> "${out_dir}/raw/r53resolver-endpoint-details.ndjson" || true
    aws "${AWS_ARGS[@]}" route53resolver list-resolver-endpoint-ip-addresses \
      --resolver-endpoint-id "$ep_id" 2>/dev/null | \
      jq -c --arg id "$ep_id" '{endpoint_id:$id, data:.}' >> "${out_dir}/raw/r53resolver-endpoint-ip-addresses.ndjson" || true
  done <<< "$resolver_ep_ids"

  safe_aws_json "${out_dir}/raw/r53resolver-rules.json" route53resolver list-resolver-rules
  local resolver_rule_ids
  resolver_rule_ids="$(jq -r '.ResolverRules[]?.Id // empty' \
    "${out_dir}/raw/r53resolver-rules.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/r53resolver-rule-details.ndjson"
  while IFS= read -r rule_id; do
    [[ -z "$rule_id" ]] && continue
    aws "${AWS_ARGS[@]}" route53resolver get-resolver-rule --resolver-rule-id "$rule_id" 2>/dev/null | \
      jq -c --arg id "$rule_id" '{rule_id:$id, data:.}' >> "${out_dir}/raw/r53resolver-rule-details.ndjson" || true
  done <<< "$resolver_rule_ids"
  safe_aws_json "${out_dir}/raw/r53resolver-rule-associations.json" \
    route53resolver list-resolver-rule-associations

  if [[ "$skip_globals" != "true" ]]; then
    progress "IAM — roles, users, groups, policies, instance profiles"
    # ---------- IAM ----------
    safe_aws_json "${out_dir}/raw/iam-roles.json" iam list-roles
    local role_names
    role_names="$(jq -r '.Roles[]?.RoleName // empty' "${out_dir}/raw/iam-roles.json")"
    : > "${out_dir}/raw/iam-role-details.ndjson"
    : > "${out_dir}/raw/iam-role-inline-policies.ndjson"
    while IFS= read -r role; do
      [[ -z "$role" ]] && continue
      local managed inline trust
      managed="$(aws "${AWS_ARGS[@]}" iam list-attached-role-policies --role-name "$role" 2>/dev/null)" || managed="{}"
      [[ -z "$managed" ]] && managed="{}"
      inline="$(aws "${AWS_ARGS[@]}" iam list-role-policies --role-name "$role" 2>/dev/null)" || inline="{}"
      [[ -z "$inline" ]] && inline="{}"
      trust="$(aws "${AWS_ARGS[@]}" iam get-role --role-name "$role" 2>/dev/null)" || trust="{}"
      [[ -z "$trust" ]] && trust="{}"
      jq -cn \
        --arg role_name "$role" \
        --argjson trust "$trust" \
        --argjson managed "$managed" \
        --argjson inline "$inline" \
        '{role_name:$role_name, trust:$trust, managed:$managed, inline:$inline}' >> "${out_dir}/raw/iam-role-details.ndjson"
      while IFS= read -r policy_name; do
        [[ -z "$policy_name" ]] && continue
        aws "${AWS_ARGS[@]}" iam get-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null | \
          jq -c --arg role "$role" --arg policy "$policy_name" \
          '{role_name:$role, policy_name:$policy, data:.}' >> "${out_dir}/raw/iam-role-inline-policies.ndjson" || true
      done < <(echo "$inline" | jq -r '.PolicyNames[]? // empty')
    done <<< "$role_names"

    safe_aws_json "${out_dir}/raw/iam-instance-profiles.json" iam list-instance-profiles

    safe_aws_json "${out_dir}/raw/iam-users.json" iam list-users
    local iam_user_names
    iam_user_names="$(jq -r '.Users[]?.UserName // empty' "${out_dir}/raw/iam-users.json" 2>/dev/null || true)"
    : > "${out_dir}/raw/iam-user-details.ndjson"
    while IFS= read -r user; do
      [[ -z "$user" ]] && continue
      local u_managed u_inline
      u_managed="$(aws "${AWS_ARGS[@]}" iam list-attached-user-policies --user-name "$user" 2>/dev/null)" || u_managed="{}"
      [[ -z "$u_managed" ]] && u_managed="{}"
      u_inline="$(aws "${AWS_ARGS[@]}" iam list-user-policies --user-name "$user" 2>/dev/null)" || u_inline="{}"
      [[ -z "$u_inline" ]] && u_inline="{}"
      jq -cn \
        --arg user_name "$user" \
        --argjson managed "$u_managed" \
        --argjson inline "$u_inline" \
        '{user_name:$user_name, managed:$managed, inline:$inline}' >> "${out_dir}/raw/iam-user-details.ndjson"
    done <<< "$iam_user_names"

    safe_aws_json "${out_dir}/raw/iam-groups.json" iam list-groups
    local iam_group_names
    iam_group_names="$(jq -r '.Groups[]?.GroupName // empty' "${out_dir}/raw/iam-groups.json" 2>/dev/null || true)"
    : > "${out_dir}/raw/iam-group-details.ndjson"
    while IFS= read -r grp; do
      [[ -z "$grp" ]] && continue
      local g_managed g_inline
      g_managed="$(aws "${AWS_ARGS[@]}" iam list-attached-group-policies --group-name "$grp" 2>/dev/null)" || g_managed="{}"
      [[ -z "$g_managed" ]] && g_managed="{}"
      g_inline="$(aws "${AWS_ARGS[@]}" iam list-group-policies --group-name "$grp" 2>/dev/null)" || g_inline="{}"
      [[ -z "$g_inline" ]] && g_inline="{}"
      jq -cn \
        --arg group_name "$grp" \
        --argjson managed "$g_managed" \
        --argjson inline "$g_inline" \
        '{group_name:$group_name, managed:$managed, inline:$inline}' >> "${out_dir}/raw/iam-group-details.ndjson"
    done <<< "$iam_group_names"

    safe_aws_json "${out_dir}/raw/iam-local-policies.json" iam list-policies --scope Local
    : > "${out_dir}/raw/iam-local-policy-versions.ndjson"
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local p_arn p_ver
      p_arn="$(echo "$entry" | cut -d'|' -f1)"
      p_ver="$(echo "$entry" | cut -d'|' -f2)"
      aws "${AWS_ARGS[@]}" iam get-policy-version --policy-arn "$p_arn" --version-id "$p_ver" 2>/dev/null | \
        jq -c --arg arn "$p_arn" '{policy_arn:$arn, data:.}' >> "${out_dir}/raw/iam-local-policy-versions.ndjson" || true
    done < <(jq -r '.Policies[]? | [.Arn, .DefaultVersionId] | join("|")' \
      "${out_dir}/raw/iam-local-policies.json" 2>/dev/null || true)
  fi

  progress "Serverless — Lambda, API Gateway, Cognito"
  # ---------- Lambda ----------
  safe_aws_json "${out_dir}/raw/lambda-functions.json" lambda list-functions
  safe_aws_json "${out_dir}/raw/lambda-event-source-mappings.json" lambda list-event-source-mappings
  local lambda_names
  lambda_names="$(jq -r '.Functions[]?.FunctionName // empty' "${out_dir}/raw/lambda-functions.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/lambda-function-policies.ndjson"
  while IFS= read -r fn; do
    [[ -z "$fn" ]] && continue
    if lambda_policy_out="$(aws "${AWS_ARGS[@]}" lambda get-policy --function-name "$fn" 2>/dev/null)"; then
      echo "$lambda_policy_out" | jq -c --arg fn "$fn" '{function_name:$fn, data:.}' >> "${out_dir}/raw/lambda-function-policies.ndjson"
    fi
  done <<< "$lambda_names"

  # ---------- API Gateway (REST v1) ----------
  safe_aws_json "${out_dir}/raw/apigw-rest-apis.json" apigateway get-rest-apis
  safe_aws_json "${out_dir}/raw/apigw-domain-names.json" apigateway get-domain-names
  local rest_api_ids
  rest_api_ids="$(jq -r '.items[]?.id // empty' "${out_dir}/raw/apigw-rest-apis.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/apigw-rest-stages.ndjson"
  : > "${out_dir}/raw/apigw-rest-resources.ndjson"
  : > "${out_dir}/raw/apigw-rest-authorizers.ndjson"
  while IFS= read -r api_id; do
    [[ -z "$api_id" ]] && continue
    aws "${AWS_ARGS[@]}" apigateway get-stages --rest-api-id "$api_id" 2>/dev/null | \
      jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' >> "${out_dir}/raw/apigw-rest-stages.ndjson" || true
    aws "${AWS_ARGS[@]}" apigateway get-resources --rest-api-id "$api_id" \
      --embed methods/integrations 2>/dev/null | \
      jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' >> "${out_dir}/raw/apigw-rest-resources.ndjson" || true
    aws "${AWS_ARGS[@]}" apigateway get-authorizers --rest-api-id "$api_id" 2>/dev/null | \
      jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' >> "${out_dir}/raw/apigw-rest-authorizers.ndjson" || true
  done <<< "$rest_api_ids"

  # ---------- API Gateway (HTTP / WebSocket v2) ----------
  safe_aws_json "${out_dir}/raw/apigwv2-apis.json" apigatewayv2 get-apis
  safe_aws_json "${out_dir}/raw/apigwv2-domain-names.json" apigatewayv2 get-domain-names
  safe_aws_json "${out_dir}/raw/apigwv2-vpc-links.json" apigatewayv2 get-vpc-links
  local v2_api_ids
  v2_api_ids="$(jq -r '.Items[]?.ApiId // empty' "${out_dir}/raw/apigwv2-apis.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/apigwv2-stages.ndjson"
  : > "${out_dir}/raw/apigwv2-integrations.ndjson"
  : > "${out_dir}/raw/apigwv2-authorizers.ndjson"
  while IFS= read -r api_id; do
    [[ -z "$api_id" ]] && continue
    aws "${AWS_ARGS[@]}" apigatewayv2 get-stages --api-id "$api_id" 2>/dev/null | \
      jq -c --arg id "$api_id" '{api_id:$id, data:.}' >> "${out_dir}/raw/apigwv2-stages.ndjson" || true
    aws "${AWS_ARGS[@]}" apigatewayv2 get-integrations --api-id "$api_id" 2>/dev/null | \
      jq -c --arg id "$api_id" '{api_id:$id, data:.}' >> "${out_dir}/raw/apigwv2-integrations.ndjson" || true
    aws "${AWS_ARGS[@]}" apigatewayv2 get-authorizers --api-id "$api_id" 2>/dev/null | \
      jq -c --arg id "$api_id" '{api_id:$id, data:.}' >> "${out_dir}/raw/apigwv2-authorizers.ndjson" || true
  done <<< "$v2_api_ids"

  # ---------- Cognito ----------
  safe_aws_json "${out_dir}/raw/cognito-user-pools.json" \
    cognito-idp list-user-pools --max-results 60
  local cognito_pool_ids
  cognito_pool_ids="$(jq -r '.UserPools[]?.Id // empty' "${out_dir}/raw/cognito-user-pools.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/cognito-user-pool-details.ndjson"
  while IFS= read -r pool_id; do
    [[ -z "$pool_id" ]] && continue
    aws "${AWS_ARGS[@]}" cognito-idp describe-user-pool --user-pool-id "$pool_id" 2>/dev/null | \
      jq -c --arg id "$pool_id" '{user_pool_id:$id, data:.}' >> "${out_dir}/raw/cognito-user-pool-details.ndjson" || true
  done <<< "$cognito_pool_ids"

  progress "Observability — CloudWatch (logs, alarms, dashboards)"
  # ---------- CloudWatch Logs ----------
  safe_aws_json "${out_dir}/raw/logs-log-groups.json" logs describe-log-groups
  safe_aws_json "${out_dir}/raw/logs-metric-filters.json" logs describe-metric-filters

  # ---------- CloudWatch ----------
  safe_aws_json "${out_dir}/raw/cloudwatch-alarms.json" \
    cloudwatch describe-alarms --alarm-types MetricAlarm CompositeAlarm
  safe_aws_json "${out_dir}/raw/cloudwatch-anomaly-detectors.json" \
    cloudwatch describe-anomaly-detectors
  safe_aws_json "${out_dir}/raw/cloudwatch-dashboards.json" cloudwatch list-dashboards
  local dashboard_names
  dashboard_names="$(jq -r '.DashboardEntries[]?.DashboardName // empty' "${out_dir}/raw/cloudwatch-dashboards.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/cloudwatch-dashboard-bodies.ndjson"
  while IFS= read -r dashboard; do
    [[ -z "$dashboard" ]] && continue
    aws "${AWS_ARGS[@]}" cloudwatch get-dashboard --dashboard-name "$dashboard" 2>/dev/null | \
      jq -c --arg name "$dashboard" '{dashboard_name:$name, data:.}' >> "${out_dir}/raw/cloudwatch-dashboard-bodies.ndjson" || true
  done <<< "$dashboard_names"

  progress "Config & secrets — Secrets Manager, SSM Parameters"
  # ---------- Secrets / SSM params ----------
  safe_aws_json "${out_dir}/raw/secretsmanager-list-secrets.json" secretsmanager list-secrets
  local sm_secret_ids
  sm_secret_ids="$(jq -r '.SecretList[]?.ARN // empty' "${out_dir}/raw/secretsmanager-list-secrets.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/secretsmanager-secret-details.ndjson"
  : > "${out_dir}/raw/secretsmanager-secret-versions.ndjson"
  : > "${out_dir}/raw/secretsmanager-secret-policies.ndjson"
  while IFS= read -r secret_id; do
    [[ -z "$secret_id" ]] && continue
    aws "${AWS_ARGS[@]}" secretsmanager describe-secret --secret-id "$secret_id" 2>/dev/null | \
      jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' >> "${out_dir}/raw/secretsmanager-secret-details.ndjson" || true
    aws "${AWS_ARGS[@]}" secretsmanager list-secret-version-ids --secret-id "$secret_id" 2>/dev/null | \
      jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' >> "${out_dir}/raw/secretsmanager-secret-versions.ndjson" || true
    if sm_policy_out="$(aws "${AWS_ARGS[@]}" secretsmanager get-resource-policy \
        --secret-id "$secret_id" 2>/dev/null)"; then
      echo "$sm_policy_out" | jq -c --arg id "$secret_id" '{secret_id:$id, data:.}' \
        >> "${out_dir}/raw/secretsmanager-secret-policies.ndjson"
    fi
  done <<< "$sm_secret_ids"
  safe_aws_json "${out_dir}/raw/ssm-describe-parameters.json" ssm describe-parameters

  if [[ "$WITH_SECRET_VALUES" == "true" ]]; then
    echo "Exporting secret and parameter values for ${region}..."
    local secret_ids param_names
    secret_ids="$(jq -r '.SecretList[]?.ARN // empty' "${out_dir}/raw/secretsmanager-list-secrets.json")"
    : > "${out_dir}/raw/secretsmanager-secret-values.ndjson"
    while IFS= read -r secret_id; do
      [[ -z "$secret_id" ]] && continue
      aws "${AWS_ARGS[@]}" secretsmanager get-secret-value --secret-id "$secret_id" 2>/dev/null | jq -c '.' >> "${out_dir}/raw/secretsmanager-secret-values.ndjson" || true
    done <<< "$secret_ids"

    param_names="$(jq -r '.Parameters[]?.Name // empty' "${out_dir}/raw/ssm-describe-parameters.json")"
    : > "${out_dir}/raw/ssm-parameter-values.ndjson"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      aws "${AWS_ARGS[@]}" ssm get-parameter --name "$name" --with-decryption 2>/dev/null | jq -c '.' >> "${out_dir}/raw/ssm-parameter-values.ndjson" || true
    done <<< "$param_names"
  fi

  progress "Messaging — SQS, SNS, EventBridge, Step Functions, MQ, MSK, Kinesis, Firehose"
  # ---------- SQS ----------
  safe_aws_json "${out_dir}/raw/sqs-queues.json" sqs list-queues
  local queue_urls
  queue_urls="$(jq -r '.QueueUrls[]? // empty' "${out_dir}/raw/sqs-queues.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/sqs-queue-attributes.ndjson"
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    aws "${AWS_ARGS[@]}" sqs get-queue-attributes --queue-url "$url" --attribute-names All 2>/dev/null | \
      jq -c --arg url "$url" '{queue_url:$url, data:.}' >> "${out_dir}/raw/sqs-queue-attributes.ndjson" || true
  done <<< "$queue_urls"

  # ---------- SNS ----------
  safe_aws_json "${out_dir}/raw/sns-topics.json" sns list-topics
  local topic_arns
  topic_arns="$(jq -r '.Topics[]?.TopicArn // empty' "${out_dir}/raw/sns-topics.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/sns-topic-attributes.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    aws "${AWS_ARGS[@]}" sns get-topic-attributes --topic-arn "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{topic_arn:$arn, data:.}' >> "${out_dir}/raw/sns-topic-attributes.ndjson" || true
  done <<< "$topic_arns"
  safe_aws_json "${out_dir}/raw/sns-subscriptions.json" sns list-subscriptions

  # ---------- EventBridge ----------
  safe_aws_json "${out_dir}/raw/events-buses.json" events list-event-buses
  : > "${out_dir}/raw/events-rules.ndjson"
  : > "${out_dir}/raw/events-targets.ndjson"
  while IFS= read -r bus; do
    [[ -z "$bus" ]] && continue
    local bus_rules_file
    bus_rules_file="${out_dir}/raw/events-rules-${bus}.json"
    safe_aws_json "$bus_rules_file" events list-rules --event-bus-name "$bus"
    jq -c --arg bus "$bus" '{event_bus_name:$bus, data:.}' "$bus_rules_file" >> "${out_dir}/raw/events-rules.ndjson"
    while IFS= read -r rule; do
      [[ -z "$rule" ]] && continue
      aws "${AWS_ARGS[@]}" events list-targets-by-rule --rule "$rule" --event-bus-name "$bus" 2>/dev/null | \
        jq -c --arg rule "$rule" --arg bus "$bus" '{rule_name:$rule, event_bus_name:$bus, data:.}' >> "${out_dir}/raw/events-targets.ndjson" || true
    done < <(jq -r '.Rules[]?.Name // empty' "$bus_rules_file")
  done < <(jq -r '.EventBuses[]?.Name // empty' "${out_dir}/raw/events-buses.json" 2>/dev/null || true)

  # ---------- EventBridge Scheduler ----------
  safe_aws_json "${out_dir}/raw/scheduler-schedule-groups.json" scheduler list-schedule-groups
  safe_aws_json "${out_dir}/raw/scheduler-schedules.json" scheduler list-schedules

  # ---------- Step Functions ----------
  safe_aws_json "${out_dir}/raw/stepfunctions-state-machines.json" stepfunctions list-state-machines
  local sm_arns
  sm_arns="$(jq -r '.stateMachines[]?.stateMachineArn // empty' "${out_dir}/raw/stepfunctions-state-machines.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/stepfunctions-state-machine-details.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    aws "${AWS_ARGS[@]}" stepfunctions describe-state-machine --state-machine-arn "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{state_machine_arn:$arn, data:.}' >> "${out_dir}/raw/stepfunctions-state-machine-details.ndjson" || true
  done <<< "$sm_arns"

  # ---------- Amazon MQ ----------
  safe_aws_json "${out_dir}/raw/mq-brokers.json" mq list-brokers
  local broker_ids
  broker_ids="$(jq -r '.BrokerSummaries[]?.BrokerId // empty' "${out_dir}/raw/mq-brokers.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/mq-broker-details.ndjson"
  while IFS= read -r broker_id; do
    [[ -z "$broker_id" ]] && continue
    aws "${AWS_ARGS[@]}" mq describe-broker --broker-id "$broker_id" 2>/dev/null | \
      jq -c --arg id "$broker_id" '{broker_id:$id, data:.}' >> "${out_dir}/raw/mq-broker-details.ndjson" || true
  done <<< "$broker_ids"

  # ---------- MSK ----------
  safe_aws_json "${out_dir}/raw/kafka-clusters.json" kafka list-clusters-v2
  local kafka_arns
  kafka_arns="$(jq -r '.ClusterInfoList[]?.ClusterArn // empty' "${out_dir}/raw/kafka-clusters.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/kafka-cluster-details.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    aws "${AWS_ARGS[@]}" kafka describe-cluster-v2 --cluster-arn "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{cluster_arn:$arn, data:.}' >> "${out_dir}/raw/kafka-cluster-details.ndjson" || true
  done <<< "$kafka_arns"

  # ---------- Kinesis ----------
  safe_aws_json "${out_dir}/raw/kinesis-streams.json" kinesis list-streams
  local kinesis_stream_names
  kinesis_stream_names="$(jq -r '.StreamNames[]? // empty' "${out_dir}/raw/kinesis-streams.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/kinesis-stream-details.ndjson"
  while IFS= read -r stream; do
    [[ -z "$stream" ]] && continue
    aws "${AWS_ARGS[@]}" kinesis describe-stream-summary --stream-name "$stream" 2>/dev/null | \
      jq -c --arg s "$stream" '{stream_name:$s, data:.}' >> "${out_dir}/raw/kinesis-stream-details.ndjson" || true
  done <<< "$kinesis_stream_names"

  # ---------- Kinesis Firehose ----------
  safe_aws_json "${out_dir}/raw/firehose-delivery-streams.json" firehose list-delivery-streams
  local firehose_stream_names
  firehose_stream_names="$(jq -r '.DeliveryStreamNames[]? // empty' "${out_dir}/raw/firehose-delivery-streams.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/firehose-delivery-stream-details.ndjson"
  while IFS= read -r stream; do
    [[ -z "$stream" ]] && continue
    aws "${AWS_ARGS[@]}" firehose describe-delivery-stream --delivery-stream-name "$stream" 2>/dev/null | \
      jq -c --arg s "$stream" '{stream_name:$s, data:.}' >> "${out_dir}/raw/firehose-delivery-stream-details.ndjson" || true
  done <<< "$firehose_stream_names"

  progress "CI/CD — CodeBuild, CodePipeline, CodeDeploy, CodeStar"
  # ---------- CodeBuild ----------
  safe_aws_json "${out_dir}/raw/codebuild-projects.json" codebuild list-projects
  local cb_names_file
  cb_names_file="${out_dir}/raw/codebuild-project-names.txt"
  jq -r '.projects[]? // empty' "${out_dir}/raw/codebuild-projects.json" > "$cb_names_file" 2>/dev/null || true
  : > "${out_dir}/raw/codebuild-project-details.ndjson"
  if [[ -s "$cb_names_file" ]]; then
    while IFS= read -r batch; do
      [[ -z "$batch" ]] && continue
      aws "${AWS_ARGS[@]}" codebuild batch-get-projects --names $batch 2>/dev/null | \
        jq -c '.projects[]?' >> "${out_dir}/raw/codebuild-project-details.ndjson" || true
    done < <(chunk_lines_file 100 "$cb_names_file")
  fi

  # ---------- CodePipeline ----------
  safe_aws_json "${out_dir}/raw/codepipeline-pipelines.json" codepipeline list-pipelines
  local pipeline_names
  pipeline_names="$(jq -r '.pipelines[]?.name // empty' "${out_dir}/raw/codepipeline-pipelines.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/codepipeline-pipeline-details.ndjson"
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    aws "${AWS_ARGS[@]}" codepipeline get-pipeline --name "$name" 2>/dev/null | \
      jq -c --arg name "$name" '{pipeline_name:$name, data:.}' >> "${out_dir}/raw/codepipeline-pipeline-details.ndjson" || true
  done <<< "$pipeline_names"

  # ---------- CodeDeploy ----------
  safe_aws_json "${out_dir}/raw/codedeploy-applications.json" deploy list-applications
  local cd_app_names
  cd_app_names="$(jq -r '.applications[]? // empty' "${out_dir}/raw/codedeploy-applications.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/codedeploy-deployment-groups.ndjson"
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    local dg_names
    dg_names="$(aws "${AWS_ARGS[@]}" deploy list-deployment-groups --application-name "$app" 2>/dev/null \
      | jq -r '.deploymentGroups[]? // empty' || true)"
    while IFS= read -r dg; do
      [[ -z "$dg" ]] && continue
      aws "${AWS_ARGS[@]}" deploy get-deployment-group \
        --application-name "$app" --deployment-group-name "$dg" 2>/dev/null | \
        jq -c --arg app "$app" --arg dg "$dg" '{application_name:$app, deployment_group_name:$dg, data:.}' \
        >> "${out_dir}/raw/codedeploy-deployment-groups.ndjson" || true
    done <<< "$dg_names"
  done <<< "$cd_app_names"

  # ---------- CodeStar Connections ----------
  safe_aws_json "${out_dir}/raw/codestar-connections.json" codestar-connections list-connections

  if [[ "$skip_globals" != "true" ]]; then
    # ---------- IAM OIDC providers ----------
    safe_aws_json "${out_dir}/raw/iam-oidc-providers.json" iam list-open-id-connect-providers
    local oidc_arns
    oidc_arns="$(jq -r '.OpenIDConnectProviderList[]?.Arn // empty' "${out_dir}/raw/iam-oidc-providers.json" 2>/dev/null || true)"
    : > "${out_dir}/raw/iam-oidc-provider-details.ndjson"
    while IFS= read -r arn; do
      [[ -z "$arn" ]] && continue
      aws "${AWS_ARGS[@]}" iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" 2>/dev/null | \
        jq -c --arg arn "$arn" '{provider_arn:$arn, data:.}' >> "${out_dir}/raw/iam-oidc-provider-details.ndjson" || true
    done <<< "$oidc_arns"
  fi

  progress "Security & governance — KMS, CloudTrail, Config, GuardDuty, Security Hub, Access Analyzer"
  # ---------- KMS ----------
  safe_aws_json "${out_dir}/raw/kms-keys.json" kms list-keys
  safe_aws_json "${out_dir}/raw/kms-aliases.json" kms list-aliases
  local kms_key_ids
  kms_key_ids="$(jq -r '.Keys[]?.KeyId // empty' "${out_dir}/raw/kms-keys.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/kms-key-details.ndjson"
  : > "${out_dir}/raw/kms-key-policies.ndjson"
  while IFS= read -r key_id; do
    [[ -z "$key_id" ]] && continue
    aws "${AWS_ARGS[@]}" kms describe-key --key-id "$key_id" 2>/dev/null | \
      jq -c --arg id "$key_id" '{key_id:$id, data:.}' >> "${out_dir}/raw/kms-key-details.ndjson" || true
    if kms_policy_out="$(aws "${AWS_ARGS[@]}" kms get-key-policy --key-id "$key_id" --policy-name default 2>/dev/null)"; then
      echo "$kms_policy_out" | jq -c --arg id "$key_id" '{key_id:$id, data:.}' >> "${out_dir}/raw/kms-key-policies.ndjson"
    fi
  done <<< "$kms_key_ids"

  # ---------- CloudTrail ----------
  safe_aws_json "${out_dir}/raw/cloudtrail-trails.json" cloudtrail describe-trails
  local trail_arns
  trail_arns="$(jq -r '.trailList[]?.TrailARN // empty' "${out_dir}/raw/cloudtrail-trails.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/cloudtrail-trail-status.ndjson"
  : > "${out_dir}/raw/cloudtrail-event-selectors.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    aws "${AWS_ARGS[@]}" cloudtrail get-trail-status --name "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{trail_arn:$arn, data:.}' >> "${out_dir}/raw/cloudtrail-trail-status.ndjson" || true
    aws "${AWS_ARGS[@]}" cloudtrail get-event-selectors --trail-name "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{trail_arn:$arn, data:.}' >> "${out_dir}/raw/cloudtrail-event-selectors.ndjson" || true
  done <<< "$trail_arns"

  # ---------- AWS Config ----------
  safe_aws_json "${out_dir}/raw/config-recorders.json" configservice describe-configuration-recorders
  safe_aws_json "${out_dir}/raw/config-delivery-channels.json" configservice describe-delivery-channels
  safe_aws_json "${out_dir}/raw/config-rules.json" configservice describe-config-rules

  # ---------- GuardDuty ----------
  safe_aws_json "${out_dir}/raw/guardduty-detectors.json" guardduty list-detectors
  local gd_ids
  gd_ids="$(jq -r '.DetectorIds[]? // empty' "${out_dir}/raw/guardduty-detectors.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/guardduty-detector-details.ndjson"
  while IFS= read -r det_id; do
    [[ -z "$det_id" ]] && continue
    aws "${AWS_ARGS[@]}" guardduty get-detector --detector-id "$det_id" 2>/dev/null | \
      jq -c --arg id "$det_id" '{detector_id:$id, data:.}' >> "${out_dir}/raw/guardduty-detector-details.ndjson" || true
  done <<< "$gd_ids"

  # ---------- Security Hub ----------
  safe_aws_json "${out_dir}/raw/securityhub-hub.json" securityhub describe-hub
  safe_aws_json "${out_dir}/raw/securityhub-standards.json" securityhub list-standards-subscriptions

  # ---------- Access Analyzer ----------
  safe_aws_json "${out_dir}/raw/accessanalyzer-analyzers.json" accessanalyzer list-analyzers
  local analyzer_arns
  analyzer_arns="$(jq -r '.analyzers[]?.arn // empty' "${out_dir}/raw/accessanalyzer-analyzers.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/accessanalyzer-findings.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    aws "${AWS_ARGS[@]}" accessanalyzer list-findings --analyzer-arn "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{analyzer_arn:$arn, data:.}' >> "${out_dir}/raw/accessanalyzer-findings.ndjson" || true
  done <<< "$analyzer_arns"

  if [[ "$skip_globals" != "true" ]]; then
    # ---------- Organizations ----------
    safe_aws_json "${out_dir}/raw/organizations-organization.json" organizations describe-organization
    safe_aws_json "${out_dir}/raw/organizations-accounts.json" organizations list-accounts
    safe_aws_json "${out_dir}/raw/organizations-scps.json" \
      organizations list-policies --filter SERVICE_CONTROL_POLICY
    local scp_ids
    scp_ids="$(jq -r '.Policies[]?.Id // empty' "${out_dir}/raw/organizations-scps.json" 2>/dev/null || true)"
    : > "${out_dir}/raw/organizations-scp-details.ndjson"
    while IFS= read -r scp_id; do
      [[ -z "$scp_id" ]] && continue
      local scp_policy_out scp_targets_out
      scp_policy_out="$(aws "${AWS_ARGS[@]}" organizations describe-policy --policy-id "$scp_id" 2>/dev/null)" || scp_policy_out="{}"
      [[ -z "$scp_policy_out" ]] && scp_policy_out="{}"
      scp_targets_out="$(aws "${AWS_ARGS[@]}" organizations list-targets-for-policy --policy-id "$scp_id" 2>/dev/null)" || scp_targets_out="{}"
      [[ -z "$scp_targets_out" ]] && scp_targets_out="{}"
      jq -cn \
        --arg id "$scp_id" \
        --argjson policy "$scp_policy_out" \
        --argjson targets "$scp_targets_out" \
        '{policy_id:$id, policy:$policy, targets:$targets}' >> "${out_dir}/raw/organizations-scp-details.ndjson"
    done <<< "$scp_ids"
  fi

  progress "Building derived topology files..."
  OUT_DIR="$out_dir" "$(dirname "$0")/derive-topology.sh"

  cat > "${OUT_ROOT}/latest.json" <<EOF
{
  "folder": "$(basename "$out_dir")"
}
EOF

  progress "✓ Snapshot complete — $(basename "$out_dir")"
  echo
  echo "Snapshot complete: ${out_dir}"
}

if [[ "$ALL_REGIONS" == "true" ]]; then
  if [[ -n "$REGION" ]]; then
    echo "Do not combine --region with --all-regions." >&2
    exit 1
  fi

  mkdir -p "$OUT_ROOT"
  REGIONS_FILE="$(mktemp)"
  aws "${BASE_AWS_ARGS[@]}" ec2 describe-regions --all-regions --query 'Regions[?OptInStatus==`opt-in-not-required` || OptInStatus==`opted-in`].RegionName' --output text | tr '\t' '\n' | sort > "$REGIONS_FILE"
  first_snapshot_folder=""
  while IFS= read -r region; do
    [[ -z "$region" ]] && continue
    echo
    echo "=== Exporting region: ${region} ==="
    if [[ -z "$first_snapshot_folder" ]]; then
      run_snapshot_for_region "$region" "false"
      first_snapshot_folder="$(jq -r '.folder' "${OUT_ROOT}/latest.json" 2>/dev/null || true)"
    else
      run_snapshot_for_region "$region" "true"
    fi
  done < "$REGIONS_FILE"
  rm -f "$REGIONS_FILE"
  # Point latest.json at the first snapshot — the only one with global data (IAM, Route53, S3, etc.)
  if [[ -n "$first_snapshot_folder" ]]; then
    cat > "${OUT_ROOT}/latest.json" <<EOF
{
  "folder": "${first_snapshot_folder}"
}
EOF
  fi
else
  REGION="$(resolve_default_region || true)"
  if [[ -z "$REGION" ]]; then
    echo "No AWS region resolved. Pass --region <region>, set AWS_REGION/AWS_DEFAULT_REGION, or configure a default region in the AWS profile." >&2
    exit 1
  fi
  mkdir -p "$OUT_ROOT"
  run_snapshot_for_region "$REGION"
fi
