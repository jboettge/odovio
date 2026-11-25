export const COMPRESSIBLE: Set<string>
export const MIN_SIZE: number
export function brotli(buf: Uint8Array): Buffer
export function gzip(buf: Uint8Array): Buffer
export function eligibleFiles(dir: string, minSize?: number): Promise<string[]>
export function compressDir(dir: string, opts?: { minSize?: number }): Promise<{ file: string; raw: number; br: number; gz: number }[]>
