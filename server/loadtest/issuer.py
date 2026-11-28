"""Lokaler Test-Issuer (OIDC-Discovery + JWKS über http) für Lasttest und Mehrprozess-Tests.

Die API muss mit OIDC_ALLOW_HTTP=1 und OIDC_ISSUER=<issuer.url> laufen (nur Test/Entwicklung!).

  python -m loadtest.issuer --port 8899 --print-token   → startet den Issuer und gibt ein Token aus
"""
import argparse
import base64
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

CLIENT_ID = "fahrzeugbuch-ios"
KID = "loadtest-kid"


def _b64(n: int) -> str:
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _load_or_create(key_file: str | None):
    if key_file and Path(key_file).is_file():
        return serialization.load_pem_private_key(Path(key_file).read_bytes(), password=None)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    if key_file:
        Path(key_file).write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                     serialization.NoEncryption()))
        Path(key_file).chmod(0o600)
    return key


class Issuer:
    def __init__(self, host: str = "127.0.0.1", port: int = 0, realm: str = "test", key_file: str | None = None):
        """key_file: Schlüssel wiederverwenden (die API cached JWKS bis 1 h je kid)."""
        self.key = _load_or_create(key_file)
        pub = self.key.public_key().public_numbers()
        jwks = json.dumps({"keys": [{"kty": "RSA", "kid": KID, "use": "sig", "alg": "RS256",
                                     "n": _b64(pub.n), "e": _b64(pub.e)}]}).encode()
        issuer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path.endswith("/.well-known/openid-configuration"):
                    body = json.dumps({"issuer": issuer.url, "jwks_uri": issuer.url + "/certs"}).encode()
                elif self.path.endswith("/certs"):
                    body = jwks
                else:
                    self.send_response(404)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer((host, port), Handler)
        self.url = f"http://{host}:{self.server.server_address[1]}/realms/{realm}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self) -> Issuer:
        self.thread.start()
        return self

    def stop(self) -> None:
        self.server.shutdown()

    def token(self, sub: str = "load-1", groups: tuple[str, ...] = ("/fahrzeugbuch/last",),
              lifetime: int = 3500, **claims) -> str:
        now = int(time.time())
        body = {"iss": self.url, "sub": sub, "azp": CLIENT_ID, "aud": "account", "iat": now, "exp": now + lifetime,
                "preferred_username": sub, "typ": "Bearer", "groups": list(groups),
                "realm_access": {"roles": ["fahrzeugbuch-user"]}}
        body.update(claims)
        return jwt.encode(body, self.key, algorithm="RS256", headers={"kid": KID})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8899)
    ap.add_argument("--print-token", action="store_true")
    ap.add_argument("--key-file", help="PEM-Schlüssel (wird angelegt, wenn nicht vorhanden)")
    args = ap.parse_args()
    iss = Issuer(args.host, args.port, key_file=args.key_file).start()
    print(f"OIDC_ISSUER={iss.url}", flush=True)
    if args.print_token:
        print(iss.token(), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        iss.stop()


if __name__ == "__main__":
    main()
