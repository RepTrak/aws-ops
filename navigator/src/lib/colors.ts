import type { ResourceType, ResourceCategory, EdgeRelationship } from '@/types/graph'

// ─── Category colors (border + header) ───────────────────────────────────────

export const CATEGORY_COLORS: Record<ResourceCategory, { border: string; bg: string; text: string; icon: string }> = {
  compute:      { border: '#3B82F6', bg: '#EFF6FF', text: '#1D4ED8', icon: '⚙️' },
  network:      { border: '#64748B', bg: '#F8FAFC', text: '#334155', icon: '🌐' },
  data:         { border: '#10B981', bg: '#ECFDF5', text: '#047857', icon: '🗄️' },
  messaging:    { border: '#8B5CF6', bg: '#F5F3FF', text: '#6D28D9', icon: '📨' },
  security:     { border: '#EF4444', bg: '#FEF2F2', text: '#B91C1C', icon: '🔐' },
  cicd:         { border: '#EC4899', bg: '#FDF2F8', text: '#BE185D', icon: '🚀' },
  observability:{ border: '#F59E0B', bg: '#FFFBEB', text: '#B45309', icon: '📊' },
}

// ─── Resource type → category mapping ────────────────────────────────────────

export const RESOURCE_CATEGORY: Record<ResourceType, ResourceCategory> = {
  ecs_service: 'compute', lambda: 'compute', ec2_instance: 'compute', eks_cluster: 'compute',
  alb: 'network', api_gateway_rest: 'network', api_gateway_http: 'network', cloudfront: 'network',
  vpc: 'network', subnet: 'network', security_group: 'network', nat_gateway: 'network', vpc_endpoint: 'network',
  cloud_map_namespace: 'network',
  rds_instance: 'data', rds_cluster: 'data', redshift_cluster: 'data', redshift_serverless: 'data',
  dynamodb_table: 'data', elasticache: 'data', memorydb: 'data', opensearch: 'data',
  docdb_cluster: 'data', efs: 'data', s3_bucket: 'data',
  sqs_queue: 'messaging', sns_topic: 'messaging', eventbridge_bus: 'messaging', eventbridge_rule: 'messaging',
  kinesis_stream: 'messaging', firehose_stream: 'messaging', msk_cluster: 'messaging', stepfunctions: 'messaging',
  iam_role: 'security', secret: 'security', kms_key: 'security', acm_cert: 'security', ssm_parameter: 'security',
  wafv2_webacl: 'security', guardduty_detector: 'observability',
  codepipeline: 'cicd', codebuild: 'cicd', ecr_repo: 'cicd', cognito_pool: 'cicd',
  cw_alarm: 'observability', log_group: 'observability',
  cidr_block: 'network',
}

// ─── Resource type icons ──────────────────────────────────────────────────────

export const RESOURCE_ICON: Record<ResourceType, string> = {
  ecs_service: '🐳', lambda: 'λ', ec2_instance: '🖥️', eks_cluster: '☸️',
  alb: '⚖️', api_gateway_rest: '🔌', api_gateway_http: '🔌', cloudfront: '🌍',
  vpc: '🏗️', subnet: '🔲', security_group: '🛡️', nat_gateway: '🔄', vpc_endpoint: '🔗',
  cloud_map_namespace: '🔭',
  rds_instance: '🐘', rds_cluster: '🐘', redshift_cluster: '📊', redshift_serverless: '📊',
  dynamodb_table: '⚡', elasticache: '⚡', memorydb: '⚡', opensearch: '🔍',
  docdb_cluster: '📄', efs: '📁', s3_bucket: '🪣',
  sqs_queue: '📬', sns_topic: '📣', eventbridge_bus: '🚌', eventbridge_rule: '📅',
  kinesis_stream: '🌊', firehose_stream: '🚒', msk_cluster: '📡', stepfunctions: '🔀',
  iam_role: '👤', secret: '🔑', kms_key: '🗝️', acm_cert: '📜', ssm_parameter: '🗂️',
  wafv2_webacl: '🔰', guardduty_detector: '🕵️',
  codepipeline: '⛓️', codebuild: '🔨', ecr_repo: '📦', cognito_pool: '🪪',
  cw_alarm: '🔔', log_group: '📋',
  cidr_block: '🔵',
}

// ─── Edge relationship colors ─────────────────────────────────────────────────

export const EDGE_COLORS: Record<EdgeRelationship, { stroke: string; label: string }> = {
  network:      { stroke: '#64748B', label: 'Network'      },
  dataflow:     { stroke: '#F97316', label: 'Data Flow'    },
  iam:          { stroke: '#8B5CF6', label: 'IAM'          },
  deployment:   { stroke: '#10B981', label: 'Deployment'   },
  observability:{ stroke: '#F59E0B', label: 'Observability'},
  auth:         { stroke: '#EC4899', label: 'Auth'         },
  encryption:   { stroke: '#0D9488', label: 'Encryption'   },
  dns:          { stroke: '#0EA5E9', label: 'DNS'          },
  logging:      { stroke: '#94A3B8', label: 'Logging'      },
}

// ─── Status indicator colors ──────────────────────────────────────────────────

export const STATUS_COLORS = {
  running: '#10B981',
  stopped: '#6B7280',
  error:   '#EF4444',
  warning: '#F59E0B',
  unknown: '#D1D5DB',
}
