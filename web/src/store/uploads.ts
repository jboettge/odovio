// Beleg-Dateien nach dem Speichern der Metadaten hochladen. Fehlgeschlagene Uploads bleiben (nur in diesem
// Tab) zum erneuten Versuch erhalten; die Metadaten sind dann bereits gespeichert (ID und Prüfsumme fest).
import { computed, reactive } from 'vue'
import { endpoints } from '../api/endpoints'
import type { Attachment, SyncOp } from '../api/types'
import { localIsoTs, upsertOp } from '../lib/schema'
import type { PreparedReceipt } from '../lib/receipts'
import { errorText, notify } from './toasts'

interface Pending {
  tenant: string
  receipt: PreparedReceipt
  error: string | null
  busy: boolean
}

const pending = reactive(new Map<string, Pending>())

export const pendingUploads = computed(() => [...pending.values()])

/** Metadaten-Op eines neuen Belegs (Tankvorgang oder Wartung). */
export function attachmentOp(r: PreparedReceipt, parent: { fuel_id?: string; maintenance_id?: string }, vehicleId: string, kind: Attachment['kind'] = 'receipt'): SyncOp {
  return upsertOp('attachment', r.id, {
    fuel_id: parent.fuel_id ?? null,
    maintenance_id: parent.maintenance_id ?? null,
    vehicle_id: vehicleId,
    kind,
    sha256: r.sha256,
    mime: r.mime,
    size: r.size,
    taken_at: localIsoTs(),
    note: r.name.slice(0, 300),
  }, null, undefined, r.id) // op_id = Beleg-ID: Wiederholung wird dedupliziert
}

async function uploadOne(p: Pending): Promise<boolean> {
  p.busy = true
  p.error = null
  try {
    await endpoints.uploadAttachment(p.tenant, p.receipt.id, p.receipt.blob, p.receipt.mime)
    pending.delete(p.receipt.id)
    return true
  } catch (e) {
    p.error = errorText(e)
    return false
  } finally {
    p.busy = false
  }
}

/** Dateien hochladen (nacheinander). Rückgabe: Anzahl fehlgeschlagener Uploads. */
export async function uploadReceipts(tenant: string, receipts: PreparedReceipt[]): Promise<number> {
  let failed = 0
  for (const receipt of receipts) {
    const p = reactive<Pending>({ tenant, receipt, error: null, busy: false })
    pending.set(receipt.id, p)
    if (!(await uploadOne(p))) failed++
  }
  if (failed) notify(`${failed} Beleg${failed === 1 ? '' : 'e'} nicht hochgeladen – unten erneut versuchen.`, 'error')
  return failed
}

export async function retryUpload(id: string): Promise<void> {
  const p = pending.get(id)
  if (p && !p.busy && (await uploadOne(p))) notify('Beleg hochgeladen')
}

export function discardUpload(id: string): void {
  pending.delete(id)
}

/** nur für Tests */
export function _resetUploads(): void {
  pending.clear()
}
