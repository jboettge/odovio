<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import PageHeader from '../components/PageHeader.vue'
import AlertBox from '../components/AlertBox.vue'
import Field from '../components/Field.vue'
import Icon from '../components/Icon.vue'
import Loading from '../components/Loading.vue'
import RoleBadge from '../components/RoleBadge.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import { endpoints } from '../api/endpoints'
import { ApiError } from '../api/client'
import type { Member, MemberList, Role } from '../api/types'
import { loadMe, role as myRole, session } from '../store/session'
import { notify, errorText } from '../store/toasts'
import { isAdmin, lostRights, ROLE_DESCRIPTIONS, ROLE_LABELS } from '../lib/roles'
import { relative } from '../lib/format'

const ROLES: Role[] = ['admin', 'write', 'read']
const SOURCE_LABELS: Record<string, string> = { keycloak: 'Keycloak', activity: 'aus Aktivität', ldap: 'LDAP' }
const label = (m: Member) => m.name || m.username || 'Unbekannt'
/** eigene Zeile: Mitglieds-ID = Keycloak-Benutzer-ID = `sub` */
const isSelf = (m: Member) => Boolean(session.me?.sub) && m.id === session.me?.sub
const router = useRouter()
const list = ref<MemberList | null>(null)
const loading = ref(false)
const error = ref<string | null>(null)
const notConfigured = ref(false)

async function load() {
  if (!session.tenant) return
  loading.value = true
  error.value = null
  try {
    list.value = await endpoints.members(session.tenant)
  } catch (e) {
    if (e instanceof ApiError && e.status === 501) notConfigured.value = true
    else error.value = errorText(e)
  } finally {
    loading.value = false
  }
}
watch(() => session.tenant, load, { immediate: true })

const manageable = computed(() => Boolean(list.value?.manageable) && !notConfigured.value)

function handle(e: unknown): string {
  if (e instanceof ApiError && e.status === 501) {
    notConfigured.value = true
    return 'Mitgliederverwaltung ist auf diesem Server nicht eingerichtet – bitte in Keycloak verwalten.'
  }
  if (e instanceof ApiError && e.status === 409) return e.message || 'Das Fahrzeugbuch braucht mindestens eine Person mit der Rolle «Verwalten».'
  return errorText(e)
}

// Einladen
const user = ref('')
const role = ref<Role>('write')
const inviteBusy = ref(false)
const inviteError = ref<string | null>(null)
const userError = computed(() => (user.value.trim().length > 254 ? 'höchstens 254 Zeichen' : undefined))
async function invite() {
  if (!session.tenant) return
  if (!user.value.trim()) {
    inviteError.value = 'Benutzername oder E-Mail angeben.'
    return
  }
  inviteBusy.value = true
  inviteError.value = null
  try {
    await endpoints.addMember(session.tenant, user.value.trim(), role.value)
    notify(`${user.value.trim()} hinzugefügt (${ROLE_LABELS[role.value]})`)
    user.value = ''
    await load()
  } catch (e) {
    inviteError.value = handle(e)
  } finally {
    inviteBusy.value = false
  }
}

// Rolle ändern: Auswahl ist zuerst nur ein Entwurf (Pfeiltasten im Select ändern nichts), erst «Übernehmen» speichert.
const drafts = reactive<Record<string, Role>>({})
const rowBusy = ref<string | null>(null)
function pick(m: Member, r: Role) {
  if (r === m.role) delete drafts[m.id]
  else drafts[m.id] = r
}
function discard(m: Member) {
  delete drafts[m.id]
}

/** Eigene Herabstufung: zusätzliche Bestätigung. */
const selfChange = ref<{ m: Member; to: Role } | null>(null)
const selfLoss = computed(() => (selfChange.value ? lostRights(selfChange.value.m.role, selfChange.value.to) : null))
function apply(m: Member) {
  const r = drafts[m.id]
  if (!r) return
  if (isSelf(m) && lostRights(m.role, r)) {
    selfChange.value = { m, to: r }
    return
  }
  void changeRole(m, r)
}

/** Nach einer Änderung an der eigenen Mitgliedschaft: Rechte neu laden, Seite ggf. verlassen. */
async function afterSelfChange() {
  await loadMe(true).catch(() => undefined)
  if (!isAdmin(myRole.value)) await router.push(session.tenant ? '/uebersicht' : '/')
}

