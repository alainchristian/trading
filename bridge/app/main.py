import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse

from app.db import log_event
from app.logging_config import configure_logging
from app.routers import context, events, health, journal, risk, risk_state, signals, trades

configure_logging()
logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).resolve().parent / "static"


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Bridge service starting up")
    log_event("bridge", "startup", None)
    yield


app = FastAPI(title="Trading Platform Bridge", version="0.1.0", lifespan=lifespan)
app.include_router(health.router)
app.include_router(signals.router)
app.include_router(trades.router)
app.include_router(risk_state.router)
app.include_router(events.router)
app.include_router(context.router)
app.include_router(risk.router)
app.include_router(journal.router)


@app.get("/", include_in_schema=False)
def dashboard():
    return FileResponse(STATIC_DIR / "dashboard.html")
