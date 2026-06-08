import { useEffect, useState, useCallback, useRef, useMemo } from 'react'
import { ReactFlowProvider, useNodesState, useEdgesState, useReactFlow } from '@xyflow/react'
import type { NodeChange, EdgeChange } from '@xyflow/react'

import type { ResourceNode, RelationshipEdge, FilterState, EdgeRelationship, ResourceNodeData } from '@/types/graph'
import type { SnapshotData } from '@/types/snapshot'
import { DEFAULT_FILTERS } from '@/types/graph'
import { EDGE_COLORS } from '@/lib/colors'
import { loadSnapshot, resolveSnapshotBase } from '@/lib/snapshotLoader'
import { buildGraph } from '@/lib/graphBuilder'
import { applyDagreLayout } from '@/lib/layout'
import { ConnectionContext } from '@/lib/expandContext'
import { positionSiblings, positionPinnedNode, SLOT_W, SLOT_H } from '@/lib/positioning'
import { computeSnapshotDiff, findNodeForDiff } from '@/lib/snapshotDiff'

import Canvas from '@/components/Canvas'
import DetailPanel from '@/components/DetailPanel'
import FilterBar from '@/components/FilterBar'
import Toolbar from '@/components/Toolbar'
import ConnectionDialog, { type ConnectionRow } from '@/components/ConnectionDialog'
import EdgeInfoPopup from '@/components/EdgeInfoPopup'
import './App.css'

export default function App() {
  return (
    <ReactFlowProvider>
      <Navigator />
    </ReactFlowProvider>
  )
}

