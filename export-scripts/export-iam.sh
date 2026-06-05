#!/usr/bin/env bash
# IAM — roles, users, groups, local policies (global, skip with --skip-globals)
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-iam.sh [--region R] [--profile P] [--skip-globals]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

if [[ "$SKIP_GLOBALS" == "true" ]]; then
  echo "  IAM skipped (--skip-globals)" >&2
  exit 0
fi

safe_aws_json "${OUT_DIR}/raw/iam-roles.json" iam list-roles
role_names="$(jq -r '.Roles[]?.RoleName // empty' "${OUT_DIR}/raw/iam-roles.json")"
: > "${OUT_DIR}/raw/iam-role-details.ndjson"
: > "${OUT_DIR}/raw/iam-role-inline-policies.ndjson"
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  managed="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-attached-role-policies \
    --role-name "$role" 2>/dev/null)" || managed="{}"
  [[ -z "$managed" ]] && managed="{}"
  inline="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-role-policies \
    --role-name "$role" 2>/dev/null)" || inline="{}"
  [[ -z "$inline" ]] && inline="{}"
  trust="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam get-role \
    --role-name "$role" 2>/dev/null)" || trust="{}"
  [[ -z "$trust" ]] && trust="{}"
  jq -cn \
    --arg role_name "$role" \
    --argjson trust "$trust" \
    --argjson managed "$managed" \
    --argjson inline "$inline" \
    '{role_name:$role_name, trust:$trust, managed:$managed, inline:$inline}' \
    >> "${OUT_DIR}/raw/iam-role-details.ndjson"
  while IFS= read -r policy_name; do
    [[ -z "$policy_name" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam get-role-policy \
      --role-name "$role" --policy-name "$policy_name" 2>/dev/null | \
      jq -c --arg role "$role" --arg policy "$policy_name" \
        '{role_name:$role, policy_name:$policy, data:.}' \
      >> "${OUT_DIR}/raw/iam-role-inline-policies.ndjson" || true
  done < <(echo "$inline" | jq -r '.PolicyNames[]? // empty')
done <<< "$role_names"

safe_aws_json "${OUT_DIR}/raw/iam-instance-profiles.json" iam list-instance-profiles

safe_aws_json "${OUT_DIR}/raw/iam-users.json" iam list-users
iam_user_names="$(jq -r '.Users[]?.UserName // empty' \
  "${OUT_DIR}/raw/iam-users.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/iam-user-details.ndjson"
while IFS= read -r user; do
  [[ -z "$user" ]] && continue
  u_managed="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-attached-user-policies \
    --user-name "$user" 2>/dev/null)" || u_managed="{}"
  [[ -z "$u_managed" ]] && u_managed="{}"
  u_inline="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-user-policies \
    --user-name "$user" 2>/dev/null)" || u_inline="{}"
  [[ -z "$u_inline" ]] && u_inline="{}"
  jq -cn \
    --arg user_name "$user" \
    --argjson managed "$u_managed" \
    --argjson inline "$u_inline" \
    '{user_name:$user_name, managed:$managed, inline:$inline}' \
    >> "${OUT_DIR}/raw/iam-user-details.ndjson"
done <<< "$iam_user_names"

safe_aws_json "${OUT_DIR}/raw/iam-groups.json" iam list-groups
iam_group_names="$(jq -r '.Groups[]?.GroupName // empty' \
  "${OUT_DIR}/raw/iam-groups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/iam-group-details.ndjson"
while IFS= read -r grp; do
  [[ -z "$grp" ]] && continue
  g_managed="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-attached-group-policies \
    --group-name "$grp" 2>/dev/null)" || g_managed="{}"
  [[ -z "$g_managed" ]] && g_managed="{}"
  g_inline="$(${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam list-group-policies \
    --group-name "$grp" 2>/dev/null)" || g_inline="{}"
  [[ -z "$g_inline" ]] && g_inline="{}"
  jq -cn \
    --arg group_name "$grp" \
    --argjson managed "$g_managed" \
    --argjson inline "$g_inline" \
    '{group_name:$group_name, managed:$managed, inline:$inline}' \
    >> "${OUT_DIR}/raw/iam-group-details.ndjson"
done <<< "$iam_group_names"

safe_aws_json "${OUT_DIR}/raw/iam-local-policies.json" iam list-policies --scope Local
: > "${OUT_DIR}/raw/iam-local-policy-versions.ndjson"
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  p_arn="$(echo "$entry" | cut -d'|' -f1)"
  p_ver="$(echo "$entry" | cut -d'|' -f2)"
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" iam get-policy-version \
    --policy-arn "$p_arn" --version-id "$p_ver" 2>/dev/null | \
    jq -c --arg arn "$p_arn" '{policy_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/iam-local-policy-versions.ndjson" || true
done < <(jq -r '.Policies[]? | [.Arn, .DefaultVersionId] | join("|")' \
  "${OUT_DIR}/raw/iam-local-policies.json" 2>/dev/null || true)
