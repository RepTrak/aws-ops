import { MarkerType } from '@xyflow/react'
import type { SnapshotData } from '@/types/snapshot'
import type {
  ResourceNode, RelationshipEdge, ResourceType, ResourceCategory,
  RelationshipSummary, EdgeRelationship,
} from '@/types/graph'
import { RESOURCE_CATEGORY, RESOURCE_ICON, EDGE_COLORS } from '@/lib/colors'
import { generateAIBrief } from '@/lib/aibrief'

// ─── ID registry ──────────────────────────────────────────────────────────────

let _nodeSeq = 0
const _nodeMap = new Map<string, string>() // original key → nodeId

function nodeId(key: string): string {
  if (!_nodeMap.has(key)) _nodeMap.set(key, `n${++_nodeSeq}`)
  return _nodeMap.get(key)!
}

/** Look up a node by its original resource key. Returns undefined if not registered. */
function findNode(key: string, nodes: ResourceNode[]): ResourceNode | undefined {
  if (!_nodeMap.has(key)) return undefined
  const id = _nodeMap.get(key)!
  return nodes.find(n => n.id === id)
}

// ─── Edge helpers ─────────────────────────────────────────────────────────────

let _edgeSeq = 0
const _edgeSet = new Set<string>() // dedup key

/** Create an edge between pre-resolved React Flow node IDs. */
function mkEdge(
  srcId: string, tgtId: string,
  rel: EdgeRelationship,
  description: string,
  visible: boolean,
  port?: string,
): RelationshipEdge {
  const color = EDGE_COLORS[rel]?.stroke ?? '#94A3B8'
  return {
    id: `e${++_edgeSeq}`,
    source: srcId, target: tgtId,
    type: 'relationship',
    hidden: !visible,
    // React Flow injects this marker directly into the canvas SVG, which fixes
    // orient="auto" rotation and gives each edge type its own colored arrowhead.
    markerEnd: { type: MarkerType.ArrowClosed, width: 10, height: 10, color } as any,
    data: { relationship: rel, description, port, animated: rel === 'dataflow' },
  }
}

/** Add edge only once per (src, tgt, rel) triple. */
function addEdge(
  edges: RelationshipEdge[],
  srcId: string, tgtId: string,
  rel: EdgeRelationship, description: string, visible: boolean, port?: string,
) {
  if (!srcId || !tgtId || srcId === tgtId) return
  const key = `${srcId}→${tgtId}:${rel}`
  if (_edgeSet.has(key)) return
  _edgeSet.add(key)
  edges.push(mkEdge(srcId, tgtId, rel, description, visible, port))
}

// ─── Node factory ─────────────────────────────────────────────────────────────

function mkNode(
  key: string, resourceType: ResourceType, label: string, sublabel: string,
  metadata: { key: string; value: string }[], raw: Record<string, unknown>,
  status: ResourceNode['data']['status'], visible: boolean,
): ResourceNode {
  const category: ResourceCategory = RESOURCE_CATEGORY[resourceType]
  return {
    id: nodeId(key), type: 'resource',
    position: { x: 0, y: 0 }, hidden: !visible,
    data: {
      resourceType, category, label, sublabel, status,
      expanded: false, neighborIds: [],
      raw, metadata, aibrief: '', relationships: [],
    },
  }
}

// ─── Main builder ──────────────────────────────────────────────────────────────

// ─── Target health helper ──────────────────────────────────────────────────

function buildHealthSummary(
  tgArns: string[],
  healthRecords: SnapshotData['targetHealth'],
): { label: string; status: 'running' | 'warning' | 'error' } | null {
  const records = healthRecords.filter(r => tgArns.includes(r.target_group_arn))
  if (records.length === 0) return null

  let healthy = 0, total = 0
  for (const rec of records) {
    const descs = rec.data?.TargetHealthDescriptions ?? []
    total   += descs.length
    healthy += descs.filter(d => d.TargetHealth?.State === 'healthy').length
  }
  if (total === 0) return null

  const label  = `${healthy}/${total} healthy`
  const status = healthy === total ? 'running' : healthy === 0 ? 'error' : 'warning'
  return { label, status }
}

