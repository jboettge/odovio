<script setup lang="ts">
import { computed, ref } from 'vue'
import Icon from './Icon.vue'
import HistoryPanel from './HistoryPanel.vue'
import type { ActivityItem } from '../api/types'
import { byId } from '../store/data'
import { ACTION_LABELS, ENTITY_LABELS } from '../lib/labels'
import { date, dateTime, relative } from '../lib/format'

const props = withDefaults(defineProps<{ items: ActivityItem[]; tenant: string; compact?: boolean; groupByDay?: boolean }>(), {
  compact: false,
  groupByDay: false,
})

const sel = ref<{ entity: string; id: string } | null>(null)
const ICONS: Record<string, string> = { create: 'plus', update: 'edit', delete: 'ban', close: 'lock' }

const groups = computed(() => {
  if (!props.groupByDay) return [{ day: '', items: props.items }]
  const out: { day: string; items: ActivityItem[] }[] = []
  for (const it of props.items) {
    const d = date(it.at)
    const last = out[out.length - 1]
    if (last && last.day === d) last.items.push(it)
    else out.push({ day: d, items: [it] })
  }
  return out
})

const historyEntities = new Set(Object.keys(ENTITY_LABELS).filter((e) => e !== 'member'))
</script>

<template>
  <p v-if="!items.length" class="muted">Noch keine Aktivität.</p>
  <template v-for="g in groups" :key="g.day">
    <h3 v-if="g.day" class="feed-day">{{ g.day }}</h3>
    <ul class="feed">
      <li v-for="it in g.items" :key="it.seq">
        <span :class="['feed-icon', `act-${it.action}`]"><Icon :name="ICONS[it.action] ?? 'activity'" size="sm" /></span>
        <div class="feed-main">
          <button v-if="historyEntities.has(it.entity)" type="button" class="linkish" @click="sel = { entity: it.entity, id: it.entity_id }">{{ it.summary }}</button>
          <span v-else>{{ it.summary }}</span>
          <div class="feed-meta">
            {{ it.actor_name || 'Unbekannt' }} · {{ ENTITY_LABELS[it.entity] ?? it.entity }} {{ (ACTION_LABELS[it.action] ?? it.action).toLowerCase() }}
            <template v-if="it.vehicle_id && byId('vehicle', it.vehicle_id)"> · <RouterLink :to="`/fahrzeuge/${it.vehicle_id}`">{{ byId('vehicle', it.vehicle_id)!.name }}</RouterLink></template>
          </div>
        </div>
        <time class="feed-meta nowrap" :datetime="it.at" :title="dateTime(it.at)">{{ compact ? relative(it.at) : dateTime(it.at).split(' ')[1] }}</time>
      </li>
    </ul>
  </template>
  <HistoryPanel :tenant="tenant" :entity="sel?.entity ?? null" :id="sel?.id ?? null" @close="sel = null" />
</template>
