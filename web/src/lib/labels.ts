// Begriffe wie in der iOS-App (Models.swift, GlossaryView.swift).
import type { PlaceKind, TaxKey, TripCategory, TripStatus } from '../api/types'

export const CATEGORY_LABELS: Record<TripCategory, string> = {
  business: 'Geschäftlich',
  private: 'Privatfahrt',
  commute: 'Arbeitsweg',
  field: 'Aussendienst',
  unknown: 'Unbekannt',
}
export const CATEGORIES = Object.keys(CATEGORY_LABELS) as TripCategory[]

export const STATUS_LABELS: Record<TripStatus, string> = {
  draft: 'Entwurf',
  suggested: 'Vorgeschlagen',
  confirmed: 'Bestätigt',
  locked: 'Abgeschlossen',
}
export const STATUSES = Object.keys(STATUS_LABELS) as TripStatus[]

export const SOURCE_LABELS: Record<string, string> = {
  auto: 'Automatisch',
  manual: 'Manuell',
  gap: 'Lücke',
  import: 'Import',
}

export const SUGGESTION_SOURCE_LABELS: Record<string, string> = {
  rule: 'Regel',
  calendar: 'Kalender',
  pattern: 'Wiederholung',
  llm: 'KI-Vorschlag',
}

export const PLACE_KIND_LABELS: Record<PlaceKind, string> = {
  home: 'Wohnort',
  work: 'Arbeitsort',
  customer: 'Kunde',
  other: 'Anderer Ort',
}

export const FUEL_TYPE_LABELS: Record<string, string> = {
  benzin: 'Benzin',
  diesel: 'Diesel',
  hybrid: 'Hybrid',
  lpg: 'LPG/CNG',
}

export const ATTACHMENT_KIND_LABELS: Record<string, string> = {
  receipt: 'Quittung',
  pump: 'Zapfsäule',
  odometer: 'Tacho',
  other: 'Weiterer Beleg',
}

export const OWNERSHIP_LABELS: Record<string, string> = {
  private: 'Privatfahrzeug',
  business: 'Geschäftsfahrzeug',
}

export const METHOD_LABELS: Record<string, string> = {
  flat: 'Pauschal (0.9 % / Monat)',
  effective: 'Effektiv (Fahrtenbuch)',
}

export const TAX_KEY_LABELS: Record<TaxKey, string> = {
  km_rate: 'Kilometeransatz Geschäftsfahrten',
  commute_rate: 'Arbeitsweg Privatauto',
  cap_federal: 'Fahrkostenabzug Obergrenze Bund',
  cap_canton: 'Fahrkostenabzug Obergrenze Kanton',
  private_share_pct: 'Privatanteil pauschal',
  min_private_month: 'Privatanteil Minimum',
  vat_rate: 'MWST-Normalsatz',
}
export const TAX_KEYS = Object.keys(TAX_KEY_LABELS) as TaxKey[]

export const TAX_UNITS: Record<TaxKey, string> = {
  km_rate: 'CHF/km',
  commute_rate: 'CHF/km',
  cap_federal: 'CHF',
  cap_canton: 'CHF',
  private_share_pct: '% / Monat',
  min_private_month: 'CHF / Monat',
  vat_rate: '%',
}

export function scopeLabel(scope: string): string {
  if (scope === 'federal') return 'Bund'
  if (scope === 'tenant') return 'Fahrzeugbuch'
  if (scope === 'default') return 'Standard (Annahme)'
  if (scope.startsWith('canton:')) return `Kanton ${scope.slice(7)}`
  return scope
}

export const ENTITY_LABELS: Record<string, string> = {
  vehicle: 'Fahrzeug',
  odometer: 'Kilometerstand',
  fuel: 'Tankvorgang',
  maintenance: 'Wartung',
  maintenance_item: 'Checklistenpunkt',
  maintenance_material: 'Material',
  material_article: 'Materialstamm',
  trip: 'Fahrt',
  place: 'Ort',
  customer: 'Kunde',
  purpose_rule: 'Regel',
  tax_param: 'Steuerparameter',
  trip_period: 'Monatsabschluss',
  attachment: 'Beleg',
  member: 'Mitglied',
}

export const ACTION_LABELS: Record<string, string> = {
  create: 'Erfasst',
  update: 'Geändert',
  delete: 'Storniert',
  close: 'Abgeschlossen',
}

export const WEEKDAYS = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So']

/** „1,2,3,4,5“ → „Mo–Fr“ */
export function weekdaysLabel(v: string | null | undefined): string {
  if (!v) return 'täglich'
  const days = v.split(',').map(Number).filter((d) => d >= 1 && d <= 7)
  if (days.length === 0 || days.length === 7) return 'täglich'
  if (days.join(',') === '1,2,3,4,5') return 'Mo–Fr'
  if (days.join(',') === '6,7') return 'Sa–So'
  return days.map((d) => WEEKDAYS[d - 1]).join(', ')
}

export const GLOSSARY: { term: string; text: string }[] = [
  { term: 'Fahrzeugbuch', text: 'Gemeinsamer Datenbestand (z. B. «privat» oder eine Firma) mit Fahrzeugen, Fahrten, Tankvorgängen und Wartungen.' },
  { term: 'ca. / geschätzt', text: 'Aus der GPS-Distanz berechneter Kilometerstand. Vor dem Monatsabschluss den Tacho ablesen und eintragen.' },
  { term: 'Kilometerkette / Lücke', text: 'Der Kilometerstand am Ende einer Fahrt muss dem Beginn der nächsten entsprechen. Fehlende Kilometer sind eine Lücke.' },
  { term: 'Bestätigen', text: 'Fahrten erhalten eine Kategorie (und bei geschäftlichen Fahrten einen Zweck). Erst bestätigte Fahrten zählen.' },
  { term: 'Monatsabschluss', text: 'Sperrt alle Fahrten eines abgelaufenen Monats. Korrekturen danach nur per Storno mit Begründung.' },
  { term: 'Stornieren', text: 'Einträge werden nie gelöscht, sondern als storniert markiert und bleiben im Änderungsprotokoll sichtbar.' },
  { term: 'Änderungsprotokoll', text: 'Jede Änderung wird auf dem Server unveränderlich in einer Hash-Kette gespeichert und regelmässig signiert.' },
]
