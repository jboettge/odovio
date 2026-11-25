"""Zugriffslog ohne Query-Strings: Koordinaten (Altaufrufe GET /api/geo/reverse?lat=…), Zeiträume u. ä.
gehören nicht ins Log. Wird beim Import von app.main am Logger `uvicorn.access` installiert; uvicorn
übergibt (client, method, full_path, http_version, status) als args. Pfad zusätzlich ohne Steuerzeichen
(Log-Injection) und gekürzt."""
import logging
import re

_CTRL = re.compile("[\x00-\x1f\x7f-\x9f]")


class StripQueryFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple) and len(args) >= 3 and isinstance(args[2], str):
            path = args[2].split("?", 1)[0]
            record.args = (*args[:2], _CTRL.sub("?", path)[:512], *args[3:])
        return True


def install() -> None:
    logger = logging.getLogger("uvicorn.access")
    if not any(isinstance(f, StripQueryFilter) for f in logger.filters):
        logger.addFilter(StripQueryFilter())
