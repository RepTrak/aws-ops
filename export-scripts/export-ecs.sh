#!/usr/bin/env bash
# ECS clusters, services, tasks, task definitions + EC2 ECS container instances
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-ecs.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

safe_aws_json "${OUT_DIR}/raw/ecs-clusters.json" ecs list-clusters
cluster_arns="$(jq -r '.clusterArns[]?' "${OUT_DIR}/raw/ecs-clusters.json")"

: > "${OUT_DIR}/raw/ecs-describe-task-definitions.ndjson"
: > "${OUT_DIR}/raw/ecs-services.ndjson"
: > "${OUT_DIR}/raw/ecs-tasks.ndjson"
: > "${OUT_DIR}/raw/ecs-container-instances.ndjson"

if [[ -n "$cluster_arns" ]]; then
  safe_aws_json "${OUT_DIR}/raw/ecs-describe-clusters.json" \
    ecs describe-clusters --clusters $cluster_arns \
    --include ATTACHMENTS CONFIGURATIONS SETTINGS STATISTICS TAGS
  safe_aws_json "${OUT_DIR}/raw/ecs-list-task-definitions.json" \
    ecs list-task-definitions --sort DESC
  task_def_arns="$(jq -r '.taskDefinitionArns[]?' "${OUT_DIR}/raw/ecs-list-task-definitions.json")"
  if [[ -n "$task_def_arns" ]]; then
    while IFS= read -r arn; do
      [[ -z "$arn" ]] && continue
      aws "${AWS_ARGS[@]}" ecs describe-task-definition --task-definition "$arn" --include TAGS 2>/dev/null | \
        jq -c --arg arn "$arn" '{task_definition_arn:$arn, data:.}' \
        >> "${OUT_DIR}/raw/ecs-describe-task-definitions.ndjson" || true
    done <<< "$task_def_arns"
  fi

  while IFS= read -r cluster; do
    [[ -z "$cluster" ]] && continue
    cluster_name="$(basename "$cluster")"
    safe_aws_json "${OUT_DIR}/raw/ecs-list-services-${cluster_name}.json" \
      ecs list-services --cluster "$cluster"
    service_arns_file="${OUT_DIR}/raw/ecs-list-services-${cluster_name}.txt"
    jq -r '.serviceArns[]?' "${OUT_DIR}/raw/ecs-list-services-${cluster_name}.json" > "$service_arns_file"
    if [[ -s "$service_arns_file" ]]; then
      while IFS= read -r batch; do
        [[ -z "$batch" ]] && continue
        aws "${AWS_ARGS[@]}" ecs describe-services --cluster "$cluster" --services $batch \
          --include TAGS 2>/dev/null | \
          jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' \
          >> "${OUT_DIR}/raw/ecs-services.ndjson" || true
      done < <(chunk_lines_file 10 "$service_arns_file")
    fi

    safe_aws_json "${OUT_DIR}/raw/ecs-list-tasks-${cluster_name}.json" \
      ecs list-tasks --cluster "$cluster"
    task_arns_file="${OUT_DIR}/raw/ecs-list-tasks-${cluster_name}.txt"
    jq -r '.taskArns[]?' "${OUT_DIR}/raw/ecs-list-tasks-${cluster_name}.json" > "$task_arns_file"
    if [[ -s "$task_arns_file" ]]; then
      while IFS= read -r batch; do
        [[ -z "$batch" ]] && continue
        aws "${AWS_ARGS[@]}" ecs describe-tasks --cluster "$cluster" --tasks $batch \
          --include TAGS 2>/dev/null | \
          jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' \
          >> "${OUT_DIR}/raw/ecs-tasks.ndjson" || true
      done < <(chunk_lines_file 100 "$task_arns_file")
    fi

    safe_aws_json "${OUT_DIR}/raw/ecs-list-container-instances-${cluster_name}.json" \
      ecs list-container-instances --cluster "$cluster"
    ci_arns_file="${OUT_DIR}/raw/ecs-list-container-instances-${cluster_name}.txt"
    jq -r '.containerInstanceArns[]?' \
      "${OUT_DIR}/raw/ecs-list-container-instances-${cluster_name}.json" > "$ci_arns_file"
    if [[ -s "$ci_arns_file" ]]; then
      while IFS= read -r batch; do
        [[ -z "$batch" ]] && continue
        aws "${AWS_ARGS[@]}" ecs describe-container-instances --cluster "$cluster" \
          --container-instances $batch \
          --include TAGS CONTAINER_INSTANCE_HEALTH 2>/dev/null | \
          jq -c --arg cluster "$cluster" '{cluster:$cluster, data:.}' \
          >> "${OUT_DIR}/raw/ecs-container-instances.ndjson" || true
      done < <(chunk_lines_file 100 "$ci_arns_file")
    fi
  done <<< "$cluster_arns"

  safe_aws_json "${OUT_DIR}/raw/ecs-capacity-providers.json" ecs describe-capacity-providers
fi

# EC2 instances tagged as ECS container hosts
safe_aws_json "${OUT_DIR}/raw/ec2-instances-ecs.json" \
  ec2 describe-instances --filters "Name=tag-key,Values=aws:ecs:cluster-name"
