import Dagre from 'dagre'
import type { ResourceNode, RelationshipEdge } from '@/types/graph'

const NODE_W = 220
const NODE_H = 72

export function applyDagreLayout(
  nodes: ResourceNode[],
  edges: RelationshipEdge[],
  direction: 'LR' | 'TB' = 'LR',
): ResourceNode[] {
  const g = new Dagre.graphlib.Graph()
  g.setDefaultEdgeLabel(() => ({}))
  g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 100, marginx: 60, marginy: 60 })

  const visibleIds = new Set(nodes.filter(n => !n.hidden).map(n => n.id))

  nodes.forEach(n => {
    if (!n.hidden) g.setNode(n.id, { width: NODE_W, height: NODE_H })
  })

  edges.forEach(e => {
    if (visibleIds.has(e.source) && visibleIds.has(e.target) && !e.hidden) {
      g.setEdge(e.source, e.target)
    }
  })

  Dagre.layout(g)

  return nodes.map(n => {
    if (n.hidden) return n
    const pos = g.node(n.id)
    if (!pos) return n
    return { ...n, position: { x: pos.x - NODE_W / 2, y: pos.y - NODE_H / 2 } }
  })
}
