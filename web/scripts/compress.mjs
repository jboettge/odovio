#!/usr/bin/env node
// Vorkomprimierte Varianten für die Auslieferung (Vertrag mit dem Server): Für jede Textdatei in dist/ ab 1 KiB
// entstehen zusätzlich <datei>.br (Brotli, Qualität 11) und <datei>.gz (gzip, Level 9). Nur Node (zlib), keine
// Abhängigkeiten. Der Server liefert sie bei passendem Accept-Encoding mit Content-Encoding und Vary aus.
//   node scripts/compress.mjs [dist]
import { brotliCompressSync, constants, gzipSync } from 'node:zlib'
import { readdir, readFile, stat, writeFile } from 'node:fs/promises'
import { extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Dateitypen, die vorkomprimiert werden (Source-Maps gibt es im Produktions-Build nicht). */
export const COMPRESSIBLE = new Set(['.html', '.js', '.mjs', '.css', '.svg', '.json', '.txt', '.xml', '.webmanifest'])
export const MIN_SIZE = 1024

export function brotli(buf) {
  return brotliCompressSync(buf, {
    params: {
      [constants.BROTLI_PARAM_QUALITY]: 11,
      [constants.BROTLI_PARAM_MODE]: constants.BROTLI_MODE_TEXT,
      [constants.BROTLI_PARAM_SIZE_HINT]: buf.length,
    },
  })
}

export function gzip(buf) {
  return gzipSync(buf, { level: 9 })
}

async function* walk(dir) {
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) yield* walk(p)
    else if (e.isFile()) yield p
  }
}

/** Alle geeigneten Dateien unter `dir` (ohne bereits komprimierte Varianten). */
export async function eligibleFiles(dir, minSize = MIN_SIZE) {
  const out = []
  for await (const file of walk(dir)) {
    if (!COMPRESSIBLE.has(extname(file).toLowerCase())) continue
    if ((await stat(file)).size < minSize) continue
    out.push(file)
  }
  return out.sort()
}

/** Erzeugt .br und .gz für alle geeigneten Dateien; liefert Statistik je Datei. */
export async function compressDir(dir, { minSize = MIN_SIZE } = {}) {
  const root = resolve(dir)
  const result = []
  for (const file of await eligibleFiles(root, minSize)) {
    const raw = await readFile(file)
    const br = brotli(raw)
    const gz = gzip(raw)
    await writeFile(`${file}.br`, br)
    await writeFile(`${file}.gz`, gz)
    result.push({ file: relative(root, file), raw: raw.length, br: br.length, gz: gz.length })
  }
  return result
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const dir = process.argv[2] ?? 'dist'
  const res = await compressDir(dir)
  const sum = (k) => res.reduce((a, r) => a + r[k], 0)
  console.log(`Vorkomprimiert: ${res.length} Dateien in ${dir} – roh ${(sum('raw') / 1024).toFixed(1)} KiB, gzip ${(sum('gz') / 1024).toFixed(1)} KiB, brotli ${(sum('br') / 1024).toFixed(1)} KiB`)
}
