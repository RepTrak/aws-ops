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

  safe_aws_json() {
    local outfile="$1"
    shift
    echo "→ $outfile"
    if aws "${AWS_ARGS[@]}" "$@" > "$outfile" 2>"${outfile}.stderr"; then
      rm -f "${outfile}.stderr"
    else
      echo "WARN: failed in ${region}: aws $*" >&2
      rm -f "${outfile}.stderr"
      echo '{}' > "$outfile"
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

  progress "Compute — ECR (repositories, images, scanning)"
  # ---------- ECR ----------
  safe_aws_json "${out_dir}/raw/ecr-repositories.json" ecr describe-repositories
  safe_aws_json "${out_dir}/raw/ecr-registry-scanning-config.json" --cli-read-timeout 30 ecr get-registry-scanning-configuration
  local repo_names
  repo_names="$(jq -r '.repositories[]?.repositoryName // empty' "${out_dir}/raw/ecr-repositories.json" 2>/dev/null || true)"
  : > "${out_dir}/raw/ecr-repository-policies.ndjson"
  : > "${out_dir}/raw/ecr-lifecycle-policies.ndjson"
  : > "${out_dir}/raw/ecr-images.ndjson"
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    if policy_out="$(aws "${AWS_ARGS[@]}" ecr get-repository-policy --repository-name "$repo" 2>/dev/null)"; then
      echo "$policy_out" | jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' >> "${out_dir}/raw/ecr-repository-policies.ndjson"
    fi
    if lifecycle_out="$(aws "${AWS_ARGS[@]}" ecr get-lifecycle-policy --repository-name "$repo" 2>/dev/null)"; then
      echo "$lifecycle_out" | jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' >> "${out_dir}/raw/ecr-lifecycle-policies.ndjson"
    fi
    aws "${AWS_ARGS[@]}" ecr describe-images --repository-name "$repo" 2>/dev/null | jq -c --arg repo "$repo" '{repository_name:$repo, data:.}' >> "${out_dir}/raw/ecr-images.ndjson" || true
  done <<< "$repo_names"

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
    mt_out="$(aws "${AWS_ARGS[@]}" efs describe-mount-targets --file-system-id "$fs" 2>/dev/null || echo '{}')"
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
    : > "${out_dir}/raw/s3-bucket-details.ndjson"
    while IFS= read -r bucket; do
      [[ -z "$bucket" ]] && continue
      local s3_location s3_versioning s3_encryption s3_public_access \
            s3_policy s3_lifecycle s3_cors s3_notifications
      # get-bucket-location works from any region; response gives the bucket's actual region
      s3_location="$(aws "${BASE_AWS_ARGS[@]}" s3api get-bucket-location \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      local bucket_region
      bucket_region="$(echo "$s3_location" | jq -r '.LocationConstraint // "us-east-1"')"
      local -a BUCKET_ARGS=("${BASE_AWS_ARGS[@]}" --region "$bucket_region")
      s3_versioning="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-versioning \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_public_access="$(aws "${BUCKET_ARGS[@]}" s3api get-public-access-block \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_notifications="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-notification-configuration \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_encryption="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-encryption \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_policy="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-policy \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_lifecycle="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-lifecycle-configuration \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
      s3_cors="$(aws "${BUCKET_ARGS[@]}" s3api get-bucket-cors \
        --bucket "$bucket" 2>/dev/null || echo '{}')"
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
      managed="$(aws "${AWS_ARGS[@]}" iam list-attached-role-policies --role-name "$role" 2>/dev/null || echo '{}')"
      inline="$(aws "${AWS_ARGS[@]}" iam list-role-policies --role-name "$role" 2>/dev/null || echo '{}')"
      trust="$(aws "${AWS_ARGS[@]}" iam get-role --role-name "$role" 2>/dev/null || echo '{}')"
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
      u_managed="$(aws "${AWS_ARGS[@]}" iam list-attached-user-policies --user-name "$user" 2>/dev/null || echo '{}')"
      u_inline="$(aws "${AWS_ARGS[@]}" iam list-user-policies --user-name "$user" 2>/dev/null || echo '{}')"
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
      g_managed="$(aws "${AWS_ARGS[@]}" iam list-attached-group-policies --group-name "$grp" 2>/dev/null || echo '{}')"
      g_inline="$(aws "${AWS_ARGS[@]}" iam list-group-policies --group-name "$grp" 2>/dev/null || echo '{}')"
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
      scp_policy_out="$(aws "${AWS_ARGS[@]}" organizations describe-policy --policy-id "$scp_id" 2>/dev/null || echo '{}')"
      scp_targets_out="$(aws "${AWS_ARGS[@]}" organizations list-targets-for-policy --policy-id "$scp_id" 2>/dev/null || echo '{}')"
      jq -cn \
        --arg id "$scp_id" \
        --argjson policy "$scp_policy_out" \
        --argjson targets "$scp_targets_out" \
        '{policy_id:$id, policy:$policy, targets:$targets}' >> "${out_dir}/raw/organizations-scp-details.ndjson"
    done <<< "$scp_ids"
  fi

  progress "Building derived topology files..."
  export OUT_DIR="$out_dir"
  python3 <<'PY'
import json
import os
import urllib.parse
from pathlib import Path

out = Path(os.environ['OUT_DIR'])
raw = out / 'raw'
derived = out / 'derived'
derived.mkdir(parents=True, exist_ok=True)


def load_json(name, default=None):
    path = raw / name
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:
        return default

def load_ndjson(name):
    path = raw / name
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue
    return records

summary = {}
summary['ecs_cluster_count'] = len((load_json('ecs-clusters.json', {}) or {}).get('clusterArns', []) or [])
summary['ecs_task_definition_count'] = len((load_json('ecs-list-task-definitions.json', {}) or {}).get('taskDefinitionArns', []) or [])
summary['load_balancer_count'] = len((load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers', []) or [])
summary['target_group_count'] = len((load_json('elbv2-target-groups.json', {}) or {}).get('TargetGroups', []) or [])
summary['vpc_count'] = len((load_json('ec2-vpcs.json', {}) or {}).get('Vpcs', []) or [])
summary['subnet_count'] = len((load_json('ec2-subnets.json', {}) or {}).get('Subnets', []) or [])
summary['security_group_count'] = len((load_json('ec2-security-groups.json', {}) or {}).get('SecurityGroups', []) or [])
summary['rds_instance_count'] = len((load_json('rds-db-instances.json', {}) or {}).get('DBInstances', []) or [])
summary['rds_proxy_count'] = len((load_json('rds-db-proxies.json', {}) or {}).get('DBProxies', []) or [])
summary['ec2_ecs_instance_count'] = sum(
    len(r.get('Instances', []))
    for r in (load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations', []) or []
)
summary['rds_snapshot_count'] = len((load_json('rds-db-snapshots.json', {}) or {}).get('DBSnapshots', []) or [])
summary['redshift_cluster_count'] = len((load_json('redshift-clusters.json', {}) or {}).get('Clusters', []) or [])
summary['redshift_serverless_workgroup_count'] = len((load_json('redshift-serverless-workgroups.json', {}) or {}).get('workgroups', []) or [])
summary['redshift_serverless_namespace_count'] = len((load_json('redshift-serverless-namespaces.json', {}) or {}).get('namespaces', []) or [])
summary['efs_file_system_count'] = len((load_json('efs-file-systems.json', {}) or {}).get('FileSystems', []) or [])
summary['s3_bucket_count'] = len((load_json('s3-buckets.json', {}) or {}).get('Buckets', []) or [])
summary['dynamodb_table_count'] = len((load_json('dynamodb-tables.json', {}) or {}).get('TableNames', []) or [])
summary['docdb_cluster_count'] = len((load_json('docdb-clusters.json', {}) or {}).get('DBClusters', []) or [])
summary['lambda_function_count'] = len((load_json('lambda-functions.json', {}) or {}).get('Functions', []) or [])
summary['lambda_event_source_mapping_count'] = len((load_json('lambda-event-source-mappings.json', {}) or {}).get('EventSourceMappings', []) or [])
summary['apigw_rest_api_count'] = len((load_json('apigw-rest-apis.json', {}) or {}).get('items', []) or [])
summary['apigwv2_api_count'] = len((load_json('apigwv2-apis.json', {}) or {}).get('Items', []) or [])
summary['cognito_user_pool_count'] = len((load_json('cognito-user-pools.json', {}) or {}).get('UserPools', []) or [])
summary['ecr_repository_count'] = len((load_json('ecr-repositories.json', {}) or {}).get('repositories', []) or [])
summary['acm_certificate_count'] = len((load_json('acm-certificates.json', {}) or {}).get('CertificateSummaryList', []) or [])
_wafv2_r = load_json('wafv2-webacls-regional.json', {}) or {}
_wafv2_cf = load_json('wafv2-webacls-cloudfront.json', {}) or {}
summary['wafv2_webacl_count'] = len(_wafv2_r.get('WebACLs', []) or []) + len(_wafv2_cf.get('WebACLs', []) or [])
summary['cloudfront_distribution_count'] = len((((load_json('cloudfront-distributions.json', {}) or {}).get('DistributionList') or {}).get('Items') or []))
summary['asg_count'] = len((load_json('autoscaling-groups.json', {}) or {}).get('AutoScalingGroups', []) or [])
summary['launch_template_count'] = len((load_json('ec2-launch-templates.json', {}) or {}).get('LaunchTemplates', []) or [])
summary['log_group_count'] = len((load_json('logs-log-groups.json', {}) or {}).get('logGroups', []) or [])
_cw_alarms = load_json('cloudwatch-alarms.json', {}) or {}
summary['cloudwatch_alarm_count'] = (
    len(_cw_alarms.get('MetricAlarms', []) or []) +
    len(_cw_alarms.get('CompositeAlarms', []) or [])
)
summary['sqs_queue_count'] = len((load_json('sqs-queues.json', {}) or {}).get('QueueUrls', []) or [])
summary['sns_topic_count'] = len((load_json('sns-topics.json', {}) or {}).get('Topics', []) or [])
summary['eventbridge_bus_count'] = len((load_json('events-buses.json', {}) or {}).get('EventBuses', []) or [])
summary['stepfunctions_count'] = len((load_json('stepfunctions-state-machines.json', {}) or {}).get('stateMachines', []) or [])
summary['msk_cluster_count'] = len((load_json('kafka-clusters.json', {}) or {}).get('ClusterInfoList', []) or [])
summary['kinesis_stream_count'] = len((load_json('kinesis-streams.json', {}) or {}).get('StreamNames', []) or [])
summary['firehose_stream_count'] = len((load_json('firehose-delivery-streams.json', {}) or {}).get('DeliveryStreamNames', []) or [])
summary['opensearch_domain_count'] = len((load_json('opensearch-domains.json', {}) or {}).get('DomainNames', []) or [])
summary['codebuild_project_count'] = len((load_json('codebuild-projects.json', {}) or {}).get('projects', []) or [])
summary['codepipeline_count'] = len((load_json('codepipeline-pipelines.json', {}) or {}).get('pipelines', []) or [])
summary['codedeploy_application_count'] = len((load_json('codedeploy-applications.json', {}) or {}).get('applications', []) or [])
summary['kms_key_count'] = len((load_json('kms-keys.json', {}) or {}).get('Keys', []) or [])
summary['cloudtrail_trail_count'] = len((load_json('cloudtrail-trails.json', {}) or {}).get('trailList', []) or [])
summary['guardduty_detector_count'] = len((load_json('guardduty-detectors.json', {}) or {}).get('DetectorIds', []) or [])
summary['iam_user_count'] = len((load_json('iam-users.json', {}) or {}).get('Users', []) or [])
summary['iam_group_count'] = len((load_json('iam-groups.json', {}) or {}).get('Groups', []) or [])
summary['iam_local_policy_count'] = len((load_json('iam-local-policies.json', {}) or {}).get('Policies', []) or [])
summary['accessanalyzer_count'] = len((load_json('accessanalyzer-analyzers.json', {}) or {}).get('analyzers', []) or [])
summary['secret_count'] = len((load_json('secretsmanager-list-secrets.json', {}) or {}).get('SecretList', []) or [])
summary['hosted_zone_count'] = len((load_json('route53-hosted-zones.json', {}) or {}).get('HostedZones', []) or [])
summary['route53_health_check_count'] = len((load_json('route53-health-checks.json', {}) or {}).get('HealthChecks', []) or [])
summary['elastic_ip_count'] = len((load_json('ec2-addresses.json', {}) or {}).get('Addresses', []) or [])
summary['vpc_peering_count'] = len((load_json('ec2-vpc-peering-connections.json', {}) or {}).get('VpcPeeringConnections', []) or [])
summary['resolver_endpoint_count'] = len((load_json('r53resolver-endpoints.json', {}) or {}).get('ResolverEndpoints', []) or [])
summary['resource_explorer_view_present'] = (raw / 'resource-explorer-2-search.json').exists()

# Consumer mapping: which task definitions reference which secrets / SSM parameters
secret_consumers = {}
param_consumers = {}
td_ndjson = raw / 'ecs-describe-task-definitions.ndjson'
if td_ndjson.exists():
    for line in td_ndjson.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
        td = (record.get('data') or record).get('taskDefinition') or {}
        td_ref = f'{td.get("family", "")}:{td.get("revision", "")}'
        for container in (td.get('containerDefinitions') or []):
            cname = container.get('name', '')
            for s in (container.get('secrets') or []):
                ref = s.get('valueFrom', '')
                entry = {'task_definition': td_ref, 'container': cname, 'env_name': s.get('name', '')}
                if 'arn:aws:ssm:' in ref or ref.startswith('/'):
                    param_consumers.setdefault(ref, []).append(entry)
                else:
                    secret_consumers.setdefault(ref, []).append(entry)

(derived / 'secret_consumers.json').write_text(json.dumps(secret_consumers, indent=2) + '\n')
(derived / 'param_consumers.json').write_text(json.dumps(param_consumers, indent=2) + '\n')
summary['mapped_secret_refs'] = len(secret_consumers)
summary['mapped_param_refs'] = len(param_consumers)

# --- derived/sg_connectivity.json ---
# SG-to-SG and SG-to-CIDR inbound edges. The primary reliable mechanism for
# inferring which services can reach which data resources (ECS → RDS, ECS →
# ElastiCache) without relying on naming heuristics.
sgs = (load_json('ec2-security-groups.json', {}) or {}).get('SecurityGroups', []) or []
sg_names = {sg.get('GroupId', ''): sg.get('GroupName', '') for sg in sgs}
sg_edges = []
for sg in sgs:
    to_sg = sg.get('GroupId', '')
    for rule in (sg.get('IpPermissions') or []):
        proto = rule.get('IpProtocol', '')
        fp = rule.get('FromPort')
        tp = rule.get('ToPort')
        for pair in (rule.get('UserIdGroupPairs') or []):
            from_sg = pair.get('GroupId', '')
            if from_sg:
                sg_edges.append({'from_sg': from_sg, 'to_sg': to_sg,
                                  'protocol': proto, 'from_port': fp, 'to_port': tp})
        for cidr in (rule.get('IpRanges') or []):
            sg_edges.append({'from_cidr': cidr.get('CidrIp', ''), 'to_sg': to_sg,
                              'protocol': proto, 'from_port': fp, 'to_port': tp})
        for cidr6 in (rule.get('Ipv6Ranges') or []):
            sg_edges.append({'from_cidr': cidr6.get('CidrIpv6', ''), 'to_sg': to_sg,
                              'protocol': proto, 'from_port': fp, 'to_port': tp})
(derived / 'sg_connectivity.json').write_text(json.dumps(
    {'edges': sg_edges, 'sg_names': sg_names}, indent=2) + '\n')
summary['derived_sg_edges'] = len(sg_edges)

# --- derived/alb_to_service.json ---
# Pre-joins ALB → target group → ECS service. Collapses a three-file join into
# a single lookup so the navigator does not have to traverse raw files.
tgs = (load_json('elbv2-target-groups.json', {}) or {}).get('TargetGroups', []) or []
tg_to_albs = {tg.get('TargetGroupArn', ''): tg.get('LoadBalancerArns', []) or []
              for tg in tgs}
tg_names = {tg.get('TargetGroupArn', ''): tg.get('TargetGroupName', '') for tg in tgs}
tg_to_services = {}
for _rec in load_ndjson('ecs-services.ndjson'):
    for svc in ((_rec.get('data') or {}).get('services') or []):
        svc_arn = svc.get('serviceArn', '')
        for _lb in (svc.get('loadBalancers') or []):
            tg_arn = _lb.get('targetGroupArn', '')
            if tg_arn and svc_arn:
                tg_to_services.setdefault(tg_arn, []).append(svc_arn)
lbs = (load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers', []) or []
alb_to_service = {}
for _lb in lbs:
    lb_arn = _lb.get('LoadBalancerArn', '')
    assoc_tgs = [t for t, alb_arns in tg_to_albs.items() if lb_arn in alb_arns]
    assoc_svcs = list({s for t in assoc_tgs for s in tg_to_services.get(t, [])})
    alb_to_service[lb_arn] = {
        'name': _lb.get('LoadBalancerName', ''),
        'scheme': _lb.get('Scheme', ''),
        'dns_name': _lb.get('DNSName', ''),
        'target_groups': [{'arn': t, 'name': tg_names.get(t, '')} for t in assoc_tgs],
        'ecs_services': assoc_svcs,
    }
(derived / 'alb_to_service.json').write_text(json.dumps(alb_to_service, indent=2) + '\n')
summary['derived_alb_mappings'] = len(alb_to_service)

# --- derived/service_topology.json ---
# Per ECS service: active task definition, image URIs, log groups, EFS mounts,
# Cloud Map registration, port mappings, subnets, security groups.
# Collapses the service → task def → container defs chain into one lookup.
_td_lookup = {}
for _rec in load_ndjson('ecs-describe-task-definitions.ndjson'):
    _arn = _rec.get('task_definition_arn', '')
    _td = (_rec.get('data') or {}).get('taskDefinition') or {}
    if _arn:
        _td_lookup[_arn] = _td
_cm_lookup = {}
for _rec in load_ndjson('servicediscovery-services.ndjson'):
    _svc_data = (_rec.get('data') or {}).get('Service') or {}
    _arn = _svc_data.get('Arn', '')
    if _arn:
        _cm_lookup[_arn] = _svc_data
service_topology = {}
for _rec in load_ndjson('ecs-services.ndjson'):
    for svc in ((_rec.get('data') or {}).get('services') or []):
        svc_arn = svc.get('serviceArn', '')
        if not svc_arn:
            continue
        td_arn = svc.get('taskDefinition', '')
        td = _td_lookup.get(td_arn, {})
        containers = []
        for c in (td.get('containerDefinitions') or []):
            log_cfg = c.get('logConfiguration') or {}
            log_group = ''
            if log_cfg.get('logDriver') == 'awslogs':
                log_group = (log_cfg.get('options') or {}).get('awslogs-group', '')
            containers.append({
                'name': c.get('name', ''),
                'image': c.get('image', ''),
                'log_group': log_group,
                'port_mappings': c.get('portMappings') or [],
            })
        efs_vols = []
        for vol in (td.get('volumes') or []):
            efs_cfg = vol.get('efsVolumeConfiguration')
            if efs_cfg:
                efs_vols.append({
                    'volume_name': vol.get('name', ''),
                    'file_system_id': efs_cfg.get('fileSystemId', ''),
                    'access_point_id': (efs_cfg.get('authorizationConfig') or {}).get('accessPointId', ''),
                })
        cloud_map = []
        for reg in (svc.get('serviceRegistries') or []):
            reg_arn = reg.get('registryArn', '')
            _cm = _cm_lookup.get(reg_arn, {})
            cloud_map.append({
                'registry_arn': reg_arn,
                'service_name': _cm.get('Name', ''),
                'namespace_id': _cm.get('NamespaceId', ''),
            })
        net = (svc.get('networkConfiguration') or {}).get('awsvpcConfiguration') or {}
        service_topology[svc_arn] = {
            'service_name': svc.get('serviceName', ''),
            'cluster_arn': svc.get('clusterArn', ''),
            'task_definition_arn': td_arn,
            'desired_count': svc.get('desiredCount', 0),
            'running_count': svc.get('runningCount', 0),
            'pending_count': svc.get('pendingCount', 0),
            'containers': containers,
            'efs_volumes': efs_vols,
            'cloud_map': cloud_map,
            'subnets': net.get('subnets') or [],
            'security_groups': net.get('securityGroups') or [],
            'load_balancer_target_groups': [
                _lb.get('targetGroupArn', '') for _lb in (svc.get('loadBalancers') or [])
            ],
        }
(derived / 'service_topology.json').write_text(json.dumps(service_topology, indent=2) + '\n')
summary['derived_service_topologies'] = len(service_topology)

# --- derived/cloudwatch_alarm_targets.json ---
# Maps each alarm to: the resource it monitors (via namespace + dimensions) and
# what it triggers (alarm actions classified by type).
def _alarm_action_type(arn):
    if ':application-autoscaling:' in arn or ('autoscaling' in arn and 'scalingPolic' in arn):
        return 'autoscaling_policy'
    if ':sns:' in arn:
        return 'sns_topic'
    if ':lambda:' in arn:
        return 'lambda'
    if ':autoscaling:' in arn:
        return 'ec2_autoscaling'
    return 'other'

def _alarm_resource(namespace, dims):
    dm = {d.get('Name', ''): d.get('Value', '') for d in (dims or [])}
    if namespace == 'AWS/ECS':
        return 'ecs_service', {'cluster': dm.get('ClusterName', ''), 'service': dm.get('ServiceName', '')}
    if namespace in ('AWS/ApplicationELB', 'AWS/NetworkELB'):
        return 'load_balancer', {'target_group': dm.get('TargetGroup', ''), 'load_balancer': dm.get('LoadBalancer', '')}
    if namespace == 'AWS/RDS':
        return 'rds_instance', {'db_instance': dm.get('DBInstanceIdentifier', ''), 'db_cluster': dm.get('DBClusterIdentifier', '')}
    if namespace == 'AWS/Redshift':
        return 'redshift_cluster', {'cluster': dm.get('ClusterIdentifier', '')}
    if namespace == 'AWS/ElastiCache':
        return 'elasticache', {'replication_group': dm.get('ReplicationGroupId', ''), 'cluster': dm.get('CacheClusterId', '')}
    if namespace == 'AWS/SQS':
        return 'sqs_queue', {'queue': dm.get('QueueName', '')}
    if namespace == 'AWS/Lambda':
        return 'lambda_function', {'function': dm.get('FunctionName', '')}
    if namespace == 'AWS/DynamoDB':
        return 'dynamodb_table', {'table': dm.get('TableName', '')}
    return 'unknown', {}

cw_data = load_json('cloudwatch-alarms.json', {}) or {}
alarm_targets = {}
for alarm in (cw_data.get('MetricAlarms') or []):
    _arn = alarm.get('AlarmArn', '')
    if not _arn:
        continue
    _rtype, _rids = _alarm_resource(alarm.get('Namespace', ''), alarm.get('Dimensions'))
    alarm_targets[_arn] = {
        'alarm_name': alarm.get('AlarmName', ''),
        'metric': alarm.get('MetricName', ''),
        'namespace': alarm.get('Namespace', ''),
        'resource_type': _rtype,
        'resource_ids': _rids,
        'threshold': alarm.get('Threshold'),
        'comparison': alarm.get('ComparisonOperator', ''),
        'state': alarm.get('StateValue', ''),
        'alarm_actions': [{'arn': a, 'type': _alarm_action_type(a)}
                          for a in (alarm.get('AlarmActions') or [])],
    }
for alarm in (cw_data.get('CompositeAlarms') or []):
    _arn = alarm.get('AlarmArn', '')
    if not _arn:
        continue
    alarm_targets[_arn] = {
        'alarm_name': alarm.get('AlarmName', ''),
        'alarm_rule': alarm.get('AlarmRule', ''),
        'resource_type': 'composite',
        'resource_ids': {},
        'state': alarm.get('StateValue', ''),
        'alarm_actions': [{'arn': a, 'type': _alarm_action_type(a)}
                          for a in (alarm.get('AlarmActions') or [])],
    }
(derived / 'cloudwatch_alarm_targets.json').write_text(json.dumps(alarm_targets, indent=2) + '\n')
summary['derived_alarm_targets'] = len(alarm_targets)

# --- derived/subnet_classification.json ---
# Classifies every subnet as public or private by tracing its effective route table
# to see whether a 0.0.0.0/0 route exits through an Internet Gateway.
# Also surfaces AZ, VPC, CIDR, and Name tag so the navigator can lay out the
# network tier without joining three files.
_igws = (load_json('ec2-internet-gateways.json', {}) or {}).get('InternetGateways', []) or []
_igw_ids = {igw.get('InternetGatewayId', '') for igw in _igws}
_route_tables = (load_json('ec2-route-tables.json', {}) or {}).get('RouteTables', []) or []
_vpc_to_main_rt = {}   # vpc_id → main route table id
_subnet_to_rt = {}     # subnet_id → explicit route table id
_rt_routes = {}        # rt_id → routes list
for _rt in _route_tables:
    _rt_id = _rt.get('RouteTableId', '')
    _rt_vpc = _rt.get('VpcId', '')
    _rt_routes[_rt_id] = _rt.get('Routes', []) or []
    for _assoc in (_rt.get('Associations') or []):
        if _assoc.get('Main'):
            _vpc_to_main_rt[_rt_vpc] = _rt_id
        elif _assoc.get('SubnetId'):
            _subnet_to_rt[_assoc['SubnetId']] = _rt_id

def _rt_is_public(rt_id):
    for route in (_rt_routes.get(rt_id) or []):
        if (route.get('DestinationCidrBlock') == '0.0.0.0/0'
                and route.get('GatewayId', '') in _igw_ids):
            return True
    return False

_subnets = (load_json('ec2-subnets.json', {}) or {}).get('Subnets', []) or []
subnet_classification = {}
for _sn in _subnets:
    _sn_id = _sn.get('SubnetId', '')
    _vpc_id = _sn.get('VpcId', '')
    _rt_id = _subnet_to_rt.get(_sn_id) or _vpc_to_main_rt.get(_vpc_id, '')
    _name = next((t.get('Value', '') for t in (_sn.get('Tags') or [])
                  if t.get('Key') == 'Name'), '')
    subnet_classification[_sn_id] = {
        'vpc_id': _vpc_id,
        'az': _sn.get('AvailabilityZone', ''),
        'cidr': _sn.get('CidrBlock', ''),
        'name': _name,
        'is_public': _rt_is_public(_rt_id),
        'map_public_ip_on_launch': _sn.get('MapPublicIpOnLaunch', False),
        'route_table_id': _rt_id,
    }
(derived / 'subnet_classification.json').write_text(json.dumps(subnet_classification, indent=2) + '\n')
summary['derived_subnet_count'] = len(subnet_classification)

# --- derived/task_eni_map.json ---
# Joins running ECS tasks (awsvpc mode) to their ENIs: private IP, subnet,
# VPC, and security groups. Enables task-level network placement in the navigator.
_enis = (load_json('ec2-network-interfaces.json', {}) or {}).get('NetworkInterfaces', []) or []
_eni_lookup = {
    eni.get('NetworkInterfaceId', ''): {
        'private_ip': eni.get('PrivateIpAddress', ''),
        'subnet_id': eni.get('SubnetId', ''),
        'vpc_id': eni.get('VpcId', ''),
        'security_groups': [g.get('GroupId', '') for g in (eni.get('Groups') or [])],
    }
    for eni in _enis if eni.get('NetworkInterfaceId')
}
task_eni_map = {}
for _rec in load_ndjson('ecs-tasks.ndjson'):
    _cluster = _rec.get('cluster', '')
    for _task in ((_rec.get('data') or {}).get('tasks') or []):
        _task_arn = _task.get('taskArn', '')
        if not _task_arn:
            continue
        _eni_id = ''
        for _attach in (_task.get('attachments') or []):
            if _attach.get('type') == 'ElasticNetworkInterface':
                for _detail in (_attach.get('details') or []):
                    if _detail.get('name') == 'networkInterfaceId':
                        _eni_id = _detail.get('value', '')
                        break
        if not _eni_id:
            continue
        _eni_info = _eni_lookup.get(_eni_id, {})
        task_eni_map[_task_arn] = {
            'cluster_arn': _cluster,
            'task_definition_arn': _task.get('taskDefinitionArn', ''),
            'eni_id': _eni_id,
            'private_ip': _eni_info.get('private_ip', ''),
            'subnet_id': _eni_info.get('subnet_id', ''),
            'vpc_id': _eni_info.get('vpc_id', ''),
            'security_groups': _eni_info.get('security_groups', []),
            'last_status': _task.get('lastStatus', ''),
        }
(derived / 'task_eni_map.json').write_text(json.dumps(task_eni_map, indent=2) + '\n')
summary['derived_task_eni_count'] = len(task_eni_map)

# --- derived/nat_gateway_eips.json ---
# Joins NAT gateways to their Elastic IP allocation details.
# Surfaces public IP, private IP, subnet, and state in one lookup so the
# navigator can show outbound internet routing paths without a two-file join.
_eips = (load_json('ec2-addresses.json', {}) or {}).get('Addresses', []) or []
_eip_by_alloc = {eip.get('AllocationId', ''): eip for eip in _eips if eip.get('AllocationId')}
_nat_gws = (load_json('ec2-nat-gateways.json', {}) or {}).get('NatGateways', []) or []
nat_gateway_eips = {}
for _ngw in _nat_gws:
    _ngw_id = _ngw.get('NatGatewayId', '')
    if not _ngw_id:
        continue
    _eip_entries = []
    for _addr in (_ngw.get('NatGatewayAddresses') or []):
        _alloc_id = _addr.get('AllocationId', '')
        _eip_data = _eip_by_alloc.get(_alloc_id, {})
        _eip_entries.append({
            'allocation_id': _alloc_id,
            'public_ip': _addr.get('PublicIp', '') or _eip_data.get('PublicIp', ''),
            'private_ip': _addr.get('PrivateIp', ''),
            'network_interface_id': _addr.get('NetworkInterfaceId', ''),
        })
    nat_gateway_eips[_ngw_id] = {
        'subnet_id': _ngw.get('SubnetId', ''),
        'vpc_id': _ngw.get('VpcId', ''),
        'state': _ngw.get('State', ''),
        'connectivity_type': _ngw.get('ConnectivityType', 'public'),
        'eips': _eip_entries,
    }
(derived / 'nat_gateway_eips.json').write_text(json.dumps(nat_gateway_eips, indent=2) + '\n')
summary['derived_nat_gateway_count'] = len(nat_gateway_eips)

# --- derived/vpc_endpoint_routes.json ---
# For gateway endpoints (S3, DynamoDB): identifies which route tables and
# therefore which subnets route through each endpoint.
# For interface endpoints: records the subnets and DNS entries directly.
_rt_to_subnets = {}
for _rt in _route_tables:
    _rt_id = _rt.get('RouteTableId', '')
    _rt_to_subnets[_rt_id] = [
        _a['SubnetId'] for _a in (_rt.get('Associations') or []) if _a.get('SubnetId')
    ]
_endpoints = (load_json('ec2-vpc-endpoints.json', {}) or {}).get('VpcEndpoints', []) or []
vpc_endpoint_routes = {}
for _ep in _endpoints:
    _ep_id = _ep.get('VpcEndpointId', '')
    if not _ep_id:
        continue
    _ep_type = _ep.get('VpcEndpointType', '')
    if _ep_type == 'Gateway':
        _rt_ids = _ep.get('RouteTableIds') or []
        _subnets_via = list({s for r in _rt_ids for s in _rt_to_subnets.get(r, [])})
        vpc_endpoint_routes[_ep_id] = {
            'service': _ep.get('ServiceName', ''),
            'vpc_id': _ep.get('VpcId', ''),
            'type': 'Gateway',
            'state': _ep.get('State', ''),
            'route_table_ids': _rt_ids,
            'subnets_routed_through': _subnets_via,
            'subnet_ids': [],
            'dns_entries': [],
        }
    else:
        vpc_endpoint_routes[_ep_id] = {
            'service': _ep.get('ServiceName', ''),
            'vpc_id': _ep.get('VpcId', ''),
            'type': _ep_type,
            'state': _ep.get('State', ''),
            'route_table_ids': [],
            'subnets_routed_through': [],
            'subnet_ids': _ep.get('SubnetIds') or [],
            'dns_entries': [d.get('DnsName', '') for d in (_ep.get('DnsEntries') or [])],
        }
(derived / 'vpc_endpoint_routes.json').write_text(json.dumps(vpc_endpoint_routes, indent=2) + '\n')
summary['derived_vpc_endpoint_count'] = len(vpc_endpoint_routes)

# --- derived/stepfunctions_resource_refs.json ---
# Parses the ASL definition of each state machine and extracts every resource
# reference: Lambda functions, ECS tasks, DynamoDB tables, SQS queues, SNS
# topics, nested Step Functions, and API Gateway endpoints.
def _parse_asl_state(state_name, state):
    resource_uri = state.get('Resource', '')
    params = state.get('Parameters') or {}
    if not resource_uri:
        return None
    base = {'state_name': state_name, 'resource_uri': resource_uri}
    # Direct Lambda ARN (activity or older syntax)
    if resource_uri.startswith('arn:aws:lambda:'):
        return {**base, 'resource_type': 'lambda', 'resource_arn': resource_uri}
    # AWS SDK / optimised integrations: arn:aws:states:::service:action
    if ':::' in resource_uri:
        service = resource_uri.split(':::')[1].split(':')[0]
        if service == 'lambda':
            return {**base, 'resource_type': 'lambda',
                    'resource_arn': params.get('FunctionName', '')}
        if service == 'ecs':
            return {**base, 'resource_type': 'ecs_task',
                    'task_definition': params.get('TaskDefinition', ''),
                    'cluster': params.get('Cluster', '')}
        if service == 'dynamodb':
            return {**base, 'resource_type': 'dynamodb',
                    'table_name': params.get('TableName', '')}
        if service == 'sqs':
            return {**base, 'resource_type': 'sqs',
                    'queue_url': params.get('QueueUrl', '')}
        if service == 'sns':
            return {**base, 'resource_type': 'sns',
                    'topic_arn': params.get('TopicArn', '')}
        if service == 'states':
            return {**base, 'resource_type': 'stepfunctions',
                    'state_machine_arn': params.get('StateMachineArn', '')}
        if service == 'apigateway':
            return {**base, 'resource_type': 'apigateway',
                    'api_endpoint': params.get('ApiEndpoint', '')}
        if service == 'events':
            return {**base, 'resource_type': 'eventbridge'}
        return {**base, 'resource_type': service}
    return {**base, 'resource_type': 'unknown'}

def _collect_asl_states(states_dict, prefix=''):
    refs = []
    for state_name, state in (states_dict or {}).items():
        full_name = f'{prefix}{state_name}' if prefix else state_name
        if state.get('Type') == 'Task':
            ref = _parse_asl_state(full_name, state)
            if ref:
                refs.append(ref)
        elif state.get('Type') == 'Map':
            # Nested states in iterator/item processor
            _iter = state.get('Iterator') or state.get('ItemProcessor') or {}
            refs.extend(_collect_asl_states(_iter.get('States', {}), f'{full_name}/'))
        elif state.get('Type') == 'Parallel':
            for _branch in (state.get('Branches') or []):
                refs.extend(_collect_asl_states(_branch.get('States', {}), f'{full_name}/'))
    return refs

sf_resource_refs = {}
for _rec in load_ndjson('stepfunctions-state-machine-details.ndjson'):
    _sm_arn = _rec.get('state_machine_arn', '')
    _sm_data = _rec.get('data') or {}
    _def_str = _sm_data.get('definition', '')
    if not _sm_arn or not _def_str:
        continue
    try:
        _asl = json.loads(_def_str)
    except Exception:
        continue
    sf_resource_refs[_sm_arn] = {
        'name': _sm_data.get('name', ''),
        'type': _sm_data.get('type', ''),
        'role_arn': _sm_data.get('roleArn', ''),
        'resource_refs': _collect_asl_states(_asl.get('States', {})),
    }
(derived / 'stepfunctions_resource_refs.json').write_text(json.dumps(sf_resource_refs, indent=2) + '\n')
summary['derived_sf_state_machines'] = len(sf_resource_refs)

# --- derived/pipeline_chains.json ---
# Parses each CodePipeline pipeline to extract the full CI/CD chain:
# source repo → CodeBuild project → S3 artifact bucket → CodeDeploy group →
# ECS service. Classifies every stage action by resource type.
def _pipeline_action_ref(stage_name, action):
    cat = (action.get('actionTypeId') or {}).get('category', '')
    provider = (action.get('actionTypeId') or {}).get('provider', '')
    config = action.get('configuration') or {}
    base = {'stage': stage_name, 'action': action.get('name', ''),
            'category': cat, 'provider': provider}
    if cat == 'Source':
        if provider in ('GitHub', 'GitHub Version 2'):
            return {**base, 'resource_type': 'github',
                    'owner': config.get('Owner', ''), 'repo': config.get('Repo', ''),
                    'branch': config.get('Branch', '')}
        if provider == 'CodeStarSourceConnection':
            return {**base, 'resource_type': 'codestar_connection',
                    'connection_arn': config.get('ConnectionArn', ''),
                    'repo': config.get('FullRepositoryId', ''),
                    'branch': config.get('BranchName', '')}
        if provider == 'CodeCommit':
            return {**base, 'resource_type': 'codecommit',
                    'repo': config.get('RepositoryName', ''),
                    'branch': config.get('BranchName', '')}
        if provider == 'S3':
            return {**base, 'resource_type': 's3_source',
                    'bucket': config.get('S3Bucket', ''),
                    'key': config.get('S3ObjectKey', '')}
        if provider == 'ECR':
            return {**base, 'resource_type': 'ecr',
                    'repository': config.get('RepositoryName', ''),
                    'image_tag': config.get('ImageTag', '')}
    if cat == 'Build' and provider == 'CodeBuild':
        return {**base, 'resource_type': 'codebuild',
                'project': config.get('ProjectName', '')}
    if cat == 'Deploy':
        if provider == 'CodeDeploy':
            return {**base, 'resource_type': 'codedeploy',
                    'application': config.get('ApplicationName', ''),
                    'deployment_group': config.get('DeploymentGroupName', '')}
        if provider == 'ECS':
            return {**base, 'resource_type': 'ecs_service',
                    'cluster': config.get('ClusterName', ''),
                    'service': config.get('ServiceName', '')}
        if provider == 'S3':
            return {**base, 'resource_type': 's3_deploy',
                    'bucket': config.get('BucketName', '')}
    if cat == 'Invoke' and provider == 'Lambda':
        return {**base, 'resource_type': 'lambda',
                'function': config.get('FunctionName', '')}
    if cat == 'Approval':
        return {**base, 'resource_type': 'approval',
                'notification_arn': config.get('NotificationArn', '')}
    return {**base, 'resource_type': 'other'}

pipeline_chains = {}
for _rec in load_ndjson('codepipeline-pipeline-details.ndjson'):
    _pl_name = _rec.get('pipeline_name', '')
    _pl = (_rec.get('data') or {}).get('pipeline') or {}
    if not _pl_name:
        continue
    _art = _pl.get('artifactStore') or {}
    _refs = []
    _stages_out = []
    for _stage in (_pl.get('stages') or []):
        _sn = _stage.get('name', '')
        for _action in (_stage.get('actions') or []):
            _ref = _pipeline_action_ref(_sn, _action)
            if _ref:
                _refs.append(_ref)
        _stages_out.append({
            'name': _sn,
            'actions': [{'name': a.get('name', ''),
                         'category': (a.get('actionTypeId') or {}).get('category', ''),
                         'provider': (a.get('actionTypeId') or {}).get('provider', '')}
                        for a in (_stage.get('actions') or [])],
        })
    pipeline_chains[_pl_name] = {
        'artifact_store_bucket': _art.get('location', ''),
        'artifact_store_type': _art.get('type', ''),
        'stages': _stages_out,
        'resource_refs': _refs,
    }
(derived / 'pipeline_chains.json').write_text(json.dumps(pipeline_chains, indent=2) + '\n')
summary['derived_pipeline_chains'] = len(pipeline_chains)

# --- derived/dynamodb_stream_consumers.json ---
# Joins DynamoDB table stream ARNs to the Lambda functions that consume them.
# LatestStreamArn (dynamodb-table-details.ndjson) matches EventSourceArn
# (lambda-event-source-mappings.json) for DynamoDB-triggered Lambdas.
_esms = (load_json('lambda-event-source-mappings.json', {}) or {}).get('EventSourceMappings', []) or []
_stream_to_lambdas = {}
for _esm in _esms:
    _esa = _esm.get('EventSourceArn', '')
    if _esa and '/stream/' in _esa and ':dynamodb:' in _esa:
        _stream_to_lambdas.setdefault(_esa, []).append({
            'function_arn': _esm.get('FunctionArn', ''),
            'state': _esm.get('State', ''),
            'batch_size': _esm.get('BatchSize'),
            'starting_position': _esm.get('StartingPosition', ''),
            'maximum_retry_attempts': _esm.get('MaximumRetryAttempts'),
            'bisect_batch_on_error': _esm.get('BisectBatchOnFunctionError', False),
        })
dynamodb_stream_consumers = {}
for _rec in load_ndjson('dynamodb-table-details.ndjson'):
    _tbl = (_rec.get('data') or {}).get('Table') or {}
    _stream_arn = _tbl.get('LatestStreamArn', '')
    if not _stream_arn:
        continue
    _consumers = _stream_to_lambdas.get(_stream_arn, [])
    if _consumers:
        dynamodb_stream_consumers[_stream_arn] = {
            'table_name': _tbl.get('TableName', ''),
            'table_arn': _tbl.get('TableArn', ''),
            'lambda_consumers': _consumers,
        }
(derived / 'dynamodb_stream_consumers.json').write_text(json.dumps(dynamodb_stream_consumers, indent=2) + '\n')
summary['derived_dynamodb_stream_consumers'] = len(dynamodb_stream_consumers)

# --- derived/iam_role_resource_access.json ---
# Parses all captured IAM policy documents (inline + customer-managed) and
# builds a service_access map per role: service → resources allowed.
# AWS-managed policies are not in the snapshot; their ARNs are preserved in
# unanalyzed_managed_policies so the navigator can flag incomplete coverage.
def _parse_policy_doc(doc):
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, str):
        try:
            return json.loads(urllib.parse.unquote(doc))
        except Exception:
            try:
                return json.loads(doc)
            except Exception:
                return None
    return None

def _extract_allow_stmts(document, source, policy_name):
    stmts = []
    if not isinstance(document, dict):
        return stmts
    for stmt in (document.get('Statement') or []):
        if stmt.get('Effect') != 'Allow':
            continue
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        resources = stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        services = ['*'] if '*' in actions else sorted(
            {a.split(':')[0].lower() for a in actions if ':' in a})
        stmts.append({'source': source, 'policy_name': policy_name,
                      'actions': actions, 'resources': resources, 'services': services})
    return stmts

def _build_svc_access(stmts):
    svc_map = {}
    for stmt in stmts:
        for svc in (stmt.get('services') or []):
            svc_map.setdefault(svc, set()).update(stmt.get('resources') or [])
    return {svc: sorted(res) for svc, res in sorted(svc_map.items())}

# customer-managed policy ARN → parsed document
_cust_policy_docs = {}
for _rec in load_ndjson('iam-local-policy-versions.ndjson'):
    _arn = _rec.get('policy_arn', '')
    _doc = (_rec.get('data') or {}).get('PolicyVersion', {}).get('Document')
    if _arn and _doc is not None:
        _cust_policy_docs[_arn] = _parse_policy_doc(_doc)

# role name → attached managed policy ARNs
_role_managed = {}
for _rec in load_ndjson('iam-role-details.ndjson'):
    _rn = _rec.get('role_name', '')
    _ml = (_rec.get('managed') or {}).get('AttachedPolicies') or []
    if _rn:
        _role_managed[_rn] = [p.get('PolicyArn', '') for p in _ml]

# role name → [{policy_name, document}]
_role_inlines = {}
for _rec in load_ndjson('iam-role-inline-policies.ndjson'):
    _rn = _rec.get('role_name', '')
    _doc = (_rec.get('data') or {}).get('PolicyDocument')
    if _rn and _doc is not None:
        _role_inlines.setdefault(_rn, []).append(
            {'policy_name': _rec.get('policy_name', ''), 'document': _parse_policy_doc(_doc)})

iam_role_resource_access = {}
for _rn in sorted(set(list(_role_managed) + list(_role_inlines))):
    _all_stmts = []
    for _ip in (_role_inlines.get(_rn) or []):
        _all_stmts.extend(_extract_allow_stmts(_ip['document'], 'inline', _ip['policy_name']))
    _unanalyzed = []
    for _parn in (_role_managed.get(_rn) or []):
        _pdoc = _cust_policy_docs.get(_parn)
        if _pdoc is not None:
            _all_stmts.extend(_extract_allow_stmts(_pdoc, 'managed', _parn.split('/')[-1]))
        else:
            _unanalyzed.append(_parn)
    if not _all_stmts and not _unanalyzed:
        continue
    iam_role_resource_access[_rn] = {
        'service_access': _build_svc_access(_all_stmts),
        'allow_statements': _all_stmts,
        'unanalyzed_managed_policies': _unanalyzed,
    }
(derived / 'iam_role_resource_access.json').write_text(
    json.dumps(iam_role_resource_access, indent=2) + '\n')
summary['derived_iam_roles_analyzed'] = len(iam_role_resource_access)

# --- derived/ec2_instance_roles.json ---
# Joins EC2 ECS container instances to their IAM roles via instance profiles,
# and attaches the analyzed service_access from iam_role_resource_access above.
# Chain: ec2 instance → IamInstanceProfile.Arn → instance profile → Roles[].
_ip_arn_to_profile = {}
for _ip in ((load_json('iam-instance-profiles.json', {}) or {}).get('InstanceProfiles') or []):
    _ip_arn = _ip.get('Arn', '')
    if _ip_arn:
        _ip_arn_to_profile[_ip_arn] = {
            'profile_name': _ip.get('InstanceProfileName', ''),
            'roles': [{'role_name': r.get('RoleName', ''), 'role_arn': r.get('Arn', '')}
                      for r in (_ip.get('Roles') or [])],
        }
ec2_instance_roles = {}
for _res in ((load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations') or []):
    for _inst in (_res.get('Instances') or []):
        _inst_id = _inst.get('InstanceId', '')
        if not _inst_id:
            continue
        _ip_arn = (_inst.get('IamInstanceProfile') or {}).get('Arn', '')
        _profile = _ip_arn_to_profile.get(_ip_arn, {})
        _role_names = [r['role_name'] for r in (_profile.get('roles') or [])]
        _cluster = next((t.get('Value', '') for t in (_inst.get('Tags') or [])
                         if t.get('Key') == 'aws:ecs:cluster-name'), '')
        ec2_instance_roles[_inst_id] = {
            'instance_profile_arn': _ip_arn,
            'profile_name': _profile.get('profile_name', ''),
            'roles': _profile.get('roles', []),
            'role_service_access': {
                rn: iam_role_resource_access.get(rn, {}).get('service_access', {})
                for rn in _role_names
            },
            'ecs_cluster': _cluster,
            'instance_type': _inst.get('InstanceType', ''),
            'private_ip': _inst.get('PrivateIpAddress', ''),
            'subnet_id': _inst.get('SubnetId', ''),
        }
(derived / 'ec2_instance_roles.json').write_text(json.dumps(ec2_instance_roles, indent=2) + '\n')
summary['derived_ec2_instance_roles'] = len(ec2_instance_roles)

# --- derived/codebuild_role_access.json ---
# Joins each CodeBuild project to its service role's analyzed permissions.
# Surfaces what the build process can access: ECR repos, S3 buckets, Secrets
# Manager, etc. Useful for auditing build-time supply chain permissions.
codebuild_role_access = {}
for _rec in load_ndjson('codebuild-project-details.ndjson'):
    _proj = _rec.get('name', '')
    _role_arn = _rec.get('serviceRole', '')
    if not _proj:
        continue
    _role_name = _role_arn.split('/')[-1] if '/' in _role_arn else ''
    _role_access = iam_role_resource_access.get(_role_name, {})
    _src = _rec.get('source') or {}
    _art = _rec.get('artifacts') or {}
    codebuild_role_access[_proj] = {
        'service_role_arn': _role_arn,
        'role_name': _role_name,
        'source': {'type': _src.get('type', ''), 'location': _src.get('location', '')},
        'artifacts': {'type': _art.get('type', ''), 'location': _art.get('location', '')},
        'service_access': _role_access.get('service_access', {}),
        'unanalyzed_managed_policies': _role_access.get('unanalyzed_managed_policies', []),
    }
(derived / 'codebuild_role_access.json').write_text(
    json.dumps(codebuild_role_access, indent=2) + '\n')
summary['derived_codebuild_projects_analyzed'] = len(codebuild_role_access)

# --- derived/iam_role_trust_analysis.json ---
# Parses every role's trust policy and classifies who can assume it:
# AWS services (ecs-tasks.amazonaws.com, lambda.amazonaws.com, etc.),
# other IAM roles (cross-account deploy roles), and federated identities.
def _parse_principal_list(val):
    if isinstance(val, str):
        return [val]
    return val if isinstance(val, list) else []

def _extract_trust_principals(trust_doc):
    result = {'trusted_services': set(), 'trusted_accounts': set(),
              'trusted_roles': set(), 'federated_principals': set()}
    for stmt in (trust_doc.get('Statement') or []):
        if stmt.get('Effect') != 'Allow':
            continue
        _p = stmt.get('Principal', {})
        if isinstance(_p, str):
            result['trusted_accounts'].add(_p)
            continue
        for _s in _parse_principal_list(_p.get('Service', [])):
            if _s:
                result['trusted_services'].add(_s)
        for _a in _parse_principal_list(_p.get('AWS', [])):
            if not _a:
                continue
            if ':role/' in _a or ':assumed-role/' in _a:
                result['trusted_roles'].add(_a)
            else:
                result['trusted_accounts'].add(_a)
        for _f in _parse_principal_list(_p.get('Federated', [])):
            if _f:
                result['federated_principals'].add(_f)
    return {k: sorted(v) for k, v in result.items()}

iam_role_trust_analysis = {}
for _rec in load_ndjson('iam-role-details.ndjson'):
    _rn = _rec.get('role_name', '')
    _role_data = (_rec.get('trust') or {}).get('Role') or {}
    _trust_doc = _role_data.get('AssumeRolePolicyDocument')
    if not _rn or not _trust_doc:
        continue
    _parsed = _parse_policy_doc(_trust_doc) if not isinstance(_trust_doc, dict) else _trust_doc
    if not _parsed:
        continue
    _principals = _extract_trust_principals(_parsed)
    iam_role_trust_analysis[_rn] = {'role_arn': _role_data.get('Arn', ''), **_principals}
(derived / 'iam_role_trust_analysis.json').write_text(json.dumps(iam_role_trust_analysis, indent=2) + '\n')
summary['derived_iam_trust_analyzed'] = len(iam_role_trust_analysis)

# --- derived/apigw_auth_chain.json ---
# Links API Gateway v2 authorizers to their Cognito user pools (for JWT
# authorizers) or Lambda functions (for REQUEST authorizers).
_cognito_pool_map = {}
for _rec in load_ndjson('cognito-user-pool-details.ndjson'):
    _pd = (_rec.get('data') or {}).get('UserPool') or {}
    _pid = _pd.get('Id', '') or _rec.get('user_pool_id', '')
    if _pid:
        _cognito_pool_map[_pid] = {'name': _pd.get('Name', ''), 'arn': _pd.get('Arn', ''),
                                   'mfa': _pd.get('MfaConfiguration', '')}

def _pool_id_from_issuer(issuer):
    parts = issuer.rstrip('/').split('/')
    return parts[-1] if parts else ''

apigw_auth_chain = {}
for _rec in load_ndjson('apigwv2-authorizers.ndjson'):
    _api_id = _rec.get('api_id', '')
    for _auth in ((_rec.get('data') or {}).get('Items') or []):
        _auth_id = _auth.get('AuthorizerId', '')
        _atype = _auth.get('AuthorizerType', '')
        entry = {'api_id': _api_id, 'authorizer_id': _auth_id,
                 'name': _auth.get('Name', ''), 'type': _atype}
        if _atype == 'JWT':
            _jwt = _auth.get('JwtConfiguration') or {}
            _issuer = _jwt.get('Issuer', '')
            entry['issuer'] = _issuer
            entry['audience'] = _jwt.get('Audience') or []
            if 'cognito-idp' in _issuer:
                _pid = _pool_id_from_issuer(_issuer)
                entry['cognito_pool_id'] = _pid
                entry['cognito_pool'] = _cognito_pool_map.get(_pid, {})
        elif _atype == 'REQUEST':
            entry['authorizer_uri'] = _auth.get('AuthorizerUri', '')
        apigw_auth_chain[f'{_api_id}/{_auth_id}'] = entry
(derived / 'apigw_auth_chain.json').write_text(json.dumps(apigw_auth_chain, indent=2) + '\n')
summary['derived_apigw_auth_chains'] = len(apigw_auth_chain)

# --- derived/sqs_dlq_chains.json ---
# Parses SQS RedrivePolicy attributes to map every queue to its dead-letter
# queue, showing failure routing paths through the messaging layer.
sqs_dlq_chains = {}
for _rec in load_ndjson('sqs-queue-attributes.ndjson'):
    _url = _rec.get('queue_url', '')
    _attrs = (_rec.get('data') or {}).get('Attributes') or {}
    _rp_raw = _attrs.get('RedrivePolicy', '')
    if not _rp_raw or not _url:
        continue
    try:
        _rp = json.loads(_rp_raw)
    except Exception:
        continue
    _dlq_arn = _rp.get('deadLetterTargetArn', '')
    if _dlq_arn:
        _q_arn = _attrs.get('QueueArn', _url)
        sqs_dlq_chains[_q_arn] = {
            'queue_url': _url,
            'queue_name': _url.split('/')[-1] if '/' in _url else _url,
            'dlq_arn': _dlq_arn,
            'max_receive_count': _rp.get('maxReceiveCount'),
        }
(derived / 'sqs_dlq_chains.json').write_text(json.dumps(sqs_dlq_chains, indent=2) + '\n')
summary['derived_sqs_dlq_count'] = len(sqs_dlq_chains)

# --- derived/sg_members.json ---
# Inverse map: security group → all resources that belong to it.
# Complements sg_connectivity.json (which edges between SGs) by telling the
# navigator what nodes sit inside each SG, enabling SG node membership display.
def _add_sg_member(sg_map, sg_id, rtype, rid, extra=None):
    if not sg_id or not rid:
        return
    entry = {'resource_type': rtype, 'resource_id': rid}
    if extra:
        entry.update(extra)
    sg_map.setdefault(sg_id, []).append(entry)

sg_members = {}

for _r in load_ndjson('ecs-services.ndjson'):
    for _s in ((_r.get('data') or {}).get('services') or []):
        _sa = _s.get('serviceArn', '')
        for _sg in (((_s.get('networkConfiguration') or {}).get('awsvpcConfiguration') or {}).get('securityGroups') or []):
            _add_sg_member(sg_members, _sg, 'ecs_service', _sa, {'name': _s.get('serviceName', '')})

_tem_path = derived / 'task_eni_map.json'
if _tem_path.exists():
    for _task_arn, _ti in (json.loads(_tem_path.read_text()) or {}).items():
        for _sg in (_ti.get('security_groups') or []):
            _add_sg_member(sg_members, _sg, 'ecs_task', _task_arn,
                           {'last_status': _ti.get('last_status', '')})

for _i in ((load_json('rds-db-instances.json', {}) or {}).get('DBInstances') or []):
    _id = _i.get('DBInstanceIdentifier', '')
    for _sg in (_i.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'rds_instance', _id)

for _c in ((load_json('rds-db-clusters.json', {}) or {}).get('DBClusters') or []):
    _id = _c.get('DBClusterIdentifier', '')
    for _sg in (_c.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'rds_cluster', _id)

for _px in ((load_json('rds-db-proxies.json', {}) or {}).get('DBProxies') or []):
    for _sg in (_px.get('VpcSecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'rds_proxy', _px.get('DBProxyName', ''))

for _rg in ((load_json('elasticache-replication-groups.json', {}) or {}).get('ReplicationGroups') or []):
    _id = _rg.get('ReplicationGroupId', '')
    for _sg in (_rg.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('SecurityGroupId', ''), 'elasticache', _id)

for _sc in ((load_json('elasticache-serverless-caches.json', {}) or {}).get('ServerlessCaches') or []):
    for _sg in (_sc.get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'elasticache_serverless', _sc.get('ServerlessCacheName', ''))

for _cl in ((load_json('memorydb-clusters.json', {}) or {}).get('Clusters') or []):
    _id = _cl.get('Name', '')
    for _sg in (_cl.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('SecurityGroupId', ''), 'memorydb_cluster', _id)

for _lb in ((load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers') or []):
    _id = _lb.get('LoadBalancerArn', '')
    for _sg in (_lb.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'load_balancer', _id, {'name': _lb.get('LoadBalancerName', '')})

for _fn in ((load_json('lambda-functions.json', {}) or {}).get('Functions') or []):
    _id = _fn.get('FunctionArn', '')
    for _sg in ((_fn.get('VpcConfig') or {}).get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'lambda', _id, {'name': _fn.get('FunctionName', '')})

for _cl in ((load_json('redshift-clusters.json', {}) or {}).get('Clusters') or []):
    _id = _cl.get('ClusterIdentifier', '')
    for _sg in (_cl.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'redshift_cluster', _id)

for _rec in load_ndjson('redshift-serverless-workgroup-details.ndjson'):
    _wg = (_rec.get('data') or {}).get('workgroup') or {}
    _id = _wg.get('workgroupName', '') or _rec.get('workgroup_name', '')
    for _sg in (_wg.get('securityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'redshift_serverless_workgroup', _id)

for _cl in ((load_json('docdb-clusters.json', {}) or {}).get('DBClusters') or []):
    _id = _cl.get('DBClusterIdentifier', '')
    for _sg in (_cl.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'docdb_cluster', _id)

for _rec in load_ndjson('kafka-cluster-details.ndjson'):
    _arn = _rec.get('cluster_arn', '')
    _ci = (_rec.get('data') or {}).get('ClusterInfo') or {}
    for _sg in ((_ci.get('Provisioned') or {}).get('BrokerNodeGroupInfo', {}).get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'msk_cluster', _arn)
    for _vc in ((_ci.get('Serverless') or {}).get('VpcConfigs') or []):
        for _sg in (_vc.get('SecurityGroupIds') or []):
            _add_sg_member(sg_members, _sg, 'msk_serverless', _arn)

for _res in ((load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations') or []):
    for _inst in (_res.get('Instances') or []):
        _id = _inst.get('InstanceId', '')
        for _sg in (_inst.get('SecurityGroups') or []):
            _add_sg_member(sg_members, _sg.get('GroupId', ''), 'ec2_instance', _id)

for _rec in load_ndjson('opensearch-domain-details.ndjson'):
    _d = _rec.get('domain_name', '')
    for _sg in (((_rec.get('data') or {}).get('DomainStatus') or {}).get('VPCOptions', {}).get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'opensearch_domain', _d)

for _rec in load_ndjson('efs-mount-target-sgs.ndjson'):
    _mt = _rec.get('mount_target_id', '')
    _fs = _rec.get('file_system_id', '')
    for _sg in ((_rec.get('data') or {}).get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'efs_mount_target', _mt, {'file_system_id': _fs})

for _vl in ((load_json('apigwv2-vpc-links.json', {}) or {}).get('Items') or []):
    _id = _vl.get('VpcLinkId', '')
    for _sg in (_vl.get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'api_gateway_vpc_link', _id)

(derived / 'sg_members.json').write_text(json.dumps(sg_members, indent=2) + '\n')
summary['derived_sg_member_entries'] = sum(len(v) for v in sg_members.values())

(derived / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
(derived / 'README.md').write_text(
    '\n'.join([
        '# AWS Infra Snapshot Summary',
        '',
        f'- ECS clusters: {summary["ecs_cluster_count"]}',
        f'- ECS task definitions: {summary["ecs_task_definition_count"]}',
        f'- Load balancers: {summary["load_balancer_count"]}',
        f'- Target groups: {summary["target_group_count"]}',
        f'- VPCs: {summary["vpc_count"]}',
        f'- Subnets: {summary["subnet_count"]}',
        f'- Security groups: {summary["security_group_count"]}',
        f'- RDS instances: {summary["rds_instance_count"]}',
        f'- RDS proxies: {summary["rds_proxy_count"]}',
        f'- EC2 ECS container instances: {summary["ec2_ecs_instance_count"]}',
        f'- RDS snapshots: {summary["rds_snapshot_count"]}',
        f'- Redshift clusters: {summary["redshift_cluster_count"]}',
        f'- Redshift Serverless workgroups: {summary["redshift_serverless_workgroup_count"]}',
        f'- Redshift Serverless namespaces: {summary["redshift_serverless_namespace_count"]}',
        f'- EFS file systems: {summary["efs_file_system_count"]}',
        f'- S3 buckets: {summary["s3_bucket_count"]}',
        f'- DynamoDB tables: {summary["dynamodb_table_count"]}',
        f'- DocumentDB clusters: {summary["docdb_cluster_count"]}',
        f'- Lambda functions: {summary["lambda_function_count"]}',
        f'- Lambda event source mappings: {summary["lambda_event_source_mapping_count"]}',
        f'- API Gateway REST APIs (v1): {summary["apigw_rest_api_count"]}',
        f'- API Gateway HTTP/WebSocket APIs (v2): {summary["apigwv2_api_count"]}',
        f'- Cognito user pools: {summary["cognito_user_pool_count"]}',
        f'- ECR repositories: {summary["ecr_repository_count"]}',
        f'- ACM certificates: {summary["acm_certificate_count"]}',
        f'- WAFv2 WebACLs: {summary["wafv2_webacl_count"]}',
        f'- CloudFront distributions: {summary["cloudfront_distribution_count"]}',
        f'- EC2 Auto Scaling Groups: {summary["asg_count"]}',
        f'- Launch templates: {summary["launch_template_count"]}',
        f'- CloudWatch log groups: {summary["log_group_count"]}',
        f'- CloudWatch alarms: {summary["cloudwatch_alarm_count"]}',
        f'- SQS queues: {summary["sqs_queue_count"]}',
        f'- SNS topics: {summary["sns_topic_count"]}',
        f'- EventBridge buses: {summary["eventbridge_bus_count"]}',
        f'- Step Functions state machines: {summary["stepfunctions_count"]}',
        f'- MSK clusters: {summary["msk_cluster_count"]}',
        f'- Kinesis streams: {summary["kinesis_stream_count"]}',
        f'- Firehose delivery streams: {summary["firehose_stream_count"]}',
        f'- OpenSearch domains: {summary["opensearch_domain_count"]}',
        f'- CodeBuild projects: {summary["codebuild_project_count"]}',
        f'- CodePipeline pipelines: {summary["codepipeline_count"]}',
        f'- CodeDeploy applications: {summary["codedeploy_application_count"]}',
        f'- KMS keys: {summary["kms_key_count"]}',
        f'- CloudTrail trails: {summary["cloudtrail_trail_count"]}',
        f'- GuardDuty detectors: {summary["guardduty_detector_count"]}',
        f'- IAM users: {summary["iam_user_count"]}',
        f'- IAM groups: {summary["iam_group_count"]}',
        f'- IAM customer-managed policies: {summary["iam_local_policy_count"]}',
        f'- Access Analyzer analyzers: {summary["accessanalyzer_count"]}',
        f'- Secrets: {summary["secret_count"]}',
        f'- Route53 hosted zones: {summary["hosted_zone_count"]}',
        f'- Route53 health checks: {summary["route53_health_check_count"]}',
        f'- Elastic IPs: {summary["elastic_ip_count"]}',
        f'- VPC peering connections: {summary["vpc_peering_count"]}',
        f'- Route53 Resolver endpoints: {summary["resolver_endpoint_count"]}',
        f'- Secret refs mapped to consumers: {summary["mapped_secret_refs"]}',
        f'- SSM param refs mapped to consumers: {summary["mapped_param_refs"]}',
        f'- SG connectivity edges (derived): {summary["derived_sg_edges"]}',
        f'- ALB→service mappings (derived): {summary["derived_alb_mappings"]}',
        f'- ECS service topologies (derived): {summary["derived_service_topologies"]}',
        f'- CloudWatch alarm targets (derived): {summary["derived_alarm_targets"]}',
        f'- Subnets classified (derived): {summary["derived_subnet_count"]}',
        f'- ECS tasks with ENI mapped (derived): {summary["derived_task_eni_count"]}',
        f'- NAT gateways with EIPs (derived): {summary["derived_nat_gateway_count"]}',
        f'- VPC endpoint routes (derived): {summary["derived_vpc_endpoint_count"]}',
        f'- Step Functions resource refs (derived): {summary["derived_sf_state_machines"]}',
        f'- Pipeline chains (derived): {summary["derived_pipeline_chains"]}',
        f'- DynamoDB stream consumers (derived): {summary["derived_dynamodb_stream_consumers"]}',
        f'- IAM roles analyzed for access (derived): {summary["derived_iam_roles_analyzed"]}',
        f'- EC2 instances with roles mapped (derived): {summary["derived_ec2_instance_roles"]}',
        f'- CodeBuild projects with role access (derived): {summary["derived_codebuild_projects_analyzed"]}',
        f'- IAM role trust policies analyzed (derived): {summary["derived_iam_trust_analyzed"]}',
        f'- API Gateway auth chains (derived): {summary["derived_apigw_auth_chains"]}',
        f'- SQS queues with DLQ (derived): {summary["derived_sqs_dlq_count"]}',
        f'- SG member entries across all resources (derived): {summary["derived_sg_member_entries"]}',
        '',
        'This summary is intentionally compact. Use the raw/*.json and raw/*.ndjson files for full detail.',
    ]) + '\n'
)
PY

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
