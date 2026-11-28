<script setup lang="ts">
// Nicht hochgeladene Belege (Metadaten gespeichert, Datei fehlt noch) – erneut versuchen oder verwerfen.
import AlertBox from './AlertBox.vue'
import { discardUpload, pendingUploads, retryUpload } from '../store/uploads'
</script>

<template>
  <AlertBox v-if="pendingUploads.some((p) => p.error)" kind="warn" title="Belege nicht hochgeladen" class="mb-1">
    <ul class="receipt-list">
      <li v-for="p in pendingUploads.filter((x) => x.error)" :key="p.receipt.id">
        <span>{{ p.receipt.name }} <span class="muted small">– {{ p.error }}</span></span>
        <span class="row">
          <button type="button" class="btn btn-sm" :disabled="p.busy" @click="retryUpload(p.receipt.id)">{{ p.busy ? 'Wird hochgeladen …' : 'Erneut versuchen' }}</button>
          <button type="button" class="btn btn-ghost btn-sm" @click="discardUpload(p.receipt.id)">Verwerfen</button>
        </span>
      </li>
    </ul>
    <p class="small mt-1">Verworfene Belege erscheinen als «nicht hochgeladen» und können storniert werden.</p>
  </AlertBox>
</template>
