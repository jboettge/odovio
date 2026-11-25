#!/usr/bin/env node
// Bundle-Budget (ohne Abhängigkeiten): gzip-Grösse des Startpfads (Entry + statische Importe + modulepreload),
// des Pfads bis zur Übersicht (Startpfad + DashboardView-Chunk), jedes einzelnen JS-Chunks und des CSS.
// Prüft zusätzlich: keine Source-Maps, vorkomprimierte .br/.gz vorhanden und verlustfrei.
// Budgets in package.json → "budgets" (KiB, gzip). Exit-Code 1 bei Verletzung.
//   node scripts/size.mjs [dist]
import { gunzipSync, brotliDecompressSync, gzipSync } from 'node:zlib'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { basename, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { COMPRESSIBLE, MIN_SIZE } from './compress.mjs'

const here = fileURLToPath(new URL('.', import.meta.url))

export const gz = (buf) => gzipSync(buf, { level: 9 }).length

/** Statische Importe eines (minifizierten) ES-Moduls: `from"./x.js"` und `import"./x.js"` – keine dynamischen. */
export function staticImports(code) {
  const out = new Set()
  const re = /\bfrom\s*["']\.\/([^"']+\.js)["']|\bimport\s*["']\.\/([^"']+\.js)["']/g
  for (const m of code.matchAll(re)) out.add(m[1] ?? m[2])
  return [...out]
}

/** Einträge aus index.html: Entry-Skripte, modulepreload und Stylesheets (Pfade relativ zu dist). */
export function htmlAssets(html) {
  const attr = (tag, name) => new RegExp(`${name}\\s*=\\s*["']([^"']+)["']`, 'i').exec(tag)?.[1] ?? null
  const scripts = []
  const preloads = []
  const styles = []
  for (const tag of html.match(/<(script|link)\b[^>]*>/gi) ?? []) {
    if (/^<script/i.test(tag) && /type\s*=\s*["']module["']/i.test(tag)) {
      const src = attr(tag, 'src')
      if (src) scripts.push(src.replace(/^\//, ''))
    } else if (/^<link/i.test(tag)) {
      const rel = attr(tag, 'rel')
      const href = attr(tag, 'href')
      if (!href) continue
      if (rel === 'modulepreload') preloads.push(href.replace(/^\//, ''))
      if (rel === 'stylesheet') styles.push(href.replace(/^\//, ''))
    }
  }
  return { scripts, preloads, styles }
}

function walk(dir) {
  const out = []
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) out.push(...walk(p))
    else out.push(p)
  }
  return out
}

export function analyze(dist, budgets) {
  const root = resolve(dist)
  const read = (rel) => readFileSync(join(root, rel))
  const html = read('index.html').toString('utf8')
  const { scripts, preloads, styles } = htmlAssets(html)
  const closure = (starts) => {
    const seen = new Set()
    const stack = [...starts]
    while (stack.length) {
      const f = stack.pop()
      if (seen.has(f)) continue
      seen.add(f)
      const dir = f.includes('/') ? f.slice(0, f.lastIndexOf('/') + 1) : ''
      for (const imp of staticImports(read(f).toString('utf8'))) stack.push(`${dir}${imp}`)
    }
    return seen
  }
  const start = closure([...scripts, ...preloads])
  const files = walk(root).map((f) => relative(root, f).split('\\').join('/'))
  const js = files.filter((f) => f.endsWith('.js'))
  const dashboardChunk = js.find((f) => basename(f).startsWith('DashboardView-'))
  const dashboard = closure([...start, ...(dashboardChunk ? [dashboardChunk] : [])])
  const workers = js.filter((f) => /worker/i.test(basename(f)))
  const size = new Map(js.map((f) => [f, gz(read(f))]))
  const sum = (set) => [...set].reduce((a, f) => a + (size.get(f) ?? 0), 0)
  const css = styles.reduce((a, f) => a + gz(read(f)), 0)
  const kib = (b) => b / 1024
  const problems = []
  const check = (label, bytes, budget) => {
    if (budget !== undefined && kib(bytes) > budget) problems.push(`${label}: ${kib(bytes).toFixed(1)} KiB > Budget ${budget} KiB`)
  }
  check('Startpfad JS (gzip)', sum(start), budgets.startJsGzipKiB)
  check('Pfad bis Übersicht JS (gzip)', sum(dashboard), budgets.dashboardJsGzipKiB)
  check('CSS Startpfad (gzip)', css, budgets.cssGzipKiB)
  for (const [f, b] of size) check(`Chunk ${f}`, b, workers.includes(f) ? budgets.workerJsGzipKiB : budgets.chunkJsGzipKiB)
  if (!dashboardChunk) problems.push('DashboardView-Chunk nicht gefunden (Route nicht lazy?)')
  // keine Source-Maps
  for (const f of files) if (f.endsWith('.map')) problems.push(`Source-Map im Build: ${f}`)
  // Vorkomprimierung vollständig und verlustfrei
  let precompressed = 0
  for (const f of files) {
    const ext = f.slice(f.lastIndexOf('.')).toLowerCase()
    if (!COMPRESSIBLE.has(ext) || statSync(join(root, f)).size < MIN_SIZE) continue
    for (const [suffix, dec] of [['.br', brotliDecompressSync], ['.gz', gunzipSync]]) {
      const p = join(root, `${f}${suffix}`)
      if (!existsSync(p)) problems.push(`fehlt: ${f}${suffix}`)
      else if (!dec(readFileSync(p)).equals(read(f))) problems.push(`verfälscht: ${f}${suffix}`)
      else precompressed++
    }
  }
  return {
    start: { files: [...start].sort(), gzip: sum(start) },
    dashboard: { chunk: dashboardChunk ?? null, gzip: sum(dashboard) },
    css,
    chunks: [...size].sort((a, b) => b[1] - a[1]).map(([file, gzip]) => ({ file, gzip })),
    workers,
    precompressed,
    problems,
  }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'))
  const budgets = pkg.budgets ?? {}
  const r = analyze(process.argv[2] ?? 'dist', budgets)
  const k = (b) => `${(b / 1024).toFixed(1)} KiB`
  console.log(`Startpfad JS (gzip):        ${k(r.start.gzip).padStart(10)}  Budget ${budgets.startJsGzipKiB} KiB  (${r.start.files.join(', ')})`)
  console.log(`Pfad bis Übersicht (gzip):  ${k(r.dashboard.gzip).padStart(10)}  Budget ${budgets.dashboardJsGzipKiB} KiB`)
  console.log(`CSS (gzip):                 ${k(r.css).padStart(10)}  Budget ${budgets.cssGzipKiB} KiB`)
  console.log(`Grösste Chunks (gzip, Budget je Chunk ${budgets.chunkJsGzipKiB} KiB, Worker ${budgets.workerJsGzipKiB} KiB):`)
  for (const c of r.chunks.slice(0, 8)) console.log(`  ${k(c.gzip).padStart(10)}  ${c.file}`)
  console.log(`Vorkomprimierte Varianten geprüft: ${r.precompressed}`)
  if (r.problems.length) {
    console.error(`\nBudget/Build-Prüfung fehlgeschlagen:\n  - ${r.problems.join('\n  - ')}`)
    process.exit(1)
  }
  console.log('Budgets eingehalten.')
}
