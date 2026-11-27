"""Gemeinsames Bewirtschaften: Rolle admin, created_by/updated_by, Aktivitäts-Feed, Mitglieder (Keycloak-Admin-
API als echter HTTP-Server auf 127.0.0.1 gemockt), Web-Frontend-Pflicht für Verwaltung und Steuerparameter."""
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from app import geo

from .conftest import WEB_CLIENT_ID, T, bearer_token, new_vehicle, op, sync, uid, web_headers

ADMIN_GROUPS = ["/fahrzeugbuch/privat/admin"]


def admin_web(**kw) -> dict:
    return web_headers(groups=ADMIN_GROUPS, **kw)


def admin_ios(**kw) -> dict:
    return bearer_token(groups=ADMIN_GROUPS, **kw)


def statuses(res):
    return [r["status"] for r in res["results"]]


# ---------- Rollen ----------
def test_admin_role_and_me(client, monkeypatch):
    h = bearer_token(groups=["/fahrzeugbuch/privat/lesen", "/fahrzeugbuch/privat/admin", "/fahrzeugbuch/firma",
                             "/fahrzeugbuch/firma/lesen", "/fahrzeugbuch/x/admin/zu-tief"],
                     name="Jakob Muster")
    me = client.get("/api/me", headers=h).json()
    assert me["tenants"] == [{"slug": "firma", "role": "write"}, {"slug": "privat", "role": "admin"}]
    assert me["name"] == "jakob" and me["display_name"] == "Jakob Muster"
    assert client.get("/api/me").json()["display_name"] == "jakob"        # ohne name-Claim
    # admin impliziert write: Sync, Monatsabschluss-Prüfung, Vorschläge
    vid = uid()
    assert statuses(sync(client, op("vehicle", vid, {"name": "Golf"}), headers=h)) == ["applied"]
    ch = client.get(f"{T}/changes?since=0", headers=h).json()
    assert ch["vehicles"][0]["name"] == "Golf"
    # DEFAULT_TENANT stuft einen Verwalter nicht herab
    monkeypatch.setenv("DEFAULT_TENANT", "privat")
    assert client.get("/api/me", headers=h).json()["tenants"][1] == {"slug": "privat", "role": "admin"}


def test_web_client_config_and_azp(client, monkeypatch):
    cfg = client.get("/auth/config", headers={"Authorization": ""}).json()
    assert cfg["web_client_id"] == WEB_CLIENT_ID
    assert client.get("/api/me", headers=web_headers()).status_code == 200
    monkeypatch.setenv("OIDC_WEB_CLIENT_ID", "fzb-web2")
    assert client.get("/auth/config", headers={"Authorization": ""}).json()["web_client_id"] == "fzb-web2"
    assert client.get("/api/me", headers=web_headers()).status_code == 401          # alter Web-Client
    assert client.get("/api/me", headers=bearer_token(azp="fzb-web2")).status_code == 200


def test_required_role_from_web_client_roles(client, monkeypatch):
    monkeypatch.setenv("OIDC_REQUIRED_ROLE", "fahrzeugbuch-user")
    h = web_headers(realm_access={}, resource_access={WEB_CLIENT_ID: {"roles": ["fahrzeugbuch-user"]}})
    assert client.get("/api/me", headers=h).status_code == 200


def test_tax_param_only_from_web(client):
    p = {"year": 2026, "scope": "tenant", "key": "km_rate", "value": 0.7}
    xid = uid()
    res = sync(client, op("tax_param", xid, p))
    assert statuses(res) == ["rejected"]
    assert res["results"][0]["error"] == "Steuerparameter nur im Webfrontend bearbeitbar"
    assert statuses(sync(client, op("tax_param", xid, p), headers=web_headers())) == ["applied"]
    res = sync(client, op("tax_param", xid, action="delete"))
    assert statuses(res) == ["rejected"]
    assert statuses(sync(client, op("tax_param", xid, action="delete"), headers=web_headers())) == ["applied"]
    # Leserolle auch im Web: kein Sync
    sync(client, op("tax_param", uid(), p), tenant="firma", headers=web_headers(), expect=403)


