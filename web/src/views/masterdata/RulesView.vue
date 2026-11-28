<script setup lang="ts">
import { computed, ref } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import CategoryBadge from '../../components/CategoryBadge.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EditorModal from './EditorModal.vue'
import RowActions from './RowActions.vue'
import Pager from '../../components/Pager.vue'
import { usePager } from '../../use/pager'
import { numOrNull, strOrNull, useEditor, useHistory, useStorno } from '../../composables'
import { active, all, byId } from '../../store/data'
import { role, session } from '../../store/session'
import { canWrite } from '../../lib/roles'
import { CATEGORIES, CATEGORY_LABELS, WEEKDAYS, weekdaysLabel } from '../../lib/labels'
import type { PurposeRule } from '../../api/types'

const writable = computed(() => canWrite(role.value))
const showDeleted = ref(false)
const rows = computed(() => all('purpose_rule').filter((r) => showDeleted.value || !r.deleted).sort((a, b) => a.priority - b.priority))
const places = computed(() => active('place'))
const customers = computed(() => active('customer'))
const vehicles = computed(() => active('vehicle'))
// Seitenaufteilung (50/100/200) – auch bei tausenden Einträgen kleines DOM
const pager = usePager(rows, { resetOn: [showDeleted] })
const ed = useEditor('purpose_rule', () => ({
  priority: 100, from_place_id: null, to_place_id: null, weekdays: '1,2,3,4,5', time_from: null, time_to: null, vehicle_id: null,
  result_category: 'business', result_purpose: '', result_customer_id: null, auto_confirm: false, origin: 'user', active: true,
}))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)

