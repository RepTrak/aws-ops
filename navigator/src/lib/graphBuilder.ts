import { MarkerType } from '@xyflow/react'
import type { SnapshotData } from '@/types/snapshot'
import type {
  ResourceNode, RelationshipEdge, ResourceType, ResourceCategory,
  RelationshipSummary, EdgeRelationship,
} from '@/types/graph'
import { RESOURCE_CATEGORY, RESOURCE_ICON, EDGE_COLORS } from '@/lib/colors'
import { generateAIBrief } from '@/lib/aibrief'

// ─── Helpers ──────────────────────────────────────────────────────────────────

// Secrets Manager valueFrom ARNs can have a trailing :JSON_KEY:: suffix beyond
// the standard 7-segment ARN. Strip it so the ref matches the plain secret ARN.
function baseSecretArn(ref: string): string {
  const parts = ref.split(':')
  return parts.length > 7 ? parts.slice(0, 7).join(':') : ref
}

// Extract S3 bucket name from a CloudFront origin domain name.
// Handles: bucket.s3.amazonaws.com, bucket.s3.region.amazonaws.com,
//          bucket.s3-website-region.amazonaws.com
function s3BucketFromOriginDomain(domain: string): string {
  const m = domain.match(/^([^.]+)\.s3[\-.]/)
  return m ? m[1] : ''
}