export function buildGraph(snap: SnapshotData): { nodes: ResourceNode[]; edges: RelationshipEdge[] } {
  _nodeSeq = 0; _edgeSeq = 0; _nodeMap.clear(); _edgeSet.clear()

  const nodes: ResourceNode[] = []
  const edges: RelationshipEdge[] = []
  const add = (n: ResourceNode) => nodes.push(n)
  const edge = (srcId: string, tgtId: string, rel: EdgeRelationship, desc: string, vis = false, port?: string) =>
    addEdge(edges, srcId, tgtId, rel, desc, vis, port)

  // ── ECS services ─────────────────────────────────────────────────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const clusterName = svc.cluster_arn.split('/').pop() ?? svc.cluster_arn
    const tdRev = svc.task_definition_arn.split('/').pop() ?? ''
    const health = buildHealthSummary(svc.load_balancer_target_groups, snap.targetHealth ?? [])
    const baseStatus: ResourceNode['data']['status'] =
      svc.running_count === svc.desired_count && svc.desired_count > 0 ? 'running'
      : svc.running_count === 0 ? 'stopped' : 'warning'
    add(mkNode(svcArn, 'ecs_service', svc.service_name, clusterName, [
      { key: 'ARN', value: svcArn },
      { key: 'Cluster', value: clusterName },
      { key: 'Task Definition', value: tdRev },
      { key: 'Running / Desired', value: `${svc.running_count} / ${svc.desired_count}` },
      ...(health ? [{ key: 'Target Health', value: health.label }] : []),
      { key: 'Subnets', value: svc.subnets.join(', ') },
      { key: 'Security Groups', value: svc.security_groups.join(', ') },
      ...(svc.task_role_arn ? [{ key: 'Task Role', value: svc.task_role_arn.split('/').pop() ?? '' }] : []),
    ], svc as unknown as Record<string, unknown>,
    health ? health.status : baseStatus, true))
  }

  // ── ALBs ─────────────────────────────────────────────────────────────────
  for (const [lbArn, alb] of Object.entries(snap.albToService ?? {})) {
    const allTgArns = alb.target_groups.map((tg: {arn: string}) => tg.arn)
    const albHealth = buildHealthSummary(allTgArns, snap.targetHealth ?? [])
    add(mkNode(lbArn, 'alb', alb.name, alb.scheme, [
      { key: 'ARN', value: lbArn },
      { key: 'DNS', value: alb.dns_name },
      { key: 'Scheme', value: alb.scheme },
      ...(albHealth ? [{ key: 'Target Health', value: albHealth.label }] : []),
    ], alb as unknown as Record<string, unknown>, albHealth ? albHealth.status : 'running', true))
    for (const svcArn of alb.ecs_services) {
      if (snap.serviceTopology[svcArn])
        edge(nodeId(lbArn), nodeId(svcArn), 'deployment', 'routes traffic to', true)
    }
  }

  // ── RDS instances ─────────────────────────────────────────────────────────
  for (const rds of snap.rdsInstances ?? []) {
    add(mkNode(rds.DBInstanceIdentifier, 'rds_instance', rds.DBInstanceIdentifier, rds.Engine, [
      { key: 'Identifier', value: rds.DBInstanceIdentifier },
      { key: 'Engine', value: `${rds.Engine} (${rds.DBInstanceClass})` },
      { key: 'Status', value: rds.DBInstanceStatus },
      { key: 'Endpoint', value: rds.Endpoint ? `${rds.Endpoint.Address}:${rds.Endpoint.Port}` : 'N/A' },
      { key: 'Security Groups', value: rds.VpcSecurityGroups.map(s => s.VpcSecurityGroupId).join(', ') },
    ], rds as unknown as Record<string, unknown>,
    rds.DBInstanceStatus === 'available' ? 'running' : 'warning', true))
  }

  // ── RDS clusters ──────────────────────────────────────────────────────────
  for (const cl of snap.rdsClusters ?? []) {
    add(mkNode(cl.DBClusterIdentifier, 'rds_cluster', cl.DBClusterIdentifier, cl.Engine, [
      { key: 'Identifier', value: cl.DBClusterIdentifier },
      { key: 'Engine', value: cl.Engine },
      { key: 'Status', value: cl.Status },
    ], cl as unknown as Record<string, unknown>,
    cl.Status === 'available' ? 'running' : 'warning', true))
  }

  // ── Redshift ──────────────────────────────────────────────────────────────
  for (const cl of snap.redshiftClusters ?? []) {
    add(mkNode(cl.ClusterIdentifier, 'redshift_cluster', cl.ClusterIdentifier,
      `${cl.NodeType} ×${cl.NumberOfNodes}`, [
        { key: 'Identifier', value: cl.ClusterIdentifier },
        { key: 'Node Type', value: cl.NodeType },
        { key: 'Status', value: cl.ClusterStatus },
      ], cl as unknown as Record<string, unknown>,
      cl.ClusterStatus === 'available' ? 'running' : 'warning', true))
  }
  for (const wg of snap.redshiftServerlessWorkgroups ?? []) {
    add(mkNode(wg.workgroupName, 'redshift_serverless', wg.workgroupName, 'Serverless', [
      { key: 'Workgroup', value: wg.workgroupName }, { key: 'Status', value: wg.status },
    ], wg as unknown as Record<string, unknown>,
    wg.status === 'AVAILABLE' ? 'running' : 'warning', true))
  }

  // ── ElastiCache ──────────────────────────────────────────────────────────
  for (const eg of snap.elasticacheGroups ?? []) {
    add(mkNode(eg.ReplicationGroupId, 'elasticache', eg.ReplicationGroupId, 'Redis', [
      { key: 'Replication Group', value: eg.ReplicationGroupId },
      { key: 'Status', value: eg.Status },
    ], eg as unknown as Record<string, unknown>,
    eg.Status === 'available' ? 'running' : 'warning', true))
  }

  // ── DynamoDB ─────────────────────────────────────────────────────────────
  for (const tbl of snap.dynamoTables ?? []) {
    add(mkNode(tbl, 'dynamodb_table', tbl, 'DynamoDB', [
      { key: 'Table', value: tbl },
    ], { TableName: tbl }, 'running', true))
  }

  // ── Lambda ───────────────────────────────────────────────────────────────
  for (const fn of snap.lambdaFunctions ?? []) {
    add(mkNode(fn.FunctionArn, 'lambda', fn.FunctionName, fn.Runtime, [
      { key: 'ARN', value: fn.FunctionArn },
      { key: 'Runtime', value: fn.Runtime },
      { key: 'Handler', value: fn.Handler },
      { key: 'Role', value: fn.Role.split('/').pop() ?? fn.Role },
      { key: 'VPC', value: fn.VpcConfig?.VpcId ?? 'No VPC' },
    ], fn as unknown as Record<string, unknown>, 'running', true))
  }

  // ── SQS (hidden — shown via dataflow filter) ──────────────────────────────
  for (const url of snap.sqsQueues ?? []) {
    const name = url.split('/').pop() ?? url
    add(mkNode(url, 'sqs_queue', name, 'SQS', [
      { key: 'Queue URL', value: url }, { key: 'Name', value: name },
    ], { QueueUrl: url }, 'running', false))
  }

  // ── SNS topics (hidden) ───────────────────────────────────────────────────
  for (const t of snap.snsTopics ?? []) {
    const name = t.TopicArn.split(':').pop() ?? t.TopicArn
    add(mkNode(t.TopicArn, 'sns_topic', name, 'SNS', [
      { key: 'ARN', value: t.TopicArn },
    ], t as unknown as Record<string, unknown>, 'running', false))
  }

  // ── API Gateway ───────────────────────────────────────────────────────────
  for (const api of snap.apigwRestApis ?? []) {
    add(mkNode(`apigw-rest-${api.id}`, 'api_gateway_rest', api.name, 'REST API', [
      { key: 'ID', value: api.id }, { key: 'Name', value: api.name },
    ], api as unknown as Record<string, unknown>, 'running', true))
  }
  for (const api of snap.apigwv2Apis ?? []) {
    add(mkNode(`apigw-v2-${api.ApiId}`, 'api_gateway_http', api.Name, api.ProtocolType, [
      { key: 'ID', value: api.ApiId }, { key: 'Protocol', value: api.ProtocolType },
    ], api as unknown as Record<string, unknown>, 'running', true))
  }

  // ── OpenSearch ────────────────────────────────────────────────────────────
  for (const d of snap.openSearchDomains ?? []) {
    add(mkNode(`os-${d.DomainName}`, 'opensearch', d.DomainName, 'OpenSearch', [
      { key: 'Domain', value: d.DomainName },
    ], d as unknown as Record<string, unknown>, 'running', true))
  }

  // ── Kinesis / Firehose (hidden) ───────────────────────────────────────────
  for (const s of snap.kinesisStreams ?? []) {
    add(mkNode(`kinesis-${s}`, 'kinesis_stream', s, 'Kinesis', [
      { key: 'Stream', value: s },
    ], { StreamName: s }, 'running', false))
  }
  for (const s of snap.firehoseStreams ?? []) {
    add(mkNode(`firehose-${s}`, 'firehose_stream', s, 'Firehose', [
      { key: 'Stream', value: s },
    ], { DeliveryStreamName: s }, 'running', false))
  }

  // ── IAM roles (hidden — shown via iam/logging/encryption filters) ─────────
  const rolesWithAccess = new Set(Object.keys(snap.iamRoleResourceAccess ?? {}))
  for (const role of snap.iamRoles ?? []) {
    if (!rolesWithAccess.has(role.RoleName)) continue
    add(mkNode(`role-${role.RoleName}`, 'iam_role', role.RoleName, 'IAM Role', [
      { key: 'ARN', value: role.Arn }, { key: 'Name', value: role.RoleName },
    ], role as unknown as Record<string, unknown>, 'running', false))
  }

  // ── Secrets (hidden — shown when parent expanded or via search) ───────────
  const referencedSecrets = new Set(Object.keys(snap.secretConsumers ?? {}))
  for (const s of snap.secrets ?? []) {
    if (!referencedSecrets.has(s.ARN) && !referencedSecrets.has(s.Name)) continue
    const name = s.Name.split('/').pop() ?? s.Name
    add(mkNode(s.ARN, 'secret', name, 'Secret', [
      { key: 'ARN', value: s.ARN }, { key: 'Name', value: s.Name },
    ], s as unknown as Record<string, unknown>, 'running', false))
  }

  // ── Cognito (visible — auth chain shows) ──────────────────────────────────
  for (const pool of snap.cognitoUserPools ?? []) {
    add(mkNode(`cognito-${pool.Id}`, 'cognito_pool', pool.Name, 'Cognito', [
      { key: 'Pool ID', value: pool.Id }, { key: 'Name', value: pool.Name },
    ], pool as unknown as Record<string, unknown>, 'running', true))
  }

  // ── S3 buckets (visible) ──────────────────────────────────────────────────
  for (const b of snap.s3Buckets ?? []) {
    add(mkNode(b.Name, 's3_bucket', b.Name, 'S3', [
      { key: 'Bucket', value: b.Name },
    ], b as unknown as Record<string, unknown>, 'running', true))
  }

  // ── KMS keys (hidden — revealed by Encryption expand) ────────────────────
  for (const alias of snap.kmsAliases ?? []) {
    if (!alias.TargetKeyId || alias.AliasName.startsWith('alias/aws/')) continue
    const displayName = alias.AliasName.replace('alias/', '')
    add(mkNode(`kms-${alias.TargetKeyId}`, 'kms_key', displayName, 'KMS Key', [
      { key: 'Key ID', value: alias.TargetKeyId },
      { key: 'Alias', value: alias.AliasName },
    ], alias as unknown as Record<string, unknown>, 'running', false))
  }

  for (const [alarmArn, alarm] of Object.entries(snap.cwAlarmTargets ?? {})) {
    const st = alarm.state === 'OK' ? 'running' : alarm.state === 'ALARM' ? 'error' : 'warning'
    add(mkNode(alarmArn, 'cw_alarm', alarm.alarm_name, alarm.namespace ?? 'CloudWatch', [
      { key: 'ARN', value: alarmArn },
      { key: 'Metric', value: alarm.metric ?? '' },
      { key: 'Threshold', value: alarm.threshold !== undefined ? String(alarm.threshold) : '' },
      { key: 'State', value: alarm.state ?? '' },
    ], alarm as unknown as Record<string, unknown>, st, false))
  }

  // ── Log groups (visible — logging edges) ──────────────────────────────────
  // Collect all log groups referenced by services and lambdas
  const logGroupKeys = new Set<string>()
  for (const svc of Object.values(snap.serviceTopology ?? {})) {
    for (const c of svc.containers) { if (c.log_group) logGroupKeys.add(c.log_group) }
  }
  for (const fn of snap.lambdaFunctions ?? []) {
    logGroupKeys.add(`/aws/lambda/${fn.FunctionName}`)
  }
  // Also include groups from raw file if they overlap
  for (const lg of snap.logGroups ?? []) {
    if (logGroupKeys.has(lg.logGroupName)) continue
    // Only include if referenced somewhere — skip generic groups
  }
  // ── Log groups (hidden — revealed by Logging expand) ─────────────────────
  for (const lgPath of logGroupKeys) {
    const name = lgPath.split('/').filter(Boolean).pop() ?? lgPath
    add(mkNode(`lg-${lgPath}`, 'log_group', name, lgPath, [
      { key: 'Log Group', value: lgPath },
    ], { logGroupName: lgPath }, 'running', false))
  }

  // ── Cloud Map namespaces (hidden — revealed by DNS expand) ───────────────
  for (const ns of snap.cloudMapNamespaces ?? []) {
    add(mkNode(`cm-${ns.Id}`, 'cloud_map_namespace', ns.Name, `Cloud Map (${ns.Type})`, [
      { key: 'ID', value: ns.Id },
      { key: 'Name', value: ns.Name },
      { key: 'Type', value: ns.Type },
    ], ns as unknown as Record<string, unknown>, 'running', false))
  }

  // All nodes start hidden — the canvas is built entirely through user
  // interaction (search-to-pin and connection expand/collapse).
  for (const n of nodes) { n.hidden = true }

  // ═══════════════════════════════════════════════════════════════════════════
  // EDGES
  // ═══════════════════════════════════════════════════════════════════════════

  // ── DEPLOYMENT: secret consumers (service → secret) ───────────────────────
  for (const [secretRef, consumers] of Object.entries(snap.secretConsumers ?? {})) {
    const secretNode = nodes.find(n =>
      (n.data.metadata as {key:string;value:string}[]).some(m =>
        (m.key === 'ARN' || m.key === 'Name') && m.value === secretRef))
    if (!secretNode) continue
    const families = [...new Set(consumers.map(c => c.task_definition.split(':')[0]))]
    for (const family of families) {
      const svcNode = nodes.find(n =>
        n.data.resourceType === 'ecs_service' &&
        (n.data.metadata as {key:string;value:string}[])
          .find(m => m.key === 'Task Definition')?.value.split(':')[0] === family)
      if (svcNode) edge(svcNode.id, secretNode.id, 'dataflow', 'reads secret')
    }
  }

  // ── DATAFLOW: DynamoDB stream → Lambda ────────────────────────────────────
  for (const [, dsc] of Object.entries(snap.dynamoStreamConsumers ?? {})) {
    const tblNode = findNode(dsc.table_name, nodes)
    if (!tblNode) continue
    for (const c of dsc.lambda_consumers) {
      const fnNode = findNode(c.function_arn, nodes)
      if (fnNode) edge(tblNode.id, fnNode.id, 'dataflow', 'stream → Lambda')
    }
  }

  // ── DATAFLOW: SQS DLQ chains ──────────────────────────────────────────────
  for (const [, dlq] of Object.entries(snap.sqsDlqChains ?? {})) {
    const srcNode = nodes.find(n => n.data.resourceType === 'sqs_queue' &&
      n.data.label === dlq.queue_name)
    const dlqName = dlq.dlq_arn.split(':').pop() ?? ''
    const dlqNode = nodes.find(n => n.data.resourceType === 'sqs_queue' && n.data.label === dlqName)
    if (srcNode && dlqNode) edge(srcNode.id, dlqNode.id, 'dataflow', 'dead-letter queue')
  }

  // ── AUTH: API Gateway → Cognito ───────────────────────────────────────────
  for (const [, auth] of Object.entries(snap.apigwAuthChain ?? {})) {
    if (!auth.cognito_pool_id) continue
    const apiNode = nodes.find(n =>
      (n.data.resourceType === 'api_gateway_http' || n.data.resourceType === 'api_gateway_rest') &&
      (n.data.metadata as {key:string;value:string}[]).some(m =>
        m.key === 'ID' && m.value === auth.api_id))
    const cogNode = nodes.find(n => n.data.resourceType === 'cognito_pool' &&
      (n.data.metadata as {key:string;value:string}[]).some(m =>
        m.key === 'Pool ID' && m.value === auth.cognito_pool_id))
    if (apiNode && cogNode) edge(apiNode.id, cogNode.id, 'auth', 'JWT auth via', false)
  }

  // ── NETWORK: SG-based resource-to-resource connectivity ───────────────────
  for (const sgEdge of (snap.sgConnectivity?.edges ?? [])) {
    if (!sgEdge.from_sg) continue  // skip plain CIDR ingress
    const fromMembers = snap.sgMembers?.[sgEdge.from_sg] ?? []
    const toMembers   = snap.sgMembers?.[sgEdge.to_sg]   ?? []
    const portLabel   = sgEdge.from_port
      ? `${sgEdge.protocol}:${sgEdge.from_port}`
      : sgEdge.protocol === '-1' ? 'all' : sgEdge.protocol
    for (const from of fromMembers) {
      const fromNode = findNode(from.resource_id, nodes)
      if (!fromNode) continue
      for (const to of toMembers) {
        const toNode = findNode(to.resource_id, nodes)
        if (!toNode) continue
        edge(fromNode.id, toNode.id, 'network', `network access (${portLabel})`, false, portLabel)
      }
    }
  }

  // ── IAM: Lambda → IAM role ────────────────────────────────────────────────
  for (const fn of snap.lambdaFunctions ?? []) {
    const fnNode  = findNode(fn.FunctionArn, nodes)
    if (!fnNode) continue
    const roleName = fn.Role.split('/').pop() ?? ''
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (roleNode) edge(fnNode.id, roleNode.id, 'iam', 'assumes role', false)
  }

  // ── IAM: ECS service → task role ──────────────────────────────────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    if (!svc.task_role_arn) continue
    const svcNode  = findNode(svcArn, nodes)
    const roleName = svc.task_role_arn.split('/').pop() ?? ''
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (svcNode && roleNode) edge(svcNode.id, roleNode.id, 'iam', 'assumes task role', false)
  }

  // ── IAM: IAM role → S3 bucket (from service_access) ──────────────────────
  for (const [roleName, access] of Object.entries(snap.iamRoleResourceAccess ?? {})) {
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (!roleNode) continue
    for (const res of (access.service_access?.s3 ?? [])) {
      const match = res.match(/arn:aws:s3:::([^/]+)/)
      if (!match) continue
      const s3Node = findNode(match[1], nodes)
      if (s3Node) edge(roleNode.id, s3Node.id, 'iam', 'can access', false)
    }
    for (const res of (access.service_access?.sqs ?? [])) {
      const queueName = res.split(':').pop() ?? ''
      const sqsNode = nodes.find(n => n.data.resourceType === 'sqs_queue' && n.data.label === queueName)
      if (sqsNode) edge(roleNode.id, sqsNode.id, 'iam', 'can send/receive', false)
    }
  }

  // ── OBSERVABILITY: alarm → monitored resource ─────────────────────────────
  for (const [alarmArn, alarm] of Object.entries(snap.cwAlarmTargets ?? {})) {
    const alarmNode = findNode(alarmArn, nodes)
    if (!alarmNode) continue
    const rtype = alarm.resource_type
    const rids  = alarm.resource_ids as Record<string, string>
    let resourceNode: ResourceNode | undefined

    if (rtype === 'ecs_service') {
      resourceNode = nodes.find(n => n.data.resourceType === 'ecs_service' &&
        n.data.label === rids?.service)
    } else if (rtype === 'rds_instance') {
      resourceNode = findNode(rids?.db_instance, nodes)
    } else if (rtype === 'elasticache') {
      resourceNode = findNode(rids?.replication_group, nodes)
    } else if (rtype === 'sqs_queue') {
      resourceNode = nodes.find(n => n.data.resourceType === 'sqs_queue' &&
        n.data.label === rids?.queue)
    } else if (rtype === 'load_balancer') {
      resourceNode = nodes.find(n => n.data.resourceType === 'alb' &&
        n.data.metadata.some((m: any) => m.key === 'DNS' && m.value.includes(rids?.load_balancer ?? '___')))
    }

    if (resourceNode) edge(alarmNode.id, resourceNode.id, 'observability', `monitors ${alarm.metric ?? ''}`, false)

    // Alarm → SNS action
    for (const act of (alarm.alarm_actions ?? [])) {
      if ((act as any).type !== 'sns_topic') continue
      const topicName = ((act as any).arn as string).split(':').pop() ?? ''
      const snsNode = nodes.find(n => n.data.resourceType === 'sns_topic' && n.data.label === topicName)
      if (snsNode) edge(alarmNode.id, snsNode.id, 'observability', 'notifies', false)
    }
  }

  // ── ENCRYPTION: resource → KMS key ────────────────────────────────────────
  for (const [keyId, usage] of Object.entries(snap.kmsUsage ?? {})) {
    const kmsNode = findNode(`kms-${keyId}`, nodes)
    if (!kmsNode) continue
    for (const res of (usage.resources ?? [])) {
      let resourceNode: ResourceNode | undefined
      if (res.resource_type === 'rds_instance')   resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'rds_cluster')    resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 's3_bucket')       resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'elasticache')     resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'secret')          resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'efs')             resourceNode = findNode(res.resource_id, nodes)
      if (!resourceNode) continue
      edge(resourceNode.id, kmsNode.id, 'encryption', `encrypted with ${usage.alias}`, false)
    }
  }

  // ── DNS: ECS service → Cloud Map namespace (service discovery) ────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const svcNode = findNode(svcArn, nodes)
    if (!svcNode) continue
    for (const cm of (svc.cloud_map ?? [])) {
      const nsNode = findNode(`cm-${cm.namespace_id}`, nodes)
      if (nsNode) edge(svcNode.id, nsNode.id, 'dns', `registered as ${cm.service_name}`, false)
    }
  }

  // ── LOGGING: ECS service container → log group ────────────────────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const svcNode = findNode(svcArn, nodes)
    if (!svcNode) continue
    for (const container of svc.containers) {
      if (!container.log_group) continue
      const lgNode = findNode(`lg-${container.log_group}`, nodes)
      if (lgNode) edge(svcNode.id, lgNode.id, 'logging', `${container.name} → CloudWatch`, false)
    }
  }

  // ── LOGGING: Lambda → log group ───────────────────────────────────────────
  for (const fn of snap.lambdaFunctions ?? []) {
    const fnNode = findNode(fn.FunctionArn, nodes)
    const lgPath = `/aws/lambda/${fn.FunctionName}`
    const lgNode = findNode(`lg-${lgPath}`, nodes)
    if (fnNode && lgNode) edge(fnNode.id, lgNode.id, 'logging', 'logs to CloudWatch', false)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SECOND PASS: build neighborIds, relationships, AI briefs
  // ═══════════════════════════════════════════════════════════════════════════

  const edgesByNode = new Map<string, RelationshipEdge[]>()
  for (const e of edges) {
    for (const id of [e.source, e.target]) {
      const arr = edgesByNode.get(id) ?? []
      arr.push(e)
      edgesByNode.set(id, arr)
    }
  }
  const nodeById = new Map(nodes.map(n => [n.id, n]))

  for (const node of nodes) {
    const adj = edgesByNode.get(node.id) ?? []
    node.data.neighborIds = [...new Set(adj.flatMap(e =>
      [e.source, e.target].filter(id => id !== node.id)))]

    node.data.relationships = adj.map(e => {
      const isOut  = e.source === node.id
      const other  = nodeById.get(isOut ? e.target : e.source)
      return {
        type:        e.data!.relationship,
        direction:   isOut ? 'outbound' : 'inbound',
        targetLabel: other?.data.label ?? '',
        targetId:    isOut ? e.target : e.source,
        description: e.data!.description,
      } as RelationshipSummary
    })

    node.data.aibrief = generateAIBrief(
      [..._nodeMap.entries()].find(([, v]) => v === node.id)?.[0] ?? node.id,
      node.data, snap)
  }

  return { nodes, edges }
}
