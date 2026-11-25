<script setup lang="ts">
import { errorText } from '../store/toasts'
// Beleg-Vorschau: Datei per Bearer laden und als Blob-URL zeigen (nie direkt verlinken).
import { onBeforeUnmount, ref, watch } from 'vue'
import { endpoints } from '../api/endpoints'
import type { Attachment } from '../api/types'
import type { BlobResult } from '../api/client'
import { ATTACHMENT_KIND_LABELS } from '../lib/labels'
import { bytes } from '../lib/format'
import { openBlob, saveBlob } from '../lib/download'
import Icon from './Icon.vue'

const props = defineProps<{ tenant: string; attachment: Attachment }>()
const url = ref<string | null>(null)
const result = ref<BlobResult | null>(null)
const error = ref<string | null>(null)
const loading = ref(false)

async function load() {
  if (url.value) URL.revokeObjectURL(url.value)
  url.value = null
  result.value = null
  error.value = null
  loading.value = true
  try {
    const res = await endpoints.attachmentBlob(props.tenant, props.attachment.id)
    result.value = res
    if (props.attachment.mime === 'image/jpeg') url.value = URL.createObjectURL(res.blob)
  } catch (e) {
    error.value = errorText(e)
  } finally {
    loading.value = false
  }
}

watch(() => props.attachment.id, load, { immediate: true })
onBeforeUnmount(() => url.value && URL.revokeObjectURL(url.value))

const kind = ATTACHMENT_KIND_LABELS[props.attachment.kind] ?? props.attachment.kind
function open() {
  if (result.value) openBlob(result.value)
}
function save() {
  if (result.value) saveBlob(result.value, `Beleg_${props.attachment.id.slice(0, 8)}`)
}
</script>

<template>
  <figure class="thumb">
    <img v-if="url" :src="url" :alt="`${kind} vom Beleg`" />
    <div v-else class="thumb-placeholder">
      <span v-if="loading">Lädt …</span>
      <span v-else-if="error">{{ error.includes('Nicht') || error.includes('nicht') ? 'Datei noch nicht hochgeladen' : error }}</span>
      <span v-else-if="attachment.mime === 'application/pdf'"><Icon name="file" size="lg" /><br />PDF</span>
      <span v-else>HEIC – im Browser nicht darstellbar</span>
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
