#!/usr/bin/env node
// Mock-Server für Entwicklung und E2E-Tests: OIDC-Issuer (Code + PKCE), Fahrzeugbuch-API, statische SPA mit CSP.
//   node mock/server.mjs [--port 8787] [--static dist] [--seed large]
// Teststeuerung: POST /__mock/reset, POST /__mock/config {members501, rate429, tokenTtl, dropResponseOnce}, POST /__mock/expire-tokens
// dropResponseOnce: nächsten POST /sync anwenden, aber die Verbindung ohne Antwort schliessen (verlorene Antwort)
// failUploadOnce: nächster PUT …/attachments/{id}/blob antwortet 503 (Upload erneut versuchen)
// --seed large: Lasttest-Bestand (Mandant «privat»: 3 Fahrzeuge × 30k Fahrten, 5k Tankvorgänge, > 90k Journal-Einträge).
// --static: liefert vorkomprimierte Varianten (<datei>.br/.gz aus scripts/compress.mjs) bei passendem Accept-Encoding.
import { createServer } from 'node:http'
import { createHash, randomBytes, randomUUID } from 'node:crypto'
import { access, readFile, stat } from 'node:fs/promises'
import { extname, join, normalize, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildDemo, buildLarge, ENTITY_KEYS, USERS, isoDate, monthOf } from './data.mjs'

const here = fileURLToPath(new URL('.', import.meta.url))
const args = process.argv.slice(2)
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`)
  return i >= 0 ? args[i + 1] : def
}
const PORT = Number(opt('port', process.env.PORT ?? 8787))
const STATIC = opt('static', null)
const STATIC_DIR = STATIC ? resolve(process.cwd(), STATIC) : null
const SEED = opt('seed', process.env.MOCK_SEED ?? 'demo')
if (!['demo', 'large'].includes(SEED)) throw new Error(`--seed ${SEED}: erwartet demo oder large`)
const build = () => (SEED === 'large' ? buildLarge() : buildDemo())
const REALM = '/oidc/realms/demo'
const WEB_CLIENT = 'fahrzeugbuch-web'
const APP_CLIENT = 'fahrzeugbuch-ios'

// ---------- Zustand ----------
let tenants = build()
// Seitengrösse /changes: Demo klein (Paging wird getestet), grosser Bestand wie der Server (CHANGES_MAX 5000)
let cfg = { members501: false, rate429: null, dropResponseOnce: false, failUploadOnce: false, tokenTtl: Number(process.env.MOCK_TOKEN_TTL ?? 300), pageMax: Number(process.env.MOCK_PAGE_MAX ?? (SEED === 'large' ? 5000 : 400)) }
const codes = new Map() // code -> {user, client_id, challenge, redirect_uri, nonce}
const tokens = new Map() // access -> {user, azp, exp}
const refreshTokens = new Map() // refresh -> {user, azp}

function reset() {
  // grosser Bestand: nur Steuerung zurücksetzen (Neuaufbau dauert Sekunden; Perf-Tests schreiben nicht)
  if (SEED !== 'large') tenants = build()
  cfg = { ...cfg, members501: false, rate429: null, dropResponseOnce: false, failUploadOnce: false }
  for (const u of Object.values(USERS)) u.tenants = { ...ORIGINAL_TENANTS[u.username] }
}
const ORIGINAL_TENANTS = Object.fromEntries(Object.values(USERS).map((u) => [u.username, { ...u.tenants }]))

// ---------- HTTP-Hilfen ----------
function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body)
  const payload = isBuf || typeof body === 'string' ? body : JSON.stringify(body)
  res.writeHead(status, { 'Content-Type': isBuf ? 'application/octet-stream' : typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json', ...headers })
  res.end(payload)
}
const json = (res, status, body, headers = {}) => send(res, status, body, { 'Content-Type': 'application/json', ...headers })
const fail = (res, status, detail, headers = {}) => json(res, status, { detail }, headers)

async function readRaw(req, max = 9 * 1024 * 1024) {
  const chunks = []
  let n = 0
  for await (const c of req) {
    n += c.length
    if (n > max) return null
    chunks.push(c)
  }
  return Buffer.concat(chunks)
}

async function readBody(req) {
  const chunks = []
  for await (const c of req) chunks.push(c)
  const raw = Buffer.concat(chunks).toString('utf8')
  const type = req.headers['content-type'] ?? ''
  if (type.includes('application/json')) return raw ? JSON.parse(raw) : {}
  if (type.includes('application/x-www-form-urlencoded')) return Object.fromEntries(new URLSearchParams(raw))
  return raw
}

function originOf(req) {
  return `http://${req.headers.host}`
}

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
function jwt(payload) {
  const h = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT', kid: 'mock' }))
  const p = b64url(JSON.stringify(payload))
  return `${h}.${p}.${b64url(randomBytes(32))}`
}

function issueTokens(origin, user, azp, nonce) {
  const access = b64url(randomBytes(24))
  const refresh = b64url(randomBytes(24))
  const now = Math.floor(Date.now() / 1000)
  tokens.set(access, { user, azp, exp: now + cfg.tokenTtl })
  refreshTokens.set(refresh, { user, azp })
  const u = USERS[user]
  return {
    access_token: access,
    refresh_token: refresh,
    token_type: 'Bearer',
    expires_in: cfg.tokenTtl,
    refresh_expires_in: 1800,
    scope: 'openid profile',
    id_token: jwt({ iss: `${origin}${REALM}`, aud: azp, azp, sub: u.sub, iat: now, exp: now + cfg.tokenTtl, name: u.name, preferred_username: u.username, ...(nonce ? { nonce } : {}) }),
  }
}

// ---------- OIDC ----------
function loginPage(q) {
  const hidden = ['client_id', 'redirect_uri', 'state', 'code_challenge', 'code_challenge_method', 'nonce', 'scope', 'response_type']
    .map((k) => `<input type="hidden" name="${k}" value="${String(q.get(k) ?? '').replace(/[&"<>]/g, (c) => ({ '&': '&amp;', '"': '&quot;', '<': '&lt;', '>': '&gt;' })[c])}">`)
    .join('')
  const users = Object.values(USERS)
    .map((u) => `<button type="submit" name="user" value="${u.username}" data-user="${u.username}">${u.name} <small>(${Object.entries(u.tenants).map(([s, r]) => `${s}: ${r}`).join(', ') || 'kein Fahrzeugbuch'})</small></button>`)
    .join('')
  return `<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Mock-Keycloak – Anmeldung</title></head><body>
<h1>Mock-Keycloak</h1><p>Demo-Benutzer wählen:</p><form method="post" action="${REALM}/protocol/openid-connect/login">${hidden}${users}</form></body></html>`
}

