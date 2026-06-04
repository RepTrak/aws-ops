import type { SnapshotData, ServiceTopology } from '@/types/snapshot'

export type DiffStatus = 'added' | 'modified'

export interface ResourceDiff {
  resourceKey: string    // stable identity (ARN, name, ID)
  resourceType: string   // matches ResourceType in graph
  label: string          // display name
  status: DiffStatus
  changes: string[]      // human-readable change descriptions shown in detail panel
}

// ─── helpers ──────────────────────────────────────────────────────────────────

function taskVersion(arn: string): string {
  return arn.split('/').pop() ?? arn
}

function cmpSvc(cur: ServiceTopology, ref: ServiceTopology): string[] {
  const c: string[] = []
  if (cur.task_definition_arn !== ref.task_definition_arn)
    c.push(`Deployed ${taskVersion(cur.task_definition_arn)} (was ${taskVersion(ref.task_definition_arn)})`)
  if (cur.desired_count !== ref.desired_count)
    c.push(`Desired count ${ref.desired_count} → ${cur.desired_count}`)
  if (cur.running_count !== cur.desired_count && ref.running_count === ref.desired_count)
    c.push(`Degraded: ${cur.running_count}/${cur.desired_count} running`)
  return c
}

// ─── main diff ────────────────────────────────────────────────────────────────

