// Typisierte Endpunkte der Server-API.
import { ApiClient, type BlobResult } from './client'
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

export const api = new ApiClient(tokenProvider)

const t = (tenant: string) => `/api/t/${encodeURIComponent(tenant)}`
const v = (tenant: string, vid: string) => `${t(tenant)}/vehicles/${encodeURIComponent(vid)}`

export const CHANGES_PAGE = 5000

export const endpoints = {
  me: () => api.get<Me>('/api/me'),
  changes: (tenant: string, since: number, limit = CHANGES_PAGE) => api.get<Changes>(`${t(tenant)}/changes`, { since, limit }),
  sync: (tenant: string, ops: SyncOp[]) => api.post<SyncResponse>(`${t(tenant)}/sync`, { ops }),
  stats: (tenant: string, vid: string) => api.get<Stats>(`${v(tenant, vid)}/stats`),
  tripCheck: (tenant: string, vid: string, month: string) => api.get<TripCheck>(`${v(tenant, vid)}/trips/check`, { month }),
  closeMonth: (tenant: string, vid: string, month: string, force: boolean, reason: string | null) =>
    api.post<CloseResult>(`${v(tenant, vid)}/periods/${encodeURIComponent(month)}/close`, { force, reason }),
  yearReport: (tenant: string, vid: string, year: number) => api.get<YearReport>(`${v(tenant, vid)}/year-report`, { year }),
  yearReportPdf: (tenant: string, vid: string, year: number) => api.blob(`${v(tenant, vid)}/year-report.pdf`, { year }),
  reportPdf: (tenant: string, vid: string, from: string, to: string) => api.blob(`${v(tenant, vid)}/report.pdf`, { from, to }),
  logbookPdf: (tenant: string, vid: string, q: { month?: string; from?: string; to?: string }) =>
    api.blob(`${v(tenant, vid)}/logbook.pdf`, q),
  tripsCsv: (tenant: string, vid: string, from: string, to: string) => api.blob(`${v(tenant, vid)}/trips.csv`, { from, to }),
  history: (tenant: string, entity: string, id: string) =>
    api.get<Revision[]>(`${t(tenant)}/history/${encodeURIComponent(entity)}/${encodeURIComponent(id)}`),
  verify: (tenant: string, full: boolean) => api.get<AuditResult>(`${t(tenant)}/audit/verify`, full ? { full: 1 } : {}),
  anchors: (tenant: string) => api.get<AnchorList>(`${t(tenant)}/audit/anchors`),
  attachmentBlob: (tenant: string, id: string): Promise<BlobResult> => api.blob(`${t(tenant)}/attachments/${encodeURIComponent(id)}/blob`),
  activity: (tenant: string, limit: number, beforeSeq?: number | null) =>
    api.get<ActivityPage>(`${t(tenant)}/activity`, { limit, before_seq: beforeSeq ?? undefined }),
  members: (tenant: string) => api.get<MemberList>(`${t(tenant)}/members`),
  addMember: (tenant: string, user: string, role: Role) => api.post<unknown>(`${t(tenant)}/members`, { user, role }),
  setMemberRole: (tenant: string, id: string, role: Role) => api.patch<unknown>(`${t(tenant)}/members/${encodeURIComponent(id)}`, { role }),
  removeMember: (tenant: string, id: string) => api.delete<unknown>(`${t(tenant)}/members/${encodeURIComponent(id)}`),
}
