// Seitenaufteilung im Client (50/100/200) für Listen mit variabler Zeilenhöhe (Wartungskarten, Zeitachse,
// Aktivität, Stammdaten). Seite wird bei geänderter Länge eingegrenzt und bei neuem Filter auf 1 gesetzt.
import { computed, reactive, ref, toValue, watch, type MaybeRefOrGetter, type WatchSource } from 'vue'

export const PAGE_SIZES = [50, 100, 200] as const

export function usePager<T>(rows: MaybeRefOrGetter<readonly T[]>, opts: { size?: number; resetOn?: WatchSource[] } = {}) {
  const page = ref(1)
  const size = ref<number>(opts.size ?? PAGE_SIZES[0])
  const list = computed(() => toValue(rows))
  const total = computed(() => list.value.length)
  const pages = computed(() => Math.max(1, Math.ceil(total.value / size.value)))
  watch([total, size], () => {
    if (page.value > pages.value) page.value = pages.value
  })
  if (opts.resetOn?.length) watch(opts.resetOn, () => (page.value = 1))
  watch(size, () => (page.value = 1))
  const from = computed(() => (total.value ? (page.value - 1) * size.value + 1 : 0))
  const to = computed(() => Math.min(total.value, page.value * size.value))
  const items = computed(() => list.value.slice(from.value ? from.value - 1 : 0, to.value))
  return reactive({ page, size, total, pages, from, to, items })
}
