"""Tiny API used as the shared CO3141 workload."""
from time import perf_counter
from fastapi import FastAPI, Query

app = FastAPI(title="CO3141 Shared Workload", version="1.0.0")


@app.get("/health")
def health():
    return {"status": "ok", "service": "co3141-api"}


@app.get("/work")
def work(seconds: int = Query(default=2, ge=1, le=30)):
    """CPU-bound endpoint for controlled load tests. Do not expose publicly for production."""
    started = perf_counter()
    deadline = started + seconds
    iterations = 0
    value = 0
    while perf_counter() < deadline:
        value = (value * 33 + iterations + 17) % 1_000_003
        iterations += 1
    return {
        "service": "co3141-api",
        "requested_seconds": seconds,
        "elapsed_seconds": round(perf_counter() - started, 3),
        "iterations": iterations,
        "checksum": value,
    }
