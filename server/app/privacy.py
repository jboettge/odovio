"""Privat-Maskierung für die Leserolle (z. B. Treuhand) – zentral für `/changes` und `/history`.

Privatfahrten (Kategorie „private“ oder Privatmodus) behalten nur Zeitpunkte, km-Stände, Distanzen,
Kategorie und Status; Orte, Zweck, Kunde, Notiz, Track-Hash und Vorschläge werden entfernt.
Private Orte verlieren Koordinaten und Namen. Die Schreibrolle sieht alles unverändert.
"""
PRIVATE_PLACE_NAME = "Privater Ort"

TRIP_MASKED = (
    "start_label", "end_label", "start_place_id", "end_place_id", "purpose", "customer_id", "customer_name",
    "note", "track_hash", "suggestion_category", "suggestion_purpose", "suggestion_customer_id",
    "suggestion_confidence", "suggestion_reason", "suggestion_source",
    # Begründungen in Revisionen (Storno/Korrektur im abgeschlossenen Monat)
    "storno_reason", "correction_reason",
)


def is_private(entity: str, data: dict) -> bool:
    if entity == "trip":
        return data.get("category") == "private" or bool(data.get("private_mode"))
    if entity == "place":
        return bool(data.get("private"))
    return False


def mask(entity: str, data: dict, force: bool = False) -> dict:
    """Kopie von `data` ohne private Angaben (force: maskieren, auch wenn dieser Stand nicht privat ist –
    z. B. ältere Revisionen einer inzwischen privaten Fahrt)."""
    if not (force or is_private(entity, data)):
        return data
    out = dict(data)
    if entity == "trip":
        for k in TRIP_MASKED:
            if k in out:
                out[k] = None
    elif entity == "place":
        out.update(lat=None, lon=None, name=PRIVATE_PLACE_NAME)
    return out
