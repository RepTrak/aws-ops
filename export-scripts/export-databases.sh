#!/usr/bin/env bash
# Databases — RDS (+ Proxy), Redshift (+ Serverless), DocumentDB, DynamoDB
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-databases.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── RDS ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/rds-db-instances.json"            rds describe-db-instances
safe_aws_json "${OUT_DIR}/raw/rds-db-clusters.json"             rds describe-db-clusters
safe_aws_json "${OUT_DIR}/raw/rds-db-subnet-groups.json"        rds describe-db-subnet-groups
safe_aws_json "${OUT_DIR}/raw/rds-db-parameter-groups.json"     rds describe-db-parameter-groups
safe_aws_json "${OUT_DIR}/raw/rds-db-snapshots.json"            rds describe-db-snapshots
safe_aws_json "${OUT_DIR}/raw/rds-db-cluster-snapshots.json"    rds describe-db-cluster-snapshots
safe_aws_json "${OUT_DIR}/raw/rds-automated-backups.json"       rds describe-db-instance-automated-backups
safe_aws_json "${OUT_DIR}/raw/rds-event-subscriptions.json"     rds describe-event-subscriptions

rds_pg_names="$(jq -r '.DBParameterGroups[]?.DBParameterGroupName // empty' \
  "${OUT_DIR}/raw/rds-db-parameter-groups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/rds-db-parameter-group-contents.ndjson"
while IFS= read -r pg; do
  [[ -z "$pg" ]] && continue
  aws "${AWS_ARGS[@]}" rds describe-db-parameters --db-parameter-group-name "$pg" 2>/dev/null | \
    jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' \
    >> "${OUT_DIR}/raw/rds-db-parameter-group-contents.ndjson" || true
done <<< "$rds_pg_names"

# ── RDS Proxy ─────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/rds-db-proxies.json" rds describe-db-proxies
proxy_names="$(jq -r '.DBProxies[]?.DBProxyName // empty' \
  "${OUT_DIR}/raw/rds-db-proxies.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/rds-db-proxy-targets.ndjson"
: > "${OUT_DIR}/raw/rds-db-proxy-target-groups.ndjson"
while IFS= read -r proxy; do
  [[ -z "$proxy" ]] && continue
  aws "${AWS_ARGS[@]}" rds describe-db-proxy-targets --db-proxy-name "$proxy" 2>/dev/null | \
    jq -c --arg p "$proxy" '{db_proxy_name:$p, data:.}' \
    >> "${OUT_DIR}/raw/rds-db-proxy-targets.ndjson" || true
  aws "${AWS_ARGS[@]}" rds describe-db-proxy-target-groups --db-proxy-name "$proxy" 2>/dev/null | \
    jq -c --arg p "$proxy" '{db_proxy_name:$p, data:.}' \
    >> "${OUT_DIR}/raw/rds-db-proxy-target-groups.ndjson" || true
done <<< "$proxy_names"

# ── Redshift ──────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/redshift-clusters.json"             redshift describe-clusters
safe_aws_json "${OUT_DIR}/raw/redshift-cluster-subnet-groups.json" redshift describe-cluster-subnet-groups
safe_aws_json "${OUT_DIR}/raw/redshift-parameter-groups.json"     redshift describe-cluster-parameter-groups
safe_aws_json "${OUT_DIR}/raw/redshift-snapshots.json"            redshift describe-cluster-snapshots
safe_aws_json "${OUT_DIR}/raw/redshift-event-subscriptions.json"  redshift describe-event-subscriptions

rs_cluster_ids="$(jq -r '.Clusters[]?.ClusterIdentifier // empty' \
  "${OUT_DIR}/raw/redshift-clusters.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/redshift-logging-status.ndjson"
while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  aws "${AWS_ARGS[@]}" redshift describe-logging-status --cluster-identifier "$cid" 2>/dev/null | \
    jq -c --arg id "$cid" '{cluster_identifier:$id, data:.}' \
    >> "${OUT_DIR}/raw/redshift-logging-status.ndjson" || true
done <<< "$rs_cluster_ids"

rs_pg_names="$(jq -r '.ParameterGroups[]?.ParameterGroupName // empty' \
  "${OUT_DIR}/raw/redshift-parameter-groups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/redshift-parameter-group-contents.ndjson"
while IFS= read -r pg; do
  [[ -z "$pg" ]] && continue
  aws "${AWS_ARGS[@]}" redshift describe-cluster-parameters \
    --parameter-group-name "$pg" 2>/dev/null | \
    jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' \
    >> "${OUT_DIR}/raw/redshift-parameter-group-contents.ndjson" || true
