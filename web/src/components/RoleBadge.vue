<script setup lang="ts">
import type { Role } from '../api/types'
import { ROLE_LABELS } from '../lib/roles'
defineProps<{ role: Role }>()
</script>

<template>
  <span :class="['badge', `role-${role}`]" :title="`Rolle: ${ROLE_LABELS[role]}`">{{ ROLE_LABELS[role] }}</span>
</template>
