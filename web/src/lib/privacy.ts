// Darstellung maskierter Privatfahrten (Leserolle, vgl. server/app/privacy.py).
import type { Place, Trip } from '../api/types'

export const PRIVATE_TRIP_LABEL = 'Privatfahrt'
export const PRIVATE_PLACE_NAME = 'Privater Ort'

export function isPrivateTrip(t: Pick<Trip, 'category' | 'private_mode'>): boolean {
  return t.category === 'private' || Boolean(t.private_mode)
}

/** Felder, die der Server für die Leserolle entfernt. */
const MASKED_FIELDS = ['start_label', 'end_label', 'start_place_id', 'end_place_id', 'purpose', 'customer_id', 'note'] as const

type MaskFields = 'category' | 'private_mode' | (typeof MASKED_FIELDS)[number]

/** Ist diese Fahrt maskiert geliefert worden (privat und alle Detailfelder leer)? */
export function isMaskedTrip(t: Pick<Trip, MaskFields>): boolean {
  return isPrivateTrip(t) && MASKED_FIELDS.every((f) => t[f] === null || t[f] === undefined)
}

export interface RouteText {
  text: string
  masked: boolean
}

type PlaceLookup = (id: string) => Place | undefined

function placeName(id: string | null, label: string | null, lookup: PlaceLookup): string | null {
  if (label) return label
  if (!id) return null
  const p = lookup(id)
  if (!p) return null
  return p.private ? PRIVATE_PLACE_NAME : p.name
}

/** „Start → Ziel“ bzw. „Privatfahrt“ für maskierte/private Fahrten ohne Orte. */
export function routeText(t: Pick<Trip, MaskFields>, lookup: PlaceLookup): RouteText {
  const from = placeName(t.start_place_id, t.start_label, lookup)
  const to = placeName(t.end_place_id, t.end_label, lookup)
  if (!from && !to) {
    if (isPrivateTrip(t)) return { text: PRIVATE_TRIP_LABEL, masked: isMaskedTrip(t) }
    return { text: 'Ort unbekannt', masked: false }
  }
  return { text: `${from ?? '?'} → ${to ?? '?'}`, masked: false }
}

/** Zweck-Spalte: maskierte Privatfahrten zeigen „Privatfahrt“, nie leere Felder. */
export function purposeText(t: Trip): string {
  if (t.purpose) return t.purpose
  if (isPrivateTrip(t)) return PRIVATE_TRIP_LABEL
  return '–'
}

/** Darf der Ort Koordinaten zeigen? Wohnort und vertrauliche Orte nie. */
export function placeShowsCoordinates(p: Place): boolean {
  return p.kind !== 'home' && !p.private && p.lat !== null && p.lon !== null
}

export function placeCoordinateText(p: Place): string {
  if (p.kind === 'home') return 'nur auf dem Gerät (Wohnort)'
  if (p.private) return 'nur auf dem Gerät (vertraulich)'
  return placeShowsCoordinates(p) ? 'erfasst (≈ 100 m gerundet)' : 'keine'
}
