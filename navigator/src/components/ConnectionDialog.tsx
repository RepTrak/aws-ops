import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { EdgeRelationship } from '@/types/graph'
import { EDGE_COLORS } from '@/lib/colors'

export interface ConnectionRow {
  edgeType: EdgeRelationship
  inbound:  { count: number; active: boolean }
  outbound: { count: number; active: boolean }
}

interface Props {
  nodeLabel: string
  position: { x: number; y: number }
  rows: ConnectionRow[]
  onToggle: (edgeType: EdgeRelationship, direction: 'in' | 'out') => void
  onClose: () => void
}

export default function ConnectionDialog({ nodeLabel, position, rows, onToggle, onClose }: Props) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const md = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose()
    }
    const kd = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('mousedown', md)
    document.addEventListener('keydown', kd)
    return () => { document.removeEventListener('mousedown', md); document.removeEventListener('keydown', kd) }
  }, [onClose])

  // Clamp to viewport so dialog doesn't go off-screen
  const dialogH = rows.length * 34 + 76
  const left = Math.min(Math.max(position.x, 8), window.innerWidth - 292)
  const top  = Math.min(Math.max(position.y, 8), window.innerHeight - dialogH - 8)

  return createPortal(
    <div ref={ref} className="conn-dialog" style={{ left, top }}>
      {/* Header */}
      <div className="conn-dialog-header">
        <span className="conn-dialog-icon">⇄</span>
        <span className="conn-dialog-title" title={nodeLabel}>{nodeLabel}</span>
        <button className="conn-dialog-close" onClick={onClose}>✕</button>
      </div>

      {/* Column labels */}
      <div className="conn-col-labels">
        <span>← inbound</span>
        <span className="conn-type-col">edge type</span>
        <span>outbound →</span>
      </div>

      {/* One row per edge type */}
      {rows.map(row => {
        const { stroke, label } = EDGE_COLORS[row.edgeType]
        return (
          <div key={row.edgeType} className="conn-row">
            {/* Left: inbound */}
            <DirButton
              count={row.inbound.count}
              active={row.inbound.active}
              align="left"
              color={stroke}
              onClick={() => onToggle(row.edgeType, 'in')}
            />

            {/* Centre: edge type label */}
            <div className="conn-type-label">
              <span className="conn-dot" style={{ background: stroke }} />
              <span>{label}</span>
            </div>

            {/* Right: outbound */}
            <DirButton
              count={row.outbound.count}
              active={row.outbound.active}
              align="right"
              color={stroke}
              onClick={() => onToggle(row.edgeType, 'out')}
            />
          </div>
        )
      })}
    </div>,
    document.body,
  )
}

// ─── inner component ─────────────────────────────────────────────────────────

function DirButton({
  count, active, align, color, onClick,
}: {
  count: number; active: boolean; align: 'left' | 'right'; color: string; onClick: () => void
}) {
  const disabled = count === 0
  const icon = active ? '−' : '+'
  const label = align === 'left'
    ? `${icon} ${count}`
    : `${count} ${icon}`

  return (
    <button
      className={`conn-dir-btn${active ? ' active' : ''}${disabled ? ' disabled' : ''}`}
      style={active ? { background: color, borderColor: color, color: '#fff' } : { borderColor: disabled ? '#E2E8F0' : color, color: disabled ? '#CBD5E1' : color }}
      disabled={disabled}
      onClick={onClick}
      title={disabled ? 'No connections' : `${active ? 'Collapse' : 'Expand'} ${count} node${count !== 1 ? 's' : ''}`}
    >
      {label}
    </button>
  )
}
