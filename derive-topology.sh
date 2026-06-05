#!/usr/bin/env bash
# Rebuild the derived/ topology files for an existing snapshot without re-running
# the full AWS export.
#
# Usage:
#   OUT_DIR=/path/to/snapshot ./derive_topology.sh
#   OUT_DIR=snapshots/2026-06-05T00-17-42Z-eu-west-1 ./derive_topology.sh
#
set -euo pipefail

if [[ -z "${OUT_DIR:-}" ]]; then
  echo "ERROR: OUT_DIR is not set. Example:" >&2
  echo "  OUT_DIR=snapshots/2026-06-05T00-17-42Z-eu-west-1 ./derive_topology.sh" >&2
  exit 1
fi

if [[ ! -d "$OUT_DIR/raw" ]]; then
  echo "ERROR: $OUT_DIR/raw does not exist — is OUT_DIR pointing at a valid snapshot folder?" >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] Building derived topology files for: $OUT_DIR"

export OUT_DIR

python3 <<'PY'
import json
import os
import urllib.parse
from pathlib import Path

out = Path(os.environ['OUT_DIR'])
raw = out / 'raw'
derived = out / 'derived'
derived.mkdir(parents=True, exist_ok=True)


def load_json(name, default=None):
    path = raw / name
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except Exception:
        return default

def load_ndjson(name):
    path = raw / name
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:
            continue
    return records

