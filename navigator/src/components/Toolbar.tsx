import { useState, useRef, useEffect, useMemo, useCallback } from 'react'
import { useReactFlow } from '@xyflow/react'
import type { ResourceNode, ResourceNodeData } from '@/types/graph'
import { RESOURCE_ICON, CATEGORY_COLORS } from '@/lib/colors'

// ─── Snapshot folder parsing ──────────────────────────────────────────────────

function parseFolder(folder: string): { date: string; time: string; region: string } {
  const m = folder.match(/^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-\d{2}Z-(.+)$/)
  if (!m) return { date: folder, time: '', region: '' }
  return { date: m[1], time: `${m[2]}:${m[3]}`, region: m[4] }
}

// ─── Search types ─────────────────────────────────────────────────────────────

interface SearchResult {
  nodeId: string; label: string; resourceType: string
  category: string; isHidden: boolean; matchedField: string
}

// ─── Props ────────────────────────────────────────────────────────────────────

interface Props {
  nodes: ResourceNode[]
  snapshotInfo: { region: string; timestamp: string; folder: string }
  onSearch: (term: string) => void
  onSelectResult: (nodeId: string) => void
  onSnapshotChange: (folder: string) => void
  comparisonFolder: string | null
  onComparisonChange: (folder: string | null) => void
  onReset: () => void
}

