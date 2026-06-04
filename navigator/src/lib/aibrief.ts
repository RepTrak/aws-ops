import type { ResourceNodeData } from '@/types/graph'
import type { SnapshotData } from '@/types/snapshot'

export function generateAIBrief(
  nodeId: string,
  data: ResourceNodeData,
  snap: SnapshotData,
): string {
  const lines: string[] = []
  const push = (...ss: string[]) => lines.push(...ss)

  push(`## AWS Resource Brief: ${data.label}`)
  push(`**Type:** ${data.resourceType.replace(/_/g, ' ').toUpperCase()}`)
  push('')

  // Identity
  push('### Identity')
  data.metadata.forEach(m => push(`- **${m.key}:** ${m.value}`))
  push('')

  // Relationships
  const byType = data.relationships.reduce<Record<string, typeof data.relationships>>((acc, r) => {
    ;(acc[r.type] ??= []).push(r)
    return acc
  }, {})

  if (Object.keys(byType).length > 0) {
    push('### Relationships')
    for (const [type, rels] of Object.entries(byType)) {
      push(`**${type.toUpperCase()}**`)
      rels.forEach(r => push(`  - [${r.direction}] ${r.targetLabel}: ${r.description}`))
    }
    push('')
  }

  // Service-specific enrichment
  if (data.resourceType === 'ecs_service') {
    const svc = snap.serviceTopology[nodeId]
    if (svc) {
      push('### Containers')
      svc.containers.forEach(c => {
        push(`- **${c.name}** → \`${c.image}\``)
        if (c.log_group) push(`  Log group: ${c.log_group}`)
        if (c.port_mappings?.length) push(`  Ports: ${c.port_mappings.map(p => p.containerPort).join(', ')}`)
      })
      push('')
      if (svc.efs_volumes?.length) {
        push('### EFS Mounts')
        svc.efs_volumes.forEach(v => push(`- ${v.volume_name}: ${v.file_system_id}`))
        push('')
      }
    }

    const secrets = Object.entries(snap.secretConsumers ?? {})
      .filter(([, consumers]) => consumers.some(c => c.task_definition.startsWith(data.metadata.find(m => m.key === 'Task Definition')?.value?.split(':')[0] ?? '___')))
    if (secrets.length) {
      push('### Secrets Referenced')
      secrets.forEach(([ref]) => push(`- \`${ref}\``))
      push('')
    }
  }

  if (data.resourceType === 'iam_role') {
    const access = snap.iamRoleResourceAccess?.[data.label]
    if (access?.service_access) {
      push('### Service Access (Allow)')
      for (const [svc, resources] of Object.entries(access.service_access)) {
        push(`- **${svc}:** ${resources.slice(0, 3).join(', ')}${resources.length > 3 ? ` (+${resources.length - 3} more)` : ''}`)
      }
      push('')
      if (access.unanalyzed_managed_policies?.length) {
        push('> ⚠️ Unanalyzed AWS-managed policies:')
        access.unanalyzed_managed_policies.forEach(p => push(`> - ${p.split('/').pop()}`))
        push('')
      }
    }
    const trust = snap.iamRoleTrustAnalysis?.[data.label]
    if (trust) {
      push('### Trust Policy')
      if (trust.trusted_services?.length) push(`- **Services:** ${trust.trusted_services.join(', ')}`)
      if (trust.trusted_roles?.length) push(`- **Roles:** ${trust.trusted_roles.join(', ')}`)
      if (trust.federated_principals?.length) push(`- **Federated:** ${trust.federated_principals.join(', ')}`)
      push('')
    }
  }

  // AI instructions
  push('---')
  push('### For AI Agents')
  push('Copy this block and paste into your AI assistant to provide context for AWS CLI or IaC changes:')
  push('')
  push('```json')
  push(JSON.stringify({
    resource_type: data.resourceType,
    name: data.label,
    identifiers: Object.fromEntries(data.metadata.map(m => [m.key.toLowerCase().replace(/\s+/g, '_'), m.value])),
    relationships: data.relationships.map(r => ({ type: r.type, direction: r.direction, target: r.targetLabel, description: r.description })),
    status: data.status,
    snapshot_region: snap.manifest?.region ?? 'unknown',
    snapshot_time: snap.manifest?.timestamp_utc ?? 'unknown',
  }, null, 2))
  push('```')

  return lines.join('\n')
}
