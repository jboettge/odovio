"""Bildauswertung von Belegen (Zapfsäule, Quittung, Tacho) über ein Vision-LLM (vLLM, OpenAI-kompatibel).

Env:
  VLLM_VISION_URL    Default = VLLM_URL (z. B. http://vllm-vision:8000/v1)
  VLLM_VISION_MODEL  Modellname; leer → nicht konfiguriert (503)
  VLLM_API_KEY       optional (vLLM --api-key)
  LLM_TIMEOUT_S      Default 10

Datenschutz: Das Bild wird nur an das selbst gehostete LLM weitergereicht – weder gespeichert noch
protokolliert. Vorher entfernt der Server Metadaten (Review X14, ohne Neukodierung der Pixel): JPEG ohne
APP1 (Exif inkl. GPS, XMP), APP13 (IPTC), Kommentare, MPF und angehängte Zusatzbilder – die Ausrichtung bleibt als
minimales Exif (nur Orientation) erhalten; PNG ohne eXIf/tEXt/zTXt/iTXt/tIME. Lässt sich die Struktur nicht
lesen, geht das Bild unverändert weiter (die App sendet ohnehin neu kodierte Bilder). Das Ergebnis ist ein
Vorschlag; übernommen wird in der App.
"""
import base64
import binascii
import datetime as dt
import logging
import os
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import geo
from .classify import LLMUnavailable
from .geo import GeoUnavailable, UpstreamError

log = logging.getLogger("fahrzeugbuch.vision")