# ---------- created_by / updated_by ----------
def test_created_and_updated_by(client):
    vid = uid()
    res = sync(client, op("vehicle", vid, {"name": "Golf", "created_by": "Hacker", "updated_by": "Hacker"}))
    assert statuses(res) == ["applied"]
    v = client.get(f"{T}/changes?since=0").json()["vehicles"][0]
    assert (v["created_by"], v["updated_by"]) == ("jakob", "jakob")
    anna = bearer_token(sub="user-2", preferred_username="anna", groups=["/fahrzeugbuch/privat"])
    assert statuses(sync(client, op("vehicle", vid, {"name": "Golf GTI"}, base=1), headers=anna)) == ["applied"]
    v = client.get(f"{T}/changes?since=0").json()["vehicles"][0]
    assert (v["created_by"], v["updated_by"], v["name"]) == ("jakob", "anna", "Golf GTI")
    # Name aus dem name-Claim, wenn preferred_username fehlt; auf 100 Zeichen gekürzt
    long = bearer_token(sub="user-3", preferred_username=None, name="N" * 150, groups=["/fahrzeugbuch/privat"])
    sync(client, op("vehicle", vid, action="delete"), headers=long)
    v = client.get(f"{T}/changes?since=0").json()["vehicles"][0]
    assert v["deleted"] and v["updated_by"] == "N" * 100 and v["created_by"] == "jakob"
    # Leserolle sieht die Felder ebenfalls; Integrität bleibt grün (nicht im Snapshot)
    reader = bearer_token(groups=["/fahrzeugbuch/privat/lesen"])
    v = client.get(f"{T}/changes?since=0", headers=reader).json()["vehicles"][0]
    assert v["created_by"] == "jakob" and v["updated_by"] == "N" * 100
    hist = client.get(f"{T}/history/vehicle/{vid}").json()
    assert all("created_by" not in r["data"] for r in hist)
    r = client.get(f"{T}/audit/verify?full=1").json()
    assert r["ok"] and r["state_ok"], r


# ---------- Aktivität ----------
def _trip(vid, **kw):
    return {"vehicle_id": vid, "start_at": "2026-11-20T08:00:00+01:00", "end_at": "2026-11-20T08:40:00+01:00",
            "km_start": 1000, "km_end": 1031, "category": "business", "start_label": "Büro",
            "end_label": "Meier AG", "purpose": "Besprechung", "status": "confirmed", **kw}


