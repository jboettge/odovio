<script setup lang="ts">
// Wartung im Web erfassen/bearbeiten: Kopfdaten, Checkliste, Material (aus dem Stamm oder frei, Menge änderbar)
// und Belege – alles in einem Sync (Wartung zuerst, dann Positionen und Belege).
import { computed, ref } from 'vue'
import Field from '../../../components/Field.vue'
import Icon from '../../../components/Icon.vue'
import CorrectionReason from '../../../components/CorrectionReason.vue'
import ReceiptPicker from '../../../components/ReceiptPicker.vue'
import EditorModal from '../../masterdata/EditorModal.vue'
import { correctionNeedsReason, numOrNull, strOrNull, useEditor } from '../../../composables'
import { useKmContext } from '../../../use/kmContext'
import { all, childrenOf } from '../../../store/data'
import { attachmentOp, uploadReceipts } from '../../../store/uploads'
import type { Maintenance, MaintenanceItem, MaintenanceMaterial, SyncOp } from '../../../api/types'
import { deleteOp, toData, upsertOp, uuid, validate } from '../../../lib/schema'
import { byText, chf, isoDate } from '../../../lib/format'
import { MIN_REASON } from '../../../lib/trips'
import type { PreparedReceipt } from '../../../lib/receipts'

interface ItemRow {
  id: string
  label: string
  done: boolean
}
interface MaterialRow {
  id: string
  article_id: string | null
  name: string
  part_number: string
  quantity: string | number
  unit: string
  unit_price: string | number | null
}

const { vid, tenant, warn } = useKmContext()
const ed = useEditor('maintenance', () => ({ vehicle_id: vid.value, date: isoDate(), km: '', title: '', cost: '', note: '', next_due_km: '', next_due_date: '' }))
const e = computed(() => ed.state.errors)
const original = ref<Maintenance | null>(null)
const reason = ref('')
const reasonError = ref<string | undefined>()
const items = ref<ItemRow[]>([])
const materials = ref<MaterialRow[]>([])
const rowErrors = ref<Record<string, string>>({})
const added = ref<PreparedReceipt[]>([])
const removed = ref<string[]>([])
const pick = ref('')
let origItems = new Map<string, MaintenanceItem>()
let origMaterials = new Map<string, MaintenanceMaterial>()

const existing = computed(() => (ed.state.id ? childrenOf('attachment', 'maintenance_id', ed.state.id) : []))
const articles = computed(() =>
  all('material_article').filter((a) => !a.deleted && (a.vehicle_id === null || a.vehicle_id === vid.value)).sort((a, b) => byText(a.name, b.name)),
)
const needsReason = computed(() => correctionNeedsReason(vid.value, ed.state.form.date, ed.state.form.km, original.value))
const kmWarn = computed(() => warn(ed.state.form.date, numOrNull(ed.state.form.km), ed.state.id))
const lineTotal = (m: MaterialRow) => {
  const q = numOrNull(m.quantity)
  const p = numOrNull(m.unit_price)
  return q !== null && p !== null && Number.isFinite(q) && Number.isFinite(p) ? q * p : 0
}
const materialSum = computed(() => materials.value.reduce((a, m) => a + lineTotal(m), 0))

const active = <T extends { deleted: boolean; position: number }>(xs: T[]) => xs.filter((x) => !x.deleted).sort((a, b) => a.position - b.position)

function open(rec: Maintenance | null) {
  original.value = rec
  reason.value = ''
  reasonError.value = undefined
  rowErrors.value = {}
  added.value = []
  removed.value = []
  pick.value = ''
  const its = rec ? active(childrenOf('maintenance_item', 'maintenance_id', rec.id)) : []
  const mats = rec ? active(childrenOf('maintenance_material', 'maintenance_id', rec.id)) : []
  origItems = new Map(its.map((x) => [x.id, x]))
  origMaterials = new Map(mats.map((x) => [x.id, x]))
  items.value = its.map((x) => ({ id: x.id, label: x.label, done: x.done }))
  materials.value = mats.map((x) => ({ id: x.id, article_id: x.article_id, name: x.name, part_number: x.part_number ?? '', quantity: x.quantity, unit: x.unit, unit_price: x.unit_price }))
  if (rec) ed.edit(rec, { km: rec.km ?? '', cost: rec.cost ?? '', next_due_km: rec.next_due_km ?? '', next_due_date: rec.next_due_date ?? '' })
  else ed.create()
}
defineExpose({ create: () => open(null), edit: (rec: Maintenance) => open(rec) })

