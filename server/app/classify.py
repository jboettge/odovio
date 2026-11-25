"""Fahrt-Vorschlag (Kategorie/Zweck/Kunde) über ein selbst gehostetes LLM (vLLM, OpenAI-kompatibel).

Env:
  VLLM_URL       z. B. http://vllm:8000/v1 (leer → nicht konfiguriert)
  VLLM_MODEL     Default "qwen3.5-9b"
  VLLM_API_KEY   optional (vLLM --api-key)
  LLM_TIMEOUT_S  Default 10

Datenschutz: Es werden nur Ortsbezeichnungen, Uhrzeiten, Wochentag, Dauer und Distanz gesendet –
nie Koordinaten. Privatfahrten (private_mode) werden gar nicht gesendet.
Der Vorschlag ist immer nur ein Vorschlag; bestätigt wird in der App.
"""
import datetime as dt
import json
import logging
import os
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import geo
from .geo import GeoUnavailable, UpstreamError

log = logging.getLogger("fahrzeugbuch.classify")

CATEGORIES = ["business", "private", "commute", "field"]
WEEKDAYS = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]


class LLMUnavailable(GeoUnavailable):
    pass


class PrivateTrip(ValueError):
    pass


SYSTEM_PROMPT = (
    "Du unterstützt ein Schweizer Fahrtenbuch (Steuer/Spesen). Schlage für eine Fahrt Kategorie, "
    "Zweck und allenfalls Kunde vor.\n"
    "Kategorien: business = geschäftliche Fahrt (Kunde, Lieferant, Termin), private = Privatfahrt, "
    "commute = Arbeitsweg Wohnort↔fester Arbeitsort, field = Aussendienst (mehrere Geschäftsorte, "
    "kein fester Arbeitsort).\n"
    "Regeln: Wähle einen Kunden ausschliesslich aus der gegebenen Kundenliste (customer_id = deren id) "
    "oder null. Erfinde keine Kunden, Namen, Orte oder Termine. Der Zweck ist kurz und sachlich "
    "(höchstens 120 Zeichen, Deutsch) und stützt sich nur auf die gegebenen Angaben. "
    "Begründe knapp (reason). Bei Unsicherheit gib eine niedrige Konfidenz (unter 0.5) an. "
    "Antworte nur mit dem JSON-Objekt gemäss Schema."
)


# ---------- Eingabe ----------
class _In(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", str_strip_whitespace=True)


Label = Field(default=None, max_length=120)


class TripFeatures(_In):
    """Nur pseudonymisierte Merkmale – Koordinaten werden abgelehnt (extra=forbid)."""
    start_at: dt.datetime
    end_at: dt.datetime | None = None
    start_label: str | None = Label
    end_label: str | None = Label
    start_place_name: str | None = Label
    end_place_name: str | None = Label
    distance_km: float | None = Field(default=None, ge=0, le=5000)
    weekday: int | str | None = Field(default=None, description="1=Montag … 7=Sonntag oder Name")
    private_mode: bool = False


class CustomerIn(_In):
    id: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=120)


class RecentTrip(_In):
    start_label: str | None = Label
    end_label: str | None = Label
    category: Literal["business", "private", "commute", "field"] | None = None
    purpose: str | None = Label


class SuggestRequest(_In):
    trip: TripFeatures
    customers: list[CustomerIn] = Field(default_factory=list, max_length=200)
    recent: list[RecentTrip] = Field(default_factory=list, max_length=20)


# ---------- Ausgabe ----------
class LLMSuggestion(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid")
    category: Literal["business", "private", "commute", "field"]
    purpose: str = Field(max_length=120)
    customer_id: str | None
    confidence: float = Field(ge=0, le=1)
    reason: str = Field(max_length=200)


def schema(customer_ids: list[str]) -> dict:
    customer = ({"type": ["string", "null"], "enum": [*customer_ids, None]} if customer_ids
                else {"type": "null"})
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["category", "purpose", "customer_id", "confidence", "reason"],
        "properties": {
            "category": {"type": "string", "enum": CATEGORIES},
            "purpose": {"type": "string", "maxLength": 120},
            "customer_id": customer,
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "reason": {"type": "string", "maxLength": 200},
        },
    }


