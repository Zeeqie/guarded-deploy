"""SEEDED DEFECT #1 (experiments/seeded-defects.md): a test that fails. Never merge."""


def test_health_status_is_healthy(client):
    # Wrong on purpose: /health returns status "ok", not "healthy".
    assert client.get("/health").json()["status"] == "healthy"
