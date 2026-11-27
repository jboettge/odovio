<script setup lang="ts">
import { computed, ref } from 'vue'
import Field from '../../components/Field.vue'
import Icon from '../../components/Icon.vue'
import AlertBox from '../../components/AlertBox.vue'
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
import { num, byText } from '../../lib/format'
import { CATEGORIES, CATEGORY_LABELS, PLACE_KIND_LABELS } from '../../lib/labels'
import { placeCoordinateText } from '../../lib/privacy'
import type { PlaceKind } from '../../api/types'

const writable = computed(() => canWrite(role.value))
const showDeleted = ref(false)
const ORDER: PlaceKind[] = ['home', 'work', 'customer', 'other']
const rows = computed(() =>
  all('place')
    .filter((p) => showDeleted.value || !p.deleted)
    .sort((a, b) => ORDER.indexOf(a.kind) - ORDER.indexOf(b.kind) || byText(a.name, b.name)),
)
const customers = computed(() => active('customer'))
// Seitenaufteilung (50/100/200) – auch bei tausenden Einträgen kleines DOM
const pager = usePager(rows, { resetOn: [showDeleted] })
const ed = useEditor('place', () => ({ name: '', kind: 'other', lat: null, lon: null, radius_m: 150, customer_id: null, default_category: null, private: false }))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)
const hidesCoords = computed(() => ed.state.form.kind === 'home' || ed.state.form.private)

function save() {
  void ed.save((f) => ({
    ...f,
    name: strOrNull(f.name) ?? '',
    radius_m: numOrNull(f.radius_m) ?? 150,
    customer_id: f.kind === 'customer' ? f.customer_id || null : null,
    default_category: f.default_category || null,
    // Koordinaten von Wohnort/vertraulichen Orten bleiben auf dem Gerät (Server lehnt sie ab)
    lat: f.kind === 'home' || f.private ? null : f.lat,
    lon: f.kind === 'home' || f.private ? null : f.lon,
  }))
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="mdp-h">
    <div class="card-header">
      <h2 id="mdp-h">Orte</h2>
      <div class="actions">
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create()"><Icon name="plus" size="sm" />Ort erfassen</button>
      </div>
    </div>
    <p class="muted small card-header">Orte erkennen Start und Ziel von Fahrten. Koordinaten werden in der App gesetzt; Wohnort und vertrauliche Orte bleiben ohne Koordinaten auf dem Server.</p>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Name</th><th scope="col">Art</th><th scope="col">Kunde</th><th scope="col">Standardkategorie</th><th scope="col" class="num">Radius</th><th scope="col">Koordinaten</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="p in pager.items" :key="p.id" :class="{ 'is-deleted': p.deleted }">
            <td class="strike-cell"><strong>{{ p.name }}</strong> <span v-if="p.private" class="badge badge-outline"><Icon name="eyeOff" size="sm" />vertraulich</span><span v-if="p.deleted" class="badge badge-danger">storniert</span></td>
            <td>{{ PLACE_KIND_LABELS[p.kind] }}</td>
            <td>{{ byId('customer', p.customer_id)?.name ?? '–' }}</td>
            <td><CategoryBadge v-if="p.default_category" :category="p.default_category" /><span v-else class="muted">–</span></td>
            <td class="num">{{ num(p.radius_m) }} m</td>
            <td class="small">{{ placeCoordinateText(p) }}</td>
            <RowActions :label="p.name" :writable="writable" :deleted="p.deleted" @edit="ed.edit(p)" @history="history.show('place', p.id)" @storno="storno.ask('place', p, p.name)" />
          </tr>
        </tbody>
      </table>
    </div>
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Orte" />
  </section>

  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Ort bearbeiten' : 'Ort erfassen'" :busy="ed.state.busy" :error="ed.state.error" :dirty="ed.dirty" @close="ed.close" @save="save">
    <Field v-slot="f" label="Name" required :error="e.name"><input :id="f.id" v-model="ed.state.form.name" class="input" maxlength="100" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Art" required :error="e.kind">
      <select :id="f.id" v-model="ed.state.form.kind" class="select"><option v-for="k in ORDER" :key="k" :value="k">{{ PLACE_KIND_LABELS[k] }}</option></select>
    </Field>
    <Field v-if="ed.state.form.kind === 'customer'" v-slot="f" label="Kunde">
      <select :id="f.id" v-model="ed.state.form.customer_id" class="select"><option :value="null">–</option><option v-for="c in customers" :key="c.id" :value="c.id">{{ c.name }}</option></select>
    </Field>
    <Field v-slot="f" label="Standardkategorie" hint="Vorschlag für Fahrten zu diesem Ort">
      <select :id="f.id" v-model="ed.state.form.default_category" class="select" :aria-describedby="f.describedby"><option :value="null">keine</option><option v-for="c in CATEGORIES.filter((c) => c !== 'unknown')" :key="c" :value="c">{{ CATEGORY_LABELS[c] }}</option></select>
    </Field>
    <Field v-slot="f" label="Radius (m)" :error="e.radius_m" hint="50–5000 m"><input :id="f.id" v-model="ed.state.form.radius_m" class="input" inputmode="numeric" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <div class="field span-2">
      <label class="check"><input v-model="ed.state.form.private" type="checkbox" />Vertraulicher Ort (z. B. Arzt) – erscheint in Berichten ohne Adresse</label>
    </div>
    <AlertBox v-if="hidesCoords" kind="info" class="span-2">Koordinaten von {{ ed.state.form.kind === 'home' ? 'Wohnort' : 'vertraulichen Orten' }} bleiben nur auf dem Gerät und werden beim Speichern entfernt.</AlertBox>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Ort stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong> wird als storniert markiert. Bestehende Fahrten behalten ihre Bezeichnung.</p>
  </ConfirmDialog>
</template>