async function oidc(req, res, url) {
  const origin = originOf(req)
  const path = url.pathname.slice(REALM.length)
  if (path === '/.well-known/openid-configuration') {
    const base = `${origin}${REALM}/protocol/openid-connect`
    return json(res, 200, {
      issuer: `${origin}${REALM}`, authorization_endpoint: `${base}/auth`, token_endpoint: `${base}/token`, end_session_endpoint: `${base}/logout`,
      revocation_endpoint: `${base}/revoke`, userinfo_endpoint: `${base}/userinfo`, jwks_uri: `${base}/certs`,
      response_types_supported: ['code'], code_challenge_methods_supported: ['S256'], grant_types_supported: ['authorization_code', 'refresh_token'],
    }, { 'Access-Control-Allow-Origin': '*' })
  }
  if (path === '/protocol/openid-connect/auth') {
    if (url.searchParams.get('code_challenge_method') !== 'S256') return send(res, 400, 'PKCE S256 erforderlich')
    return send(res, 200, loginPage(url.searchParams), { 'Content-Type': 'text/html; charset=utf-8' })
  }
  if (path === '/protocol/openid-connect/login' && req.method === 'POST') {
    const f = await readBody(req)
    if (!USERS[f.user]) return send(res, 400, 'Unbekannter Benutzer')
    const code = b64url(randomBytes(16))
    codes.set(code, { user: f.user, client_id: f.client_id, challenge: f.code_challenge, redirect_uri: f.redirect_uri, nonce: f.nonce || null })
    const to = new URL(f.redirect_uri)
    to.searchParams.set('code', code)
    to.searchParams.set('state', f.state)
    to.searchParams.set('session_state', 'mock')
    res.writeHead(302, { Location: to.toString() })
    return res.end()
  }
  if (path === '/protocol/openid-connect/token' && req.method === 'POST') {
    const f = await readBody(req)
    const cors = { 'Access-Control-Allow-Origin': '*' }
    if (f.grant_type === 'authorization_code') {
      const c = codes.get(f.code)
      codes.delete(f.code)
      if (!c) return json(res, 400, { error: 'invalid_grant' }, cors)
      const verifier = b64url(createHash('sha256').update(f.code_verifier ?? '').digest())
      if (verifier !== c.challenge || f.redirect_uri !== c.redirect_uri) return json(res, 400, { error: 'invalid_grant', error_description: 'PKCE' }, cors)
      return json(res, 200, issueTokens(origin, c.user, c.client_id, c.nonce), cors)
    }
    if (f.grant_type === 'refresh_token') {
      const r = refreshTokens.get(f.refresh_token)
      if (!r) return json(res, 400, { error: 'invalid_grant' }, cors)
      refreshTokens.delete(f.refresh_token)
      return json(res, 200, issueTokens(origin, r.user, r.azp, null), cors)
    }
    return json(res, 400, { error: 'unsupported_grant_type' }, cors)
  }
  if (path === '/protocol/openid-connect/revoke') {
    const f = await readBody(req)
    refreshTokens.delete(f.token)
    tokens.delete(f.token)
    return send(res, 200, '', { 'Access-Control-Allow-Origin': '*' })
  }
  if (path === '/protocol/openid-connect/logout') {
    const to = url.searchParams.get('post_logout_redirect_uri') ?? `${origin}/`
    res.writeHead(302, { Location: to })
    return res.end()
  }
  return send(res, 404, 'not found')
}

// ---------- Fachlogik ----------
const TRIP_MASKED = ['start_label', 'end_label', 'start_place_id', 'end_place_id', 'purpose', 'customer_id', 'customer_name', 'note', 'track_hash',
  'suggestion_category', 'suggestion_purpose', 'suggestion_customer_id', 'suggestion_confidence', 'suggestion_reason', 'suggestion_source', 'storno_reason', 'correction_reason']
const isPrivate = (entity, d) => (entity === 'trip' ? d.category === 'private' || Boolean(d.private_mode) : entity === 'place' ? Boolean(d.private) : false)
function mask(entity, d, force = false) {
  if (!(force || isPrivate(entity, d))) return d
  const o = { ...d }
  if (entity === 'trip') for (const k of TRIP_MASKED) if (k in o) o[k] = null
  if (entity === 'place') Object.assign(o, { lat: null, lon: null, name: 'Privater Ort' })
  return o
}
function out(entity, row, role) {
  const { last_seq: _l, ...rest } = row
  return role === 'read' ? mask(entity, rest) : rest
}

const tripKm = (t) => (t.km_start !== null && t.km_end !== null ? t.km_end - t.km_start : (t.distance_route ?? t.distance_gps ?? 0))
const needsReview = (t) => !['confirmed', 'locked'].includes(t.status) || t.category === 'unknown'
const sortTrips = (a) => a.map((x) => [Date.parse(x.start_at), x]).sort((x, y) => x[0] - y[0]).map((x) => x[1])
const currentMonth = () => monthOf(new Date().toISOString())
const closedPeriod = (t, vid, month) => t.list('trip_period').find((p) => p.vehicle_id === vid && p.month === month && !p.deleted && p.status === 'closed')

function vehicleData(t, vid) {
  const active = (e) => t.list(e).filter((r) => r.vehicle_id === vid && !r.deleted)
  return { fuel: active('fuel'), odometer: active('odometer'), maintenance: active('maintenance'), trips: active('trip') }
}
function maintenanceCost(t, m) {
  if (m.cost !== null && m.cost !== undefined) return m.cost
  return t.list('maintenance_material').filter((x) => x.maintenance_id === m.id && !x.deleted).reduce((a, x) => a + x.quantity * (x.unit_price ?? 0), 0)
}

