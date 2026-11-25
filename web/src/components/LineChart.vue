<script setup lang="ts">
// Liniendiagramm mit Referenzlinie (z. B. Ø-Verbrauch), Fadenkreuz-Tooltip, Tastaturbedienung
// (Pfeiltasten) und Datentabelle. Reines SVG, keine Inline-Styles.
import { computed, ref } from 'vue'
import { niceTicks, scale } from '../lib/chart'
import { useWidth } from './useWidth'

export interface LinePoint {
  label: string
  value: number
  detail?: string
}

const props = withDefaults(
  defineProps<{
    title: string
    points: LinePoint[]
    refValue?: number | null
    refLabel?: string
    format: (v: number) => string
    seriesLabel: string
    unit?: string
    height?: number
  }>(),
  { refValue: null, refLabel: 'Ø', unit: '', height: 240 },
)

const wrap = ref<HTMLElement | null>(null)
const width = useWidth(wrap)
const active = ref<number | null>(null)
const M = { top: 16, right: 64, bottom: 30, left: 52 }

const geo = computed(() => {
  const w = Math.max(280, width.value)
  const h = props.height
  const vals = props.points.map((p) => p.value)
  if (props.refValue !== null && props.refValue !== undefined) vals.push(props.refValue)
  const ticks = niceTicks(Math.min(...vals), Math.max(...vals), 5)
  const y = scale(ticks[0]!, ticks[ticks.length - 1]!, h - M.bottom, M.top)
  const n = props.points.length
  const x = (i: number) => (n <= 1 ? (M.left + w - M.right) / 2 : M.left + (i * (w - M.left - M.right)) / (n - 1))
  const pts = props.points.map((p, i) => ({ ...p, cx: x(i), cy: y(p.value) }))
  const path = pts.map((p, i) => `${i ? 'L' : 'M'}${p.cx.toFixed(1)},${p.cy.toFixed(1)}`).join(' ')
  const step = Math.max(1, Math.ceil(n / Math.max(2, Math.floor((w - M.left - M.right) / 90))))
  const xLabels = pts.filter((_, i) => i % step === 0 || i === n - 1)
  const slot = n > 1 ? (w - M.left - M.right) / (n - 1) : w - M.left - M.right
  const tickStep = ticks.length > 1 ? Math.abs(ticks[1]! - ticks[0]!) : 1
  const decimals = Math.max(0, Math.min(3, -Math.floor(Math.log10(tickStep))))
  const tickFmt = new Intl.NumberFormat('de-CH', { minimumFractionDigits: decimals, maximumFractionDigits: decimals })
  const tickLabel = (v: number) => `${tickFmt.format(v)}${props.unit ? ` ${props.unit}` : ''}`
  return { w, h, ticks, y, pts, path, xLabels, slot, tickLabel }
})

const refY = computed(() => (props.refValue !== null && props.refValue !== undefined ? geo.value.y(props.refValue) : null))

const tip = computed(() => {
  if (active.value === null) return null
  const p = geo.value.pts[active.value]
  if (!p) return null
  const lines = [p.label, `${props.seriesLabel}: ${props.format(p.value)}`]
  if (p.detail) lines.push(p.detail)
  const tw = Math.max(...lines.map((l) => l.length)) * 6.6 + 20
  const th = lines.length * 16 + 10
  let tx = p.cx - tw / 2
  tx = Math.max(4, Math.min(geo.value.w - tw - 4, tx))
  const ty = p.cy - th - 12 < 2 ? p.cy + 14 : p.cy - th - 12
  return { p, lines, tw, th, tx, ty }
})

const liveText = computed(() => (tip.value ? tip.value.lines.join(', ') : ''))

function onKey(e: KeyboardEvent) {
  const n = props.points.length
  if (!n) return
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
    e.preventDefault()
    const cur = active.value ?? (e.key === 'ArrowRight' ? -1 : n)
    active.value = Math.max(0, Math.min(n - 1, cur + (e.key === 'ArrowRight' ? 1 : -1)))
  } else if (e.key === 'Home') active.value = 0
  else if (e.key === 'End') active.value = n - 1
  else if (e.key === 'Escape') active.value = null
}
</script>

<template>
  <div ref="wrap" class="chart-wrap">
    <svg
      v-if="points.length"
      class="chart"
      :viewBox="`0 0 ${geo.w} ${geo.h}`"
      :width="geo.w"
      :height="geo.h"
      role="img"
      :aria-label="`${title}. Pfeiltasten zeigen die einzelnen Werte.`"
      tabindex="0"
      @keydown="onKey"
      @blur="active = null"
      @mouseleave="active = null"
    >
      <g>
        <template v-for="t in geo.ticks" :key="t">
          <line class="grid-line" :x1="M.left" :x2="geo.w - M.right" :y1="geo.y(t)" :y2="geo.y(t)" />
          <text :x="M.left - 8" :y="geo.y(t) + 4" text-anchor="end">{{ geo.tickLabel(t) }}</text>
        </template>
        <text v-for="p in geo.xLabels" :key="`x${p.cx}`" :x="p.cx" :y="geo.h - 8" text-anchor="middle">{{ p.label }}</text>
      </g>
      <g v-if="refY !== null">
        <line class="ref-line" :x1="M.left" :x2="geo.w - M.right" :y1="refY" :y2="refY" />
        <text class="ref-label" :x="geo.w - M.right + 6" :y="refY + 4">{{ refLabel }}</text>
      </g>
      <line v-if="tip" class="crosshair" :x1="tip.p.cx" :x2="tip.p.cx" :y1="M.top" :y2="geo.h - M.bottom" />
      <path class="series-line" :d="geo.path" />
      <circle v-for="(p, i) in geo.pts" :key="i" class="series-dot" :cx="p.cx" :cy="p.cy" :r="active === i ? 6 : 4" />
      <rect
        v-for="(p, i) in geo.pts"
        :key="`h${i}`"
        class="hit"
        :x="p.cx - geo.slot / 2"
        :y="M.top"
        :width="Math.max(8, geo.slot)"
        :height="geo.h - M.top - M.bottom"
        @mouseenter="active = i"
      />
      <g v-if="tip" pointer-events="none">
        <rect :x="tip.tx" :y="tip.ty" :width="tip.tw" :height="tip.th" rx="6" class="tip-box" />
        <text v-for="(l, i) in tip.lines" :key="i" :x="tip.tx + 10" :y="tip.ty + 19 + i * 16" :class="i === 0 ? 'tip-title' : 'tip-text'">{{ l }}</text>
      </g>
    </svg>
    <p class="sr-only" aria-live="polite">{{ liveText }}</p>
    <div class="chart-legend">
      <span><span class="legend-swatch s1"></span>{{ seriesLabel }}</span>
      <span v-if="refValue !== null && refValue !== undefined"><span class="legend-swatch ref"></span>{{ refLabel }} {{ format(refValue) }}</span>
    </div>
    <details class="data-table">
      <summary>Daten als Tabelle</summary>
      <table class="table mt-1">
        <thead><tr><th scope="col">Datum</th><th scope="col" class="num">{{ seriesLabel }}</th><th v-if="points.some((p) => p.detail)" scope="col">Details</th></tr></thead>
        <tbody>
          <tr v-for="(p, i) in points" :key="i"><td>{{ p.label }}</td><td class="num">{{ format(p.value) }}</td><td v-if="points.some((q) => q.detail)">{{ p.detail }}</td></tr>
        </tbody>
      </table>
    </details>
  </div>
</template>
