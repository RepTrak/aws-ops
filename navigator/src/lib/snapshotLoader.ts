import type { SnapshotData } from '@/types/snapshot'

async function j<T>(base: string, path: string): Promise<T> {
  try {
    const r = await fetch(`${base}/${path}`)
    if (!r.ok) return {} as T
    // Guard against Vite's SPA fallback returning index.html (200 HTML) for
    // missing snapshot files — parse the text first to detect HTML responses.
    const text = await r.text()
    if (!text || text.trimStart().startsWith('<')) return {} as T
    return JSON.parse(text) as T
  } catch { return {} as T }
}

async function jNdj<T>(base: string, path: string): Promise<T[]> {
  try {
    const r = await fetch(`${base}/${path}`)
    if (!r.ok) return []
    const text = await r.text()
    if (!text || text.trimStart().startsWith('<')) return []
    return text.split('\n')
      .map(l => l.trim()).filter(Boolean)
      .flatMap(l => { try { return [JSON.parse(l) as T] } catch { return [] } })
  } catch { return [] }
}

export async function resolveSnapshotBase(): Promise<{ base: string; folder: string }> {
  const params = new URLSearchParams(window.location.search)
  const explicit = params.get('snapshot')
  if (explicit) return { base: `/snapshots/${explicit}`, folder: explicit }
  try {
    const latest = await fetch('/snapshots/latest.json').then(r => r.json()) as { folder: string }
    return { base: `/snapshots/${latest.folder}`, folder: latest.folder }
  } catch {
    throw new Error('Could not load /snapshots/latest.json. Is the dev server running from aws-ops/?')
  }
}

