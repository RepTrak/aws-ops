// Snapshot-level types — what we load from the derived/ and raw/ JSON files.

export interface SnapshotManifest {
  timestamp_utc: string
  region: string
  profile: string | null
  with_secret_values: boolean
  all_regions_mode: boolean
}

export interface SnapshotData {
  manifest: SnapshotManifest
  // derived
  serviceTopology: Record<string, ServiceTopology>
  albToService: Record<string, AlbToService>
  sgConnectivity: { edges: SgEdge[]; sg_names: Record<string, string> }
  sgMembers: Record<string, SgMember[]>
  subnetClassification: Record<string, SubnetInfo>
  iamRoleResourceAccess: Record<string, IamRoleAccess>
  iamRoleTrustAnalysis: Record<string, IamRoleTrust>
  cwAlarmTargets: Record<string, CwAlarmTarget>
  secretConsumers: Record<string, Consumer[]>
  paramConsumers: Record<string, Consumer[]>
  taskEniMap: Record<string, TaskEni>
  pipelineChains: Record<string, PipelineChain>
  sfResourceRefs: Record<string, SfResourceRefs>
  dynamoStreamConsumers: Record<string, DynamoStreamConsumer>
  apigwAuthChain: Record<string, ApigwAuth>
  sqsDlqChains: Record<string, SqsDlq>
  // raw summaries
  loadBalancers: LbRaw[]
  rdsInstances: RdsInstanceRaw[]
  rdsClusters: RdsClusterRaw[]
  redshiftClusters: RedshiftClusterRaw[]
  redshiftServerlessWorkgroups: RedshiftWgRaw[]
  elasticacheGroups: ElasticacheRaw[]
  dynamoTables: string[]
  lambdaFunctions: LambdaRaw[]
  sqsQueues: string[]
  snsTopics: SnsTopicRaw[]
  ecsClusters: string[]
  apigwRestApis: ApigwRestApiRaw[]
  apigwv2Apis: ApigwV2ApiRaw[]
  s3Buckets: S3BucketRaw[]
  secrets: SecretRaw[]
  iamRoles: IamRoleRaw[]
  cognitoUserPools: CognitoPoolRaw[]
  openSearchDomains: OsNameRaw[]
  kinesisStreams: string[]
  firehoseStreams: string[]
  targetHealth: TargetHealthRecord[]
  kmsAliases: KmsAliasRaw[]
  kmsUsage: Record<string, KmsUsageEntry>
  logGroups: LogGroupRaw[]
  cloudMapNamespaces: CloudMapNamespaceRaw[]
  lambdaEsms: LambdaEsmRaw[]
  ecrRepos: EcrRepoRaw[]
  acmCertDetails: AcmCertDetailRecord[]
  elbListeners: ElbListenerRecord[]
  eventbridgeRules: EventbridgeRuleRecord[]
  eventbridgeTargets: EventbridgeTargetRecord[]
  codebuildProjects: string[]
  efsFileSystems: EfsRaw[]
  natGatewayEips: Record<string, NatGatewayEip>
  vpcEndpointRoutes: Record<string, VpcEndpointRoute>
  cloudfrontDistributions: CloudFrontDistributionRaw[]
  route53RecordSets: Route53RecordSetRecord[]
  vpcs: VpcRaw[]
  mskClusters: MskClusterRaw[]
  memorydbClusters: MemoryDbRaw[]
  wafv2RegionalDetails: Wafv2DetailRecord[]
  wafv2RegionalResources: Wafv2ResourceRecord[]
  wafv2CfDetails: Wafv2DetailRecord[]
  guarddutyDetails: GuardDutyDetailRecord[]
  eksClusterDetails: EksClusterDetailRecord[]
}

// — derived types —

export interface ServiceTopology {
  service_name: string
  cluster_arn: string
  task_definition_arn: string
  task_role_arn?: string
  execution_role_arn?: string
  desired_count: number
  running_count: number
  pending_count: number
  containers: { name: string; image: string; log_group: string; port_mappings: PortMapping[] }[]
  efs_volumes: { volume_name: string; file_system_id: string; access_point_id: string }[]
  cloud_map: { registry_arn: string; service_name: string; namespace_id: string }[]
  subnets: string[]
  security_groups: string[]
  load_balancer_target_groups: string[]
}

export interface PortMapping { containerPort: number; protocol: string; hostPort?: number }

