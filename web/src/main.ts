import { createApp } from 'vue'
import App from './App.vue'
import { router } from './router'
import { authState, fetchAuthConfig, initAuth } from './auth/oidc'
import './styles/main.css'

async function boot(): Promise<void> {
  try {
    await initAuth(await fetchAuthConfig())
  } catch (e) {
    authState.error =
      e instanceof Error && e.message.startsWith('Anmeldekonfiguration')
        ? e.message
        : 'Server nicht erreichbar – Anmeldekonfiguration konnte nicht geladen werden.'
    authState.ready = true
  }
  createApp(App).use(router).mount('#app')
}

void boot()
