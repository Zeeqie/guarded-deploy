import functools

from app import repository


def test_health_defaults_to_dev(monkeypatch):
    """Unit: /health needs no DynamoDB table at all."""
    from fastapi.testclient import TestClient

    from app.main import app

    monkeypatch.delenv("GIT_SHA", raising=False)
    r = TestClient(app).get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok", "version": "dev"}


def test_health_reports_git_sha(monkeypatch):
    """Unit: version field comes from env GIT_SHA (used to verify live release)."""
    from fastapi.testclient import TestClient

    from app.main import app

    monkeypatch.setenv("GIT_SHA", "abc1234")
    assert TestClient(app).get("/health").json()["version"] == "abc1234"


def test_create_then_redirect(client):
    """Integration-style: API -> repository -> mocked DynamoDB round trip."""
    r = client.post("/links", json={"url": "https://example.com/page"})
    assert r.status_code == 201
    body = r.json()
    assert body["url"] == "https://example.com/page"

    redirect = client.get(f"/{body['code']}")
    assert redirect.status_code == 307
    assert redirect.headers["location"] == "https://example.com/page"


def test_invalid_url_rejected(client):
    """Integration-style: pydantic validation returns 422 before any DB write."""
    for bad in ["not a url", "ftp://example.com", ""]:
        assert client.post("/links", json={"url": bad}).status_code == 422
    assert client.post("/links", json={}).status_code == 422


def test_unknown_code_404(client):
    """Integration-style: missing item in DynamoDB -> 404."""
    assert client.get("/doesnotexist").status_code == 404


def test_collision_retries_with_new_code(client, table, monkeypatch):
    """Integration-style: first generated code already exists, so the
    conditional put fails and a second code is used; the original survives."""
    table.put_item(Item={"code": "taken", "url": "https://original.example"})
    codes = iter(["taken", "fresh"])
    monkeypatch.setattr(repository, "generate_code", lambda: next(codes))

    r = client.post("/links", json={"url": "https://new.example"})

    assert r.status_code == 201
    assert r.json()["code"] == "fresh"
    assert table.get_item(Key={"code": "taken"})["Item"]["url"] == "https://original.example"


def test_exhausted_retries_returns_503(client, table, monkeypatch):
    """Integration-style: every attempt collides -> 503, nothing overwritten."""
    table.put_item(Item={"code": "taken", "url": "https://original.example"})
    monkeypatch.setattr(repository, "generate_code", lambda: "taken")

    r = client.post("/links", json={"url": "https://new.example"})

    assert r.status_code == 503
    assert table.get_item(Key={"code": "taken"})["Item"]["url"] == "https://original.example"


def test_generate_code_is_urlsafe_and_varies():
    """Unit: codes are 8 URL-safe chars and not constant."""
    codes = {repository.generate_code() for _ in range(50)}
    assert len(codes) > 1
    assert all(len(c) == 8 and c.replace("-", "").replace("_", "").isalnum() for c in codes)


def test_unexpected_dynamodb_error_is_not_swallowed(table, monkeypatch):
    """Unit: a ClientError other than a collision is re-raised -> API returns 500."""
    from botocore.exceptions import ClientError
    from fastapi.testclient import TestClient

    from app.main import app

    class Denied:
        def put_item(self, **_):
            raise ClientError({"Error": {"Code": "AccessDeniedException"}}, "PutItem")

    monkeypatch.setattr(repository, "_table", functools.cache(lambda: Denied()))
    client = TestClient(app, raise_server_exceptions=False)
    assert client.post("/links", json={"url": "https://example.com"}).status_code == 500
