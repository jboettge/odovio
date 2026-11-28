// Fokus-Hilfen für Formulare.

/** Erstes fehlerhaftes Feld: aria-invalid, sonst das erste Eingabeelement neben einer Fehlermeldung. */
export function firstInvalid(root: ParentNode): HTMLElement | null {
  const marked = root.querySelector<HTMLElement>('[aria-invalid="true"]')
  if (marked) return marked
  const err = root.querySelector('.error')
  return err?.closest('.field, fieldset')?.querySelector<HTMLElement>('input:not([type=hidden]), select, textarea') ?? null
}
