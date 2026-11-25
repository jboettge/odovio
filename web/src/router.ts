import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'
import { authState, isAuthenticated, login } from './auth/oidc'
import { gate, type GateMeta } from './lib/roles'
import { loadMe, role, selectTenant, session } from './store/session'
import { abortNavigation } from './api/navigation'

declare module 'vue-router' {
  interface RouteMeta extends GateMeta {
    title?: string
  }
}

export const routes: RouteRecordRaw[] = [
  { path: '/', name: 'start', component: () => import('./views/StartView.vue'), meta: { public: true, title: 'Start' } },
  { path: '/auth/callback', name: 'callback', component: () => import('./views/CallbackView.vue'), meta: { public: true, title: 'Anmeldung' } },
  { path: '/uebersicht', name: 'dashboard', component: () => import('./views/DashboardView.vue'), meta: { minRole: 'read', title: 'Übersicht' } },
  {
    path: '/fahrzeuge/:vid',
    component: () => import('./views/vehicle/VehicleView.vue'),
    meta: { minRole: 'read' },
    props: true,
    children: [
      { path: '', name: 'vehicle', component: () => import('./views/vehicle/VehicleOverview.vue'), meta: { minRole: 'read', title: 'Fahrzeug' } },
      { path: 'fahrten', name: 'vehicle-trips', component: () => import('./views/vehicle/VehicleTrips.vue'), meta: { minRole: 'read', title: 'Fahrten' } },
      { path: 'tanken', name: 'vehicle-fuel', component: () => import('./views/vehicle/VehicleFuel.vue'), meta: { minRole: 'read', title: 'Tankvorgänge' } },
      { path: 'wartungen', name: 'vehicle-maintenance', component: () => import('./views/vehicle/VehicleMaintenance.vue'), meta: { minRole: 'read', title: 'Wartungen' } },
      { path: 'kilometerstaende', name: 'vehicle-odometer', component: () => import('./views/vehicle/VehicleOdometer.vue'), meta: { minRole: 'read', title: 'Kilometerstände' } },
      { path: 'berichte', name: 'vehicle-reports', component: () => import('./views/vehicle/VehicleReports.vue'), meta: { minRole: 'read', title: 'Berichte' } },
      { path: 'monatsabschluss', name: 'vehicle-close', component: () => import('./views/vehicle/VehicleMonthClose.vue'), meta: { minRole: 'write', title: 'Monatsabschluss' } },
    ],
  },
  { path: '/aktivitaet', name: 'activity', component: () => import('./views/ActivityView.vue'), meta: { minRole: 'read', title: 'Aktivität' } },
  { path: '/integritaet', name: 'integrity', component: () => import('./views/IntegrityView.vue'), meta: { minRole: 'read', title: 'Integrität' } },
  {
    path: '/stammdaten',
    component: () => import('./views/masterdata/MasterdataLayout.vue'),
    meta: { minRole: 'read' },
    children: [
      { path: '', redirect: { name: 'md-vehicles' } },
      { path: 'fahrzeuge', name: 'md-vehicles', component: () => import('./views/masterdata/VehiclesView.vue'), meta: { minRole: 'read', title: 'Fahrzeuge' } },
      { path: 'orte', name: 'md-places', component: () => import('./views/masterdata/PlacesView.vue'), meta: { minRole: 'read', title: 'Orte' } },
      { path: 'kunden', name: 'md-customers', component: () => import('./views/masterdata/CustomersView.vue'), meta: { minRole: 'read', title: 'Kunden' } },
      { path: 'regeln', name: 'md-rules', component: () => import('./views/masterdata/RulesView.vue'), meta: { minRole: 'read', title: 'Regeln' } },
      { path: 'steuerparameter', name: 'md-tax', component: () => import('./views/masterdata/TaxParamsView.vue'), meta: { minRole: 'read', title: 'Steuerparameter' } },
      { path: 'material', name: 'md-material', component: () => import('./views/masterdata/MaterialView.vue'), meta: { minRole: 'read', title: 'Materialstamm' } },
    ],
  },
  { path: '/verwaltung', redirect: { name: 'members' }, meta: { minRole: 'admin' } },
  { path: '/verwaltung/mitglieder', name: 'members', component: () => import('./views/MembersView.vue'), meta: { minRole: 'admin', title: 'Mitglieder' } },
  { path: '/konto', name: 'account', component: () => import('./views/AccountView.vue'), meta: { title: 'Konto' } },
  { path: '/kein-zugriff', name: 'forbidden', component: () => import('./views/ForbiddenView.vue'), meta: { title: 'Kein Zugriff' } },
  { path: '/:pathMatch(.*)*', name: 'notfound', component: () => import('./views/NotFoundView.vue'), meta: { public: true, title: 'Nicht gefunden' } },
]

export const router = createRouter({
  history: createWebHistory('/'),
  routes,
  scrollBehavior: (_to, _from, saved) => saved ?? { top: 0 },
})

router.beforeEach(async (to) => {
  const meta = to.meta
  if (meta.public) return true
  if (!isAuthenticated()) {
    if (authState.error) return { name: 'start' }
    await login(to.fullPath)
    return false
  }
  try {
    await loadMe()
  } catch {
    return { name: 'start' }
  }
  // Deep-Link mit Fahrzeugbuch, z. B. /verwaltung/mitglieder?buch=privat
  const buch = to.query.buch
  if (typeof buch === 'string' && buch && buch !== session.tenant) {
    if (!selectTenant(buch)) return { name: 'forbidden', query: { from: to.fullPath, buch } }
  }
  const result = gate(meta, { authenticated: true, role: role.value, tenant: session.tenant })
  if (result === 'choose-tenant') return { name: 'start', query: { returnTo: to.fullPath } }
  if (result === 'forbidden') return { name: 'forbidden', query: { from: to.fullPath } }
  return true
})

router.afterEach((to, from, failure) => {
  // Seite verlassen: noch offene GETs der alten Seite abbrechen (nicht bei reinen Query-Änderungen)
  if (!failure && to.path !== from.path) abortNavigation()
  const title = [...to.matched].reverse().find((r) => r.meta.title)?.meta.title
  document.title = title ? `${title} – Fahrzeugbuch` : 'Fahrzeugbuch'
})