export async function loadSnapshot(explicitFolder?: string): Promise<SnapshotData> {
  const { base } = explicitFolder
    ? { base: `/snapshots/${explicitFolder}` }
    : await resolveSnapshotBase()
  const d = `${base}/derived`
  const r = `${base}/raw`

  const [
    manifest,
    serviceTopology, albToService, sgConnectivity, sgMembers,
    subnetClassification, iamRoleResourceAccess, iamRoleTrustAnalysis,
    cwAlarmTargets, secretConsumers, paramConsumers, taskEniMap,
    pipelineChains, sfResourceRefs, dynamoStreamConsumers,
    apigwAuthChain, sqsDlqChains, kmsUsage,
    lbRaw, rdsInstancesRaw, rdsClustersRaw, redshiftClustersRaw,
    redshiftWgRaw, elasticacheRaw, dynamoTablesRaw,
    lambdaRaw, sqsQueuesRaw, snsTopicsRaw, ecsClustersRaw,
    apigwRestRaw, apigwV2Raw, s3BucketsRaw, secretsRaw, iamRolesRaw,
    cognitoRaw, osRaw, kinesisRaw, firehoseRaw,
    targetHealthRaw,           // ← position matches the jNdj fetch below
    kmsAliasesRaw, logGroupsRaw, cloudMapNsRaw, lambdaEsmsRaw,
    ecrReposRaw, acmCertDetailsRaw, elbListenersRaw,
    eventbridgeRulesRaw, eventbridgeTargetsRaw, codebuildProjectsRaw,
    efsRaw, natGwRaw, vpcEpRaw,
    cfRaw, r53Raw,
    vpcsRaw, mskRaw, memdbRaw,
    wafRegionalDetailRaw, wafRegionalResourceRaw, wafCfDetailRaw, gdRaw,
    eksRaw,
  ] = await Promise.all([
    j<SnapshotData['manifest']>(base, 'manifest.json'),
    j<SnapshotData['serviceTopology']>(d, 'service_topology.json'),
    j<SnapshotData['albToService']>(d, 'alb_to_service.json'),
    j<SnapshotData['sgConnectivity']>(d, 'sg_connectivity.json'),
    j<SnapshotData['sgMembers']>(d, 'sg_members.json'),
    j<SnapshotData['subnetClassification']>(d, 'subnet_classification.json'),
    j<SnapshotData['iamRoleResourceAccess']>(d, 'iam_role_resource_access.json'),
    j<SnapshotData['iamRoleTrustAnalysis']>(d, 'iam_role_trust_analysis.json'),
    j<SnapshotData['cwAlarmTargets']>(d, 'cloudwatch_alarm_targets.json'),
    j<SnapshotData['secretConsumers']>(d, 'secret_consumers.json'),
    j<SnapshotData['paramConsumers']>(d, 'param_consumers.json'),
    j<SnapshotData['taskEniMap']>(d, 'task_eni_map.json'),
    j<SnapshotData['pipelineChains']>(d, 'pipeline_chains.json'),
    j<SnapshotData['sfResourceRefs']>(d, 'stepfunctions_resource_refs.json'),
    j<SnapshotData['dynamoStreamConsumers']>(d, 'dynamodb_stream_consumers.json'),
    j<SnapshotData['apigwAuthChain']>(d, 'apigw_auth_chain.json'),
    j<SnapshotData['sqsDlqChains']>(d, 'sqs_dlq_chains.json'),
    j<SnapshotData['kmsUsage']>(d, 'kms_usage.json'),
    j<{ LoadBalancers: SnapshotData['loadBalancers'] }>(r, 'elbv2-load-balancers.json'),
    j<{ DBInstances: SnapshotData['rdsInstances'] }>(r, 'rds-db-instances.json'),
    j<{ DBClusters: SnapshotData['rdsClusters'] }>(r, 'rds-db-clusters.json'),
    j<{ Clusters: SnapshotData['redshiftClusters'] }>(r, 'redshift-clusters.json'),
    j<{ workgroups: SnapshotData['redshiftServerlessWorkgroups'] }>(r, 'redshift-serverless-workgroups.json'),
    j<{ ReplicationGroups: SnapshotData['elasticacheGroups'] }>(r, 'elasticache-replication-groups.json'),
    j<{ TableNames: string[] }>(r, 'dynamodb-tables.json'),
    j<{ Functions: SnapshotData['lambdaFunctions'] }>(r, 'lambda-functions.json'),
    j<{ QueueUrls: string[] }>(r, 'sqs-queues.json'),
    j<{ Topics: SnapshotData['snsTopics'] }>(r, 'sns-topics.json'),
    j<{ clusterArns: string[] }>(r, 'ecs-clusters.json'),
    j<{ items: SnapshotData['apigwRestApis'] }>(r, 'apigw-rest-apis.json'),
    j<{ Items: SnapshotData['apigwv2Apis'] }>(r, 'apigwv2-apis.json'),
    j<{ Buckets: SnapshotData['s3Buckets'] }>(r, 's3-buckets.json'),
    j<{ SecretList: SnapshotData['secrets'] }>(r, 'secretsmanager-list-secrets.json'),
    j<{ Roles: SnapshotData['iamRoles'] }>(r, 'iam-roles.json'),
    j<{ UserPools: SnapshotData['cognitoUserPools'] }>(r, 'cognito-user-pools.json'),
    j<{ DomainNames: SnapshotData['openSearchDomains'] }>(r, 'opensearch-domains.json'),
    j<{ StreamNames: string[] }>(r, 'kinesis-streams.json'),
    j<{ DeliveryStreamNames: string[] }>(r, 'firehose-delivery-streams.json'),
    jNdj<SnapshotData['targetHealth'][0]>(r, 'elbv2-target-health.ndjson'),
    j<{ Aliases: SnapshotData['kmsAliases'] }>(r, 'kms-aliases.json'),
    j<{ logGroups: SnapshotData['logGroups'] }>(r, 'logs-log-groups.json'),
    j<{ Namespaces: SnapshotData['cloudMapNamespaces'] }>(r, 'servicediscovery-list-namespaces.json'),
    j<{ EventSourceMappings: SnapshotData['lambdaEsms'] }>(r, 'lambda-event-source-mappings.json'),
    j<{ repositories: SnapshotData['ecrRepos'] }>(r, 'ecr-repositories.json'),
    jNdj<SnapshotData['acmCertDetails'][0]>(r, 'acm-certificate-details.ndjson'),
    jNdj<SnapshotData['elbListeners'][0]>(r, 'elbv2-listeners.ndjson'),
    jNdj<SnapshotData['eventbridgeRules'][0]>(r, 'events-rules.ndjson'),
    jNdj<SnapshotData['eventbridgeTargets'][0]>(r, 'events-targets.ndjson'),
    j<{ projects: string[] }>(r, 'codebuild-projects.json'),
    j<{ FileSystems: SnapshotData['efsFileSystems'] }>(r, 'efs-file-systems.json'),
    j<SnapshotData['natGatewayEips']>(d, 'nat_gateway_eips.json'),
    j<SnapshotData['vpcEndpointRoutes']>(d, 'vpc_endpoint_routes.json'),
    j<{ DistributionList: { Items: SnapshotData['cloudfrontDistributions'] } }>(r, 'cloudfront-distributions.json'),
    jNdj<SnapshotData['route53RecordSets'][0]>(r, 'route53-record-sets.ndjson'),
    j<{ Vpcs: SnapshotData['vpcs'] }>(r, 'ec2-vpcs.json'),
    j<{ ClusterInfoList: SnapshotData['mskClusters'] }>(r, 'kafka-clusters.json'),
    j<{ Clusters: SnapshotData['memorydbClusters'] }>(r, 'memorydb-clusters.json'),
    jNdj<SnapshotData['wafv2RegionalDetails'][0]>(r, 'wafv2-webacl-details-regional.ndjson'),
    jNdj<SnapshotData['wafv2RegionalResources'][0]>(r, 'wafv2-webacl-resources-regional.ndjson'),
    jNdj<SnapshotData['wafv2CfDetails'][0]>(r, 'wafv2-webacl-details-cloudfront.ndjson'),
    jNdj<SnapshotData['guarddutyDetails'][0]>(r, 'guardduty-detector-details.ndjson'),
    jNdj<SnapshotData['eksClusterDetails'][0]>(r, 'eks-cluster-details.ndjson'),
  ])

  return {
    manifest,
    serviceTopology, albToService,
    sgConnectivity:  sgConnectivity ?? { edges: [], sg_names: {} },
    sgMembers:       sgMembers ?? {},
    subnetClassification, iamRoleResourceAccess, iamRoleTrustAnalysis,
    cwAlarmTargets, secretConsumers, paramConsumers, taskEniMap,
    pipelineChains, sfResourceRefs, dynamoStreamConsumers, apigwAuthChain, sqsDlqChains,
    kmsUsage: kmsUsage ?? {},
    targetHealth: Array.isArray(targetHealthRaw) ? targetHealthRaw as SnapshotData['targetHealth'] : [],
    loadBalancers:   (lbRaw as any)?.LoadBalancers ?? [],
    rdsInstances:    (rdsInstancesRaw as any)?.DBInstances ?? [],
    rdsClusters:     (rdsClustersRaw as any)?.DBClusters ?? [],
    redshiftClusters:(redshiftClustersRaw as any)?.Clusters ?? [],
    redshiftServerlessWorkgroups: (redshiftWgRaw as any)?.workgroups ?? [],
    elasticacheGroups:(elasticacheRaw as any)?.ReplicationGroups ?? [],
    dynamoTables:    (dynamoTablesRaw as any)?.TableNames ?? [],
    lambdaFunctions: (lambdaRaw as any)?.Functions ?? [],
    sqsQueues:       (sqsQueuesRaw as any)?.QueueUrls ?? [],
    snsTopics:       (snsTopicsRaw as any)?.Topics ?? [],
    ecsClusters:     (ecsClustersRaw as any)?.clusterArns ?? [],
    apigwRestApis:   (apigwRestRaw as any)?.items ?? [],
    apigwv2Apis:     (apigwV2Raw as any)?.Items ?? [],
    s3Buckets:       (s3BucketsRaw as any)?.Buckets ?? [],
    secrets:         (secretsRaw as any)?.SecretList ?? [],
    iamRoles:        (iamRolesRaw as any)?.Roles ?? [],
    cognitoUserPools:(cognitoRaw as any)?.UserPools ?? [],
    openSearchDomains:(osRaw as any)?.DomainNames ?? [],
    kinesisStreams:  (kinesisRaw as any)?.StreamNames ?? [],
    firehoseStreams:  (firehoseRaw as any)?.DeliveryStreamNames ?? [],
    kmsAliases:      (kmsAliasesRaw as any)?.Aliases ?? [],
    logGroups:       (logGroupsRaw as any)?.logGroups ?? [],
    cloudMapNamespaces: (cloudMapNsRaw as any)?.Namespaces ?? [],
    lambdaEsms:          (lambdaEsmsRaw as any)?.EventSourceMappings ?? [],
    ecrRepos:            (ecrReposRaw as any)?.repositories ?? [],
    acmCertDetails:      Array.isArray(acmCertDetailsRaw) ? acmCertDetailsRaw : [],
    elbListeners:        Array.isArray(elbListenersRaw) ? elbListenersRaw : [],
    eventbridgeRules:    Array.isArray(eventbridgeRulesRaw) ? eventbridgeRulesRaw : [],
    eventbridgeTargets:  Array.isArray(eventbridgeTargetsRaw) ? eventbridgeTargetsRaw : [],
    codebuildProjects:   (codebuildProjectsRaw as any)?.projects ?? [],
    efsFileSystems:           (efsRaw as any)?.FileSystems ?? [],
    natGatewayEips:           (natGwRaw as any) ?? {},
    vpcEndpointRoutes:        (vpcEpRaw as any) ?? {},
    cloudfrontDistributions:  (cfRaw as any)?.DistributionList?.Items ?? [],
    route53RecordSets:        Array.isArray(r53Raw) ? r53Raw : [],
    vpcs:                     (vpcsRaw as any)?.Vpcs ?? [],
    mskClusters:              (mskRaw as any)?.ClusterInfoList ?? [],
    memorydbClusters:         (memdbRaw as any)?.Clusters ?? [],
    wafv2RegionalDetails:     Array.isArray(wafRegionalDetailRaw) ? wafRegionalDetailRaw : [],
    wafv2RegionalResources:   Array.isArray(wafRegionalResourceRaw) ? wafRegionalResourceRaw : [],
    wafv2CfDetails:           Array.isArray(wafCfDetailRaw) ? wafCfDetailRaw : [],
    guarddutyDetails:         Array.isArray(gdRaw) ? gdRaw : [],
    eksClusterDetails:        Array.isArray(eksRaw) ? eksRaw : [],
  }
}
