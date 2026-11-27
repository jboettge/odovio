// Typisierte Endpunkte der Server-API.
import { ApiClient, type BlobResult } from './client'
import { navigationSignal } from './navigation'
import { tokenProvider } from '../auth/oidc'
import type {
  ActivityPage,
  AnchorList,
  AuditResult,
  Changes,
  CloseResult,
  Me,
  MemberList,
  Revision,
  Role,
  Stats,
  SyncOp,
  SyncResponse,
  TripCheck,
  YearReport,
} from './types'

// GETs ohne eigenes Signal werden beim Routenwechsel abgebrochen (siehe router.ts)
export const api = new ApiClient(tokenProvider, '', undefined, { maxConcurrent: 4, retries: 2, defaultSignal: navigationSignal })

const t = (tenant: string) => `/api/t/${encodeURIComponent(tenant)}`
const v = (tenant: string, vid: string) => `${t(tenant)}/vehicles/${encodeURIComponent(vid)}`

export const CHANGES_PAGE = 5000

export const endpoints = {
  me: (signal?: AbortSignal) => api.get<Me>('/api/me', undefined, signal),
  changes: (tenant: string, since: number, limit = CHANGES_PAGE, signal?: AbortSignal) =>
    api.get<Changes>(`${t(tenant)}/changes`, { since, limit }, signal),
  sync: (tenant: string, ops: SyncOp[]) => api.post<SyncResponse>(`${t(tenant)}/sync`, { ops }),
  stats: (tenant: string, vid: string, signal?: AbortSignal) => api.get<Stats>(`${v(tenant, vid)}/stats`, undefined, signal),
  tripCheck: (tenant: string, vid: string, month: string, signal?: AbortSignal) => api.get<TripCheck>(`${v(tenant, vid)}/trips/check`, { month }, signal),
  closeMonth: (tenant: string, vid: string, month: string, force: boolean, reason: string | null) =>
    api.post<CloseResult>(`${v(tenant, vid)}/periods/${encodeURIComponent(month)}/close`, { force, reason }),
  yearReport: (tenant: string, vid: string, year: number, signal?: AbortSignal) => api.get<YearReport>(`${v(tenant, vid)}/year-report`, { year }, signal),
  yearReportPdf: (tenant: string, vid: string, year: number) => api.blob(`${v(tenant, vid)}/year-report.pdf`, { year }),
  reportPdf: (tenant: string, vid: string, from: string, to: string) => api.blob(`${v(tenant, vid)}/report.pdf`, { from, to }),
  logbookPdf: (tenant: string, vid: string, q: { month?: string; from?: string; to?: string }) =>
    api.blob(`${v(tenant, vid)}/logbook.pdf`, q),
  tripsCsv: (tenant: string, vid: string, from: string, to: string) => api.blob(`${v(tenant, vid)}/trips.csv`, { from, to }),
  history: (tenant: string, entity: string, id: string, signal?: AbortSignal) =>
    api.get<Revision[]>(`${t(tenant)}/history/${encodeURIComponent(entity)}/${encodeURIComponent(id)}`, undefined, signal),
  verify: (tenant: string, full: boolean) => api.get<AuditResult>(`${t(tenant)}/audit/verify`, full ? { full: 1 } : {}),
  anchors: (tenant: string) => api.get<AnchorList>(`${t(tenant)}/audit/anchors`),
  attachmentBlob: (tenant: string, id: string, signal?: AbortSignal): Promise<BlobResult> =>
    api.blob(`${t(tenant)}/attachments/${encodeURIComponent(id)}/blob`, undefined, signal),
  uploadAttachment: (tenant: string, id: string, data: Blob, mime: string) =>
    api.putFile<{ stored: boolean; existing: boolean }>(`${t(tenant)}/attachments/${encodeURIComponent(id)}/blob`, data, mime),
  activity: (tenant: string, limit: number, beforeSeq?: number | null, signal?: AbortSignal) =>
    api.get<ActivityPage>(`${t(tenant)}/activity`, { limit, before_seq: beforeSeq ?? undefined }, signal),
  members: (tenant: string) => api.get<MemberList>(`${t(tenant)}/members`),
  addMember: (tenant: string, user: string, role: Role) => api.post<unknown>(`${t(tenant)}/members`, { user, role }),
  setMemberRole: (tenant: string, id: string, role: Role) => api.patch<unknown>(`${t(tenant)}/members/${encodeURIComponent(id)}`, { role }),
  removeMember: (tenant: string, id: string) => api.delete<unknown>(`${t(tenant)}/members/${encodeURIComponent(id)}`),
}