const addItem = () => items.value.push({ id: uuid(), label: '', done: true })
const addFree = () => materials.value.push({ id: uuid(), article_id: null, name: '', part_number: '', quantity: 1, unit: 'Stk', unit_price: null })
function addArticle() {
  const a = articles.value.find((x) => x.id === pick.value)
  pick.value = ''
  if (!a) return
  materials.value.push({ id: uuid(), article_id: a.id, name: a.name, part_number: a.part_number ?? '', quantity: 1, unit: a.unit, unit_price: a.unit_price })
}
const removeAt = <T,>(list: T[], i: number) => list.splice(i, 1)

const same = (entity: 'maintenance_item' | 'maintenance_material', a: object, b: object) => JSON.stringify(toData(entity, a)) === JSON.stringify(toData(entity, b))

function itemData(mid: string, it: ItemRow, i: number) {
  return { maintenance_id: mid, label: it.label.trim(), done: it.done, position: i }
}
function materialData(mid: string, m: MaterialRow, i: number) {
  return { maintenance_id: mid, article_id: m.article_id, name: m.name.trim(), part_number: strOrNull(m.part_number), quantity: numOrNull(m.quantity), unit: m.unit.trim(), unit_price: numOrNull(m.unit_price), position: i }
}

/** Positionen prüfen (Zeilenfehler je Feld: `${id}.${feld}`). */
function checkRows(): boolean {
  const errs: Record<string, string> = {}
  items.value.forEach((it, i) => {
    for (const [f, m] of Object.entries(validate('maintenance_item', itemData('x', it, i)))) if (f !== 'maintenance_id') errs[`${it.id}.${f}`] = m
  })
  materials.value.forEach((m, i) => {
    for (const [f, msg] of Object.entries(validate('maintenance_material', materialData('x', m, i)))) if (f !== 'maintenance_id') errs[`${m.id}.${f}`] = msg
  })
  rowErrors.value = errs
  return !Object.keys(errs).length
}

function childOps(mid: string, receipts: PreparedReceipt[]): SyncOp[] {
  const ops: SyncOp[] = []
  items.value.forEach((it, i) => {
    const data = itemData(mid, it, i)
    const o = origItems.get(it.id)
    if (!o || !same('maintenance_item', o, data)) ops.push(upsertOp('maintenance_item', it.id, data, o?.version ?? null))
  })
  for (const o of origItems.values()) if (!items.value.some((x) => x.id === o.id)) ops.push(deleteOp('maintenance_item', o.id, o.version))
  materials.value.forEach((m, i) => {
    const data = materialData(mid, m, i)
    const o = origMaterials.get(m.id)
    if (!o || !same('maintenance_material', o, data)) ops.push(upsertOp('maintenance_material', m.id, data, o?.version ?? null))
  })
  for (const o of origMaterials.values()) if (!materials.value.some((x) => x.id === o.id)) ops.push(deleteOp('maintenance_material', o.id, o.version))
  for (const r of receipts) ops.push(attachmentOp(r, { maintenance_id: mid }, vid.value))
  for (const a of existing.value) if (removed.value.includes(a.id) && !a.deleted) ops.push(deleteOp('attachment', a.id, a.version))
  return ops
}

function save() {
  const rowsOk = checkRows()
  if (needsReason.value && reason.value.trim().length < MIN_REASON) {
    reasonError.value = `Begründung mit mindestens ${MIN_REASON} Zeichen erforderlich`
    return
  }
  reasonError.value = undefined
  if (!rowsOk) {
    ed.state.error = 'Bitte die markierten Positionen prüfen.'
    return
  }
  const receipts = added.value
  void ed.save(
    (f) => ({
      ...f,
      vehicle_id: vid.value,
      km: numOrNull(f.km),
      title: strOrNull(f.title) ?? '',
      cost: numOrNull(f.cost),
      note: strOrNull(f.note),
      next_due_km: numOrNull(f.next_due_km),
      next_due_date: strOrNull(f.next_due_date),
    }),
    {
      reason: needsReason.value ? reason.value : undefined,
      extra: (id) => childOps(id, receipts),
      after: async () => {
        if (receipts.length) await uploadReceipts(tenant.value, receipts)
      },
    },
  )
}
const err = (id: string, f: string) => rowErrors.value[`${id}.${f}`]
</script>

