import { useCallback, useMemo } from 'react'
import {
  ReactFlow, Background, Controls, MiniMap,
  useReactFlow, BackgroundVariant,
} from '@xyflow/react'
import type { Node, NodeChange, EdgeChange, Edge } from '@xyflow/react'
import '@xyflow/react/dist/style.css'

import type { ResourceNode, RelationshipEdge, FilterState, ResourceNodeData } from '@/types/graph'
import ResourceNodeComponent from '@/components/nodes/ResourceNode'
import RelationshipEdgeComponent from '@/components/edges/RelationshipEdge'
import { CATEGORY_COLORS } from '@/lib/colors'

const nodeTypes = { resource: ResourceNodeComponent }
const edgeTypes = { relationship: RelationshipEdgeComponent }

interface Props {
  nodes: ResourceNode[]
  edges: RelationshipEdge[]
  onNodesChange: (changes: NodeChange[]) => void
  onEdgesChange: (changes: EdgeChange[]) => void
  filters: FilterState
  onNodeSelect: (node: ResourceNode | null) => void
  onEdgeClick: (event: React.MouseEvent, edge: RelationshipEdge) => void
  searchTerm: string
}

export default function Canvas({
  nodes, edges, onNodesChange, onEdgesChange,
  filters, onNodeSelect, onEdgeClick, searchTerm,
}: Props) {
  const { fitView } = useReactFlow()

  // Apply edge filter visibility based on active relationship types
  const visibleEdges = useMemo(() =>
    edges.map(e => ({
      ...e,
      hidden: !(filters[(e.data as RelationshipEdge['data'])?.relationship as keyof FilterState] ?? false),
    })),
  [edges, filters])

  // Apply search highlight without changing hidden state
  // (App.tsx already unhides matching nodes; we just mark them here for styling)
  const displayNodes = useMemo(() => {
    if (!searchTerm) return nodes
    const t = searchTerm.toLowerCase()
    return nodes.map(n => {
      const d = n.data as ResourceNodeData
      const hit =
        String(d.label).toLowerCase().includes(t) ||
        (d.metadata as { key: string; value: string }[]).some(m =>
          m.value != null && String(m.value).toLowerCase().includes(t))
      return { ...n, data: { ...n.data, highlighted: hit } }
    })
  }, [nodes, searchTerm])

  const handleNodeClick = useCallback((_: React.MouseEvent, node: Node) => {
    onNodeSelect(node as ResourceNode)
  }, [onNodeSelect])

  const handlePaneClick = useCallback(() => {
    onNodeSelect(null)
  }, [onNodeSelect])


  const miniMapColor = useCallback((node: Node) => {
    const cat = (node.data as ResourceNodeData)?.category as string
    return CATEGORY_COLORS[cat as keyof typeof CATEGORY_COLORS]?.border ?? '#94A3B8'
  }, [])

  return (
    <div className="canvas-wrap">
      <ReactFlow
        nodes={displayNodes}
        edges={visibleEdges}
        nodeTypes={nodeTypes as any}
        edgeTypes={edgeTypes as any}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onNodeClick={handleNodeClick}
        onEdgeClick={(event, edge) => onEdgeClick(event as React.MouseEvent, edge as RelationshipEdge)}
        onPaneClick={handlePaneClick}
        fitView
        fitViewOptions={{ padding: 0.15 }}
        minZoom={0.05}
        maxZoom={2}
        defaultEdgeOptions={{ type: 'relationship' }}
      >
        <Background variant={BackgroundVariant.Dots} gap={20} size={1} color="#E2E8F0" />
        <Controls showInteractive={false} />
        <MiniMap
          nodeColor={miniMapColor as any}
          nodeStrokeWidth={2}
          zoomable
          pannable
          style={{ background: '#F8FAFC', border: '1px solid #E2E8F0' }}
        />
        {/* Blue arrowhead used when an edge is selected.
            Must live inside the ReactFlow component so React Flow's SVG
            context is available and orient="auto" rotates correctly. */}
        <svg style={{ position: 'absolute', width: 0, height: 0, overflow: 'visible' }}>
          <defs>
            <marker
              id="arrow-selected"
              markerWidth="10" markerHeight="10"
              refX="9" refY="5"
              orient="auto-start-reverse"
              markerUnits="userSpaceOnUse"
            >
              <path d="M0,0 L0,10 L10,5 z" fill="#2563EB" />
            </marker>
          </defs>
        </svg>
      </ReactFlow>
    </div>
  )
}
