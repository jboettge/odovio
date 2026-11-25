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
import { numOrNull, strOrNull, useEditor, useHistory, useStorno } from '../../composables'
import { all } from '../../store/data'
import { role, session } from '../../store/session'
import { canWrite } from '../../lib/roles'
import { chf, km, byText } from '../../lib/format'
import { FUEL_TYPE_LABELS, METHOD_LABELS, OWNERSHIP_LABELS } from '../../lib/labels'

const writable = computed(() => canWrite(role.value))
const showDeleted = ref(false)
const rows = computed(() => all('vehicle').filter((v) => showDeleted.value || !v.deleted).sort((a, b) => byText(a.name, b.name)))
// Seitenaufteilung (50/100/200) – auch bei tausenden Einträgen kleines DOM
const pager = usePager(rows, { resetOn: [showDeleted] })
const ed = useEditor('vehicle', () => ({ name: '', make: '', model: '', plate: '', fuel_type: 'benzin', initial_km: 0, purchase_price: null, ownership: 'private', private_use_method: null, annual_fixed_costs: null }))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)

function save() {
  void ed.save((f) => ({
    ...f,
    name: strOrNull(f.name) ?? '',
    make: strOrNull(f.make),
    model: strOrNull(f.model),
    plate: strOrNull(f.plate),
    initial_km: numOrNull(f.initial_km) ?? 0,
    purchase_price: numOrNull(f.purchase_price),
    annual_fixed_costs: numOrNull(f.annual_fixed_costs),
    ownership: f.ownership || null,
    private_use_method: f.ownership === 'business' ? f.private_use_method || null : null,
  }))
}
</script>

<template>
  <section class="card card-flush" aria-labelledby="mdv-h">
    <div class="card-header">
      <h2 id="mdv-h">Fahrzeuge</h2>
      <div class="actions">
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte anzeigen</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create()"><Icon name="plus" size="sm" />Fahrzeug erfassen</button>
      </div>
    </div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Name</th><th scope="col">Kennzeichen</th><th scope="col">Treibstoff</th><th scope="col" class="num">Start-km</th><th scope="col">Halter / Privatanteil</th><th scope="col" class="num">Kaufpreis</th><th scope="col" class="num">Fixkosten/Jahr</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="v in pager.items" :key="v.id" :class="{ 'is-deleted': v.deleted }">
            <td class="strike-cell"><strong>{{ v.name }}</strong><span class="cell-sub">{{ [v.make, v.model].filter(Boolean).join(' ') }}</span><span v-if="v.deleted" class="badge badge-danger">storniert</span></td>
            <td><span v-if="v.plate" class="plate">{{ v.plate }}</span></td>
            <td>{{ FUEL_TYPE_LABELS[v.fuel_type] ?? v.fuel_type }}</td>
            <td class="num">{{ km(v.initial_km) }}</td>
            <td>{{ v.ownership ? OWNERSHIP_LABELS[v.ownership] : 'nicht erfasst' }}<span v-if="v.ownership === 'business'" class="cell-sub">{{ v.private_use_method ? METHOD_LABELS[v.private_use_method] : 'Methode nicht erfasst' }}</span></td>
            <td class="num">{{ chf(v.purchase_price, 0) }}</td>
            <td class="num">{{ chf(v.annual_fixed_costs, 0) }}</td>
            <RowActions :label="v.name" :writable="writable" :deleted="v.deleted" @edit="ed.edit(v)" @history="history.show('vehicle', v.id)" @storno="storno.ask('vehicle', v, v.name)" />
          </tr>
        </tbody>
      </table>
    </div>
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Fahrzeuge" />
  </section>

  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Fahrzeug bearbeiten' : 'Fahrzeug erfassen'" :busy="ed.state.busy" :error="ed.state.error" @close="ed.close" @save="save">
    <Field v-slot="f" label="Name" required :error="e.name"><input :id="f.id" v-model="ed.state.form.name" class="input" maxlength="100" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Kennzeichen" :error="e.plate"><input :id="f.id" v-model="ed.state.form.plate" class="input" maxlength="30" placeholder="ZH 123 456" :aria-invalid="f.invalid" /></Field>
    <Field v-slot="f" label="Marke" :error="e.make"><input :id="f.id" v-model="ed.state.form.make" class="input" maxlength="100" /></Field>
    <Field v-slot="f" label="Modell" :error="e.model"><input :id="f.id" v-model="ed.state.form.model" class="input" maxlength="100" /></Field>
    <Field v-slot="f" label="Treibstoff" :error="e.fuel_type">
      <select :id="f.id" v-model="ed.state.form.fuel_type" class="select"><option v-for="(l, k) in FUEL_TYPE_LABELS" :key="k" :value="k">{{ l }}</option></select>
    </Field>
    <Field v-slot="f" label="Start-km" required :error="e.initial_km"><input :id="f.id" v-model="ed.state.form.initial_km" class="input" inputmode="numeric" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <fieldset class="fieldset span-2">
      <legend>Steuer &amp; Kosten</legend>
      <div class="form-grid">
        <Field v-slot="f" label="Halter" hint="Bestimmt Privatanteil (Geschäftsfahrzeug) oder Kilometerentschädigung (Privatfahrzeug).">
          <select :id="f.id" v-model="ed.state.form.ownership" class="select" :aria-describedby="f.describedby"><option :value="null">nicht erfasst</option><option v-for="(l, k) in OWNERSHIP_LABELS" :key="k" :value="k">{{ l }}</option></select>
        </Field>
        <Field v-if="ed.state.form.ownership === 'business'" v-slot="f" label="Methode Privatanteil">
          <select :id="f.id" v-model="ed.state.form.private_use_method" class="select"><option :value="null">nicht erfasst</option><option v-for="(l, k) in METHOD_LABELS" :key="k" :value="k">{{ l }}</option></select>
        </Field>
        <Field v-slot="f" label="Kaufpreis exkl. MWST (CHF)" :error="e.purchase_price"><input :id="f.id" v-model="ed.state.form.purchase_price" class="input" inputmode="decimal" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
        <Field v-slot="f" label="Fixkosten pro Jahr (CHF)" hint="Versicherung, Steuer, Vignette …" :error="e.annual_fixed_costs"><input :id="f.id" v-model="ed.state.form.annual_fixed_costs" class="input" inputmode="decimal" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
      </div>
    </fieldset>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Fahrzeug stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong> wird als storniert markiert. Fahrten, Tankvorgänge und Berichte bleiben erhalten.</p>
  </ConfirmDialog>
</template>
