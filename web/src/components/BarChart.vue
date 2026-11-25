<script setup lang="ts">
// Gestapeltes Säulendiagramm (z. B. Kosten je Monat: Treibstoff + Wartung). SVG, Tooltip, Tabelle.
import { computed, ref } from 'vue'
import { niceTicks, scale } from '../lib/chart'
import { useWidth } from './useWidth'

export interface BarDatum {
  label: string
  values: number[]
}

const props = withDefaults(
  defineProps<{ title: string; series: string[]; data: BarDatum[]; format: (v: number) => string; height?: number }>(),
  { height: 240 },
)

const wrap = ref<HTMLElement | null>(null)
const width = useWidth(wrap)
const active = ref<number | null>(null)
const M = { top: 16, right: 16, bottom: 30, left: 70 }

const geo = computed(() => {
  const w = Math.max(280, width.value)
  const h = props.height
  const totals = props.data.map((d) => d.values.reduce((a, b) => a + b, 0))
  const ticks = niceTicks(0, Math.max(1, ...totals), 5)
  const y = scale(0, ticks[ticks.length - 1]!, h - M.bottom, M.top)
  const n = props.data.length
  const band = (w - M.left - M.right) / Math.max(1, n)
  const bw = Math.max(6, Math.min(44, band * 0.62))
  const bars = props.data.map((d, i) => {
    const cx = M.left + band * i + band / 2
    let acc = 0
    const segs = d.values.map((v, s) => {
      const y0 = y(acc)
      acc += v
      const y1 = y(acc)
      return { s, x: cx - bw / 2, y: y1, h: Math.max(0, y0 - y1), v }
    })
    return { d, i, cx, segs, total: totals[i] ?? 0 }
  })
  const step = Math.max(1, Math.ceil(n / Math.max(2, Math.floor((w - M.left - M.right) / 60))))
  return { w, h, ticks, y, bars, band, step }
})

const tip = computed(() => {
  if (active.value === null) return null
  const b = geo.value.bars[active.value]
  if (!b) return null
  const lines = [b.d.label, ...props.series.map((s, i) => `${s}: ${props.format(b.d.values[i] ?? 0)}`), `Total: ${props.format(b.total)}`]
  const tw = Math.max(...lines.map((l) => l.length)) * 6.6 + 20
  const th = lines.length * 16 + 10
  const top = geo.value.y(b.total)
  const tx = Math.max(4, Math.min(geo.value.w - tw - 4, b.cx - tw / 2))
  const ty = top - th - 10 < 2 ? top + 10 : top - th - 10
  return { lines, tw, th, tx, ty }
})
const liveText = computed(() => (tip.value ? tip.value.lines.join(', ') : ''))

function onKey(e: KeyboardEvent) {
  const n = props.data.length
  if (!n) return
  if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
    e.preventDefault()
    const cur = active.value ?? (e.key === 'ArrowRight' ? -1 : n)
    active.value = Math.max(0, Math.min(n - 1, cur + (e.key === 'ArrowRight' ? 1 : -1)))
  } else if (e.key === 'Escape') active.value = null
}
</script>

<template>
  <div ref="wrap" class="chart-wrap">
    <svg
      class="chart"
      :viewBox="`0 0 ${geo.w} ${geo.h}`"
      :width="geo.w"
      :height="geo.h"
      role="img"
      :aria-label="`${title}. Pfeiltasten zeigen die einzelnen Monate.`"
      tabindex="0"
      @keydown="onKey"
      @blur="active = null"
      @mouseleave="active = null"
    >
      <template v-for="t in geo.ticks" :key="t">
        <line class="grid-line" :x1="M.left" :x2="geo.w - M.right" :y1="geo.y(t)" :y2="geo.y(t)" />
        <text :x="M.left - 8" :y="geo.y(t) + 4" text-anchor="end">{{ format(t) }}</text>
      </template>
      <g v-for="b in geo.bars" :key="b.i">
        <rect v-for="s in b.segs.filter((x) => x.h > 0)" :key="s.s" :class="['bar-gap', `bar-${s.s + 1}`]" :x="s.x" :y="s.y" :width="Math.max(6, Math.min(44, geo.band * 0.62))" :height="s.h" rx="3" />
        <text v-if="b.i % geo.step === 0" :x="b.cx" :y="geo.h - 8" text-anchor="middle">{{ b.d.label }}</text>
        <rect class="hit" :x="b.cx - geo.band / 2" :y="M.top" :width="geo.band" :height="geo.h - M.top - M.bottom" @mouseenter="active = b.i" />
      </g>
      <line class="axis-line" :x1="M.left" :x2="geo.w - M.right" :y1="geo.y(0)" :y2="geo.y(0)" />
      <g v-if="tip" pointer-events="none">
        <rect :x="tip.tx" :y="tip.ty" :width="tip.tw" :height="tip.th" rx="6" class="tip-box" />
        <text v-for="(l, i) in tip.lines" :key="i" :x="tip.tx + 10" :y="tip.ty + 19 + i * 16" :class="i === 0 ? 'tip-title' : 'tip-text'">{{ l }}</text>
      </g>
    </svg>
    <p class="sr-only" aria-live="polite">{{ liveText }}</p>
    <div class="chart-legend">
      <span v-for="(s, i) in series" :key="s"><span :class="['legend-swatch', `s${i + 1}`]"></span>{{ s }}</span>
    </div>
    <details class="data-table">
      <summary>Daten als Tabelle</summary>
      <table class="table mt-1">
        <thead><tr><th scope="col">Monat</th><th v-for="s in series" :key="s" scope="col" class="num">{{ s }}</th><th scope="col" class="num">Total</th></tr></thead>
        <tbody>
          <tr v-for="d in data" :key="d.label">
            <td>{{ d.label }}</td>
            <td v-for="(v, i) in d.values" :key="i" class="num">{{ format(v) }}</td>
            <td class="num">{{ format(d.values.reduce((a, b) => a + b, 0)) }}</td>
          </tr>
        </tbody>
      </table>
    </details>
  </div>
</template>