export default function Toolbar({
  nodes, snapshotInfo, onSearch, onSelectResult,
  onSnapshotChange, comparisonFolder, onComparisonChange, onReset,
}: Props) {
  const { fitView } = useReactFlow()

  // ── Search state ────────────────────────────────────────────────────────────
  const [query, setQuery]   = useState('')
  const [open, setOpen]     = useState(false)
  const [cursor, setCursor] = useState(-1)
  const searchWrapRef = useRef<HTMLDivElement>(null)
  const inputRef      = useRef<HTMLInputElement>(null)

  // ── Snapshot picker state ───────────────────────────────────────────────────
  const [pickerOpen, setPickerOpen]       = useState(false)
  const [cmpPickerOpen, setCmpPickerOpen] = useState(false)
  const [snapshotList, setSnapshotList]   = useState<string[]>([])
  const [loadingList, setLoadingList]     = useState(false)
  const pickerRef    = useRef<HTMLDivElement>(null)
  const cmpPickerRef = useRef<HTMLDivElement>(null)

  // Lazy-load snapshot list when either picker opens
  useEffect(() => {
    if ((!pickerOpen && !cmpPickerOpen) || snapshotList.length > 0) return
    setLoadingList(true)
    fetch('/snapshots/_list')
      .then(r => r.json())
      .then((folders: string[]) => { setSnapshotList(folders); setLoadingList(false) })
      .catch(() => setLoadingList(false))
  }, [pickerOpen, cmpPickerOpen, snapshotList.length])

  // Close pickers on outside click
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (pickerRef.current    && !pickerRef.current.contains(e.target as Node))    setPickerOpen(false)
      if (cmpPickerRef.current && !cmpPickerRef.current.contains(e.target as Node)) setCmpPickerOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [])

  const handlePickerSelect = (folder: string) => {
    setPickerOpen(false)
    if (folder !== snapshotInfo.folder) onSnapshotChange(folder)
  }

  const handleCmpSelect = (folder: string | null) => {
    setCmpPickerOpen(false)
    onComparisonChange(folder)
  }

  const cmpParsed = comparisonFolder ? parseFolder(comparisonFolder) : null

  // ── Search ──────────────────────────────────────────────────────────────────
  const results = useMemo<SearchResult[]>(() => {
    const t = query.trim().toLowerCase()
    if (!t) return []
    return nodes.reduce<SearchResult[]>((acc, n) => {
      const d = n.data as ResourceNodeData
      const label      = String(d.label)
      const rtype      = String(d.resourceType).replace(/_/g, ' ')
      const matchedMeta = (d.metadata as { key: string; value: string }[])
        .find(m => m.value.toLowerCase().includes(t))
      if (!label.toLowerCase().includes(t) && !rtype.includes(t) && !matchedMeta) return acc
      acc.push({
        nodeId: n.id, label, resourceType: rtype,
        category: String(d.category), isHidden: n.hidden ?? false,
        matchedField: matchedMeta && !label.toLowerCase().includes(t)
          ? `${matchedMeta.key}: ${matchedMeta.value}` : rtype,
      })
      return acc
    }, []).slice(0, 12)
  }, [query, nodes])

  useEffect(() => { onSearch(query) }, [query, onSearch])

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (searchWrapRef.current && !searchWrapRef.current.contains(e.target as Node))
        setOpen(false)
    }
    document.addEventListener('mousedown', handler)
    return () => document.removeEventListener('mousedown', handler)
  }, [])

  const handleChange = (v: string) => { setQuery(v); setCursor(-1); setOpen(true) }

  const handleSelect = useCallback((r: SearchResult) => {
    setQuery(''); setOpen(false); setCursor(-1)
    onSelectResult(r.nodeId)
  }, [onSelectResult])

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (!open || results.length === 0) return
    if (e.key === 'ArrowDown') { e.preventDefault(); setCursor(c => Math.min(c + 1, results.length - 1)) }
    if (e.key === 'ArrowUp')   { e.preventDefault(); setCursor(c => Math.max(c - 1, 0)) }
    if (e.key === 'Enter' && cursor >= 0) { e.preventDefault(); handleSelect(results[cursor]) }
    if (e.key === 'Escape') { setOpen(false); inputRef.current?.blur() }
  }

  const visibleCount = nodes.filter(n => !n.hidden).length
  const current = parseFolder(snapshotInfo.folder)

  return (
    <header className="toolbar">
      {/* Brand + snapshot picker */}
      <div className="toolbar-brand">
        <span className="toolbar-logo">⬡</span>
        <span className="toolbar-title">AWS Navigator</span>

        {/* Snapshot version — click to open picker */}
        <div className="snapshot-picker-wrap" ref={pickerRef}>
          <button
            className={`snapshot-current-btn${pickerOpen ? ' open' : ''}`}
            onClick={() => setPickerOpen(v => !v)}
            title="Switch snapshot"
          >
            <span className="snapshot-region">{current.region || snapshotInfo.region}</span>
            <span className="snapshot-date">{current.date || snapshotInfo.timestamp}</span>
            <span className="snapshot-time">{current.time}</span>
            <span className="snapshot-chevron">{pickerOpen ? '▲' : '▼'}</span>
          </button>

          {pickerOpen && (
            <div className="snapshot-dropdown">
              {loadingList ? (
                <div className="snapshot-loading">Loading…</div>
              ) : snapshotList.length === 0 ? (
                <div className="snapshot-loading">No snapshots found</div>
              ) : snapshotList.map(folder => {
                const p = parseFolder(folder)
                const isCurrent = folder === snapshotInfo.folder
                return (
                  <button
                    key={folder}
                    className={`snapshot-item${isCurrent ? ' current' : ''}`}
                    onClick={() => handlePickerSelect(folder)}
                  >
                    <div className="snapshot-item-main">
                      <span className="snapshot-item-region">{p.region}</span>
                      <span className="snapshot-item-date">{p.date}</span>
                    </div>
                    <div className="snapshot-item-sub">
                      <span className="snapshot-item-time">{p.time} UTC</span>
                      {isCurrent && <span className="snapshot-item-badge">current</span>}
                    </div>
                  </button>
                )
              })}
            </div>
          )}
        </div>
      </div>

      {/* Comparison snapshot picker */}
      <div className="snapshot-picker-wrap" ref={cmpPickerRef} style={{ marginLeft: 4 }}>
        <button
          className={`snapshot-current-btn${cmpPickerOpen ? ' open' : ''}${comparisonFolder ? ' cmp-active' : ''}`}
          onClick={() => setCmpPickerOpen(v => !v)}
          title={comparisonFolder ? 'Change comparison snapshot' : 'Select snapshot to compare against'}
          style={comparisonFolder ? { borderColor: '#F59E0B', color: '#F59E0B' } : {}}
        >
          {cmpParsed ? (
            <>
              <span className="snapshot-region" style={{ color: '#F59E0B' }}>⇄ {cmpParsed.region}</span>
              <span className="snapshot-date">{cmpParsed.date}</span>
              <span className="snapshot-time">{cmpParsed.time}</span>
            </>
          ) : (
            <span style={{ color: '#64748B', fontFamily: 'sans-serif', letterSpacing: 0 }}>⇄ compare with…</span>
          )}
          <span className="snapshot-chevron">{cmpPickerOpen ? '▲' : '▼'}</span>
        </button>

        {cmpPickerOpen && (
          <div className="snapshot-dropdown">
            {/* Clear option */}
            <button
              className={`snapshot-item${!comparisonFolder ? ' current' : ''}`}
              onClick={() => handleCmpSelect(null)}
              style={{ borderBottom: '1px solid #334155' }}
            >
              <div className="snapshot-item-main">
                <span className="snapshot-item-region" style={{ color: '#94A3B8' }}>— none —</span>
                <span className="snapshot-item-date" style={{ color: '#64748B', fontSize: 10 }}>no comparison</span>
              </div>
            </button>

            {loadingList ? (
              <div className="snapshot-loading">Loading…</div>
            ) : snapshotList.filter(f => f !== snapshotInfo.folder).length === 0 ? (
              <div className="snapshot-loading">No other snapshots found</div>
            ) : snapshotList.filter(f => f !== snapshotInfo.folder).map(folder => {
              const p = parseFolder(folder)
              const isCmp = folder === comparisonFolder
              return (
                <button
                  key={folder}
                  className={`snapshot-item${isCmp ? ' current' : ''}`}
                  onClick={() => handleCmpSelect(folder)}
                >
                  <div className="snapshot-item-main">
                    <span className="snapshot-item-region">{p.region}</span>
                    <span className="snapshot-item-date">{p.date}</span>
                  </div>
                  <div className="snapshot-item-sub">
                    <span className="snapshot-item-time">{p.time} UTC</span>
                    {isCmp && <span className="snapshot-item-badge" style={{ background: '#92400E', color: '#FDE68A' }}>comparing</span>}
                  </div>
                </button>
              )
            })}
          </div>
        )}
      </div>

      <div className="toolbar-spacer" />

      {/* Right: search + actions */}
      <div className="toolbar-actions">
        <div className="search-wrap" ref={searchWrapRef}>
          <input
            ref={inputRef}
            className="toolbar-search"
            type="search"
            placeholder="Search any resource…"
            value={query}
            onChange={e => handleChange(e.target.value)}
            onFocus={() => query && setOpen(true)}
            onKeyDown={handleKeyDown}
            autoComplete="off"
          />
          {open && query.trim() !== '' && (
            <div className="search-dropdown">
              {results.length === 0 ? (
                <div className="search-empty">No matches for "{query}"</div>
              ) : results.map((r, idx) => {
                const icon   = RESOURCE_ICON[r.resourceType.replace(/ /g, '_') as keyof typeof RESOURCE_ICON] ?? '□'
                const colors = CATEGORY_COLORS[r.category as keyof typeof CATEGORY_COLORS] ?? CATEGORY_COLORS.compute
                return (
                  <button
                    key={r.nodeId}
                    className={`search-result${idx === cursor ? ' active' : ''}`}
                    onMouseDown={() => handleSelect(r)}
                    onMouseEnter={() => setCursor(idx)}
                  >
                    <span className="sr-icon">{icon}</span>
                    <div className="sr-text">
                      <span className="sr-label">{r.label}</span>
                      <span className="sr-sub" style={{ color: colors.text }}>{r.matchedField}</span>
                    </div>
                    {r.isHidden && <span className="sr-hidden-badge">off-canvas</span>}
                  </button>
                )
              })}
            </div>
          )}
        </div>

        <span className="toolbar-count">{visibleCount} visible</span>
        <button className="toolbar-btn" onClick={() => fitView({ duration: 400, padding: 0.1 })}>Fit</button>
        <button className="toolbar-btn" onClick={onReset}>Reset</button>
      </div>
    </header>
  )
}
