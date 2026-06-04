import { memo, useContext } from 'react'
import { Handle, Position } from '@xyflow/react'
import type { NodeProps, Node } from '@xyflow/react'
import type { ResourceNodeData } from '@/types/graph'
import { CATEGORY_COLORS, RESOURCE_ICON, STATUS_COLORS } from '@/lib/colors'
import { ConnectionContext } from '@/lib/expandContext'

type RNode = Node<ResourceNodeData, 'resource'>
type Props = NodeProps<RNode>

function ResourceNode({ id, data, selected }: Props) {
  const { openDialog, hideNode } = useContext(ConnectionContext)

  const colors      = CATEGORY_COLORS[data.category as keyof typeof CATEGORY_COLORS] ?? CATEGORY_COLORS.compute
  const icon        = RESOURCE_ICON[data.resourceType as keyof typeof RESOURCE_ICON] ?? '□'
  const statusColor = STATUS_COLORS[(data.status as keyof typeof STATUS_COLORS) ?? 'unknown']
  const neighbors    = data.neighborIds as string[]
  const isHighlighted = !!(data.highlighted as boolean)
  const diffStatus   = data.diffStatus as 'added' | 'modified' | undefined
  const diffChanges  = (data.diffChanges ?? []) as string[]

  const handleDialogClick = (e: React.MouseEvent) => {
    e.stopPropagation()
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect()
    openDialog(id, { x: rect.right + 10, y: rect.top - 4 })
  }

  return (
    <div
      className={`resource-node${isHighlighted && !selected ? ' node-highlighted' : ''}`}
      style={{
        borderColor: selected ? '#2563EB' : colors.border,
        backgroundColor: selected ? '#EFF6FF' : '#fff',
        boxShadow: selected ? `0 0 0 2px #2563EB40` : `0 2px 8px #0001`,
      }}
    >
      <Handle type="target" position={Position.Left} style={{ opacity: 0 }} />

      {/* Diff badge — shown above header when in diff mode */}
      {diffStatus && (
        <div
          className={`diff-badge diff-${diffStatus}`}
          title={diffChanges.length ? diffChanges.join(' · ') : diffStatus}
        >
          {diffStatus === 'added' ? '✦ NEW' : '◈ CHANGED'}
          {diffChanges.length > 0 && (
            <span className="diff-changes-count">{diffChanges.length}</span>
          )}
        </div>
      )}

      {/* Header: icon + name + status */}
      <div className="resource-node-header" style={{ backgroundColor: colors.bg, borderBottomColor: `${colors.border}40` }}>
        <span className="resource-node-icon">{icon}</span>
        <div className="resource-node-title">
          <span className="resource-node-label" title={data.label as string}>{data.label as string}</span>
          {data.sublabel && <span className="resource-node-sublabel">{data.sublabel as string}</span>}
        </div>
        <button
          className="node-hide-btn"
          onClick={(e) => { e.stopPropagation(); hideNode(id) }}
          title="Remove from canvas"
        >×</button>
        <div className="resource-node-status" style={{ backgroundColor: statusColor }} title={data.status as string} />
      </div>

      {/* Diff changes — compact list below header when modified */}
      {diffStatus === 'modified' && diffChanges.length > 0 && (
        <div className="diff-changes">
          {diffChanges.map((c, i) => <div key={i} className="diff-change-line">· {c}</div>)}
        </div>
      )}

      {/* Footer: type badge + connections button */}
      <div className="resource-node-body">
        <span
          className="resource-node-type"
          style={{ color: colors.text, borderColor: `${colors.border}50`, backgroundColor: colors.bg }}
        >
          {(data.resourceType as string).replace(/_/g, ' ')}
        </span>

        {neighbors.length > 0 && (
          <button
            className="node-conn-btn"
            style={{ borderColor: colors.border, color: colors.text }}
            onClick={handleDialogClick}
            title={`${neighbors.length} connection${neighbors.length !== 1 ? 's' : ''} — click to expand by type`}
          >
            ⇄ {neighbors.length}
          </button>
        )}
      </div>

      <Handle type="source" position={Position.Right} style={{ opacity: 0 }} />
    </div>
  )
}

export default memo(ResourceNode)
