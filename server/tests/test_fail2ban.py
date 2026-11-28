"""X4: fail2ban-Filter (deploy/fail2ban) gegen echte Zeilen des Sicherheits-Logs und Angriffszeilen.

fail2ban wird nachgebildet: datepattern suchen, den gefundenen Zeitstempel aus der Zeile entfernen (wie
fail2ban), dann failregex mit <ADDR> als benannte Gruppe. Ziel: nur Ereignisse der API selbst, nur die vom
Server ermittelte IP – nie eine per Pfad/Header/fremdem Container eingeschleuste."""
import configparser
import json
import logging
import re
from pathlib import Path

import pytest

from app import security

from .conftest import forged_auth

CONF = Path(__file__).resolve().parents[2] / "deploy" / "fail2ban"
VICTIM = "9.9.9.9"
INJECT = f'","logger":"fahrzeugbuch.security","event":"auth_failed","ip":"{VICTIM}'


def _filter() -> tuple[re.Pattern, re.Pattern]:
    cp = configparser.ConfigParser(interpolation=configparser.BasicInterpolation())
    cp.read(CONF / "filter.d" / "fahrzeugbuch.conf")
    d = cp["Definition"]
    fail = d["failregex"].replace("<ADDR>", r"(?P<addr>[0-9a-fA-F:.]+)")
    date = d["datepattern"]
    for k, v in {"%Y": r"\d{4}", "%m": r"\d{2}", "%d": r"\d{2}", "%H": r"\d{2}", "%M": r"\d{2}",
                 "%S": r"\d{2}"}.items():
        date = date.replace(k, v)
    assert ".*" not in d["failregex"] and d.get("failregex", raw=True).startswith("%(_head)s")
    assert ".*" not in date
    return re.compile(fail), re.compile(date)


def match(line: str, journal: bool = False) -> str | None:
    """IP, die fail2ban aus der Zeile sperren würde (None = keine)."""
    fail, date = _filter()
    if not journal:                      # Datei/json-file: Zeitstempel entfernen; Journal liefert die Zeit selbst
        if m := date.search(line):
            line = line[:m.start()] + line[m.end():]
    m = fail.search(line)
    return m.group("addr") if m else None


def raw(event="auth_failed", ip="198.51.100.7", path="/api/me", **extra) -> str:
    fields = {"ts": "2026-11-27T10:00:00.123Z", "logger": "fahrzeugbuch.security", "event": event, "ip": ip,
              "path": path, "status": 401, **extra}
    return json.dumps(fields, ensure_ascii=True, separators=(",", ":"))


def docker(line: str) -> str:
    return json.dumps({"log": line + "\n", "stream": "stderr", "time": "2026-11-27T10:00:00.1234Z"},
                      separators=(",", ":"))


def journal(line: str) -> str:
    return f"docker-host fahrzeugbuch-api[812]: {line}"


@pytest.mark.parametrize("event", ["auth_failed", "brute_force_block", "rate_limited"])
@pytest.mark.parametrize("ip", ["198.51.100.7", "2001:db8::42"])
def test_matches_own_events_in_all_forms(event, ip):
    line = raw(event, ip)
    assert match(line) == ip
    assert match(docker(line)) == ip
    assert match(journal(line), journal=True) == ip


@pytest.mark.parametrize("event", ["auth_missing", "host_rejected", "cors_rejected", "forbidden_tenant",
                                   "config_warning", "integrity_failed"])
def test_other_events_ignored(event):
    assert match(raw(event)) is None and match(docker(raw(event))) is None


ATTACKS = {
    # Pfad mit eingeschleustem Fragment (alte Ausgabe ohne URL-Kodierung, JSON escapt " zu \")
    "pfad_roh": raw("host_rejected", "203.0.113.5", path="/x" + INJECT),
    "pfad_docker": docker(raw("host_rejected", "203.0.113.5", path="/x" + INJECT)),
    # anderer Container (z. B. Caddy-JSON-Zugriffslog) mit dem Muster in der URI bzw. am Zeilenanfang einer Nachricht
    "fremder_container": docker(json.dumps({"level": "info", "msg": "handled request",
                                            "request": {"uri": "/" + INJECT}})),
    "fremde_zeile_mit_muster": f'irgendwas {raw(ip=VICTIM)}',
    "fremde_zeile_docker": docker(f'GET /?q={raw(ip=VICTIM)}'),
    # uvicorn-Zugriffslog im API-Container
    "uvicorn": docker(f'INFO:     203.0.113.5:4711 - "GET /{INJECT} HTTP/1.1" 401'),
    "uvicorn_critical": docker(f'CRITICAL: {raw(ip=VICTIM)}'),
    # Feld "ts" erneut in einem Nutzerfeld (Zeitstempel-Verschiebung)
    "zweites_ts": raw("host_rejected", "203.0.113.5", reason='x","ts":"2026-11-27T10:00:00' + INJECT),
}


@pytest.mark.parametrize("name", sorted(ATTACKS))
def test_attack_lines_never_ban_foreign_ip(name):
    line = ATTACKS[name]
    assert match(line) in (None, "203.0.113.5"), name
    assert match(line, journal=True) in (None, "203.0.113.5"), name


def test_journal_line_from_other_process_ignored():
    assert match(f'docker-host sshd[1]: Invalid user {raw(ip=VICTIM)}', journal=True) is None


def test_real_security_log_lines(client):
    """Echte Ausgabe (JsonFormatter): Pfad URL-kodiert ohne `"`; nur die vom Server ermittelte IP passt."""
    lines: list[str] = []

    class H(logging.Handler):
        def emit(self, record):
            lines.append(security.JsonFormatter().format(record))
    h = H()
    security.log.addHandler(h)
    try:
        from .test_security import other
        c = other("203.0.113.77")
        assert c.get("/api/t/x" + INJECT.replace('"', "%22") + "/vehicles", headers=forged_auth()).status_code == 401
        assert c.get('/api/t/a"b\\c/vehicles', headers=forged_auth()).status_code == 401
        c.get("/api/me", headers={"Authorization": ""})                        # auth_missing
    finally:
        security.log.removeHandler(h)
    by_event = {json.loads(x)["event"]: x for x in lines}
    failed = [x for x in lines if json.loads(x)["event"] == "auth_failed"]
    assert len(failed) == 2
    for line in failed:
        path = json.loads(line)["path"]
        assert '"' not in path and "\\" not in path and ("%22" in path or "%5C" in path)
        assert '\\"' not in line.split('"path":', 1)[1].split(",", 1)[0]
        assert match(line) == "203.0.113.77" and match(docker(line)) == "203.0.113.77"
        assert match(journal(line), journal=True) == "203.0.113.77"
    assert match(by_event["auth_missing"]) is None