MAX_IMAGE_BYTES = 2 * 1024 * 1024
MAX_IMAGE_B64 = 4 * ((MAX_IMAGE_BYTES + 2) // 3)
ScanKind = Literal["pump", "receipt", "odometer"]

BOUNDS = {"liters": (0, 5000), "amount": (0, 100_000), "price_per_liter": (0.3, 10), "km": (0, 5_000_000)}

SYSTEM_PROMPT = (
    "Du liest Werte aus Fotos für ein Schweizer Fahrzeugbuch (Tankvorgänge, km-Stand). "
    "Gib nur Werte an, die auf dem Bild eindeutig lesbar sind; alles andere ist null. Erfinde nichts. "
    "Zahlen ohne Einheit und Tausendertrennzeichen, Dezimalpunkt. Beträge in der Währung des Belegs "
    "(normalerweise CHF). Datum als YYYY-MM-DD. station = Name/Marke der Tankstelle, sonst null. "
    "Begründe knapp (reason), z. B. welche Anzeige gelesen wurde. Bei schlechter Lesbarkeit niedrige "
    "Konfidenz (unter 0.5). Antworte nur mit dem JSON-Objekt gemäss Schema."
)
TASKS = {
    "pump": "Foto einer Zapfsäulenanzeige: lies getankte Liter (liters), Betrag (amount) und Preis pro "
            "Liter (price_per_liter). km und date sind normalerweise null.",
    "receipt": "Foto einer Tankquittung: lies Liter (liters), Gesamtbetrag (amount), Preis pro Liter "
               "(price_per_liter), Datum (date) und Tankstelle (station).",
    "odometer": "Foto eines Tachos/Kilometerzählers: lies den Gesamtkilometerstand (km, ganze Zahl, nicht "
                "den Tageskilometerzähler). Übrige Werte null.",
}


class InvalidImage(ValueError):
    pass


# ---------- Bild ----------
JPEG, PNG = b"\xff\xd8\xff", b"\x89PNG\r\n\x1a\n"


def decode_image(image_b64: str) -> tuple[bytes, str]:
    """Base64 (optional als data:-URL) → (Bytes ohne Metadaten, MIME). Nur JPEG/PNG, dekodiert ≤ 2 MiB.
    Fehlermeldungen ohne Teile der Eingabe."""
    s = image_b64.strip()
    if s.startswith("data:"):
        head, sep, s = s.partition(",")
        if not sep or not head.endswith(";base64"):
            raise InvalidImage("Bild als Base64 erwartet")
    s = re.sub(r"\s+", "", s)
    if len(s) > MAX_IMAGE_B64 + 4:
        raise InvalidImage("Bild zu gross (max. 2 MiB)")
    try:
        raw = base64.b64decode(s, validate=True)
    except (binascii.Error, ValueError):
        raise InvalidImage("Bild als Base64 erwartet") from None
    if len(raw) > MAX_IMAGE_BYTES:
        raise InvalidImage("Bild zu gross (max. 2 MiB)")
    if raw.startswith(JPEG):
        return strip_metadata(raw, "image/jpeg"), "image/jpeg"
    if raw.startswith(PNG):
        return strip_metadata(raw, "image/png"), "image/png"
    raise InvalidImage("Nur JPEG oder PNG")


# ---------- Metadaten entfernen ----------
class _Malformed(ValueError):
    pass


_JPEG_DROP = {0xE1, 0xED, 0xFE}                  # APP1 (Exif/XMP), APP13 (IPTC/Photoshop), COM
_PNG_DROP = {b"eXIf", b"tEXt", b"zTXt", b"iTXt", b"tIME"}
_ORIENTATION = 0x0112


def _exif_orientation(payload: bytes) -> int | None:
    """Orientation (1–8) aus dem IFD0 eines APP1-Exif-Segments, sonst None."""
    if not payload.startswith(b"Exif\0\0"):
        return None
    tiff = payload[6:]
    order = {b"II*\0": "little", b"MM\0*": "big"}.get(tiff[:4])
    if order is None:
        return None
    off = int.from_bytes(tiff[4:8], order)
    if off + 2 > len(tiff):
        return None
    for i in range(int.from_bytes(tiff[off:off + 2], order)):
        e = off + 2 + 12 * i
        if e + 12 > len(tiff):
            break
        if int.from_bytes(tiff[e:e + 2], order) == _ORIENTATION:
            v = int.from_bytes(tiff[e + 8:e + 10], order)
            return v if 1 <= v <= 8 else None
    return None


def _orientation_segment(v: int) -> bytes:
    """Minimales APP1-Exif nur mit IFD0/Orientation (Big Endian)."""
    entry = _ORIENTATION.to_bytes(2, "big") + (3).to_bytes(2, "big") + (1).to_bytes(4, "big") \
        + v.to_bytes(2, "big") + b"\0\0"
    payload = b"Exif\0\0" + b"MM\0*" + (8).to_bytes(4, "big") + (1).to_bytes(2, "big") + entry + bytes(4)
    return b"\xff\xe1" + (len(payload) + 2).to_bytes(2, "big") + payload


def _strip_jpeg(raw: bytes) -> bytes:
    head, rest, orientation, i = [raw[:2]], [], None, 2
    while True:
        if i >= len(raw) or raw[i] != 0xFF:
            raise _Malformed
        while i < len(raw) and raw[i] == 0xFF:          # Füllbytes vor dem Marker
            i += 1
        if i >= len(raw):
            raise _Malformed
        marker = raw[i]
        i += 1
        if 0xD0 <= marker <= 0xD7 or marker == 0x01:  # ohne Länge
            rest.append(bytes([0xFF, marker]))
            continue
        if i + 2 > len(raw):
            raise _Malformed
        length = int.from_bytes(raw[i:i + 2], "big")
        if length < 2 or i + length > len(raw):
            raise _Malformed
        if marker == 0xDA:                             # Start of Scan: Bilddaten bis EOI, Anhang verwerfen
            end = raw.find(b"\xff\xd9", i + length)
            if end < 0:
                raise _Malformed
            rest.append(b"\xff\xda" + raw[i:end + 2])
            break
        payload = raw[i + 2:i + length]
        if marker in _JPEG_DROP or (marker == 0xE2 and payload.startswith(b"MPF\0")):
            if marker == 0xE1 and orientation is None:
                orientation = _exif_orientation(payload)
        elif marker == 0xE0 and not rest:              # JFIF/JFXX bleibt direkt nach SOI
            head.append(b"\xff\xe0" + raw[i:i + length])
        else:
            rest.append(bytes([0xFF, marker]) + raw[i:i + length])
        i += length
    if orientation and orientation != 1:
        head.append(_orientation_segment(orientation))
    return b"".join(head + rest)


def _strip_png(raw: bytes) -> bytes:
    out, i = [raw[:8]], 8
    while True:
        if i + 12 > len(raw):
            raise _Malformed
        length = int.from_bytes(raw[i:i + 4], "big")
        kind = raw[i + 4:i + 8]
        end = i + 12 + length
        if end > len(raw):
            raise _Malformed
        if kind not in _PNG_DROP:
            out.append(raw[i:end])
        i = end
        if kind == b"IEND":
            return b"".join(out)


def strip_metadata(raw: bytes, mime: str) -> bytes:
    """Metadaten (Exif/GPS, XMP, IPTC, Kommentare) entfernen, ohne die Pixel neu zu kodieren."""
    try:
        return _strip_jpeg(raw) if mime == "image/jpeg" else _strip_png(raw)
    except _Malformed:
        log.debug("Bildstruktur nicht lesbar – Metadaten nicht entfernt")
        return raw


# ---------- Konfiguration ----------
def _config():
    try:
        base = geo.base_url("VLLM_VISION_URL" if (os.environ.get("VLLM_VISION_URL") or "").strip() else "VLLM_URL")
    except GeoUnavailable as e:
        raise LLMUnavailable("VLLM_VISION_URL") from e
    model = (os.environ.get("VLLM_VISION_MODEL") or "").strip()
    if not model:
        raise LLMUnavailable("VLLM_VISION_MODEL")
    return base, model, os.environ.get("VLLM_API_KEY") or None, geo.env_float("LLM_TIMEOUT_S", 10)


def configured() -> bool:
    try:
        _config()
        return True
    except GeoUnavailable:
        return False


# ---------- Anfrage ----------
def _num(kind: str, lo: float, hi: float) -> dict:
    return {"type": [kind, "null"], "minimum": lo, "maximum": hi}


def schema() -> dict:
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["liters", "amount", "price_per_liter", "km", "date", "station", "confidence", "reason"],
        "properties": {
            "liters": _num("number", *BOUNDS["liters"]),
            "amount": _num("number", *BOUNDS["amount"]),
            "price_per_liter": _num("number", *BOUNDS["price_per_liter"]),
            "km": _num("integer", *BOUNDS["km"]),
            "date": {"type": ["string", "null"], "maxLength": 10},
            "station": {"type": ["string", "null"], "maxLength": 100},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "reason": {"type": "string", "maxLength": 200},
        },
    }