summary = {}
summary['ecs_cluster_count'] = len((load_json('ecs-clusters.json', {}) or {}).get('clusterArns', []) or [])
summary['ecs_task_definition_count'] = len((load_json('ecs-list-task-definitions.json', {}) or {}).get('taskDefinitionArns', []) or [])
summary['load_balancer_count'] = len((load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers', []) or [])
summary['target_group_count'] = len((load_json('elbv2-target-groups.json', {}) or {}).get('TargetGroups', []) or [])
summary['vpc_count'] = len((load_json('ec2-vpcs.json', {}) or {}).get('Vpcs', []) or [])
summary['subnet_count'] = len((load_json('ec2-subnets.json', {}) or {}).get('Subnets', []) or [])
summary['security_group_count'] = len((load_json('ec2-security-groups.json', {}) or {}).get('SecurityGroups', []) or [])
summary['rds_instance_count'] = len((load_json('rds-db-instances.json', {}) or {}).get('DBInstances', []) or [])
summary['rds_proxy_count'] = len((load_json('rds-db-proxies.json', {}) or {}).get('DBProxies', []) or [])
summary['ec2_ecs_instance_count'] = sum(
    len(r.get('Instances', []))
    for r in (load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations', []) or []
)
summary['rds_snapshot_count'] = len((load_json('rds-db-snapshots.json', {}) or {}).get('DBSnapshots', []) or [])
summary['redshift_cluster_count'] = len((load_json('redshift-clusters.json', {}) or {}).get('Clusters', []) or [])
summary['redshift_serverless_workgroup_count'] = len((load_json('redshift-serverless-workgroups.json', {}) or {}).get('workgroups', []) or [])
summary['redshift_serverless_namespace_count'] = len((load_json('redshift-serverless-namespaces.json', {}) or {}).get('namespaces', []) or [])
summary['efs_file_system_count'] = len((load_json('efs-file-systems.json', {}) or {}).get('FileSystems', []) or [])
summary['s3_bucket_count'] = len((load_json('s3-buckets.json', {}) or {}).get('Buckets', []) or [])
summary['dynamodb_table_count'] = len((load_json('dynamodb-tables.json', {}) or {}).get('TableNames', []) or [])
summary['docdb_cluster_count'] = len((load_json('docdb-clusters.json', {}) or {}).get('DBClusters', []) or [])
summary['lambda_function_count'] = len((load_json('lambda-functions.json', {}) or {}).get('Functions', []) or [])
summary['lambda_event_source_mapping_count'] = len((load_json('lambda-event-source-mappings.json', {}) or {}).get('EventSourceMappings', []) or [])
summary['apigw_rest_api_count'] = len((load_json('apigw-rest-apis.json', {}) or {}).get('items', []) or [])
summary['apigwv2_api_count'] = len((load_json('apigwv2-apis.json', {}) or {}).get('Items', []) or [])
summary['cognito_user_pool_count'] = len((load_json('cognito-user-pools.json', {}) or {}).get('UserPools', []) or [])
summary['ecr_repository_count'] = len((load_json('ecr-repositories.json', {}) or {}).get('repositories', []) or [])
summary['acm_certificate_count'] = len((load_json('acm-certificates.json', {}) or {}).get('CertificateSummaryList', []) or [])
_wafv2_r = load_json('wafv2-webacls-regional.json', {}) or {}
_wafv2_cf = load_json('wafv2-webacls-cloudfront.json', {}) or {}
summary['wafv2_webacl_count'] = len(_wafv2_r.get('WebACLs', []) or []) + len(_wafv2_cf.get('WebACLs', []) or [])
summary['cloudfront_distribution_count'] = len((((load_json('cloudfront-distributions.json', {}) or {}).get('DistributionList') or {}).get('Items') or []))
summary['asg_count'] = len((load_json('autoscaling-groups.json', {}) or {}).get('AutoScalingGroups', []) or [])
summary['launch_template_count'] = len((load_json('ec2-launch-templates.json', {}) or {}).get('LaunchTemplates', []) or [])
summary['log_group_count'] = len((load_json('logs-log-groups.json', {}) or {}).get('logGroups', []) or [])
_cw_alarms = load_json('cloudwatch-alarms.json', {}) or {}
summary['cloudwatch_alarm_count'] = (
    len(_cw_alarms.get('MetricAlarms', []) or []) +
    len(_cw_alarms.get('CompositeAlarms', []) or [])
)
summary['sqs_queue_count'] = len((load_json('sqs-queues.json', {}) or {}).get('QueueUrls', []) or [])
summary['sns_topic_count'] = len((load_json('sns-topics.json', {}) or {}).get('Topics', []) or [])
summary['eventbridge_bus_count'] = len((load_json('events-buses.json', {}) or {}).get('EventBuses', []) or [])
summary['stepfunctions_count'] = len((load_json('stepfunctions-state-machines.json', {}) or {}).get('stateMachines', []) or [])
summary['msk_cluster_count'] = len((load_json('kafka-clusters.json', {}) or {}).get('ClusterInfoList', []) or [])
summary['kinesis_stream_count'] = len((load_json('kinesis-streams.json', {}) or {}).get('StreamNames', []) or [])
summary['firehose_stream_count'] = len((load_json('firehose-delivery-streams.json', {}) or {}).get('DeliveryStreamNames', []) or [])
summary['opensearch_domain_count'] = len((load_json('opensearch-domains.json', {}) or {}).get('DomainNames', []) or [])
summary['codebuild_project_count'] = len((load_json('codebuild-projects.json', {}) or {}).get('projects', []) or [])
summary['codepipeline_count'] = len((load_json('codepipeline-pipelines.json', {}) or {}).get('pipelines', []) or [])
summary['codedeploy_application_count'] = len((load_json('codedeploy-applications.json', {}) or {}).get('applications', []) or [])
summary['kms_key_count'] = len((load_json('kms-keys.json', {}) or {}).get('Keys', []) or [])
summary['cloudtrail_trail_count'] = len((load_json('cloudtrail-trails.json', {}) or {}).get('trailList', []) or [])
summary['guardduty_detector_count'] = len((load_json('guardduty-detectors.json', {}) or {}).get('DetectorIds', []) or [])
summary['iam_user_count'] = len((load_json('iam-users.json', {}) or {}).get('Users', []) or [])
summary['iam_group_count'] = len((load_json('iam-groups.json', {}) or {}).get('Groups', []) or [])
summary['iam_local_policy_count'] = len((load_json('iam-local-policies.json', {}) or {}).get('Policies', []) or [])
summary['accessanalyzer_count'] = len((load_json('accessanalyzer-analyzers.json', {}) or {}).get('analyzers', []) or [])
summary['secret_count'] = len((load_json('secretsmanager-list-secrets.json', {}) or {}).get('SecretList', []) or [])
summary['hosted_zone_count'] = len((load_json('route53-hosted-zones.json', {}) or {}).get('HostedZones', []) or [])
summary['route53_health_check_count'] = len((load_json('route53-health-checks.json', {}) or {}).get('HealthChecks', []) or [])
summary['elastic_ip_count'] = len((load_json('ec2-addresses.json', {}) or {}).get('Addresses', []) or [])
summary['vpc_peering_count'] = len((load_json('ec2-vpc-peering-connections.json', {}) or {}).get('VpcPeeringConnections', []) or [])
summary['resolver_endpoint_count'] = len((load_json('r53resolver-endpoints.json', {}) or {}).get('ResolverEndpoints', []) or [])
summary['resource_explorer_view_present'] = (raw / 'resource-explorer-2-search.json').exists()

# Consumer mapping: which task definitions reference which secrets / SSM parameters
secret_consumers = {}
param_consumers = {}
td_ndjson = raw / 'ecs-describe-task-definitions.ndjson'
if td_ndjson.exists():
    for line in td_ndjson.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except Exception:
            continue
        td = (record.get('data') or record).get('taskDefinition') or {}
        td_ref = f'{td.get("family", "")}:{td.get("revision", "")}'
        for container in (td.get('containerDefinitions') or []):
            cname = container.get('name', '')
            for s in (container.get('secrets') or []):
                ref = s.get('valueFrom', '')
                entry = {'task_definition': td_ref, 'container': cname, 'env_name': s.get('name', '')}
                if 'arn:aws:ssm:' in ref or ref.startswith('/'):
                    param_consumers.setdefault(ref, []).append(entry)
                else:
                    secret_consumers.setdefault(ref, []).append(entry)

(derived / 'secret_consumers.json').write_text(json.dumps(secret_consumers, indent=2) + '\n')
(derived / 'param_consumers.json').write_text(json.dumps(param_consumers, indent=2) + '\n')
summary['mapped_secret_refs'] = len(secret_consumers)
summary['mapped_param_refs'] = len(param_consumers)

# --- derived/sg_connectivity.json ---
sgs = (load_json('ec2-security-groups.json', {}) or {}).get('SecurityGroups', []) or []
sg_names = {sg.get('GroupId', ''): sg.get('GroupName', '') for sg in sgs}
sg_edges = []
for sg in sgs:
    to_sg = sg.get('GroupId', '')
    for rule in (sg.get('IpPermissions') or []):
        proto = rule.get('IpProtocol', '')
        fp = rule.get('FromPort')
        tp = rule.get('ToPort')
        for pair in (rule.get('UserIdGroupPairs') or []):
            from_sg = pair.get('GroupId', '')
            if from_sg:
                sg_edges.append({'from_sg': from_sg, 'to_sg': to_sg,
                                  'protocol': proto, 'from_port': fp, 'to_port': tp})
        for cidr in (rule.get('IpRanges') or []):
            sg_edges.append({'from_cidr': cidr.get('CidrIp', ''), 'to_sg': to_sg,
                              'protocol': proto, 'from_port': fp, 'to_port': tp})
        for cidr6 in (rule.get('Ipv6Ranges') or []):
            sg_edges.append({'from_cidr': cidr6.get('CidrIpv6', ''), 'to_sg': to_sg,
                              'protocol': proto, 'from_port': fp, 'to_port': tp})
(derived / 'sg_connectivity.json').write_text(json.dumps(
    {'edges': sg_edges, 'sg_names': sg_names}, indent=2) + '\n')
summary['derived_sg_edges'] = len(sg_edges)

# --- derived/alb_to_service.json ---
tgs = (load_json('elbv2-target-groups.json', {}) or {}).get('TargetGroups', []) or []
tg_to_albs = {tg.get('TargetGroupArn', ''): tg.get('LoadBalancerArns', []) or []
              for tg in tgs}
tg_names = {tg.get('TargetGroupArn', ''): tg.get('TargetGroupName', '') for tg in tgs}
tg_to_services = {}
for _rec in load_ndjson('ecs-services.ndjson'):
    for svc in ((_rec.get('data') or {}).get('services') or []):
        svc_arn = svc.get('serviceArn', '')
        for _lb in (svc.get('loadBalancers') or []):
            tg_arn = _lb.get('targetGroupArn', '')
            if tg_arn and svc_arn:
                tg_to_services.setdefault(tg_arn, []).append(svc_arn)
lbs = (load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers', []) or []
alb_to_service = {}
for _lb in lbs:
    lb_arn = _lb.get('LoadBalancerArn', '')
    assoc_tgs = [t for t, alb_arns in tg_to_albs.items() if lb_arn in alb_arns]
    assoc_svcs = list({s for t in assoc_tgs for s in tg_to_services.get(t, [])})
    alb_to_service[lb_arn] = {
        'name': _lb.get('LoadBalancerName', ''),
        'scheme': _lb.get('Scheme', ''),
        'dns_name': _lb.get('DNSName', ''),
        'target_groups': [{'arn': t, 'name': tg_names.get(t, '')} for t in assoc_tgs],
        'ecs_services': assoc_svcs,
    }
(derived / 'alb_to_service.json').write_text(json.dumps(alb_to_service, indent=2) + '\n')
summary['derived_alb_mappings'] = len(alb_to_service)

# --- derived/service_topology.json ---
_td_lookup = {}
for _rec in load_ndjson('ecs-describe-task-definitions.ndjson'):
    _arn = _rec.get('task_definition_arn', '')
    _td = (_rec.get('data') or {}).get('taskDefinition') or {}
    if _arn:
        _td_lookup[_arn] = _td
_cm_lookup = {}
for _rec in load_ndjson('servicediscovery-services.ndjson'):
    _svc_data = (_rec.get('data') or {}).get('Service') or {}
    _arn = _svc_data.get('Arn', '')
    if _arn:
        _cm_lookup[_arn] = _svc_data
service_topology = {}
for _rec in load_ndjson('ecs-services.ndjson'):
    for svc in ((_rec.get('data') or {}).get('services') or []):
        svc_arn = svc.get('serviceArn', '')
        if not svc_arn:
            continue
        td_arn = svc.get('taskDefinition', '')
        td = _td_lookup.get(td_arn, {})
        containers = []
        for c in (td.get('containerDefinitions') or []):
            log_cfg = c.get('logConfiguration') or {}
            log_group = ''
            if log_cfg.get('logDriver') == 'awslogs':
                log_group = (log_cfg.get('options') or {}).get('awslogs-group', '')
            containers.append({
                'name': c.get('name', ''),
                'image': c.get('image', ''),
                'log_group': log_group,
                'port_mappings': c.get('portMappings') or [],
            })
        efs_vols = []
        for vol in (td.get('volumes') or []):
            efs_cfg = vol.get('efsVolumeConfiguration')
            if efs_cfg:
                efs_vols.append({
                    'volume_name': vol.get('name', ''),
                    'file_system_id': efs_cfg.get('fileSystemId', ''),
                    'access_point_id': (efs_cfg.get('authorizationConfig') or {}).get('accessPointId', ''),
                })
        cloud_map = []
        for reg in (svc.get('serviceRegistries') or []):
            reg_arn = reg.get('registryArn', '')
            _cm = _cm_lookup.get(reg_arn, {})
            cloud_map.append({
                'registry_arn': reg_arn,
                'service_name': _cm.get('Name', ''),
                'namespace_id': _cm.get('NamespaceId', ''),
            })
        net = (svc.get('networkConfiguration') or {}).get('awsvpcConfiguration') or {}
        service_topology[svc_arn] = {
            'service_name': svc.get('serviceName', ''),
            'cluster_arn': svc.get('clusterArn', ''),
            'task_definition_arn': td_arn,
            'desired_count': svc.get('desiredCount', 0),
            'running_count': svc.get('runningCount', 0),
            'pending_count': svc.get('pendingCount', 0),
            'containers': containers,
            'efs_volumes': efs_vols,
            'cloud_map': cloud_map,
            'subnets': net.get('subnets') or [],
            'security_groups': net.get('securityGroups') or [],
            'load_balancer_target_groups': [
                _lb.get('targetGroupArn', '') for _lb in (svc.get('loadBalancers') or [])
            ],
        }
(derived / 'service_topology.json').write_text(json.dumps(service_topology, indent=2) + '\n')
summary['derived_service_topologies'] = len(service_topology)

# --- derived/cloudwatch_alarm_targets.json ---
def _alarm_action_type(arn):
    if ':application-autoscaling:' in arn or ('autoscaling' in arn and 'scalingPolic' in arn):
        return 'autoscaling_policy'
    if ':sns:' in arn:
        return 'sns_topic'
    if ':lambda:' in arn:
        return 'lambda'
    if ':autoscaling:' in arn:
        return 'ec2_autoscaling'
    return 'other'

def _alarm_resource(namespace, dims):
    dm = {d.get('Name', ''): d.get('Value', '') for d in (dims or [])}
    if namespace == 'AWS/ECS':
        return 'ecs_service', {'cluster': dm.get('ClusterName', ''), 'service': dm.get('ServiceName', '')}
    if namespace in ('AWS/ApplicationELB', 'AWS/NetworkELB'):
        return 'load_balancer', {'target_group': dm.get('TargetGroup', ''), 'load_balancer': dm.get('LoadBalancer', '')}
    if namespace == 'AWS/RDS':
        return 'rds_instance', {'db_instance': dm.get('DBInstanceIdentifier', ''), 'db_cluster': dm.get('DBClusterIdentifier', '')}
    if namespace == 'AWS/Redshift':
        return 'redshift_cluster', {'cluster': dm.get('ClusterIdentifier', '')}
    if namespace == 'AWS/ElastiCache':
        return 'elasticache', {'replication_group': dm.get('ReplicationGroupId', ''), 'cluster': dm.get('CacheClusterId', '')}
    if namespace == 'AWS/SQS':
        return 'sqs_queue', {'queue': dm.get('QueueName', '')}
    if namespace == 'AWS/Lambda':
        return 'lambda_function', {'function': dm.get('FunctionName', '')}
    if namespace == 'AWS/DynamoDB':
        return 'dynamodb_table', {'table': dm.get('TableName', '')}
    return 'unknown', {}

cw_data = load_json('cloudwatch-alarms.json', {}) or {}
alarm_targets = {}
for alarm in (cw_data.get('MetricAlarms') or []):
    _arn = alarm.get('AlarmArn', '')
    if not _arn:
        continue
    _rtype, _rids = _alarm_resource(alarm.get('Namespace', ''), alarm.get('Dimensions'))
    alarm_targets[_arn] = {
        'alarm_name': alarm.get('AlarmName', ''),
        'metric': alarm.get('MetricName', ''),
        'namespace': alarm.get('Namespace', ''),
        'resource_type': _rtype,
        'resource_ids': _rids,
        'threshold': alarm.get('Threshold'),
        'comparison': alarm.get('ComparisonOperator', ''),
        'state': alarm.get('StateValue', ''),
        'alarm_actions': [{'arn': a, 'type': _alarm_action_type(a)}
                          for a in (alarm.get('AlarmActions') or [])],
    }
for alarm in (cw_data.get('CompositeAlarms') or []):
    _arn = alarm.get('AlarmArn', '')
    if not _arn:
        continue
    alarm_targets[_arn] = {
        'alarm_name': alarm.get('AlarmName', ''),
        'alarm_rule': alarm.get('AlarmRule', ''),
        'resource_type': 'composite',
        'resource_ids': {},
        'state': alarm.get('StateValue', ''),
        'alarm_actions': [{'arn': a, 'type': _alarm_action_type(a)}
                          for a in (alarm.get('AlarmActions') or [])],
    }
(derived / 'cloudwatch_alarm_targets.json').write_text(json.dumps(alarm_targets, indent=2) + '\n')
summary['derived_alarm_targets'] = len(alarm_targets)

# --- derived/subnet_classification.json ---
_igws = (load_json('ec2-internet-gateways.json', {}) or {}).get('InternetGateways', []) or []
_igw_ids = {igw.get('InternetGatewayId', '') for igw in _igws}
_route_tables = (load_json('ec2-route-tables.json', {}) or {}).get('RouteTables', []) or []
_vpc_to_main_rt = {}
_subnet_to_rt = {}
_rt_routes = {}
for _rt in _route_tables:
    _rt_id = _rt.get('RouteTableId', '')
    _rt_vpc = _rt.get('VpcId', '')
    _rt_routes[_rt_id] = _rt.get('Routes', []) or []
    for _assoc in (_rt.get('Associations') or []):
        if _assoc.get('Main'):
            _vpc_to_main_rt[_rt_vpc] = _rt_id
        elif _assoc.get('SubnetId'):
            _subnet_to_rt[_assoc['SubnetId']] = _rt_id

def _rt_is_public(rt_id):
    for route in (_rt_routes.get(rt_id) or []):
        if (route.get('DestinationCidrBlock') == '0.0.0.0/0'
                and route.get('GatewayId', '') in _igw_ids):
            return True
    return False

_subnets = (load_json('ec2-subnets.json', {}) or {}).get('Subnets', []) or []
subnet_classification = {}
for _sn in _subnets:
    _sn_id = _sn.get('SubnetId', '')
    _vpc_id = _sn.get('VpcId', '')
    _rt_id = _subnet_to_rt.get(_sn_id) or _vpc_to_main_rt.get(_vpc_id, '')
    _name = next((t.get('Value', '') for t in (_sn.get('Tags') or [])
                  if t.get('Key') == 'Name'), '')
    subnet_classification[_sn_id] = {
        'vpc_id': _vpc_id,
        'az': _sn.get('AvailabilityZone', ''),
        'cidr': _sn.get('CidrBlock', ''),
        'name': _name,
        'is_public': _rt_is_public(_rt_id),
        'map_public_ip_on_launch': _sn.get('MapPublicIpOnLaunch', False),
        'route_table_id': _rt_id,
    }
(derived / 'subnet_classification.json').write_text(json.dumps(subnet_classification, indent=2) + '\n')
summary['derived_subnet_count'] = len(subnet_classification)

# --- derived/task_eni_map.json ---
_enis = (load_json('ec2-network-interfaces.json', {}) or {}).get('NetworkInterfaces', []) or []
_eni_lookup = {
    eni.get('NetworkInterfaceId', ''): {
        'private_ip': eni.get('PrivateIpAddress', ''),
        'subnet_id': eni.get('SubnetId', ''),
        'vpc_id': eni.get('VpcId', ''),
        'security_groups': [g.get('GroupId', '') for g in (eni.get('Groups') or [])],
    }
    for eni in _enis if eni.get('NetworkInterfaceId')
}
task_eni_map = {}
for _rec in load_ndjson('ecs-tasks.ndjson'):
    _cluster = _rec.get('cluster', '')
    for _task in ((_rec.get('data') or {}).get('tasks') or []):
        _task_arn = _task.get('taskArn', '')
        if not _task_arn:
            continue
        _eni_id = ''
        for _attach in (_task.get('attachments') or []):
            if _attach.get('type') == 'ElasticNetworkInterface':
                for _detail in (_attach.get('details') or []):
                    if _detail.get('name') == 'networkInterfaceId':
                        _eni_id = _detail.get('value', '')
                        break
        if not _eni_id:
            continue
        _eni_info = _eni_lookup.get(_eni_id, {})
        task_eni_map[_task_arn] = {
            'cluster_arn': _cluster,
            'task_definition_arn': _task.get('taskDefinitionArn', ''),
            'eni_id': _eni_id,
            'private_ip': _eni_info.get('private_ip', ''),
            'subnet_id': _eni_info.get('subnet_id', ''),
            'vpc_id': _eni_info.get('vpc_id', ''),
            'security_groups': _eni_info.get('security_groups', []),
            'last_status': _task.get('lastStatus', ''),
        }
(derived / 'task_eni_map.json').write_text(json.dumps(task_eni_map, indent=2) + '\n')
summary['derived_task_eni_count'] = len(task_eni_map)

# --- derived/nat_gateway_eips.json ---
_eips = (load_json('ec2-addresses.json', {}) or {}).get('Addresses', []) or []
_eip_by_alloc = {eip.get('AllocationId', ''): eip for eip in _eips if eip.get('AllocationId')}
_nat_gws = (load_json('ec2-nat-gateways.json', {}) or {}).get('NatGateways', []) or []
nat_gateway_eips = {}
for _ngw in _nat_gws:
    _ngw_id = _ngw.get('NatGatewayId', '')
    if not _ngw_id:
        continue
    _eip_entries = []
    for _addr in (_ngw.get('NatGatewayAddresses') or []):
        _alloc_id = _addr.get('AllocationId', '')
        _eip_data = _eip_by_alloc.get(_alloc_id, {})
        _eip_entries.append({
            'allocation_id': _alloc_id,
            'public_ip': _addr.get('PublicIp', '') or _eip_data.get('PublicIp', ''),
            'private_ip': _addr.get('PrivateIp', ''),
            'network_interface_id': _addr.get('NetworkInterfaceId', ''),
        })
    nat_gateway_eips[_ngw_id] = {
        'subnet_id': _ngw.get('SubnetId', ''),
        'vpc_id': _ngw.get('VpcId', ''),
        'state': _ngw.get('State', ''),
        'connectivity_type': _ngw.get('ConnectivityType', 'public'),
        'eips': _eip_entries,
    }
(derived / 'nat_gateway_eips.json').write_text(json.dumps(nat_gateway_eips, indent=2) + '\n')
summary['derived_nat_gateway_count'] = len(nat_gateway_eips)

# --- derived/vpc_endpoint_routes.json ---
_rt_to_subnets = {}
for _rt in _route_tables:
    _rt_id = _rt.get('RouteTableId', '')
    _rt_to_subnets[_rt_id] = [
        _a['SubnetId'] for _a in (_rt.get('Associations') or []) if _a.get('SubnetId')
    ]
_endpoints = (load_json('ec2-vpc-endpoints.json', {}) or {}).get('VpcEndpoints', []) or []
vpc_endpoint_routes = {}
for _ep in _endpoints:
    _ep_id = _ep.get('VpcEndpointId', '')
    if not _ep_id:
        continue
    _ep_type = _ep.get('VpcEndpointType', '')
    if _ep_type == 'Gateway':
        _rt_ids = _ep.get('RouteTableIds') or []
        _subnets_via = list({s for r in _rt_ids for s in _rt_to_subnets.get(r, [])})
        vpc_endpoint_routes[_ep_id] = {
            'service': _ep.get('ServiceName', ''),
            'vpc_id': _ep.get('VpcId', ''),
            'type': 'Gateway',
            'state': _ep.get('State', ''),
            'route_table_ids': _rt_ids,
            'subnets_routed_through': _subnets_via,
            'subnet_ids': [],
            'dns_entries': [],
        }
    else:
        vpc_endpoint_routes[_ep_id] = {
            'service': _ep.get('ServiceName', ''),
            'vpc_id': _ep.get('VpcId', ''),
            'type': _ep_type,
            'state': _ep.get('State', ''),
            'route_table_ids': [],
            'subnets_routed_through': [],
            'subnet_ids': _ep.get('SubnetIds') or [],
            'dns_entries': [d.get('DnsName', '') for d in (_ep.get('DnsEntries') or [])],
        }
(derived / 'vpc_endpoint_routes.json').write_text(json.dumps(vpc_endpoint_routes, indent=2) + '\n')
summary['derived_vpc_endpoint_count'] = len(vpc_endpoint_routes)

# --- derived/stepfunctions_resource_refs.json ---
def _parse_asl_state(state_name, state):
    resource_uri = state.get('Resource', '')
    params = state.get('Parameters') or {}
    if not resource_uri:
        return None
    base = {'state_name': state_name, 'resource_uri': resource_uri}
    if resource_uri.startswith('arn:aws:lambda:'):
        return {**base, 'resource_type': 'lambda', 'resource_arn': resource_uri}
    if ':::' in resource_uri:
        service = resource_uri.split(':::')[1].split(':')[0]
        if service == 'lambda':
            return {**base, 'resource_type': 'lambda',
                    'resource_arn': params.get('FunctionName', '')}
        if service == 'ecs':
            return {**base, 'resource_type': 'ecs_task',
                    'task_definition': params.get('TaskDefinition', ''),
                    'cluster': params.get('Cluster', '')}
        if service == 'dynamodb':
            return {**base, 'resource_type': 'dynamodb',
                    'table_name': params.get('TableName', '')}
        if service == 'sqs':
            return {**base, 'resource_type': 'sqs',
                    'queue_url': params.get('QueueUrl', '')}
        if service == 'sns':
            return {**base, 'resource_type': 'sns',
                    'topic_arn': params.get('TopicArn', '')}
        if service == 'states':
            return {**base, 'resource_type': 'stepfunctions',
                    'state_machine_arn': params.get('StateMachineArn', '')}
        if service == 'apigateway':
            return {**base, 'resource_type': 'apigateway',
                    'api_endpoint': params.get('ApiEndpoint', '')}
        if service == 'events':
            return {**base, 'resource_type': 'eventbridge'}
        return {**base, 'resource_type': service}
    return {**base, 'resource_type': 'unknown'}

def _collect_asl_states(states_dict, prefix=''):
    refs = []
    for state_name, state in (states_dict or {}).items():
        full_name = f'{prefix}{state_name}' if prefix else state_name
        if state.get('Type') == 'Task':
            ref = _parse_asl_state(full_name, state)
            if ref:
                refs.append(ref)
        elif state.get('Type') == 'Map':
            _iter = state.get('Iterator') or state.get('ItemProcessor') or {}
            refs.extend(_collect_asl_states(_iter.get('States', {}), f'{full_name}/'))
        elif state.get('Type') == 'Parallel':
            for _branch in (state.get('Branches') or []):
                refs.extend(_collect_asl_states(_branch.get('States', {}), f'{full_name}/'))
    return refs

sf_resource_refs = {}
for _rec in load_ndjson('stepfunctions-state-machine-details.ndjson'):
    _sm_arn = _rec.get('state_machine_arn', '')
    _sm_data = _rec.get('data') or {}
    _def_str = _sm_data.get('definition', '')
    if not _sm_arn or not _def_str:
        continue
    try:
        _asl = json.loads(_def_str)
    except Exception:
        continue
    sf_resource_refs[_sm_arn] = {
        'name': _sm_data.get('name', ''),
        'type': _sm_data.get('type', ''),
        'role_arn': _sm_data.get('roleArn', ''),
        'resource_refs': _collect_asl_states(_asl.get('States', {})),
    }
(derived / 'stepfunctions_resource_refs.json').write_text(json.dumps(sf_resource_refs, indent=2) + '\n')
summary['derived_sf_state_machines'] = len(sf_resource_refs)

# --- derived/pipeline_chains.json ---
def _pipeline_action_ref(stage_name, action):
    cat = (action.get('actionTypeId') or {}).get('category', '')
    provider = (action.get('actionTypeId') or {}).get('provider', '')
    config = action.get('configuration') or {}
    base = {'stage': stage_name, 'action': action.get('name', ''),
            'category': cat, 'provider': provider}
    if cat == 'Source':
        if provider in ('GitHub', 'GitHub Version 2'):
            return {**base, 'resource_type': 'github',
                    'owner': config.get('Owner', ''), 'repo': config.get('Repo', ''),
                    'branch': config.get('Branch', '')}
        if provider == 'CodeStarSourceConnection':
            return {**base, 'resource_type': 'codestar_connection',
                    'connection_arn': config.get('ConnectionArn', ''),
                    'repo': config.get('FullRepositoryId', ''),
                    'branch': config.get('BranchName', '')}
        if provider == 'CodeCommit':
            return {**base, 'resource_type': 'codecommit',
                    'repo': config.get('RepositoryName', ''),
                    'branch': config.get('BranchName', '')}
        if provider == 'S3':
            return {**base, 'resource_type': 's3_source',
                    'bucket': config.get('S3Bucket', ''),
                    'key': config.get('S3ObjectKey', '')}
        if provider == 'ECR':
            return {**base, 'resource_type': 'ecr',
                    'repository': config.get('RepositoryName', ''),
                    'image_tag': config.get('ImageTag', '')}
    if cat == 'Build' and provider == 'CodeBuild':
        return {**base, 'resource_type': 'codebuild',
                'project': config.get('ProjectName', '')}
    if cat == 'Deploy':
        if provider == 'CodeDeploy':
            return {**base, 'resource_type': 'codedeploy',
                    'application': config.get('ApplicationName', ''),
                    'deployment_group': config.get('DeploymentGroupName', '')}
        if provider == 'ECS':
            return {**base, 'resource_type': 'ecs_service',
                    'cluster': config.get('ClusterName', ''),
                    'service': config.get('ServiceName', '')}
        if provider == 'S3':
            return {**base, 'resource_type': 's3_deploy',
                    'bucket': config.get('BucketName', '')}
    if cat == 'Invoke' and provider == 'Lambda':
        return {**base, 'resource_type': 'lambda',
                'function': config.get('FunctionName', '')}
    if cat == 'Approval':
        return {**base, 'resource_type': 'approval',
                'notification_arn': config.get('NotificationArn', '')}
    return {**base, 'resource_type': 'other'}

pipeline_chains = {}
for _rec in load_ndjson('codepipeline-pipeline-details.ndjson'):
    _pl_name = _rec.get('pipeline_name', '')
    _pl = (_rec.get('data') or {}).get('pipeline') or {}
    if not _pl_name:
        continue
    _art = _pl.get('artifactStore') or {}
    _refs = []
    _stages_out = []
    for _stage in (_pl.get('stages') or []):
        _sn = _stage.get('name', '')
        for _action in (_stage.get('actions') or []):
            _ref = _pipeline_action_ref(_sn, _action)
            if _ref:
                _refs.append(_ref)
        _stages_out.append({
            'name': _sn,
            'actions': [{'name': a.get('name', ''),
                         'category': (a.get('actionTypeId') or {}).get('category', ''),
                         'provider': (a.get('actionTypeId') or {}).get('provider', '')}
                        for a in (_stage.get('actions') or [])],
        })
    pipeline_chains[_pl_name] = {
        'artifact_store_bucket': _art.get('location', ''),
        'artifact_store_type': _art.get('type', ''),
        'stages': _stages_out,
        'resource_refs': _refs,
    }
(derived / 'pipeline_chains.json').write_text(json.dumps(pipeline_chains, indent=2) + '\n')
summary['derived_pipeline_chains'] = len(pipeline_chains)

# --- derived/dynamodb_stream_consumers.json ---
_esms = (load_json('lambda-event-source-mappings.json', {}) or {}).get('EventSourceMappings', []) or []
_stream_to_lambdas = {}
for _esm in _esms:
    _esa = _esm.get('EventSourceArn', '')
    if _esa and '/stream/' in _esa and ':dynamodb:' in _esa:
        _stream_to_lambdas.setdefault(_esa, []).append({
            'function_arn': _esm.get('FunctionArn', ''),
            'state': _esm.get('State', ''),
            'batch_size': _esm.get('BatchSize'),
            'starting_position': _esm.get('StartingPosition', ''),
            'maximum_retry_attempts': _esm.get('MaximumRetryAttempts'),
            'bisect_batch_on_error': _esm.get('BisectBatchOnFunctionError', False),
        })
dynamodb_stream_consumers = {}
for _rec in load_ndjson('dynamodb-table-details.ndjson'):
    _tbl = (_rec.get('data') or {}).get('Table') or {}
    _stream_arn = _tbl.get('LatestStreamArn', '')
    if not _stream_arn:
        continue
    _consumers = _stream_to_lambdas.get(_stream_arn, [])
    if _consumers:
        dynamodb_stream_consumers[_stream_arn] = {
            'table_name': _tbl.get('TableName', ''),
            'table_arn': _tbl.get('TableArn', ''),
            'lambda_consumers': _consumers,
        }
(derived / 'dynamodb_stream_consumers.json').write_text(json.dumps(dynamodb_stream_consumers, indent=2) + '\n')
summary['derived_dynamodb_stream_consumers'] = len(dynamodb_stream_consumers)

# --- derived/iam_role_resource_access.json ---
def _parse_policy_doc(doc):
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, str):
        try:
            return json.loads(urllib.parse.unquote(doc))
        except Exception:
            try:
                return json.loads(doc)
            except Exception:
                return None
    return None

def _extract_allow_stmts(document, source, policy_name):
    stmts = []
    if not isinstance(document, dict):
        return stmts
    stmts_raw = document.get('Statement') or []
    if isinstance(stmts_raw, dict):
        stmts_raw = [stmts_raw]
    for stmt in stmts_raw:
        if not isinstance(stmt, dict):
            continue
        if stmt.get('Effect') != 'Allow':
            continue
        actions = stmt.get('Action', [])
        if isinstance(actions, str):
            actions = [actions]
        resources = stmt.get('Resource', [])
        if isinstance(resources, str):
            resources = [resources]
        services = ['*'] if '*' in actions else sorted(
            {a.split(':')[0].lower() for a in actions if ':' in a})
        stmts.append({'source': source, 'policy_name': policy_name,
                      'actions': actions, 'resources': resources, 'services': services})
    return stmts

def _build_svc_access(stmts):
    svc_map = {}
    for stmt in stmts:
        for svc in (stmt.get('services') or []):
            svc_map.setdefault(svc, set()).update(stmt.get('resources') or [])
    return {svc: sorted(res) for svc, res in sorted(svc_map.items())}

_cust_policy_docs = {}
for _rec in load_ndjson('iam-local-policy-versions.ndjson'):
    _arn = _rec.get('policy_arn', '')
    _doc = (_rec.get('data') or {}).get('PolicyVersion', {}).get('Document')
    if _arn and _doc is not None:
        _cust_policy_docs[_arn] = _parse_policy_doc(_doc)

_role_managed = {}
for _rec in load_ndjson('iam-role-details.ndjson'):
    _rn = _rec.get('role_name', '')
    _ml = (_rec.get('managed') or {}).get('AttachedPolicies') or []
    if _rn:
        _role_managed[_rn] = [p.get('PolicyArn', '') for p in _ml]

_role_inlines = {}
for _rec in load_ndjson('iam-role-inline-policies.ndjson'):
    _rn = _rec.get('role_name', '')
    _doc = (_rec.get('data') or {}).get('PolicyDocument')
    if _rn and _doc is not None:
        _role_inlines.setdefault(_rn, []).append(
            {'policy_name': _rec.get('policy_name', ''), 'document': _parse_policy_doc(_doc)})

iam_role_resource_access = {}
for _rn in sorted(set(list(_role_managed) + list(_role_inlines))):
    _all_stmts = []
    for _ip in (_role_inlines.get(_rn) or []):
        _all_stmts.extend(_extract_allow_stmts(_ip['document'], 'inline', _ip['policy_name']))
    _unanalyzed = []
    for _parn in (_role_managed.get(_rn) or []):
        _pdoc = _cust_policy_docs.get(_parn)
        if _pdoc is not None:
            _all_stmts.extend(_extract_allow_stmts(_pdoc, 'managed', _parn.split('/')[-1]))
        else:
            _unanalyzed.append(_parn)
    if not _all_stmts and not _unanalyzed:
        continue
    iam_role_resource_access[_rn] = {
        'service_access': _build_svc_access(_all_stmts),
        'allow_statements': _all_stmts,
        'unanalyzed_managed_policies': _unanalyzed,
    }
(derived / 'iam_role_resource_access.json').write_text(
    json.dumps(iam_role_resource_access, indent=2) + '\n')
summary['derived_iam_roles_analyzed'] = len(iam_role_resource_access)

# --- derived/ec2_instance_roles.json ---
_ip_arn_to_profile = {}
for _ip in ((load_json('iam-instance-profiles.json', {}) or {}).get('InstanceProfiles') or []):
    _ip_arn = _ip.get('Arn', '')
    if _ip_arn:
        _ip_arn_to_profile[_ip_arn] = {
            'profile_name': _ip.get('InstanceProfileName', ''),
            'roles': [{'role_name': r.get('RoleName', ''), 'role_arn': r.get('Arn', '')}
                      for r in (_ip.get('Roles') or [])],
        }
ec2_instance_roles = {}
for _res in ((load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations') or []):
    for _inst in (_res.get('Instances') or []):
        _inst_id = _inst.get('InstanceId', '')
        if not _inst_id:
            continue
        _ip_arn = (_inst.get('IamInstanceProfile') or {}).get('Arn', '')
        _profile = _ip_arn_to_profile.get(_ip_arn, {})
        _role_names = [r['role_name'] for r in (_profile.get('roles') or [])]
        _cluster = next((t.get('Value', '') for t in (_inst.get('Tags') or [])
                         if t.get('Key') == 'aws:ecs:cluster-name'), '')
        ec2_instance_roles[_inst_id] = {
            'instance_profile_arn': _ip_arn,
            'profile_name': _profile.get('profile_name', ''),
            'roles': _profile.get('roles', []),
            'role_service_access': {
                rn: iam_role_resource_access.get(rn, {}).get('service_access', {})
                for rn in _role_names
            },
            'ecs_cluster': _cluster,
            'instance_type': _inst.get('InstanceType', ''),
            'private_ip': _inst.get('PrivateIpAddress', ''),
            'subnet_id': _inst.get('SubnetId', ''),
        }
(derived / 'ec2_instance_roles.json').write_text(json.dumps(ec2_instance_roles, indent=2) + '\n')
summary['derived_ec2_instance_roles'] = len(ec2_instance_roles)

# --- derived/codebuild_role_access.json ---
codebuild_role_access = {}
for _rec in load_ndjson('codebuild-project-details.ndjson'):
    _proj = _rec.get('name', '')
    _role_arn = _rec.get('serviceRole', '')
    if not _proj:
        continue
    _role_name = _role_arn.split('/')[-1] if '/' in _role_arn else ''
    _role_access = iam_role_resource_access.get(_role_name, {})
    _src = _rec.get('source') or {}
    _art = _rec.get('artifacts') or {}
    codebuild_role_access[_proj] = {
        'service_role_arn': _role_arn,
        'role_name': _role_name,
        'source': {'type': _src.get('type', ''), 'location': _src.get('location', '')},
        'artifacts': {'type': _art.get('type', ''), 'location': _art.get('location', '')},
        'service_access': _role_access.get('service_access', {}),
        'unanalyzed_managed_policies': _role_access.get('unanalyzed_managed_policies', []),
    }
(derived / 'codebuild_role_access.json').write_text(
    json.dumps(codebuild_role_access, indent=2) + '\n')
summary['derived_codebuild_projects_analyzed'] = len(codebuild_role_access)

# --- derived/iam_role_trust_analysis.json ---
def _parse_principal_list(val):
    if isinstance(val, str):
        return [val]
    return val if isinstance(val, list) else []

def _extract_trust_principals(trust_doc):
    result = {'trusted_services': set(), 'trusted_accounts': set(),
              'trusted_roles': set(), 'federated_principals': set()}
    stmts_raw = trust_doc.get('Statement') or []
    if isinstance(stmts_raw, dict):
        stmts_raw = [stmts_raw]
    for stmt in stmts_raw:
        if not isinstance(stmt, dict):
            continue
        if stmt.get('Effect') != 'Allow':
            continue
        _p = stmt.get('Principal', {})
        if isinstance(_p, str):
            result['trusted_accounts'].add(_p)
            continue
        for _s in _parse_principal_list(_p.get('Service', [])):
            if _s:
                result['trusted_services'].add(_s)
        for _a in _parse_principal_list(_p.get('AWS', [])):
            if not _a:
                continue
            if ':role/' in _a or ':assumed-role/' in _a:
                result['trusted_roles'].add(_a)
            else:
                result['trusted_accounts'].add(_a)
        for _f in _parse_principal_list(_p.get('Federated', [])):
            if _f:
                result['federated_principals'].add(_f)
    return {k: sorted(v) for k, v in result.items()}

iam_role_trust_analysis = {}
for _rec in load_ndjson('iam-role-details.ndjson'):
    _rn = _rec.get('role_name', '')
    _role_data = (_rec.get('trust') or {}).get('Role') or {}
    _trust_doc = _role_data.get('AssumeRolePolicyDocument')
    if not _rn or not _trust_doc:
        continue
    _parsed = _parse_policy_doc(_trust_doc) if not isinstance(_trust_doc, dict) else _trust_doc
    if not _parsed:
        continue
    _principals = _extract_trust_principals(_parsed)
    iam_role_trust_analysis[_rn] = {'role_arn': _role_data.get('Arn', ''), **_principals}
(derived / 'iam_role_trust_analysis.json').write_text(json.dumps(iam_role_trust_analysis, indent=2) + '\n')
summary['derived_iam_trust_analyzed'] = len(iam_role_trust_analysis)

# --- derived/apigw_auth_chain.json ---
_cognito_pool_map = {}
for _rec in load_ndjson('cognito-user-pool-details.ndjson'):
    _pd = (_rec.get('data') or {}).get('UserPool') or {}
    _pid = _pd.get('Id', '') or _rec.get('user_pool_id', '')
    if _pid:
        _cognito_pool_map[_pid] = {'name': _pd.get('Name', ''), 'arn': _pd.get('Arn', ''),
                                   'mfa': _pd.get('MfaConfiguration', '')}

def _pool_id_from_issuer(issuer):
    parts = issuer.rstrip('/').split('/')
    return parts[-1] if parts else ''

apigw_auth_chain = {}
for _rec in load_ndjson('apigwv2-authorizers.ndjson'):
    _api_id = _rec.get('api_id', '')
    for _auth in ((_rec.get('data') or {}).get('Items') or []):
        _auth_id = _auth.get('AuthorizerId', '')
        _atype = _auth.get('AuthorizerType', '')
        entry = {'api_id': _api_id, 'authorizer_id': _auth_id,
                 'name': _auth.get('Name', ''), 'type': _atype}
        if _atype == 'JWT':
            _jwt = _auth.get('JwtConfiguration') or {}
            _issuer = _jwt.get('Issuer', '')
            entry['issuer'] = _issuer
            entry['audience'] = _jwt.get('Audience') or []
            if 'cognito-idp' in _issuer:
                _pid = _pool_id_from_issuer(_issuer)
                entry['cognito_pool_id'] = _pid
                entry['cognito_pool'] = _cognito_pool_map.get(_pid, {})
        elif _atype == 'REQUEST':
            entry['authorizer_uri'] = _auth.get('AuthorizerUri', '')
        apigw_auth_chain[f'{_api_id}/{_auth_id}'] = entry
(derived / 'apigw_auth_chain.json').write_text(json.dumps(apigw_auth_chain, indent=2) + '\n')
summary['derived_apigw_auth_chains'] = len(apigw_auth_chain)

# --- derived/sqs_dlq_chains.json ---
sqs_dlq_chains = {}
for _rec in load_ndjson('sqs-queue-attributes.ndjson'):
    _url = _rec.get('queue_url', '')
    _attrs = (_rec.get('data') or {}).get('Attributes') or {}
    _rp_raw = _attrs.get('RedrivePolicy', '')
    if not _rp_raw or not _url:
        continue
    try:
        _rp = json.loads(_rp_raw)
    except Exception:
        continue
    _dlq_arn = _rp.get('deadLetterTargetArn', '')
    if _dlq_arn:
        _q_arn = _attrs.get('QueueArn', _url)
        sqs_dlq_chains[_q_arn] = {
            'queue_url': _url,
            'queue_name': _url.split('/')[-1] if '/' in _url else _url,
            'dlq_arn': _dlq_arn,
            'max_receive_count': _rp.get('maxReceiveCount'),
        }
(derived / 'sqs_dlq_chains.json').write_text(json.dumps(sqs_dlq_chains, indent=2) + '\n')
summary['derived_sqs_dlq_count'] = len(sqs_dlq_chains)

# --- derived/sg_members.json ---
def _add_sg_member(sg_map, sg_id, rtype, rid, extra=None):
    if not sg_id or not rid:
        return
    entry = {'resource_type': rtype, 'resource_id': rid}
    if extra:
        entry.update(extra)
    sg_map.setdefault(sg_id, []).append(entry)

sg_members = {}

for _r in load_ndjson('ecs-services.ndjson'):
    for _s in ((_r.get('data') or {}).get('services') or []):
        _sa = _s.get('serviceArn', '')
        for _sg in (((_s.get('networkConfiguration') or {}).get('awsvpcConfiguration') or {}).get('securityGroups') or []):
            _add_sg_member(sg_members, _sg, 'ecs_service', _sa, {'name': _s.get('serviceName', '')})

_tem_path = derived / 'task_eni_map.json'
if _tem_path.exists():
    for _task_arn, _ti in (json.loads(_tem_path.read_text()) or {}).items():
        for _sg in (_ti.get('security_groups') or []):
            _add_sg_member(sg_members, _sg, 'ecs_task', _task_arn,
                           {'last_status': _ti.get('last_status', '')})

for _i in ((load_json('rds-db-instances.json', {}) or {}).get('DBInstances') or []):
    _id = _i.get('DBInstanceIdentifier', '')
    for _sg in (_i.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'rds_instance', _id)

for _c in ((load_json('rds-db-clusters.json', {}) or {}).get('DBClusters') or []):
    _id = _c.get('DBClusterIdentifier', '')
    for _sg in (_c.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'rds_cluster', _id)

for _px in ((load_json('rds-db-proxies.json', {}) or {}).get('DBProxies') or []):
    for _sg in (_px.get('VpcSecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'rds_proxy', _px.get('DBProxyName', ''))

for _rg in ((load_json('elasticache-replication-groups.json', {}) or {}).get('ReplicationGroups') or []):
    _id = _rg.get('ReplicationGroupId', '')
    for _sg in (_rg.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('SecurityGroupId', ''), 'elasticache', _id)

for _sc in ((load_json('elasticache-serverless-caches.json', {}) or {}).get('ServerlessCaches') or []):
    for _sg in (_sc.get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'elasticache_serverless', _sc.get('ServerlessCacheName', ''))

for _cl in ((load_json('memorydb-clusters.json', {}) or {}).get('Clusters') or []):
    _id = _cl.get('Name', '')
    for _sg in (_cl.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('SecurityGroupId', ''), 'memorydb_cluster', _id)

for _lb in ((load_json('elbv2-load-balancers.json', {}) or {}).get('LoadBalancers') or []):
    _id = _lb.get('LoadBalancerArn', '')
    for _sg in (_lb.get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'load_balancer', _id, {'name': _lb.get('LoadBalancerName', '')})

for _fn in ((load_json('lambda-functions.json', {}) or {}).get('Functions') or []):
    _id = _fn.get('FunctionArn', '')
    for _sg in ((_fn.get('VpcConfig') or {}).get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'lambda', _id, {'name': _fn.get('FunctionName', '')})

for _cl in ((load_json('redshift-clusters.json', {}) or {}).get('Clusters') or []):
    _id = _cl.get('ClusterIdentifier', '')
    for _sg in (_cl.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'redshift_cluster', _id)

for _rec in load_ndjson('redshift-serverless-workgroup-details.ndjson'):
    _wg = (_rec.get('data') or {}).get('workgroup') or {}
    _id = _wg.get('workgroupName', '') or _rec.get('workgroup_name', '')
    for _sg in (_wg.get('securityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'redshift_serverless_workgroup', _id)

for _cl in ((load_json('docdb-clusters.json', {}) or {}).get('DBClusters') or []):
    _id = _cl.get('DBClusterIdentifier', '')
    for _sg in (_cl.get('VpcSecurityGroups') or []):
        _add_sg_member(sg_members, _sg.get('VpcSecurityGroupId', ''), 'docdb_cluster', _id)

for _rec in load_ndjson('kafka-cluster-details.ndjson'):
    _arn = _rec.get('cluster_arn', '')
    _ci = (_rec.get('data') or {}).get('ClusterInfo') or {}
    for _sg in ((_ci.get('Provisioned') or {}).get('BrokerNodeGroupInfo', {}).get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'msk_cluster', _arn)
    for _vc in ((_ci.get('Serverless') or {}).get('VpcConfigs') or []):
        for _sg in (_vc.get('SecurityGroupIds') or []):
            _add_sg_member(sg_members, _sg, 'msk_serverless', _arn)

for _res in ((load_json('ec2-instances-ecs.json', {}) or {}).get('Reservations') or []):
    for _inst in (_res.get('Instances') or []):
        _id = _inst.get('InstanceId', '')
        for _sg in (_inst.get('SecurityGroups') or []):
            _add_sg_member(sg_members, _sg.get('GroupId', ''), 'ec2_instance', _id)

for _rec in load_ndjson('opensearch-domain-details.ndjson'):
    _d = _rec.get('domain_name', '')
    for _sg in (((_rec.get('data') or {}).get('DomainStatus') or {}).get('VPCOptions', {}).get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'opensearch_domain', _d)

for _rec in load_ndjson('efs-mount-target-sgs.ndjson'):
    _mt = _rec.get('mount_target_id', '')
    _fs = _rec.get('file_system_id', '')
    for _sg in ((_rec.get('data') or {}).get('SecurityGroups') or []):
        _add_sg_member(sg_members, _sg, 'efs_mount_target', _mt, {'file_system_id': _fs})

for _vl in ((load_json('apigwv2-vpc-links.json', {}) or {}).get('Items') or []):
    _id = _vl.get('VpcLinkId', '')
    for _sg in (_vl.get('SecurityGroupIds') or []):
        _add_sg_member(sg_members, _sg, 'api_gateway_vpc_link', _id)

(derived / 'sg_members.json').write_text(json.dumps(sg_members, indent=2) + '\n')
summary['derived_sg_member_entries'] = sum(len(v) for v in sg_members.values())

(derived / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
(derived / 'README.md').write_text(
    '\n'.join([
        '# AWS Infra Snapshot Summary',
        '',
        f'- ECS clusters: {summary["ecs_cluster_count"]}',
        f'- ECS task definitions: {summary["ecs_task_definition_count"]}',
        f'- Load balancers: {summary["load_balancer_count"]}',
        f'- Target groups: {summary["target_group_count"]}',
        f'- VPCs: {summary["vpc_count"]}',
        f'- Subnets: {summary["subnet_count"]}',
        f'- Security groups: {summary["security_group_count"]}',
        f'- RDS instances: {summary["rds_instance_count"]}',
        f'- RDS proxies: {summary["rds_proxy_count"]}',
        f'- EC2 ECS container instances: {summary["ec2_ecs_instance_count"]}',
        f'- RDS snapshots: {summary["rds_snapshot_count"]}',
        f'- Redshift clusters: {summary["redshift_cluster_count"]}',
        f'- Redshift Serverless workgroups: {summary["redshift_serverless_workgroup_count"]}',
        f'- Redshift Serverless namespaces: {summary["redshift_serverless_namespace_count"]}',
        f'- EFS file systems: {summary["efs_file_system_count"]}',
        f'- S3 buckets: {summary["s3_bucket_count"]}',
        f'- DynamoDB tables: {summary["dynamodb_table_count"]}',
        f'- DocumentDB clusters: {summary["docdb_cluster_count"]}',
        f'- Lambda functions: {summary["lambda_function_count"]}',
        f'- Lambda event source mappings: {summary["lambda_event_source_mapping_count"]}',
        f'- API Gateway REST APIs (v1): {summary["apigw_rest_api_count"]}',
        f'- API Gateway HTTP/WebSocket APIs (v2): {summary["apigwv2_api_count"]}',
        f'- Cognito user pools: {summary["cognito_user_pool_count"]}',
        f'- ECR repositories: {summary["ecr_repository_count"]}',
        f'- ACM certificates: {summary["acm_certificate_count"]}',
        f'- WAFv2 WebACLs: {summary["wafv2_webacl_count"]}',
        f'- CloudFront distributions: {summary["cloudfront_distribution_count"]}',
        f'- EC2 Auto Scaling Groups: {summary["asg_count"]}',
        f'- Launch templates: {summary["launch_template_count"]}',
        f'- CloudWatch log groups: {summary["log_group_count"]}',
        f'- CloudWatch alarms: {summary["cloudwatch_alarm_count"]}',
        f'- SQS queues: {summary["sqs_queue_count"]}',
        f'- SNS topics: {summary["sns_topic_count"]}',
        f'- EventBridge buses: {summary["eventbridge_bus_count"]}',
        f'- Step Functions state machines: {summary["stepfunctions_count"]}',
        f'- MSK clusters: {summary["msk_cluster_count"]}',
        f'- Kinesis streams: {summary["kinesis_stream_count"]}',
        f'- Firehose delivery streams: {summary["firehose_stream_count"]}',
        f'- OpenSearch domains: {summary["opensearch_domain_count"]}',
        f'- CodeBuild projects: {summary["codebuild_project_count"]}',
        f'- CodePipeline pipelines: {summary["codepipeline_count"]}',
        f'- CodeDeploy applications: {summary["codedeploy_application_count"]}',
        f'- KMS keys: {summary["kms_key_count"]}',
        f'- CloudTrail trails: {summary["cloudtrail_trail_count"]}',
        f'- GuardDuty detectors: {summary["guardduty_detector_count"]}',
        f'- IAM users: {summary["iam_user_count"]}',
        f'- IAM groups: {summary["iam_group_count"]}',
        f'- IAM customer-managed policies: {summary["iam_local_policy_count"]}',
        f'- Access Analyzer analyzers: {summary["accessanalyzer_count"]}',
        f'- Secrets: {summary["secret_count"]}',
        f'- Route53 hosted zones: {summary["hosted_zone_count"]}',
        f'- Route53 health checks: {summary["route53_health_check_count"]}',
        f'- Elastic IPs: {summary["elastic_ip_count"]}',
        f'- VPC peering connections: {summary["vpc_peering_count"]}',
        f'- Route53 Resolver endpoints: {summary["resolver_endpoint_count"]}',
        f'- Secret refs mapped to consumers: {summary["mapped_secret_refs"]}',
        f'- SSM param refs mapped to consumers: {summary["mapped_param_refs"]}',
        f'- SG connectivity edges (derived): {summary["derived_sg_edges"]}',
        f'- ALB→service mappings (derived): {summary["derived_alb_mappings"]}',
        f'- ECS service topologies (derived): {summary["derived_service_topologies"]}',
        f'- CloudWatch alarm targets (derived): {summary["derived_alarm_targets"]}',
        f'- Subnets classified (derived): {summary["derived_subnet_count"]}',
        f'- ECS tasks with ENI mapped (derived): {summary["derived_task_eni_count"]}',
        f'- NAT gateways with EIPs (derived): {summary["derived_nat_gateway_count"]}',
        f'- VPC endpoint routes (derived): {summary["derived_vpc_endpoint_count"]}',
        f'- Step Functions resource refs (derived): {summary["derived_sf_state_machines"]}',
        f'- Pipeline chains (derived): {summary["derived_pipeline_chains"]}',
        f'- DynamoDB stream consumers (derived): {summary["derived_dynamodb_stream_consumers"]}',
        f'- IAM roles analyzed for access (derived): {summary["derived_iam_roles_analyzed"]}',
        f'- EC2 instances with roles mapped (derived): {summary["derived_ec2_instance_roles"]}',
        f'- CodeBuild projects with role access (derived): {summary["derived_codebuild_projects_analyzed"]}',
        f'- IAM role trust policies analyzed (derived): {summary["derived_iam_trust_analyzed"]}',
        f'- API Gateway auth chains (derived): {summary["derived_apigw_auth_chains"]}',
        f'- SQS queues with DLQ (derived): {summary["derived_sqs_dlq_count"]}',
        f'- SG member entries across all resources (derived): {summary["derived_sg_member_entries"]}',
        '',
        'This summary is intentionally compact. Use the raw/*.json and raw/*.ndjson files for full detail.',
    ]) + '\n'
)

print(f"Done. Wrote {len(list(derived.iterdir()))} files to {derived}")
PY

echo "[$(date '+%H:%M:%S')] Done."
