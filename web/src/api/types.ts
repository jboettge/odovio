// Datentypen der Server-API (snake_case wie geliefert). Felder gemäss server/app/schemas.py.

export type Role = 'admin' | 'write' | 'read'

export interface TenantInfo {
  slug: string
  role: Role
  name?: string | null
}

export interface Me {
  sub: string
  name: string | null
  display_name?: string | null
  tenants: TenantInfo[]
}

export interface AuthConfig {
  issuer: string
  client_id: string
  scopes: string
  web_client_id?: string | null
}

/** Gemeinsame Metadaten aller synchronisierten Objekte. */
export interface EntityMeta {
  id: string
  version: number
  deleted: boolean
  created_by?: string | null
  updated_by?: string | null
  created_at?: string | null
  updated_at?: string | null
}

export type FuelType = 'benzin' | 'diesel' | 'hybrid' | 'lpg' | string

export interface Vehicle extends EntityMeta {
  name: string
  make: string | null
  model: string | null
  plate: string | null
  fuel_type: FuelType
  initial_km: number
  purchase_price: number | null
  ownership: 'private' | 'business' | null
  private_use_method: 'flat' | 'effective' | null
  annual_fixed_costs: number | null
}

export interface OdometerReading extends EntityMeta {
  vehicle_id: string
  date: string
  km: number
  note: string | null
}

export interface FuelEntry extends EntityMeta {
  vehicle_id: string
  date: string
  km: number
  liters: number
  price_total: number
  full_tank: boolean
  station: string | null
  note: string | null
}

export interface Maintenance extends EntityMeta {
  vehicle_id: string
  date: string
  km: number | null
  title: string
  cost: number | null
  note: string | null
  next_due_km: number | null
  next_due_date: string | null
}

export interface MaintenanceItem extends EntityMeta {
  maintenance_id: string
  label: string
  done: boolean
  position: number
}

export interface MaintenanceMaterial extends EntityMeta {
  maintenance_id: string
  article_id: string | null
  name: string
  part_number: string | null
  quantity: number
  unit: string
  unit_price: number | null
  position: number
}

export interface MaterialArticle extends EntityMeta {
  name: string
  part_number: string | null
  unit: string
  unit_price: number | null
  category: string | null
  vehicle_id: string | null
  note: string | null
}

export type TripCategory = 'business' | 'private' | 'commute' | 'field' | 'unknown'
export type TripStatus = 'draft' | 'suggested' | 'confirmed' | 'locked'

export interface Trip extends EntityMeta {
  vehicle_id: string
  driver_sub: string | null
  driver_name: string | null
  start_at: string
  end_at: string | null
  km_start: number | null
  km_end: number | null
  distance_gps: number | null
  distance_route: number | null
  start_place_id: string | null
  end_place_id: string | null
  start_label: string | null
  end_label: string | null
  category: TripCategory
  purpose: string | null
  customer_id: string | null
  customer_name: string | null
  status: TripStatus
  source: 'auto' | 'manual' | 'gap' | 'import'
  suggestion_category: TripCategory | null
  suggestion_purpose: string | null
  suggestion_customer_id: string | null
  suggestion_confidence: number | null
  suggestion_reason: string | null
  suggestion_source: 'rule' | 'calendar' | 'pattern' | 'llm' | null
  track_hash: string | null
  split_of: string | null
  private_mode: boolean
  note: string | null
  km_estimated: boolean
}

export type PlaceKind = 'home' | 'work' | 'customer' | 'other'

export interface Place extends EntityMeta {
  name: string
  kind: PlaceKind
  lat: number | null
  lon: number | null
  radius_m: number
  customer_id: string | null
  default_category: TripCategory | null
  private: boolean
}

export interface Customer extends EntityMeta {
  name: string
  ref: string | null
  note: string | null
}

