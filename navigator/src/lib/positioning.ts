// ─── Node slot dimensions ─────────────────────────────────────────────────────
// These must be wider/taller than the actual node so we get comfortable gaps.
export const SLOT_W = 240   // node width (200) + 40px gap
export const SLOT_H = 100   // node height (~72) + 28px gap

interface Point { x: number; y: number }

/** True if two nodes placed at `a` and `b` would overlap (using slot dimensions). */
function overlaps(a: Point, b: Point): boolean {
  return Math.abs(a.x - b.x) < SLOT_W && Math.abs(a.y - b.y) < SLOT_H
}

/**
 * Starting from `desired`, find the nearest free slot that doesn't collide with
 * any position in `occupied`.  Searches in concentric rectangular rings,
 * preferring positions close to the desired point.
 */
export function findFreeSlot(desired: Point, occupied: Point[]): Point {
  if (!occupied.some(o => overlaps(desired, o))) return desired

  for (let ring = 1; ring <= 12; ring++) {
    // Walk the perimeter of the ring (clockwise: top → right → bottom → left)
    const candidates: Point[] = []

    // Top row
    for (let dx = -ring; dx <= ring; dx++)
      candidates.push({ x: desired.x + dx * SLOT_W, y: desired.y - ring * SLOT_H })
    // Right column (skip top/bottom corners already added)
    for (let dy = -ring + 1; dy <= ring - 1; dy++)
      candidates.push({ x: desired.x + ring * SLOT_W, y: desired.y + dy * SLOT_H })
    // Bottom row (right → left)
    for (let dx = ring; dx >= -ring; dx--)
      candidates.push({ x: desired.x + dx * SLOT_W, y: desired.y + ring * SLOT_H })
    // Left column (skip corners)
    for (let dy = ring - 1; dy >= -ring + 1; dy--)
      candidates.push({ x: desired.x - ring * SLOT_W, y: desired.y + dy * SLOT_H })

    // Return the candidate closest to `desired` that is collision-free
    const free = candidates
      .filter(c => !occupied.some(o => overlaps(c, o)))
      .sort((a, b) => {
        const da = (a.x - desired.x) ** 2 + (a.y - desired.y) ** 2
        const db = (b.x - desired.x) ** 2 + (b.y - desired.y) ** 2
        return da - db
      })[0]

    if (free) return free
  }

  // Last-resort fallback: place well below existing content
  return { x: desired.x, y: desired.y + 12 * SLOT_H }
}

/**
 * Place `count` sibling nodes near `anchor`.
 *
 * - `direction` 'out' → column to the RIGHT of anchor;
 *                'in'  → column to the LEFT.
 * - Each sibling avoids colliding with `existingPositions` AND with
 *   previously assigned siblings in this same batch.
 *
 * Returns an array of positions in the same order as the input count.
 */
export function positionSiblings(
  count: number,
  anchor: Point,
  direction: 'out' | 'in',
  existingPositions: Point[],
): Point[] {
  const xBase = direction === 'out'
    ? anchor.x + SLOT_W
    : anchor.x - SLOT_W

  const taken = [...existingPositions]
  const result: Point[] = []

  for (let i = 0; i < count; i++) {
    // Desired Y: stack siblings vertically, centred on anchor
    const yDesired = anchor.y + (i - (count - 1) / 2) * SLOT_H
    const desired: Point = { x: xBase, y: yDesired }
    const free = findFreeSlot(desired, taken)
    result.push(free)
    taken.push(free)   // reserve for subsequent siblings
  }

  return result
}

/**
 * Pick a position for a single newly-pinned node (from search).
 *
 * Prefers to place near `anchorPos` if provided, otherwise near the
 * centre of mass of `existingPositions`, or the canvas origin.
 */
export function positionPinnedNode(
  existingPositions: Point[],
  anchorPos?: Point,
): Point {
  let desired: Point

  if (anchorPos) {
    desired = { x: anchorPos.x + SLOT_W, y: anchorPos.y }
  } else if (existingPositions.length > 0) {
    // Centre of mass of visible nodes
    const cx = existingPositions.reduce((s, p) => s + p.x, 0) / existingPositions.length
    const cy = existingPositions.reduce((s, p) => s + p.y, 0) / existingPositions.length
    desired = { x: cx + SLOT_W, y: cy }
  } else {
    desired = { x: 120, y: 120 }
  }

  return findFreeSlot(desired, existingPositions)
}