async function changeRole(m: Member, r: Role) {
  if (!session.tenant || r === m.role) return
  rowBusy.value = m.id
  try {
    await endpoints.setMemberRole(session.tenant, m.id, r)
    notify(`Rolle von ${label(m)}: ${ROLE_LABELS[r]}`)
    if (isSelf(m)) await afterSelfChange()
    else await load()
  } catch (e) {
    notify(handle(e), 'error')
    await load()
  } finally {
    // Auswahl zeigt danach wieder die tatsächliche Rolle
    delete drafts[m.id]
    rowBusy.value = null
  }
}
async function confirmSelfChange() {
  const c = selfChange.value
  selfChange.value = null
  if (c) await changeRole(c.m, c.to)
}

// Entfernen
const removing = ref<Member | null>(null)
const removeBusy = ref(false)
const removeError = ref<string | null>(null)
async function remove() {
  if (!session.tenant || !removing.value) return
  removeBusy.value = true
  removeError.value = null
  try {
    const m = removing.value
    await endpoints.removeMember(session.tenant, m.id)
    notify(`${label(m)} entfernt`)
    removing.value = null
    if (isSelf(m)) await afterSelfChange()
    else await load()
  } catch (e) {
    removeError.value = handle(e)
  } finally {
    removeBusy.value = false
  }
}
</script>

