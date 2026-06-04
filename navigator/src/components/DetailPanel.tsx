import { useState, useCallback } from 'react'
import type { ResourceNode } from '@/types/graph'
import { CATEGORY_COLORS, RESOURCE_ICON, EDGE_COLORS } from '@/lib/colors'

interface Props {
  node: ResourceNode | null
  onClose: () => void
}

type Tab = 'summary' | 'relationships' | 'brief' | 'raw'

export default function DetailPanel({ node, onClose }: Props) {
  const [tab, setTab] = useState<Tab>('summary')
  const [copied, setCopied] = useState(false)

  if (!node) return (
    <aside className="detail-panel detail-panel-empty">
      <p>Click any node to inspect it.</p>
      <p className="detail-hint">Hold <kbd>Ctrl</kbd> or <kbd>⌘</kbd> and click to multi-select.</p>
    </aside>
  )

  const { data } = node
  const colors = CATEGORY_COLORS[data.category]
  const icon = RESOURCE_ICON[data.resourceType]

  const copyBrief = () => {
    navigator.clipboard.writeText(data.aibrief).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  const relGroups = data.relationships.reduce<Record<string, typeof data.relationships>>((acc, r) => {
    ;(acc[r.type] ??= []).push(r)
    return acc
  }, {})

  return (
    <aside className="detail-panel">
      {/* Node header */}
      <div className="detail-header" style={{ borderLeftColor: colors.border }}>
        <span className="detail-icon">{icon}</span>
        <div className="detail-title-block">
          <h2 className="detail-name" title={data.label}>{data.label}</h2>
          <span className="detail-type" style={{ color: colors.text }}>{data.resourceType.replace(/_/g, ' ')}</span>
          {data.sublabel && <span className="detail-sublabel">{data.sublabel}</span>}
        </div>
        <button className="detail-close" onClick={onClose}>✕</button>
      </div>

      {/* Status */}
      <div className="detail-actions">
        {data.status && (
          <span className={`status-badge status-${data.status}`}>{data.status}</span>
        )}
        {(data.neighborIds as string[]).length > 0 && (
          <span className="detail-conn-hint" style={{ color: colors.text }}>
            ⇄ {(data.neighborIds as string[]).length} connections — use node button to expand
          </span>
        )}
      </div>

      {/* Tabs */}
      <div className="detail-tabs">
        {(['summary', 'relationships', 'brief', 'raw'] as Tab[]).map(t => (
          <button
            key={t}
            className={`detail-tab${tab === t ? ' active' : ''}`}
            style={tab === t ? { borderBottomColor: colors.border, color: colors.text } : {}}
            onClick={() => setTab(t)}
          >
            {t === 'brief' ? 'AI Brief' : t === 'raw' ? 'Raw JSON' : t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div className="detail-body">
        {tab === 'summary' && (
          <dl className="detail-meta">
            {data.metadata.map(m => (
              <div key={m.key} className="detail-meta-row">
                <dt>{m.key}</dt>
                <dd title={m.value}>{m.value || '—'}</dd>
              </div>
            ))}
          </dl>
        )}

        {tab === 'relationships' && (
          <div className="detail-rels">
            {Object.keys(relGroups).length === 0 && (
              <p className="detail-empty">No relationships mapped for this resource.</p>
            )}
            {Object.entries(relGroups).map(([type, rels]) => {
              const ec = EDGE_COLORS[type as keyof typeof EDGE_COLORS]
              return (
                <div key={type} className="detail-rel-group">
                  <h3 className="detail-rel-type" style={{ color: ec?.stroke }}>
                    <span className="rel-dot" style={{ backgroundColor: ec?.stroke }} />
                    {ec?.label ?? type}
                  </h3>
                  <ul className="detail-rel-list">
                    {rels.map((r, i) => (
                      <li key={i} className="detail-rel-item">
                        <span className={`rel-arrow ${r.direction}`}>
                          {r.direction === 'outbound' ? '→' : '←'}
                        </span>
                        <span className="rel-target">{r.targetLabel}</span>
                        <span className="rel-desc">{r.description}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              )
            })}
          </div>
        )}

        {tab === 'raw' && (
          <RawJsonPanel raw={data.raw as Record<string, unknown>} />
        )}

        {tab === 'brief' && (
          <div className="detail-brief">
            <div className="brief-actions">
              <button className="brief-copy-btn" onClick={copyBrief}>
                {copied ? '✓ Copied!' : '📋 Copy Brief'}
              </button>
              <span className="brief-hint">Paste into Claude or any AI assistant</span>
            </div>
            <pre className="brief-content">{data.aibrief}</pre>
          </div>
        )}
      </div>
    </aside>
  )
}

// ─── Raw JSON viewer ──────────────────────────────────────────────────────────

function RawJsonPanel({ raw }: { raw: Record<string, unknown> }) {
  const [copied, setCopied] = useState(false)
  const text = JSON.stringify(raw, null, 2)

  const copy = useCallback(() => {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }, [text])

  return (
    <div className="detail-brief">
      <div className="brief-actions">
        <button className="brief-copy-btn" onClick={copy}>
          {copied ? '✓ Copied!' : '📋 Copy JSON'}
        </button>
        <span className="brief-hint">Raw snapshot data for this resource</span>
      </div>
      <pre className="brief-content raw-json">{text}</pre>
    </div>
  )
}
