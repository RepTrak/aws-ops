import type { FilterState } from '@/types/graph'
import { EDGE_COLORS } from '@/lib/colors'

interface Props {
  filters: FilterState
  onChange: (f: FilterState) => void
}

const FILTERS: { key: keyof FilterState; label: string; hint: string }[] = [
  {
    key: 'deployment',   label: 'Deployment',
    hint: 'Traffic routing & CI/CD chains — ALB → service, CodePipeline → ECS deploy, ECR image → task definition',
  },
  {
    key: 'dataflow',     label: 'Data Flow',
    hint: 'Data movement — service reads Secrets Manager / SSM, Lambda ← SQS event, DynamoDB stream → Lambda, SQS → DLQ',
  },
  {
    key: 'network',      label: 'Network',
    hint: 'SG-based connectivity — security group rule allows traffic from one resource to another (inferred from SG membership)',
  },
  {
    key: 'iam',          label: 'IAM',
    hint: 'Permission chains — Lambda / ECS assumes IAM role, role has access to S3 buckets / SQS queues / etc.',
  },
  {
    key: 'observability', label: 'Observability',
    hint: 'Monitoring wires — CloudWatch alarm watches a resource (ECS / RDS / SQS), alarm triggers SNS on breach',
  },
  {
    key: 'auth',         label: 'Auth',
    hint: 'Authentication layer — API Gateway → Cognito JWT authorizer, Lambda REQUEST authorizer',
  },
  {
    key: 'encryption',   label: 'Encryption',
    hint: 'Data-at-rest protection — RDS / ElastiCache / S3 / Secrets Manager resource encrypted with a customer KMS key',
  },
  {
    key: 'dns',          label: 'DNS',
    hint: 'Service discovery — ECS service registers with Cloud Map namespace, making it addressable by DNS name',
  },
  {
    key: 'logging',      label: 'Logging',
    hint: 'Log routing — ECS container or Lambda function sends stdout / stderr to a CloudWatch log group',
  },
]

export default function FilterBar({ filters, onChange }: Props) {
  const toggle = (key: keyof FilterState) =>
    onChange({ ...filters, [key]: !filters[key] })

  return (
    <div className="filter-bar">
      <span className="filter-bar-label">Show edges:</span>
      {FILTERS.map(({ key, label, hint }) => {
        const on = filters[key]
        const color = EDGE_COLORS[key].stroke
        return (
          <button
            key={key}
            className={`filter-chip${on ? ' active' : ''}`}
            style={on ? { backgroundColor: color, borderColor: color, color: '#fff' } : { borderColor: color, color }}
            onClick={() => toggle(key)}
            title={hint}
          >
            <span className="filter-chip-dot" style={{ backgroundColor: on ? '#fff' : color }} />
            {label}
          </button>
        )
      })}
    </div>
  )
}
