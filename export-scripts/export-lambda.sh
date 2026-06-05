#!/usr/bin/env bash
# Serverless — Lambda, API Gateway (REST + HTTP/WebSocket), Cognito
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-lambda.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── Lambda ────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/lambda-functions.json"              lambda list-functions
safe_aws_json "${OUT_DIR}/raw/lambda-event-source-mappings.json"  lambda list-event-source-mappings
lambda_names="$(jq -r '.Functions[]?.FunctionName // empty' \
  "${OUT_DIR}/raw/lambda-functions.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/lambda-function-policies.ndjson"
while IFS= read -r fn; do
  [[ -z "$fn" ]] && continue
  if lambda_policy_out="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" lambda get-policy \
      --function-name "$fn" 2>/dev/null)"; then
    echo "$lambda_policy_out" | jq -c --arg fn "$fn" '{function_name:$fn, data:.}' \
      >> "${OUT_DIR}/raw/lambda-function-policies.ndjson"
  fi
done <<< "$lambda_names"

# ── API Gateway REST v1 ───────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/apigw-rest-apis.json"    apigateway get-rest-apis
safe_aws_json "${OUT_DIR}/raw/apigw-domain-names.json" apigateway get-domain-names
rest_api_ids="$(jq -r '.items[]?.id // empty' \
  "${OUT_DIR}/raw/apigw-rest-apis.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/apigw-rest-stages.ndjson"
: > "${OUT_DIR}/raw/apigw-rest-resources.ndjson"
: > "${OUT_DIR}/raw/apigw-rest-authorizers.ndjson"
while IFS= read -r api_id; do
  [[ -z "$api_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigateway get-stages --rest-api-id "$api_id" 2>/dev/null | \
    jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigw-rest-stages.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigateway get-resources --rest-api-id "$api_id" \
    --embed methods/integrations 2>/dev/null | \
    jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigw-rest-resources.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigateway get-authorizers --rest-api-id "$api_id" 2>/dev/null | \
    jq -c --arg id "$api_id" '{rest_api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigw-rest-authorizers.ndjson" || true
done <<< "$rest_api_ids"

# ── API Gateway HTTP/WebSocket v2 ─────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/apigwv2-apis.json"         apigatewayv2 get-apis
safe_aws_json "${OUT_DIR}/raw/apigwv2-domain-names.json" apigatewayv2 get-domain-names
safe_aws_json "${OUT_DIR}/raw/apigwv2-vpc-links.json"    apigatewayv2 get-vpc-links
v2_api_ids="$(jq -r '.Items[]?.ApiId // empty' \
  "${OUT_DIR}/raw/apigwv2-apis.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/apigwv2-stages.ndjson"
: > "${OUT_DIR}/raw/apigwv2-integrations.ndjson"
: > "${OUT_DIR}/raw/apigwv2-authorizers.ndjson"
while IFS= read -r api_id; do
  [[ -z "$api_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigatewayv2 get-stages --api-id "$api_id" 2>/dev/null | \
    jq -c --arg id "$api_id" '{api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigwv2-stages.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigatewayv2 get-integrations --api-id "$api_id" 2>/dev/null | \
    jq -c --arg id "$api_id" '{api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigwv2-integrations.ndjson" || true
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" apigatewayv2 get-authorizers --api-id "$api_id" 2>/dev/null | \
    jq -c --arg id "$api_id" '{api_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/apigwv2-authorizers.ndjson" || true
done <<< "$v2_api_ids"

# ── Cognito ───────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/cognito-user-pools.json" \
  cognito-idp list-user-pools --max-results 60
cognito_pool_ids="$(jq -r '.UserPools[]?.Id // empty' \
  "${OUT_DIR}/raw/cognito-user-pools.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/cognito-user-pool-details.ndjson"
while IFS= read -r pool_id; do
  [[ -z "$pool_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" cognito-idp describe-user-pool \
    --user-pool-id "$pool_id" 2>/dev/null | \
    jq -c --arg id "$pool_id" '{user_pool_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/cognito-user-pool-details.ndjson" || true
done <<< "$cognito_pool_ids"