function stats(t, v) {
  const d = vehicleData(t, v.id)
  let current = v.initial_km
  for (const k of [...d.fuel.map((f) => f.km), ...d.odometer.map((o) => o.km), ...d.maintenance.filter((m) => m.km !== null).map((m) => m.km), ...d.trips.map((x) => x.km_end ?? 0)]) if (k > current) current = k
  const fuel = [...d.fuel].sort((a, b) => a.km - b.km)
  const points = []
  let last = null
  let accL = 0
  let accC = 0
  for (const f of fuel) {
    if (last === null) {
      if (f.full_tank) last = f
      continue
    }
    accL += f.liters
    accC += f.price_total
    if (f.full_tank) {
      const dist = f.km - last.km
      if (dist > 0) points.push({ date: f.date, km: f.km, distance: dist, liters: +accL.toFixed(2), cost: +accC.toFixed(2), consumption: +((accL / dist) * 100).toFixed(2), cost_per_km: +(accC / dist).toFixed(3) })
      last = f
      accL = 0
      accC = 0
    }
  }
  const dist = points.reduce((a, p) => a + p.distance, 0)
  const lit = points.reduce((a, p) => a + p.liters, 0)
  const cost = points.reduce((a, p) => a + p.cost, 0)
  const today = isoDate(new Date())
  const latest = {}
  for (const m of d.maintenance) if (m.next_due_km !== null || m.next_due_date) latest[m.title] = !latest[m.title] || latest[m.title].date < m.date ? m : latest[m.title]
  const due = Object.values(latest)
    .map((m) => ({ maintenance_id: m.id, title: m.title, next_due_km: m.next_due_km, next_due_date: m.next_due_date, overdue: (m.next_due_km !== null && current >= m.next_due_km) || (m.next_due_date !== null && today >= m.next_due_date) }))
    .filter((x) => x.overdue || (x.next_due_date && x.next_due_date <= isoDate(new Date(Date.now() + 60 * 86400000))) || (x.next_due_km !== null && x.next_due_km - current < 1500))
    .sort((a, b) => Number(b.overdue) - Number(a.overdue))
  return {
    current_km: current, driven_km: current - v.initial_km,
    avg_consumption: dist ? +((lit / dist) * 100).toFixed(2) : null, avg_liters_per_km: dist ? +(lit / dist).toFixed(4) : null, avg_cost_per_km: dist ? +(cost / dist).toFixed(3) : null,
    total_liters: +d.fuel.reduce((a, f) => a + f.liters, 0).toFixed(2), total_fuel_cost: +d.fuel.reduce((a, f) => a + f.price_total, 0).toFixed(2),
    total_maintenance_cost: +d.maintenance.reduce((a, m) => a + maintenanceCost(t, m), 0).toFixed(2), points, due,
  }
}

function gaps(trips) {
  const c = sortTrips(trips)
  const g = []
  for (let i = 1; i < c.length; i++) if (c[i - 1].km_end !== null && c[i].km_start !== null && c[i - 1].km_end !== c[i].km_start)
    g.push({ after_trip_id: c[i - 1].id, before_trip_id: c[i].id, km_from: c[i - 1].km_end, km_to: c[i].km_start, km: c[i].km_start - c[i - 1].km_end })
  return g
}
function mismatches(trips) {
  const out = []
  for (const x of trips) {
    if (x.km_start === null || x.km_end === null) out.push({ trip_id: x.id, reason: 'km-Stand Beginn/Ende fehlt', blocking: true })
    else if (x.km_estimated) out.push({ trip_id: x.id, reason: 'km-Stand geschätzt (nicht abgelesen)', blocking: true })
    if (!x.end_at) out.push({ trip_id: x.id, reason: 'Endzeit fehlt', blocking: true })
    if (['business', 'field'].includes(x.category) && !(x.purpose ?? '').trim()) out.push({ trip_id: x.id, reason: `Zweck fehlt (${x.category === 'business' ? 'geschäftlich' : 'Aussendienst'})`, blocking: true })
    if (x.distance_gps !== null && x.km_end !== null && Math.abs(x.distance_gps - (x.km_end - x.km_start)) > Math.max(3, 0.1 * (x.km_end - x.km_start)))
      out.push({ trip_id: x.id, reason: `GPS-Distanz ${x.distance_gps.toFixed(1)} km weicht vom km-Stand (${x.km_end - x.km_start} km) ab`, blocking: false })
  }
  return out
}
function check(t, vid, month) {
  const all = sortTrips(t.list('trip').filter((x) => x.vehicle_id === vid && !x.deleted))
  const trips = all.filter((x) => monthOf(x.start_at) === month)
  const prev = all.filter((x) => monthOf(x.start_at) < month).at(-1)
  const d = vehicleData(t, vid)
  const readings = [...d.odometer, ...d.fuel, ...d.maintenance.filter((m) => m.km !== null)].filter((r) => r.date.slice(0, 7) === month).map((r) => r.km)
  const tripSum = +trips.reduce((a, x) => a + tripKm(x), 0).toFixed(1)
  let odo
  if (readings.length < 2 || Math.max(...readings) === Math.min(...readings)) odo = { trip_km: tripSum, odometer_km: null, diff_km: null, ok: null, readings: readings.length, note: 'Zu wenige km-Stände im Monat für den Abgleich' }
  else {
    const lo = Math.min(...readings)
    const hi = Math.max(...readings)
    const covered = trips.reduce((a, x) => a + Math.max(0, Math.min(x.km_end ?? 0, hi) - Math.max(x.km_start ?? 0, lo)), 0)
    const diff = +(covered - (hi - lo)).toFixed(1)
    odo = { trip_km: covered, odometer_km: hi - lo, diff_km: diff, ok: Math.abs(diff) <= Math.max(5, 0.02 * (hi - lo)), readings: readings.length, note: null }
  }
  const period = closedPeriod(t, vid, month)
  return { month, trips: trips.length, gaps: gaps(prev ? [prev, ...trips] : trips), mismatches: mismatches(trips), odometer_check: odo, unconfirmed: trips.filter(needsReview).length, closed: Boolean(period), corrections: period?.corrections ?? 0 }
}

