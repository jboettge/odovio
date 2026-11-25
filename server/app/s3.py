"""Schlanker S3-Client (S3-kompatibel: MinIO, Ceph RGW, AWS, RustFS, SeaweedFS) – nur stdlib, AWS Signature V4.

Bewusst ohne boto3/botocore (≈ 15 MB, viele transitive Pakete in der Hash-Lock-Datei): gebraucht werden nur
PUT (bedingt, If-None-Match: *), GET (gestreamt), HEAD und ListObjectsV2. Keine Weiterleitungen, kein Proxy aus
der Umgebung, Antwortgrössen begrenzt, TLS mit System-CAs.

Env:
  S3_ENDPOINT          z. B. https://minio.lan:9000 (leer → AWS: https://s3.<region>.amazonaws.com)
  S3_BUCKET            Pflicht
  S3_REGION            Default us-east-1
  S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_SESSION_TOKEN (optional) – auch als <NAME>_FILE
  S3_PREFIX            Schlüsselpräfix, Default "attachments/"
  S3_FORCE_PATH_STYLE  1 (Default) = https://endpoint/bucket/key, 0 = https://bucket.endpoint/key
  S3_TIMEOUT_S         Default 30
"""
import datetime as dt
import hashlib
import hmac
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

MAX_LIST_BYTES = 8 * 1024 * 1024
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


