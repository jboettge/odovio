<script setup lang="ts">
import { errorText } from '../store/toasts'
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import AlertBox from '../components/AlertBox.vue'
import Loading from '../components/Loading.vue'
import { completeLogin } from '../auth/oidc'

const router = useRouter()
const error = ref<string | null>(null)

onMounted(async () => {
  try {
    const to = await completeLogin()
    await router.replace(to)
  } catch (e) {
    error.value = errorText(e)
  }
})
</script>

<template>
  <main id="main" class="start" tabindex="-1">
    <div class="card start-card">
      <h1>Anmeldung</h1>
      <AlertBox v-if="error" kind="danger" title="Anmeldung fehlgeschlagen" live>
        <p>{{ error }}</p>
        <RouterLink to="/" class="btn btn-sm">Zur Startseite</RouterLink>
      </AlertBox>
      <Loading v-else text="Anmeldung wird abgeschlossen …" />
    </div>
  </main>
</template>
