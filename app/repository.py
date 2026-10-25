"""DynamoDB access for the link shortener. Nothing else in the app talks to AWS."""

import os
import secrets

import boto3
from botocore.exceptions import ClientError

MAX_ATTEMPTS = 5


class CodeGenerationError(Exception):
    """Raised when no unused short code could be stored within MAX_ATTEMPTS."""


def _table():
    return boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def generate_code() -> str:
    # 6 random bytes -> 8 URL-safe characters, from the OS CSPRNG (not `random`).
    return secrets.token_urlsafe(6)


def save_link(url: str) -> str:
    """Store url under a fresh code and return the code.

    The conditional put makes DynamoDB reject a code that already exists, so a
    collision can never overwrite someone else's link; we just try a new code.
    """
    table = _table()
    for _ in range(MAX_ATTEMPTS):
        code = generate_code()
        try:
            table.put_item(
                Item={"code": code, "url": url},
                ConditionExpression="attribute_not_exists(code)",
            )
        except ClientError as err:
            if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
                continue
            raise
        return code
    raise CodeGenerationError("could not allocate a unique code")


def get_link(code: str) -> str | None:
    item = _table().get_item(Key={"code": code}).get("Item")
    return item["url"] if item else None