<template>
  <EditorModal :open="ed.state.open" :title="ed.state.id ? 'Wartung bearbeiten' : 'Wartung erfassen'" :busy="ed.state.busy" :error="ed.state.error" @close="ed.close" @save="save">
    <Field v-slot="f" label="Bezeichnung" required span :error="e.title"><input :id="f.id" v-model="ed.state.form.title" class="input" maxlength="150" placeholder="z. B. Service 60 000 km, Pneuwechsel" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Datum" required :error="e.date"><input :id="f.id" v-model="ed.state.form.date" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Kilometerstand" :error="e.km" :warning="kmWarn"><input :id="f.id" v-model="ed.state.form.km" class="input" inputmode="numeric" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Kosten (CHF)" :error="e.cost" :hint="`Leer = Summe Material (${chf(materialSum)})`"><input :id="f.id" v-model="ed.state.form.cost" class="input" inputmode="decimal" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
    <Field v-slot="f" label="Notiz" :error="e.note"><textarea :id="f.id" v-model="ed.state.form.note" class="textarea" maxlength="2000"></textarea></Field>
    <fieldset class="fieldset span-2">
      <legend>Nächste Wartung</legend>
      <div class="form-grid">
        <Field v-slot="f" label="Bei Kilometerstand" :error="e.next_due_km"><input :id="f.id" v-model="ed.state.form.next_due_km" class="input" inputmode="numeric" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
        <Field v-slot="f" label="Spätestens am" :error="e.next_due_date"><input :id="f.id" v-model="ed.state.form.next_due_date" type="date" class="input" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
      </div>
    </fieldset>

    <fieldset class="fieldset span-2">
      <legend>Checkliste</legend>
      <div v-if="items.length" class="subrows">
        <div v-for="(it, i) in items" :key="it.id" class="subrow subrow-check">
          <label class="check"><input v-model="it.done" type="checkbox" :aria-label="`Position ${i + 1} erledigt`" /></label>
          <div class="field">
            <input v-model="it.label" class="input" maxlength="200" :aria-label="`Checkliste Position ${i + 1}`" placeholder="z. B. Ölwechsel" :aria-invalid="err(it.id, 'label') ? true : undefined" />
            <span v-if="err(it.id, 'label')" class="error">{{ err(it.id, 'label') }}</span>
          </div>
          <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Checkliste Position ${i + 1} entfernen`" @click="removeAt(items, i)"><Icon name="trash" size="sm" /></button>
        </div>
      </div>
      <p v-else class="muted small">Keine Positionen.</p>
      <button type="button" class="btn btn-sm mt-1" @click="addItem"><Icon name="plus" size="sm" />Position hinzufügen</button>
    </fieldset>

    <fieldset class="fieldset span-2">
      <legend>Material</legend>
      <div v-if="materials.length" class="subrows">
        <div v-for="(m, i) in materials" :key="m.id" class="subrow subrow-material">
          <Field v-slot="f" :label="`Artikel ${i + 1}`" :error="err(m.id, 'name')"><input :id="f.id" v-model="m.name" class="input" maxlength="150" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
          <Field v-slot="f" label="Teilenummer" :error="err(m.id, 'part_number')"><input :id="f.id" v-model="m.part_number" class="input mono" maxlength="60" /></Field>
          <Field v-slot="f" label="Menge" :error="err(m.id, 'quantity')"><input :id="f.id" v-model="m.quantity" class="input" inputmode="decimal" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
          <Field v-slot="f" label="Einheit" :error="err(m.id, 'unit')"><input :id="f.id" v-model="m.unit" class="input" maxlength="20" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
          <Field v-slot="f" label="Preis/Einheit" :error="err(m.id, 'unit_price')"><input :id="f.id" v-model="m.unit_price" class="input" inputmode="decimal" autocomplete="off" :aria-invalid="f.invalid" :aria-describedby="f.describedby" /></Field>
          <span class="subrow-total">{{ chf(lineTotal(m)) }}</span>
          <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`Material ${i + 1} entfernen`" @click="removeAt(materials, i)"><Icon name="trash" size="sm" /></button>
        </div>
        <p class="small"><strong>Material total {{ chf(materialSum) }}</strong></p>
      </div>
      <p v-else class="muted small">Kein Material.</p>
      <div class="row mt-1">
        <select v-if="articles.length" v-model="pick" class="select select-inline" aria-label="Material aus dem Stamm wählen" @change="addArticle">
          <option value="">Aus dem Stamm hinzufügen …</option>
          <option v-for="a in articles" :key="a.id" :value="a.id">{{ a.name }}{{ a.part_number ? ` (${a.part_number})` : '' }}{{ a.unit_price !== null ? ` · ${chf(a.unit_price)}/${a.unit}` : '' }}</option>
        </select>
        <button type="button" class="btn btn-sm" @click="addFree"><Icon name="plus" size="sm" />Freie Position</button>
      </div>
    </fieldset>

    <ReceiptPicker v-model:added="added" v-model:removed="removed" :existing="existing" />
    <CorrectionReason v-if="needsReason" v-model="reason" :error="reasonError" />
  </EditorModal>
</template>