def test_activity_feed(client):
    vid = new_vehicle(client)
    mid, tid, pid = uid(), uid(), uid()
    sync(client,
         op("fuel", uid(), {"vehicle_id": vid, "date": "2026-11-24", "km": 1100, "liters": 43.6,
                            "price_total": 77.8}),
         op("trip", uid(), _trip(vid)),
         op("place", pid, {"name": "Zuhause Mama", "kind": "other", "private": True}),
         op("trip", tid, _trip(vid, km_start=1031, km_end=1053, category="private", purpose=None,
                               start_label="Meier AG", end_label=None, end_place_id=pid)),
         op("maintenance", mid, {"vehicle_id": vid, "date": "2026-11-25", "title": "Service 50'000"}),
         op("maintenance_item", uid(), {"maintenance_id": mid, "label": "Öl", "done": True}),
         op("odometer", uid(), {"vehicle_id": vid, "date": "2026-11-25", "km": 51234}))
    sync(client, op("trip", tid, action="delete", reason="doppelt erfasst"))
    r = client.get(f"{T}/activity").json()
    items = r["items"]
    assert r["next_before_seq"] is None and [i["seq"] for i in items] == sorted((i["seq"] for i in items),
                                                                                  reverse=True)
    by = {i["seq"]: i for i in items}
    s = [i["summary"] for i in reversed(items)]
    assert s[0] == "Fahrzeug Golf (ZH 123)"
    assert s[1] == "Tankvorgang 24.11. · 43.6 l · CHF 77.80"
    assert s[2] == "Fahrt Büro → Meier AG · 31 km"
    assert s[3] == "Ort Zuhause Mama"
    assert s[4] == "Privatfahrt Meier AG → Zuhause Mama · 22 km"
    assert s[5] == "Wartung Service 50'000"
    assert s[6] == "Checkliste: Öl (erledigt)"
    assert s[7] == "Kilometerstand 25.11. · 51'234 km"
    last = items[0]
    assert last["action"] == "delete" and last["entity"] == "trip" and last["entity_id"] == tid
    assert all(i["vehicle_id"] == vid for i in items if i["entity"] != "place")
    assert by[items[1]["seq"]]["entity"] == "odometer" and items[0]["actor_name"] == "jakob"
    assert items[0]["at"].endswith("+00:00")

    # Leserolle: Privatfahrt und privater Ort maskiert
    reader = bearer_token(groups=["/fahrzeugbuch/privat/lesen"])
    rs = [i["summary"] for i in reversed(client.get(f"{T}/activity", headers=reader).json()["items"])]
    assert rs[3] == "Ort Privater Ort" and rs[4] == "Privatfahrt · 22 km" and rs[-1] == "Privatfahrt · 22 km"
    assert rs[2] == "Fahrt Büro → Meier AG · 31 km"
    assert not any("Mama" in x for x in rs)

    # Seitenweise
    page = client.get(f"{T}/activity?limit=3").json()
    assert len(page["items"]) == 3 and page["next_before_seq"] == page["items"][-1]["seq"]
    nxt = client.get(f"{T}/activity?limit=3&before_seq={page['next_before_seq']}").json()
    assert nxt["items"][0]["seq"] == page["next_before_seq"] - 1
    assert client.get(f"{T}/activity?limit=201").status_code == 422
    assert client.get(f"{T}/activity?limit=200").status_code == 200
    assert client.get("/api/t/fremd/activity").status_code == 403


def test_activity_rate_limit(client, monkeypatch):
    monkeypatch.setenv("RATE_ACTIVITY", "2")
    assert [client.get(f"{T}/activity").status_code for _ in range(3)] == [200, 200, 429]


def test_private_mode_trip_masked_in_older_revisions(client):
    vid = new_vehicle(client)
    tid = uid()
    sync(client, op("trip", tid, _trip(vid)))
    sync(client, op("trip", tid, _trip(vid, category="private", purpose=None), base=1))
    reader = bearer_token(groups=["/fahrzeugbuch/privat/lesen"])
    trips = [i["summary"] for i in client.get(f"{T}/activity", headers=reader).json()["items"]
             if i["entity"] == "trip"]
    assert trips == ["Privatfahrt · 31 km", "Privatfahrt · 31 km"]   # auch der frühere geschäftliche Stand


# ---------- Mitglieder ohne Keycloak ----------
def test_members_without_keycloak(client):
    new_vehicle(client)
    anna = bearer_token(sub="user-2", preferred_username="anna", groups=["/fahrzeugbuch/privat"])
    sync(client, op("vehicle", uid(), {"name": "Up"}), headers=anna)
    r = client.get(f"{T}/members", headers=admin_web()).json()
    assert r["manageable"] is False
    assert {m["id"]: (m["username"], m["role"], m["source"]) for m in r["members"]} == {
        "user-1": ("jakob", None, "activity"), "user-2": ("anna", None, "activity")}
    assert r["members"][0]["id"] == "user-2" and r["members"][0]["last_activity_at"]
    body = {"user": "anna", "role": "read"}
    assert client.post(f"{T}/members", json=body, headers=admin_web()).status_code == 501
    assert client.post(f"{T}/members", json=body, headers=admin_web()).json()["detail"] == \
        "Mitgliederverwaltung nicht konfiguriert"
    assert client.patch(f"{T}/members/user-2", json={"role": "read"}, headers=admin_web()).status_code == 501
    assert client.delete(f"{T}/members/user-2", headers=admin_web()).status_code == 501
    r = client.post(f"{T}/members", json=body, headers=admin_ios())
    assert r.status_code == 403 and r.json()["detail"] == "Verwaltung nur im Webfrontend"
    assert client.post(f"{T}/members", json=body, headers=web_headers()).status_code == 403   # nur write
    assert client.get(f"{T}/members", headers=bearer_token(groups=["/fahrzeugbuch/privat/lesen"])).status_code \
        == 200


