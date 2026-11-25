<script setup lang="ts">
import { onMounted, ref } from 'vue'
import PageHeader from '../components/PageHeader.vue'
import AlertBox from '../components/AlertBox.vue'
import Icon from '../components/Icon.vue'
import Loading from '../components/Loading.vue'
import { endpoints } from '../api/endpoints'
import type { AnchorList, AuditResult } from '../api/types'
import { session } from '../store/session'
import { errorText } from '../store/toasts'
import { dateTime, num, shortHash } from '../lib/format'

const full = ref(false)
const running = ref(false)
const result = ref<AuditResult | null>(null)
const checkedAt = ref<Date | null>(null)
const error = ref<string | null>(null)
const anchors = ref<AnchorList | null>(null)
const anchorsError = ref<string | null>(null)

async function verify() {
  if (!session.tenant) return
  running.value = true
  error.value = null
  try {
    result.value = await endpoints.verify(session.tenant, full.value)
    checkedAt.value = new Date()
  } catch (e) {
    error.value = errorText(e)
  } finally {
    running.value = false
  }
}

onMounted(async () => {
  if (!session.tenant) return
  try {
    anchors.value = await endpoints.anchors(session.tenant)
  } catch (e) {
    anchorsError.value = errorText(e)
  }
})
</script>

