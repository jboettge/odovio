"""Zeitzone des Fahrtenbuchs: Monatszuordnung, „heute“ und Anzeige immer in einer festen Zone.

Fahrten tragen ihren eigenen Offset (ISO-8601). Für Monatsabschluss, Prüfungen und Berichte zählt die
lokale Zeit in `APP_TIMEZONE` (Default Europe/Zurich) – nicht der Datumsteil des Textes: sonst liesse sich
`2026-11-01T12:30+14:00` (in Zürich noch 31.10.) in einen anderen Monat schieben.
"""
import datetime as dt
import os
from zoneinfo import ZoneInfo

TZ = ZoneInfo((os.environ.get("APP_TIMEZONE") or "Europe/Zurich").strip())

# Max. Unterschied zwischen dem Datumsteil eines Zeitstempels (Offset −12…+14 h) und dem lokalen Datum
TEXT_SLACK = dt.timedelta(days=2)


def local(ts: str) -> dt.datetime:
    return dt.datetime.fromisoformat(ts).astimezone(TZ)


def local_date(ts: str) -> dt.date:
    return local(ts).date()


def local_month(ts: str) -> str:
    return f"{local(ts):%Y-%m}"


def now() -> dt.datetime:
    return dt.datetime.now(TZ)


def today() -> dt.date:
    return now().date()


def current_month() -> str:
    return f"{today():%Y-%m}"
