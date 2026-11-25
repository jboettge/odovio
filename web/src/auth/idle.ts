// Abmeldung nach Inaktivität (Standard 30 Minuten; Build-Variable VITE_IDLE_TIMEOUT_MIN).
export const IDLE_TIMEOUT_MIN = Number(import.meta.env.VITE_IDLE_TIMEOUT_MIN ?? 30) || 30
export const LOGOUT_REASON_KEY = 'fzb.logoutReason'

const EVENTS = ['pointerdown', 'keydown', 'wheel', 'touchstart', 'scroll'] as const

export interface IdleWatch {
  stop(): void
  /** Für Tests: letzte Aktivität. */
  readonly lastActivity: number
}

/** Ruft `onIdle` einmal auf, wenn `timeoutMs` lang keine Eingabe erfolgte. */
export function watchIdle(onIdle: () => void, timeoutMs = IDLE_TIMEOUT_MIN * 60_000, now: () => number = Date.now): IdleWatch {
  let last = now()
  let fired = false
  const bump = () => {
    last = now()
  }
  for (const ev of EVENTS) window.addEventListener(ev, bump, { passive: true, capture: true })
  const check = () => {
    if (!fired && now() - last >= timeoutMs) {
      fired = true
      onIdle()
    }
  }
  const timer = window.setInterval(check, Math.min(30_000, Math.max(1000, timeoutMs / 4)))
  document.addEventListener('visibilitychange', check)
  return {
    stop() {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', check)
      for (const ev of EVENTS) window.removeEventListener(ev, bump, { capture: true })
    },
    get lastActivity() {
      return last
    },
  }
}