def _weekday(trip: TripFeatures) -> str:
    w = trip.weekday
    if isinstance(w, int) and 1 <= w <= 7:
        return WEEKDAYS[w - 1]
    if isinstance(w, str) and w:
        return w[:12]
    return WEEKDAYS[trip.start_at.weekday()]


def features(req: SuggestRequest) -> dict:
    """Was das LLM sieht. Zeiten in der Ortszeit des Geräts (Offset aus start_at), ohne Datum."""
    t = req.trip
    out = {
        "wochentag": _weekday(t),
        "start_uhrzeit": t.start_at.strftime("%H:%M"),
        "start": t.start_place_name or t.start_label,
        "ziel": t.end_place_name or t.end_label,
    }
    if t.start_place_name and t.start_label and t.start_label != t.start_place_name:
        out["start_adresse"] = t.start_label
    if t.end_place_name and t.end_label and t.end_label != t.end_place_name:
        out["ziel_adresse"] = t.end_label
    if t.end_at:
        end = t.end_at
        if t.start_at.tzinfo and end.tzinfo:
            end = end.astimezone(t.start_at.tzinfo)
        out["end_uhrzeit"] = end.strftime("%H:%M")
        try:
            minutes = (t.end_at - t.start_at).total_seconds() / 60
        except TypeError:   # naiv vs. mit Zeitzone
            minutes = None
        if minutes is not None and minutes >= 0:
            out["dauer_min"] = round(minutes)
    if t.distance_km is not None:
        out["distanz_km"] = round(t.distance_km, 1)
    return out


def user_message(req: SuggestRequest) -> str:
    payload = {
        "fahrt": features(req),
        "kunden": [{"id": c.id, "name": c.name} for c in req.customers],
        "letzte_fahrten": [{k: v for k, v in r.model_dump().items() if v is not None} for r in req.recent],
    }
    return json.dumps(payload, ensure_ascii=False)


def _config():
    try:
        base = geo.base_url("VLLM_URL")
    except GeoUnavailable as e:
        raise LLMUnavailable("VLLM_URL") from e
    return base, (os.environ.get("VLLM_MODEL") or "qwen3.5-9b").strip(), os.environ.get("VLLM_API_KEY") or None, \
        geo.env_float("LLM_TIMEOUT_S", 10)


def configured() -> bool:
    try:
        _config()
        return True
    except GeoUnavailable:
        return False


def build_request(req: SuggestRequest, model: str) -> dict:
    ids = list(dict.fromkeys(c.id for c in req.customers))
    s = schema(ids)
    return {
        "model": model,
        "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                     {"role": "user", "content": user_message(req)}],
        "temperature": 0,
        "max_tokens": 400,
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "trip_suggestion", "strict": True, "schema": s}},
        "guided_json": s,                                   # ältere vLLM-Versionen
        "chat_template_kwargs": {"enable_thinking": False},  # Qwen: ohne Denkphase
    }


_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)
_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$")


def parse(content, customer_ids: set[str]) -> dict | None:
    if not isinstance(content, str):
        return None
    text = _FENCE.sub("", _THINK.sub("", content).strip()).strip()
    try:
        s = LLMSuggestion.model_validate_json(text)
    except (ValidationError, ValueError):
        log.info("LLM-Antwort verworfen (Schema)")
        return None
    out = s.model_dump()
    out["purpose"] = out["purpose"].strip()
    out["reason"] = out["reason"].strip()
    if out["customer_id"] not in customer_ids:
        out["customer_id"] = None
    out["source"] = "llm"
    return out


def suggest(req: SuggestRequest) -> dict | None:
    """Vorschlag oder None (kein verwertbarer Vorschlag). Fehler: PrivateTrip, LLMUnavailable, UpstreamError."""
    if req.trip.private_mode:
        raise PrivateTrip("Privatfahrten werden nicht an das LLM gesendet")
    base, model, key, timeout = _config()
    headers = {"Authorization": f"Bearer {key}"} if key else None
    res = geo.http_json(f"{base}/chat/completions", build_request(req, model), headers=headers, timeout=timeout)
    try:
        content = res["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as e:
        raise UpstreamError("LLM: unerwartete Antwort") from e
    return parse(content, {c.id for c in req.customers})
