<script setup lang="ts">
// Beleg-Vorschau: Datei per Bearer laden und als Blob-URL zeigen (nie direkt verlinken). Geladen wird erst, wenn
// die Vorschau sichtbar wird (IntersectionObserver); geladene Belege liegen in einem begrenzten Cache (LRU),
// verdrängte blob:-URLs werden freigegeben. Fehler nach Status: 404 = Datei (noch) nicht auf dem Server,
// sonst Meldung mit «Erneut versuchen».
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { endpoints } from '../api/endpoints'
import type { Attachment } from '../api/types'
import { ApiError, isAbort, type BlobResult } from '../api/client'
import { userMessage } from '../lib/security'
import { ATTACHMENT_KIND_LABELS } from '../lib/labels'
import { bytes, date } from '../lib/format'
import { openBlob, saveBlob } from '../lib/download'
import { blobCache } from '../lib/blobCache'
import Icon from './Icon.vue'

const props = defineProps<{ tenant: string; attachment: Attachment }>()
const root = ref<HTMLElement | null>(null)
const url = ref<string | null>(null)
const result = ref<BlobResult | null>(null)
const error = ref<string | null>(null)
/** Datei fehlt auf dem Server (404): Metadaten gespeichert, Upload nicht abgeschlossen */
const missing = ref(false)
const loading = ref(false)
let ctrl: AbortController | null = null
let visible = false
let observer: IntersectionObserver | null = null

async function load() {
  ctrl?.abort()
  url.value = null
  result.value = null
  error.value = null
  missing.value = false
  const key = `${props.tenant}:${props.attachment.id}`
  const hit = blobCache.get(key)
  if (hit) {
    result.value = hit.result
    url.value = hit.url
    return
  }
  const my = (ctrl = new AbortController())
  loading.value = true
  try {
    const res = await endpoints.attachmentBlob(props.tenant, props.attachment.id, my.signal)
    const entry = blobCache.get(key) ?? blobCache.set(key, { result: res, url: props.attachment.mime === 'image/jpeg' ? URL.createObjectURL(res.blob) : null })
    result.value = entry.result
    url.value = entry.url
  } catch (e) {
    if (isAbort(e) || ctrl !== my) return
    if (e instanceof ApiError && e.status === 404) missing.value = true
    else error.value = userMessage(e)
  } finally {
    // auch nach Abbruch (z. B. Routenwechsel) keine endlose Ladeanzeige
    if (ctrl === my) {
      loading.value = false
      ctrl = null
    }
  }
}

onMounted(() => {
  if (typeof IntersectionObserver === 'undefined' || !root.value) {
    visible = true
    void load()
    return
  }
  observer = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        visible = true
        observer?.disconnect()
        observer = null
        void load()
      }
    },
    { rootMargin: '200px' },
  )
  observer.observe(root.value)
})
watch(
  () => props.attachment.id,
  () => {
    if (visible) void load()
  },
)
onBeforeUnmount(() => {
  observer?.disconnect()
  ctrl?.abort()
})

const kind = computed(() => ATTACHMENT_KIND_LABELS[props.attachment.kind] ?? props.attachment.kind)
/** Eindeutige Bezeichnung (mehrere Belege gleicher Art im selben Dialog): Art, Aufnahmedatum, Grösse */
const desc = computed(() => [kind.value, props.attachment.taken_at ? `vom ${date(props.attachment.taken_at)}` : '', bytes(props.attachment.size)].filter(Boolean).join(', '))
function open() {
  if (result.value) openBlob(result.value)
}
function save() {
  if (result.value) saveBlob(result.value, `Beleg_${props.attachment.id.slice(0, 8)}`)
}
</script>

<template>
  <figure ref="root" class="thumb">
    <img v-if="url" :src="url" :alt="`Foto: ${desc}`" loading="lazy" decoding="async" />
    <div v-else class="thumb-placeholder">
      <span v-if="loading">Lädt …</span>
      <span v-else-if="missing">Datei nicht vorhanden – noch nicht hochgeladen</span>
      <span v-else-if="error" class="thumb-error">
        <span>{{ error }}</span>
        <button type="button" class="btn btn-sm" :aria-label="`${desc} erneut laden`" @click="load()"><Icon name="refresh" size="sm" />Erneut versuchen</button>
      </span>
      <span v-else-if="attachment.mime === 'application/pdf'"><Icon name="file" size="lg" /><br />PDF</span>
      <span v-else-if="attachment.mime === 'image/heic'">HEIC – im Browser nicht darstellbar</span>
      <span v-else>Wird geladen, sobald sichtbar …</span>
    </div>
    <figcaption class="thumb-cap">
      <span>{{ kind }} <span class="muted">· {{ bytes(attachment.size) }}</span><span v-if="attachment.deleted" class="badge badge-danger">storniert</span></span>
      <span v-if="result" class="row">
        <button v-if="attachment.mime === 'application/pdf'" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${desc} öffnen`" @click="open"><Icon name="eye" size="sm" /></button>
        <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${desc} herunterladen`" @click="save"><Icon name="download" size="sm" /></button>
      </span>
    </figcaption>
  </figure>
</template>
