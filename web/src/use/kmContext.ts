// Kilometerstände des aktuellen Fahrzeugs für Vorschlag (aktueller Stand) und Plausibilitätshinweise.
import { computed } from 'vue'
import { useVehicle } from '../composables'
import { currentKm, kmPoints, kmWarning } from '../lib/readings'

export function useKmContext() {
  const v = useVehicle()
  const points = computed(() => kmPoints({ odometer: v.odometer.value, fuel: v.fuel.value, maintenance: v.maintenance.value, trips: v.trips.value }))
  const initial = computed(() => v.vehicle.value?.initial_km ?? 0)
  return {
    ...v,
    current: computed(() => currentKm(points.value, initial.value)),
    warn: (day: unknown, km: number | null, excludeId?: string | null) =>
      typeof day === 'string' ? kmWarning(points.value, day, km, initial.value, excludeId) : null,
  }
}