// Normalise an ALB DNS name for matching: strip dualstack. prefix and trailing dot.
function normaliseAlbDns(dns: string): string {
  return dns.replace(/^dualstack\./i, '').replace(/\.$/, '').toLowerCase()
}

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
    data: { relationship: rel, description, port, animated: false },
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

  // ── RDS clusters (Aurora) + DocumentDB clusters ───────────────────────────
  for (const cl of snap.rdsClusters ?? []) {
    const isDocDb = cl.Engine === 'docdb'
    const rtype = isDocDb ? 'docdb_cluster' : 'rds_cluster'
    add(mkNode(cl.DBClusterIdentifier, rtype, cl.DBClusterIdentifier, cl.Engine, [
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
  for (const role of snap.iamRoles ?? []) {
    const access = snap.iamRoleResourceAccess?.[role.RoleName]
    if (!access) continue
    // Skip roles with no analyzable permissions and no unanalyzed managed policies
    if (!Object.keys(access.service_access ?? {}).length &&
        !(access.unanalyzed_managed_policies ?? []).length) continue
    add(mkNode(`role-${role.RoleName}`, 'iam_role', role.RoleName, 'IAM Role', [
      { key: 'ARN', value: role.Arn }, { key: 'Name', value: role.RoleName },
    ], role as unknown as Record<string, unknown>, 'running', false))
  }

  // ── Secrets (hidden — shown when parent expanded or via search) ───────────
  // secretConsumers keys are valueFrom ARNs which may have a :JSON_KEY:: suffix
  const referencedSecrets = new Set(
    Object.keys(snap.secretConsumers ?? {}).map(baseSecretArn)
  )
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

  // ── EKS clusters (visible) ────────────────────────────────────────────────
  for (const rec of snap.eksClusterDetails ?? []) {
    const cl = rec.data?.cluster
    if (!cl) continue
    const vpc = cl.resourcesVpcConfig?.vpcId ?? ''
    add(mkNode(cl.arn, 'eks_cluster', cl.name, `EKS v${cl.version}`, [
      { key: 'ARN', value: cl.arn },
      { key: 'Name', value: cl.name },
      { key: 'Version', value: cl.version },
      { key: 'Status', value: cl.status },
      { key: 'VPC', value: vpc },
      { key: 'Endpoint', value: cl.endpoint ?? '' },
      { key: 'Role', value: cl.roleArn?.split('/').pop() ?? '' },
    ], cl as unknown as Record<string, unknown>,
    cl.status === 'ACTIVE' ? 'running' : 'warning', true))
  }

  // ── WAFv2 WebACLs (hidden — revealed by auth expand) ─────────────────────
  for (const rec of [...(snap.wafv2RegionalDetails ?? []), ...(snap.wafv2CfDetails ?? [])]) {
    const acl = rec.data?.WebACL
    if (!acl) continue
    add(mkNode(acl.ARN, 'wafv2_webacl', acl.Name, 'WAFv2', [
      { key: 'ARN', value: acl.ARN },
      { key: 'Name', value: acl.Name },
      { key: 'Description', value: acl.Description ?? '' },
    ], acl as unknown as Record<string, unknown>, 'running', false))
  }

  // ── GuardDuty detectors (hidden) ──────────────────────────────────────────
  for (const rec of snap.guarddutyDetails ?? []) {
    const status = rec.data?.Status ?? 'UNKNOWN'
    add(mkNode(`gd-${rec.detector_id}`, 'guardduty_detector', 'GuardDuty', rec.detector_id.slice(0, 8), [
      { key: 'Detector ID', value: rec.detector_id },
      { key: 'Status', value: status },
      { key: 'Frequency', value: rec.data?.FindingPublishingFrequency ?? '' },
    ], rec as unknown as Record<string, unknown>,
    status === 'ENABLED' ? 'running' : 'warning', false))
  }

  // ── VPCs (hidden — revealed by network expand) ────────────────────────────
  for (const vpc of snap.vpcs ?? []) {
    const name = vpc.Tags?.find(t => t.Key === 'Name')?.Value ?? vpc.VpcId
    add(mkNode(`vpc-${vpc.VpcId}`, 'vpc', name, vpc.CidrBlock, [
      { key: 'VPC ID', value: vpc.VpcId },
      { key: 'CIDR', value: vpc.CidrBlock },
      { key: 'State', value: vpc.State },
    ], vpc as unknown as Record<string, unknown>,
    vpc.State === 'available' ? 'running' : 'warning', false))
  }

  // ── EventBridge buses (hidden — derived from rules data) ─────────────────
  const seenBuses = new Set<string>()
  for (const rec of snap.eventbridgeRules ?? []) {
    if (!rec.event_bus_name || seenBuses.has(rec.event_bus_name)) continue
    seenBuses.add(rec.event_bus_name)
    add(mkNode(`eb-bus-${rec.event_bus_name}`, 'eventbridge_bus', rec.event_bus_name, 'EventBridge Bus', [
      { key: 'Bus', value: rec.event_bus_name },
    ], { bus: rec.event_bus_name }, 'running', false))
  }

  // ── MSK clusters (hidden) ─────────────────────────────────────────────────
  for (const cl of snap.mskClusters ?? []) {
    add(mkNode(cl.ClusterArn, 'msk_cluster', cl.ClusterName, cl.ClusterType ?? 'MSK', [
      { key: 'ARN', value: cl.ClusterArn },
      { key: 'Name', value: cl.ClusterName },
      { key: 'State', value: cl.State },
    ], cl as unknown as Record<string, unknown>,
    cl.State === 'ACTIVE' ? 'running' : 'warning', false))
  }

  // ── MemoryDB clusters (hidden) ────────────────────────────────────────────
  for (const cl of snap.memorydbClusters ?? []) {
    add(mkNode(`memdb-${cl.Name}`, 'memorydb', cl.Name, cl.NodeType, [
      { key: 'Name', value: cl.Name },
      { key: 'Node Type', value: cl.NodeType },
      { key: 'Status', value: cl.Status },
      { key: 'Engine', value: cl.EngineVersion ?? '' },
    ], cl as unknown as Record<string, unknown>,
    cl.Status === 'available' ? 'running' : 'warning', false))
  }

  // ── EC2 instances (hidden) ────────────────────────────────────────────────
  for (const res of (snap.rdsInstances ? [] : [])) { void res } // placeholder — no ECS EC2 data

  // ── CloudFront distributions (visible) ───────────────────────────────────
  for (const dist of snap.cloudfrontDistributions ?? []) {
    const aliases = (dist.Aliases?.Items ?? []).join(', ')
    const label = (dist.Aliases?.Items ?? [])[0] ?? dist.DomainName
    add(mkNode(dist.ARN, 'cloudfront', label, dist.DomainName, [
      { key: 'ARN', value: dist.ARN },
      { key: 'ID', value: dist.Id },
      { key: 'Domain', value: dist.DomainName },
      { key: 'Aliases', value: aliases },
      { key: 'Status', value: dist.Status },
    ], dist as unknown as Record<string, unknown>,
    dist.Status === 'Deployed' ? 'running' : 'warning', true))
  }

  // ── EFS file systems (hidden) ─────────────────────────────────────────────
  for (const fs of snap.efsFileSystems ?? []) {
    const name = fs.Name || fs.FileSystemId
    add(mkNode(fs.FileSystemId, 'efs', name, 'EFS', [
      { key: 'File System ID', value: fs.FileSystemId },
      { key: 'ARN', value: fs.FileSystemArn },
      { key: 'State', value: fs.LifeCycleState },
      { key: 'Encrypted', value: fs.Encrypted ? 'Yes' : 'No' },
    ], fs as unknown as Record<string, unknown>,
    fs.LifeCycleState === 'available' ? 'running' : 'warning', false))
  }

  // ── NAT gateways (hidden) ─────────────────────────────────────────────────
  for (const [ngwId, ngw] of Object.entries(snap.natGatewayEips ?? {})) {
    const publicIp = ngw.eips[0]?.public_ip ?? ''
    add(mkNode(`ngw-${ngwId}`, 'nat_gateway', ngwId.split('-').pop() ?? ngwId, 'NAT Gateway', [
      { key: 'ID', value: ngwId },
      { key: 'Public IP', value: publicIp },
      { key: 'Subnet', value: ngw.subnet_id },
      { key: 'VPC', value: ngw.vpc_id },
      { key: 'Type', value: ngw.connectivity_type },
    ], ngw as unknown as Record<string, unknown>,
    ngw.state === 'available' ? 'running' : 'warning', false))
  }

  // ── VPC endpoints (hidden) ────────────────────────────────────────────────
  for (const [epId, ep] of Object.entries(snap.vpcEndpointRoutes ?? {})) {
    const svcShort = ep.service.split('.').pop() ?? ep.service
    add(mkNode(`ep-${epId}`, 'vpc_endpoint', svcShort, `${ep.type} endpoint`, [
      { key: 'Endpoint ID', value: epId },
      { key: 'Service', value: ep.service },
      { key: 'Type', value: ep.type },
      { key: 'VPC', value: ep.vpc_id },
      { key: 'State', value: ep.state },
    ], ep as unknown as Record<string, unknown>,
    ep.state === 'available' ? 'running' : 'warning', false))
  }

  // ── Step Functions state machines (hidden) ───────────────────────────────
  for (const [smArn, sm] of Object.entries(snap.sfResourceRefs ?? {})) {
    add(mkNode(smArn, 'stepfunctions', sm.name, sm.type ?? 'EXPRESS', [
      { key: 'ARN', value: smArn },
      { key: 'Name', value: sm.name },
      { key: 'Type', value: sm.type ?? '' },
      { key: 'Role', value: sm.role_arn?.split('/').pop() ?? '' },
    ], sm as unknown as Record<string, unknown>, 'running', false))
  }

  // ── CodePipeline pipelines (hidden) ───────────────────────────────────────
  for (const [name, pl] of Object.entries(snap.pipelineChains ?? {})) {
    add(mkNode(`pipeline-${name}`, 'codepipeline', name, 'CodePipeline', [
      { key: 'Name', value: name },
      { key: 'Artifact Bucket', value: pl.artifact_store_bucket },
    ], pl as unknown as Record<string, unknown>, 'running', false))
  }

  // ── CodeBuild projects (hidden) ───────────────────────────────────────────
  for (const project of snap.codebuildProjects ?? []) {
    add(mkNode(`codebuild-${project}`, 'codebuild', project, 'CodeBuild', [
      { key: 'Project', value: project },
    ], { projectName: project }, 'running', false))
  }

  // ── ECR repositories (hidden — revealed by deployment expand) ────────────
  for (const repo of snap.ecrRepos ?? []) {
    add(mkNode(repo.repositoryArn, 'ecr_repo', repo.repositoryName, 'ECR', [
      { key: 'ARN', value: repo.repositoryArn },
      { key: 'Name', value: repo.repositoryName },
      { key: 'URI', value: repo.repositoryUri },
    ], repo as unknown as Record<string, unknown>, 'running', false))
  }

  // ── ACM certificates (hidden — revealed by encryption expand) ─────────────
  for (const rec of snap.acmCertDetails ?? []) {
    const cert = rec.data?.Certificate
    if (!cert) continue
    // Use the ARN from inside the Certificate object as the canonical key;
    // fall back to the top-level certificate_arn field.
    const certArn = cert.CertificateArn || rec.certificate_arn
    if (!certArn) continue
    const domain = cert.DomainName ?? certArn
    add(mkNode(certArn, 'acm_cert', domain, 'ACM Certificate', [
      { key: 'ARN', value: certArn },
      { key: 'Domain', value: cert.DomainName ?? '' },
      { key: 'Status', value: cert.Status ?? '' },
      { key: 'SANs', value: (cert.SubjectAlternativeNames ?? []).join(', ') },
    ], cert as unknown as Record<string, unknown>, 'running', false))
  }

  // ── EventBridge rules (hidden — revealed by dataflow expand) ─────────────
  for (const rec of snap.eventbridgeRules ?? []) {
    for (const rule of (rec.data?.Rules ?? [])) {
      if (rule.State === 'DISABLED') continue
      const ruleKey = `ebr-${rec.event_bus_name}/${rule.Name}`
      add(mkNode(ruleKey, 'eventbridge_rule', rule.Name, rec.event_bus_name, [
        { key: 'ARN', value: rule.Arn },
        { key: 'Name', value: rule.Name },
        { key: 'Bus', value: rec.event_bus_name },
        ...(rule.ScheduleExpression ? [{ key: 'Schedule', value: rule.ScheduleExpression }] : []),
      ], rule as unknown as Record<string, unknown>, 'running', false))
    }
  }

  // ── SSM parameters (hidden — revealed via paramConsumers) ─────────────────
  for (const paramRef of Object.keys(snap.paramConsumers ?? {})) {
    const name = paramRef.split('/').pop() ?? paramRef
    add(mkNode(`ssm-${paramRef}`, 'ssm_parameter', name, paramRef, [
      { key: 'Path', value: paramRef },
    ], { path: paramRef }, 'running', false))
  }

  // ── Subnets (hidden — revealed by network expand) ─────────────────────────
  // Only create nodes for subnets actually used by services/lambdas
  const usedSubnetIds = new Set<string>()
  for (const svc of Object.values(snap.serviceTopology ?? {})) {
    svc.subnets.forEach(s => usedSubnetIds.add(s))
  }
  for (const fn of snap.lambdaFunctions ?? []) {
    for (const s of (fn.VpcConfig?.SubnetIds ?? [])) usedSubnetIds.add(s)
  }
  for (const [snId, sn] of Object.entries(snap.subnetClassification ?? {})) {
    if (!usedSubnetIds.has(snId)) continue
    const label = sn.name || snId
    const tier = sn.is_public ? 'public' : 'private'
    add(mkNode(`subnet-${snId}`, 'subnet', label, `${tier} · ${sn.az}`, [
      { key: 'Subnet ID', value: snId },
      { key: 'VPC', value: sn.vpc_id },
      { key: 'AZ', value: sn.az },
      { key: 'CIDR', value: sn.cidr },
      { key: 'Tier', value: tier },
    ], sn as unknown as Record<string, unknown>, 'running', false))
  }

  // ── CIDR pseudo-nodes (hidden — revealed by network expand) ───────────────
  // Only for private/non-internet CIDRs that appear as ingress sources
  const seenCidrs = new Set<string>()
  for (const sgEdge of (snap.sgConnectivity?.edges ?? [])) {
    const cidr = sgEdge.from_cidr
    if (!cidr || cidr === '0.0.0.0/0' || cidr === '::/0') continue
    if (seenCidrs.has(cidr)) continue
    seenCidrs.add(cidr)
    add(mkNode(`cidr-${cidr}`, 'cidr_block', cidr, 'CIDR', [
      { key: 'CIDR', value: cidr },
    ], { cidr }, 'running', false))
  }

  // ── Cloud Map namespaces (hidden — revealed by DNS expand) ───────────────
  for (const ns of snap.cloudMapNamespaces ?? []) {
    add(mkNode(`cm-${ns.Id}`, 'cloud_map_namespace', ns.Name, `Cloud Map (${ns.Type})`, [
      { key: 'ID', value: ns.Id },
      { key: 'Name', value: ns.Name },
      { key: 'Type', value: ns.Type },
    ], ns as unknown as Record<string, unknown>, 'running', false))
  }

  // ── Enrich ALB/CloudFront nodes with Route53 DNS aliases pointing to them ─
  // Build lookup: normalised DNS target → list of hostnames pointing to it
  const dnsAliases: Record<string, string[]> = {}
  for (const zoneRec of snap.route53RecordSets ?? []) {
    for (const r of (zoneRec.data?.ResourceRecordSets ?? [])) {
      if (r.Type !== 'A' && r.Type !== 'AAAA') continue
      const target = normaliseAlbDns(r.AliasTarget?.DNSName ?? '')
      if (!target) continue
      dnsAliases[target] = dnsAliases[target] ?? []
      dnsAliases[target].push(r.Name.replace(/\.$/, ''))
    }
  }
  // Enrich ALB nodes
  for (const [lbArn, alb] of Object.entries(snap.albToService ?? {})) {
    const lbNode = findNode(lbArn, nodes)
    if (!lbNode) continue
    const normDns = normaliseAlbDns(alb.dns_name)
    const aliases = Object.entries(dnsAliases)
      .filter(([target]) => target.includes(normDns) || normDns.includes(target))
      .flatMap(([, names]) => names)
    if (aliases.length) {
      ;(lbNode.data.metadata as {key:string;value:string}[]).push(
        { key: 'DNS Aliases', value: aliases.join(', ') }
      )
    }
  }
  // Enrich CloudFront nodes with Route53 aliases pointing to their domain
  for (const dist of snap.cloudfrontDistributions ?? []) {
    const cfNode = findNode(dist.ARN, nodes)
    if (!cfNode) continue
    const normCfDomain = dist.DomainName.toLowerCase()
    const aliases = Object.entries(dnsAliases)
      .filter(([target]) => target.includes(normCfDomain))
      .flatMap(([, names]) => names)
    if (aliases.length) {
      ;(cfNode.data.metadata as {key:string;value:string}[]).push(
        { key: 'DNS Aliases', value: aliases.join(', ') }
      )
    }
  }

  // ── Enrich ECS service nodes with running task IPs from taskEniMap ────────
  const taskIpsBySvc: Record<string, string[]> = {}
  for (const [, task] of Object.entries(snap.taskEniMap ?? {})) {
    // task_definition_arn → match to a service by task def prefix
    const tdBase = task.task_definition_arn.split(':').slice(0, -1).join(':')
    for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
      if (svc.task_definition_arn.startsWith(tdBase) || svc.task_definition_arn === task.task_definition_arn) {
        taskIpsBySvc[svcArn] = taskIpsBySvc[svcArn] ?? []
        if (task.private_ip) taskIpsBySvc[svcArn].push(task.private_ip)
      }
    }
  }
  for (const [svcArn, ips] of Object.entries(taskIpsBySvc)) {
    const svcNode = findNode(svcArn, nodes)
    if (svcNode && ips.length > 0) {
      ;(svcNode.data.metadata as {key:string;value:string}[]).push(
        { key: 'Running Task IPs', value: [...new Set(ips)].join(', ') }
      )
    }
  }

  // All nodes start hidden — the canvas is built entirely through user
  // interaction (search-to-pin and connection expand/collapse).
  for (const n of nodes) { n.hidden = true }

  // ═══════════════════════════════════════════════════════════════════════════
  // EDGES
  // ═══════════════════════════════════════════════════════════════════════════

  // ── DATAFLOW: secret consumers (service → secret) ────────────────────────
  for (const [secretRef, consumers] of Object.entries(snap.secretConsumers ?? {})) {
    const baseArn = baseSecretArn(secretRef)
    const secretNode = findNode(baseArn, nodes)
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

  // ── DATAFLOW: SQS / Kinesis → Lambda (event source mappings) ────────────
  for (const esm of snap.lambdaEsms ?? []) {
    if (esm.State === 'Disabled') continue
    const fnNode = findNode(esm.FunctionArn, nodes)
    if (!fnNode) continue
    if (esm.EventSourceArn.includes(':sqs:')) {
      const queueName = esm.EventSourceArn.split(':').pop() ?? ''
      const sqsNode = nodes.find(n => n.data.resourceType === 'sqs_queue' && n.data.label === queueName)
      if (sqsNode) edge(sqsNode.id, fnNode.id, 'dataflow', 'triggers Lambda')
    } else if (esm.EventSourceArn.includes(':kinesis:')) {
      const streamName = esm.EventSourceArn.split('/').pop() ?? ''
      const kNode = nodes.find(n => n.data.resourceType === 'kinesis_stream' && n.data.label === streamName)
      if (kNode) edge(kNode.id, fnNode.id, 'dataflow', 'stream → Lambda')
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

  // ── DEPLOYMENT: ALB → EKS cluster (K8s ingress controller pattern) ───────
  // The K8s LB Controller creates ALBs whose SGs are named with a "k8s-" prefix.
  // Match strategy: ALB has k8s- SG AND that SG is in the same VPC as the cluster
  // (checked via subnetClassification of SG member resources).
  const sgNames = snap.sgConnectivity?.sg_names ?? {}

  // Build vpc_id → EKS cluster ARN map
  const vpcToEksClusters = new Map<string, string[]>()
  for (const rec of snap.eksClusterDetails ?? []) {
    const cl = rec.data?.cluster
    if (!cl) continue
    const vpc = cl.resourcesVpcConfig?.vpcId ?? ''
    if (vpc) {
      const arr = vpcToEksClusters.get(vpc) ?? []
      arr.push(cl.arn)
      vpcToEksClusters.set(vpc, arr)
    }
  }

  for (const rec of snap.eksClusterDetails ?? []) {
    const cl = rec.data?.cluster
    if (!cl) continue
    const eksNode = findNode(cl.arn, nodes)
    if (!eksNode) continue

    // EKS cluster → VPC network edge
    const vpcNode = findNode(`vpc-${cl.resourcesVpcConfig?.vpcId}`, nodes)
    if (vpcNode) edge(eksNode.id, vpcNode.id, 'network', 'cluster in VPC')

    // EKS cluster → IAM service role
    const roleName = cl.roleArn?.split('/').pop() ?? ''
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (roleNode) edge(eksNode.id, roleNode.id, 'iam', 'cluster service role')
  }

  // Build direct ARN → VPC map from the raw load balancer list
  const lbVpcMap = new Map<string, string>()
  for (const lb of snap.loadBalancers ?? []) {
    if (lb.VpcId) lbVpcMap.set(lb.LoadBalancerArn, lb.VpcId)
  }

  // For each ALB: if it has k8s- SGs and is in the same VPC as a cluster → link
  for (const [lbArn] of Object.entries(snap.albToService ?? {})) {
    const lbNode = findNode(lbArn, nodes)
    if (!lbNode) continue
    // Find this ALB's SG IDs via sg_members
    const lbSgs = Object.entries(snap.sgMembers ?? {})
      .filter(([, members]) => members.some(m => m.resource_id === lbArn))
      .map(([sgId]) => sgId)
    // Only proceed if any SG has the k8s- prefix (K8s LB Controller pattern)
    if (!lbSgs.some(sg => (sgNames[sg] ?? '').toLowerCase().startsWith('k8s-'))) continue
    // Get the VPC directly from the LB raw data
    const albVpc = lbVpcMap.get(lbArn) ?? ''
    if (!albVpc) continue
    // Link to all EKS clusters in the same VPC
    for (const clArn of (vpcToEksClusters.get(albVpc) ?? [])) {
      const eksNode = findNode(clArn, nodes)
      if (eksNode) edge(lbNode.id, eksNode.id, 'deployment', 'K8s ingress → cluster')
    }
  }

  // ── AUTH: WAFv2 WebACL → protected ALB ───────────────────────────────────
  for (const rec of snap.wafv2RegionalResources ?? []) {
    const aclNode = findNode(rec.web_acl_arn, nodes)
    if (!aclNode) continue
    for (const resArn of (rec.data?.ResourceArns ?? [])) {
      const lbNode = findNode(resArn, nodes)
      if (lbNode) edge(aclNode.id, lbNode.id, 'auth', 'WAF protects')
    }
  }
  // CloudFront WAFv2: link via CloudFront distribution WebACLId
  for (const dist of snap.cloudfrontDistributions ?? []) {
    const wafId = (dist as any).WebACLId as string | undefined
    if (!wafId) continue
    const cfNode = findNode(dist.ARN, nodes)
    const aclNode = findNode(wafId, nodes)
    if (cfNode && aclNode) edge(aclNode.id, cfNode.id, 'auth', 'WAF protects')
  }

  // ── AUTH: API Gateway → Cognito / Lambda authorizer ───────────────────────
  for (const [, auth] of Object.entries(snap.apigwAuthChain ?? {})) {
    const apiNode = nodes.find(n =>
      (n.data.resourceType === 'api_gateway_http' || n.data.resourceType === 'api_gateway_rest') &&
      (n.data.metadata as {key:string;value:string}[]).some(m =>
        m.key === 'ID' && m.value === auth.api_id))
    if (!apiNode) continue
    if (auth.cognito_pool_id) {
      const cogNode = nodes.find(n => n.data.resourceType === 'cognito_pool' &&
        (n.data.metadata as {key:string;value:string}[]).some(m =>
          m.key === 'Pool ID' && m.value === auth.cognito_pool_id))
      if (cogNode) edge(apiNode.id, cogNode.id, 'auth', 'JWT auth via Cognito', false)
    }
    if (auth.type === 'REQUEST' && auth.authorizer_uri) {
      // URI format: arn:aws:apigateway:region:lambda:path/.../functions/LAMBDA_ARN/invocations
      const match = auth.authorizer_uri.match(/functions\/(arn:aws:lambda:[^/]+)\//)
      if (match) {
        const fnNode = findNode(match[1], nodes)
        if (fnNode) edge(apiNode.id, fnNode.id, 'auth', 'Lambda REQUEST authorizer', false)
      }
    }
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

  // ── IAM: Redshift cluster → attached IAM roles (for S3 COPY/UNLOAD) ────────
  for (const cl of snap.redshiftClusters ?? []) {
    const clNode = findNode(cl.ClusterIdentifier, nodes)
    if (!clNode) continue
    for (const r of (cl.IamRoles ?? [])) {
      if (r.ApplyStatus !== 'in-sync') continue
      const roleName = r.IamRoleArn.split('/').pop() ?? ''
      const roleNode = findNode(`role-${roleName}`, nodes)
      if (roleNode) edge(clNode.id, roleNode.id, 'iam', 'attached IAM role', false)
    }
  }

  // ── IAM: IAM role → S3 bucket (from service_access) ──────────────────────
  for (const [roleName, access] of Object.entries(snap.iamRoleResourceAccess ?? {})) {
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (!roleNode) continue
    for (const res of (access.service_access?.s3 ?? [])) {
      const match = res.match(/arn:aws:s3:::([^/*]+)/)  // skip wildcards
      if (!match) continue
      const s3Node = findNode(match[1], nodes)
      if (s3Node) edge(roleNode.id, s3Node.id, 'iam', 'can access', false)
    }
    for (const res of (access.service_access?.sqs ?? [])) {
      const queueName = res.split(':').pop() ?? ''
      if (!queueName || queueName.includes('*')) continue  // skip wildcards
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
    } else if (rtype === 'lambda_function') {
      resourceNode = nodes.find(n => n.data.resourceType === 'lambda' &&
        n.data.label === rids?.function)
    } else if (rtype === 'rds_cluster') {
      resourceNode = findNode(rids?.db_cluster, nodes)
    } else if (rtype === 'dynamodb_table') {
      resourceNode = findNode(rids?.table, nodes)
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
      if (res.resource_type === 'rds_instance')     resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'rds_cluster')      resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'docdb_cluster')    resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 's3_bucket')         resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'elasticache')       resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'secret')            resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'efs')               resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'dynamodb_table')    resourceNode = findNode(res.resource_id, nodes)
      if (res.resource_type === 'redshift_cluster')  resourceNode = findNode(res.resource_id, nodes)
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

  // ── DATAFLOW: CloudFront → S3 / ALB origins ──────────────────────────────
  for (const dist of snap.cloudfrontDistributions ?? []) {
    const cfNode = findNode(dist.ARN, nodes)
    if (!cfNode) continue
    for (const origin of (dist.Origins?.Items ?? [])) {
      const domain = origin.DomainName
      // S3 origin
      const bucket = s3BucketFromOriginDomain(domain)
      if (bucket) {
        const s3Node = findNode(bucket, nodes)
        if (s3Node) edge(cfNode.id, s3Node.id, 'dataflow', 'serves from S3')
        continue
      }
      // ALB origin
      if (domain.includes('.elb.')) {
        const normOrigin = normaliseAlbDns(domain)
        const lbNode = nodes.find(n => {
          if (n.data.resourceType !== 'alb') return false
          const dns = (n.data.metadata as {key:string;value:string}[])
            .find(m => m.key === 'DNS')?.value ?? ''
          return normaliseAlbDns(dns) === normOrigin
        })
        if (lbNode) edge(cfNode.id, lbNode.id, 'dataflow', 'routes to ALB')
      }
    }
    // ENCRYPTION: CloudFront → ACM certificate
    const certArn = dist.ViewerCertificate?.ACMCertificateArn
    if (certArn) {
      const certNode = findNode(certArn, nodes)
      if (certNode) edge(cfNode.id, certNode.id, 'encryption', 'TLS certificate')
    }
  }

  // ── DATAFLOW: ECS service → EFS volume ────────────────────────────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const svcNode = findNode(svcArn, nodes)
    if (!svcNode) continue
    for (const vol of (svc.efs_volumes ?? [])) {
      const efsNode = findNode(vol.file_system_id, nodes)
      if (efsNode) edge(svcNode.id, efsNode.id, 'dataflow', `mounts EFS: ${vol.volume_name}`)
    }
  }

  // ── NETWORK: NAT gateway → subnet ────────────────────────────────────────
  for (const [ngwId, ngw] of Object.entries(snap.natGatewayEips ?? {})) {
    const ngwNode = findNode(`ngw-${ngwId}`, nodes)
    if (!ngwNode) continue
    const snNode = findNode(`subnet-${ngw.subnet_id}`, nodes)
    if (snNode) edge(snNode.id, ngwNode.id, 'network', 'NAT gateway in subnet')
  }

  // ── NETWORK: VPC endpoint → subnets routed through it ────────────────────
  for (const [epId, ep] of Object.entries(snap.vpcEndpointRoutes ?? {})) {
    const epNode = findNode(`ep-${epId}`, nodes)
    if (!epNode) continue
    for (const snId of [...ep.subnets_routed_through, ...ep.subnet_ids]) {
      const snNode = findNode(`subnet-${snId}`, nodes)
      if (snNode) edge(epNode.id, snNode.id, 'network', `${ep.type} endpoint route`)
    }
    // Gateway S3/DynamoDB endpoints link to the service
    if (ep.service.endsWith('.s3')) {
      for (const b of snap.s3Buckets ?? []) {
        const bNode = findNode(b.Name, nodes)
        if (bNode) { edge(epNode.id, bNode.id, 'network', 'private S3 access'); break }
      }
    } else if (ep.service.endsWith('.dynamodb')) {
      for (const tbl of snap.dynamoTables ?? []) {
        const tblNode = findNode(tbl, nodes)
        if (tblNode) { edge(epNode.id, tblNode.id, 'network', 'private DynamoDB access'); break }
      }
    }
  }

  // ── DEPLOYMENT: Step Functions → Lambda / ECS task / SQS / SNS ──────────
  for (const [smArn, sm] of Object.entries(snap.sfResourceRefs ?? {})) {
    const smNode = findNode(smArn, nodes)
    if (!smNode) continue
    for (const ref of (sm.resource_refs ?? [])) {
      if (ref.resource_type === 'lambda' && ref.resource_arn) {
        const fnNode = findNode(ref.resource_arn, nodes)
        if (fnNode) edge(smNode.id, fnNode.id, 'deployment', `invokes: ${ref.state_name}`)
      } else if (ref.resource_type === 'ecs_task') {
        const svcNode = nodes.find(n => n.data.resourceType === 'ecs_service' &&
          (n.data.raw as any)?.task_definition_arn?.includes((ref as any).task_definition ?? '___'))
        if (svcNode) edge(smNode.id, svcNode.id, 'deployment', `runs ECS task: ${ref.state_name}`)
      } else if (ref.resource_type === 'sqs' && ref.queue_url) {
        const queueName = ref.queue_url.split('/').pop() ?? ''
        const sqsNode = nodes.find(n => n.data.resourceType === 'sqs_queue' && n.data.label === queueName)
        if (sqsNode) edge(smNode.id, sqsNode.id, 'dataflow', `sends to queue: ${ref.state_name}`)
      } else if (ref.resource_type === 'sns' && ref.topic_arn) {
        const topicName = ref.topic_arn.split(':').pop() ?? ''
        const snsNode = nodes.find(n => n.data.resourceType === 'sns_topic' && n.data.label === topicName)
        if (snsNode) edge(smNode.id, snsNode.id, 'dataflow', `publishes: ${ref.state_name}`)
      } else if (ref.resource_type === 'stepfunctions' && ref.state_machine_arn) {
        const childSm = findNode(ref.state_machine_arn, nodes)
        if (childSm) edge(smNode.id, childSm.id, 'deployment', `child state machine: ${ref.state_name}`)
      }
    }
  }

  // ── DEPLOYMENT: CodePipeline → ECS service / CodeBuild ───────────────────
  for (const [name, pl] of Object.entries(snap.pipelineChains ?? {})) {
    const plNode = findNode(`pipeline-${name}`, nodes)
    if (!plNode) continue
    for (const ref of (pl.resource_refs ?? [])) {
      if (ref.resource_type === 'ecs_service' && ref.service) {
        const svcNode = nodes.find(n => n.data.resourceType === 'ecs_service' && n.data.label === ref.service)
        if (svcNode) edge(plNode.id, svcNode.id, 'deployment', 'deploys to ECS')
      } else if (ref.resource_type === 'codebuild' && ref.project) {
        const cbNode = findNode(`codebuild-${ref.project}`, nodes)
        if (cbNode) edge(plNode.id, cbNode.id, 'deployment', 'builds with CodeBuild')
      }
    }
  }

  // ── DEPLOYMENT: ECS service / Lambda → ECR repo (image pull) ─────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const svcNode = findNode(svcArn, nodes)
    if (!svcNode) continue
    for (const container of svc.containers) {
      for (const repo of (snap.ecrRepos ?? [])) {
        if (container.image.startsWith(repo.repositoryUri)) {
          const repoNode = findNode(repo.repositoryArn, nodes)
          if (repoNode) edge(svcNode.id, repoNode.id, 'deployment', `pulls image: ${container.name}`)
          break
        }
      }
    }
  }
  for (const fn of snap.lambdaFunctions ?? []) {
    const fnNode = findNode(fn.FunctionArn, nodes)
    if (!fnNode) continue
    for (const repo of (snap.ecrRepos ?? [])) {
      if ((fn as any).Code?.ImageUri?.startsWith(repo.repositoryUri)) {
        const repoNode = findNode(repo.repositoryArn, nodes)
        if (repoNode) edge(fnNode.id, repoNode.id, 'deployment', 'pulls container image')
        break
      }
    }
  }

  // ── ENCRYPTION: ALB → ACM certificate (via listeners) ────────────────────
  for (const rec of snap.elbListeners ?? []) {
    const lbNode = findNode(rec.load_balancer_arn, nodes)
    if (!lbNode) continue
    for (const listener of (rec.data?.Listeners ?? [])) {
      for (const cert of (listener.Certificates ?? [])) {
        const certNode = findNode(cert.CertificateArn, nodes)
        if (certNode) edge(lbNode.id, certNode.id, 'encryption', `TLS on port ${listener.Port}`)
      }
    }
  }

  // ── DATAFLOW: EventBridge rule → Lambda / SQS / SNS / Step Functions ──────
  for (const rec of snap.eventbridgeTargets ?? []) {
    const ruleKey = `ebr-${rec.event_bus_name}/${rec.rule_name}`
    const ruleNode = findNode(ruleKey, nodes)
    if (!ruleNode) continue
    for (const target of (rec.data?.Targets ?? [])) {
      const arn = target.Arn
      if (arn.includes(':lambda:')) {
        const fnNode = findNode(arn, nodes)
        if (fnNode) edge(ruleNode.id, fnNode.id, 'dataflow', 'triggers Lambda')
      } else if (arn.includes(':sqs:')) {
        const queueName = arn.split(':').pop() ?? ''
        const sqsNode = nodes.find(n => n.data.resourceType === 'sqs_queue' && n.data.label === queueName)
        if (sqsNode) edge(ruleNode.id, sqsNode.id, 'dataflow', 'sends to queue')
      } else if (arn.includes(':sns:')) {
        const topicName = arn.split(':').pop() ?? ''
        const snsNode = nodes.find(n => n.data.resourceType === 'sns_topic' && n.data.label === topicName)
        if (snsNode) edge(ruleNode.id, snsNode.id, 'dataflow', 'publishes to topic')
      } else if (arn.includes(':states:')) {
        const smNode = findNode(arn, nodes)
        if (smNode) edge(ruleNode.id, smNode.id, 'dataflow', 'triggers state machine')
      }
    }
  }

  // ── DATAFLOW: ECS service → SSM parameter ────────────────────────────────
  for (const [paramRef, consumers] of Object.entries(snap.paramConsumers ?? {})) {
    const paramNode = findNode(`ssm-${paramRef}`, nodes)
    if (!paramNode) continue
    const families = [...new Set(consumers.map(c => c.task_definition.split(':')[0]))]
    for (const family of families) {
      const svcNode = nodes.find(n =>
        n.data.resourceType === 'ecs_service' &&
        (n.data.metadata as {key:string;value:string}[])
          .find(m => m.key === 'Task Definition')?.value.split(':')[0] === family)
      if (svcNode) edge(svcNode.id, paramNode.id, 'dataflow', 'reads SSM parameter')
    }
  }

  // ── NETWORK: subnet → VPC ────────────────────────────────────────────────
  for (const [snId, sn] of Object.entries(snap.subnetClassification ?? {})) {
    const snNode = findNode(`subnet-${snId}`, nodes)
    const vpcNode = findNode(`vpc-${sn.vpc_id}`, nodes)
    if (snNode && vpcNode) edge(snNode.id, vpcNode.id, 'network', 'subnet in VPC')
  }

  // ── DATAFLOW: EventBridge rule → bus (parent relationship) ───────────────
  for (const rec of snap.eventbridgeRules ?? []) {
    const busNode = findNode(`eb-bus-${rec.event_bus_name}`, nodes)
    if (!busNode) continue
    for (const rule of (rec.data?.Rules ?? [])) {
      if (rule.State === 'DISABLED') continue
      const ruleNode = findNode(`ebr-${rec.event_bus_name}/${rule.Name}`, nodes)
      if (ruleNode) edge(busNode.id, ruleNode.id, 'dataflow', 'bus routes rule')
    }
  }

  // ── NETWORK: ECS service / Lambda → subnet ────────────────────────────────
  for (const [svcArn, svc] of Object.entries(snap.serviceTopology ?? {})) {
    const svcNode = findNode(svcArn, nodes)
    if (!svcNode) continue
    for (const snId of svc.subnets) {
      const snNode = findNode(`subnet-${snId}`, nodes)
      if (snNode) edge(svcNode.id, snNode.id, 'network', 'runs in subnet')
    }
  }
  for (const fn of snap.lambdaFunctions ?? []) {
    const fnNode = findNode(fn.FunctionArn, nodes)
    if (!fnNode) continue
    for (const snId of (fn.VpcConfig?.SubnetIds ?? [])) {
      const snNode = findNode(`subnet-${snId}`, nodes)
      if (snNode) edge(fnNode.id, snNode.id, 'network', 'runs in subnet')
    }
  }

  // ── NETWORK: CIDR block → SG members ─────────────────────────────────────
  for (const sgEdge of (snap.sgConnectivity?.edges ?? [])) {
    const cidr = sgEdge.from_cidr
    if (!cidr || cidr === '0.0.0.0/0' || cidr === '::/0') continue
    const cidrNode = findNode(`cidr-${cidr}`, nodes)
    if (!cidrNode) continue
    const portLabel = sgEdge.from_port
      ? `${sgEdge.protocol}:${sgEdge.from_port}`
      : sgEdge.protocol === '-1' ? 'all' : sgEdge.protocol
    for (const member of (snap.sgMembers?.[sgEdge.to_sg] ?? [])) {
      const toNode = findNode(member.resource_id, nodes)
      if (toNode) edge(cidrNode.id, toNode.id, 'network', `ingress from ${cidr} (${portLabel})`, false, portLabel)
    }
  }

  // ── IAM: role trust → role (role chaining) ────────────────────────────────
  for (const [roleName, trust] of Object.entries(snap.iamRoleTrustAnalysis ?? {})) {
    const roleNode = findNode(`role-${roleName}`, nodes)
    if (!roleNode) continue
    for (const trustedRoleArn of (trust.trusted_roles ?? [])) {
      const trustedRoleName = trustedRoleArn.split('/').pop() ?? ''
      const trustedNode = findNode(`role-${trustedRoleName}`, nodes)
      if (trustedNode) edge(trustedNode.id, roleNode.id, 'iam', 'can assume role')
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