const days = computed<number[]>({
  get: () => String(ed.state.form.weekdays ?? '').split(',').filter(Boolean).map(Number),
  set: (v) => (ed.state.form.weekdays = [...v].sort().join(',') || null),
})
function toggleDay(d: number) {
  days.value = days.value.includes(d) ? days.value.filter((x) => x !== d) : [...days.value, d]
}
const placeName = (id: string | null) => (id ? (byId('place', id)?.name ?? '?') : 'beliebig')
function describe(r: PurposeRule): string {
  const time = r.time_from || r.time_to ? `, ${r.time_from ?? '00:00'}–${r.time_to ?? '24:00'}` : ''
  return `${placeName(r.from_place_id)} → ${placeName(r.to_place_id)} · ${weekdaysLabel(r.weekdays)}${time}`
}
function save() {
  void ed.save((f) => ({
    ...f,
    priority: numOrNull(f.priority) ?? 100,
    time_from: strOrNull(f.time_from),
    time_to: strOrNull(f.time_to),
    weekdays: strOrNull(f.weekdays),
    result_purpose: strOrNull(f.result_purpose),
    from_place_id: f.from_place_id || null,
    to_place_id: f.to_place_id || null,
    vehicle_id: f.vehicle_id || null,
    result_customer_id: f.result_customer_id || null,
  }))
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="mdr-h">
    <div class="card-header">
      <h2 id="mdr-h">Regeln</h2>
      <div class="actions">
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create()"><Icon name="plus" size="sm" />Regel erfassen</button>
      </div>
    </div>
    <p class="muted small card-header">«Wenn Start/Ziel/Wochentag/Zeit … dann Kategorie/Zweck/Kunde». Regeln erzeugen Vorschläge; nur ausdrücklich markierte Regeln bestätigen automatisch.</p>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col" class="num">Priorität</th><th scope="col">Wenn</th><th scope="col">Dann</th><th scope="col">Fahrzeug</th><th scope="col">Status</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="r in pager.items" :key="r.id" :class="{ 'is-deleted': r.deleted }">
            <td class="num">{{ r.priority }}</td>
            <td class="strike-cell">{{ describe(r) }}</td>
            <td><CategoryBadge :category="r.result_category" /> {{ r.result_purpose || '' }}<span v-if="r.result_customer_id" class="cell-sub">{{ byId('customer', r.result_customer_id)?.name }}</span></td>
            <td>{{ r.vehicle_id ? byId('vehicle', r.vehicle_id)?.name : 'alle' }}</td>
            <td>
              <span :class="['badge', r.active ? 'badge-ok' : 'badge-outline']">{{ r.active ? 'aktiv' : 'inaktiv' }}</span>
              <span v-if="r.auto_confirm" class="badge badge-warn">bestätigt automatisch</span>
              <span v-if="r.origin === 'learned'" class="badge badge-info">gelernt</span>
              <span v-if="r.deleted" class="badge badge-danger">storniert</span>
            </td>
            <RowActions :label="`Regel ${r.priority}`" :writable="writable" :deleted="r.deleted" @edit="ed.edit(r)" @history="history.show('purpose_rule', r.id)" @storno="storno.ask('purpose_rule', r, describe(r))" />
          </tr>
          <tr v-if="!rows.length"><td colspan="6" class="muted">Keine Regeln.</td></tr>
        </tbody>
      </table>
    </div>
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Regeln" />
  </section>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Regel bearbeiten' : 'Regel erfassen'" :busy="ed.state.busy" :error="ed.state.error" :dirty="ed.dirty" @close="ed.close" @save="save">
    <Field v-slot="f" label="Von Ort"><select :id="f.id" v-model="ed.state.form.from_place_id" class="select"><option :value="null">beliebig</option><option v-for="p in places" :key="p.id" :value="p.id">{{ p.name }}</option></select></Field>
    <Field v-slot="f" label="Nach Ort"><select :id="f.id" v-model="ed.state.form.to_place_id" class="select"><option :value="null">beliebig</option><option v-for="p in places" :key="p.id" :value="p.id">{{ p.name }}</option></select></Field>
    <fieldset class="fieldset span-2" :aria-describedby="e.weekdays ? 'rule-weekdays-err' : undefined">
      <legend>Wochentage</legend>
      <div class="row">
        <label v-for="(d, i) in WEEKDAYS" :key="d" class="check"><input type="checkbox" :checked="days.includes(i + 1)" @change="toggleDay(i + 1)" />{{ d }}</label>
      </div>
      <p v-if="e.weekdays" id="rule-weekdays-err" class="error small">{{ e.weekdays }}</p>
    </fieldset>
    <Field v-slot="f" label="Zeit von" hint="HH:MM, leer = ganzer Tag" :error="e.time_from"><input :id="f.id" v-model="ed.state.form.time_from" class="input" type="time" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Zeit bis" :error="e.time_to"><input :id="f.id" v-model="ed.state.form.time_to" class="input" type="time" :aria-invalid="f.invalid" /></Field>
    <Field v-slot="f" label="Kategorie" required :error="e.result_category">
      <select :id="f.id" v-model="ed.state.form.result_category" class="select"><option v-for="c in CATEGORIES.filter((c) => c !== 'unknown')" :key="c" :value="c">{{ CATEGORY_LABELS[c] }}</option></select>
    </Field>
    <Field v-slot="f" label="Zweck" :error="e.result_purpose"><input :id="f.id" v-model="ed.state.form.result_purpose" class="input" maxlength="300" /></Field>
    <Field v-slot="f" label="Kunde"><select :id="f.id" v-model="ed.state.form.result_customer_id" class="select"><option :value="null">–</option><option v-for="c in customers" :key="c.id" :value="c.id">{{ c.name }}</option></select></Field>
    <Field v-slot="f" label="Fahrzeug"><select :id="f.id" v-model="ed.state.form.vehicle_id" class="select"><option :value="null">alle</option><option v-for="v in vehicles" :key="v.id" :value="v.id">{{ v.name }}</option></select></Field>
    <Field v-slot="f" label="Priorität" hint="0–1000, kleiner = wichtiger" :error="e.priority"><input :id="f.id" v-model="ed.state.form.priority" class="input" inputmode="numeric" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <div class="field">
      <label class="check"><input v-model="ed.state.form.active" type="checkbox" />Aktiv</label>
      <label class="check"><input v-model="ed.state.form.auto_confirm" type="checkbox" />Automatisch bestätigen</label>
    </div>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Regel stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong></p>
  </ConfirmDialog>
</template>
