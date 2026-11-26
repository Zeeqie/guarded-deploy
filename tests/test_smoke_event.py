"""The pre-traffic smoke test (scripts/deploy.sh) invokes Lambda with this exact event file.

If Mangum or the route changes so the event no longer reaches /health, this fails in CI
instead of failing the first real deploy.
"""

import json
from pathlib import Path

from app.main import handler

EVENT = Path(__file__).resolve().parent.parent / "scripts" / "events" / "health.json"


def test_smoke_event_reaches_health(monkeypatch):
    monkeypatch.setenv("GIT_SHA", "0123abc")
    event = json.loads(EVENT.read_text())

    response = handler(event, None)

    assert response["statusCode"] == 200
    assert json.loads(response["body"]) == {"status": "ok", "version": "0123abc"}
