<script setup lang="ts">
// Quellcode-Link (AGPL-3.0 § 13): Nutzer des Netzdienstes erhalten Zugang zum Quellcode der laufenden Fassung.
import { computed } from 'vue'
import { authState } from '../auth/oidc'
import { sourceHref } from '../lib/source'

const href = computed(() => sourceHref(authState.config?.source_url))
</script>

<template>
  <p class="source-link small">
    <a :href="href" target="_blank" rel="noopener noreferrer">Quellcode (AGPL-3.0)</a>
  </p>
</template>
