export function gz(buf: Uint8Array): number
export function staticImports(code: string): string[]
export function htmlAssets(html: string): { scripts: string[]; preloads: string[]; styles: string[] }
export interface SizeReport {
  start: { files: string[]; gzip: number }
  dashboard: { chunk: string | null; gzip: number }
  css: number
  chunks: { file: string; gzip: number }[]
  workers: string[]
  precompressed: number
  problems: string[]
}
export function analyze(dist: string, budgets: Record<string, number | undefined>): SizeReport
