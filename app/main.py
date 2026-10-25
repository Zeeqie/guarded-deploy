"""FastAPI routes. `handler` is the AWS Lambda entry point (via Mangum)."""

import os

from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from mangum import Mangum
from pydantic import BaseModel, HttpUrl

from app import repository

app = FastAPI(title="guarded-deploy link shortener")


class LinkIn(BaseModel):
    url: HttpUrl


class LinkOut(BaseModel):
    code: str
    url: str


@app.get("/health")
def health() -> dict[str, str]:
    # No DynamoDB call on purpose: the smoke test must be fast, and `version`
    # tells us which release is actually serving traffic.
    return {"status": "ok", "version": os.environ.get("GIT_SHA", "dev")}


@app.post("/links", status_code=201)
def create_link(body: LinkIn) -> LinkOut:
    url = str(body.url)
    try:
        code = repository.save_link(url)
    except repository.CodeGenerationError:
        raise HTTPException(status_code=503, detail="try again") from None
    return LinkOut(code=code, url=url)


@app.get("/{code}")
def follow(code: str) -> RedirectResponse:
    url = repository.get_link(code)
    if url is None:
        raise HTTPException(status_code=404, detail="unknown code")
    return RedirectResponse(url, status_code=307)


handler = Mangum(app)
