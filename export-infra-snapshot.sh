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


  # Helper: call an export-script with OUT_DIR + common flags
  _export() {
    local script="$1"; shift
    OUT_DIR="$out_dir" "${SCRIPT_DIR}/export-scripts/${script}" \
      --region "$region" \
      ${PROFILE:+--profile "$PROFILE"} \
      "$@"
  }
  # Shorthand for scripts that receive --skip-globals when skip_globals=true
  _export_sg() {
    local script="$1"; shift
    if [[ "$skip_globals" == "true" ]]; then
      _export "$script" --skip-globals "$@"
    else
      _export "$script" "$@"
    fi
  }

  progress "Starting snapshot — ${region}"

  progress "Broad inventory (Resource Explorer, tagging API)"
  _export export-inventory.sh

  progress "Compute — ECS (clusters, services, tasks, task definitions)"
  _export export-ecs.sh

  progress "Compute — EKS (clusters, node groups, Fargate profiles)"
  _export export-eks.sh

  progress "Compute — ECR (repositories, images, scanning)"
  _export export-ecr.sh

  progress "Scaling — Auto Scaling (ECS policies, EC2 ASGs, launch templates)"
  _export export-autoscaling.sh

  progress "Service discovery — Cloud Map"
  _export export-cloudmap.sh

  progress "Load balancing & edge — ALB/NLB, ACM, WAFv2, CloudFront"
  _export_sg export-elb.sh

  progress "Networking — VPC, subnets, SGs, route tables, TGW, VPN, Direct Connect"
  _export export-vpc.sh

  progress "Databases — RDS, RDS Proxy, Redshift, DocumentDB, DynamoDB"
  _export export-databases.sh

  progress "Storage — EFS, S3"
  _export_sg export-storage.sh

  progress "Cache & search — ElastiCache, MemoryDB, OpenSearch"
  _export export-cache.sh

  progress "DNS — Route53 (global) + Route53 Resolver"
  _export_sg export-route53.sh

  progress "IAM — roles, users, groups, policies, instance profiles"
  _export_sg export-iam.sh

  progress "Serverless — Lambda, API Gateway, Cognito"
  _export export-lambda.sh

  progress "Observability — CloudWatch (logs, alarms, dashboards)"
  _export export-observability.sh

  progress "Config & secrets — Secrets Manager, SSM Parameters"
  _export export-secrets.sh $([[ "$WITH_SECRET_VALUES" == "true" ]] && echo --with-secret-values || true)

  progress "Messaging — SQS, SNS, EventBridge, Step Functions, MQ, MSK, Kinesis, Firehose"
  _export export-messaging.sh

  progress "CI/CD — CodeBuild, CodePipeline, CodeDeploy, CodeStar"
  _export_sg export-cicd.sh

  progress "Security & governance — KMS, CloudTrail, Config, GuardDuty, Security Hub, Access Analyzer"
  _export_sg export-security.sh

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
