<script setup lang="ts">
import { errorText } from '../../store/toasts'
import { computed, ref, watch } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import AlertBox from '../../components/AlertBox.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EditorModal from './EditorModal.vue'
import RowActions from './RowActions.vue'
import { numOrNull, strOrNull, useEditor, useHistory, useStorno } from '../../composables'
import { active, all } from '../../store/data'
import { role, session } from '../../store/session'
import { canWrite } from '../../lib/roles'
import { endpoints } from '../../api/endpoints'
import type { TaxKey, YearReportParam } from '../../api/types'
import { num } from '../../lib/format'
import { safeHref } from '../../lib/security'
import { TAX_KEYS, TAX_KEY_LABELS, TAX_UNITS, scopeLabel } from '../../lib/labels'

const writable = computed(() => canWrite(role.value))
const thisYear = new Date().getFullYear()
const year = ref(thisYear)
const years = computed(() => {
  const ys = new Set([thisYear + 1, thisYear, thisYear - 1, ...all('tax_param').map((p) => p.year)])
  return [...ys].sort((a, b) => b - a)
})
const showDeleted = ref(false)
const rows = computed(() =>
  all('tax_param')
    .filter((p) => p.year === year.value && (showDeleted.value || !p.deleted))
    .sort((a, b) => TAX_KEYS.indexOf(a.key) - TAX_KEYS.indexOf(b.key) || a.scope.localeCompare(b.scope)),
)

// Wirksame Werte (inkl. Standard-Annahmen des Servers) über den Jahresbericht des ersten Fahrzeugs
const effective = ref<Record<string, YearReportParam> | null>(null)
const effectiveError = ref<string | null>(null)
watch(
  [year, () => active('vehicle')[0]?.id, () => rows.value.length],
  async ([y, vid]) => {
    effective.value = null
    effectiveError.value = null
    if (!vid || !session.tenant) return
    try {
      effective.value = (await endpoints.yearReport(session.tenant, vid, y)).params
    } catch (e) {
      effectiveError.value = errorText(e)
    }
  },
  { immediate: true },
)

const ed = useEditor('tax_param', () => ({ year: year.value, scope: 'tenant', key: 'km_rate', value: null, source_url: '', note: '' }))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)
const scopeKind = computed({
  get: () => (String(ed.state.form.scope ?? '').startsWith('canton:') ? 'canton' : String(ed.state.form.scope ?? 'tenant')),
  set: (v: string) => (ed.state.form.scope = v === 'canton' ? 'canton:' : v),
})
const canton = computed({
  get: () => String(ed.state.form.scope ?? '').replace(/^canton:/, ''),
  set: (v: string) => (ed.state.form.scope = `canton:${v.toUpperCase().slice(0, 2)}`),
})
function save() {
  void ed.save((f) => ({ ...f, year: numOrNull(f.year), value: numOrNull(f.value), source_url: strOrNull(f.source_url), note: strOrNull(f.note) }))
}
const unit = (k: string) => TAX_UNITS[k as TaxKey] ?? ''
</script>

