from typing import Optional

from fastapi import APIRouter
from pydantic import BaseModel

from app.db import log_event

router = APIRouter()


class EventIn(BaseModel):
    source: str
    event_type: str
    payload: Optional[dict] = None


@router.post("/log-event")
def log_event_endpoint(event: EventIn):
    # Thin wrapper around the existing system_events writer (already used
    # internally by bridge startup/heartbeat) -- exposes it over HTTP so the
    # EA can record audit-trail events (e.g. partial closes) that don't
    # belong as columns on `trades`/`signals`.
    log_event(event.source, event.event_type, event.payload)
    return {"status": "ok"}
