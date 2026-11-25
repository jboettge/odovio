// Abbruch laufender GETs beim Routenwechsel: Jede Seite bekommt ein frisches Signal; verlässt man sie,
// werden ihre noch offenen Anfragen abgebrochen (Server wird nicht mit veralteten Anfragen belastet).
let ctrl = new AbortController()

export function navigationSignal(): AbortSignal {
  return ctrl.signal
}

/** Offene GETs der bisherigen Seite abbrechen und neues Signal bereitstellen. */
export function abortNavigation(): void {
  ctrl.abort()
  ctrl = new AbortController()
}
