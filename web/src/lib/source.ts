// Quellcode-Link (AGPL-3.0 § 13): vom Server (/auth/config → source_url, nur https), sonst das öffentliche Repository.
import { safeHref } from './security'

export const DEFAULT_SOURCE_URL = 'https://github.com/jboettge/odovio'

export function sourceHref(v: unknown): string {
  const h = safeHref(v)
  return h && h.startsWith('https://') ? h : DEFAULT_SOURCE_URL
}