export interface AlbToService {
  name: string; scheme: string; dns_name: string
  target_groups: { arn: string; name: string }[]
  ecs_services: string[]
}

export interface SgEdge {
  from_sg?: string; from_cidr?: string; to_sg: string
  protocol: string; from_port: number | null; to_port: number | null
}

export interface SgMember { resource_type: string; resource_id: string; name?: string }

export interface SubnetInfo {
  vpc_id: string; az: string; cidr: string; name: string
  is_public: boolean; map_public_ip_on_launch: boolean; route_table_id: string
}

export interface IamRoleAccess {
  service_access: Record<string, string[]>
  allow_statements: { source: string; policy_name: string; actions: string[]; resources: string[]; services: string[] }[]
  unanalyzed_managed_policies: string[]
}

export interface IamRoleTrust {
  role_arn: string; trusted_services: string[]; trusted_accounts: string[]
  trusted_roles: string[]; federated_principals: string[]
}

export interface CwAlarmTarget {
  alarm_name: string; metric?: string; namespace?: string
  resource_type: string; resource_ids: Record<string, string>
  threshold?: number; comparison?: string; state?: string
  alarm_actions: { arn: string; type: string }[]
  alarm_rule?: string
}

export interface Consumer { task_definition: string; container: string; env_name: string }

export interface TaskEni {
  cluster_arn: string; task_definition_arn: string; eni_id: string
  private_ip: string; subnet_id: string; vpc_id: string
  security_groups: string[]; last_status: string
}

export interface PipelineChain {
  artifact_store_bucket: string; artifact_store_type: string
  stages: { name: string; actions: { name: string; category: string; provider: string }[] }[]
  resource_refs: PipelineRef[]
}

export interface PipelineRef {
  stage: string; action: string; category: string; provider: string; resource_type: string
  project?: string; cluster?: string; service?: string; application?: string
  deployment_group?: string; repo?: string; owner?: string; branch?: string
  connection_arn?: string; bucket?: string; repository?: string
}

export interface SfResourceRefs {
  name: string; type: string; role_arn: string
  resource_refs: { state_name: string; resource_type: string; resource_uri: string; resource_arn?: string; table_name?: string; queue_url?: string; topic_arn?: string; state_machine_arn?: string }[]
}

export interface DynamoStreamConsumer {
  table_name: string; table_arn: string
  lambda_consumers: { function_arn: string; state: string; batch_size: number | null; starting_position: string }[]
}

export interface ApigwAuth {
  api_id: string; authorizer_id: string; name: string; type: string
  issuer?: string; audience?: string[]; cognito_pool_id?: string
  cognito_pool?: { name: string; arn: string; mfa: string }
  authorizer_uri?: string
}

export interface SqsDlq {
  queue_url: string; queue_name: string; dlq_arn: string; max_receive_count: number | null
}

// — raw types (minimally typed, just what we display) —