<template>
  <PageHeader title="Integrität" subtitle="Prüft, ob das Änderungsprotokoll (Hash-Kette), der aktuelle Datenstand und die Belegdateien unverändert sind." />

  <section class="card" aria-labelledby="int-run">
    <h2 id="int-run" class="section-title">Prüfung</h2>
    <div class="row">
      <button type="button" class="btn btn-primary" :disabled="running" @click="verify"><Icon name="shield" size="sm" />{{ running ? 'Prüfung läuft …' : 'Prüfung starten' }}</button>
      <label class="check"><input v-model="full" type="checkbox" />Vollprüfung (ganze Kette und alle Belegdateien)</label>
    </div>
    <p class="muted small mt-1">Ohne Vollprüfung wird die Kette ab dem zuletzt bestätigten Stand geprüft (schneller). Anker werden immer vollständig geprüft.</p>
    <Loading v-if="running" text="Kette und Datenstand werden geprüft …" />
    <AlertBox v-else-if="error" kind="danger" live class="mt-2">{{ error }}</AlertBox>
    <template v-else-if="result">
      <AlertBox :kind="result.ok ? 'ok' : 'danger'" live class="mt-2" :title="result.ok ? 'Keine Unstimmigkeiten gefunden' : 'Unstimmigkeiten gefunden'">
        <p v-if="result.ok">Alle {{ num(result.count) }} Revisionen sind lückenlos verkettet, der Datenstand stimmt mit dem Protokoll überein<span v-if="result.signed"> und die Anker-Signaturen sind gültig</span>.</p>
        <p v-else>Das Protokoll oder der Datenstand weicht ab. Details unten – bitte die Verwaltung informieren und ein Backup sichern.</p>
        <p class="small muted">Geprüft {{ checkedAt ? dateTime(checkedAt.toISOString()) : '' }}<template v-if="result.incremental_from"> · inkrementell ab Revision {{ num(result.incremental_from) }}</template><template v-else> · vollständig</template></p>
      </AlertBox>
      <ul class="checklist mt-2">
        <li>
          <Icon :name="result.chain_ok ? 'checkCircle' : 'xCircle'" :class="result.chain_ok ? 'check-ok' : 'check-fail'" :label="result.chain_ok ? 'in Ordnung' : 'Fehler'" />
          <div><strong>Hash-Kette</strong><div class="muted small">Jede Revision enthält den Hash der vorherigen – nachträgliche Änderungen brechen die Kette.<template v-if="result.broken_at"> Bruch bei Revision {{ result.broken_at }}<template v-if="result.reason">: {{ result.reason }}</template>.</template></div></div>
        </li>
        <li>
          <Icon :name="result.state_ok ? 'checkCircle' : 'xCircle'" :class="result.state_ok ? 'check-ok' : 'check-fail'" :label="result.state_ok ? 'in Ordnung' : 'Fehler'" />
          <div><strong>Datenstand</strong><div class="muted small">Aktuelle Einträge entsprechen der jeweils letzten Revision im Protokoll.</div></div>
        </li>
        <li>
          <Icon :name="result.signed ? 'checkCircle' : 'alert'" :class="result.signed ? 'check-ok' : 'check-warn'" :label="result.signed ? 'signiert' : 'nicht signiert'" />
          <div><strong>Signierte Anker</strong><div class="muted small">{{ result.signed ? `${num(result.anchors)} Anker mit Ed25519-Signatur geprüft.` : 'Kein Signaturschlüssel konfiguriert – Anker werden nicht signiert.' }}</div></div>
        </li>
        <li>
          <Icon :name="result.blobs_checked || !result.blobs_missing ? 'checkCircle' : 'help'" :class="result.blobs_checked || !result.blobs_missing ? 'check-ok' : 'check-na'" label="Belege" />
          <div><strong>Belegdateien</strong><div class="muted small">{{ num(result.blobs_checked) }} {{ result.blobs_checked === 1 ? 'Datei' : 'Dateien' }} mit Prüfsumme geprüft<template v-if="!result.blobs_checked && result.incremental_from"> (Dateien nur bei Vollprüfung)</template><template v-if="result.blobs_missing">, {{ num(result.blobs_missing) }} {{ result.blobs_missing === 1 ? 'Beleg' : 'Belege' }} ohne hochgeladene Datei (kein Fehler)</template>.</div></div>
        </li>
      </ul>
      <dl class="dl mt-2 small">
        <dt>Revisionen</dt><dd>{{ num(result.count) }}</dd>
        <dt>Aktueller Hash</dt><dd class="mono" :title="result.head_hash">{{ shortHash(result.head_hash, 24) }}</dd>
      </dl>
      <AlertBox v-if="result.problems.length" kind="danger" title="Gefundene Probleme" class="mt-2">
        <ul><li v-for="p in result.problems" :key="p">{{ p }}</li></ul>
      </AlertBox>
    </template>
  </section>

  <section class="card" aria-labelledby="int-anchors">
    <h2 id="int-anchors" class="section-title">Anker</h2>
    <p class="small muted">Anker halten den Stand der Kette (Revision + Hash) signiert fest. Externe Archivierung (z. B. täglich nach Paperless) macht spätere Manipulationen auch für den Server-Betreiber nachweisbar.</p>
    <AlertBox v-if="anchorsError" kind="danger">{{ anchorsError }}</AlertBox>
    <template v-else-if="anchors">
      <dl class="dl small mt-1">
        <dt>Öffentlicher Schlüssel</dt><dd class="mono">{{ anchors.public_key ?? 'nicht konfiguriert' }}</dd>
        <dt>Schlüssel-ID</dt><dd class="mono">{{ anchors.key_id ?? '–' }}</dd>
        <dt>Nachrichtenformat</dt><dd class="mono">{{ anchors.message_format }}</dd>
      </dl>
      <p v-if="!anchors.anchors.length" class="muted mt-2">Noch keine Anker gesetzt.</p>
      <div v-else class="table-wrap mt-2">
        <table class="table">
          <thead><tr><th scope="col" class="num">Revision</th><th scope="col">Zeitpunkt</th><th scope="col">Hash</th><th scope="col">Schlüssel</th><th scope="col">Signatur</th></tr></thead>
          <tbody>
            <tr v-for="a in [...anchors.anchors].reverse().slice(0, 50)" :key="a.seq">
              <td class="num">{{ num(a.seq) }}</td>
              <td>{{ dateTime(a.created_at) }}</td>
              <td class="mono" :title="a.head_hash">{{ shortHash(a.head_hash, 16) }}</td>
              <td class="mono">{{ a.key_id }}</td>
              <td class="mono" :title="a.signature">{{ shortHash(a.signature, 16) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-if="anchors.anchors.length > 50" class="muted small mt-1">Die neuesten 50 von {{ anchors.anchors.length }} Ankern.</p>
    </template>
    <Loading v-else />
  </section>

  <AlertBox kind="info" title="Grenzen der Prüfung" class="mt-3">
    <ul>
      <li>Die Prüfung erkennt nachträgliche Änderungen an Protokoll, Datenstand und Belegdateien – sie verhindert sie nicht.</li>
      <li>Wer Server <em>und</em> Signaturschlüssel kontrolliert, könnte die Kette neu aufbauen. Davor schützt nur ein extern archivierter Anker.</li>
      <li>Die Richtigkeit der Angaben selbst (z. B. Zweck einer Fahrt) kann keine technische Prüfung belegen.</li>
      <li>Belege ohne hochgeladene Datei gelten nicht als Fehler.</li>
    </ul>
  </AlertBox>
</template>
