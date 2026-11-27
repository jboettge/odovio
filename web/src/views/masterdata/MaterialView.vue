<script setup lang="ts">
import { computed, ref } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import HistoryPanel from '../../components/HistoryPanel.vue'
import ConfirmDialog from '../../components/ConfirmDialog.vue'
import EditorModal from './EditorModal.vue'
import RowActions from './RowActions.vue'
import Pager from '../../components/Pager.vue'
import { usePager } from '../../use/pager'
import { useDebounced } from '../../use/debounced'
import { numOrNull, strOrNull, useEditor, useHistory, useStorno } from '../../composables'
import { active, all, byId, countBy } from '../../store/data'
import { role, session } from '../../store/session'
import { canWrite } from '../../lib/roles'
import { chf, byText } from '../../lib/format'

const writable = computed(() => canWrite(role.value))
const showDeleted = ref(false)
const q = ref('')
const qDebounced = useDebounced(q)
const rows = computed(() => {
  const s = qDebounced.value.trim().toLowerCase()
  return all('material_article')
    .filter((a) => showDeleted.value || !a.deleted)
    .filter((a) => !s || `${a.name} ${a.part_number ?? ''} ${a.category ?? ''}`.toLowerCase().includes(s))
    .sort((a, b) => byText(a.category ?? '', b.category ?? '') || byText(a.name, b.name))
})
const usage = computed(() => countBy('maintenance_material', 'article_id'))
const categories = computed(() => [...new Set(active('material_article').map((a) => a.category).filter(Boolean))] as string[])
const vehicles = computed(() => active('vehicle'))
// Seitenaufteilung (50/100/200) – auch bei tausenden Einträgen kleines DOM
const pager = usePager(rows, { resetOn: [showDeleted, qDebounced] })
const ed = useEditor('material_article', () => ({ name: '', part_number: '', unit: 'Stk', unit_price: null, category: '', vehicle_id: null, note: '' }))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)
function save() {
  void ed.save((f) => ({
    name: strOrNull(f.name) ?? '',
    part_number: strOrNull(f.part_number),
    unit: strOrNull(f.unit) ?? 'Stk',
    unit_price: numOrNull(f.unit_price),
    category: strOrNull(f.category),
    vehicle_id: f.vehicle_id || null,
    note: strOrNull(f.note),
  }))
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="mdm-h">
    <div class="card-header">
      <h2 id="mdm-h">Materialstamm</h2>
      <div class="actions">
        <label for="mat-q" class="sr-only">Material suchen</label>
        <input id="mat-q" v-model="q" class="input" type="search" placeholder="Suchen" />
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create()"><Icon name="plus" size="sm" />Artikel erfassen</button>
      </div>
    </div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Artikel</th><th scope="col">Artikelnummer</th><th scope="col">Kategorie</th><th scope="col">Fahrzeug</th><th scope="col" class="num">Preis</th><th scope="col" class="num">Verwendet</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="a in pager.items" :key="a.id" :class="{ 'is-deleted': a.deleted }">
            <td class="strike-cell"><strong>{{ a.name }}</strong><span v-if="a.note" class="cell-sub">{{ a.note }}</span><span v-if="a.deleted" class="badge badge-danger">storniert</span></td>
            <td class="mono">{{ a.part_number || '–' }}</td>
            <td>{{ a.category || '–' }}</td>
            <td>{{ a.vehicle_id ? byId('vehicle', a.vehicle_id)?.name : 'alle' }}</td>
            <td class="num">{{ chf(a.unit_price) }} / {{ a.unit }}</td>
            <td class="num">{{ usage[a.id] ?? 0 }}×</td>
            <RowActions :label="a.name" :writable="writable" :deleted="a.deleted" @edit="ed.edit(a)" @history="history.show('material_article', a.id)" @storno="storno.ask('material_article', a, a.name)" />
          </tr>
          <tr v-if="!rows.length"><td colspan="7" class="muted">Keine Artikel.</td></tr>
        </tbody>
      </table>
    </div>
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Artikel" />
  </section>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Artikel bearbeiten' : 'Artikel erfassen'" :busy="ed.state.busy" :error="ed.state.error" :dirty="ed.dirty" @close="ed.close" @save="save">
    <Field v-slot="f" label="Bezeichnung" required :error="e.name"><input :id="f.id" v-model="ed.state.form.name" class="input" maxlength="150" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Artikelnummer" :error="e.part_number"><input :id="f.id" v-model="ed.state.form.part_number" class="input" maxlength="60" /></Field>
    <Field v-slot="f" label="Kategorie" :error="e.category">
      <input :id="f.id" v-model="ed.state.form.category" class="input" maxlength="50" list="mat-cats" />
      <datalist id="mat-cats"><option v-for="c in categories" :key="c" :value="c"></option></datalist>
    </Field>
    <Field v-slot="f" label="Fahrzeug"><select :id="f.id" v-model="ed.state.form.vehicle_id" class="select"><option :value="null">alle Fahrzeuge</option><option v-for="v in vehicles" :key="v.id" :value="v.id">{{ v.name }}</option></select></Field>
    <Field v-slot="f" label="Einheit" required :error="e.unit"><input :id="f.id" v-model="ed.state.form.unit" class="input" maxlength="20" :aria-invalid="f.invalid" /></Field>
    <Field v-slot="f" label="Preis pro Einheit (CHF)" :error="e.unit_price"><input :id="f.id" v-model="ed.state.form.unit_price" class="input" inputmode="decimal" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Notiz" span :error="e.note"><input :id="f.id" v-model="ed.state.form.note" class="input" maxlength="500" /></Field>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Artikel stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong> – bestehende Wartungen behalten ihr Material.</p>
  </ConfirmDialog>
</template>
