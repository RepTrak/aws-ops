import type { Node, Edge } from '@xyflow/react'

// ─── Node categories ────────────────────────────────────────────────────────

export type ResourceCategory =
  | 'compute'    // ECS service, Lambda, EC2
  | 'network'    // VPC, ALB, subnet, SG, API Gateway
  | 'data'       // RDS, DynamoDB, ElastiCache, OpenSearch, EFS, S3
  | 'messaging'  // SQS, SNS, EventBridge, Kinesis, Firehose, MSK
  | 'security'   // IAM role, Secrets Manager, KMS
  | 'cicd'       // CodePipeline, CodeBuild, CodeDeploy, ECR
  | 'observability' // CloudWatch alarm, log group

export type ResourceType =
  | 'ecs_service' | 'lambda' | 'ec2_instance' | 'eks_cluster'
  | 'alb' | 'api_gateway_rest' | 'api_gateway_http' | 'cloudfront'
  | 'rds_instance' | 'rds_cluster' | 'redshift_cluster' | 'redshift_serverless'
  | 'dynamodb_table' | 'elasticache' | 'memorydb' | 'opensearch' | 'docdb_cluster'
  | 'efs' | 's3_bucket'
  | 'sqs_queue' | 'sns_topic' | 'eventbridge_bus' | 'eventbridge_rule' | 'kinesis_stream'
  | 'firehose_stream' | 'msk_cluster' | 'stepfunctions'
  | 'iam_role' | 'secret' | 'kms_key' | 'acm_cert' | 'ssm_parameter'
  | 'wafv2_webacl' | 'guardduty_detector'
  | 'codepipeline' | 'codebuild' | 'ecr_repo' | 'cognito_pool'
  | 'cw_alarm' | 'log_group' | 'cloud_map_namespace'
  | 'vpc' | 'subnet' | 'security_group' | 'nat_gateway' | 'vpc_endpoint'
  | 'cidr_block'

// ─── Edge relationship types ─────────────────────────────────────────────────

export type EdgeRelationship =
  | 'network'       // SG rules, subnet placement — resource can reach resource
  | 'dataflow'      // service→DB, Lambda←SQS, Firehose→S3
  | 'iam'           // assumes role, role can access resource
  | 'deployment'    // pipeline→service, ALB→ECS
  | 'observability' // alarm→monitored resource, alarm→SNS action
  | 'auth'          // API Gateway→Cognito, ALB→WAF
  | 'encryption'    // resource uses KMS key for data-at-rest encryption
  | 'dns'           // Route53 / Cloud Map service discovery registration
  | 'logging'       // sends logs to CloudWatch log group or S3

// ─── Node data ───────────────────────────────────────────────────────────────

export interface ResourceNodeData extends Record<string, unknown> {
  resourceType: ResourceType
  category: ResourceCategory
  label: string
  sublabel?: string   // secondary label (cluster name, engine, etc.)
  status?: 'running' | 'stopped' | 'error' | 'warning' | 'unknown'
  neighborIds: string[] // all adjacent node IDs (used by detail panel + AI brief)
  raw: Record<string, unknown> // raw data for detail panel
  aibrief: string     // pre-generated AI brief text
  // Diff mode — set when comparing two snapshots
  diffStatus?:  'added' | 'modified'
  diffChanges?: string[]
  metadata: { key: string; value: string }[] // structured key-value for detail
  relationships: RelationshipSummary[] // human-readable relationship list
}

export interface RelationshipSummary {
  type: EdgeRelationship
  direction: 'outbound' | 'inbound'
  targetLabel: string
  targetId: string
  description: string
}

// ─── React Flow node/edge types ──────────────────────────────────────────────

export type ResourceNode = Node<ResourceNodeData, 'resource'>

export interface RelationshipEdgeData extends Record<string, unknown> {
  relationship: EdgeRelationship
  description: string
  port?: string
  animated?: boolean
}

export type RelationshipEdge = Edge<RelationshipEdgeData>

// ─── Filter state ─────────────────────────────────────────────────────────────

export interface FilterState {
  network: boolean
  dataflow: boolean
  iam: boolean
  deployment: boolean
  observability: boolean
  auth: boolean
  encryption: boolean
  dns: boolean
  logging: boolean
}

export const DEFAULT_FILTERS: FilterState = {
  network: false, dataflow: false, iam: false,
  deployment: false, observability: false, auth: false,
  encryption: false, dns: false, logging: false,
}