<template>
  <PageHeader title="Mitglieder" :subtitle="`Wer hat Zugriff auf das Fahrzeugbuch ${session.tenant ?? ''}?`" eyebrow="Verwaltung" />

  <AlertBox v-if="notConfigured" kind="info" title="In Keycloak verwalten">
    <p>Die Mitgliederverwaltung ist auf diesem Server nicht eingerichtet. Mitglieder werden über die Keycloak-Gruppen <span class="mono">/fahrzeugbuch/{{ session.tenant }}</span> (Bearbeiten), <span class="mono">/fahrzeugbuch/{{ session.tenant }}/lesen</span> (Lesen) bzw. die Verwaltungsgruppe gepflegt.</p>
  </AlertBox>
  <Loading v-else-if="loading && !list" />
  <AlertBox v-else-if="error" kind="danger" live>{{ error }}</AlertBox>

  <template v-if="list && !notConfigured">
    <section v-if="manageable" class="card" aria-labelledby="mem-invite">
      <h2 id="mem-invite" class="section-title">Person hinzufügen</h2>
      <form class="toolbar" @submit.prevent="invite">
        <Field v-slot="f" label="Benutzername oder E-Mail" class="grow" :error="userError" hint="Die Person muss in Keycloak existieren.">
          <input :id="f.id" v-model="user" class="input" type="text" autocomplete="off" maxlength="254" :aria-invalid="f.invalid" :aria-describedby="f.describedby" />
        </Field>
        <Field v-slot="f" label="Rolle">
          <select :id="f.id" v-model="role" class="select"><option v-for="r in ROLES" :key="r" :value="r">{{ ROLE_LABELS[r] }}</option></select>
        </Field>
        <button type="submit" class="btn btn-primary" :disabled="inviteBusy"><Icon name="plus" size="sm" />{{ inviteBusy ? 'Wird hinzugefügt …' : 'Hinzufügen' }}</button>
      </form>
      <AlertBox v-if="inviteError" kind="danger" live>{{ inviteError }}</AlertBox>
      <p class="muted small">{{ ROLE_LABELS.admin }}: {{ ROLE_DESCRIPTIONS.admin }} · {{ ROLE_LABELS.write }}: {{ ROLE_DESCRIPTIONS.write }} · {{ ROLE_LABELS.read }}: {{ ROLE_DESCRIPTIONS.read }}</p>
    </section>
    <AlertBox v-else kind="info" title="In Keycloak verwalten">
      <p v-if="list.members.some((m) => m.source === 'activity')">Die Mitgliederverwaltung ist auf diesem Server nicht eingerichtet. Angezeigt werden Personen, die im Fahrzeugbuch Änderungen erfasst haben; Zugriffe werden in Keycloak (Gruppen) verwaltet.</p>
      <p v-else>Mitglieder können hier nur angesehen werden – Änderungen in Keycloak (Gruppen) vornehmen.</p>
    </AlertBox>

    <section class="card card-flush" aria-labelledby="mem-list">
      <div class="card-header"><h2 id="mem-list">Mitglieder</h2><span class="muted small">{{ list.members.length }}</span></div>
      <div class="table-wrap">
        <table class="table">
          <thead><tr><th scope="col">Name</th><th scope="col">Benutzername</th><th scope="col">E-Mail</th><th scope="col">Rolle</th><th scope="col">Quelle</th><th scope="col">Zuletzt aktiv</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
          <tbody>
            <tr v-for="m in list.members" :key="m.id">
              <td><strong>{{ label(m) }}</strong><span v-if="isSelf(m)" class="muted"> (du)</span></td>
              <td class="mono">{{ m.username || '–' }}</td>
              <td>{{ m.email || '–' }}</td>
              <td>
                <div v-if="manageable && m.role && m.source !== 'activity'" class="role-edit">
                  <label :for="`role-${m.id}`" class="sr-only">Rolle von {{ label(m) }}{{ isSelf(m) ? ' (du)' : '' }}</label>
                  <select :id="`role-${m.id}`" class="select" :value="drafts[m.id] ?? m.role" :disabled="rowBusy === m.id" @change="pick(m, ($event.target as HTMLSelectElement).value as Role)">
                    <option v-for="r in ROLES" :key="r" :value="r">{{ ROLE_LABELS[r] }}</option>
                  </select>
                  <template v-if="drafts[m.id]">
                    <button type="button" class="btn btn-primary btn-sm" :disabled="rowBusy === m.id" :aria-label="`Rolle von ${label(m)} übernehmen: ${ROLE_LABELS[m.role]} → ${ROLE_LABELS[drafts[m.id]!]}`" @click="apply(m)">Übernehmen</button>
                    <button type="button" class="btn btn-ghost btn-sm" :disabled="rowBusy === m.id" :aria-label="`Rollenänderung von ${label(m)} verwerfen`" @click="discard(m)">Verwerfen</button>
                    <span class="muted small">bisher {{ ROLE_LABELS[m.role] }}</span>
                  </template>
                </div>
                <RoleBadge v-else-if="m.role" :role="m.role" />
                <span v-else class="muted">–</span>
              </td>
              <td><span class="badge badge-outline">{{ SOURCE_LABELS[m.source] ?? m.source }}</span></td>
              <td>{{ m.last_activity_at ? relative(m.last_activity_at) : '–' }}</td>
              <td class="actions">
                <button v-if="manageable && m.source !== 'activity'" type="button" class="btn btn-ghost btn-sm" :aria-label="`${label(m)} entfernen`" @click="removing = m; removeError = null"><Icon name="trash" size="sm" />{{ isSelf(m) ? 'Mich entfernen' : 'Entfernen' }}</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </template>

  <ConfirmDialog :open="removing !== null" :title="removing && isSelf(removing) ? 'Dich selbst entfernen' : 'Mitglied entfernen'" :confirm-label="removing && isSelf(removing) ? 'Mich entfernen' : 'Entfernen'" danger :busy="removeBusy" :error="removeError" @close="removing = null" @confirm="remove">
    <template v-if="removing && isSelf(removing)">
      <AlertBox kind="danger" title="Du entfernst dich selbst">
        <p>Du verlierst damit sofort den Zugriff auf das Fahrzeugbuch «{{ session.tenant }}» und kannst das nicht selbst rückgängig machen. Erfasste Einträge bleiben erhalten.</p>
      </AlertBox>
    </template>
    <p v-else><strong>{{ removing ? label(removing) : '' }}</strong> verliert den Zugriff auf das Fahrzeugbuch «{{ session.tenant }}». Erfasste Einträge bleiben erhalten.</p>
  </ConfirmDialog>

  <ConfirmDialog :open="selfChange !== null" title="Eigene Rolle ändern" confirm-label="Rolle trotzdem ändern" danger @close="selfChange = null" @confirm="confirmSelfChange">
    <template v-if="selfChange">
      <p>Deine Rolle im Fahrzeugbuch «{{ session.tenant }}»: <strong>{{ selfChange.m.role ? ROLE_LABELS[selfChange.m.role] : '–' }}</strong> → <strong>{{ ROLE_LABELS[selfChange.to] }}</strong></p>
      <AlertBox kind="danger" title="Du stufst dich selbst herab">
        <p>Du verlierst damit sofort {{ selfLoss }} und kannst das nicht selbst rückgängig machen.</p>
      </AlertBox>
    </template>
  </ConfirmDialog>
</template>