def build_request(raw: bytes, mime: str, kind: str, model: str) -> dict:
    s = schema()
    url = f"data:{mime};base64,{base64.b64encode(raw).decode()}"
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": [
                {"type": "text", "text": TASKS[kind]},
                {"type": "image_url", "image_url": {"url": url}},
            ]},
        ],
        "temperature": 0,
        "max_tokens": 300,
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "receipt_scan", "strict": True, "schema": s}},
        "guided_json": s,                                   # ältere vLLM-Versionen
        "chat_template_kwargs": {"enable_thinking": False},  # Qwen: ohne Denkphase
    }


# ---------- Antwort ----------
class LLMScan(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="ignore")
    liters: float | None = Field(default=None, ge=0, le=5000)
    amount: float | None = Field(default=None, ge=0, le=100_000)
    price_per_liter: float | None = Field(default=None, ge=0.3, le=10)
    km: int | None = Field(default=None, ge=0, le=5_000_000)
    date: str | None = Field(default=None, max_length=40)
    station: str | None = Field(default=None, max_length=200)
    confidence: float = Field(ge=0, le=1)
    reason: str = Field(default="", max_length=400)


_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)
_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$")
_DMY = re.compile(r"^(\d{1,2})\.(\d{1,2})\.(\d{2}|\d{4})$")


def _date(v: str | None) -> str | None:
    """YYYY-MM-DD (auch aus TT.MM.JJJJ), sonst None."""
    if not v:
        return None
    v = v.strip()
    try:
        if m := _DMY.match(v):
            d, mo, y = (int(x) for x in m.groups())
            d = dt.date(y + 2000 if y < 100 else y, mo, d)
        else:
            d = dt.date.fromisoformat(v[:10])
    except ValueError:
        return None
    return d.isoformat() if 2000 <= d.year <= 2100 else None


def plausible(out: dict) -> dict:
    """Betrag ≈ Liter × Preis/l (Toleranz max(0.05, 1 % des Betrags)), sonst Konfidenz halbieren."""
    liters, amount, ppl = out["liters"], out["amount"], out["price_per_liter"]
    if liters is not None and amount is not None and ppl is not None:
        diff = abs(amount - liters * ppl)
        if diff > max(0.05, 0.01 * amount):
            out["confidence"] = round(out["confidence"] / 2, 3)
            note = f"Unplausibel: Liter × Preis/l = {liters * ppl:.2f} ≠ Betrag {amount:.2f}"
            out["reason"] = f"{out['reason']} · {note}" if out["reason"] else note
    return out


def parse(content) -> dict | None:
    """Ergebnis oder None (Antwort unbrauchbar oder kein einziger Wert gelesen)."""
    if not isinstance(content, str):
        return None
    text = _FENCE.sub("", _THINK.sub("", content).strip()).strip()
    try:
        s = LLMScan.model_validate_json(text)
    except (ValidationError, ValueError):
        log.info("Vision-Antwort verworfen (Schema)")
        return None
    station = (s.station or "").strip()[:100] or None
    out = {
        "liters": None if s.liters is None else round(s.liters, 3),
        "amount": None if s.amount is None else round(s.amount, 2),
        "price_per_liter": None if s.price_per_liter is None else round(s.price_per_liter, 3),
        "km": s.km,
        "date": _date(s.date),
        "station": station,
        "confidence": s.confidence,
        "reason": s.reason.strip()[:200],
    }
    if all(out[k] is None for k in ("liters", "amount", "price_per_liter", "km", "date", "station")):
        return None
    return plausible(out)


def scan(raw: bytes, mime: str, kind: str) -> dict | None:
    """Fehler: LLMUnavailable (nicht konfiguriert), UpstreamError (Dienst/Antwort)."""
    base, model, key, timeout = _config()
    headers = {"Authorization": f"Bearer {key}"} if key else None
    with geo.UPSTREAMS["vision"].guard():
        res = geo.http_json(f"{base}/chat/completions", build_request(raw, mime, kind, model),
                            headers=headers, timeout=timeout)
        try:
            content = res["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as e:
            raise UpstreamError("Vision-LLM: unerwartete Antwort") from e
    return parse(content)
