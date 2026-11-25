<script setup lang="ts">
import { errorText } from '../store/toasts'
// Seitenpanel: Verlauf eines Eintrags aus dem Änderungsprotokoll (Hash-Kette).
import { computed, ref, watch } from 'vue'
import Modal from './Modal.vue'
import Loading from './Loading.vue'
import AlertBox from './AlertBox.vue'
import { endpoints } from '../api/endpoints'
import type { Revision } from '../api/types'
import { diffRevisions, fieldLabel, valueText } from '../lib/history'
import { ACTION_LABELS, ENTITY_LABELS } from '../lib/labels'
import { dateTime, shortHash } from '../lib/format'

const props = defineProps<{ tenant: string; entity: string | null; id: string | null; title?: string }>()
const emit = defineEmits<{ close: [] }>()

const revs = ref<Revision[]>([])
const loading = ref(false)
const error = ref<string | null>(null)

watch(
  () => [props.entity, props.id] as const,
  async ([entity, id]) => {
    revs.value = []
    error.value = null
    if (!entity || !id) return
    loading.value = true
    try {
      revs.value = await endpoints.history(props.tenant, entity, id)
    } catch (e) {
      error.value = errorText(e)
    } finally {
      loading.value = false
    }
  },
  { immediate: true },
)

const items = computed(() =>
  revs.value
    .map((r, i) => ({ r, changes: diffRevisions(i > 0 ? revs.value[i - 1]! : null, r) }))
    .reverse(),
)
const heading = computed(() => props.title ?? `Verlauf: ${ENTITY_LABELS[props.entity ?? ''] ?? props.entity}`)
</script>

<template>
  <Modal :open="Boolean(entity && id)" :title="heading" variant="panel" @close="emit('close')">
    <Loading v-if="loading" text="Verlauf wird geladen …" />
    <AlertBox v-else-if="error" kind="danger" live>{{ error }}</AlertBox>
    <p v-else-if="!items.length" class="muted">Keine Einträge im Änderungsprotokoll.</p>
    <ol v-else class="timeline" aria-label="Revisionen, neueste zuerst">
      <li v-for="{ r, changes } in items" :key="r.seq">
        <span :class="['timeline-dot', `dot-${r.action}`]" aria-hidden="true"></span>
        <div class="row-between">
          <strong>{{ ACTION_LABELS[r.action] ?? r.action }} · Version {{ r.version }}</strong>
          <span v-if="r.conflict" class="badge badge-warn" title="Gleichzeitige Änderung – ältere Version überschrieben">Konflikt</span>
        </div>
        <div class="muted small">
          {{ dateTime(r.recorded_at) }} · {{ r.actor_name || 'Unbekannt' }}
          <span v-if="r.client_ts && r.client_ts.slice(0, 16) !== r.recorded_at.slice(0, 16)"> · erfasst {{ dateTime(r.client_ts) }}</span>
        </div>
        <dl v-if="changes.length" class="diff">
          <template v-for="c in changes" :key="c.field">
            <dt>{{ fieldLabel(c.field) }}</dt>
            <dd>
              <template v-if="r.action !== 'create' && items.length > 1"><del>{{ valueText(c.before) }}</del> → </template>
              <ins>{{ valueText(c.after) }}</ins>
            </dd>
          </template>
        </dl>
        <div class="muted small mono mt-1" :title="r.hash">Seq {{ r.seq }} · Hash {{ shortHash(r.hash) }}</div>
      </li>
    </ol>
  </Modal>
</template>
