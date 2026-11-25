import os
import sys
from pathlib import Path

os.environ["DATABASE_URL"] = os.environ.get("FZB_TEST_DATABASE_URL") or "sqlite:///" + str(Path(__file__).parent / ".test.db")
os.environ["API_TOKEN"] = "test-token"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.db import Base, engine  # noqa: E402
from app.main import app  # noqa: E402


@pytest.fixture
def client():
    Base.metadata.drop_all(engine)
    with TestClient(app) as c:
        c.headers["Authorization"] = "Bearer test-token"
        yield c
