/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Mock-API für die Entwicklung: `npm run mock` (Port 8787), dann `npm run dev`.
const API_TARGET = process.env.FZB_API ?? 'http://127.0.0.1:8787'

export default defineConfig({
  base: '/',
  plugins: [vue()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
    // CSP: keine Inline-Skripte – Preload-Polyfill nicht inline einfügen
    modulePreload: { polyfill: false },
    // keine data:-URIs für Assets im JS/CSS (img-src erlaubt data:, aber Fonts/Skripte nicht)
    assetsInlineLimit: 0,
    cssCodeSplit: true,
    target: 'es2022',
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
