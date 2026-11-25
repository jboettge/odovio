import json
import os

DEFAULT_TEMPLATES = [
    {
        "title": "Service",
        "items": [
            "Motoröl gewechselt",
            "Ölfilter gewechselt",
            "Luftfilter geprüft/gewechselt",
            "Innenraumfilter gewechselt",
            "Bremsflüssigkeit geprüft",
            "Kühlmittel geprüft",
            "Scheibenwaschwasser aufgefüllt",
            "Beleuchtung geprüft",
            "Batterie geprüft",
            "Serviceintervall zurückgesetzt",
        ],
    },
    {
        "title": "Reifenwechsel",
        "items": [
            "Räder gewechselt",
            "Profiltiefe geprüft",
            "Reifendruck eingestellt",
            "Radschrauben nachgezogen (nach 50 km)",
            "Eingelagerte Räder gereinigt",
        ],
    },
    {
        "title": "MFK-Vorbereitung",
        "items": [
            "Beleuchtung & Blinker",
            "Bremsen (Beläge/Scheiben)",
            "Reifen (Profil, Alter)",
            "Scheibenwischer",
            "Auspuff dicht",
            "Keine Ölverluste",
            "Fahrzeugausweis dabei",
        ],
    },
]


def load_templates() -> list[dict]:
    path = os.environ.get("CHECKLIST_FILE")
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return DEFAULT_TEMPLATES
