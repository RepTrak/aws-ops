import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import type { RelationshipEdge, RelationshipEdgeData, EdgeRelationship } from '@/types/graph'
import { EDGE_COLORS, RESOURCE_ICON } from '@/lib/colors'

interface Props {
  edge: RelationshipEdge
  sourceLabel: string
  sourceType: string
  targetLabel: string
  targetType: string
  position: { x: number; y: number }
  onClose: () => void
}

export default function EdgeInfoPopup({
  edge, sourceLabel, sourceType, targetLabel, targetType, position, onClose,
}: Props) {
  const ref = useRef<HTMLDivElement>(null)

  // Close on outside click (delayed slightly so the opening click doesn't immediately close it)
  useEffect(() => {
    const md = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose()
    }
    const kd = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    const t = setTimeout(() => {
      document.addEventListener('mousedown', md)
      document.addEventListener('keydown', kd)
    }, 60)
    return () => {
      clearTimeout(t)
      document.removeEventListener('mousedown', md)
      document.removeEventListener('keydown', kd)
    }
  }, [onClose])

  const data  = edge.data as RelationshipEdgeData
  const rel   = (data?.relationship ?? 'dataflow') as EdgeRelationship
  const { stroke, label: relLabel } = EDGE_COLORS[rel] ?? EDGE_COLORS.dataflow
  const desc  = data?.description ?? ''

  const srcIcon = RESOURCE_ICON[sourceType as keyof typeof RESOURCE_ICON] ?? '□'
  const tgtIcon = RESOURCE_ICON[targetType as keyof typeof RESOURCE_ICON] ?? '□'

  // Clamp to viewport so it doesn't go off-screen
  const W = 268, H = 86
  const left = Math.min(Math.max(position.x + 14, 8), window.innerWidth  - W - 8)
  const top  = Math.min(Math.max(position.y - 44, 8), window.innerHeight - H - 8)

  return createPortal(
    <div ref={ref} className="edge-popup" style={{ left, top }}>
      {/* Type header */}
      <div className="edge-popup-header" style={{ borderLeftColor: stroke }}>
        <span className="edge-popup-dot" style={{ background: stroke }} />
        <span className="edge-popup-rel">{relLabel}</span>
        {desc && <span className="edge-popup-desc" title={desc}>{desc}</span>}
        <button className="edge-popup-close" onClick={onClose}>✕</button>
      </div>

      {/* Source → Target */}
      <div className="edge-popup-flow">
        <span className="edge-popup-node">
          <span className="edge-popup-icon">{srcIcon}</span>
          <span className="edge-popup-label" title={sourceLabel}>{sourceLabel}</span>
        </span>
        <span className="edge-popup-arrow" style={{ color: stroke }}>→</span>
        <span className="edge-popup-node">
          <span className="edge-popup-icon">{tgtIcon}</span>
          <span className="edge-popup-label" title={targetLabel}>{targetLabel}</span>
        </span>
      </div>
    </div>,
    document.body,
  )
}
