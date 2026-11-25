// Änderungen zwischen aufeinanderfolgenden Revisionen (Verlauf je Eintrag).
import type { Revision } from '../api/types'
import { num } from './format'

export interface FieldChange {
  field: string
  before: unknown
  after: unknown
}

const HIDDEN = new Set(['deleted', 'track_hash'])

export function diffRevisions(prev: Revision | null, cur: Revision): FieldChange[] {
  const a = prev?.data ?? {}
  const b = cur.data
  const keys = new Set([...Object.keys(a), ...Object.keys(b)])
  const out: FieldChange[] = []
  for (const k of keys) {
    if (HIDDEN.has(k)) continue
    const before = a[k] ?? null
    const after = b[k] ?? null
    if (JSON.stringify(before) !== JSON.stringify(after)) {
      if (!prev && after === null) continue
      out.push({ field: k, before, after })
    }
  }
  return out
}

export const FIELD_LABELS: Record<string, string> = {
  name: 'Name', make: 'Marke', model: 'Modell', plate: 'Kennzeichen', fuel_type: 'Treibstoff', initial_km: 'Start-km',
  purchase_price: 'Kaufpreis', ownership: 'Halter', private_use_method: 'Methode Privatanteil', annual_fixed_costs: 'Fixkosten/Jahr',
  vehicle_id: 'Fahrzeug', date: 'Datum', km: 'Kilometerstand', note: 'Notiz', liters: 'Liter', price_total: 'Betrag',
  full_tank: 'Volltankung', station: 'Tankstelle', title: 'Titel', cost: 'Kosten', next_due_km: 'Nächste Fälligkeit km',
  next_due_date: 'Nächste Fälligkeit Datum', label: 'Bezeichnung', done: 'Erledigt', position: 'Position', quantity: 'Menge',
  unit: 'Einheit', unit_price: 'Preis/Einheit', part_number: 'Artikelnummer', category: 'Kategorie', ref: 'Referenz',
  kind: 'Art', lat: 'Breite', lon: 'Länge', radius_m: 'Radius (m)', customer_id: 'Kunde', default_category: 'Standardkategorie',
  private: 'Vertraulich', start_at: 'Beginn', end_at: 'Ende', km_start: 'km Beginn', km_end: 'km Ende', distance_gps: 'GPS-Distanz',
  distance_route: 'Routendistanz', start_label: 'Start', end_label: 'Ziel', start_place_id: 'Startort', end_place_id: 'Zielort',
  purpose: 'Zweck', customer_name: 'Kundenname', status: 'Status', source: 'Quelle', private_mode: 'Privatmodus',
  km_estimated: 'km geschätzt', driver_name: 'Fahrer/in', storno_reason: 'Begründung Storno', correction_reason: 'Begründung Korrektur',
  priority: 'Priorität', weekdays: 'Wochentage', time_from: 'Zeit von', time_to: 'Zeit bis', result_category: 'Kategorie',
  result_purpose: 'Zweck', result_customer_id: 'Kunde', auto_confirm: 'Automatisch bestätigen', active: 'Aktiv', origin: 'Herkunft',
  year: 'Jahr', scope: 'Geltung', key: 'Parameter', value: 'Wert', source_url: 'Quelle', month: 'Monat', corrections: 'Korrekturen',
  trips_count: 'Fahrten', business_km: 'Geschäftlich km', private_km: 'Privat km', commute_km: 'Arbeitsweg km', field_km: 'Aussendienst km',
  sha256: 'Prüfsumme', mime: 'Dateityp', size: 'Grösse', taken_at: 'Aufgenommen', fuel_id: 'Tankvorgang', maintenance_id: 'Wartung',
  article_id: 'Artikel', suggestion_category: 'Vorschlag Kategorie', suggestion_purpose: 'Vorschlag Zweck',
  suggestion_confidence: 'Vorschlag Sicherheit', suggestion_reason: 'Vorschlag Grund', suggestion_source: 'Vorschlag Quelle',
  suggestion_customer_id: 'Vorschlag Kunde', split_of: 'Geteilt aus', driver_sub: 'Fahrer-ID', closed_by: 'Abgeschlossen von',
  closed_at: 'Abgeschlossen am', anchor_seq: 'Anker',
}

export function fieldLabel(f: string): string {
  return FIELD_LABELS[f] ?? f
}

export function valueText(v: unknown): string {
  if (v === null || v === undefined || v === '') return '–'
  if (typeof v === 'boolean') return v ? 'ja' : 'nein'
  // gecachter Intl.NumberFormat (lib/format) statt toLocaleString je Aufruf
  if (typeof v === 'number') return num(v, 0, 3)
  return String(v)
}