const DEFAULTS = { km_rate: 0.75, commute_rate: 0.75, cap_federal: 3300, private_share_pct: 0.9, min_private_month: 150, vat_rate: 8.1 }
const LABELS = { km_rate: 'Kilometeransatz Geschäftsfahrten (CHF/km)', commute_rate: 'Arbeitsweg Privatauto (CHF/km)', cap_federal: 'Fahrkostenabzug Obergrenze Bund (CHF)', cap_canton: 'Fahrkostenabzug Obergrenze Kanton (CHF)', private_share_pct: 'Privatanteil pauschal (% Kaufpreis pro Monat)', min_private_month: 'Privatanteil Minimum (CHF pro Monat)', vat_rate: 'MWST-Normalsatz (%)' }
function params(t, year) {
  const rank = { tenant: 0, 'canton:ZH': 1, federal: 2 }
  const out = {}
  for (const key of Object.keys(LABELS)) {
    const rows = t.list('tax_param').filter((p) => !p.deleted && p.year === year && p.key === key && p.scope in rank).sort((a, b) => rank[a.scope] - rank[b.scope] || b.last_seq - a.last_seq)
    if (rows[0]) out[key] = { key, label: LABELS[key], value: rows[0].value, year, scope: rows[0].scope, source_url: rows[0].source_url, note: rows[0].note }
    else if (key in DEFAULTS) out[key] = { key, label: LABELS[key], value: DEFAULTS[key], year, scope: 'default', source_url: null, note: '[A] Default gemäss Konzept Fahrtenbuch, mit Treuhand bestätigen' }
  }
  return out
}
function yearReport(t, v, year) {
  const d = vehicleData(t, v.id)
  const trips = d.trips.filter((x) => new Date(x.start_at).getFullYear() === year)
  const cats = ['business', 'private', 'commute', 'field', 'unknown']
  const km = Object.fromEntries(cats.map((c) => [c, 0]))
  for (const x of trips) km[x.category] += tripKm(x)
  const total = cats.reduce((a, c) => a + km[c], 0)
  const p = params(t, year)
  const fuel = d.fuel.filter((f) => f.date.startsWith(String(year))).reduce((a, f) => a + f.price_total, 0)
  const maint = d.maintenance.filter((m) => m.date.startsWith(String(year))).reduce((a, m) => a + maintenanceCost(t, m), 0)
  const fixed = v.annual_fixed_costs ?? 0
  const business = v.ownership === 'business'
  const months = new Set([...trips.map((x) => monthOf(x.start_at)), ...d.fuel.filter((f) => f.date.startsWith(String(year))).map((f) => f.date.slice(0, 7))])
  const r2 = (x) => (x === null ? null : Math.round(x * 100) / 100)
  const raw = km.commute * p.commute_rate.value
  const items = {
    private_share_flat: { label: 'Privatanteil pauschal', value: business && v.purchase_price ? r2(Math.max((p.private_share_pct.value / 100) * v.purchase_price, p.min_private_month.value) * months.size) : null, applicable: business, formula: `max(${p.private_share_pct.value} % × Kaufpreis, CHF ${p.min_private_month.value}) × ${months.size} Monate mit Nutzung`, inputs: { purchase_price: v.purchase_price, months_used: months.size }, params: [p.private_share_pct, p.min_private_month], reason: business ? null : 'nur für Geschäftsfahrzeuge (ownership business)' },
    private_share_effective: { label: 'Privatanteil effektiv', value: business && total ? r2(((fuel + maint + fixed) * km.private) / total) : null, applicable: business, formula: 'Kosten Jahr × private-km ÷ total-km', inputs: {}, params: [], reason: business ? null : 'nur für Geschäftsfahrzeuge (ownership business)' },
    km_compensation: { label: 'Kilometerentschädigung', value: business ? null : r2(km.business * p.km_rate.value), applicable: !business, formula: `geschäftliche km × CHF ${p.km_rate.value}/km`, inputs: { business_km: km.business }, params: [p.km_rate], reason: business ? 'nur für Privatfahrzeuge (ownership private)' : null },
    commute_deduction_federal: { label: 'Arbeitsweg-Abzug Bund', value: r2(Math.min(raw, p.cap_federal.value)), applicable: true, formula: `min(Arbeitsweg-km × CHF ${p.commute_rate.value}/km, CHF ${p.cap_federal.value})`, inputs: { commute_km: km.commute, uncapped: r2(raw) }, params: [p.commute_rate, p.cap_federal], reason: null },
    commute_deduction_canton: { label: 'Arbeitsweg-Abzug Kanton', value: p.cap_canton ? r2(Math.min(raw, p.cap_canton.value)) : null, applicable: Boolean(p.cap_canton), formula: `min(Arbeitsweg-km × CHF ${p.commute_rate.value}/km, CHF ${p.cap_canton?.value ?? '–'})`, inputs: {}, params: p.cap_canton ? [p.commute_rate, p.cap_canton] : [], reason: p.cap_canton ? null : 'Parameter cap_canton fehlt' },
  }
  const unconfirmed = trips.filter(needsReview).length
  const warnings = []
  if (unconfirmed) warnings.push(`${unconfirmed} Fahrt(en) nicht bestätigt bzw. ohne Kategorie – Zahlen vorläufig.`)
  if (Object.values(p).some((x) => x.scope === 'default')) warnings.push('Teilweise Default-Parameter verwendet [A] – eigene tax_params erfassen/bestätigen.')
  return {
    vehicle: { id: v.id, name: v.name, plate: v.plate, vin: v.vin ?? null, ownership: v.ownership ?? 'private', private_use_method: v.private_use_method ?? 'flat', purchase_price: v.purchase_price, annual_fixed_costs: v.annual_fixed_costs },
    year, canton: 'ZH', trips_count: trips.length, unconfirmed, months_used: months.size,
    km: { ...Object.fromEntries(cats.map((c) => [c, +km[c].toFixed(1)])), total: +total.toFixed(1) },
    shares_pct: Object.fromEntries(cats.map((c) => [c, total ? +((km[c] / total) * 100).toFixed(1) : null])),
    costs: { fuel: r2(fuel), maintenance: r2(maint), fixed: r2(fixed), total: r2(fuel + maint + fixed) }, items, params: p, warnings,
    disclaimer: 'Annahmen gemäss Konzept, mit Treuhand bestätigen. Die Berechnungen sind Hilfsgrössen und ersetzen keine Steuerberatung; massgebend sind Spesenreglement, Lohnausweis und kantonale Praxis.',
  }
}

/** Minimales gültiges PDF mit Textzeilen (Latin-1). */
function pdf(lines) {
  const esc = (s) => s.replace(/[\\()]/g, (c) => `\\${c}`)
  const content = ['BT', '/F1 12 Tf', '50 790 Td', '16 TL', ...lines.map((l) => `(${esc(l)}) '`), 'ET'].join('\n')
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    `<< /Length ${Buffer.byteLength(content, 'latin1')} >>\nstream\n${content}\nendstream`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  ]
  let body = '%PDF-1.4\n'
  const offsets = []
  objs.forEach((o, i) => {
    offsets.push(Buffer.byteLength(body, 'latin1'))
    body += `${i + 1} 0 obj\n${o}\nendobj\n`
  })
  const xref = Buffer.byteLength(body, 'latin1')
  body += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`
  body += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  return Buffer.from(body, 'latin1')
}
const disposition = (name) => `attachment; filename="${name.replace(/[^\x20-\x7e]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(name)}`

