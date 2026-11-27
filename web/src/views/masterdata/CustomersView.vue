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
import { strOrNull, useEditor, useHistory, useStorno } from '../../composables'
import { all, countBy } from '../../store/data'
import { role, session } from '../../store/session'
import { canWrite } from '../../lib/roles'
import { byText, byCode } from '../../lib/format'

const writable = computed(() => canWrite(role.value))
const showDeleted = ref(false)
const q = ref('')
const qDebounced = useDebounced(q)
const rows = computed(() => {
  const s = qDebounced.value.trim().toLowerCase()
  return all('customer')
    .filter((c) => showDeleted.value || !c.deleted)
    .filter((c) => !s || `${c.name} ${c.ref ?? ''} ${c.note ?? ''}`.toLowerCase().includes(s))
    .sort((a, b) => byText(a.name, b.name) || byCode(a.id, b.id))
})
// Fahrten je Kunde: einmal je Datenstand gezählt (zwischengespeichert im Store)
const tripCount = computed(() => countBy('trip', 'customer_id'))
// Seitenaufteilung (50/100/200) – auch bei tausenden Einträgen kleines DOM
const pager = usePager(rows, { resetOn: [showDeleted, qDebounced] })
const ed = useEditor('customer', () => ({ name: '', ref: '', note: '' }))
const history = useHistory()
const storno = useStorno()
const e = computed(() => ed.state.errors)
const save = () => void ed.save((f) => ({ name: strOrNull(f.name) ?? '', ref: strOrNull(f.ref), note: strOrNull(f.note) }))
</script>

<template>
  <section class="card card-flush" aria-labelledby="mdc-h">
    <div class="card-header">
      <h2 id="mdc-h">Kunden</h2>
      <div class="actions">
        <label for="cust-q" class="sr-only">Kunden suchen</label>
        <input id="cust-q" v-model="q" class="input" type="search" placeholder="Suchen" />
        <label class="check"><input v-model="showDeleted" type="checkbox" />Stornierte</label>
        <button v-if="writable" type="button" class="btn btn-primary btn-sm" @click="ed.create()"><Icon name="plus" size="sm" />Kunde erfassen</button>
      </div>
    </div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th scope="col">Name</th><th scope="col">Referenz</th><th scope="col">Notiz</th><th scope="col" class="num">Fahrten</th><th scope="col"><span class="sr-only">Aktionen</span></th></tr></thead>
        <tbody>
          <tr v-for="c in pager.items" :key="c.id" :class="{ 'is-deleted': c.deleted }">
            <td class="strike-cell"><strong>{{ c.name }}</strong><span v-if="c.deleted" class="badge badge-danger">storniert</span></td>
            <td class="mono">{{ c.ref || '–' }}</td>
            <td>{{ c.note || '–' }}</td>
            <td class="num">{{ tripCount[c.id] ?? 0 }}</td>
            <RowActions :label="c.name" :writable="writable" :deleted="c.deleted" @edit="ed.edit(c)" @history="history.show('customer', c.id)" @storno="storno.ask('customer', c, c.name)" />
          </tr>
          <tr v-if="!rows.length"><td colspan="5" class="muted">Keine Kunden.</td></tr>
        </tbody>
      </table>
    </div>
    <Pager v-model:page="pager.page" v-model:size="pager.size" :total="pager.total" label="Seiten der Kunden" />
  </section>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Kunde bearbeiten' : 'Kunde erfassen'" :busy="ed.state.busy" :error="ed.state.error" :dirty="ed.dirty" @close="ed.close" @save="save">
    <Field v-slot="f" label="Name" required :error="e.name"><input :id="f.id" v-model="ed.state.form.name" class="input" maxlength="150" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Referenz" hint="z. B. Kundennummer" :error="e.ref"><input :id="f.id" v-model="ed.state.form.ref" class="input" maxlength="50" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Notiz" span :error="e.note"><textarea :id="f.id" v-model="ed.state.form.note" class="textarea" maxlength="500"></textarea></Field>
  </EditorModal>
  <HistoryPanel :tenant="session.tenant ?? ''" :entity="history.sel.value?.entity ?? null" :id="history.sel.value?.id ?? null" @close="history.close" />
  <ConfirmDialog :open="storno.state.open" title="Kunde stornieren" confirm-label="Stornieren" danger reason="optional" :busy="storno.state.busy" :error="storno.state.error" @close="storno.close" @confirm="storno.confirm">
    <p><strong>{{ storno.state.label }}</strong> wird als storniert markiert.</p>
  </ConfirmDialog>
</template>
