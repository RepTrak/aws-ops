import { memo } from 'react'
import { BaseEdge, getBezierPath } from '@xyflow/react'
import type { EdgeProps, Edge } from '@xyflow/react'
import type { RelationshipEdgeData, EdgeRelationship } from '@/types/graph'
import { EDGE_COLORS } from '@/lib/colors'

type REEdge = Edge<RelationshipEdgeData>

// Vertical offset applied to BOTH source and target Y.
// Edges between the same two nodes start and end at different vertical
// positions, so they never share the same path and are individually clickable.
const Y_OFFSET: Record<EdgeRelationship, number> = {
  deployment:    -20,
  auth:          -13,
  dataflow:       -6,
  observability:   1,
  network:         8,
  iam:            15,
  encryption:     22,
  dns:            29,
  logging:        36,
}

function RelationshipEdge({
  id, sourceX, sourceY, targetX, targetY,
  sourcePosition, targetPosition, data, selected, markerEnd,
}: EdgeProps<REEdge>) {
  const rel     = (data?.relationship as string) ?? 'dataflow'
  const { stroke } = EDGE_COLORS[rel as keyof typeof EDGE_COLORS] ?? EDGE_COLORS.dataflow
  const animated = data?.animated && rel === 'dataflow'

  const yOff = Y_OFFSET[rel as EdgeRelationship] ?? 0

  const [edgePath] = getBezierPath({
    sourceX,
    sourceY: sourceY + yOff,
    sourcePosition,
    targetX,
    targetY: targetY + yOff,
    targetPosition,
    curvature: 0.25,
  })

  const edgeStroke = selected ? '#2563EB' : stroke
  const edgeMarker = selected ? 'url(#arrow-selected)' : markerEnd

  return (
    <BaseEdge
      id={id}
      path={edgePath}
      markerEnd={edgeMarker}
      style={{
        stroke: edgeStroke,
        strokeWidth: selected ? 2.5 : 1.5,
        strokeDasharray:
          rel === 'iam'           ? '4 3' :
          rel === 'observability' ? '2 3' :
          rel === 'logging'       ? '3 2' :
          undefined,
        opacity: selected ? 1 : 0.65,
      }}
      className={animated ? 'edge-animated' : undefined}
    />
  )
}

export default memo(RelationshipEdge)