function summary(t, rev, role) {
  const d = role === 'read' ? mask(rev.entity, rev.data) : rev.data
  const p = (id) => (id ? t.get('place', id)?.name : null)
  switch (rev.entity) {
    case 'trip': {
      if (isPrivate('trip', d) && role === 'read') return 'Privatfahrt'
      const from = d.start_label ?? p(d.start_place_id) ?? '?'
      const to = d.end_label ?? p(d.end_place_id) ?? '?'
      return `Fahrt ${from} → ${to}`
    }
    case 'fuel': return `Tankvorgang ${d.liters?.toFixed?.(2) ?? ''} l · CHF ${d.price_total?.toFixed?.(2) ?? ''}`
    case 'odometer': return `Kilometerstand ${Number(d.km).toLocaleString('de-CH')} km`
    case 'maintenance': return `Wartung «${d.title}»`
    case 'maintenance_item': return `Checkliste: ${d.label}`
    case 'maintenance_material': return `Material: ${d.name}`
    case 'material_article': return `Materialstamm: ${d.name}`
    case 'vehicle': return `Fahrzeug ${d.name}`
    case 'place': return `Ort ${d.name}`
    case 'customer': return `Kunde ${d.name}`
    case 'purpose_rule': return `Regel (Priorität ${d.priority})`
    case 'tax_param': return `Steuerparameter ${d.key} ${d.year}: ${d.value}`
    case 'trip_period': {
      const [y, m] = String(d.month).split('-').map(Number)
      return `Monatsabschluss ${new Date(y, m - 1, 1).toLocaleDateString('de-CH', { month: 'long', year: 'numeric' })}`
    }
    case 'attachment': return `Beleg (${d.kind})`
    default: return rev.entity
  }
}
const vehicleOf = (t, rev) => {
  const d = rev.data
  if (d.vehicle_id) return d.vehicle_id
  if (rev.entity === 'vehicle') return rev.entity_id
  if (d.maintenance_id) return t.get('maintenance', d.maintenance_id)?.vehicle_id ?? null
  return null
}

// ---------- Sync ----------
const REQUIRED = {
  vehicle: ['name'], odometer: ['vehicle_id', 'date', 'km'], fuel: ['vehicle_id', 'date', 'km', 'liters', 'price_total'], maintenance: ['vehicle_id', 'date', 'title'],
  maintenance_item: ['maintenance_id', 'label'], maintenance_material: ['maintenance_id', 'name', 'quantity'], material_article: ['name'], customer: ['name'],
  place: ['name', 'kind'], trip: ['vehicle_id', 'start_at'], purpose_rule: ['result_category'], tax_param: ['year', 'scope', 'key', 'value'], attachment: ['kind', 'sha256', 'mime', 'size'],
}
function applyOp(t, user, azp, op) {
  const base = { op_id: op.op_id, entity: op.entity, id: op.id }
  const reject = (error) => ({ ...base, status: 'rejected', error })
  if (!(op.entity in ENTITY_KEYS)) return reject('Unbekannter Objekttyp')
  if (op.entity === 'trip_period') return reject('trip_period wird nur vom Server geschrieben')
  if (op.entity === 'tax_param' && azp !== WEB_CLIENT) return reject('Verwaltung nur im Webfrontend')
  const dup = t.revisions.find((r) => r.op_id === op.op_id)
  if (dup) return { ...base, status: 'duplicate', version: t.get(op.entity, op.id)?.version }
  const existing = t.get(op.entity, op.id)
  const conflict = existing && op.base_version !== null && op.base_version !== existing.version
  const reason = (op.reason ?? '').trim()
  const closedMonth = (row) => {
    if (!row) return false
    if (op.entity === 'trip') return row.status === 'locked' || Boolean(closedPeriod(t, row.vehicle_id, monthOf(row.start_at)))
    if (['fuel', 'odometer', 'maintenance'].includes(op.entity) && row.km !== null && row.km !== undefined) return Boolean(closedPeriod(t, row.vehicle_id, row.date.slice(0, 7)))
    return false
  }
  if (op.action === 'delete') {
    if (!existing) return reject('Objekt nicht gefunden')
    if (existing.deleted) return { ...base, status: 'noop', version: existing.version }
    if (closedMonth(existing) && reason.length < 10) return reject('Begründung erforderlich: Storno im abgeschlossenen Monat (reason, mind. 10 Zeichen)')
    const row = t.record(op.entity, existing, 'delete', user.name, new Date(), reason ? { storno_reason: reason } : {})
    Object.assign(t.revisions.at(-1), { op_id: op.op_id, conflict: Boolean(conflict) })
    return { ...base, status: conflict ? 'conflict' : 'applied', version: row.version }
  }
  const data = op.data ?? {}
  for (const f of REQUIRED[op.entity] ?? []) if (data[f] === null || data[f] === undefined || data[f] === '') return reject(`${f}: Field required`)
  if (op.entity === 'place' && (data.lat !== null || data.lon !== null) && data.lat !== undefined) {
    if (data.kind === 'home') return reject('Wohnort-Koordinaten bleiben auf dem Gerät')
    if (data.private) return reject('Koordinaten privater Orte bleiben auf dem Gerät')
  }
  if (op.entity === 'tax_param' && !/^(federal|canton:[A-Z]{2}|tenant)$/.test(data.scope)) return reject('scope: String should match pattern')
  if (op.entity === 'vehicle') {
    // wie server/app/schemas.normalize_vin: Leer-/Bindestriche weg, Grossbuchstaben, 17 Zeichen ohne I/O/Q
    const vin = String(data.vin ?? '').replace(/[\s-]+/g, '').toUpperCase()
    if (vin && !/^[A-HJ-NPR-Z0-9]{17}$/.test(vin)) return reject('vin: Value error, VIN ungültig: genau 17 Zeichen (Ziffern und Buchstaben ohne I, O, Q)')
    data.vin = vin || null
  }
  if (op.entity === 'trip' && existing?.status === 'locked') return reject('Monat abgeschlossen')
  if (['fuel', 'odometer', 'maintenance'].includes(op.entity) && (closedMonth(data) || closedMonth(existing)) && reason.length < 10) {
    return reject('Begründung erforderlich: Änderung im abgeschlossenen Monat (reason, mind. 10 Zeichen)')
  }
  const row = t.record(op.entity, { ...data, id: op.id, deleted: false }, existing ? 'update' : 'create', user.name)
  Object.assign(t.revisions.at(-1), { op_id: op.op_id, conflict: Boolean(conflict) })
  return { ...base, status: conflict ? 'conflict' : 'applied', version: row.version }
}

