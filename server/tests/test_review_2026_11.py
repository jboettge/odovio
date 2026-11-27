"""Befunde aus docs/REVIEW-2026-11.md ohne eigenen Testort: Zeitzone «heute» (S9), doppelter Content-Type (X6),
gestaffeltes Vollabgleich-Limit (X7), exaktes Gruppen-Mapping (X9), HEIF-Brand (X13), Metadaten der Scan-Bilder und
Warnung zu Hilfsdiensten (X14), IPv6-Limits je /64 (X16), lokales Budget bei Valkey-Ausfall (X5)."""
import base64
import datetime as dt
import io
import json

import pytest

from app import attachments, auth, main, security, state, stats, timeutil, vision

from .conftest import T, bearer_token, new_vehicle, op, sync, uid
from .test_security import events, other  # noqa: F401  (Fixture)


# ---------- S9: «heute» in APP_TIMEZONE ----------
def test_due_items_use_app_timezone(monkeypatch):
    """Kurz nach Mitternacht in Zürich ist in UTC noch der Vortag – fällig ist, was heute (Zürich) fällig ist."""
    zurich_now = dt.datetime(2026, 3, 2, 0, 30, tzinfo=timeutil.TZ)
    assert zurich_now.astimezone(dt.UTC).date() == dt.date(2026, 3, 1)
    monkeypatch.setattr(timeutil, "now", lambda: zurich_now)
    m = type("M", (), {"id": "m1", "title": "MFK", "date": dt.date(2025, 3, 2), "km": None, "next_due_km": None,
                       "next_due_date": dt.date(2026, 3, 2), "cost": None})()
    v = type("V", (), {"initial_km": 0})()
    data = stats.VehicleData(v, [], [], [m], {})
    assert stats.due_items(data)[0]["overdue"] is True


# ---------- X6: mehrdeutiger Content-Type ----------
def test_duplicate_content_type_rejected(client):
    body = json.dumps({"ops": [op("vehicle", uid(), {"name": "x"})]})
    r = client.post(f"{T}/sync", content=body,
                    headers=[("Content-Type", "application/json"), ("Content-Type", "text/plain")])
    assert r.status_code == 400 and "mehrfach" in r.json()["detail"]
    r = client.post(f"{T}/sync", content=body, headers={"Content-Type": "application/json"})
    assert r.status_code == 200


# ---------- X7: Vollabgleich gestaffelt ----------
def test_deep_changes_rate_limited(client, monkeypatch):
    monkeypatch.setenv("RATE_DEEP_SYNC", "2")
    monkeypatch.setattr(main, "CHANGES_MAX", 2)
    vid = new_vehicle(client)
    for i in range(4):
        sync(client, op("odometer", uid(), {"vehicle_id": vid, "date": f"2026-01-0{i + 1}", "km": 10001 + i}))
    codes = [client.get(f"{T}/changes?since=1").status_code for _ in range(3)]     # 4 Revisionen zurück
    assert codes == [200, 200, 429]
    assert client.get(f"{T}/changes?since=2&limit=1").status_code == 429            # gleiches Kontingent
    assert [client.get(f"{T}/changes?since=4").status_code for _ in range(5)] == [200] * 5   # inkrementell frei


# ---------- X9: Gruppen exakt wie die Mitgliederverwaltung ----------
def test_group_mapping_exact(client, events):  # noqa: F811
    groups = ["/fahrzeugbuch/Privat", "/fahrzeugbuch/privat/read", "/fahrzeugbuch/privat/Lesen",
              "/fahrzeugbuch/privat/ADMIN", "/fahrzeugbuch/firma", "/fahrzeugbuch/b-re.ch/lesen",
              "/fahrzeugbuch/x/admin/zu-tief", "/andere-app/privat"]
    me = client.get("/api/me", headers=bearer_token(groups=groups)).json()
    assert me["tenants"] == [{"slug": "b-re.ch", "role": "read"}, {"slug": "firma", "role": "write"}]
    warned = " ".join(e.get("reason", "") for e in events if e["event"] == "config_warning")
    for g in ("/fahrzeugbuch/Privat", "/fahrzeugbuch/privat/read", "/fahrzeugbuch/privat/Lesen",
              "/fahrzeugbuch/privat/ADMIN", "/fahrzeugbuch/x/admin/zu-tief"):
        assert g in warned, g
    assert "/andere-app" not in warned
    assert auth.tenants_from_claims({"groups": ["/fahrzeugbuch/privat/lesen", "/fahrzeugbuch/privat/admin"]}) \
        == {"privat": "admin"}


