// @vitest-environment node
// Vorkomprimierung (scripts/compress.mjs) und Bundle-Budget (scripts/size.mjs) an einem kleinen Beispiel-dist.
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { brotliDecompressSync, gunzipSync } from 'node:zlib'
import { compressDir } from '../../scripts/compress.mjs'
import { analyze, htmlAssets, staticImports } from '../../scripts/size.mjs'

let dir = ''
const text = (n: number, seed = 'x') => Array.from({ length: n }, (_, i) => `${seed}${i % 97};`).join('')

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'fzb-dist-'))
  await mkdir(join(dir, 'assets'))
  await writeFile(
    join(dir, 'index.html'),
    `<!doctype html><html><head><script type="module" crossorigin src="/assets/app-1.js"></script><link rel="modulepreload" crossorigin href="/assets/vendor-2.js"><link rel="stylesheet" href="/assets/app-3.css"></head><body>${text(300, 'h')}</body></html>`,
  )
  await writeFile(join(dir, 'assets/app-1.js'), `import{a}from"./vendor-2.js";import"./core-4.js";const r=()=>import("./DashboardView-5.js");${text(800, 'a')}`)
  await writeFile(join(dir, 'assets/vendor-2.js'), `export const a=1;${text(2000, 'v')}`)
  await writeFile(join(dir, 'assets/core-4.js'), `export const c=1;${text(400, 'c')}`)
  await writeFile(join(dir, 'assets/DashboardView-5.js'), `import{c}from"./core-4.js";import{d}from"./charts-6.js";${text(300, 'd')}`)
  await writeFile(join(dir, 'assets/charts-6.js'), `export const d=1;${text(100, 'g')}`)
  await writeFile(join(dir, 'assets/app-3.css'), `body{color:red}${text(50, '.c')}`)
  await writeFile(join(dir, 'assets/small.js'), 'export const s=1')
  await writeFile(join(dir, 'assets/logo.png'), Buffer.alloc(4096, 7))
})
afterEach(async () => {
  await rm(dir, { recursive: true, force: true })
})

describe('scripts/compress.mjs', () => {
  it('erzeugt .br und .gz ab 1 KiB, verlustfrei; kleine und binäre Dateien bleiben ohne Varianten', async () => {
    const res = await compressDir(dir)
    const files = res.map((r) => r.file.split('\\').join('/')).sort()
    expect(files).toEqual(['assets/DashboardView-5.js', 'assets/app-1.js', 'assets/core-4.js', 'assets/vendor-2.js', 'index.html'].sort())
    for (const f of files) {
      const raw = await readFile(join(dir, f))
      expect(brotliDecompressSync(await readFile(join(dir, `${f}.br`))).equals(raw)).toBe(true)
      expect(gunzipSync(await readFile(join(dir, `${f}.gz`))).equals(raw)).toBe(true)
      const r = res.find((x) => x.file.split('\\').join('/') === f)!
      expect(r.br).toBeLessThan(r.raw)
      expect(r.gz).toBeLessThan(r.raw)
    }
    expect(existsSync(join(dir, 'assets/small.js.br'))).toBe(false)
    expect(existsSync(join(dir, 'assets/logo.png.gz'))).toBe(false)
    expect(existsSync(join(dir, 'assets/charts-6.js.gz'))).toBe(false) // < 1 KiB
  })
})

describe('scripts/size.mjs', () => {
  it('erkennt statische (nicht dynamische) Importe und Tags aus index.html', () => {
    expect(staticImports('import{a as b}from"./vendor-2.js";import"./core-4.js";const x=()=>import("./Lazy-9.js")')).toEqual(['vendor-2.js', 'core-4.js'])
    expect(htmlAssets('<script type="module" src="/assets/a.js"></script><link rel="modulepreload" href="/assets/b.js"><link rel="stylesheet" href="/assets/c.css">')).toEqual({
      scripts: ['assets/a.js'],
      preloads: ['assets/b.js'],
      styles: ['assets/c.css'],
    })
  })

  it('Startpfad = Entry + statische Importe; Pfad bis Übersicht inkl. DashboardView; Budgets und Vorkomprimierung geprüft', async () => {
    await compressDir(dir)
    const ok = analyze(dir, { startJsGzipKiB: 50, dashboardJsGzipKiB: 50, chunkJsGzipKiB: 50, cssGzipKiB: 5 })
    expect(ok.start.files).toEqual(['assets/app-1.js', 'assets/core-4.js', 'assets/vendor-2.js'])
    expect(ok.dashboard.chunk).toBe('assets/DashboardView-5.js')
    expect(ok.dashboard.gzip).toBeGreaterThan(ok.start.gzip)
    expect(ok.problems).toEqual([])

    const tight = analyze(dir, { startJsGzipKiB: 0.1, chunkJsGzipKiB: 0.1 })
    expect(tight.problems.some((p) => p.startsWith('Startpfad JS'))).toBe(true)
    expect(tight.problems.some((p) => p.startsWith('Chunk assets/vendor-2.js'))).toBe(true)
  })

  it('meldet fehlende Vorkomprimierung und Source-Maps', async () => {
    await writeFile(join(dir, 'assets/app-1.js.map'), '{}')
    const r = analyze(dir, {})
    expect(r.problems).toContain('fehlt: index.html.br')
    expect(r.problems).toContain('Source-Map im Build: assets/app-1.js.map')
  })
})