export function computeSnapshotDiff(
  current: SnapshotData,
  reference: SnapshotData,
): ResourceDiff[] {
  const out: ResourceDiff[] = []

  function add(key: string, type: string, label: string, status: DiffStatus, changes: string[]) {
    out.push({ resourceKey: key, resourceType: type, label, status, changes })
  }

  // ── ECS services ───────────────────────────────────────────────────────────
  const curSvcs = current.serviceTopology  ?? {}
  const refSvcs = reference.serviceTopology ?? {}
  for (const [arn, svc] of Object.entries(curSvcs)) {
    const ref = refSvcs[arn]
    if (!ref) { add(arn, 'ecs_service', svc.service_name, 'added', ['New service']) }
    else {
      const ch = cmpSvc(svc, ref)
      if (ch.length) add(arn, 'ecs_service', svc.service_name, 'modified', ch)
    }
  }

  // ── Lambda functions ───────────────────────────────────────────────────────
  const curFns = new Map((current.lambdaFunctions  ?? []).map(f => [f.FunctionArn, f]))
  const refFns = new Map((reference.lambdaFunctions ?? []).map(f => [f.FunctionArn, f]))
  for (const [arn, fn] of curFns) {
    const ref = refFns.get(arn)
    if (!ref) { add(arn, 'lambda', fn.FunctionName, 'added', ['New function']) }
    else {
      const ch: string[] = []
      if (fn.Runtime !== ref.Runtime) ch.push(`Runtime: ${ref.Runtime} → ${fn.Runtime}`)
      if (fn.Role   !== ref.Role)    ch.push('IAM role changed')
      if (ch.length) add(arn, 'lambda', fn.FunctionName, 'modified', ch)
    }
  }

  // ── RDS instances ──────────────────────────────────────────────────────────
  const curRds = new Map((current.rdsInstances  ?? []).map(r => [r.DBInstanceIdentifier, r]))
  const refRds = new Map((reference.rdsInstances ?? []).map(r => [r.DBInstanceIdentifier, r]))
  for (const [id, rds] of curRds) {
    const ref = refRds.get(id)
    if (!ref) { add(id, 'rds_instance', id, 'added', ['New RDS instance']) }
    else {
      const ch: string[] = []
      if (rds.DBInstanceStatus !== ref.DBInstanceStatus) ch.push(`Status: ${ref.DBInstanceStatus} → ${rds.DBInstanceStatus}`)
      if (rds.DBInstanceClass  !== ref.DBInstanceClass)  ch.push(`Class: ${ref.DBInstanceClass} → ${rds.DBInstanceClass}`)
      if (ch.length) add(id, 'rds_instance', id, 'modified', ch)
    }
  }

  // ── ElastiCache ────────────────────────────────────────────────────────────
  const curEc = new Map((current.elasticacheGroups  ?? []).map(g => [g.ReplicationGroupId, g]))
  const refEc = new Map((reference.elasticacheGroups ?? []).map(g => [g.ReplicationGroupId, g]))
  for (const [id, eg] of curEc) {
    const ref = refEc.get(id)
    if (!ref) { add(id, 'elasticache', id, 'added', ['New cache cluster']) }
    else {
      const ch: string[] = []
      if (eg.Status !== ref.Status) ch.push(`Status: ${ref.Status} → ${eg.Status}`)
      if (ch.length) add(id, 'elasticache', id, 'modified', ch)
    }
  }

  // ── Redshift clusters ──────────────────────────────────────────────────────
  const curRs = new Map((current.redshiftClusters  ?? []).map(c => [c.ClusterIdentifier, c]))
  const refRs = new Map((reference.redshiftClusters ?? []).map(c => [c.ClusterIdentifier, c]))
  for (const [id, cl] of curRs) {
    const ref = refRs.get(id)
    if (!ref) { add(id, 'redshift_cluster', id, 'added', ['New Redshift cluster']) }
    else {
      const ch: string[] = []
      if (cl.ClusterStatus !== ref.ClusterStatus) ch.push(`Status: ${ref.ClusterStatus} → ${cl.ClusterStatus}`)
      if (cl.NodeType      !== ref.NodeType)      ch.push(`Node type: ${ref.NodeType} → ${cl.NodeType}`)
      if (cl.NumberOfNodes !== ref.NumberOfNodes) ch.push(`Nodes: ${ref.NumberOfNodes} → ${cl.NumberOfNodes}`)
      if (ch.length) add(id, 'redshift_cluster', id, 'modified', ch)
    }
  }

  // ── DynamoDB tables ────────────────────────────────────────────────────────
  const curTbls = new Set(current.dynamoTables  ?? [])
  const refTbls = new Set(reference.dynamoTables ?? [])
  for (const tbl of curTbls) if (!refTbls.has(tbl)) add(tbl, 'dynamodb_table', tbl, 'added', ['New table'])

  // ── S3 buckets ─────────────────────────────────────────────────────────────
  const curS3 = new Set((current.s3Buckets  ?? []).map(b => b.Name))
  const refS3 = new Set((reference.s3Buckets ?? []).map(b => b.Name))
  for (const name of curS3) if (!refS3.has(name)) add(name, 's3_bucket', name, 'added', ['New bucket'])

  // ── SQS queues ─────────────────────────────────────────────────────────────
  const qName = (url: string) => url.split('/').pop() ?? url
  const curQ = new Set((current.sqsQueues  ?? []).map(qName))
  const refQ = new Set((reference.sqsQueues ?? []).map(qName))
  for (const name of curQ) if (!refQ.has(name)) add(name, 'sqs_queue', name, 'added', ['New queue'])

  // ── SNS topics ─────────────────────────────────────────────────────────────
  const tName = (arn: string) => arn.split(':').pop() ?? arn
  const curT = new Set((current.snsTopics  ?? []).map(t => t.TopicArn))
  const refT = new Set((reference.snsTopics ?? []).map(t => t.TopicArn))
  for (const arn of curT) if (!refT.has(arn)) add(arn, 'sns_topic', tName(arn), 'added', ['New topic'])

  // ── API Gateway v2 ─────────────────────────────────────────────────────────
  const curApi = new Map((current.apigwv2Apis  ?? []).map(a => [a.ApiId, a]))
  const refApi = new Map((reference.apigwv2Apis ?? []).map(a => [a.ApiId, a]))
  for (const [id, api] of curApi) {
    if (!refApi.has(id)) add(`apigw-v2-${id}`, 'api_gateway_http', api.Name, 'added', ['New API'])
  }

  // ── Lambda event source mappings (new triggers) ────────────────────────────
  const curEsm = new Set((current.lambdaFunctions ?? []).map(f => f.FunctionArn))
  // (Detailed ESM diff requires loading raw files; skip for now — covered by lambda diff above)

  // ── Cognito user pools ─────────────────────────────────────────────────────
  const curPools = new Set((current.cognitoUserPools  ?? []).map(p => p.Id))
  const refPools = new Set((reference.cognitoUserPools ?? []).map(p => p.Id))
  for (const id of curPools) {
    if (!refPools.has(id)) {
      const pool = current.cognitoUserPools?.find(p => p.Id === id)
      add(`cognito-${id}`, 'cognito_pool', pool?.Name ?? id, 'added', ['New Cognito pool'])
    }
  }

  return out
}

// ─── find graph node that corresponds to a diff entry ─────────────────────────

import type { ResourceNode, ResourceNodeData } from '@/types/graph'

export function findNodeForDiff(nodes: ResourceNode[], diff: ResourceDiff): ResourceNode | undefined {
  return nodes.find(n => {
    const d = n.data as ResourceNodeData
    if (String(d.resourceType) !== diff.resourceType) return false
    if (String(d.label) === diff.label) return true
    // Also check ARN in metadata
    return (d.metadata as {key:string;value:string}[]).some(m =>
      (m.key === 'ARN' || m.key === 'Key ID') && m.value === diff.resourceKey)
  })
}
