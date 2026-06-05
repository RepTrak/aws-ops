#!/usr/bin/env bash
# CI/CD — CodeBuild, CodePipeline, CodeDeploy, CodeStar + IAM OIDC (global, skip with --skip-globals)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-cicd.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── CodeBuild ─────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/codebuild-projects.json" codebuild list-projects
cb_names_file="${OUT_DIR}/raw/codebuild-project-names.txt"
jq -r '.projects[]? // empty' "${OUT_DIR}/raw/codebuild-projects.json" \
  > "$cb_names_file" 2>/dev/null || true
: > "${OUT_DIR}/raw/codebuild-project-details.ndjson"
if [[ -s "$cb_names_file" ]]; then
  while IFS= read -r batch; do
    [[ -z "$batch" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" codebuild batch-get-projects --names $batch 2>/dev/null | \
      jq -c '.projects[]?' >> "${OUT_DIR}/raw/codebuild-project-details.ndjson" || true
  done < <(chunk_lines_file 100 "$cb_names_file")
fi

# ── CodePipeline ──────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/codepipeline-pipelines.json" codepipeline list-pipelines
pipeline_names="$(jq -r '.pipelines[]?.name // empty' \
  "${OUT_DIR}/raw/codepipeline-pipelines.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/codepipeline-pipeline-details.ndjson"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" codepipeline get-pipeline --name "$name" 2>/dev/null | \
    jq -c --arg name "$name" '{pipeline_name:$name, data:.}' \
    >> "${OUT_DIR}/raw/codepipeline-pipeline-details.ndjson" || true
done <<< "$pipeline_names"

# ── CodeDeploy ────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/codedeploy-applications.json" deploy list-applications
cd_app_names="$(jq -r '.applications[]? // empty' \
  "${OUT_DIR}/raw/codedeploy-applications.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/codedeploy-deployment-groups.ndjson"
while IFS= read -r app; do
  [[ -z "$app" ]] && continue
  dg_names="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" deploy list-deployment-groups \
    --application-name "$app" 2>/dev/null \
    | jq -r '.deploymentGroups[]? // empty' || true)"
  while IFS= read -r dg; do
    [[ -z "$dg" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" deploy get-deployment-group \
      --application-name "$app" --deployment-group-name "$dg" 2>/dev/null | \
      jq -c --arg app "$app" --arg dg "$dg" \
        '{application_name:$app, deployment_group_name:$dg, data:.}' \
      >> "${OUT_DIR}/raw/codedeploy-deployment-groups.ndjson" || true
  done <<< "$dg_names"
done <<< "$cd_app_names"

# ── CodeStar Connections ──────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/codestar-connections.json" codestar-connections list-connections

# ── IAM OIDC providers (global — skip in multi-region mode) ───────────────────
if [[ "$SKIP_GLOBALS" != "true" ]]; then
  safe_aws_json "${OUT_DIR}/raw/iam-oidc-providers.json" \
    iam list-open-id-connect-providers
  oidc_arns="$(jq -r '.OpenIDConnectProviderList[]?.Arn // empty' \
    "${OUT_DIR}/raw/iam-oidc-providers.json" 2>/dev/null || true)"
  : > "${OUT_DIR}/raw/iam-oidc-provider-details.ndjson"
  while IFS= read -r arn; do
    [[ -z "$arn" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$arn" 2>/dev/null | \
      jq -c --arg arn "$arn" '{provider_arn:$arn, data:.}' \
      >> "${OUT_DIR}/raw/iam-oidc-provider-details.ndjson" || true
  done <<< "$oidc_arns"
fi
