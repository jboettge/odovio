<script setup lang="ts">
// Seitenpanel: Verlauf eines Eintrags aus dem Änderungsprotokoll (Hash-Kette). Wechselt der Eintrag während des
// Ladens, wird die alte Anfrage abgebrochen (keine veraltete Antwort im Panel).
import { computed } from 'vue'
import Modal from './Modal.vue'
import Icon from './Icon.vue'
import Loading from './Loading.vue'
import AlertBox from './AlertBox.vue'
import { endpoints } from '../api/endpoints'
import type { Revision } from '../api/types'
import { diffRevisions, fieldLabel, valueText } from '../lib/history'
import { ACTION_LABELS, ENTITY_LABELS } from '../lib/labels'
import { dateTime, shortHash } from '../lib/format'
import { useAsync } from '../use/async'

const props = defineProps<{ tenant: string; entity: string | null; id: string | null; title?: string }>()
const emit = defineEmits<{ close: [] }>()

const res = useAsync(
  () => ({ tenant: props.tenant, entity: props.entity, id: props.id }),
  (a, signal): Promise<Revision[]> => (a.entity && a.id ? endpoints.history(a.tenant, a.entity, a.id, signal) : Promise.resolve([])),
  [] as Revision[],
  { resetOnError: true },
)
const revs = res.data
const loading = res.pending
const error = res.error

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
    <AlertBox v-else-if="error" kind="danger" live>
      <p>{{ error }}</p>
      <button type="button" class="btn btn-sm" @click="res.reload()"><Icon name="refresh" size="sm" />Erneut versuchen</button>
    </AlertBox>
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
