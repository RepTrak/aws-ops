#!/usr/bin/env bash
# Messaging — SQS, SNS, EventBridge, Step Functions, MQ, MSK, Kinesis, Firehose
# Usage: OUT_DIR=snapshots/... ./export-scripts/export-messaging.sh [--region R] [--profile P]
set -euo pipefail
source "$(dirname "$0")/_common.sh"
setup_common "$@"

# ── SQS ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/sqs-queues.json" sqs list-queues
queue_urls="$(jq -r '.QueueUrls[]? // empty' "${OUT_DIR}/raw/sqs-queues.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/sqs-queue-attributes.ndjson"
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" sqs get-queue-attributes \
    --queue-url "$url" --attribute-names All 2>/dev/null | \
    jq -c --arg url "$url" '{queue_url:$url, data:.}' \
    >> "${OUT_DIR}/raw/sqs-queue-attributes.ndjson" || true
done <<< "$queue_urls"

# ── SNS ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/sns-topics.json"        sns list-topics
safe_aws_json "${OUT_DIR}/raw/sns-subscriptions.json" sns list-subscriptions
topic_arns="$(jq -r '.Topics[]?.TopicArn // empty' "${OUT_DIR}/raw/sns-topics.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/sns-topic-attributes.ndjson"
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" sns get-topic-attributes --topic-arn "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{topic_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/sns-topic-attributes.ndjson" || true
done <<< "$topic_arns"

# ── EventBridge ───────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/events-buses.json" events list-event-buses
: > "${OUT_DIR}/raw/events-rules.ndjson"
: > "${OUT_DIR}/raw/events-targets.ndjson"
while IFS= read -r bus; do
  [[ -z "$bus" ]] && continue
  bus_rules_file="${OUT_DIR}/raw/events-rules-${bus}.json"
  safe_aws_json "$bus_rules_file" events list-rules --event-bus-name "$bus"
  jq -c --arg bus "$bus" '{event_bus_name:$bus, data:.}' "$bus_rules_file" \
    >> "${OUT_DIR}/raw/events-rules.ndjson"
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" events list-targets-by-rule \
      --rule "$rule" --event-bus-name "$bus" 2>/dev/null | \
      jq -c --arg rule "$rule" --arg bus "$bus" \
        '{rule_name:$rule, event_bus_name:$bus, data:.}' \
      >> "${OUT_DIR}/raw/events-targets.ndjson" || true
  done < <(jq -r '.Rules[]?.Name // empty' "$bus_rules_file")
done < <(jq -r '.EventBuses[]?.Name // empty' "${OUT_DIR}/raw/events-buses.json" 2>/dev/null || true)

safe_aws_json "${OUT_DIR}/raw/scheduler-schedule-groups.json" scheduler list-schedule-groups
safe_aws_json "${OUT_DIR}/raw/scheduler-schedules.json"       scheduler list-schedules

# ── Step Functions ────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/stepfunctions-state-machines.json" \
  stepfunctions list-state-machines
sm_arns="$(jq -r '.stateMachines[]?.stateMachineArn // empty' \
  "${OUT_DIR}/raw/stepfunctions-state-machines.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/stepfunctions-state-machine-details.ndjson"
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" stepfunctions describe-state-machine \
    --state-machine-arn "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{state_machine_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/stepfunctions-state-machine-details.ndjson" || true
done <<< "$sm_arns"

# ── Amazon MQ ─────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/mq-brokers.json" mq list-brokers
broker_ids="$(jq -r '.BrokerSummaries[]?.BrokerId // empty' \
  "${OUT_DIR}/raw/mq-brokers.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/mq-broker-details.ndjson"
while IFS= read -r broker_id; do
  [[ -z "$broker_id" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" mq describe-broker --broker-id "$broker_id" 2>/dev/null | \
    jq -c --arg id "$broker_id" '{broker_id:$id, data:.}' \
    >> "${OUT_DIR}/raw/mq-broker-details.ndjson" || true
done <<< "$broker_ids"

# ── MSK ───────────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/kafka-clusters.json" kafka list-clusters-v2
kafka_arns="$(jq -r '.ClusterInfoList[]?.ClusterArn // empty' \
  "${OUT_DIR}/raw/kafka-clusters.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/kafka-cluster-details.ndjson"
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" kafka describe-cluster-v2 --cluster-arn "$arn" 2>/dev/null | \
    jq -c --arg arn "$arn" '{cluster_arn:$arn, data:.}' \
    >> "${OUT_DIR}/raw/kafka-cluster-details.ndjson" || true
done <<< "$kafka_arns"

# ── Kinesis ───────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/kinesis-streams.json" kinesis list-streams
kinesis_stream_names="$(jq -r '.StreamNames[]? // empty' \
  "${OUT_DIR}/raw/kinesis-streams.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/kinesis-stream-details.ndjson"
while IFS= read -r stream; do
  [[ -z "$stream" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" kinesis describe-stream-summary \
    --stream-name "$stream" 2>/dev/null | \
    jq -c --arg s "$stream" '{stream_name:$s, data:.}' \
    >> "${OUT_DIR}/raw/kinesis-stream-details.ndjson" || true
done <<< "$kinesis_stream_names"

# ── Firehose ──────────────────────────────────────────────────────────────────
safe_aws_json "${OUT_DIR}/raw/firehose-delivery-streams.json" firehose list-delivery-streams
firehose_stream_names="$(jq -r '.DeliveryStreamNames[]? // empty' \
  "${OUT_DIR}/raw/firehose-delivery-streams.json" 2>/dev/null || true)"
: > "${OUT_DIR}/raw/firehose-delivery-stream-details.ndjson"
while IFS= read -r stream; do
  [[ -z "$stream" ]] && continue
  ${_TIMEOUT_CMD} aws "${AWS_ARGS[@]}" firehose describe-delivery-stream \
    --delivery-stream-name "$stream" 2>/dev/null | \
    jq -c --arg s "$stream" '{stream_name:$s, data:.}' \
    >> "${OUT_DIR}/raw/firehose-delivery-stream-details.ndjson" || true
done <<< "$firehose_stream_names"