# ---------- X13: HEIC nur mit HEIF-Brand ----------
@pytest.mark.parametrize("head,ok", [
    (b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic", True),
    (b"\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00mif1heic", True),
    (b"\x00\x00\x00\x1cftypMiHE\x00\x00\x00\x00MiHEmiafheix", True),     # kompatible Brand genügt
    (b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2", False),         # MP4
    (b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00qt  ", False),             # MOV
    (b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom", False),
    (b"\xff\xff\xff\xffftypavif\x00\x00\x00\x00", False),                 # unplausible Grösse, AVIF
])
def test_heif_brand(head, ok):
    assert attachments.content_matches("image/heic", head + b"\x00" * 64) is ok


# ---------- X14: Metadaten der Scan-Bilder ----------
def _jpeg_with_exif(orientation: int | None = 6) -> bytes:
    from PIL import Image
    img = Image.new("RGB", (32, 16), (200, 30, 30))
    exif = Image.Exif()
    exif[0x010F] = "Apple"                                   # Make
    if orientation is not None:
        exif[0x0112] = orientation
    exif[0x8825] = {1: "N", 2: (47.0, 22.0, 1.5), 3: "E", 4: (8.0, 32.0, 2.5)}   # GPS-IFD
    out = io.BytesIO()
    img.save(out, "JPEG", exif=exif, comment=b"Notiz mit Ort", quality=80)
    return out.getvalue()


def test_scan_image_metadata_stripped():
    from PIL import Image
    raw = _jpeg_with_exif()
    assert b"Exif" in raw and b"Apple" in raw and b"Notiz mit Ort" in raw
    clean, mime = vision.decode_image(base64.b64encode(raw).decode())
    assert mime == "image/jpeg" and b"Apple" not in clean and b"Notiz mit Ort" not in clean
    img = Image.open(io.BytesIO(clean))
    img.load()                                               # Pixel unverändert dekodierbar
    exif = img.getexif()
    assert dict(exif) == {0x0112: 6}                         # nur die Ausrichtung bleibt
    assert exif.get_ifd(0x8825) == {}
    assert img.size == (32, 16)
    # ohne Ausrichtung: gar kein Exif mehr
    clean = vision.strip_metadata(_jpeg_with_exif(orientation=None), "image/jpeg")
    assert b"Exif" not in clean and dict(Image.open(io.BytesIO(clean)).getexif()) == {}
    # angehängte Daten nach EOI (z. B. Zusatzbilder) fallen weg
    assert vision.strip_metadata(raw + b"\xff\xd8GPS-im-Anhang\xff\xd9", "image/jpeg").count(b"GPS-im-Anhang") == 0


def test_scan_png_text_chunks_stripped():
    from PIL import Image, PngImagePlugin
    info = PngImagePlugin.PngInfo()
    info.add_text("Location", "47.37,8.54")
    out = io.BytesIO()
    Image.new("RGB", (4, 4)).save(out, "PNG", pnginfo=info)
    raw = out.getvalue()
    assert b"Location" in raw
    clean = vision.strip_metadata(raw, "image/png")
    assert b"Location" not in clean and Image.open(io.BytesIO(clean)).size == (4, 4)


def test_scan_image_unparsable_passes_unchanged():
    raw = b"\xff\xd8\xff\xe0\x10JFIF" + bytes(range(256))
    assert vision.strip_metadata(raw, "image/jpeg") == raw


@pytest.mark.parametrize("url,warn", [
    ("http://osrm:5000", False), ("http://host.docker.internal:5000", False), ("http://10.0.10.5:5000", False),
    ("http://[fd00::5]:5000", False), ("http://photon.lan:2322", False), ("http://localhost:8000/v1", False),
    ("https://vllm.example.org/v1", False), ("http://vllm.example.org/v1", True), ("http://1.1.1.1:8000", True),
    ("ftp://osrm:5000", True),
])
def test_upstream_url_warnings(monkeypatch, url, warn):
    for name in security.UPSTREAM_URLS:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.delenv("UPSTREAM_ALLOW_HTTP", raising=False)
    monkeypatch.setenv("VLLM_URL", url)
    got = security.upstream_warnings()
    assert bool(got) is warn, got
    if warn:
        assert any("VLLM_URL" in w for w in security.config_warnings())
    monkeypatch.setenv("UPSTREAM_ALLOW_HTTP", "1")
    assert bool(security.upstream_warnings()) is (warn and url.startswith("ftp"))


# ---------- X16: IPv6 je /64 ----------
def test_ipv6_limits_per_prefix(client, monkeypatch, events):  # noqa: F811
    monkeypatch.setenv("RATE_IP_PER_MIN", "3")
    monkeypatch.setenv("RATE_IP_BURST", "3")
    a, b, c = other("2001:db8:1:2::1"), other("2001:db8:1:2:ffff::9"), other("2001:db8:1:3::1")
    assert [a.get("/api/me").status_code for _ in range(2)] == [200, 200]
    assert [b.get("/api/me").status_code for _ in range(2)] == [200, 429]           # gleiches /64
    assert c.get("/api/me").status_code == 200                                      # anderes /64
    assert security.limit_key("2001:db8:1:2::1") == "2001:db8:1:2::/64"
    assert security.limit_key("198.51.100.7") == "198.51.100.7"
    assert security.limit_key("::ffff:198.51.100.7") == "198.51.100.7"
    monkeypatch.setenv("IPV6_LIMIT_PREFIX", "128")
    assert security.limit_key("2001:db8:1:2::1") == "2001:db8:1:2::1"


def test_ipv6_block_logs_client_ip_and_net(client, monkeypatch, events):  # noqa: F811
    from .conftest import forged_auth
    monkeypatch.setenv("BRUTE_401_THRESHOLD", "2")
    a, b = other("2001:db8:5:6::1"), other("2001:db8:5:6::2")
    assert a.get("/api/me", headers=forged_auth()).status_code == 401
    assert b.get("/api/me", headers=forged_auth()).status_code == 401
    assert a.get("/api/me").status_code == 429                                      # ganzes /64 gesperrt
    block = next(e for e in events if e["event"] == "brute_force_block")
    assert block["ip"] == "2001:db8:5:6::2" and block["net"] == "2001:db8:5:6::/64"  # fail2ban: volle IP


# ---------- X5: Valkey-Ausfall → lokales Budget ----------
@pytest.fixture
def broken_state(monkeypatch):
    monkeypatch.setenv("STATE_BACKEND", "redis")
    monkeypatch.setenv("REDIS_URL", "redis://127.0.0.1:1/0")
    monkeypatch.setenv("REDIS_TIMEOUT_MS", "100")
    monkeypatch.setenv("REDIS_RETRY_S", "5")
    broken = state.RedisState("redis://127.0.0.1:1/0", key_prefix="fzbbroken:")
    state.configure(broken)
    yield broken
    state.configure(None)


def test_outage_uses_local_budget(client, broken_state, monkeypatch, events):  # noqa: F811
    monkeypatch.setenv("WEB_CONCURRENCY", "2")
    monkeypatch.setenv("REPLICAS_HINT", "2")
    monkeypatch.setenv("RATE_IP_PER_MIN", "8")
    monkeypatch.setenv("RATE_IP_BURST", "8")                  # 8 ÷ (2 × 2) = 2 je Prozess
    c = other("203.0.113.120")
    assert [c.get("/api/me").status_code for _ in range(3)] == [200, 200, 429]
    assert any(e["event"] == "state_backend_error" for e in events)
    assert security.local_budget(1) == 1 and security.local_budget(9) == 3
