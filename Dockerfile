# =============================================================================
# Agency Marketing OS — Multi-Stage Production Dockerfile
# =============================================================================

# ---- Builder Stage ----
FROM python:3.11-slim AS builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && pip install --no-cache-dir -r requirements.txt

# ---- Runtime Stage ----
FROM python:3.11-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 curl && rm -rf /var/lib/apt/lists/*
RUN groupadd -r appuser && useradd -r -g appuser -d /app -s /sbin/nologin appuser
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# *** THE FIX ***
# Tell Python to look in /app for packages.
# Without this, `from app.core.config import ...` fails because
# Python's working directory is /app but the `app` package lives
# inside /app (i.e. /app/app/).  PYTHONPATH=/app makes Python
# search /app, so it finds /app/app/ as the `app` package.
ENV PYTHONPATH=/app

WORKDIR /app
COPY --chown=appuser:appuser . .
RUN mkdir -p /app/logs && chown -R appuser:appuser /app
USER appuser
EXPOSE 8000

# uvicorn app.main:app → finds /app/app/main.py because PYTHONPATH=/app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4", "--proxy-headers", "--forwarded-allow-ips", "*"]