function Navigator() {
  const [loading, setLoading]   = useState(true)
  const [error, setError]       = useState<string | null>(null)
  const [snap, setSnap]         = useState<SnapshotData | null>(null)
  const [snapshotFolder, setSnapshotFolder] = useState('')
  // Drives the load effect — null means "use latest.json / URL param"
  const [explicitSnapshot, setExplicitSnapshot] = useState<string | null>(
    new URLSearchParams(window.location.search).get('snapshot')
  )
  const [comparisonFolder, setComparisonFolder] = useState<string | null>(null)
  const [selectedNode, setSelectedNode]     = useState<ResourceNode | null>(null)
  const [filters, setFilters]               = useState<FilterState>(DEFAULT_FILTERS)
  const [searchTerm, setSearchTerm]         = useState('')
  const [pendingFocusId, setPendingFocusId] = useState<string | null>(null)

  // ── React Flow state ──────────────────────────────────────────────────────
  const [nodes, setNodes, onNodesChange] = useNodesState<ResourceNode>([])
  const [edges, setEdges, onEdgesChange] = useEdgesState<RelationshipEdge>([])
  const { fitView } = useReactFlow()

  // ── Expansion state ────────────────────────────────────────────────────────
  // Keys: `${nodeId}:${edgeType}:${'in'|'out'}`
  const [activeExpansions, setActiveExpansions] = useState<Set<string>>(new Set())
  // Ref mirrors state so handleConnectionToggle can read it synchronously
  const activeExpansionsRef = useRef<Set<string>>(new Set())
  // Nodes explicitly placed by the user via search — never auto-hidden by collapses
  const pinnedNodeIdsRef = useRef<Set<string>>(new Set())
  // Nodes explicitly dismissed with ×  — stay hidden even if an expansion targets them
  const forcedHiddenIdsRef = useRef<Set<string>>(new Set())
  // Stable ref to the latest edges (avoids stale closure in callbacks)
  const edgesRef = useRef<RelationshipEdge[]>([])
  useEffect(() => { edgesRef.current = edges }, [edges])

  // ── Dialog state ──────────────────────────────────────────────────────────
  const [dialog, setDialog]       = useState<{ nodeId: string; position: { x: number; y: number } } | null>(null)
  const [edgePopup, setEdgePopup] = useState<{
    edge: RelationshipEdge
    position: { x: number; y: number }
    sourceLabel: string; sourceType: string
    targetLabel: string; targetType: string
  } | null>(null)

  // ── Load snapshot — re-runs when explicitSnapshot changes ────────────────
  useEffect(() => {
    setLoading(true)
    setError(null)
    resolveSnapshotBase().then(({ folder }) => setSnapshotFolder(folder)).catch(() => {})
    loadSnapshot(explicitSnapshot ?? undefined)
      .then(data => {
        setSnap(data)
        const { nodes: n, edges: e } = buildGraph(data)
        const laid = applyDagreLayout(n, e, 'LR')
        // All nodes start hidden; pinnedNodeIds is empty — clean slate.
        setNodes(laid)
        setEdges(e)
        setLoading(false)
      })
      .catch(err => { setError(String(err?.message ?? err)); setLoading(false) })
  }, [explicitSnapshot, setNodes, setEdges])  // re-runs when user picks a different snapshot

  // ── Shared helper: compute visible node IDs from pins + expansions ────────
  const computeVisibleIds = useCallback((
    expansions: Set<string>, currentEdges: RelationshipEdge[],
  ): Set<string> => {
    const ids = new Set(pinnedNodeIdsRef.current)
    for (const k of expansions) {
      const [sId, eType, dir] = k.split(':')
      for (const e of currentEdges) {
        if ((e.data as RelationshipEdge['data'])?.relationship !== eType) continue
        if (dir === 'out' && e.source === sId) ids.add(e.target)
        if (dir === 'in'  && e.target === sId) ids.add(e.source)
      }
    }
    // Forced-hidden nodes are never visible regardless of pins or expansions
    for (const id of forcedHiddenIdsRef.current) ids.delete(id)
    return ids
  }, [])

  // ── Connection toggle — computes visibility synchronously, no useEffect ───
  const handleConnectionToggle = useCallback((
    nodeId: string, edgeType: EdgeRelationship, direction: 'in' | 'out',
  ) => {
    const key = `${nodeId}:${edgeType}:${direction}`
    const currentEdges = edgesRef.current

    // Update expansion ref + state synchronously
    const next = new Set(activeExpansionsRef.current)
    const isExpanding = !next.has(key)
    if (isExpanding) next.add(key)
    else next.delete(key)
    activeExpansionsRef.current = next
    setActiveExpansions(new Set(next))  // trigger dialog re-render

    // Auto-enable the edge-type filter when expanding so edges become visible.
    // Never disable on collapse — filter state is additive.
    if (isExpanding) {
      setFilters(prev => prev[edgeType as keyof typeof prev] ? prev : { ...prev, [edgeType]: true })
    }

    // When expanding, lift the forced-hidden ban for nodes directly targeted by
    // this expansion — "x" means "hide until re-expanded", not "permanently hidden".
    if (isExpanding) {
      for (const e of currentEdges) {
        if ((e.data as RelationshipEdge['data'])?.relationship !== edgeType) continue
        if (direction === 'out' && e.source === nodeId) forcedHiddenIdsRef.current.delete(e.target)
        if (direction === 'in'  && e.target === nodeId) forcedHiddenIdsRef.current.delete(e.source)
      }
    }

    // Compute the complete set of visible node IDs from pinned + active expansions
    const visibleIds = computeVisibleIds(next, currentEdges)

    // Collect the IDs that are newly revealed by this specific expansion so we
    // can pan the viewport to include them after React commits the node update.
    let newlyRevealedIds: string[] = []

    // Apply visibility to nodes — compute non-overlapping positions for newly revealed siblings
    setNodes(prev => {
      const anchor = prev.find(n => n.id === nodeId)

      // Compute positions for nodes directly connected to this expansion.
      // This covers both hidden nodes (being newly revealed) and already-visible
      // nodes that should be repositioned near the anchor (shared subnet/cert scenario).
      let siblingPositions: Map<string, { x: number; y: number }> | null = null
      if (isExpanding && anchor) {
        const expansionTargets = prev.filter(p =>
          visibleIds.has(p.id) && currentEdges.some(e =>
            (e.data as RelationshipEdge['data'])?.relationship === edgeType &&
            (direction === 'out'
              ? e.source === nodeId && e.target === p.id
              : e.target === nodeId && e.source === p.id)))

        if (expansionTargets.length > 0) {
          const existingPositions = prev
            .filter(n => !n.hidden && !expansionTargets.some(t => t.id === n.id))
            .map(n => n.position)
          const positions = positionSiblings(
            expansionTargets.length, anchor.position, direction, existingPositions)
          siblingPositions = new Map(expansionTargets.map((s, i) => [s.id, positions[i]]))
          newlyRevealedIds = expansionTargets.map(s => s.id)
        }
      }

      const needsUpdate = prev.some(n => {
        const shouldBeVisible = visibleIds.has(n.id)
        if (n.hidden !== !shouldBeVisible) return true          // visibility change
        if (!n.hidden && siblingPositions?.has(n.id)) return true  // position change
        return false
      })
      if (!needsUpdate) return prev

      return prev.map(n => {
        const shouldBeVisible = visibleIds.has(n.id)
        if (n.hidden && !shouldBeVisible) return n   // stay hidden ✓

        if (shouldBeVisible) {
          const pos = siblingPositions?.get(n.id) ?? n.position
          return { ...n, hidden: false, position: pos }
        } else {
          return { ...n, hidden: true }
        }
      })
    })

    // Pan viewport to include the anchor + all expansion targets (newly revealed OR already
    // visible). This handles the case where the target node is already on canvas from a
    // previous expansion — the user still needs the viewport to pan to it.
    if (isExpanding) {
      const allTargetIds = currentEdges
        .filter(e =>
          (e.data as RelationshipEdge['data'])?.relationship === edgeType &&
          (direction === 'out' ? e.source === nodeId : e.target === nodeId))
        .map(e => direction === 'out' ? e.target : e.source)
      if (allTargetIds.length > 0) {
        setTimeout(() => {
          fitView({
            nodes: [nodeId, ...allTargetIds].map(id => ({ id })),
            duration: 350,
            padding: 0.35,
          })
        }, 50)
      }
    }
  }, [setNodes, fitView, computeVisibleIds])

  // ── Hide node — marks it forced-hidden, unpins it, removes its expansions ─
  const handleHideNode = useCallback((nodeId: string) => {
    // Mark as explicitly dismissed — stays hidden even if another expansion targets it
    forcedHiddenIdsRef.current.add(nodeId)

    // Remove from pins
    pinnedNodeIdsRef.current.delete(nodeId)

    // Remove expansion keys that originated from this node
    const next = new Set(activeExpansionsRef.current)
    for (const key of [...next]) {
      if (key.startsWith(`${nodeId}:`)) next.delete(key)
    }
    activeExpansionsRef.current = next
    setActiveExpansions(new Set(next))

    // Recompute visibility — computeVisibleIds already excludes forcedHiddenIds
    const visibleIds = computeVisibleIds(next, edgesRef.current)

    setNodes(prev => prev.map(n => {
      if (n.id === nodeId) return { ...n, hidden: true, selected: false }
      const shouldBeVisible = visibleIds.has(n.id)
      if (n.hidden === !shouldBeVisible) return n   // already correct
      return { ...n, hidden: !shouldBeVisible }
    }))

    setSelectedNode(prev => prev?.id === nodeId ? null : prev)
    setDialog(prev => prev?.nodeId === nodeId ? null : prev)
  }, [setNodes, computeVisibleIds])

  // ── Dialog: compute rows for a given node ─────────────────────────────────
  const getDialogRows = useCallback((nodeId: string): ConnectionRow[] => {
    const rows: ConnectionRow[] = []
    for (const edgeType of Object.keys(EDGE_COLORS) as EdgeRelationship[]) {
      const inEdges  = edges.filter(e => (e.data as RelationshipEdge['data'])?.relationship === edgeType && e.target === nodeId)
      const outEdges = edges.filter(e => (e.data as RelationshipEdge['data'])?.relationship === edgeType && e.source === nodeId)
      if (inEdges.length === 0 && outEdges.length === 0) continue
      rows.push({
        edgeType,
        inbound:  { count: inEdges.length,  active: activeExpansions.has(`${nodeId}:${edgeType}:in`)  },
        outbound: { count: outEdges.length, active: activeExpansions.has(`${nodeId}:${edgeType}:out`) },
      })
    }
    return rows
  }, [edges, activeExpansions])

  // ── Dialog open / close ───────────────────────────────────────────────────
  const openDialog = useCallback((nodeId: string, position: { x: number; y: number }) => {
    setDialog(prev => prev?.nodeId === nodeId ? null : { nodeId, position })
  }, [])

  const closeDialog = useCallback(() => setDialog(null), [])

  // ── Edge click — show info popup at cursor position ──────────────────────
  const handleEdgeClick = useCallback((event: React.MouseEvent, edge: RelationshipEdge) => {
    const srcNode = nodes.find(n => n.id === edge.source)
    const tgtNode = nodes.find(n => n.id === edge.target)
    setEdgePopup({
      edge,
      position: { x: event.clientX, y: event.clientY },
      sourceLabel: String(srcNode?.data.label  ?? edge.source),
      sourceType:  String(srcNode?.data.resourceType ?? ''),
      targetLabel: String(tgtNode?.data.label  ?? edge.target),
      targetType:  String(tgtNode?.data.resourceType ?? ''),
    })
  }, [nodes])

  // ── Comparison snapshot change ────────────────────────────────────────────
  const handleComparisonChange = useCallback(async (folder: string | null) => {
    setComparisonFolder(folder)

    // Clear canvas state
    pinnedNodeIdsRef.current    = new Set()
    forcedHiddenIdsRef.current  = new Set()
    activeExpansionsRef.current = new Set()
    setActiveExpansions(new Set())
    setSelectedNode(null)
    setDialog(null)
    setFilters(DEFAULT_FILTERS)

    const currentSnap = snap  // capture for the async path below
    if (!folder || !currentSnap) {
      // Comparison cleared — just reset canvas
      setNodes(prev => prev.map(n => ({ ...n, hidden: true, selected: false, data: { ...n.data, diffStatus: undefined, diffChanges: undefined } })))
      return
    }

    // Load comparison snapshot
    const compSnap = await loadSnapshot(folder)
    const diffs = computeSnapshotDiff(currentSnap, compSnap)

    // Build a fresh graph so positions are clean
    const { nodes: freshNodes, edges: freshEdges } = buildGraph(currentSnap)
    const laidNodes = applyDagreLayout(freshNodes, freshEdges, 'LR')

    // Separate into groups: modified first (left), added right
    const modifiedDiffs = diffs.filter(d => d.status === 'modified')
    const addedDiffs    = diffs.filter(d => d.status === 'added')

    // Find matching nodes in the fresh layout
    const COLS      = 4
    const START_Y   = 120
    const MOD_START_X = 80
    const ADD_START_X = MOD_START_X + Math.max(1, Math.ceil(modifiedDiffs.length / COLS)) * SLOT_W + SLOT_W

    function gridPos(idx: number, startX: number) {
      return {
        x: startX + (idx % COLS) * SLOT_W,
        y: START_Y + Math.floor(idx / COLS) * SLOT_H,
      }
    }

    const pinned = new Set<string>()
    const updatedNodes = laidNodes.map(n => ({
      ...n, hidden: true, selected: false,
      data: { ...n.data, diffStatus: undefined, diffChanges: undefined },
    }))

    const nodeById = new Map(updatedNodes.map(n => [n.id, n]))

    function applyDiff(diffsArr: typeof diffs, startX: number) {
      let placed = 0
      for (const diff of diffsArr) {
        const match = findNodeForDiff(updatedNodes, diff)
        if (!match) continue
        const node = nodeById.get(match.id)
        if (!node) continue
        const pos = gridPos(placed++, startX)
        node.hidden       = false
        node.position     = pos
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ;(node.data as any).diffStatus  = diff.status
        ;(node.data as any).diffChanges = diff.changes
        pinned.add(node.id)
      }
    }

    applyDiff(modifiedDiffs, MOD_START_X)
    applyDiff(addedDiffs, ADD_START_X)

    pinnedNodeIdsRef.current = pinned

    setNodes([...nodeById.values()])
    setEdges(freshEdges)

    // Fit view after render
    setPendingFocusId('__diff_fit__')
  }, [snap, setNodes, setEdges, buildGraph])

  // Diff fit-view (triggered via pendingFocusId sentinel)
  useEffect(() => {
    if (pendingFocusId !== '__diff_fit__') return
    const t = setTimeout(() => {
      fitView({ padding: 0.12, duration: 500 })
      setPendingFocusId(null)
    }, 100)
    return () => clearTimeout(t)
  }, [pendingFocusId, fitView])

  // ── Snapshot change — update URL param + trigger reload ──────────────────
  const handleSnapshotChange = useCallback((folder: string) => {
    setComparisonFolder(null)  // reset comparison when primary changes
    const url = new URL(window.location.href)
    url.searchParams.set('snapshot', folder)
    window.history.pushState({}, '', url.toString())
    setExplicitSnapshot(folder)
    // Clear canvas state so the new snapshot starts fresh
    pinnedNodeIdsRef.current = new Set()
    forcedHiddenIdsRef.current = new Set()
    activeExpansionsRef.current = new Set()
    setActiveExpansions(new Set())
    setSelectedNode(null)
    setDialog(null)
    setFilters(DEFAULT_FILTERS)
    setSearchTerm('')
  }, [])

  // ── Reset ─────────────────────────────────────────────────────────────────
  const handleReset = useCallback(() => {
    if (!snap) return
    const { nodes: n, edges: e } = buildGraph(snap)
    const laid = applyDagreLayout(n, e, 'LR')
    setNodes(laid); setEdges(e)
    setSelectedNode(null); setFilters(DEFAULT_FILTERS)
    setSearchTerm('')
    pinnedNodeIdsRef.current = new Set()      // clear all pins — back to empty canvas
    forcedHiddenIdsRef.current = new Set()   // clear forced-hidden overrides
    activeExpansionsRef.current = new Set()
    setActiveExpansions(new Set())
    setDialog(null)
  }, [snap, setNodes, setEdges])

  // ── Search ────────────────────────────────────────────────────────────────
  const handleSearch = useCallback((term: string) => setSearchTerm(term), [])

  // ── Search result select — pins the node on canvas permanently ───────────
  const handleSearchSelect = useCallback((nodeId: string) => {
    forcedHiddenIdsRef.current.delete(nodeId)  // user explicitly re-adds → lift the ban
    pinnedNodeIdsRef.current.add(nodeId)        // stays visible even after collapses

    setNodes(prev => {
      const target = prev.find(n => n.id === nodeId)
      if (!target) return prev

      // Already visible — just select it
      if (!target.hidden) {
        const updated = { ...target, selected: true }
        setSelectedNode(updated)
        setPendingFocusId(nodeId)
        return prev.map(n => n.id === nodeId ? updated : { ...n, selected: false })
      }

      // Find a free non-overlapping position for the newly pinned node
      const visiblePositions = prev.filter(n => !n.hidden).map(n => n.position)
      const neighborSet = new Set(target.data.neighborIds as string[])
      const anchor = prev.find(n => !n.hidden && neighborSet.has(n.id))

      const pos = positionPinnedNode(visiblePositions, anchor?.position)

      const updated = { ...target, hidden: false, position: pos, selected: true }
      setSelectedNode(updated)
      setPendingFocusId(nodeId)
      return prev.map(n => n.id === nodeId ? updated : { ...n, selected: false })
    })
  }, [setNodes])

  // ── Focus via fitView after node is revealed ──────────────────────────────
  useEffect(() => {
    if (!pendingFocusId) return
    const t = setTimeout(() => {
      fitView({ nodes: [{ id: pendingFocusId }], duration: 500, padding: 0.6 })
      setPendingFocusId(null)
    }, 80)
    return () => clearTimeout(t)
  }, [pendingFocusId, fitView])

  // ── Keep selected node fresh ──────────────────────────────────────────────
  const currentSelected = selectedNode
    ? (nodes.find(n => n.id === selectedNode.id) ?? selectedNode)
    : null

  const handleNodeSelect = useCallback((node: ResourceNode | null) => {
    setSelectedNode(node)
    setDialog(null) // close dialog when selecting via canvas click
  }, [])

  // ── Context value ─────────────────────────────────────────────────────────
  const connectionContextValue = useMemo(() => ({
    openDialog, activeExpansions,
    toggleConnection: handleConnectionToggle,
    hideNode: handleHideNode,
  }), [openDialog, activeExpansions, handleConnectionToggle, handleHideNode])

  // ── Dialog data for current open node ────────────────────────────────────
  const dialogRows = dialog ? getDialogRows(dialog.nodeId) : []
  const dialogNode = dialog ? nodes.find(n => n.id === dialog.nodeId) : null

  // ── Loading / error ───────────────────────────────────────────────────────
  if (loading) return (
    <div className="app-state">
      <div className="spinner" />
      <p>Loading snapshot…</p>
    </div>
  )
  if (error) return (
    <div className="app-state app-state-error">
      <h2>⚠️ Could not load snapshot</h2>
      <pre>{error}</pre>
      <p>Run <code>npm run dev</code> from <code>aws-ops/navigator/</code>.</p>
    </div>
  )

  const manifest = snap?.manifest
  const snapshotInfo = {
    region:    manifest?.region ?? '—',
    timestamp: manifest?.timestamp_utc?.slice(0, 16).replace('T', ' ') ?? '—',
    folder:    snapshotFolder,
  }

  return (
    <ConnectionContext.Provider value={connectionContextValue}>
      <div className="app-shell">
        <Toolbar
          nodes={nodes}
          snapshotInfo={snapshotInfo}
          onSearch={handleSearch}
          onSelectResult={handleSearchSelect}
          onSnapshotChange={handleSnapshotChange}
          comparisonFolder={comparisonFolder}
          onComparisonChange={handleComparisonChange}
          onReset={handleReset}
        />

        <div className="app-body">
          {nodes.every(n => n.hidden) && (
          <div className="empty-canvas-guide">
            <div className="empty-canvas-icon">⬡</div>
            <h2>Start exploring your architecture</h2>
            <p>Search for any resource in the toolbar to place it here,<br />then use <strong>⇄</strong> to expand its connections.</p>
          </div>
        )}

        <Canvas
            nodes={nodes}
            edges={edges}
            onNodesChange={onNodesChange as (c: NodeChange[]) => void}
            onEdgesChange={onEdgesChange as (c: EdgeChange[]) => void}
            filters={filters}
            onNodeSelect={handleNodeSelect}
            onEdgeClick={handleEdgeClick}
            searchTerm={searchTerm}
          />

          <DetailPanel
            node={currentSelected}
            onClose={() => setSelectedNode(null)}
          />
        </div>

        <FilterBar filters={filters} onChange={setFilters} />

        {/* Edge info popup — appears at cursor position on edge click */}
        {edgePopup && (
          <EdgeInfoPopup
            edge={edgePopup.edge}
            sourceLabel={edgePopup.sourceLabel}
            sourceType={edgePopup.sourceType}
            targetLabel={edgePopup.targetLabel}
            targetType={edgePopup.targetType}
            position={edgePopup.position}
            onClose={() => setEdgePopup(null)}
          />
        )}

        {/* Connection dialog — portal-rendered at body level */}
        {dialog && dialogNode && dialogRows.length > 0 && (
          <ConnectionDialog
            nodeLabel={dialogNode.data.label as string}
            position={dialog.position}
            rows={dialogRows}
            onToggle={(edgeType, dir) => handleConnectionToggle(dialog.nodeId, edgeType, dir)}
            onClose={closeDialog}
          />
        )}
      </div>
    </ConnectionContext.Provider>
  )
}
