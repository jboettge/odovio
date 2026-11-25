/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Mock-API für die Entwicklung: `npm run mock` (Port 8787), dann `npm run dev`.
const API_TARGET = process.env.FZB_API ?? 'http://127.0.0.1:8787'

type ModuleInfo = { isEntry: boolean; importers: readonly string[] } | null
type ChunkMeta = { getModuleInfo: (id: string) => ModuleInfo }

/** Gruppen von App-Modulen mit eigenem Chunk (nur von den Seiten geladen, die sie brauchen). */
const GROUPS: [RegExp, string][] = [
  [/\/src\/(components\/(LineChart|BarChart)\.vue|components\/useWidth\.ts|lib\/(chart|downsample)\.ts)/, 'charts'],
  [/\/src\/lib\/(download|blobCache)\.ts$/, 'export'],
  [/\/src\/(components\/(Pager|VPad)\.vue|use\/(pager|virtualRows|debounced|async)\.ts)/, 'lists'],
]

/**
 * Eigene, stabile Chunks: Vendor-Code ändert seinen Hash nur bei einem Update der Abhängigkeit (Browser-Cache
 * bleibt bei App-Releases gültig); Diagramme, Export/Download und Listen-Hilfen liegen getrennt. Module, die
 * statisch vom Entry erreichbar sind, kommen in `core` – sonst würde Rollup gemeinsame Abhängigkeiten in einen
 * Gruppen-Chunk ziehen und diesen in den Startpfad holen.
 */
export function chunkFor(id: string, meta?: ChunkMeta, cache = new Map<string, boolean>()): string | undefined {
  const p = id.split('\\').join('/')
  if (p.includes('/node_modules/')) {
    if (/\/node_modules\/(@vue|vue)\//.test(p)) return 'vendor-vue'
    if (p.includes('/node_modules/vue-router/')) return 'vendor-router'
    if (/\/node_modules\/(oidc-client-ts|jwt-decode)\//.test(p)) return 'vendor-oidc'
    return 'vendor'
  }
  for (const [re, name] of GROUPS) if (re.test(p)) return name
  if (meta && !meta.getModuleInfo(id)?.isEntry && staticFromEntry(id, meta, cache)) return 'core'
  return undefined
}

/** Ist das Modul über statische Importe vom Entry erreichbar (= gehört zum Startpfad)? */
function staticFromEntry(id: string, meta: ChunkMeta, cache: Map<string, boolean>, seen = new Set<string>()): boolean {
  const hit = cache.get(id)
  if (hit !== undefined) return hit
  if (seen.has(id)) return false
  seen.add(id)
  const info = meta.getModuleInfo(id)
  const res = Boolean(info && (info.isEntry || info.importers.some((imp) => staticFromEntry(imp, meta, cache, seen))))
  cache.set(id, res)
  return res
}

const reachCache = new Map<string, boolean>()

/** Lesbare Chunk-Namen (ohne `.vue_vue_type_script_setup_true_lang`). */
function cleanName(name: string): string {
  return name.replace(/\.vue_vue_type.*$/, '').replace(/[^A-Za-z0-9_-]/g, '_') || 'chunk'
}

export default defineConfig({
  base: '/',
  plugins: [vue()],
  define: {
    // nur Composition API (<script setup>): Options-API-Code aus dem Vue-Bundle entfernen (kleinerer Startpfad)
    __VUE_OPTIONS_API__: 'false',
    __VUE_PROD_DEVTOOLS__: 'false',
    __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: 'false',
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // keine Source-Maps in Produktion (scripts/size.mjs prüft das)
    sourcemap: false,
    // CSP: keine Inline-Skripte – Preload-Polyfill nicht inline einfügen. modulepreload in index.html nur für
    // den Startpfad (statische Importe des Entry); Routen-Chunks werden erst bei Bedarf samt Abhängigkeiten geladen.
    modulePreload: { polyfill: false },
    // keine data:-URIs für Assets im JS/CSS (img-src erlaubt data:, aber Fonts/Skripte nicht)
    assetsInlineLimit: 0,
    cssCodeSplit: true,
    target: 'es2022',
    reportCompressedSize: true,
    rollupOptions: {
      output: {
        manualChunks: (id, meta) => chunkFor(id, meta, reachCache),
        entryFileNames: 'assets/app-[hash].js',
        chunkFileNames: (info) => `assets/${cleanName(info.name)}-[hash].js`,
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
  worker: {
    // Web Worker als eigene Datei (CSP: worker-src → script-src 'self'), nie als blob:/data:-URL
    format: 'es',
    rollupOptions: { output: { entryFileNames: 'assets/[name]-[hash].js', chunkFileNames: 'assets/w-[name]-[hash].js' } },
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': API_TARGET,
      '/auth/config': API_TARGET,
      '/oidc': API_TARGET,
    },
  },
  test: {
    environment: 'jsdom',
    include: ['tests/unit/**/*.spec.ts'],
    restoreMocks: true,
  },
})