export interface PurposeRule extends EntityMeta {
  priority: number
  from_place_id: string | null
  to_place_id: string | null
  weekdays: string | null
  time_from: string | null
  time_to: string | null
  vehicle_id: string | null
  result_category: Exclude<TripCategory, 'unknown'>
  result_purpose: string | null
  result_customer_id: string | null
  auto_confirm: boolean
  origin: 'user' | 'learned'
  active: boolean
}

export type TaxKey =
  | 'km_rate'
  | 'commute_rate'
  | 'cap_federal'
  | 'cap_canton'
  | 'private_share_pct'
  | 'min_private_month'
  | 'vat_rate'

export interface TaxParam extends EntityMeta {
  year: number
  scope: string
  key: TaxKey
  value: number
  source_url: string | null
  note: string | null
}

export interface TripPeriod extends EntityMeta {
  vehicle_id: string
  month: string
  status: 'closed'
  closed_by: string | null
  closed_at: string | null
  anchor_seq: number | null
  km_start: number | null
  km_end: number | null
  trips_count: number
  business_km: number
  private_km: number
  commute_km: number
  field_km: number
  note: string | null
  corrections: number
}

export interface Attachment extends EntityMeta {
  fuel_id: string | null
  maintenance_id: string | null
  vehicle_id: string | null
  kind: 'receipt' | 'pump' | 'odometer' | 'other'
  sha256: string
  mime: 'image/jpeg' | 'image/heic' | 'application/pdf'
  size: number
  taken_at: string | null
  note: string | null
}

export interface EntityMap {
  vehicle: Vehicle
  odometer: OdometerReading
  fuel: FuelEntry
  maintenance: Maintenance
  maintenance_item: MaintenanceItem
  maintenance_material: MaintenanceMaterial
  material_article: MaterialArticle
  trip: Trip
  place: Place
  customer: Customer
  purpose_rule: PurposeRule
  tax_param: TaxParam
  trip_period: TripPeriod
  attachment: Attachment
}

export type EntityName = keyof EntityMap

export interface Changes {
  cursor: number
  has_more: boolean
  vehicles: Vehicle[]
  odometer: OdometerReading[]
  fuel: FuelEntry[]
  maintenance: Maintenance[]
  maintenance_items: MaintenanceItem[]
  maintenance_materials: MaintenanceMaterial[]
  material_articles: MaterialArticle[]
  trips: Trip[]
  places: Place[]
  customers: Customer[]
  purpose_rules: PurposeRule[]
  tax_params: TaxParam[]
  trip_periods: TripPeriod[]
  attachments: Attachment[]
}

export const CHANGE_KEYS: Record<EntityName, keyof Omit<Changes, 'cursor' | 'has_more'>> = {
  vehicle: 'vehicles',
  odometer: 'odometer',
  fuel: 'fuel',
  maintenance: 'maintenance',
  maintenance_item: 'maintenance_items',
  maintenance_material: 'maintenance_materials',
  material_article: 'material_articles',
  trip: 'trips',
  place: 'places',
  customer: 'customers',
  purpose_rule: 'purpose_rules',
  tax_param: 'tax_params',
  trip_period: 'trip_periods',
  attachment: 'attachments',
}

// ---------- Auswertungen ----------
export interface ConsumptionPoint {
  date: string
  km: number
  distance: number
  liters: number
  cost: number
  consumption: number
  cost_per_km: number
}

export interface DueItem {
  maintenance_id: string
  title: string
  next_due_km: number | null
  next_due_date: string | null
  overdue: boolean
}

export interface Stats {
  current_km: number
  driven_km: number
  avg_consumption: number | null
  avg_liters_per_km: number | null
  avg_cost_per_km: number | null
  total_liters: number
  total_fuel_cost: number
  total_maintenance_cost: number
  points: ConsumptionPoint[]
  due: DueItem[]
}

export interface TripGap {
  after_trip_id: string
  before_trip_id: string
  km_from: number
  km_to: number
  km: number
}

export interface TripMismatch {
  trip_id: string
  reason: string
  blocking: boolean
}

