from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.routes import expenses

app = FastAPI(title=settings.app_name, version=settings.app_version)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(expenses.router)

# Exposes http_requests_total, http_request_duration_seconds, etc. on /metrics
Instrumentator(excluded_handlers=["/metrics", "/health"]).instrument(app).expose(
    app, endpoint="/metrics", include_in_schema=False
)


@app.get("/health", tags=["health"])
def health():
    """Liveness probe: the process is up."""
    return {"status": "ok", "version": settings.app_version}


@app.get("/health/ready", tags=["health"])
def readiness(db: Session = Depends(get_db)):
    """Readiness probe: the database is reachable."""
    db.execute(text("SELECT 1"))
    return {"status": "ready"}