# ---------- Mitglieder mit Keycloak (HTTP-Mock) ----------
class FakeKeycloak:
    REALM = "test"

    def __init__(self):
        self.users = {
            "user-1": {"id": "user-1", "username": "jakob", "email": "jakob@example.test", "firstName": "Jakob",
                       "lastName": "Muster"},
            "user-2": {"id": "user-2", "username": "anna", "email": "anna@example.test", "firstName": "Anna"},
            "user-3": {"id": "user-3", "username": "treuhand", "email": "buero@treuhand.test"},
            "user-4": {"id": "user-4", "username": "zweit", "email": "zweit@example.test"},
        }
        self.groups: dict[str, dict] = {}     # id → {name, parent, members}
        self.tokens: set[str] = set()
        self.token_requests = 0
        self.requests: list[tuple[str, str]] = []
        self.fail = False
        self.fail_calls: set[tuple[str, int]] = set()   # (Methode, n-ter Aufruf der Admin-API) → einmal HTTP 500
        self.calls: dict[str, int] = {}
        self.lock = threading.Lock()

    # Hilfen für Tests
    def path_of(self, gid):
        g = self.groups[gid]
        return (self.path_of(g["parent"]) if g["parent"] else "") + "/" + g["name"]

    def by_path(self, path):
        return next((gid for gid in self.groups if self.path_of(gid) == path), None)

    def add_group(self, path):
        parent = None
        for i, name in enumerate(path.strip("/").split("/")):
            sub = "/" + "/".join(path.strip("/").split("/")[: i + 1])
            gid = self.by_path(sub)
            if gid is None:
                gid = f"g{len(self.groups) + 1}"
                self.groups[gid] = {"name": name, "parent": parent, "members": set()}
            parent = gid
        return parent

    def member(self, path, uid_):
        self.groups[self.add_group(path)]["members"].add(uid_)

    def paths_of(self, uid_):
        return sorted(self.path_of(g) for g, v in self.groups.items() if uid_ in v["members"])

    # HTTP
    def handle(self, h: BaseHTTPRequestHandler, method: str):
        url = urllib.parse.urlsplit(h.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        length = int(h.headers.get("Content-Length") or 0)
        body = h.rfile.read(length) if length else b""
        with self.lock:
            self.requests.append((method, url.path))
            if self.fail:
                return 500, None, {}
            if url.path == f"/realms/{self.REALM}/protocol/openid-connect/token":
                form = dict(urllib.parse.parse_qsl(body.decode()))
                if (form.get("grant_type"), form.get("client_id"), form.get("client_secret")) != \
                        ("client_credentials", "fzb-admin", "geheim"):
                    return 401, {"error": "unauthorized_client"}, {}
                self.token_requests += 1
                tok = f"tok-{self.token_requests}"
                self.tokens.add(tok)
                return 200, {"access_token": tok, "expires_in": 300}, {}
            auth = h.headers.get("Authorization", "")
            if auth[7:] not in self.tokens:
                return 401, None, {}
            prefix = f"/admin/realms/{self.REALM}"
            assert url.path.startswith(prefix)
            if method in ("PUT", "DELETE"):
                self.calls[method] = n = self.calls.get(method, 0) + 1
                if (method, n) in self.fail_calls:
                    return 500, None, {}
            parts = [urllib.parse.unquote(p) for p in url.path[len(prefix):].strip("/").split("/")]
            return self.route(method, parts, q, json.loads(body) if body else None)

    def route(self, method, parts, q, payload):
        if parts[0] == "group-by-path" and method == "GET":
            gid = self.by_path("/" + "/".join(parts[1:]))
            return (404, {"error": "Group path does not exist"}, {}) if gid is None else \
                (200, {"id": gid, "name": self.groups[gid]["name"], "path": self.path_of(gid)}, {})
        if parts == ["groups"] and method == "POST":
            if any(g["name"] == payload["name"] and g["parent"] is None for g in self.groups.values()):
                return 409, None, {}
            gid = self.add_group("/" + payload["name"])
            return 201, None, {"Location": f"http://kc/admin/realms/test/groups/{gid}"}
        if len(parts) == 3 and parts[0] == "groups" and parts[2] == "children" and method == "POST":
            gid = self.add_group(self.path_of(parts[1]) + "/" + payload["name"])
            return 201, None, {"Location": f"http://kc/admin/realms/test/groups/{gid}"}
        if len(parts) == 3 and parts[0] == "groups" and parts[2] == "members" and method == "GET":
            if parts[1] not in self.groups:
                return 404, None, {}
            ids = sorted(self.groups[parts[1]]["members"])
            first, mx = int(q.get("first", 0)), int(q.get("max", 100))
            return 200, [self.users[i] for i in ids[first:first + mx]], {}
        if parts == ["users"] and method == "GET":
            assert q.get("exact") == "true"
            for fld in ("username", "email"):
                if fld in q:
                    return 200, [u for u in self.users.values() if u[fld].lower() == q[fld].lower()], {}
        if len(parts) == 2 and parts[0] == "users" and method == "GET":
            u = self.users.get(parts[1])
            return (200, u, {}) if u else (404, None, {})
        if len(parts) == 4 and parts[0] == "users" and parts[2] == "groups":
            if parts[1] not in self.users or parts[3] not in self.groups:
                return 404, None, {}
            members = self.groups[parts[3]]["members"]
            if method == "PUT":
                members.add(parts[1])
            elif method == "DELETE":
                members.discard(parts[1])
            return 204, None, {}
        return 404, {"error": "unbekannt"}, {}


@pytest.fixture
def kc(monkeypatch):
    fake = FakeKeycloak()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _do(self, method):
            code, payload, headers = fake.handle(self, method)
            data = b"" if payload is None else json.dumps(payload).encode()
            self.send_response(code)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._do("GET")

        def do_POST(self):
            self._do("POST")

        def do_PUT(self):
            self._do("PUT")

        def do_DELETE(self):
            self._do("DELETE")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    monkeypatch.setenv("KC_ADMIN_URL", f"http://127.0.0.1:{server.server_address[1]}")
    monkeypatch.setenv("KC_ADMIN_CLIENT_ID", "fzb-admin")
    monkeypatch.setenv("KC_ADMIN_CLIENT_SECRET", "geheim")
    monkeypatch.delenv("KC_ADMIN_REALM", raising=False)       # aus OIDC_ISSUER: "test"
    fake.member("/fahrzeugbuch/privat/admin", "user-1")
    fake.member("/fahrzeugbuch/privat", "user-2")
    yield fake
    server.shutdown()
    server.server_close()


def test_members_list_from_keycloak(client, kc):
    new_vehicle(client)
    r = client.get(f"{T}/members", headers=admin_web()).json()
    assert r["manageable"] is True
    assert [(m["id"], m["username"], m["name"], m["role"], m["source"], m["email"]) for m in r["members"]] == [
        ("user-1", "jakob", "Jakob Muster", "admin", "keycloak", "jakob@example.test"),
        ("user-2", "anna", "Anna", "write", "keycloak", "anna@example.test")]
    assert r["members"][0]["last_activity_at"] and r["members"][1]["last_activity_at"] is None
    # Verwalter im iOS-Client: nicht verwaltbar; Leserolle: keine E-Mail
    assert client.get(f"{T}/members", headers=admin_ios()).json()["manageable"] is False
    reader = bearer_token(sub="user-3", groups=["/fahrzeugbuch/privat/lesen"])
    r = client.get(f"{T}/members", headers=reader).json()
    assert r["manageable"] is False and all(m["email"] is None for m in r["members"])
    assert kc.token_requests == 1                     # Token zwischengespeichert
    # Lesen legt keine Gruppen an
    assert kc.by_path("/fahrzeugbuch/privat/lesen") is None


def test_member_add_change_remove(client, kc):
    h = admin_web()
    # per E-Mail, Gruppen fehlen → werden angelegt
    r = client.post(f"{T}/members", json={"user": "Buero@Treuhand.test", "role": "read"}, headers=h)
    assert r.status_code == 201, r.text
    assert r.json() == {"id": "user-3", "username": "treuhand", "name": "treuhand", "email": "buero@treuhand.test",
                        "role": "read", "source": "keycloak", "last_activity_at": None}
    assert kc.paths_of("user-3") == ["/fahrzeugbuch/privat/lesen"]
    assert kc.by_path("/fahrzeugbuch/privat/lesen") and kc.by_path("/fahrzeugbuch/privat/admin")
    assert client.post(f"{T}/members", json={"user": "treuhand", "role": "write"}, headers=h).status_code == 409
    r = client.post(f"{T}/members", json={"user": "niemand", "role": "read"}, headers=h)
    assert r.status_code == 404 and r.json()["detail"] == "Benutzer nicht gefunden"
    assert client.post(f"{T}/members", json={"user": "anna", "role": "chef"}, headers=h).status_code == 422

    # Rolle ändern: genau eine Gruppe
    kc.member("/fahrzeugbuch/privat/lesen", "user-2")          # Altlast: doppelt zugeordnet
    r = client.patch(f"{T}/members/user-2", json={"role": "admin"}, headers=h)
    assert r.status_code == 200 and r.json()["role"] == "admin"
    assert kc.paths_of("user-2") == ["/fahrzeugbuch/privat/admin"]
    assert client.patch(f"{T}/members/user-9", json={"role": "read"}, headers=h).status_code == 404
    assert client.patch(f"{T}/members/..%2F..", json={"role": "read"}, headers=h).status_code == 404

    # Entfernen
    assert client.delete(f"{T}/members/user-3", headers=h).status_code == 204
    assert kc.paths_of("user-3") == []
    assert client.delete(f"{T}/members/user-3", headers=h).status_code == 404

    # Journal: Mitgliederänderungen nachvollziehbar, Integrität grün
    acts = [(i["entity"], i["action"], i["summary"]) for i in client.get(f"{T}/activity").json()["items"]]
    assert acts == [("membership", "delete", "Mitglied treuhand entfernt"),
                    ("membership", "update", "Rolle von anna: Verwalten"),
                    ("membership", "create", "Mitglied treuhand hinzugefügt (Lesen)")]
    v = client.get(f"{T}/audit/verify?full=1").json()
    assert v["ok"] and v["count"] == 3, v


def test_last_admin_protection(client, kc):
    h = admin_web()
    r = client.patch(f"{T}/members/user-1", json={"role": "write"}, headers=h)
    assert r.status_code == 409
    assert client.delete(f"{T}/members/user-1", headers=h).status_code == 409
    assert kc.paths_of("user-1") == ["/fahrzeugbuch/privat/admin"]
    # mit zweitem Verwalter: sich selbst herabstufen/entfernen erlaubt
    assert client.post(f"{T}/members", json={"user": "zweit", "role": "admin"}, headers=h).status_code == 201
    assert client.patch(f"{T}/members/user-1", json={"role": "write"}, headers=h).status_code == 200
    assert kc.paths_of("user-1") == ["/fahrzeugbuch/privat"]
    # user-4 ist nun einziger Verwalter: entfernen/herabstufen → 409
    h4 = admin_web(sub="user-4", preferred_username="zweit")
    assert client.delete(f"{T}/members/user-4", headers=h4).status_code == 409
    assert client.delete(f"{T}/members/user-1", headers=h4).status_code == 204
    # nichts ins Journal bei abgelehnten Änderungen
    acts = [i["action"] for i in client.get(f"{T}/activity").json()["items"] if i["entity"] == "membership"]
    assert acts == ["delete", "update", "create"]


def test_self_removal_requires_other_admin(client, kc):
    # Token sagt admin, Keycloak kennt den Benutzer aber nur als Schreibenden (Token veraltet)
    kc.groups[kc.by_path("/fahrzeugbuch/privat/admin")]["members"].discard("user-1")
    kc.member("/fahrzeugbuch/privat", "user-1")
    assert client.delete(f"{T}/members/user-1", headers=admin_web()).status_code == 409
    kc.member("/fahrzeugbuch/privat/admin", "user-4")
    assert client.delete(f"{T}/members/user-1", headers=admin_web()).status_code == 204


def test_member_mutation_permissions(client, kc):
    body = {"user": "treuhand", "role": "read"}
    r = client.post(f"{T}/members", json=body, headers=admin_ios())
    assert r.status_code == 403 and r.json()["detail"] == "Verwaltung nur im Webfrontend"
    assert client.patch(f"{T}/members/user-2", json={"role": "read"}, headers=admin_ios()).status_code == 403
    assert client.delete(f"{T}/members/user-2", headers=admin_ios()).status_code == 403
    assert client.post(f"{T}/members", json=body, headers=web_headers()).status_code == 403   # write
    assert client.post("/api/t/fremd/members", json=body, headers=admin_web()).status_code == 403
    assert kc.paths_of("user-3") == []


def test_keycloak_token_refresh_and_errors(client, kc, monkeypatch):
    h = admin_web()
    assert client.get(f"{T}/members", headers=h).status_code == 200
    kc.tokens.clear()                                   # Token serverseitig widerrufen → 401 → neues Token
    assert client.get(f"{T}/members", headers=h).json()["members"][0]["source"] == "keycloak"
    assert kc.token_requests == 2
    # Keycloak gestört: Liste fällt auf das Journal zurück, Änderungen → 502, nach Fehlern Circuit-Breaker
    kc.fail = True
    r = client.get(f"{T}/members", headers=h)
    assert r.status_code == 200 and all(m["source"] == "activity" for m in r.json()["members"])
    codes = [client.post(f"{T}/members", json={"user": "treuhand", "role": "read"}, headers=h).status_code
             for _ in range(3)]
    assert codes[0] == 502 and codes[-1] == 503
    kc.fail = False
    geo.reset_upstreams()
    # falsches Secret
    monkeypatch.setenv("KC_ADMIN_CLIENT_SECRET", "falsch")
    r = client.post(f"{T}/members", json={"user": "treuhand", "role": "read"}, headers=h)
    assert r.status_code == 502 and r.json()["detail"] == "Keycloak verweigert die Mitgliederverwaltung"
    assert kc.paths_of("user-3") == []


def _membership_acts(client) -> list[str]:
    return [i["action"] for i in client.get(f"{T}/activity").json()["items"] if i["entity"] == "membership"]


def test_member_change_compensated_when_keycloak_step_fails(client, kc):
    """S13: Rolle ändern = Gruppe zuweisen + alte Gruppen entfernen; scheitert ein späterer Schritt, werden die
    bereits ausgeführten zurückgenommen (Zustand wie vorher), nichts im Journal."""
    kc.member("/fahrzeugbuch/privat/lesen", "user-2")          # doppelt zugeordnet: zwei DELETE nötig
    before = kc.paths_of("user-2")
    kc.fail_calls = {("DELETE", 2)}
    r = client.patch(f"{T}/members/user-2", json={"role": "admin"}, headers=admin_web())
    assert r.status_code == 502
    assert kc.paths_of("user-2") == before
    assert _membership_acts(client) == []


def test_member_change_compensated_when_journal_commit_fails(client, kc, monkeypatch):
    """S13: Keycloak geändert, Journal/Commit scheitert → Keycloak-Schritte zurückgenommen."""
    from app import main

    real, broken = main.maybe_anchor, [True]

    def anchor(*args, **kwargs):
        if broken[0]:
            raise RuntimeError("DB weg")
        return real(*args, **kwargs)
    monkeypatch.setattr(main, "maybe_anchor", anchor)
    with pytest.raises(RuntimeError):
        client.post(f"{T}/members", json={"user": "treuhand", "role": "read"}, headers=admin_web())
    assert kc.paths_of("user-3") == []
    broken[0] = False
    assert _membership_acts(client) == []
    assert client.post(f"{T}/members", json={"user": "treuhand", "role": "read"}, headers=admin_web()).status_code \
        == 201
    assert _membership_acts(client) == ["create"]
