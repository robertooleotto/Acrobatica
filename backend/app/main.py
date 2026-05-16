"""FastAPI entrypoint."""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .routers import facade_sessions

app = FastAPI(
    title="Acrobatica Backend",
    description="Stitching, rettifica e misurazione di facciate da foto.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # demo; restringere in produzione
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(facade_sessions.router)


@app.get("/health")
def health():
    return {"status": "ok"}