done <<< "$rs_pg_names"

# ── Redshift Serverless ───────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/redshift-serverless-namespaces.json" \
  redshift-serverless list-namespaces
rs_ns_names="$(jq -r '.namespaces[]?.namespaceName // empty' \
  "${OUT_DIR}/raw/redshift-serverless-namespaces.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/redshift-serverless-namespace-details.ndjson"
while IFS= read -r ns; do
  [[ -z "$ns" ]] && continue
  aws "${AWS_ARGS[@]}" redshift-serverless get-namespace --namespace-name "$ns" 2>/dev/null | \
    jq -c --arg ns "$ns" '{namespace_name:$ns, data:.}' \
    >> "${OUT_DIR}/raw/redshift-serverless-namespace-details.ndjson" || true
done <<< "$rs_ns_names"
safe_aws_json "${OUT_DIR}/raw/redshift-serverless-workgroups.json" \
  redshift-serverless list-workgroups
rs_wg_names="$(jq -r '.workgroups[]?.workgroupName // empty' \
  "${OUT_DIR}/raw/redshift-serverless-workgroups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/redshift-serverless-workgroup-details.ndjson"
while IFS= read -r wg; do
  [[ -z "$wg" ]] && continue
  aws "${AWS_ARGS[@]}" redshift-serverless get-workgroup --workgroup-name "$wg" 2>/dev/null | \
    jq -c --arg wg "$wg" '{workgroup_name:$wg, data:.}' \
    >> "${OUT_DIR}/raw/redshift-serverless-workgroup-details.ndjson" || true
done <<< "$rs_wg_names"
safe_aws_json "${OUT_DIR}/raw/redshift-serverless-snapshots.json" \
  redshift-serverless list-snapshots

# ── DocumentDB ────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/docdb-clusters.json"           docdb describe-db-clusters
safe_aws_json "${OUT_DIR}/raw/docdb-instances.json"          docdb describe-db-instances
safe_aws_json "${OUT_DIR}/raw/docdb-subnet-groups.json"      docdb describe-db-subnet-groups
safe_aws_json "${OUT_DIR}/raw/docdb-cluster-snapshots.json"  docdb describe-db-cluster-snapshots
safe_aws_json "${OUT_DIR}/raw/docdb-event-subscriptions.json" docdb describe-event-subscriptions
safe_aws_json "${OUT_DIR}/raw/docdb-parameter-groups.json"   docdb describe-db-cluster-parameter-groups
docdb_pg_names="$(jq -r '.DBClusterParameterGroups[]?.DBClusterParameterGroupName // empty' \
  "${OUT_DIR}/raw/docdb-parameter-groups.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/docdb-parameter-group-contents.ndjson"
while IFS= read -r pg; do
  [[ -z "$pg" ]] && continue
  aws "${AWS_ARGS[@]}" docdb describe-db-cluster-parameters \
    --db-cluster-parameter-group-name "$pg" 2>/dev/null | \
    jq -c --arg pg "$pg" '{parameter_group_name:$pg, data:.}' \
    >> "${OUT_DIR}/raw/docdb-parameter-group-contents.ndjson" || true
done <<< "$docdb_pg_names"

# ── DynamoDB ──────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/dynamodb-tables.json" dynamodb list-tables
ddb_table_names="$(jq -r '.TableNames[]? // empty' \
  "${OUT_DIR}/raw/dynamodb-tables.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/dynamodb-table-details.ndjson"
: > "${OUT_DIR}/raw/dynamodb-continuous-backups.ndjson"
while IFS= read -r table; do
  [[ -z "$table" ]] && continue
  aws "${AWS_ARGS[@]}" dynamodb describe-table --table-name "$table" 2>/dev/null | \
    jq -c --arg t "$table" '{table_name:$t, data:.}' \
    >> "${OUT_DIR}/raw/dynamodb-table-details.ndjson" || true
  aws "${AWS_ARGS[@]}" dynamodb describe-continuous-backups --table-name "$table" 2>/dev/null | \
    jq -c --arg t "$table" '{table_name:$t, data:.}' \
    >> "${OUT_DIR}/raw/dynamodb-continuous-backups.ndjson" || true
done <<< "$ddb_table_names"
safe_aws_json "${OUT_DIR}/raw/dynamodb-backups.json" dynamodb list-backups