class S3Error(Exception):
    """S3 nicht erreichbar oder unerwartete Antwort (ohne Zugangsdaten/URL im Text)."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())


def _q(value: str, safe: str = "-_.~") -> str:
    return urllib.parse.quote(value, safe=safe)


@dataclass(frozen=True)
class S3Config:
    endpoint: str
    bucket: str
    region: str
    access_key: str
    secret_key: str
    session_token: str | None = None
    prefix: str = "attachments/"
    path_style: bool = True
    timeout: float = 30.0

    @classmethod
    def from_env(cls) -> "S3Config":
        env = os.environ.get
        region = (env("S3_REGION") or "us-east-1").strip()
        endpoint = (env("S3_ENDPOINT") or f"https://s3.{region}.amazonaws.com").strip().rstrip("/")
        bucket = (env("S3_BUCKET") or "").strip()
        if not bucket or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket):
            raise S3Error("S3_BUCKET fehlt oder ungültig")
        if urllib.parse.urlsplit(endpoint).scheme not in ("http", "https"):
            raise S3Error("S3_ENDPOINT: nur http/https")
        try:
            timeout = float(env("S3_TIMEOUT_S") or 30)
        except ValueError:
            timeout = 30.0
        return cls(endpoint=endpoint, bucket=bucket, region=region,
                   access_key=(env("S3_ACCESS_KEY_ID") or "").strip(),
                   secret_key=(env("S3_SECRET_ACCESS_KEY") or "").strip(),
                   session_token=(env("S3_SESSION_TOKEN") or "").strip() or None,
                   prefix=env("S3_PREFIX") if env("S3_PREFIX") is not None else "attachments/",
                   path_style=(env("S3_FORCE_PATH_STYLE") or "1") != "0", timeout=max(1.0, timeout))


@dataclass(frozen=True)
class ObjectInfo:
    key: str
    size: int
    etag: str
    last_modified: str

    @property
    def fingerprint(self) -> str:
        return f"s3:{self.etag}:{self.size}:{self.last_modified}"


class S3Client:
    def __init__(self, cfg: S3Config):
        self.cfg = cfg
        parts = urllib.parse.urlsplit(cfg.endpoint)
        self.scheme = parts.scheme
        self.host = parts.netloc if cfg.path_style else f"{cfg.bucket}.{parts.netloc}"
        self.base_path = parts.path.rstrip("/")

    # ---------- Signatur V4 ----------
    def _path(self, key: str) -> str:
        p = self.base_path + (f"/{self.cfg.bucket}" if self.cfg.path_style else "")
        return p + "/" + _q(key, safe="-_.~/")

    def _sign(self, method: str, path: str, query: dict, payload_hash: str, now: dt.datetime,
              amz_headers: dict | None = None) -> dict:
        """Signierte Header: host, x-amz-content-sha256, x-amz-date und alle x-amz-*-Header (Pflicht bei S3)."""
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        day = amz_date[:8]
        headers = {k.lower(): str(v).strip() for k, v in (amz_headers or {}).items()}
        headers.update({"host": self.host, "x-amz-content-sha256": payload_hash, "x-amz-date": amz_date})
        if self.cfg.session_token:
            headers["x-amz-security-token"] = self.cfg.session_token
        names = sorted(headers)
        canonical_query = "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items()))
        canonical = "\n".join([method, path, canonical_query, *(f"{n}:{headers[n]}" for n in names), "",
                               ";".join(names), payload_hash])
        scope = f"{day}/{self.cfg.region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        key = ("AWS4" + self.cfg.secret_key).encode()
        for part in (day, self.cfg.region, "s3", "aws4_request"):
            key = hmac.new(key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={self.cfg.access_key}/{scope}, "
                                    f"SignedHeaders={';'.join(names)}, Signature={signature}")
        del headers["host"]           # setzt urllib aus der URL (identisch)
        return headers

    def request(self, method: str, key: str = "", query: dict | None = None, body: bytes | None = None,
                payload_hash: str | None = None, headers: dict | None = None, ok=(200,)):
        """→ (Status, Antwort-Objekt); Antwort muss vom Aufrufer gelesen/geschlossen werden (Status in ok)."""
        query = query or {}
        path = self._path(key)
        payload_hash = payload_hash or (hashlib.sha256(body).hexdigest() if body else EMPTY_SHA256)
        extra = headers or {}
        amz = {k: v for k, v in extra.items() if k.lower().startswith("x-amz-")}
        hdrs = self._sign(method, path, query, payload_hash, dt.datetime.now(dt.UTC), amz)
        hdrs.update({k: v for k, v in extra.items() if not k.lower().startswith("x-amz-")})
        qs = "&".join(f"{_q(k)}={_q(v)}" for k, v in sorted(query.items()))
        url = f"{self.scheme}://{self.host}{path}" + (f"?{qs}" if qs else "")
        req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
        try:
            # Schema (http/https) in S3Config.from_env geprüft
            resp = _opener.open(req, timeout=self.cfg.timeout)  # nosec B310
        except urllib.error.HTTPError as e:
            if e.code in ok:
                return e.code, e
            code = _error_code(e)
            e.close()
            raise S3Error(f"{method} HTTP {e.code} {code}".strip()) from None
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise S3Error(f"{method} {type(e).__name__}") from None
        if resp.status not in ok:
            resp.close()
            raise S3Error(f"{method} HTTP {resp.status}")
        return resp.status, resp

    # ---------- Operationen ----------
    def key(self, name: str) -> str:
        return self.cfg.prefix + name

    def put(self, name: str, data: bytes, content_type: str, sha256: str, overwrite: bool = False) -> bool:
        """True = gespeichert, False = existierte bereits (If-None-Match: *, nie überschrieben)."""
        headers = {"Content-Type": content_type, "Content-Length": str(len(data)), "x-amz-meta-sha256": sha256}
        if not overwrite:
            headers["If-None-Match"] = "*"
        status, resp = self.request("PUT", self.key(name), body=data, payload_hash=sha256, headers=headers,
                                    ok=(200, 412))
        resp.close()
        return status == 200

    def head(self, name: str) -> ObjectInfo | None:
        status, resp = self.request("HEAD", self.key(name), ok=(200, 404))
        try:
            if status == 404:
                return None
            h = resp.headers
            return ObjectInfo(self.key(name), int(h.get("Content-Length") or 0), (h.get("ETag") or "").strip('"'),
                              h.get("Last-Modified") or "")
        finally:
            resp.close()

    def get(self, name: str):
        """Antwort-Objekt zum blockweisen Lesen (read(n)); None = nicht vorhanden."""
        status, resp = self.request("GET", self.key(name), ok=(200, 404))
        if status == 404:
            resp.close()
            return None
        return resp

    def list(self, prefix: str) -> list[ObjectInfo]:
        out, token = [], None
        while True:
            query = {"list-type": "2", "prefix": self.key(prefix), "max-keys": "1000"}
            if token:
                query["continuation-token"] = token
            _, resp = self.request("GET", "", query=query)
            with resp:
                body = resp.read(MAX_LIST_BYTES + 1)
            if len(body) > MAX_LIST_BYTES:
                raise S3Error("Liste zu gross")
            items, token = parse_list(body.decode("utf-8", "replace"))
            out += items
            if not token:
                return out

    def ping(self) -> None:
        _, resp = self.request("HEAD", "", ok=(200,))
        resp.close()


_CONTENTS = re.compile(r"<Contents>(.*?)</Contents>", re.S)


def _tag(block: str, name: str) -> str:
    m = re.search(rf"<{name}>(.*?)</{name}>", block, re.S)
    return _xml_unescape(m.group(1)) if m else ""


def _xml_unescape(s: str) -> str:
    return (s.replace("&quot;", '"').replace("&apos;", "'").replace("&lt;", "<").replace("&gt;", ">")
            .replace("&#34;", '"').replace("&amp;", "&"))


def parse_list(xml: str) -> tuple[list[ObjectInfo], str | None]:
    """ListObjectsV2 ohne XML-Parser (nur die benötigten Felder; keine Entitäten/DTD-Auswertung)."""
    items = []
    for block in _CONTENTS.findall(xml):
        try:
            size = int(_tag(block, "Size") or 0)
        except ValueError:
            size = 0
        items.append(ObjectInfo(_tag(block, "Key"), size, _tag(block, "ETag").strip('"'),
                                _tag(block, "LastModified")))
    rest = _CONTENTS.sub("", xml)
    token = _tag(rest, "NextContinuationToken") if _tag(rest, "IsTruncated") == "true" else ""
    return items, token or None


def _error_code(e: urllib.error.HTTPError) -> str:
    try:
        body = e.read(4096).decode("utf-8", "replace")
    except OSError:
        return ""
    m = re.search(r"<Code>([A-Za-z]{1,64})</Code>", body)
    return m.group(1) if m else ""
