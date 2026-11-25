<script setup lang="ts">
import { errorText } from '../store/toasts'
// Beleg-Vorschau: Datei per Bearer laden und als Blob-URL zeigen (nie direkt verlinken). Geladen wird erst, wenn
// die Vorschau sichtbar wird (IntersectionObserver); geladene Belege liegen in einem begrenzten Cache (LRU),
// verdrängte blob:-URLs werden freigegeben.
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { endpoints } from '../api/endpoints'
import type { Attachment } from '../api/types'
import { isAbort, type BlobResult } from '../api/client'
import { ATTACHMENT_KIND_LABELS } from '../lib/labels'
import { bytes } from '../lib/format'
import { openBlob, saveBlob } from '../lib/download'
import { blobCache } from '../lib/blobCache'
import Icon from './Icon.vue'

const props = defineProps<{ tenant: string; attachment: Attachment }>()
const root = ref<HTMLElement | null>(null)
const url = ref<string | null>(null)
const result = ref<BlobResult | null>(null)
const error = ref<string | null>(null)
const loading = ref(false)
let ctrl: AbortController | null = null
let visible = false
let observer: IntersectionObserver | null = null

async function load() {
  ctrl?.abort()
  url.value = null
  result.value = null
  error.value = null
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
    if (!isAbort(e)) error.value = errorText(e)
  } finally {
    if (ctrl === my) loading.value = false
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

const kind = ATTACHMENT_KIND_LABELS[props.attachment.kind] ?? props.attachment.kind
function open() {
  if (result.value) openBlob(result.value)
}
function save() {
  if (result.value) saveBlob(result.value, `Beleg_${props.attachment.id.slice(0, 8)}`)
}
</script>

<template>
  <figure ref="root" class="thumb">
    <img v-if="url" :src="url" :alt="`${kind} vom Beleg`" loading="lazy" decoding="async" />
    <div v-else class="thumb-placeholder">
      <span v-if="loading">Lädt …</span>
      <span v-else-if="error">{{ error.includes('Nicht') || error.includes('nicht') ? 'Datei noch nicht hochgeladen' : error }}</span>
      <span v-else-if="attachment.mime === 'application/pdf'"><Icon name="file" size="lg" /><br />PDF</span>
      <span v-else-if="attachment.mime === 'image/heic'">HEIC – im Browser nicht darstellbar</span>
      <span v-else>Wird geladen, sobald sichtbar …</span>
    </div>
    <figcaption class="thumb-cap">
      <span>{{ kind }} <span class="muted">· {{ bytes(attachment.size) }}</span><span v-if="attachment.deleted" class="badge badge-danger">storniert</span></span>
      <span v-if="result" class="row">
        <button v-if="attachment.mime === 'application/pdf'" type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${kind} öffnen`" @click="open"><Icon name="eye" size="sm" /></button>
        <button type="button" class="btn btn-ghost btn-icon btn-sm" :aria-label="`${kind} herunterladen`" @click="save"><Icon name="download" size="sm" /></button>
      </span>
    </figcaption>
  </figure>
</template>