export interface OdometerCheck {
  trip_km: number
  odometer_km: number | null
  diff_km: number | null
  ok: boolean | null
  readings: number
  note: string | null
}

export interface TripCheck {
  month: string
  trips: number
  gaps: TripGap[]
  mismatches: TripMismatch[]
  odometer_check: OdometerCheck
  unconfirmed: number
  closed: boolean
  corrections: number
}

export interface CloseConflictDetail {
  message: string
  gaps?: TripGap[]
  mismatches?: TripMismatch[]
  trips?: { id: string; start_at: string; status: string; category: string }[]
  period?: TripPeriod
}

export interface CloseResult {
  period: TripPeriod
  locked_trips: number
  gaps: TripGap[]
  mismatches: TripMismatch[]
  forced: boolean
  cursor: number
  anchor: { seq: number; head_hash: string; created_at: string; key_id: string } | null
}

export interface YearReportParam {
  key: string
  label: string
  value: number
  year: number
  scope: string
  source_url: string | null
  note: string | null
}

export interface YearReportItem {
  label: string
  value: number | null
  applicable: boolean
  formula: string
  inputs: Record<string, number | null>
  params: YearReportParam[]
  reason: string | null
}

export interface YearReport {
  vehicle: {
    id: string
    name: string
    plate: string | null
    ownership: string
    private_use_method: string
    purchase_price: number | null
    annual_fixed_costs: number | null
  }
  year: number
  canton: string | null
  trips_count: number
  unconfirmed: number
  months_used: number
  km: Record<TripCategory | 'total', number>
  shares_pct: Record<TripCategory, number | null>
  costs: { fuel: number; maintenance: number; fixed: number; total: number }
  items: Record<string, YearReportItem>
  params: Record<string, YearReportParam>
  warnings: string[]
  disclaimer: string
}

// ---------- Revisionssicherheit ----------
export interface Revision {
  seq: number
  entity: string
  entity_id: string
  version: number
  action: 'create' | 'update' | 'delete' | string
  data: Record<string, unknown>
  actor_name: string | null
  recorded_at: string
  client_ts: string | null
  conflict: boolean
  hash: string
}

export interface AuditResult {
  ok: boolean
  chain_ok: boolean
  state_ok: boolean
  count: number
  head_hash: string
  broken_at?: number | null
  reason?: string | null
  problems: string[]
  signed: boolean
  anchors: number
  blobs_checked: number
  blobs_missing: number
  incremental_from?: number | null
  full_seq?: number | null
  full_at?: string | null
  anchors_checked?: number | null
}

export interface Anchor {
  seq: number
  head_hash: string
  created_at: string
  key_id: string
  signature: string
}

export interface AnchorList {
  tenant: string
  public_key: string | null
  key_id: string | null
  message_format: string
  anchors: Anchor[]
}

export interface ActivityItem {
  seq: number
  at: string
  actor_name: string | null
  action: string
  entity: string
  entity_id: string
  vehicle_id?: string | null
  summary: string
}

export interface ActivityPage {
  items: ActivityItem[]
  next_before_seq?: number | null
}

export interface Member {
  id: string
  username: string | null
  name: string | null
  email?: string | null
  role?: Role | null
  /** keycloak = Gruppenmitglied; activity = ohne Keycloak-Verwaltung aus dem Journal ermittelt */
  source: 'keycloak' | 'activity' | string
  last_activity_at?: string | null
}

export interface MemberList {
  members: Member[]
  manageable: boolean
}

// ---------- Sync ----------
export interface SyncOp {
  op_id: string
  entity: EntityName
  id: string
  action: 'upsert' | 'delete'
  base_version: number | null
  data: Record<string, unknown>
  client_ts: string
  reason?: string
}

export interface OpResult {
  op_id: string
  status: 'applied' | 'conflict' | 'duplicate' | 'noop' | 'rejected'
  entity?: string
  id?: string
  version?: number | null
  error?: string | null
}

export interface SyncResponse {
  results: OpResult[]
  cursor: number
}