// ---------- API ----------
async function api(req, res, url) {
  const auth = req.headers.authorization ?? ''
  if (!auth.toLowerCase().startsWith('bearer ')) return fail(res, 401, 'Token fehlt', { 'WWW-Authenticate': 'Bearer' })
  const tok = tokens.get(auth.slice(7).trim())
  if (!tok || tok.exp < Date.now() / 1000) return fail(res, 401, 'Token ungültig oder abgelaufen', { 'WWW-Authenticate': 'Bearer' })
  const user = USERS[tok.user]
  const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent) // api, t, slug, ...
  const q = url.searchParams

  if (url.pathname === '/api/me') {
    return json(res, 200, { sub: user.sub, name: user.name, display_name: user.name, tenants: Object.entries(user.tenants).sort().map(([slug, role]) => ({ slug, role })) })
  }
  if (parts[1] !== 't' || !parts[2]) return fail(res, 404, 'Nicht gefunden')
  const slug = parts[2]
  const role = user.tenants[slug]
  if (!role) return fail(res, 403, `Kein Zugriff auf Mandant ${slug}`)
  const t = tenants[slug]
  if (!t) return fail(res, 404, 'Mandant nicht gefunden')
  const rest = parts.slice(3)
  const route = rest.join('/')
  const write = role === 'write' || role === 'admin'
  const rateLimited = (name) => {
    if (cfg.rate429 === name || cfg.rate429 === '*') {
      cfg.rate429 = null
      fail(res, 429, 'Zu viele Anfragen', { 'Retry-After': '30' })
      return true
    }
    return false
  }

  if (route === 'changes' && req.method === 'GET') {
    if (rateLimited('changes')) return
    const since = Number(q.get('since') ?? 0)
    const limit = Math.min(Number(q.get('limit') ?? 2000), 5000, cfg.pageMax)
    const rows = t.changesSince(since, limit)
    const hasMore = rows.length > limit
    const page = rows.slice(0, limit)
    const body = { cursor: hasMore ? page.at(-1)[0] : t.seq, has_more: hasMore, ...Object.fromEntries(Object.values(ENTITY_KEYS).map((k) => [k, []])) }
    for (const [, entity, r] of page) body[ENTITY_KEYS[entity]].push(out(entity, r, role))
    return json(res, 200, body)
  }
  if (route === 'sync' && req.method === 'POST') {
    if (!write) return fail(res, 403, 'Nur Lesezugriff auf diesen Mandanten')
    if (rateLimited('sync')) return
    const body = await readBody(req)
    const results = (body.ops ?? []).map((op) => applyOp(t, user, tok.azp, op))
    if (cfg.dropResponseOnce) {
      // angewendet, aber die Antwort bricht nach den Headern ab: der Client sieht nur einen Netzwerkfehler.
      // (Ein Abbruch ganz ohne Antwort würde Chromium auf einer Keep-alive-Verbindung still wiederholen lassen.)
      cfg.dropResponseOnce = false
      res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': '4096' })
      res.write('{"results":[', () => res.socket?.destroy())
      return
    }
    return json(res, 200, { results, cursor: t.seq })
  }
  if (rest[0] === 'vehicles' && rest[1]) {
    const v = t.get('vehicle', rest[1])
    if (!v) return fail(res, 404, 'Fahrzeug nicht gefunden')
    const sub = rest.slice(2).join('/')
    if (sub === 'stats') return json(res, 200, stats(t, v))
    if (sub === 'trips/check') {
      const m = q.get('month') ?? ''
      if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(m)) return fail(res, 422, 'Monat im Format YYYY-MM erwartet')
      return json(res, 200, check(t, v.id, m))
    }
    if (rest[2] === 'periods' && rest[4] === 'close' && req.method === 'POST') {
      if (!write) return fail(res, 403, 'Nur Lesezugriff auf diesen Mandanten')
      const month = rest[3]
      const body = await readBody(req)
      if (month >= currentMonth()) return fail(res, 422, 'Nur abgelaufene Monate können abgeschlossen werden')
      if (closedPeriod(t, v.id, month)) return fail(res, 409, { message: 'Monat bereits abgeschlossen', period: closedPeriod(t, v.id, month) })
      const c = check(t, v.id, month)
      const trips = t.list('trip').filter((x) => x.vehicle_id === v.id && !x.deleted && monthOf(x.start_at) === month)
      const open = trips.filter(needsReview)
      if (open.length) return fail(res, 409, { message: 'Nicht alle Fahrten bestätigt', trips: open.map((x) => ({ id: x.id, start_at: x.start_at, status: x.status, category: x.category })) })
      const blocking = c.mismatches.filter((m) => m.blocking)
      if ((c.gaps.length || blocking.length) && !body.force) return fail(res, 409, { message: blocking.length ? 'Fahrten unvollständig (Zweck, km-Stand oder Endzeit)' : 'km-Lücken vorhanden', gaps: c.gaps, mismatches: blocking })
      if ((c.gaps.length || blocking.length) && (body.reason ?? '').trim().length < 10) return fail(res, 409, { message: 'Erzwungener Abschluss braucht eine Begründung (mind. 10 Zeichen)', gaps: c.gaps, mismatches: blocking })
      for (const x of trips) t.record('trip', { ...x, status: 'locked' }, 'update', user.name)
      const sum = (cat) => trips.filter((x) => x.category === cat).reduce((a, x) => a + tripKm(x), 0)
      t.anchor()
      const period = t.record('trip_period', { id: randomUUID(), vehicle_id: v.id, month, status: 'closed', closed_by: user.name, closed_at: new Date().toISOString(), anchor_seq: t.seq, km_start: trips[0]?.km_start ?? null, km_end: trips.at(-1)?.km_end ?? null, trips_count: trips.length, business_km: sum('business'), private_km: sum('private'), commute_km: sum('commute'), field_km: sum('field'), note: body.force ? body.reason : null, corrections: 0 }, 'create', user.name)
      return json(res, 200, { period: out('trip_period', period, role), locked_trips: trips.length, gaps: c.gaps, mismatches: blocking, forced: Boolean(body.force), cursor: t.seq, anchor: t.anchors.at(-1) })
    }
    const from = q.get('from') ?? `${new Date().getFullYear()}-01-01`
    const to = q.get('to') ?? isoDate(new Date())
    if (sub === 'report.pdf' || sub === 'logbook.pdf' || sub === 'year-report.pdf') {
      if (rateLimited('report')) return
      if (sub === 'logbook.pdf' && !q.get('month') && (new Date(to) - new Date(from)) / 86400000 >= 366) return fail(res, 422, 'Zeitraum zu lang (max. 366 Tage)')
      const title = { 'report.pdf': 'Fahrzeugbuch', 'logbook.pdf': 'Fahrtenbuch', 'year-report.pdf': 'Jahresbericht' }[sub]
      const period = q.get('month') ?? q.get('year') ?? `${from}_${to}`
      return send(res, 200, pdf([`${title} ${v.name} (${v.plate ?? ''})`, `Zeitraum: ${period}`, `Erstellt von ${user.name} (Mock)`, `Anker: Seq ${t.seq} ${t.head.slice(0, 16)}`]), { 'Content-Type': 'application/pdf', 'Content-Disposition': disposition(`${title}_${v.name}_${period}.pdf`) })
    }
    if (sub === 'trips.csv') {
      if ((new Date(to) - new Date(from)) / 86400000 >= 366) return fail(res, 422, 'Zeitraum zu lang (max. 366 Tage)')
      const rows = sortTrips(t.list('trip').filter((x) => x.vehicle_id === v.id && !x.deleted && x.start_at.slice(0, 10) >= from && x.start_at.slice(0, 10) <= to)).map((x) => out('trip', x, role))
      const csv = ['Datum;Start;Ziel;Kategorie;Zweck;km Beginn;km Ende', ...rows.map((x) => [x.start_at, x.start_label ?? '', x.end_label ?? '', x.category, x.purpose ?? '', x.km_start, x.km_end].join(';'))].join('\n')
      return send(res, 200, `\ufeff${csv}\n`, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': disposition(`Fahrten_${v.name}_${from}_${to}.csv`) })
    }
    if (sub === 'year-report') {
      if (rateLimited('report')) return
      return json(res, 200, yearReport(t, v, Number(q.get('year') ?? new Date().getFullYear())))
    }
    return fail(res, 404, 'Nicht gefunden')
  }
  if (rest[0] === 'attachments' && rest[2] === 'blob' && req.method === 'PUT') {
    // wie server/app/main.put_attachment_blob: Metadaten zuerst, Typ/Magic Bytes/Grösse/Prüfsumme müssen passen
    if (!write) return fail(res, 403, 'Nur Lesezugriff auf diesen Mandanten')
    const a = t.get('attachment', rest[1])
    if (!a) return fail(res, 404, 'Beleg nicht gefunden')
    const body = await readRaw(req)
    if (!body) return fail(res, 413, 'Anfrage zu gross')
    if (cfg.failUploadOnce) {
      cfg.failUploadOnce = false
      return fail(res, 503, 'Speicher vorübergehend nicht verfügbar')
    }
    if ((req.headers['content-type'] ?? '').split(';')[0].trim() !== a.mime) return fail(res, 415, 'Content-Type entspricht nicht dem Beleg (mime)')
    const magic = { 'image/jpeg': (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff, 'application/pdf': (b) => b.subarray(0, 4).toString('latin1') === '%PDF', 'image/heic': (b) => b.subarray(4, 8).toString('latin1') === 'ftyp' }[a.mime]
    if (!magic?.(body)) return fail(res, 415, 'Dateiinhalt passt nicht zum Typ (Magic Bytes)')
    if (body.length !== a.size) return fail(res, 422, 'Grösse stimmt nicht')
    if (createHash('sha256').update(body).digest('hex') !== a.sha256) return fail(res, 422, 'Prüfsumme stimmt nicht')
    if (t.blobs.has(a.id)) return json(res, 200, { stored: true, existing: true })
    if (a.deleted) return fail(res, 409, 'Beleg storniert')
    t.blobs.set(a.id, body)
    return json(res, 201, { stored: true, existing: false })
  }
  if (rest[0] === 'attachments' && rest[2] === 'blob' && req.method === 'GET') {
    const a = t.get('attachment', rest[1])
    if (!a) return fail(res, 404, 'Beleg nicht gefunden')
    const file = t.blobs.get(a.id)
    if (!file) return fail(res, 404, 'Datei nicht vorhanden')
    const body = Buffer.isBuffer(file) ? file : await readFile(join(here, 'assets', file))
    return send(res, 200, body, { 'Content-Type': a.mime, 'Content-Disposition': `inline; filename="Beleg_${a.kind}_${a.id.slice(0, 8)}.${a.mime === 'application/pdf' ? 'pdf' : 'jpg'}"`, 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'; sandbox" })
  }
  if (rest[0] === 'history' && rest[1] && rest[2]) {
    if (!(rest[1] in ENTITY_KEYS)) return fail(res, 404, 'Unbekannter Objekttyp')
    const revs = t.revisions.filter((r) => r.entity === rest[1] && r.entity_id === rest[2])
    const obj = t.get(rest[1], rest[2])
    const force = role === 'read' && obj && isPrivate(rest[1], obj)
    return json(res, 200, revs.map(({ op_id: _o, ...r }) => ({ ...r, data: role === 'read' ? mask(r.entity, r.data, force) : r.data })))
  }
  if (route === 'audit/verify') {
    if (rateLimited('verify')) return
    const blobs = [...t.blobs.keys()].length
    return json(res, 200, { ok: true, chain_ok: true, state_ok: true, count: t.revisions.length, head_hash: t.head, broken_at: null, reason: null, problems: [], signed: true, anchors: t.anchors.length, blobs_checked: q.get('full') ? blobs : 0, blobs_missing: t.list('attachment').length - blobs, incremental_from: q.get('full') ? null : Math.max(1, t.seq - 40) })
  }
  if (route === 'audit/anchors') {
    return json(res, 200, { tenant: slug, public_key: 'MCowBQYDK2VwAyEAmockPublicKeyDemoOnly000000000000000=', key_id: 'demo-ed25519-01', message_format: 'fahrzeugbuch-anchor|<tenant>|<seq>|<head_hash>|<created_at>', anchors: t.anchors })
  }
  if (route === 'activity') {
    const limit = Math.min(Number(q.get('limit') ?? 50), 200)
    const before = q.get('before_seq') ? Number(q.get('before_seq')) : Infinity
    const revs = t.revisionsBefore(before, limit)
    const items = revs.map((r) => ({ seq: r.seq, at: r.recorded_at, actor_name: r.actor_name, action: r.action, entity: r.entity, entity_id: r.entity_id, vehicle_id: vehicleOf(t, r), summary: summary(t, r, role) }))
    const oldest = revs.at(-1)?.seq
    return json(res, 200, { items, next_before_seq: oldest && oldest > 1 ? oldest : null })
  }
  if (rest[0] === 'members') {
    if (req.method === 'GET' && rest.length === 1) {
      // ohne Keycloak-Admin-Konfiguration: Akteure aus dem Journal, Rolle unbekannt, nicht verwaltbar (wie Server)
      if (cfg.members501) {
        const actors = [...new Set(t.revisions.map((r) => r.actor_name).filter(Boolean))]
        return json(res, 200, { members: actors.map((n, i) => ({ id: `a-${i}`, username: null, name: n, email: null, role: null, source: 'activity', last_activity_at: t.revisions.filter((r) => r.actor_name === n).at(-1)?.recorded_at ?? null })), manageable: false })
      }
      return json(res, 200, { members: t.members.map((m) => ({ ...m, email: role === 'admin' ? m.email : null })), manageable: role === 'admin' && tok.azp === WEB_CLIENT })
    }
    if (cfg.members501) return fail(res, 501, 'Mitgliederverwaltung nicht konfiguriert – in Keycloak verwalten')
    if (role !== 'admin') return fail(res, 403, 'Nur Verwalter können Mitglieder verwalten')
    if (tok.azp !== WEB_CLIENT) return fail(res, 403, 'Verwaltung nur im Webfrontend')
    const body = req.method === 'DELETE' ? {} : await readBody(req)
    const admins = () => t.members.filter((m) => m.role === 'admin').length
    if (req.method === 'POST' && rest.length === 1) {
      const key = String(body.user ?? '').trim().toLowerCase()
      const u = Object.values(USERS).find((x) => x.username === key || x.email.toLowerCase() === key)
      if (!u) return fail(res, 404, 'Benutzer in Keycloak nicht gefunden')
      if (!['admin', 'write', 'read'].includes(body.role)) return fail(res, 422, 'Rolle ungültig')
      if (t.members.some((m) => m.username === u.username)) return fail(res, 409, 'Bereits Mitglied')
      const m = { id: u.sub, username: u.username, name: u.name, email: u.email, role: body.role, source: 'keycloak', last_activity_at: null }
      t.members.push(m)
      u.tenants[slug] = body.role
      return json(res, 201, m)
    }
    const m = t.members.find((x) => x.id === rest[1])
    if (!m) return fail(res, 404, 'Mitglied nicht gefunden')
    if (req.method === 'PATCH') {
      if (!['admin', 'write', 'read'].includes(body.role)) return fail(res, 422, 'Rolle ungültig')
      if (m.role === 'admin' && body.role !== 'admin' && admins() <= 1) return fail(res, 409, 'Letzter Verwalter kann nicht herabgestuft werden')
      m.role = body.role
      if (USERS[m.username]) USERS[m.username].tenants[slug] = body.role
      return json(res, 200, m)
    }
    if (req.method === 'DELETE') {
      if (m.role === 'admin' && admins() <= 1) return fail(res, 409, 'Letzter Verwalter kann nicht entfernt werden')
      t.members = t.members.filter((x) => x !== m)
      if (USERS[m.username]) delete USERS[m.username].tenants[slug]
      return send(res, 204, '')
    }
  }
  return fail(res, 404, 'Nicht gefunden')
}

// ---------- Statische SPA ----------
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.json': 'application/json', '.woff2': 'font/woff2' }
function securityHeaders(origin) {
  return {
    'Content-Security-Policy': `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self' ${origin}; frame-ancestors 'none'; base-uri 'self'; form-action 'self'; object-src 'none'`,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  }
}
/** Akzeptierte Kodierung (q > 0) laut Accept-Encoding. */
function acceptsEncoding(header, enc) {
  for (const part of String(header ?? '').split(',')) {
    const [name, ...params] = part.trim().split(';')
    if (name.trim().toLowerCase() !== enc && name.trim() !== '*') continue
    const q = params.map((p) => p.trim()).find((p) => p.startsWith('q='))
    return !q || Number(q.slice(2)) > 0
  }
  return false
}
const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.svg', '.json', '.txt', '.xml', '.webmanifest'])
const exists = (p) => access(p).then(() => true, () => false)

async function serveStatic(req, res, url) {
  const rel = normalize(decodeURIComponent(url.pathname)).replace(/^([/\\])+/, '')
  let file = join(STATIC_DIR, rel)
  if (!file.startsWith(STATIC_DIR)) return send(res, 403, 'Verboten')
  // vorkomprimierte Varianten nur über Accept-Encoding, nicht direkt (wie der Server)
  if (/\.(br|gz)$/.test(rel)) return send(res, 404, 'Nicht gefunden')
  let s = await stat(file).catch(() => null)
  if (!s || s.isDirectory()) {
    // SPA-Fallback (Dateien mit Endung → 404)
    if (extname(rel)) return send(res, 404, 'Nicht gefunden')
    file = join(STATIC_DIR, 'index.html')
    s = await stat(file).catch(() => null)
    if (!s) return send(res, 404, 'dist fehlt – zuerst npm run build')
  }
  const immutable = file.includes(`${join(STATIC_DIR, 'assets')}`)
  const headers = { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream', 'Cache-Control': immutable ? 'public, max-age=31536000, immutable' : 'no-cache', ...securityHeaders(originOf(req)) }
  // vorkomprimierte Variante (wie der Produktionsserver): br vor gzip, sonst unkomprimiert
  let body = null
  if (COMPRESSIBLE.has(extname(file))) {
    headers.Vary = 'Accept-Encoding'
    const ae = req.headers['accept-encoding']
    for (const [enc, suffix] of [['br', '.br'], ['gzip', '.gz']]) {
      if (acceptsEncoding(ae, enc) && (await exists(`${file}${suffix}`))) {
        body = await readFile(`${file}${suffix}`)
        headers['Content-Encoding'] = enc
        break
      }
    }
  }
  body ??= await readFile(file)
  return send(res, 200, body, headers)
}

// ---------- Server ----------
const server = createServer(async (req, res) => {
  const url = new URL(req.url, originOf(req))
  try {
    if (req.method === 'OPTIONS') {
      res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'content-type, authorization', 'Access-Control-Allow-Methods': 'GET, POST' })
      return res.end()
    }
    if (url.pathname.startsWith('/__mock/')) {
      const body = req.method === 'POST' ? await readBody(req).catch(() => ({})) : {}
      if (url.pathname === '/__mock/reset') reset()
      else if (url.pathname === '/__mock/config') cfg = { ...cfg, ...body }
      else if (url.pathname === '/__mock/expire-tokens') for (const v of tokens.values()) v.exp = 0
      return json(res, 200, { ok: true, cfg })
    }
    if (url.pathname === '/auth/config') {
      return json(res, 200, { issuer: `${originOf(req)}${REALM}`, client_id: APP_CLIENT, scopes: 'openid profile offline_access', web_client_id: WEB_CLIENT, source_url: 'https://github.com/jboettge/odovio' }, { 'Cache-Control': 'no-store' })
    }
    if (url.pathname.startsWith(REALM)) return await oidc(req, res, url)
    if (url.pathname.startsWith('/api/')) {
      res.setHeader('Cache-Control', 'no-store')
      return await api(req, res, url)
    }
    if (STATIC_DIR) return await serveStatic(req, res, url)
    return send(res, 404, 'Nicht gefunden')
  } catch (e) {
    console.error(e)
    return fail(res, 500, 'Interner Fehler')
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Mock-Server: http://127.0.0.1:${PORT}${STATIC_DIR ? ` (SPA aus ${STATIC_DIR})` : ''}${SEED === 'large' ? ' – grosser Datenbestand' : ''}`)
})
