// «…/tanken?neu=1» (Schnellaktion der Fahrzeugübersicht) öffnet direkt das Erfassen-Formular.
import { onMounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'

export function useOpenOnQuery(open: () => void, enabled: () => boolean) {
  const route = useRoute()
  const router = useRouter()
  onMounted(() => {
    if (route.query.neu === undefined) return
    const { neu: _n, ...query } = route.query
    void router.replace({ query })
    if (enabled()) open()
  })
}