export interface LbRaw { LoadBalancerArn: string; LoadBalancerName: string; Scheme: string; DNSName: string; Type: string; VpcId?: string }
export interface RdsInstanceRaw { DBInstanceIdentifier: string; DBInstanceClass: string; Engine: string; DBInstanceStatus: string; Endpoint?: { Address: string; Port: number }; VpcSecurityGroups: { VpcSecurityGroupId: string }[] }
export interface RdsClusterRaw { DBClusterIdentifier: string; Engine: string; Status: string; VpcSecurityGroups: { VpcSecurityGroupId: string }[] }
export interface RedshiftClusterRaw { ClusterIdentifier: string; NodeType: string; ClusterStatus: string; NumberOfNodes: number; VpcSecurityGroups: { VpcSecurityGroupId: string }[] }
export interface RedshiftWgRaw { workgroupName: string; status: string; baseCapacity: number }
export interface ElasticacheRaw { ReplicationGroupId: string; Description: string; Status: string; SecurityGroups?: { SecurityGroupId: string }[] }
export interface LambdaRaw { FunctionName: string; FunctionArn: string; Runtime: string; Handler: string; Role: string; VpcConfig?: { VpcId: string; SubnetIds: string[]; SecurityGroupIds: string[] } }
export interface SnsTopicRaw { TopicArn: string }
export interface ApigwRestApiRaw { id: string; name: string; description?: string }
export interface ApigwV2ApiRaw { ApiId: string; Name: string; ProtocolType: string }
export interface S3BucketRaw { Name: string; CreationDate: string }
export interface SecretRaw { ARN: string; Name: string; Description?: string }
export interface IamRoleRaw { RoleName: string; Arn: string; Description?: string }
export interface CognitoPoolRaw { Id: string; Name: string }
export interface OsNameRaw { DomainName: string }
export interface TargetHealthRecord {
  target_group_arn: string
  data: {
    TargetHealthDescriptions: Array<{
      Target: { Id: string; Port: number }
      TargetHealth: { State: string; Description?: string; Reason?: string }
    }>
  }
}
export interface KmsAliasRaw { AliasName: string; AliasArn: string; TargetKeyId?: string }
export interface LogGroupRaw { logGroupName: string; retentionInDays?: number }
export interface CloudMapNamespaceRaw { Id: string; Name: string; Type: string; Arn?: string }
export interface KmsUsageEntry {
  alias: string
  resources: { resource_type: string; resource_id: string }[]
}
export interface LambdaEsmRaw {
  EventSourceArn: string
  FunctionArn: string
  State: string
  BatchSize?: number
}
export interface EcrRepoRaw {
  repositoryName: string
  repositoryArn: string
  repositoryUri: string
}
export interface AcmCertDetailRecord {
  certificate_arn: string   // actual field name in the ndjson
  data?: {
    Certificate?: {
      CertificateArn: string
      DomainName: string
      SubjectAlternativeNames?: string[]
      Status?: string
      InUseBy?: string[]
    }
  }
}
export interface ElbListenerRecord {
  load_balancer_arn: string
  data?: {
    Listeners?: Array<{
      Port: number
      Protocol: string
      Certificates?: Array<{ CertificateArn: string }>
    }>
  }
}
export interface EventbridgeRuleRecord {
  bus: string
  data?: {
    Rules?: Array<{ Name: string; Arn: string; State: string; ScheduleExpression?: string }>
  }
}
export interface EventbridgeTargetRecord {
  rule: string
  bus: string
  data?: { Targets?: Array<{ Id: string; Arn: string }> }
}
export interface EfsRaw {
  FileSystemId: string
  FileSystemArn: string
  Name?: string
  LifeCycleState: string
  Encrypted?: boolean
  KmsKeyId?: string
}
export interface NatGatewayEip {
  subnet_id: string
  vpc_id: string
  state: string
  connectivity_type: string
  eips: Array<{ allocation_id: string; public_ip: string; private_ip: string }>
}
export interface Wafv2DetailRecord {
  data?: { WebACL?: { Name: string; ARN: string; Description?: string } }
}
export interface Wafv2ResourceRecord {
  web_acl_arn: string
  data?: { ResourceArns?: string[] }
}
export interface EksClusterDetailRecord {
  cluster_name: string
  data?: {
    cluster?: {
      name: string
      arn: string
      status: string
      version: string
      endpoint?: string
      roleArn?: string
      resourcesVpcConfig?: {
        vpcId: string
        subnetIds: string[]
        securityGroupIds: string[]
        clusterSecurityGroupId?: string
      }
      tags?: Record<string, string>
    }
  }
}
export interface GuardDutyDetailRecord {
  detector_id: string
  data?: {
    Status?: string
    FindingPublishingFrequency?: string
    DataSources?: Record<string, unknown>
  }
}
export interface VpcRaw {
  VpcId: string
  CidrBlock: string
  State: string
  Tags?: Array<{ Key: string; Value: string }>
}
export interface MskClusterRaw {
  ClusterArn: string
  ClusterName: string
  State: string
  ClusterType?: string
}
export interface MemoryDbRaw {
  Name: string
  Status: string
  NodeType: string
  EngineVersion?: string
}
export interface CloudFrontDistributionRaw {
  Id: string
  ARN: string
  Status: string
  DomainName: string
  Aliases?: { Items?: string[] }
  Origins?: { Items?: Array<{ Id: string; DomainName: string }> }
  ViewerCertificate?: { ACMCertificateArn?: string }
}
export interface Route53RecordSetRecord {
  hosted_zone_id: string
  data?: {
    ResourceRecordSets?: Array<{
      Name: string
      Type: string
      AliasTarget?: { DNSName: string }
      ResourceRecords?: Array<{ Value: string }>
    }>
  }
}
export interface VpcEndpointRoute {
  service: string
  vpc_id: string
  type: string
  state: string
  route_table_ids: string[]
  subnets_routed_through: string[]
  subnet_ids: string[]
  dns_entries: string[]
}