<template>
  <AlertBox kind="warn" title="Annahmen – mit Treuhand prüfen" class="mt-0">
    <p>Steuerparameter sind Annahmen gemäss Konzept (Stand 11/2026). Die Berechnungen sind Hilfsgrössen und ersetzen keine Steuerberatung; massgebend sind Spesenreglement, Lohnausweis und kantonale Praxis.</p>
  </AlertBox>
  <section class="card card-flush mt-2" aria-labelledby="mdt-h">
    <div class="card-header">
      <h2 id="mdt-h">Steuerparameter {{ year }}</h2>
      <div class="actions">
        <label for="tax-year" class="sr-only">Jahr</label>
        <select id="tax-year" v-model.number="year" class="select"><option v-for="y in years" :key="y" :value="y">{{ y }}</option></select>
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create({ year })"><Icon name="plus" size="sm" />Parameter erfassen</button>
      </div>
    </div>
    <p class="muted small card-header">Vorrang: Fahrzeugbuch vor Kanton vor Bund vor Standard-Annahme. Änderungen sind nur im Web möglich und werden protokolliert.</p>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Parameter</th><th scope="col">Geltung</th><th scope="col" class="num">Wert</th><th scope="col">Quelle / Notiz</th><th scope="col">Erfasst von</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="p in rows" :key="p.id" :class="{ 'is-deleted': p.deleted }">
            <td class="strike-cell"><strong>{{ TAX_KEY_LABELS[p.key] }}</strong><span class="cell-sub mono">{{ p.key }}</span><span v-if="p.deleted" class="badge badge-danger">storniert</span></td>
            <td>{{ scopeLabel(p.scope) }}</td>
            <td class="num">{{ num(p.value, 0, 3) }} {{ unit(p.key) }}</td>
            <td><a v-if="safeHref(p.source_url)" :href="safeHref(p.source_url)!" target="_blank" rel="noopener noreferrer">Quelle</a><span v-else-if="p.source_url" class="cell-sub">{{ p.source_url }}</span><span class="cell-sub">{{ p.note }}</span></td>
            <td>{{ p.updated_by || p.created_by || '–' }}</td>
            <RowActions :label="TAX_KEY_LABELS[p.key]" :writable="writable" :deleted="p.deleted" @edit="ed.edit(p)" @history="history.show('tax_param', p.id)" @storno="storno.ask('tax_param', p, `${TAX_KEY_LABELS[p.key]} ${p.year} (${scopeLabel(p.scope)})`)" />
          </tr>
          <tr v-if="!rows.length"><td colspan="6" class="muted">Keine eigenen Parameter für {{ year }} – es gelten die Standard-Annahmen.</td></tr>
        </tbody>
      </table>
    </div>
  </section>

  <section class="card mt-2" aria-labelledby="mdt-eff">
    <h2 id="mdt-eff" class="section-title">Wirksame Werte {{ year }}</h2>
    <p v-if="effectiveError" class="muted">{{ effectiveError }}</p>
    <p v-else-if="!effective" class="muted">Wird ermittelt … (benötigt mindestens ein Fahrzeug)</p>
    <div v-else class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Parameter</th><th scope="col" class="num">Wert</th><th scope="col">Herkunft</th><th scope="col">Hinweis</th></tr></thead>
        <tbody>
          <tr v-for="(p, k) in effective" :key="k">
            <td>{{ TAX_KEY_LABELS[k as TaxKey] ?? p.label }}</td>
            <td class="num">{{ num(p.value, 0, 3) }} {{ unit(String(k)) }}</td>
            <td><span :class="['badge', p.scope === 'default' ? 'badge-warn' : 'badge-ok']">{{ scopeLabel(p.scope) }}</span></td>
            <td class="small muted">{{ p.note }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>

  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Steuerparameter bearbeiten' : 'Steuerparameter erfassen'" :busy="ed.state.busy" :error="ed.state.error" @close="ed.close" @save="save">
    <Field v-slot="f" label="Parameter" required :error="e.key">
      <select :id="f.id" v-model="ed.state.form.key" class="select"><option v-for="k in TAX_KEYS" :key="k" :value="k">{{ TAX_KEY_LABELS[k] }} ({{ TAX_UNITS[k] }})</option></select>
    </Field>
    <Field v-slot="f" label="Jahr" required :error="e.year"><input :id="f.id" v-model="ed.state.form.year" class="input" inputmode="numeric" :aria-invalid="f.invalid" /></Field>
    <Field v-slot="f" label="Geltung" required :error="e.scope">
      <select :id="f.id" v-model="scopeKind" class="select"><option value="tenant">Fahrzeugbuch</option><option value="canton">Kanton</option><option value="federal">Bund</option></select>
    </Field>
    <Field v-if="scopeKind === 'canton'" v-slot="f" label="Kanton (Kürzel)" hint="z. B. ZH, BE"><input :id="f.id" v-model="canton" class="input" maxlength="2" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" :label="`Wert (${unit(String(ed.state.form.key))})`" required :error="e.value"><input :id="f.id" v-model="ed.state.form.value" class="input" inputmode="decimal" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Quelle (URL)" :error="e.source_url"><input :id="f.id" v-model="ed.state.form.source_url" class="input" type="url" maxlength="300" /></Field>
    <Field v-slot="f" label="Notiz" span :error="e.note"><input :id="f.id" v-model="ed.state.form.note" class="input" maxlength="300" /></Field>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Steuerparameter stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong> – danach gilt der nächstrangige Wert bzw. die Standard-Annahme.</p>
  </ConfirmDialog>
</template>
