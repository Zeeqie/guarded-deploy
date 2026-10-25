import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

from app.main import app

TABLE = "links-test"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    # Dummy values so boto3 never looks for real credentials or config.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "ap-southeast-1")
    monkeypatch.setenv("TABLE_NAME", TABLE)


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
