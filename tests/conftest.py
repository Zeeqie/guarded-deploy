import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from app import repository
from app.main import app

TABLE = "links-test"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch, tmp_path):
    """Make real AWS unreachable: dummy creds, no profile, no config/credentials files."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-southeast-1")
    monkeypatch.setenv("AWS_CONFIG_FILE", str(tmp_path / "no-such-config"))
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", str(tmp_path / "no-such-credentials"))
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    monkeypatch.setenv("TABLE_NAME", TABLE)
    repository._table.cache_clear()  # never reuse a resource built under another test's env
    yield
    repository._table.cache_clear()


@pytest.fixture
def table(aws_env):
    with mock_aws():
        ddb = boto3.resource("dynamodb")
        yield ddb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "code", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "code", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )


@pytest.fixture
def client(table):
    return TestClient(app, follow_redirects=False)
