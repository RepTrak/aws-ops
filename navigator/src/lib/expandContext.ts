import { createContext } from 'react'
import type { EdgeRelationship } from '@/types/graph'

export interface ConnectionContextValue {
  openDialog:       (nodeId: string, position: { x: number; y: number }) => void
  activeExpansions: Set<string>
  toggleConnection: (nodeId: string, edgeType: EdgeRelationship, direction: 'in' | 'out') => void
  hideNode:         (nodeId: string) => void
}

export const ConnectionContext = createContext<ConnectionContextValue>({
  openDialog:       () => {},
  activeExpansions: new Set(),
  toggleConnection: () => {},
  hideNode:         () => {},
})
